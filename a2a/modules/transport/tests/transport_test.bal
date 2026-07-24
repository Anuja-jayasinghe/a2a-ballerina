import ballerina/test;
import ballerina/a2a;
import ballerina/http;

// A short-lived listener + service, used only by
// testReadSseStreamOverRealHttpResponse to exercise readSseStream against
// a real http:Response rather than a synthetic stream.
listener http:Listener sseTestListener = check new (19099);

service /events on sseTestListener {
    resource function get .() returns stream<http:SseEvent, error?> {
        http:SseEvent[] events = [
            {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`},
            {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`}
        ];
        return events.toStream();
    }
}

@test:Config {}
function testJsonRpcRequestEncodesPerWireExample() returns error? {
    JsonRpcRequest req = {
        id: "550e8400-e29b-41d4-a716-446655440000",
        method: "message/send",
        params: {
            message: {
                messageId: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
                role: "ROLE_USER",
                parts: [{text: "What is the weather in Colombo?"}]
            },
            configuration: {
                acceptedOutputModes: ["text"],
                returnImmediately: false
            },
            tenant: "acme-corp"
        }
    };

    json expected = {
        jsonrpc: "2.0",
        id: "550e8400-e29b-41d4-a716-446655440000",
        method: "message/send",
        params: {
            message: {
                messageId: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
                role: "ROLE_USER",
                parts: [{text: "What is the weather in Colombo?"}]
            },
            configuration: {
                acceptedOutputModes: ["text"],
                returnImmediately: false
            },
            tenant: "acme-corp"
        }
    };

    test:assertEquals(req.toJson(), expected);
}

@test:Config {}
function testJsonRpcResponseDecodesSuccessExample() returns error? {
    json payload = {
        jsonrpc: "2.0",
        id: "550e8400-e29b-41d4-a716-446655440000",
        result: {
            id: "task-7f3a9b2c",
            contextId: "ctx-4e8d1a6f",
            status: {
                state: "TASK_STATE_COMPLETED",
                timestamp: "2026-07-20T14:32:11Z"
            },
            artifacts: [{
                artifactId: "art-9c2e",
                parts: [{text: "29 degrees Celsius and partly cloudy."}]
            }]
        }
    };

    JsonRpcResponse resp = check payload.cloneWithType(JsonRpcResponse);

    test:assertEquals(resp.id, "550e8400-e29b-41d4-a716-446655440000");
    test:assertTrue(resp?.'error is (), "error should be nil on a success response");

    json? result = resp?.result;
    test:assertTrue(result is json, "result should be present on a success response");
    a2a:Task task = check (<json>result).cloneWithType(a2a:Task);
    test:assertEquals(task.id, "task-7f3a9b2c");
    test:assertEquals(task.status.state, a2a:TASK_STATE_COMPLETED);
    test:assertEquals(task.artifacts.length(), 1);
}

@test:Config {}
function testJsonRpcResponseDecodesErrorExample() returns error? {
    json payload = {
        jsonrpc: "2.0",
        id: "550e8400-e29b-41d4-a716-446655440000",
        'error: {
            code: -32001,
            message: "Task not found",
            data: {taskId: "task-unknown"}
        }
    };

    JsonRpcResponse resp = check payload.cloneWithType(JsonRpcResponse);

    test:assertTrue(resp?.result is (), "result should be nil on an error response");

    JsonRpcError? rpcErr = resp?.'error;
    test:assertTrue(rpcErr is JsonRpcError, "error should be present on an error response");
    JsonRpcError err = <JsonRpcError>rpcErr;
    test:assertEquals(err.code, -32001);
    test:assertEquals(err.message, "Task not found");
}

@test:Config {}
function testToA2AErrorMapsTaskNotFound() {
    a2a:A2AError err = toA2AError({code: -32001, message: "Task not found"});
    test:assertTrue(err is a2a:TaskNotFoundError, "should map to TaskNotFoundError");
}

@test:Config {}
function testToA2AErrorMapsTaskNotCancelable() {
    a2a:A2AError err = toA2AError({code: -32002, message: "Task not cancelable"});
    test:assertTrue(err is a2a:TaskNotCancelableError, "should map to TaskNotCancelableError");
}

