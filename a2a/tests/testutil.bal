import ballerina/http;
import ballerina/lang.runtime;
import ballerina/os;
import ballerina/test;

# Base URL for Client/resolveAgentCard tests. Reads A2A_TEST_SERVER_URL so
# Phase 5's interoperability tests can point the same test suite at a real
# reference server later; falls back to the local scripted mock below.
#
# + return - the base URL to run tests against
public isolated function getServerBaseUrl() returns string {
    string envUrl = os:getEnv("A2A_TEST_SERVER_URL");
    if envUrl != "" {
        return envUrl;
    }
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

type MockRpcScript record {|
    json jsonBody = {};
    int statusCode = 200;
    http:SseEvent[] sseEvents = [];
    boolean isSse = false;
    decimal delaySeconds = 0;
|};

type MockWellKnownScript record {|
    boolean hasOverride = false;
    json overrideBody = {};
    int overrideStatus = 200;
|};

isolated MockRpcScript rpcScript = {};
isolated MockWellKnownScript wellKnownScript = {};

# Scripts the next JSON-RPC request to receive a plain JSON response.
#
# + body - the JSON body to respond with
# + statusCode - the HTTP status code to respond with
public isolated function setNextJsonResponse(json body, int statusCode = 200) {
    lock {
        rpcScript = {jsonBody: body.clone(), statusCode, isSse: false, delaySeconds: 0};
    }
}

# Scripts the next JSON-RPC request to receive an SSE stream response.
#
# + events - the canned SSE events to stream back
public isolated function setNextSseResponse(http:SseEvent[] events) {
    lock {
        rpcScript = {sseEvents: events.clone(), isSse: true, delaySeconds: 0};
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

service / on mockListener {
    resource function get \.well\-known/agent\-card\.json(http:Caller caller) returns error? {
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
        json _ = check req.getJsonPayload();

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
            res.setPayload(script.sseEvents.toStream());
            check caller->respond(res);
        } else {
            http:Response res = new;
            res.statusCode = script.statusCode;
            res.setJsonPayload(script.jsonBody);
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
