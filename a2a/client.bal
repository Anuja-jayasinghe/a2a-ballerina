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
# + card - the agent card to read the endpoint from
# + return - supportedInterfaces[0].url if present, the legacy url field
#            if that's unset but url is, or an error if neither is present
public isolated function primaryUrl(AgentCard card) returns string|error {
    if card.supportedInterfaces.length() > 0 {
        return card.supportedInterfaces[0].url;
    }
    string? legacyUrl = card?.url;
    if legacyUrl is string {
        return legacyUrl;
    }
    return error("AgentCard has neither supportedInterfaces nor a legacy url field");
}

# An A2A protocol client for calling remote agents.
public isolated client class Client {
    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;

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
    # + return - error if the underlying http:Client cannot be created
    public isolated function init(
            string serviceUrl,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = ()) returns error? {
        self.httpClient = check new (serviceUrl, clientConfig);
        self.defaultHeaders = headers.cloneReadOnly();
        self.tenant = tenant;
    }

    # Builds the header map for an outbound request. The A2A-Version header
    # is mandatory on every request per specification section 3.6.1; an
    # agent receiving an empty value assumes protocol version 0.3, which
    # would silently downgrade the interaction.
    #
    # + return - the headers to send with the request
    private isolated function buildHeaders() returns map<string> {
        map<string> headers = {
            "Content-Type": "application/json",
            "A2A-Version": "1.0"
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
        transport:JsonRpcRequest req = {
            id: uuid:createType4AsString(),
            method: method,
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
    # + return - A Task or a Message on success, or an error on failure
    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = ()) returns Task|Message|error {
        map<json> params = {"message": message.toJson()};
        if config is SendMessageConfiguration {
            params["configuration"] = config.toJson();
        }
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("SendMessage", params);

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
        transport:JsonRpcRequest req = {
            id: uuid:createType4AsString(),
            method: method,
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
        return readSseStream(resp);
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
    # + return - A stream of StreamResponse values, or an error
    isolated remote function sendMessageStream(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = ()) returns stream<StreamResponse, error?>|error {
        map<json> params = {"message": message.toJson()};
        if config is SendMessageConfiguration {
            params["configuration"] = config.toJson();
        }
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string {
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
        if effectiveTenant is string {
            params["tenant"] = effectiveTenant;
        }
        json result = check self.rpcCall("GetTask", params);
        return check result.cloneWithType(Task);
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
        if effectiveTenant is string {
            params["tenant"] = effectiveTenant;
        }
        json result = check self.rpcCall("CancelTask", params);
        return check result.cloneWithType(Task);
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
        if effectiveTenant is string {
            params["tenant"] = effectiveTenant;
        }
        return self.openSseStream("SubscribeToTask", params);
    }
}
