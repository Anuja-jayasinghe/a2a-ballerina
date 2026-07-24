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
# + return - a stream of decoded StreamResponse values
isolated function readSseStream(http:Response resp)
        returns stream<StreamResponse, error?>|error {
    stream<http:SseEvent, error?> sseStream = check resp.getSseEventStream();
    A2AStreamGenerator generator = new (sseStream);
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

    isolated function init(stream<http:SseEvent, error?> sseStream) {
        self.sseStream = sseStream;
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
        return check result.cloneWithType(StreamResponse);
    }

    public isolated function close() returns error? {
        self.closed = true;
        return self.sseStream.close();
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
