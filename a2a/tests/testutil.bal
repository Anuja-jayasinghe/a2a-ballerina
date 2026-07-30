import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;

# Base URL for the scripted mock A2A server used by Client tests.
#
# + return - the base URL to run tests against
public isolated function getServerBaseUrl() returns string {
    return "http://localhost:19199";
}

// ---- Scriptable mock A2A server -------------------------------------
//
// One listener, two resources: a static (optionally overridable) Agent
// Card at the well-known endpoint, and a single JSON-RPC endpoint at the
// root path (every Client operation POSTs to "" — the method name lives
// in the request body, not the URL) that replays whatever the current
// test last scripted via setNextJsonResponse/setNextSseResponse.
//
// Each script is bundled into a single record behind a single isolated
// variable, since Ballerina's `lock` statement rejects touching more than
// one isolated variable in one block.

listener http:Listener mockListener = check new (19199);

// ETag value for the default mock Agent Card
final string DEFAULT_MOCK_CARD_ETAG = "\"default-card-v1\"";

type MockRpcScript record {|
    json jsonBody = {};
    int statusCode = 200;
    http:SseEvent[] sseEvents = [];
    boolean isSse = false;
    decimal delaySeconds = 0;
    string? extensionsHeader = ();
|};

type MockWellKnownScript record {|
    boolean hasOverride = false;
    json overrideBody = {};
    int overrideStatus = 200;
    string? etag = ();
    int? conditionalStatus = ();
|};

isolated MockRpcScript rpcScript = {};
isolated MockWellKnownScript wellKnownScript = {};
isolated json lastRequestBody = {};
isolated map<string> lastRequestHeaders = {};

# Returns the JSON body of the last request the mock JSON-RPC endpoint
# received, so tests can assert on what the Client actually sent on the
# wire (e.g. tenant propagation).
#
# + return - the last received request body
public isolated function getLastRequestBody() returns json {
    lock {
        return lastRequestBody.clone();
    }
}

# Returns the headers of the last request the mock JSON-RPC endpoint
# received, so tests can assert on outbound headers (e.g. A2A-Extensions).
# Keys are lowercased, since the wire casing of header names varies with
# HTTP protocol negotiation on this connection (see the capture site for
# details) -- callers should look up headers by their lowercase name.
#
# + return - the last received request's headers, keyed by lowercase header name
public isolated function getLastRequestHeaders() returns map<string> {
    lock {
        return lastRequestHeaders.clone();
    }
}

# Scripts the next JSON-RPC request to receive a plain JSON response.
#
# + body - the JSON body to respond with
# + statusCode - the HTTP status code to respond with
# + extensionsHeader - optional X-A2A-Extensions header value to set on the response
public isolated function setNextJsonResponse(json body, int statusCode = 200, string? extensionsHeader = ()) {
    lock {
        rpcScript = {jsonBody: body.clone(), statusCode, isSse: false, delaySeconds: 0, extensionsHeader};
    }
}

# Scripts the next JSON-RPC request to receive an SSE stream response.
#
# + events - the canned SSE events to stream back
# + extensionsHeader - optional X-A2A-Extensions header value to set on the response
public isolated function setNextSseResponse(http:SseEvent[] events, string? extensionsHeader = ()) {
    lock {
        rpcScript = {sseEvents: events.clone(), isSse: true, delaySeconds: 0, extensionsHeader};
    }
}

# Delays the next JSON-RPC response by the given number of seconds, to
# exercise http:ClientConfiguration.timeout passthrough.
#
# + seconds - how long the mock server should wait before responding
public isolated function setNextDelay(decimal seconds) {
    lock {
        rpcScript.delaySeconds = seconds;
    }
}

# Overrides the well-known endpoint's response for one test (e.g. a
# malformed-card or non-200 scenario). Pass `()` to restore the default
# static card.
#
# + body - the JSON body to respond with, or `()` to use the default card
# + statusCode - the HTTP status code to respond with
public isolated function setWellKnownOverride(json? body, int statusCode = 200) {
    lock {
        if body is () {
            wellKnownScript = {};
        } else {
            // Preserve existing ETag and conditionalStatus when setting override
            string? existingEtag = wellKnownScript.etag;
            int? existingConditional = wellKnownScript.conditionalStatus;
            wellKnownScript = {hasOverride: true, overrideBody: body.clone(), overrideStatus: statusCode, etag: existingEtag, conditionalStatus: existingConditional};
        }
    }
}

# Sets the ETag value for well-known endpoint responses, enabling conditional
# request testing.
#
# + etagValue - the ETag value to include in responses (e.g., "\"v1\"")
public isolated function setWellKnownETag(string etagValue) {
    lock {
        wellKnownScript.etag = etagValue;
    }
}

# Sets the HTTP status code for a conditional well-known response when an
# If-None-Match header is present and matches the scripted ETag.
#
# + statusCode - the HTTP status code to respond with (typically 304)
public isolated function setWellKnownConditionalOverride(int statusCode) {
    lock {
        wellKnownScript.conditionalStatus = statusCode;
    }
}

# A minimal, valid Task JSON body, for tests that don't care about the
# task's contents and just need something that decodes successfully.
#
# + return - a minimal Task's JSON representation
public isolated function defaultTaskJson() returns json {
    return {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}};
}

