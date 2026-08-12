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

isolated function newGenerator((http:SseEvent|error)[] events, ProtocolMode mode = "V1_0") returns A2AStreamGenerator {
    stream<http:SseEvent, error?> sseStream = new (new TestSseSource(events));
    return new A2AStreamGenerator(sseStream, mode);
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

# isTerminalEvent is a four-way OR, but only TASK_STATE_COMPLETED was ever
# exercised as a stream terminator — dropping any of the other three arms
# left the suite green. Each terminal state is checked here against a
# generator whose next event must never be delivered, and each interrupted
# state against one whose next event must be.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testA2AStreamGeneratorClosesOnEveryTerminalStateAndOnlyThose() returns error? {
    string[] terminal = [
        "TASK_STATE_COMPLETED", "TASK_STATE_FAILED",
        "TASK_STATE_CANCELED", "TASK_STATE_REJECTED"
    ];
    foreach string state in terminal {
        A2AStreamGenerator generator = newGenerator([
            {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"${state}"}}}}`},
            {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}}`}
        ]);
        StreamResponse first = check expectValue(generator.next());
        test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, <TaskState>state);

        record {| StreamResponse value; |}|error? second = generator.next();
        test:assertTrue(second is (),
                string `${state} is a terminal state and must close the stream, leaving the following event undelivered`);
    }

    // The states a task can rest in mid-conversation must NOT close it —
    // otherwise a stream that pauses for input can never be resumed.
    string[] nonTerminal = [
        "TASK_STATE_SUBMITTED", "TASK_STATE_WORKING",
        "TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"
    ];
    foreach string state in nonTerminal {
        A2AStreamGenerator generator = newGenerator([
            {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"${state}"}}}}`},
            {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`}
        ]);
        _ = check expectValue(generator.next());
        StreamResponse second = check expectValue(generator.next());
        test:assertEquals((<TaskStatusUpdateEvent>second?.statusUpdate).status.state, TASK_STATE_COMPLETED,
                string `${state} is not terminal and must leave the stream open`);
    }
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

@test:Config {}
function testA2AStreamGeneratorDecodesV03StatusUpdate() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"working"}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"completed"}}}`}
    ], "V0_3");

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>second?.statusUpdate).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? third = generator.next();
    test:assertTrue(third is (), "stream should close after the v0.3 terminal status, same as v1.0");
}

# Confirms end-to-end (not just decodeV03StreamEvent in isolation) that
# final:true on a non-terminal v0.3 state does not close the stream —
# terminal-ness must come only from the translated TaskState.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testA2AStreamGeneratorIgnoresV03FinalFieldOnNonTerminalState() returns error? {
    A2AStreamGenerator generator = newGenerator([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"working"},"final":true}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"completed"}}}`}
    ], "V0_3");

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    // If final:true had closed the stream despite the non-terminal state,
    // this would return () instead of the second event.
    StreamResponse second = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>second?.statusUpdate).status.state, TASK_STATE_COMPLETED);
}
