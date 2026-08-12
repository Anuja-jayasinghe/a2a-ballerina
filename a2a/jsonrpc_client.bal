// The JSON-RPC 2.0 transport binding.
//
// This class speaks exactly one binding, so it carries no `binding` field
// and there is no per-call branch anywhere in it — which transport it uses
// is settled by which type you instantiated. The eleven operations are
// three lines each: build the params (operations.bal, shared with every
// other binding), send them, decode the reply.

import ballerina/http;
import ballerina/uuid;

import ballerina/a2a.transport;

# An A2A client that speaks the JSON-RPC 2.0 binding.
#
# Construct this directly when the agent is known to serve JSON-RPC, or
# when JSON-RPC is wanted regardless of what the Agent Card lists first.
# To let the card decide instead, use `Client`.
#
# ```ballerina
# a2a:JsonRpcClient agent = check new ("https://agent.example.com");
# a2a:Task|a2a:Message reply = check agent->sendMessage(msg);
# ```
#
# This binding serves both wire dialects: an Agent Card resolving to A2A
# v0.3 is translated transparently, the same as before the client types
# were split. It is the only one that does — v0.3 defines all three
# bindings, but `compat_v03.bal` translates the JSON-RPC dialect alone, so
# `RestClient` and `GrpcClient` reject a v0.3 card. See issue #31.
public isolated client class JsonRpcClient {
    *AgentClient;

    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;
    private final ProtocolMode mode;
    private final string[] & readonly requestedExtensions;
    private final int maxReconnectAttempts;
    # The most recent AgentCard this client knows about: the one resolved
    # during construction, replaced by the extended card once
    # getExtendedAgentCard fetches one. Mutable (hence lock-guarded)
    # precisely so that fetching an extended card updates what later calls
    # reason about.
    private AgentCard? agentCard;

    # Creates a JSON-RPC client pointed at a remote A2A agent.
    #
    # Accepts either the agent's base URL or an already-resolved AgentCard.
    # Given a URL, the card is always resolved first: it determines the
    # service URL, the protocol version, and the tenant.
    #
    # + agent - the agent's base URL, or an AgentCard already resolved via
    #           resolveAgentCard
    # + clientConfig - Full http:ClientConfiguration. Covers auth, TLS,
    #                  retry, circuit breaker, proxy, timeouts, and
    #                  connection pooling. Also used for the card fetch
    #                  when agent is a URL.
    # + headers - Default headers merged into every outbound request
    # + tenant - Optional multi-tenant routing identifier. When the card's
    #            JSONRPC interface declares a tenant it is used
    #            automatically; an explicitly-passed tenant wins.
    # + requestedExtensions - Optional A2A extension URIs to request, sent
    #                         as a comma-joined A2A-Extensions header
    # + maxReconnectAttempts - Opt-in automatic SSE reconnection; 0 (the
    #                          default) surfaces a dropped stream's error
    #                          immediately
    # + return - an error from resolveAgentCard, from URL derivation when
    #            the card declares no JSONRPC interface and no legacy url,
    #            or if the underlying http:Client cannot be created
    public isolated function init(
            AgentCard|string agent,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            string[] requestedExtensions = [],
            int maxReconnectAttempts = 0) returns error? {
        AgentCard card = agent is string
            ? check resolveAgentCard(agent, clientConfig, headers)
            : agent;
        string serviceUrl = check primaryUrl(card, "JSONRPC");
        string? effectiveTenant = tenant;
        if effectiveTenant is () {
            AgentInterface|error iface = selectInterface(card, "JSONRPC");
            if iface is AgentInterface {
                effectiveTenant = iface?.tenant;
            }
        }
        // http:ClientConfiguration isn't Cloneable (some of its fields
        // aren't pure data), so a mapping-constructor spread is used
        // instead of .clone() to shallow-copy it — otherwise this could
        // mutate the caller's own clientConfig in place.
        http:ClientConfiguration effectiveClientConfig = {...clientConfig};
        self.httpClient = check new (serviceUrl, effectiveClientConfig);
        self.defaultHeaders = headers.clone().cloneReadOnly();
        self.tenant = effectiveTenant;
        self.mode = detectProtocolModeForBinding(card, "JSONRPC");
        self.requestedExtensions = requestedExtensions.cloneReadOnly();
        self.maxReconnectAttempts = maxReconnectAttempts;
        self.agentCard = card.clone();
    }

    # Builds the header map for an outbound request. The A2A-Version header
    # is mandatory on every request per specification section 3.6.1; an
    # agent receiving an empty value assumes protocol version 0.3, which
    # would silently downgrade the interaction.
    #
    # + return - the headers to send with the request
    private isolated function buildHeaders() returns map<string> {
        map<string> headers = {
            "A2A-Version": self.mode == "V0_3" ? "0.3" : "1.0",
            "Content-Type": "application/json"
        };
        foreach [string, string] [k, v] in self.defaultHeaders.entries() {
            headers[k] = v;
        }
        if self.requestedExtensions.length() > 0 {
            headers["A2A-Extensions"] = string:'join(",", ...self.requestedExtensions);
        }
        return headers;
    }

    # Performs a unary JSON-RPC call and returns the unwrapped result.
    #
    # + method - the v1.0 method name; translated for v0.3 when needed
    # + params - the method parameters
    # + return - the unwrapped result, or a typed A2AError
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

    # Opens a JSON-RPC streaming call and hands the response to
    # readSseStream. Shared by sendStreamingMessage and subscribeToTask.
    #
    # + method - the method name
    # + params - the method parameters
    # + return - a stream of StreamResponse values, or an error
    private isolated function openEventStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
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

        return readSseStream(resp, self.mode, "JSONRPC");
    }

    # Opens the raw, unwrapped subscribeToTask stream — the same request
    # subscribeToTask sends, but without any reconnect wrapping.
    #
    # ReconnectingStreamGenerator must resubscribe through this rather than
    # through the public subscribeToTask: going through the remote function
    # would build a brand-new generator with its own fresh
    # attemptsUsed/maxAttempts budget on every reconnect, silently resetting
    # the count and defeating maxReconnectAttempts entirely — against a
    # persistently-failing agent, reconnection would recurse without bound
    # instead of ever giving up.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated function openTaskSubscriptionStream(string taskId, string? tenant = ()) returns stream<StreamResponse, error?>|error {
        map<json> params = buildSubscribeToTaskParams(taskId, tenant ?: self.tenant, self.mode);
        return self.openEventStream("SubscribeToTask", params);
    }

    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|error {
        map<json> params = check buildSendMessageParams(
                message, config, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.rpcCall("SendMessage", params);
        return decodeSendMessageResult(result, self.mode);
    }

    isolated remote function sendStreamingMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|error {
        string? effectiveTenant = tenant ?: self.tenant;
        map<json> params = check buildSendMessageParams(
                message, config, metadata, effectiveTenant, self.mode);
        stream<StreamResponse, error?> rawStream = check self.openEventStream("SendStreamingMessage", params);
        return wrapReconnecting(rawStream, self, self.maxReconnectAttempts, effectiveTenant);
    }

    isolated remote function getTask(
            string taskId,
            int? historyLength = (),
            string? tenant = ()) returns Task|error {
        map<json> params = buildGetTaskParams(taskId, historyLength, tenant ?: self.tenant, self.mode);
        json result = check self.rpcCall("GetTask", params);
        return decodeTaskResult(result, self.mode);
    }

    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|error {
        map<json> params = buildCancelTaskParams(taskId, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.rpcCall("CancelTask", params);
        return decodeTaskResult(result, self.mode);
    }

    isolated remote function subscribeToTask(
            string taskId,
            string? tenant = ()) returns stream<StreamResponse, error?>|error {
        stream<StreamResponse, error?> rawStream = check self.openTaskSubscriptionStream(taskId, tenant);
        if self.maxReconnectAttempts <= 0 {
            return rawStream;
        }
        stream<StreamResponse, error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, self, taskId, self.maxReconnectAttempts, tenant = tenant));
        return wrapped;
    }

    isolated remote function listTasks(
            ListTasksFilter? filter = (),
            string? tenant = ()) returns ListTasksResult|error {
        check guardListTasksSupported(self.mode);
        map<json> params = buildListTasksParams(filter, tenant ?: self.tenant, self.mode);
        json result = check self.rpcCall("ListTasks", params);
        return decodeListTasksResult(result);
    }

    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = check buildCreateTaskPushNotificationConfigParams(
                config, tenant ?: self.tenant, self.mode);
        json result = check self.rpcCall("CreateTaskPushNotificationConfig", params);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json result = check self.rpcCall("GetTaskPushNotificationConfig", params);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error {
        map<json> params = buildListTaskPushNotificationConfigsParams(
                taskId, pageSize, pageToken, tenant ?: self.tenant, self.mode);
        json result = check self.rpcCall("ListTaskPushNotificationConfigs", params);
        return decodeListTaskPushNotificationConfigsResult(result, self.mode);
    }

    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns error? {
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json _ = check self.rpcCall("DeleteTaskPushNotificationConfig", params);
    }

    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error {
        lock {
            AgentCard? held = self.agentCard;
            if held is AgentCard && !held.capabilities.extendedAgentCard {
                return held.clone();
            }
        }
        map<json> params = buildGetExtendedAgentCardParams(tenant ?: self.tenant, self.mode);
        json result = check self.rpcCall("GetExtendedAgentCard", params);
        AgentCard fetched = check parseAgentCardBody(result);
        lock {
            self.agentCard = fetched.clone();
        }
        return fetched;
    }
}
