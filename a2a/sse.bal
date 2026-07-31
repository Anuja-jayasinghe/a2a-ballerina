// SSE stream decoding for the A2A client.
//
// Lives in the root module, not modules/transport/, because it constructs
// StreamResponse/A2AError values directly and modules/transport/ cannot
// import the root a2a module without creating a cyclic module dependency
// (the root module already needs to import modules/transport/ for the
// JSON-RPC envelope types). See LEARNING_LOG.md.

import ballerina/a2a.transport;
import ballerina/http;

# Wraps the standard library SSE event stream, decoding each event's
# JSON-RPC envelope into a StreamResponse and closing the stream once a
# terminal task status is reached.
#
# + resp - the HTTP response opened with `Accept: text/event-stream`
# + mode - which wire dialect to decode events as; defaults to V1_0,
#          preserving every existing caller's behavior unchanged
# + return - a stream of decoded StreamResponse values
isolated function readSseStream(http:Response resp, ProtocolMode mode = "V1_0")
        returns stream<StreamResponse, error?>|error {
    stream<http:SseEvent, error?> sseStream = check resp.getSseEventStream();
    A2AStreamGenerator generator = new (sseStream, mode);
    stream<StreamResponse, error?> result = new (generator);
    return result;
}

# Iterates a raw SSE event stream, decoding each event's JSON-RPC envelope
# into a StreamResponse. Stops once a terminal task status is reached; per
# design §8.1, a TaskArtifactUpdateEvent never closes the stream, and
# interrupted states (INPUT_REQUIRED, AUTH_REQUIRED) also do not close it.
class A2AStreamGenerator {
    private stream<http:SseEvent, error?> sseStream;
    private boolean closed = false;
    private ProtocolMode mode;

    isolated function init(stream<http:SseEvent, error?> sseStream, ProtocolMode mode = "V1_0") {
        self.sseStream = sseStream;
        self.mode = mode;
    }

    public isolated function next() returns record {| StreamResponse value; |}|error? {
        if self.closed {
            return ();
        }

        while true {
            record {| http:SseEvent value; |}|error? chunk = self.sseStream.next();

            if chunk is () {
                self.closed = true;
                return ();
            }
            if chunk is error {
                self.closed = true;
                return chunk;
            }

            string? data = chunk.value.data;
            if data is () {
                // Comment / keep-alive frame — no payload, pull the next one
                continue;
            }

            StreamResponse|error result = self.decodeEvent(data);
            if result is error {
                self.closed = true;
                return result;
            }

            if isTerminalEvent(result) {
                self.closed = true;
            }
            return {value: result};
        }
    }

    private isolated function decodeEvent(string data) returns StreamResponse|error {
        json envelope = check data.fromJsonString();
        transport:JsonRpcResponse rpcResp = check envelope.cloneWithType(transport:JsonRpcResponse);

        transport:JsonRpcError? rpcErr = rpcResp?.'error;
        if rpcErr is transport:JsonRpcError {
            return toA2AError(rpcErr);
        }

        json? result = rpcResp?.result;
        if result is () {
            return error InvalidAgentResponseError(
                "SSE event contained neither result nor error",
                message = "SSE event contained neither result nor error"
            );
        }
        return self.mode == "V0_3" ? decodeV03StreamEvent(result) : check result.cloneWithType(StreamResponse);
    }

    public isolated function close() returns error? {
        self.closed = true;
        return self.sseStream.close();
    }
}

# Wraps an existing StreamResponse stream, transparently reconnecting via
# subscribeToTask when the underlying stream ends with an error instead of
# a clean terminal-state close — up to a caller-configured attempt limit.
# Per specification section 3.1.6, a resubscription's first delivered event
# is always the task's current state, so no event is lost across a
# reconnect, only possibly duplicated (a status the client already saw
# delivered again) — callers already need to tolerate duplicate/out-of-order
# status updates per the spec's own guidance on this, so this is not a new
# burden.
class ReconnectingStreamGenerator {
    private stream<StreamResponse, error?> current;
    private final Client a2aClient;
    private final string taskId;
    private final int maxAttempts;
    private int attemptsUsed = 0;
    private boolean done = false;
    // Wiring the taskId to resubscribe to (in sendMessageStream) requires
    // peeking the underlying stream's first event before construction —
    // that peeked value is buffered here and replayed as this generator's
    // own first result, so the caller never observes that a peek happened.
    private record {| StreamResponse value; |}? bufferedFirst;

    isolated function init(stream<StreamResponse, error?> initial, Client a2aClient, string taskId, int maxAttempts, record {| StreamResponse value; |}? bufferedFirst = ()) {
        self.current = initial;
        self.a2aClient = a2aClient;
        self.taskId = taskId;
        self.maxAttempts = maxAttempts;
        self.bufferedFirst = bufferedFirst;
    }

    public isolated function next() returns record {| StreamResponse value; |}|error? {
        if self.done {
            return ();
        }
        record {| StreamResponse value; |}? buffered = self.bufferedFirst;
        if buffered is record {| StreamResponse value; |} {
            self.bufferedFirst = ();
            return buffered;
        }
        record {| StreamResponse value; |}|error? result = self.current.next();
        if result is error && self.attemptsUsed < self.maxAttempts {
            self.attemptsUsed += 1;
            // Deliberately calls the raw, unwrapped openTaskSubscriptionStream
            // helper rather than the public subscribeToTask remote function.
            // Going through subscribeToTask here would wrap each
            // resubscribed stream in a brand-new ReconnectingStreamGenerator
            // with its own fresh attemptsUsed/maxAttempts budget, silently
            // resetting the attempt count on every reconnect — against a
            // persistently-failing agent, reconnection would recurse without
            // bound instead of ever giving up. See
            // openTaskSubscriptionStream's doc comment for the full
            // rationale.
            stream<StreamResponse, error?>|error reconnected = self.a2aClient.openTaskSubscriptionStream(self.taskId);
            if reconnected is stream<StreamResponse, error?> {
                // Best-effort close of the errored/dropped stream before
                // swapping in the reconnected one; a failure here doesn't
                // change anything about the reconnect itself, so it's
                // deliberately not surfaced.
                error? closeResult = self.current.close();
                if closeResult is error {
                    // ignored
                }
                self.current = reconnected;
                return self.next();
            }
            // Intentional: if the resubscribe call itself fails (e.g. the
            // agent is unreachable), that failure is not surfaced —
            // `result` still holds the original drop error, which falls
            // through to be returned below. This attempt still counted
            // against attemptsUsed above, so a persistently-unreachable
            // agent still gives up after maxAttempts rather than retrying
            // forever; the caller just sees the original connection-drop
            // error rather than the (usually less informative) resubscribe
            // failure.
        }
        if result is () || result is error {
            self.done = true;
        }
        return result;
    }

    public isolated function close() returns error? {
        self.done = true;
        return self.current.close();
    }
}

# A stream terminates only on a status update carrying a terminal state.
#
# + event - the decoded stream event to inspect
# + return - true if this event should close the stream
isolated function isTerminalEvent(StreamResponse event) returns boolean {
    TaskStatusUpdateEvent? statusUpdate = event?.statusUpdate;
    if statusUpdate is () {
        return false;
    }
    TaskState state = statusUpdate.status.state;
    return state == TASK_STATE_COMPLETED
        || state == TASK_STATE_FAILED
        || state == TASK_STATE_CANCELED
        || state == TASK_STATE_REJECTED;
}
