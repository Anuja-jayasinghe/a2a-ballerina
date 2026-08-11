import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;

# Base URL for the scripted mock A2A server used by Client tests.
#
# + return - the base URL to run tests against
public isolated function getServerBaseUrl() returns string {
    return "http://localhost:19199";
}

# Port the scripted mock gRPC A2AService (tests/grpcmock_service.bal) listens
# on, distinct from the HTTP mock's 19199. Shared as a single constant with
# tests/grpcmock_scripting.bal and tests/grpcmock_service.bal so the port
# only needs to change in one place.
const int GRPC_MOCK_PORT = 19198;

# Port of the scripted mock gRPC A2AService used by gRPC-binding Client
# tests (see tests/grpcmock_service.bal), distinct from the HTTP mock's
# 19199.
#
# + return - the port the gRPC mock listens on
public isolated function getGrpcMockPort() returns int {
    return GRPC_MOCK_PORT;
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

type MockRpcScript record {|
    json jsonBody = {};
    int statusCode = 200;
    http:SseEvent[] sseEvents = [];
    boolean isSse = false;
    decimal delaySeconds = 0;
    string? extensionsHeader = ();
    // When true, the SSE response ends the scripted events with a genuine
    // stream error instead of a clean end-of-stream — simulating a dropped
    // connection (as opposed to sseEvents simply running out, which the
    // underlying HTTP response framing surfaces as a normal, error-free
    // stream end). Used to exercise ReconnectingStreamGenerator's
    // reconnect-on-error path, which must NOT trigger on a clean close.
    boolean simulateDropError = false;
|};

type MockWellKnownScript record {|
    boolean hasOverride = false;
    json overrideBody = {};
    int overrideStatus = 200;
|};

isolated MockRpcScript rpcScript = {};
isolated MockWellKnownScript wellKnownScript = {};
isolated json lastRequestBody = {};
isolated map<string> lastRequestHeaders = {};

type MockRestScript record {|
    json jsonBody = {};
    int statusCode = 200;
    boolean hasResponseBody = true;
    map<string> lastQueryParams = {};
    string lastPath = "";
    string lastMethod = "";
    json lastBody = {};
    http:SseEvent[] sseEvents = [];
    boolean isSse = false;
    boolean simulateDropError = false;
    // Task 6's SubscribeToTask GET-vs-POST fallback support: when set,
    // the mock rejects exactly one request of this method with this
    // status, then clears itself so the retry (a different method)
    // succeeds normally. () means no rejection scripted.
    string? rejectMethod = ();
    int rejectStatusCode = 0;
|};

isolated MockRestScript restScript = {};

# Scripts the next REST request to receive a plain JSON response.
#
# + body - the JSON body to respond with
# + statusCode - the HTTP status code to respond with
# + hasResponseBody - false for e.g. a DELETE's empty 204 response
public isolated function setNextRestResponse(json body, int statusCode = 200, boolean hasResponseBody = true) {
    lock {
        restScript = {jsonBody: body.clone(), statusCode, hasResponseBody};
    }
}

# Scripts the next REST request to receive an SSE stream response, with
# bare StreamResponse JSON event data (no JSON-RPC envelope) — the REST
# binding's actual wire shape.
#
# + events - the canned SSE events to stream back
public isolated function setNextRestSseResponse(http:SseEvent[] events) {
    lock {
        restScript.sseEvents = events.clone();
        restScript.isSse = true;
        restScript.simulateDropError = false;
    }
}

# Scripts the mock to reject exactly the next request of the given HTTP
# method with the given status code (e.g. simulating a server that only
# routes POST for an operation the proto annotates as GET), then clear
# the rejection so a subsequent request — the client's retry with a
# different method — succeeds normally against whatever else is scripted.
#
# + httpMethod - the method to reject once, e.g. "GET"
# + statusCode - the status to reject it with, e.g. 405
public isolated function setRestRejectMethod(string httpMethod, int statusCode) {
    lock {
        restScript.rejectMethod = httpMethod;
        restScript.rejectStatusCode = statusCode;
    }
}

# Returns the method, path, and query params of the last REST request the
# mock received, so tests can assert on exactly what the Client sent.
#
# + return - a record with the last request's method, path, and query params
public isolated function getLastRestRequest() returns record {| string method; string path; map<string> queryParams; |} {
    lock {
        return {method: restScript.lastMethod, path: restScript.lastPath, queryParams: restScript.lastQueryParams.clone()};
    }
}

# Returns the JSON body of the last REST request the mock received, so
# tests can assert on what the Client actually sent on the wire (e.g. the
# M3/M4 tenant/path-param body duplication for hasBody operations). `{}`
# for a bodiless request (e.g. a GET or DELETE, which never carries a
# request body to parse).
#
# + return - the last REST request's JSON body, or `{}` if it had none
public isolated function getLastRestBody() returns json {
    lock {
        return restScript.lastBody.clone();
    }
}

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
# + extensionsHeader - optional A2A-Extensions header value to set on the response
public isolated function setNextJsonResponse(json body, int statusCode = 200, string? extensionsHeader = ()) {
    lock {
        rpcScript = {jsonBody: body.clone(), statusCode, isSse: false, delaySeconds: 0, extensionsHeader};
    }
}

# Scripts the next JSON-RPC request to receive an SSE stream response.
#
# + events - the canned SSE events to stream back
# + extensionsHeader - optional A2A-Extensions header value to set on the response
public isolated function setNextSseResponse(http:SseEvent[] events, string? extensionsHeader = ()) {
    lock {
        rpcScript = {sseEvents: events.clone(), isSse: true, delaySeconds: 0, extensionsHeader};
    }
}

# Scripts the next JSON-RPC request to receive an SSE stream that plays the
# given events and then ends with a genuine stream error, simulating a
# dropped connection — distinct from setNextSseResponse, whose events
# simply running out produces a normal, error-free stream end (proven by
# testSendMessageStreamPausesAtInputRequiredThenResumes). Used to exercise
# the reconnect-on-error path of automatic SSE reconnection.
#
# + events - the canned SSE events to stream back before the simulated drop
public isolated function setNextSseResponseThenDrop(http:SseEvent[] events) {
    lock {
        rpcScript = {sseEvents: events.clone(), isSse: true, delaySeconds: 0, simulateDropError: true};
    }
}

# A synthetic SSE source that replays a fixed list of events, then yields a
# stream error instead of ending cleanly — used by
# setNextSseResponseThenDrop to simulate a dropped connection at the wire
# level, since a plain array-backed stream (events.toStream()) has no way
# to end with anything but a clean, error-free close.
isolated class DropAfterEventsGenerator {
    private final http:SseEvent[] & readonly events;
    private int idx = 0;

    isolated function init(http:SseEvent[] events) {
        self.events = events.cloneReadOnly();
    }

    public isolated function next() returns record {| http:SseEvent value; |}|error? {
        int i;
        lock {
            i = self.idx;
            self.idx += 1;
        }
        if i >= self.events.length() {
            return error("simulated connection drop");
        }
        return {value: self.events[i]};
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
            wellKnownScript = {hasOverride: true, overrideBody: body.clone(), overrideStatus: statusCode};
        }
    }
}

