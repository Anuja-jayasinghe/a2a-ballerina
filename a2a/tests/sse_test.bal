import ballerina/http;
import ballerina/test;

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

# Exercises readSseStream(http:Response) end to end over a real HTTP
# connection — a short-lived listener serves a canned SSE response, a real
# http:Client fetches it, and the resulting http:Response (including its
# actual resp.getSseEventStream() call) is fed to readSseStream. Only
# A2AStreamGenerator was covered by the synthetic-stream tests below;
# readSseStream's own wiring had zero coverage before this test.
#
# + return - an error if any HTTP or stream operation fails
@test:Config {}
function testReadSseStreamOverRealHttpResponse() returns error? {
    http:Client testClient = check new ("http://localhost:19099");
    http:Response resp = check testClient->get("/events");

    stream<StreamResponse, error?> result = check readSseStream(resp);

    StreamResponse first = check expectValue(result.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(result.next());
    test:assertEquals((<TaskStatusUpdateEvent>second?.statusUpdate).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? third = result.next();
    test:assertTrue(third is (), "stream should be closed after the terminal status delivered over real HTTP");
}

// A synthetic SSE source for tests — no real HTTP involved. Feeds a
// pre-built array of http:SseEvent|error values to an A2AStreamGenerator.
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

@test:Config {}
function testA2AStreamGeneratorClosesOnTerminalStatus() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"artifactUpdate":{"taskId":"task-1","contextId":"ctx-1","artifact":{"artifactId":"art-1","parts":[{"text":"partial"}]}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`}
    ]);

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(generator.next());
    test:assertTrue(second?.artifactUpdate is TaskArtifactUpdateEvent, "artifact event should be delivered");

    StreamResponse third = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>third?.statusUpdate).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? fourth = generator.next();
    test:assertTrue(fourth is (), "stream should be closed after the terminal event, regardless of remaining source events");
}

@test:Config {}
function testA2AStreamGeneratorDoesNotCloseOnInputRequired() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_INPUT_REQUIRED"}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`}
    ]);

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_INPUT_REQUIRED);

    // If INPUT_REQUIRED had closed the stream, this would fail instead of returning the next event.
    StreamResponse second = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>second?.statusUpdate).status.state, TASK_STATE_WORKING);
}

@test:Config {}
function testA2AStreamGeneratorSkipsCommentFrames() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {comment: "keep-alive"},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`}
    ]);

    StreamResponse result = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>result?.statusUpdate).status.state, TASK_STATE_WORKING);
}

@test:Config {}
function testA2AStreamGeneratorPropagatesUnderlyingStreamErrorBeforeTerminal() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"artifactUpdate":{"taskId":"task-1","contextId":"ctx-1","artifact":{"artifactId":"art-1","parts":[{"text":"partial"}]}}}}`},
        error("connection reset by peer")
    ]);

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(generator.next());
    test:assertTrue(second?.artifactUpdate is TaskArtifactUpdateEvent, "artifact event should be delivered");

    record {| StreamResponse value; |}|error? third = generator.next();
    test:assertTrue(third is error, "an underlying stream error before a terminal status should propagate to the caller, not be swallowed");
    if third is error {
        test:assertEquals(third.message(), "connection reset by peer");
    }

    // The generator should have closed itself after surfacing the error.
    record {| StreamResponse value; |}|error? fourth = generator.next();
    test:assertTrue(fourth is (), "generator should be closed after propagating an underlying stream error");
}

@test:Config {}
function testA2AStreamGeneratorPropagatesMalformedJsonAsError() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: "{not valid json"}
    ]);

    record {| StreamResponse value; |}|error? result = generator.next();
    test:assertTrue(result is error, "malformed event data should surface as an error, not a panic");

    // The generator should close after surfacing the error.
    record {| StreamResponse value; |}|error? next = generator.next();
    test:assertTrue(next is (), "generator should be closed after a decode error");
}