isolated function defaultMockAgentCard() returns json {
    AgentCard card = {
        name: "Mock Weather Agent",
        description: "A scripted mock agent used by Client tests",
        version: "1.0.0",
        url: "http://localhost:19199",
        capabilities: {streaming: true},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC", tenant: "acme-corp"}
        ],
        skills: [
            {
                id: "weather-lookup",
                name: "Weather Lookup",
                description: "Reports current weather for a city"
            }
        ]
    };
    return card.toJson();
}

# Sends a response via the given caller, discarding any error instead of
# letting it propagate as the resource function's return value.
#
# Used for delayed responses (setNextDelay): when a test's client-side
# timeout fires first, the client has already closed the connection by
# the time this delayed respond() runs, so the write fails. Propagating
# that failure via `check` would make the resource function return an
# error, which the HTTP engine then tries to convert into its own error
# response on the same (already-attempted) exchange — logging a spurious
# "illegal return: response has already been sent" that reads like a
# real failure in test output. The client-side timeout is what the test
# actually asserts on; the server-side write failing afterward is
# expected and not actionable, so it's swallowed here rather than logged.
#
# + caller - the caller to respond on
# + res - the response to send
isolated function respondIgnoringClientGoneAway(http:Caller caller, http:Response res) {
    error? result = caller->respond(res);
    if result is error {
        // Deliberately ignored — see function doc above.
    }
}

service / on mockListener {
    resource function get \.well\-known/agent\-card\.json(http:Caller caller, http:Request req) returns error? {
        MockWellKnownScript wk;
        lock {
            wk = wellKnownScript.clone();
        }

        // Ensure default card has an ETag for conditional requests
        string etag;
        if wk.etag is string {
            etag = <string>wk.etag;
        } else if !wk.hasOverride {
            etag = DEFAULT_MOCK_CARD_ETAG;
        } else {
            etag = "";
        }

        // Check for conditional request (If-None-Match header)
        string|http:HeaderNotFoundError ifNoneMatch = req.getHeader("If-None-Match");
        if ifNoneMatch is string && wk.conditionalStatus is int && etag.length() > 0 && ifNoneMatch == etag {
            // Send conditional response (typically 304 Not Modified)
            http:Response res = new;
            res.statusCode = <int>wk.conditionalStatus;
            check caller->respond(res);
            return;
        }

        http:Response res = new;
        if wk.hasOverride {
            res.statusCode = wk.overrideStatus;
            res.setJsonPayload(wk.overrideBody);
        } else {
            res.statusCode = 200;
            res.setJsonPayload(defaultMockAgentCard());
        }
        if etag.length() > 0 {
            res.setHeader("ETag", etag);
        }
        check caller->respond(res);
    }

    resource function post .(http:Caller caller, http:Request req) returns error? {
        json body = check req.getJsonPayload();
        lock {
            lastRequestBody = body.clone();
        }

        // Header names are case-insensitive per HTTP semantics, but this
        // connection's actual wire casing varies with protocol negotiation
        // (HTTP/1.1 preserves the sender's casing; an h2c-upgraded HTTP/2
        // connection lowercases all header names per the HTTP/2 spec) --
        // observed directly across test runs on this same mock listener.
        // Normalizing to lowercase here makes header assertions stable
        // regardless of which protocol a given request happened to use.
        map<string> headers = {};
        foreach string headerName in req.getHeaderNames() {
            string|http:HeaderNotFoundError headerValue = req.getHeader(headerName);
            if headerValue is string {
                headers[headerName.toLowerAscii()] = headerValue;
            }
        }
        lock {
            lastRequestHeaders = headers.clone();
        }

        MockRpcScript script;
        lock {
            script = rpcScript.clone();
        }

        if script.delaySeconds > 0d {
            runtime:sleep(script.delaySeconds);
        }

        if script.isSse {
            // caller->respond() with a raw stream defaults POST responses
            // to 201; the Client checks for exactly 200, so set it explicitly.
            http:Response res = new;
            res.statusCode = 200;
            string? extHeader = script.extensionsHeader;
            if extHeader is string {
                res.setHeader("X-A2A-Extensions", extHeader);
            }
            res.setPayload(script.sseEvents.toStream());
            respondIgnoringClientGoneAway(caller, res);
        } else {
            http:Response res = new;
            res.statusCode = script.statusCode;
            string? extHeader = script.extensionsHeader;
            if extHeader is string {
                res.setHeader("X-A2A-Extensions", extHeader);
            }
            res.setJsonPayload(script.jsonBody);
            respondIgnoringClientGoneAway(caller, res);
        }
    }
}

// ---- Shared assertion helpers -----------------------------------------

# Unwraps a stream.next() result, failing the test immediately if the
# stream ended or returned an error where a value was expected. Same
# shape as the helper in modules/transport/tests/transport_test.bal —
# duplicated rather than imported, since test files aren't part of a
# module's exported API and can't be shared across modules.
#
# + result - the raw return value of a StreamResponse stream's next()
# + return - the decoded StreamResponse, or an error
public isolated function expectValue(record {| StreamResponse value; |}|error? result) returns StreamResponse|error {
    if result is error {
        return result;
    }
    if result is () {
        return error("expected a value but the stream ended");
    }
    return result.value;
}

# + task - the task to sanity-check
public isolated function assertValidTask(Task task) {
    test:assertTrue(task.id.length() > 0, "Task.id should be non-empty");
}

# + artifact - the artifact to extract text from
# + return - the first non-nil text part's content, if any
public isolated function extractArtifactText(Artifact artifact) returns string? {
    foreach Part part in artifact.parts {
        string? text = part?.text;
        if text is string {
            return text;
        }
    }
    return ();
}