# A minimal, valid Task JSON body, for tests that don't care about the
# task's contents and just need something that decodes successfully.
#
# + return - a minimal Task's JSON representation
public isolated function defaultTaskJson() returns json {
    return {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}};
}

# Builds a Task JSON body with the specified task ID and state, wrapped in a
# JSON-RPC response envelope for use with setNextJsonResponse().
#
# + taskId - the task identifier to stamp on the task
# + state - the TaskState string value (e.g. "TASK_STATE_FAILED")
# + return - the JSON-RPC response body with the task
public isolated function taskJsonWithState(string taskId, string state) returns json {
    return {
        jsonrpc: "2.0",
        id: "1",
        result: {id: taskId, status: {state: state}}
    };
}

# Builds a JSON-RPC-enveloped {"task": {...}} SSE data payload — the shape
# a real sendStreamingMessage response opens with per specification section
# 3.1.1 (the stream opens with a Task or a Message, then delivers zero or
# more status/artifact update events).
#
# + taskId - the task identifier to stamp on the task
# + state - the TaskState string value (e.g. "TASK_STATE_SUBMITTED")
# + return - the SSE event's `data:` field content
public isolated function taskJson(string taskId, string state = "TASK_STATE_SUBMITTED") returns string {
    return string `{"jsonrpc":"2.0","id":"1","result":{"task":{"id":"${taskId}","status":{"state":"${state}"}}}}`;
}

