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
# + binding - which transport binding's wire shape to decode events as;
#             defaults to JSONRPC, preserving every existing caller's
#             behavior unchanged
# + return - a stream of decoded StreamResponse values
isolated function readSseStream(http:Response resp, ProtocolMode mode = "V1_0", TransportBinding binding = "JSONRPC")
        returns stream<StreamResponse, error?>|error {
    stream<http:SseEvent, error?> sseStream = check resp.getSseEventStream();
    A2AStreamGenerator generator = new (sseStream, mode, binding);
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
    private TransportBinding binding;

    isolated function init(stream<http:SseEvent, error?> sseStream, ProtocolMode mode = "V1_0", TransportBinding binding = "JSONRPC") {
        self.sseStream = sseStream;
        self.mode = mode;
        self.binding = binding;
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

            // REST binding signals a mid-stream error via a named "error"
            // SSE frame, whose data is a REST error payload — not a
            // StreamResponse at all. The JSON-RPC binding has no
            // equivalent (its errors travel inside the envelope), so this
            // check is REST-only.
            if self.binding == "HTTP+JSON" && chunk.value.'event == "error" {
                json|error errBody = data.fromJsonString();
                self.closed = true;
                return toA2AErrorFromRest(200, errBody is json ? errBody : ());
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
        if self.binding == "HTTP+JSON" {
            // REST events carry a bare StreamResponse with no JSON-RPC
            // envelope, unlike the JSON-RPC binding's enveloped events.
            json restEnvelope = check data.fromJsonString();
            return check (check decodeRawBytesFromWire(restEnvelope)).cloneWithType(StreamResponse);
        }
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
        return self.mode == "V0_3" ? decodeV03StreamEvent(result) : check (check decodeRawBytesFromWire(result)).cloneWithType(StreamResponse);
    }

    public isolated function close() returns error? {
        self.closed = true;
        return self.sseStream.close();
    }
}

# Wraps a unary sendMessage reply as a one-event StreamResponse stream, for
# sendStreamingMessage's capability-gated fallback per issue #11: when the
# held AgentCard says streaming is unsupported, the call degrades to a
# single unary request instead of opening (and having the server reject) an
# SSE connection. sendMessage already blocks until the task reaches a
# terminal state (or returns a Message with no task at all), so the lone
# event this yields is already the finished result - nothing further would
# ever arrive on a real stream either.
#
# + result - the unary sendMessage reply to wrap
# + return - a stream yielding exactly that one event, then closing
isolated function singleEventStream(Task|Message result) returns stream<StreamResponse, error?> {
    // Task and Message are both open records (explicit `json...;` rest
    // field, per repo convention), so the compiler can't prove `is Task`
    // narrows `result` in the corresponding else branch - hence the
    // explicit casts rather than relying on flow-sensitive narrowing.
    StreamResponse response;
    if result is Task {
        response = {task: <Task>result};
    } else {
        response = {message: <Message>result};
    }
    return new (new SingleEventStreamGenerator(response));
}

# Yields one pre-built StreamResponse, then ends the stream cleanly. See
# singleEventStream.
class SingleEventStreamGenerator {
    private record {| StreamResponse value; |}? pending;

    isolated function init(StreamResponse value) {
        self.pending = {value};
    }

    public isolated function next() returns record {| StreamResponse value; |}|error? {
        record {| StreamResponse value; |}? p = self.pending;
        self.pending = ();
        return p;
    }

