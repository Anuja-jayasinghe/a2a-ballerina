// The gRPC transport binding.
//
// The most distinct of the three. There is no http:Client here at all —
// the generated grpcstub:A2AServiceClient is the transport — so headers
// travel as call metadata rather than HTTP headers, and the params map
// has to be marshalled into generated protobuf types on the way out and
// back into this module's own types on the way in (grpc_binding.bal).

import ballerina/grpc;
import ballerina/http;

import ballerina/a2a.grpcstub;

# An A2A client that speaks the gRPC binding.
#
# Construct this directly when the agent is known to serve gRPC, or when
# that binding is wanted regardless of what the Agent Card lists first. To
# let the card decide instead, use `Client`.
#
# ```ballerina
# a2a:GrpcClient agent = check new ("https://agent.example.com");
# a2a:Task|a2a:Message reply = check agent->sendMessage(msg);
# ```
#
# A2A v0.3 does define a gRPC binding, but this library does not implement
# it: `compat_v03.bal` is entirely a JSON-shape translator, none of which
# has meaning over protobuf, and `modules/grpcstub` is generated from v1.0's
# proto. A card resolving to v0.3 is therefore rejected at construction. Use
# `JsonRpcClient` for a v0.3 agent. See issue #31.
#
# Auth is configured through `clientConfig.auth` as with the other
# bindings; HTTP Basic and Bearer configurations are projected onto their
# structurally equivalent gRPC forms. Auth shapes with no gRPC equivalent
# (OAuth2, JWT) are rejected at construction rather than silently dropped.
public isolated client class GrpcClient {
    *AgentClient;

    private final grpcstub:A2AServiceClient grpcStub;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;
    # Always "V1_0" — construction rejects anything else, since v0.3 has
    # no gRPC equivalent.
    private final ProtocolMode mode;
    private final string[] & readonly requestedExtensions;
    private final int maxReconnectAttempts;
    # The most recent AgentCard this client knows about; replaced by the
    # extended card once getExtendedAgentCard fetches one.
    private AgentCard? agentCard;

    # Creates a gRPC client pointed at a remote A2A agent.
    #
    # Note the Agent Card itself is always fetched over HTTP from the
    # well-known endpoint — that is how discovery is defined — and only the
    # A2A operations travel over gRPC, against the URL the card's GRPC
    # interface declares.
    #
    # + agent - the agent's base URL, or an AgentCard already resolved via
    #           resolveAgentCard
    # + clientConfig - Full http:ClientConfiguration. Used for the card
    #                  fetch, and its auth is projected onto the gRPC
    #                  channel's configuration.
    # + headers - Default metadata merged into every outbound call
    # + tenant - Optional multi-tenant routing identifier; the card's GRPC
    #            interface supplies one automatically when it declares it,
    #            and an explicit value wins
    # + requestedExtensions - Optional A2A extension URIs to request
    # + maxReconnectAttempts - Opt-in automatic stream reconnection
    # + return - an error from resolveAgentCard, from URL derivation when
    #            the card declares no GRPC interface, if the card resolves
    #            to A2A v0.3, if clientConfig.auth has no gRPC equivalent,
    #            or if the gRPC channel cannot be created
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
        string serviceUrl = check primaryUrl(card, "GRPC");
        string? effectiveTenant = tenant;
        if effectiveTenant is () {
            AgentInterface|error iface = selectInterface(card, "GRPC");
            if iface is AgentInterface {
                effectiveTenant = iface?.tenant;
            }
        }
        ProtocolMode detected = detectProtocolModeForBinding(card, "GRPC");
        if detected == "V0_3" {
            return error VersionNotSupportedError(
                "this library does not implement A2A v0.3 over the gRPC binding; use JsonRpcClient for a v0.3 agent",
                message = "this library does not implement A2A v0.3 over the gRPC binding; use JsonRpcClient for a v0.3 agent"
            );
        }
        http:ClientConfiguration effectiveClientConfig = {...clientConfig};
        grpc:ClientConfiguration grpcConfig = check projectToGrpcClientConfig(effectiveClientConfig);
        self.grpcStub = check new (normalizeGrpcSchemeUrl(serviceUrl), grpcConfig);
        self.defaultHeaders = headers.clone().cloneReadOnly();
        self.tenant = effectiveTenant;
        self.mode = detected;
        self.requestedExtensions = requestedExtensions.cloneReadOnly();
        self.maxReconnectAttempts = maxReconnectAttempts;
        self.agentCard = card.clone();
    }

    # Builds the outbound call metadata. No Content-Type: gRPC sets its
    # own, and supplying one here would be meaningless at best.
    #
    # + return - the metadata to send with the call
    private isolated function buildHeaders() returns map<string> {
        map<string> headers = {"A2A-Version": "1.0"};
        foreach [string, string] [k, v] in self.defaultHeaders.entries() {
            headers[k] = v;
        }
        if self.requestedExtensions.length() > 0 {
            headers["A2A-Extensions"] = string:'join(",", ...self.requestedExtensions);
        }
        return headers;
    }

    # Performs one gRPC call and returns the unwrapped result.
    #
    # + method - the operation name
    # + params - the same params map every binding builds
    # + return - the unwrapped result json, or a typed A2AError
    private isolated function grpcCall(string method, map<json> params) returns json|error {
        anydata req = check encodeGrpcRequest(method, params);
        map<string|string[]> headers = self.buildHeaders();
        anydata|grpc:Error response = self.dispatchGrpcContextCall(method, req, headers);
        if response is grpc:Error {
            return toA2AErrorFromGrpc(response);
        }
        return decodeGrpcResponse(method, response);
    }

    # Dispatches to the correct generated *Context method for one unary
    # operation.
    #
    # The *Context variants are used exclusively, never the plain ones, so
    # that outbound call metadata (A2A-Version, auth, requested extensions)
    # is reachable at all. Every generated *Context remote function takes a
    # single parameter: a union of the plain request type or the
    # corresponding `grpcstub:Context{Operation}Request` wrapper record
    # (`{content, headers}`), not a separate trailing headers parameter.
    # Outbound metadata is therefore sent by constructing that wrapper
    # record here. Confirmed against the real generated
    # `a2a/modules/grpcstub/a2a_pb.bal`.
    #
    # + method - the operation name
    # + req - the typed grpcstub request value from encodeGrpcRequest
    # + headers - outbound metadata (A2A-Version, A2A-Extensions, auth)
    # + return - the typed grpcstub response value, or a grpc:Error
    private isolated function dispatchGrpcContextCall(
            string method, anydata req,
            map<string|string[]> headers) returns anydata|grpc:Error {
        grpcstub:A2AServiceClient stub = self.grpcStub;
        match method {
            "SendMessage" => {
                var result = stub->SendMessageContext({content: <grpcstub:SendMessageRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                return result.content;
            }
            "GetTask" => {
                var result = stub->GetTaskContext({content: <grpcstub:GetTaskRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                return result.content;
            }
            "CancelTask" => {
                var result = stub->CancelTaskContext({content: <grpcstub:CancelTaskRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                return result.content;
            }
            "ListTasks" => {
                var result = stub->ListTasksContext({content: <grpcstub:ListTasksRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                return result.content;
            }
            "CreateTaskPushNotificationConfig" => {
                var result = stub->CreateTaskPushNotificationConfigContext({content: <grpcstub:TaskPushNotificationConfig>req, headers});
                if result is grpc:Error {
                    return result;
                }
                return result.content;
            }
            "GetTaskPushNotificationConfig" => {
                var result = stub->GetTaskPushNotificationConfigContext({content: <grpcstub:GetTaskPushNotificationConfigRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                return result.content;
            }
            "ListTaskPushNotificationConfigs" => {
                var result = stub->ListTaskPushNotificationConfigsContext({content: <grpcstub:ListTaskPushNotificationConfigsRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                return result.content;
            }
            "DeleteTaskPushNotificationConfig" => {
                var result = stub->DeleteTaskPushNotificationConfigContext({content: <grpcstub:DeleteTaskPushNotificationConfigRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                // google.protobuf.Empty (empty:ContextNil) carries no
                // `content` field at all — decodeGrpcResponse's
                // "DeleteTaskPushNotificationConfig" branch ignores its
                // response argument entirely and always returns {}, so ()
                // here is discarded downstream, not silently wrong.
                return ();
            }
            "GetExtendedAgentCard" => {
                var result = stub->GetExtendedAgentCardContext({content: <grpcstub:GetExtendedAgentCardRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                return result.content;
            }
            _ => {
                return error grpc:InternalError(string `no gRPC dispatch for unary method "${method}"`);
            }
        }
    }

    # Opens a gRPC server-streaming call.
    #
    # + method - "SendStreamingMessage" or "SubscribeToTask"
    # + params - the same params map every binding builds
    # + return - a stream of StreamResponse values, or a typed A2AError
    private isolated function openGrpcStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        grpcstub:A2AServiceClient stub = self.grpcStub;
        anydata req = check encodeGrpcRequest(method, params);
        map<string|string[]> headers = self.buildHeaders();
        if method == "SendStreamingMessage" {
            grpcstub:ContextStreamResponseStream|grpc:Error result =
                stub->SendStreamingMessageContext({content: <grpcstub:SendMessageRequest>req, headers});
            if result is grpc:Error {
                return toA2AErrorFromGrpc(result);
            }
            stream<StreamResponse, error?> wrapped = new (new GrpcStreamAdapter(result.content));
            return wrapped;
        }
        grpcstub:ContextStreamResponseStream|grpc:Error result =
            stub->SubscribeToTaskContext({content: <grpcstub:SubscribeToTaskRequest>req, headers});
        if result is grpc:Error {
            return toA2AErrorFromGrpc(result);
        }
        stream<StreamResponse, error?> wrapped = new (new GrpcStreamAdapter(result.content));
        return wrapped;
    }

    # Opens the raw, unwrapped subscribeToTask stream. See
    # JsonRpcClient.openTaskSubscriptionStream for why reconnection must
    # resubscribe through this rather than the public remote function.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated function openTaskSubscriptionStream(string taskId, string? tenant = ()) returns stream<StreamResponse, error?>|error {
        map<json> params = buildSubscribeToTaskParams(taskId, tenant ?: self.tenant, self.mode);
        return self.openGrpcStream("SubscribeToTask", params);
    }

    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|error {
        map<json> params = check buildSendMessageParams(
                message, config, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("SendMessage", params);
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
        stream<StreamResponse, error?> rawStream = check self.openGrpcStream("SendStreamingMessage", params);
        return wrapReconnecting(rawStream, self, self.maxReconnectAttempts, effectiveTenant);
    }

    isolated remote function getTask(
            string taskId,
            int? historyLength = (),
            string? tenant = ()) returns Task|error {
        map<json> params = buildGetTaskParams(taskId, historyLength, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("GetTask", params);
        return decodeTaskResult(result, self.mode);
    }

    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|error {
        map<json> params = buildCancelTaskParams(taskId, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("CancelTask", params);
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
        json result = check self.grpcCall("ListTasks", params);
        return decodeListTasksResult(result);
    }

    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = check buildCreateTaskPushNotificationConfigParams(
                config, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("CreateTaskPushNotificationConfig", params);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("GetTaskPushNotificationConfig", params);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error {
        map<json> params = buildListTaskPushNotificationConfigsParams(
                taskId, pageSize, pageToken, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("ListTaskPushNotificationConfigs", params);
        return decodeListTaskPushNotificationConfigsResult(result, self.mode);
    }

    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns error? {
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json _ = check self.grpcCall("DeleteTaskPushNotificationConfig", params);
    }

    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error {
        lock {
            AgentCard? held = self.agentCard;
            if held is AgentCard && !held.capabilities.extendedAgentCard {
                return held.clone();
            }
        }
        map<json> params = buildGetExtendedAgentCardParams(tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("GetExtendedAgentCard", params);
        AgentCard fetched = check parseAgentCardBody(result);
        lock {
            self.agentCard = fetched.clone();
        }
        return fetched;
    }
}