# Builds a JSON-RPC-enveloped {"message": {...}} SSE data payload — the
# other valid shape sendStreamingMessage can open with per specification
# section 3.1.1: a plain conversational reply with no task. Used to
# exercise the no-op reconnect-wrapping path, since a bare Message carries
# no taskId to resubscribe with.
#
# + messageId - the message identifier to stamp on the reply
# + return - the SSE event's `data:` field content
public isolated function messageJson(string messageId) returns string {
    return string `{"jsonrpc":"2.0","id":"1","result":{"message":{"messageId":"${messageId}","role":"ROLE_AGENT","parts":[{"text":"a direct reply"}]}}}`;
}

# Builds a JSON-RPC-enveloped TaskStatusUpdateEvent SSE data payload, for
# tests scripting a status-update SSE event without repeating the envelope
# shape inline (follows the same {"jsonrpc":"2.0","id":"1","result":{...}}
# envelope other tests in client_test.bal construct by hand).
#
# + taskId - the task identifier to stamp on the status update
# + state - the TaskState string value (e.g. "TASK_STATE_WORKING")
# + return - the SSE event's `data:` field content
public isolated function statusUpdateJson(string taskId, string state) returns string {
    return string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"${taskId}","contextId":"ctx-1","status":{"state":"${state}"}}}}`;
}

isolated function defaultMockAgentCard() returns json {
    AgentCard card = {
        name: "Mock Weather Agent",
        description: "A scripted mock agent used by Client tests",
        version: "1.0.0",
        url: "http://localhost:19199",
        // The mock answers GetExtendedAgentCard, so the card declares the
        // capability. This matters now that every Client holds a card:
        // getExtendedAgentCard short-circuits on a card declaring
        // extendedAgentCard=false, so a neutral fixture would silently stop
        // every extended-card test from ever reaching the wire.
        capabilities: {streaming: true, extendedAgentCard: true},
        // All three bindings are declared so a test can construct any
        // binding's client from getServerBaseUrl() alone. The client
        // resolves this card over HTTP from the 19199 mock, then dials
        // whichever interface matches its binding — for GRPC that is the
        // separate gRPC mock port.
        //
        // No tenant is declared here on purpose: tenant auto-wiring is
        // exercised by tests that override the well-known card with one
        // that does declare it, so the common fixture stays neutral and
        // every other test's request params are unaffected.
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC"},
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON"},
            {url: string `http://localhost:${GRPC_MOCK_PORT}`, protocolBinding: "GRPC"}
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

        http:Response res = new;
        if wk.hasOverride {
            res.statusCode = wk.overrideStatus;
            res.setJsonPayload(wk.overrideBody);
        } else {
            res.statusCode = 200;
            res.setJsonPayload(defaultMockAgentCard());
        }
        check caller->respond(res);
    }

    resource function post .(http:Caller caller, http:Request req) returns error? {
        json body = check req.getJsonPayload();
        lock {
            lastRequestBody = body.clone();
        }

        // Header names are case-insensitive per HTTP semantics, but this
        // connection's actual wire casing varies with protocol negotiation.
        // Confirmed by logging req.getHeaderNames() directly: the client's
        // http:ClientConfiguration defaults httpVersion to "2.0" with
        // http2PriorKnowledge false (ballerina/http's own defaults -- not
        // anything this repo configures), so the first request on a fresh
        // connection is a plaintext HTTP/1.1 request carrying `Upgrade:
        // h2c`/`HTTP2-Settings` and preserves the sender's original header
        // casing (e.g. "A2A-Extensions"), while every subsequent request
        // reusing that same pooled, now-upgraded connection is real HTTP/2
        // framing, which came through with all-lowercase header names
        // (e.g. "a2a-extensions") -- consistent with HTTP/2 requiring
        // lowercase header field names on the wire. Normalizing to
        // lowercase here makes header assertions stable regardless of
        // which of those two cases a given test's request happens to hit.
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
                res.setHeader("A2A-Extensions", extHeader);
            }
            if script.simulateDropError {
                stream<http:SseEvent, error?> dropStream = new (new DropAfterEventsGenerator(script.sseEvents));
                res.setPayload(dropStream);
            } else {
                res.setPayload(script.sseEvents.toStream());
            }
            respondIgnoringClientGoneAway(caller, res);
        } else {
            http:Response res = new;
            res.statusCode = script.statusCode;
            string? extHeader = script.extensionsHeader;
            if extHeader is string {
                res.setHeader("A2A-Extensions", extHeader);
            }
            res.setJsonPayload(script.jsonBody);
            respondIgnoringClientGoneAway(caller, res);
        }
    }

    // Method-agnostic catch-all for the REST/HTTP+JSON binding's
    // resources (e.g. /tasks/{id}, /tasks/{id}:cancel,
    // /tasks/{taskId}/pushNotificationConfigs). Confirmed empirically to
    // be the only mechanism that can express a `/tasks/{id}:cancel`-shaped
    // path: a resource path segment cannot combine a bracketed path-param
    // with an adjacent literal suffix like `:cancel`, so per-operation
    // resource routing isn't possible here. This 'default resource
    // matches any HTTP method not already matched by a more specific
    // resource above (e.g. the well-known card GET or the JSON-RPC root
    // POST), and yields the full raw path via the [string... path] rest
    // parameter.
    resource function 'default [string... path](http:Caller caller, http:Request req) returns error? {
        MockRestScript script;
        lock {
            script = restScript.clone();
        }
        map<string> queryParams = {};
        foreach string k in req.getQueryParams().keys() {
            string? v = req.getQueryParamValue(k);
            if v is string {
                queryParams[k] = v;
            }
        }
        // req.rawPath is the actual wire path (percent-encoding intact),
        // plus the query string; the [string... path] rest param, by
        // contrast, gives each segment already percent-decoded by the
        // routing layer, which would hide a real encoding bug (e.g. "/"
        // in a path param must arrive as "%2F", not a literal "/"). Strip
        // just the query string, keep everything else as sent.
        string rawPath = req.rawPath;
        int? qIdx = rawPath.indexOf("?");
        string fullPath = qIdx is int ? rawPath.substring(0, qIdx) : rawPath;
        // GET/DELETE requests never carry a body -- getJsonPayload() on a
        // bodiless request is an error, not a useful {} value, so this is
        // guarded rather than `check`ed; a genuinely malformed body on a
        // POST is likewise tolerated here (recorded as {}) since body
        // well-formedness isn't this mock's concern -- it exists to let
        // tests assert on what the Client sent, not to validate it.
        json|error parsedBody = req.getJsonPayload();
        json capturedBody = parsedBody is json ? parsedBody : {};
        lock {
            restScript.lastMethod = req.method;
            restScript.lastPath = fullPath;
            restScript.lastQueryParams = queryParams.clone();
            restScript.lastBody = capturedBody.clone();
        }

        if script.rejectMethod is string && req.method == script.rejectMethod {
            http:Response rejectRes = new;
            rejectRes.statusCode = script.rejectStatusCode;
            lock {
                restScript.rejectMethod = ();
            }
            check caller->respond(rejectRes);
            return;
        }

        http:Response res = new;
        if script.isSse {
            // caller->respond() with a raw stream defaults POST responses
            // to 201; the Client checks for exactly 200, so set it explicitly.
            res.statusCode = 200;
            if script.simulateDropError {
                stream<http:SseEvent, error?> dropStream = new (new DropAfterEventsGenerator(script.sseEvents));
                res.setPayload(dropStream);
            } else {
                res.setPayload(script.sseEvents.toStream());
            }
            respondIgnoringClientGoneAway(caller, res);
        } else {
            res.statusCode = script.statusCode;
            if script.hasResponseBody {
                res.setJsonPayload(script.jsonBody);
            }
            check caller->respond(res);
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