    public isolated function close() returns error? {
        self.pending = ();
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
# The single capability ReconnectingStreamGenerator needs from the client
# that owns it: reopening a task subscription, raw, without wrapping the
# result in another reconnect layer.
#
# Declared as an object type rather than naming a concrete class so that
# every transport-specific client can hand itself to the generator. The
# generator has no interest in which binding it is reconnecting over.
type StreamReconnectable isolated object {
    isolated function openTaskSubscriptionStream(string taskId, string? tenant) returns stream<StreamResponse, error?>|error;
};

class ReconnectingStreamGenerator {
    private stream<StreamResponse, error?> current;
    private final StreamReconnectable a2aClient;
    private final string taskId;
    // The per-call tenant override (if any) from the originating
    // sendStreamingMessage/subscribeToTask call. Must be threaded through to
    // the reconnect's openTaskSubscriptionStream call below — otherwise a
    // reconnect silently falls back to the client-level default tenant
    // (or no tenant), resubscribing under the wrong tenant in a
    // multi-tenant deployment.
    private final string? tenant;
    private final int maxAttempts;
    private int attemptsUsed = 0;
    private boolean done = false;
    // Wiring the taskId to resubscribe to (in sendStreamingMessage) requires
    // peeking the underlying stream's first event before construction —
    // that peeked value is buffered here and replayed as this generator's
    // own first result, so the caller never observes that a peek happened.
    private record {| StreamResponse value; |}? bufferedFirst;

    isolated function init(stream<StreamResponse, error?> initial, StreamReconnectable a2aClient, string taskId, int maxAttempts, record {| StreamResponse value; |}? bufferedFirst = (), string? tenant = ()) {
        self.current = initial;
        self.a2aClient = a2aClient;
        self.taskId = taskId;
        self.maxAttempts = maxAttempts;
        self.bufferedFirst = bufferedFirst;
        self.tenant = tenant;
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
            stream<StreamResponse, error?>|error reconnected = self.a2aClient.openTaskSubscriptionStream(self.taskId, self.tenant);
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

# Wraps a freshly-opened stream so a dropped connection resubscribes
# automatically, when the owning client was configured for it.
#
# Finding the taskId to resubscribe against requires peeking the stream's
# first event, so that peeked value is buffered into the generator and
# replayed as its own first result - the caller never observes that a peek
# happened. A stream that opens with a bare Message carries nothing to
# reconnect against, so it is still wrapped, but with a zero attempt budget
# rather than being handed back raw; that keeps the peeked value spliced
# back on either way.
#
# Shared by every transport binding: reconnection is a client-side policy
# over a stream of StreamResponse values and has nothing to say about how
# those values arrived.
#
# + rawStream - the stream just opened by the transport
# + owner - the client to resubscribe through on a drop
# + maxReconnectAttempts - the caller's configured attempt budget; zero or
#                          less returns rawStream untouched
# + tenant - the originating call's per-call tenant override, which must be
#            threaded through so a reconnect resubscribes under the same
#            tenant rather than falling back to the client-level default
# + return - the stream to hand the caller, or an error if the first event
#            was itself an error
isolated function wrapReconnecting(
        stream<StreamResponse, error?> rawStream,
        StreamReconnectable owner,
        int maxReconnectAttempts,
        string? tenant) returns stream<StreamResponse, error?>|error {
    if maxReconnectAttempts <= 0 {
        return rawStream;
    }
    record {| StreamResponse value; |}|error? peeked = rawStream.next();
    if peeked is error {
        return peeked;
    }
    if peeked is () {
        stream<StreamResponse, error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, owner, "", 0, tenant = tenant));
        return wrapped;
    }
    Task? maybeTask = peeked.value?.task;
    if maybeTask is Task {
        stream<StreamResponse, error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, owner, maybeTask.id, maxReconnectAttempts, peeked, tenant));
        return wrapped;
    }
    // A stream can also legitimately open with a status update rather than
    // a Task (e.g. resubscribing to an already-created task), and that
    // update still carries a taskId worth reconnecting against.
    string? maybeTaskId = peeked.value?.statusUpdate?.taskId;
    if maybeTaskId is string {
        stream<StreamResponse, error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, owner, maybeTaskId, maxReconnectAttempts, peeked, tenant));
        return wrapped;
    }
    stream<StreamResponse, error?> wrapped =
        new (new ReconnectingStreamGenerator(rawStream, owner, "", 0, peeked, tenant));
    return wrapped;
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
