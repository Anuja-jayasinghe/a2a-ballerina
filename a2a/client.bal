// A2A client implementation.

import ballerina/a2a.transport;
import ballerina/http;
import ballerina/uuid;

# Fetches and parses a remote agent's Agent Card from its well-known
# endpoint.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers, for API key authentication
# + return - The parsed AgentCard, or an error if the fetch or parse fails
public isolated function resolveAgentCard(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns AgentCard|error {
    http:Client discoveryClient = check new (agentBaseUrl, clientConfig);
    map<string> reqHeaders = {"A2A-Version": "1.0"};
    foreach [string, string] [k, v] in headers.entries() {
        reqHeaders[k] = v;
    }
    http:Response resp = check discoveryClient->get(
        "/.well-known/agent-card.json", reqHeaders
    );
    if resp.statusCode != 200 {
        return error A2AInternalError(
            string `Agent Card fetch failed with HTTP ${resp.statusCode}`,
            code = resp.statusCode
        );
    }
    json body = check resp.getJsonPayload();
    return check body.cloneWithType(AgentCard);
}

# Resolves the URL to construct a Client against, per v1.0's removal of
# AgentCard.url as a required field.
#
# This Client only ever speaks the JSON-RPC binding on the wire, so among
# supportedInterfaces it looks specifically for a "JSONRPC" entry rather
# than blindly taking index 0 — a card listing e.g. a GRPC interface first
# would otherwise resolve to an endpoint this Client can't actually talk
# to, then fail non-obviously on the first request instead of here.
#
# + card - the agent card to read the endpoint from
# + return - the first supportedInterfaces entry declaring the "JSONRPC"
#            protocolBinding, the legacy url field if no such entry
#            exists, or an error if neither is present
public isolated function primaryUrl(AgentCard card) returns string|error {
    foreach AgentInterface iface in card.supportedInterfaces {
        if iface.protocolBinding == "JSONRPC" {
            return iface.url;
        }
    }
    string? legacyUrl = card?.url;
    if legacyUrl is string {
        return legacyUrl;
    }
    return error("AgentCard has no JSONRPC entry in supportedInterfaces and no legacy url field");
}

# An A2A protocol client for calling remote agents.
public isolated client class Client {
    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;
    private final ProtocolMode mode;

    # Creates a client pointed at a remote A2A agent.
    #
    # + serviceUrl - Base URL of the remote agent's A2A endpoint
    # + clientConfig - Full http:ClientConfiguration. Covers auth, TLS,
    #                  retry, circuit breaker, proxy, timeouts, and
    #                  connection pooling.
    # + headers - Default headers merged into every outbound request. Use
    #             for API key schemes requiring a custom header name.
    #             Bearer and OAuth2 auth belong in clientConfig.auth.
    # + tenant - Optional multi-tenant routing identifier. When the selected
    #            AgentInterface in the Agent Card declares a tenant value,
    #            that value must be supplied here so it is sent with every
    #            operation. Leave unset for single-tenant agents.
    # + agentCard - The card previously fetched via resolveAgentCard, if
    #               any. When given, its declared protocol version is used
    #               to auto-detect whether to speak v1.0 or v0.3 wire
    #               format to this server. Omitting it (the default)
    #               preserves today's v1.0-only behavior exactly.
    # + return - error if the underlying http:Client cannot be created
    public isolated function init(
            string serviceUrl,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            AgentCard? agentCard = ()) returns error? {
        self.httpClient = check new (serviceUrl, clientConfig);
        self.defaultHeaders = headers.cloneReadOnly();
        self.tenant = tenant;
        self.mode = agentCard is AgentCard ? detectProtocolMode(agentCard) : "V1_0";
    }

    # Builds the header map for an outbound request. The A2A-Version header
    # is mandatory on every request per specification section 3.6.1; an
    # agent receiving an empty value assumes protocol version 0.3, which
    # would silently downgrade the interaction. Sends "0.3" instead of
    # "1.0" when this Client was constructed for a v0.3 server, per the
    # spec's per-interface header-negotiation guidance.
    #
    # + return - the headers to send with the request
    private isolated function buildHeaders() returns map<string> {
        map<string> headers = {
            "Content-Type": "application/json",
            "A2A-Version": self.mode == "V0_3" ? "0.3" : "1.0"
        };
        foreach [string, string] [k, v] in self.defaultHeaders.entries() {
            headers[k] = v;
        }
        return headers;
    }

    # Performs a unary JSON-RPC call and returns the unwrapped result.
    #
    # + method - the JSON-RPC method name
    # + params - the JSON-RPC method parameters
    # + return - the unwrapped result, or an error
    private isolated function rpcCall(string method, map<json> params) returns json|error {
        string wireMethod = self.mode == "V0_3" ? v03MethodName(method) : method;
        transport:JsonRpcRequest req = {
            id: uuid:createType4AsString(),
            method: wireMethod,
            params: params
        };
        http:Response resp = check self.httpClient->post(
            "", req.toJson(), self.buildHeaders()
        );
        json body = check resp.getJsonPayload();
        transport:JsonRpcResponse rpcResp =
            check body.cloneWithType(transport:JsonRpcResponse);
        transport:JsonRpcError? rpcErr = rpcResp?.'error;
        if rpcErr is transport:JsonRpcError {
            return toA2AError(rpcErr);
        }
        json? result = rpcResp?.result;
        if result is () {
            return error InvalidAgentResponseError(
                "JSON-RPC response contained neither result nor error"
            );
        }
        return result;
    }

    # Sends a message to the remote agent.
    #
    # Blocking by default: the call does not return until the task reaches
    # a terminal or interrupted state. Set config.returnImmediately to true
    # for non-blocking behaviour, then poll with getTask or subscribe with
    # subscribeToTask.
    #
    # The agent may respond with a Task for tracked work, or with a Message
    # for a simple direct reply that needs no task lifecycle. Both are
    # valid per specification section 3.1.1, so the return type covers
    # both.
    #
    # + message - The message to send; messageId must be set by the caller
    # + config - Optional send configuration
    # + tenant - Optional per-call tenant override
    # + metadata - Optional request-level metadata, per SendMessageRequest
    #              (specification section 3.2.1) — distinct from
    #              message.metadata, which is metadata on the Message itself
    # + return - A Task or a Message on success, or an error on failure
    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|error {
        json messageJson = self.mode == "V0_3" ? check encodeV03Message(message) : message.toJson();
        map<json> params = {"message": messageJson};
        if config is SendMessageConfiguration {
            params["configuration"] = self.mode == "V0_3" ? encodeV03SendConfiguration(config) : config.toJson();
        }
        if metadata is map<json> {
            params["metadata"] = metadata;
        }
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("SendMessage", params);

        if self.mode == "V0_3" {
            return check decodeV03SendResult(result);
        }

        // The wire response wraps the payload — {"task": {...}} or
        // {"message": {...}} — rather than returning either one flat.
        SendMessageResult wrapped = check result.cloneWithType(SendMessageResult);
        Task? maybeTask = wrapped?.task;
        Message? maybeMessage = wrapped?.message;

        // A conforming server can't produce this — task/message form a real
        // protobuf oneof upstream, which makes both being set structurally
        // impossible in a well-formed response. But SendMessageResult is a
        // plain open record on our side, not an actual oneof, so nothing
        // stops a non-conforming server from sending both. Rather than
        // silently preferring one, treat it as the malformed response it is.
        if maybeTask is Task && maybeMessage is Message {
            return error InvalidAgentResponseError(
                "Response contained both a task and a message"
            );
        }
        if maybeTask is Task {
            return maybeTask;
        }
        if maybeMessage is Message {
            return maybeMessage;
        }
        return error InvalidAgentResponseError(
            "Response contained neither a task nor a message"
        );
    }

    # Opens a JSON-RPC streaming call and hands the response to
    # readSseStream. Shared by sendMessageStream and subscribeToTask.
    #
    # + method - the JSON-RPC method name
    # + params - the JSON-RPC method parameters
    # + return - a stream of StreamResponse values, or an error
    private isolated function openSseStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        string wireMethod = self.mode == "V0_3" ? v03MethodName(method) : method;
        transport:JsonRpcRequest req = {
            id: uuid:createType4AsString(),
            method: wireMethod,
            params: params
        };
        map<string> headers = self.buildHeaders();
        headers["Accept"] = "text/event-stream";
        http:Response resp = check self.httpClient->post(
            "", req.toJson(), headers
        );
        if resp.statusCode != 200 {
            return error A2AInternalError(
                string `Stream request failed with HTTP ${resp.statusCode}`,
                code = resp.statusCode
            );
        }

        // A rejected streaming request (e.g. subscribing to a task already
        // in a terminal state) can come back as a plain JSON-RPC error with
        // HTTP 200, not an SSE-framed stream — resp.getSseEventStream()
        // rejects that Content-Type with a raw, untyped error rather than
        // surfacing the actual JSON-RPC error underneath. Detect that case
        // first and route it through the same error mapping as a unary call.
        if !resp.getContentType().startsWith("text/event-stream") {
            json body = check resp.getJsonPayload();
            transport:JsonRpcResponse rpcResp =
                check body.cloneWithType(transport:JsonRpcResponse);
            transport:JsonRpcError? rpcErr = rpcResp?.'error;
            if rpcErr is transport:JsonRpcError {
                return toA2AError(rpcErr);
            }
            return error InvalidAgentResponseError(
                "Stream request returned a non-streaming response with neither a JSON-RPC error nor an SSE stream"
            );
        }

        return readSseStream(resp, self.mode);
    }

    # Sends a message and receives updates in real time over SSE.
    #
    # Requires the remote agent to declare capabilities.streaming as true;
    # otherwise the agent returns UnsupportedOperationError.
    #
    # The stream opens with a Task or a Message, then delivers zero or more
    # TaskStatusUpdateEvent and TaskArtifactUpdateEvent values, and closes
    # when the task reaches a terminal state. Each StreamResponse carries
    # exactly one non-nil field.
    #
    # + message - The message to send
    # + config - Optional send configuration
    # + tenant - Optional per-call tenant override
    # + metadata - Optional request-level metadata, per SendMessageRequest
    #              (specification section 3.2.1) — distinct from
    #              message.metadata, which is metadata on the Message itself
    # + return - A stream of StreamResponse values, or an error
    isolated remote function sendMessageStream(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|error {
        json messageJson = self.mode == "V0_3" ? check encodeV03Message(message) : message.toJson();
        map<json> params = {"message": messageJson};
        if config is SendMessageConfiguration {
            params["configuration"] = self.mode == "V0_3" ? encodeV03SendConfiguration(config) : config.toJson();
        }
        if metadata is map<json> {
            params["metadata"] = metadata;
        }
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }
        return self.openSseStream("SendStreamingMessage", params);
    }

    # Retrieves the current state of a task.
    #
    # Used for polling after a non-blocking send, for fetching final state
    # after a push notification, or for inspecting a task after a stream
    # has ended.
    #
    # + taskId - The task identifier returned by a previous sendMessage
    # + historyLength - Maximum messages to include in task.history. Unset
    #                   means no limit; zero requests that history be
    #                   omitted.
    # + tenant - Optional per-call tenant override
    # + return - The current Task, or an error if unknown
    isolated remote function getTask(
            string taskId,
            int? historyLength = (),
            string? tenant = ()) returns Task|error {
        map<json> params = {"id": taskId};
        if historyLength is int {
            params["historyLength"] = historyLength;
        }
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }
        json result = check self.rpcCall("GetTask", params);
        return self.mode == "V0_3" ? check parseV03Task(result) : check result.cloneWithType(Task);
    }

    # Requests cancellation of an in-progress task.
    #
    # Cancellation is best effort. If the task has already reached a
    # terminal state the agent returns TaskNotCancelableError.
    #
    # + taskId - The task to cancel
    # + metadata - Optional additional context passed to the agent
    # + tenant - Optional per-call tenant override
    # + return - The updated Task, or an error
    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|error {
        map<json> params = {"id": taskId};
        if metadata is map<json> {
            params["metadata"] = metadata;
        }
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }
        json result = check self.rpcCall("CancelTask", params);
        return self.mode == "V0_3" ? check parseV03Task(result) : check result.cloneWithType(Task);
    }

    # Opens a stream on an existing task.
    #
    # The primary use is recovering from a dropped sendMessageStream
    # connection. Per specification section 3.1.6 the first event
    # delivered is always the task's current state, which prevents
    # information loss between calling getTask and re-subscribing.
    #
    # Requires capabilities.streaming to be true. Returns
    # UnsupportedOperationError if attempted on a task already in a
    # terminal state.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated remote function subscribeToTask(
            string taskId,
            string? tenant = ()) returns stream<StreamResponse, error?>|error {
        map<json> params = {"id": taskId};
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }
        return self.openSseStream("SubscribeToTask", params);
    }
}