@test:Config {}
function testToA2AErrorMapsPushNotificationNotSupported() {
    a2a:A2AError err = toA2AError({code: -32003, message: "Push notifications not supported"});
    test:assertTrue(err is a2a:PushNotificationNotSupportedError, "should map to PushNotificationNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsUnsupportedOperation() {
    a2a:A2AError err = toA2AError({code: -32004, message: "Unsupported operation"});
    test:assertTrue(err is a2a:UnsupportedOperationError, "should map to UnsupportedOperationError");
}

@test:Config {}
function testToA2AErrorMapsContentTypeNotSupported() {
    a2a:A2AError err = toA2AError({code: -32005, message: "Content type not supported"});
    test:assertTrue(err is a2a:ContentTypeNotSupportedError, "should map to ContentTypeNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsInvalidAgentResponse() {
    a2a:A2AError err = toA2AError({code: -32006, message: "Invalid agent response"});
    test:assertTrue(err is a2a:InvalidAgentResponseError, "should map to InvalidAgentResponseError");
}

@test:Config {}
function testToA2AErrorMapsExtendedAgentCardNotConfiguredToUnsupportedOperation() {
    a2a:A2AError err = toA2AError({code: -32007, message: "Extended agent card not configured"});
    test:assertTrue(err is a2a:UnsupportedOperationError, "-32007 should map to UnsupportedOperationError");
}

@test:Config {}
function testToA2AErrorMapsExtensionSupportRequiredToUnsupportedOperation() {
    a2a:A2AError err = toA2AError({code: -32008, message: "Extension support required"});
    test:assertTrue(err is a2a:UnsupportedOperationError, "-32008 should map to UnsupportedOperationError");
}

@test:Config {}
function testToA2AErrorMapsVersionNotSupported() {
    a2a:A2AError err = toA2AError({code: -32009, message: "Version not supported"});
    test:assertTrue(err is a2a:VersionNotSupportedError, "should map to VersionNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsUnrecognizedCodeToInternalError() {
    a2a:A2AError err = toA2AError({code: -32600, message: "Invalid Request"});
    test:assertTrue(err is a2a:A2AInternalError, "unrecognised codes should map to A2AInternalError");
    a2a:A2AInternalError internalErr = <a2a:A2AInternalError>err;
    test:assertEquals(internalErr.detail().code, -32600);
}

# Regression test: toA2AError passes the JSON-RPC error message both as
# the error's own reason string and as A2AErrorDetail.message. Nothing
# previously verified these stay in sync — a caller reading err.message()
# (idiomatic Ballerina) must see the same text as err.detail().message.
@test:Config {}
function testToA2AErrorMessageMatchesDetailMessage() {
    a2a:A2AError err = toA2AError({code: -32001, message: "Task not found"});

    test:assertEquals(err.message(), "Task not found");
    test:assertEquals(err.detail().message, "Task not found");
    test:assertEquals(err.message(), err.detail().message);
}

# Exercises readSseStream(http:Response) end to end over a real HTTP
# connection — a short-lived listener serves a canned SSE response, a real
# http:Client fetches it, and the resulting http:Response (including its
# actual resp.getSseEventStream() call) is fed to readSseStream. Only
# A2AStreamGenerator was covered by the earlier synthetic-stream tests;
# readSseStream's own wiring had zero coverage before this test.
#
# + return - an error if any HTTP or stream operation fails
@test:Config {}
function testReadSseStreamOverRealHttpResponse() returns error? {
    http:Client testClient = check new ("http://localhost:19099");
    http:Response resp = check testClient->get("/events");

    stream<a2a:StreamResponse, error?> result = check readSseStream(resp);

    a2a:StreamResponse first = check expectValue(result.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>first?.statusUpdate).status.state, a2a:TASK_STATE_WORKING);

    a2a:StreamResponse second = check expectValue(result.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>second?.statusUpdate).status.state, a2a:TASK_STATE_COMPLETED);

    record {| a2a:StreamResponse value; |}|error? third = result.next();
    test:assertTrue(third is (), "stream should be closed after the terminal status delivered over real HTTP");
}

# Regression test: A2AError's 8 subtypes must be nominally distinct
# (declared with `distinct`), not plain aliases for `error<A2AErrorDetail>`.
# Without `distinct`, every subtype is structurally identical and `is`
# checks between siblings are always true regardless of which error was
# actually constructed — this previously let every testToA2AErrorMaps*
# test above pass for the wrong reason.
@test:Config {}
function testA2AErrorSubtypesAreMutuallyDistinguishable() {
    a2a:A2AError taskNotFound = toA2AError({code: -32001, message: "Task not found"});

    test:assertTrue(taskNotFound is a2a:A2AError, "every subtype must still satisfy the common base type");
    test:assertTrue(taskNotFound is a2a:TaskNotFoundError, "should be its own mapped type");
    test:assertFalse(taskNotFound is a2a:PushNotificationNotSupportedError, "must not match an unrelated sibling type");
    test:assertFalse(taskNotFound is a2a:A2AInternalError, "must not match an unrelated sibling type");
}

# A synthetic SSE source for tests — no real HTTP involved. Feeds a
# pre-built array of http:SseEvent|error values to an A2AStreamGenerator.
class TestSseSource {
    private (http:SseEvent|error)[] events;
    private int idx = 0;

    isolated function init((http:SseEvent|error)[] events) {
        self.events = events;
    }

    public isolated function next() returns record {| http:SseEvent value; |}|error? {
        if self.idx >= self.events.length() {
            return ();
        }
        http:SseEvent|error event = self.events[self.idx];
        self.idx += 1;
        if event is error {
            return event;
        }
        return {value: event};
    }
}

isolated function newGenerator((http:SseEvent|error)[] events) returns A2AStreamGenerator {
    stream<http:SseEvent, error?> sseStream = new (new TestSseSource(events));
    return new A2AStreamGenerator(sseStream);
}

# Unwraps a generator.next() result into its StreamResponse, failing the
# test immediately if the stream ended or returned an error where a value
# was expected.
#
# + result - the raw return value of A2AStreamGenerator.next()
# + return - the decoded StreamResponse, or an error
isolated function expectValue(record {| a2a:StreamResponse value; |}|error? result) returns a2a:StreamResponse|error {
    if result is error {
        return result;
    }
    if result is () {
        return error("expected a value but the stream ended");
    }
    return result.value;
}

@test:Config {}
function testA2AStreamGeneratorClosesOnTerminalStatus() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"artifactUpdate":{"taskId":"task-1","contextId":"ctx-1","artifact":{"artifactId":"art-1","parts":[{"text":"partial"}]}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`}
    ]);

    a2a:StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>first?.statusUpdate).status.state, a2a:TASK_STATE_WORKING);

    a2a:StreamResponse second = check expectValue(generator.next());
    test:assertTrue(second?.artifactUpdate is a2a:TaskArtifactUpdateEvent, "artifact event should be delivered");

    a2a:StreamResponse third = check expectValue(generator.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>third?.statusUpdate).status.state, a2a:TASK_STATE_COMPLETED);

    record {| a2a:StreamResponse value; |}|error? fourth = generator.next();
    test:assertTrue(fourth is (), "stream should be closed after the terminal event, regardless of remaining source events");
}

@test:Config {}
function testA2AStreamGeneratorDoesNotCloseOnInputRequired() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_INPUT_REQUIRED"}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`}
    ]);

    a2a:StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>first?.statusUpdate).status.state, a2a:TASK_STATE_INPUT_REQUIRED);

    // If INPUT_REQUIRED had closed the stream, this would fail instead of returning the next event.
    a2a:StreamResponse second = check expectValue(generator.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>second?.statusUpdate).status.state, a2a:TASK_STATE_WORKING);
}

@test:Config {}
function testA2AStreamGeneratorSkipsCommentFrames() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {comment: "keep-alive"},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`}
    ]);

    a2a:StreamResponse result = check expectValue(generator.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>result?.statusUpdate).status.state, a2a:TASK_STATE_WORKING);
}

@test:Config {}
function testA2AStreamGeneratorPropagatesMalformedJsonAsError() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: "{not valid json"}
    ]);

    record {| a2a:StreamResponse value; |}|error? result = generator.next();
    test:assertTrue(result is error, "malformed event data should surface as an error, not a panic");

    // The generator should close after surfacing the error.
    record {| a2a:StreamResponse value; |}|error? next = generator.next();
    test:assertTrue(next is (), "generator should be closed after a decode error");
}
