// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

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
#
# See `ClientMethods`'s doc comment for this type's error contract: the
# A2AError subtype named on each method below is what a protocol-level
# failure produces, not the only kind of error that can come back.
public isolated client class GrpcClient {
    *ClientMethods;

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
    # + return - a typed A2AError: from resolveAgentCard, from URL
    #            derivation when the card declares no GRPC interface, a
    #            VersionNotSupportedError if the card resolves to A2A
    #            v0.3, or an A2AInternalError if the gRPC channel cannot
    #            be created
    public isolated function init(
            AgentCard|string agent,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            string[] requestedExtensions = [],
            int maxReconnectAttempts = 0) returns A2AError? {
        AgentCard card = agent is string
            ? check resolveAgentCard(agent, clientConfig, headers)
            : agent;
        string serviceUrl = check primaryUrl(card, GRPC);
        string? effectiveTenant = tenant;
        if effectiveTenant is () {
            AgentInterface|error iface = selectInterface(card, GRPC);
            if iface is AgentInterface {
                effectiveTenant = iface?.tenant;
            }
        }
        ProtocolMode detected = detectProtocolModeForBinding(card, GRPC);
        if detected == "V0_3" {
            return error VersionNotSupportedError(
                "this library does not implement A2A v0.3 over the gRPC binding; use JsonRpcClient for a v0.3 agent",
                message = "this library does not implement A2A v0.3 over the gRPC binding; use JsonRpcClient for a v0.3 agent"
            );
        }
        // http:ClientConfiguration isn't Cloneable (some of its fields
        // aren't pure data), so a mapping-constructor spread is used
        // instead of .clone() to shallow-copy it — otherwise this could
        // mutate the caller's own clientConfig in place.
        http:ClientConfiguration effectiveClientConfig = {...clientConfig};
        grpc:ClientConfiguration grpcConfig = projectToGrpcClientConfig(effectiveClientConfig);
        grpcstub:A2AServiceClient|error newGrpcStub = new (normalizeGrpcSchemeUrl(serviceUrl), grpcConfig);
        if newGrpcStub is error {
            return wrapTransportError(newGrpcStub);
        }
        self.grpcStub = newGrpcStub;
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
    # Declared and constructed as `map<string|string[]>`, not `map<string>`,
    # even though every value put in here is a plain string: a Ballerina
    # map's *inherent* type is fixed at construction and is enforced at
    # runtime independent of whatever wider static type a caller later
    # references it through. ballerina/grpc's own
    # ClientOAuth2Handler.enrich (auth_client_oauth2_handler.bal) inserts
    # the bearer token as a `string[]` (`headers[AUTH_HEADER] = [token]`)
    # when OAuth2 auth is configured - confirmed empirically: constructing
    # this map as `map<string>` throws `InherentTypeViolation` ("expected
    # value of type 'string', found 'string[]'") the first time an
    # OAuth2-authenticated call reaches that handler, even though every
    # call site here already declares its own local as
    # `map<string|string[]>`. Widening the inherent type here, at the one
    # place this map is built, fixes every caller at once.
    #
    # + return - the metadata to send with the call
    private isolated function buildHeaders() returns map<string|string[]> {
        map<string|string[]> headers = {"A2A-Version": "1.0"};
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
    # + return - the unwrapped result json; a typed A2AError for a gRPC
    #            status the call returned (via toA2AErrorFromGrpc), a
    #            response this binding can't decode (via
    #            decodeGrpcResponse/InvalidAgentResponseError), or a
    #            params shape encodeGrpcRequest can't marshal (wrapped as
    #            A2AInternalError)
    private isolated function grpcCall(string method, map<json> params) returns json|A2AError {
        anydata|error rawReq = encodeGrpcRequest(method, params);
        if rawReq is error {
            return wrapTransportError(rawReq);
        }
        anydata req = rawReq;
        map<string|string[]> headers = self.buildHeaders();
        anydata|grpc:Error response = self.dispatchGrpcContextCall(method, req, headers);
        if response is grpc:Error {
            return toA2AErrorFromGrpc(response);
        }
        json|error decoded = decodeGrpcResponse(method, response);
        if decoded is error {
            return wrapTransportError(decoded);
        }
        return decoded;
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
    # + return - a stream of StreamResponse values; a typed A2AError for a
    #            gRPC status the call returned (via toA2AErrorFromGrpc); or
    #            the underlying clone/decode error, unwrapped, for a params
    #            shape encodeGrpcRequest can't marshal
    private isolated function openGrpcStream(string method, map<json> params) returns stream<StreamResponse, error?>|A2AError {
        grpcstub:A2AServiceClient stub = self.grpcStub;
        anydata|error rawReq = encodeGrpcRequest(method, params);
        if rawReq is error {
            return wrapTransportError(rawReq);
        }
        anydata req = rawReq;
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
    isolated function openTaskSubscriptionStream(string taskId, string? tenant = ()) returns stream<StreamResponse, error?>|A2AError {
        map<json> params = buildSubscribeToTaskParams(taskId, tenant ?: self.tenant, self.mode);
        return self.openGrpcStream("SubscribeToTask", params);
    }

    # The unary sendMessage body, factored out so sendStreamingMessage's
    # capability-gated fallback (issue #11) can call it without going
    # through a remote method on self.
    #
    # + message - the message to send
    # + config - optional send configuration
    # + tenant - optional per-call tenant override
    # + metadata - optional additional context
    # + return - the finished Task or a plain Message reply
    private isolated function sendMessageUnary(
            Message message,
            SendMessageConfiguration? config,
            string? tenant,
            map<json>? metadata) returns Task|Message|A2AError {
        map<json> params = check buildSendMessageParams(
                message, config, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("SendMessage", params);
        return decodeSendMessageResult(result, self.mode);
    }

    # Sends a message to the remote agent over gRPC.
    #
    # + message - The message to send; messageId must be set by the caller
    # + config - Optional send configuration
    # + tenant - Optional per-call tenant override
    # + metadata - Optional request-level metadata, per SendMessageRequest
    #              (specification section 3.2.1) — distinct from
    #              message.metadata, which is metadata on the Message itself
    # + return - A Task or a Message on success, or a typed A2AError on failure
    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|A2AError {
        return self.sendMessageUnary(message, config, tenant, metadata);
    }

    # Sends a message and receives updates as they happen, over a gRPC
    # server-streaming call.
    #
    # Falls back to a single unary sendMessage call, wrapped as a one-event
    # stream, when the held AgentCard says streaming is unsupported — see
    # issue #11 — instead of opening (and having the server reject) a
    # streaming connection.
    #
    # + message - The message to send
    # + config - Optional send configuration
    # + tenant - Optional per-call tenant override
    # + metadata - Optional request-level metadata
    # + return - A stream of StreamResponse values, or a typed A2AError
    isolated remote function sendStreamingMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|A2AError {
        boolean denied;
        lock {
            denied = cardDeniesStreaming(self.agentCard);
        }
        if denied {
            // Falls back to a single unary call instead of opening (and
            // having the server reject) a streaming connection - see
            // singleEventStream and issue #11.
            Task|Message result = check self.sendMessageUnary(message, config, tenant, metadata);
            return singleEventStream(result);
        }
        string? effectiveTenant = tenant ?: self.tenant;
        map<json> params = check buildSendMessageParams(
                message, config, metadata, effectiveTenant, self.mode);
        stream<StreamResponse, error?> rawStream = check self.openGrpcStream("SendStreamingMessage", params);
        return wrapReconnecting(rawStream, self, self.maxReconnectAttempts, effectiveTenant);
    }

    # Retrieves the current state of a task.
    #
    # + taskId - The task identifier returned by a previous sendMessage
    # + historyLength - Maximum messages to include in task.history
    # + tenant - Optional per-call tenant override
    # + return - The current Task, or a TaskNotFoundError (or other typed
    #            A2AError) if unknown
    isolated remote function getTask(string taskId, int? historyLength = (), string? tenant = ()) returns Task|A2AError {
        map<json> params = buildGetTaskParams(taskId, historyLength, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("GetTask", params);
        return decodeTaskResult(result, self.mode);
    }

    # Requests cancellation of an in-progress task.
    #
    # + taskId - The task to cancel
    # + metadata - Optional additional context passed to the agent
    # + tenant - Optional per-call tenant override
    # + return - The updated Task, or a TaskNotFoundError/TaskNotCancelableError
    #            (or other typed A2AError)
    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|A2AError {
        map<json> params = buildCancelTaskParams(taskId, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("CancelTask", params);
        return decodeTaskResult(result, self.mode);
    }

    # Opens a stream on an existing task over a gRPC server-streaming call.
    #
    # Unlike sendStreamingMessage, subscribing to a task already in flight
    # has no unary equivalent to fall back to when the held AgentCard says
    # streaming is unsupported — see issue #11 — so that case is rejected
    # client-side with an UnsupportedOperationError instead.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or a typed A2AError
    isolated remote function subscribeToTask(
            string taskId,
            string? tenant = ()) returns stream<StreamResponse, error?>|A2AError {
        boolean denied;
        lock {
            denied = cardDeniesStreaming(self.agentCard);
        }
        if denied {
            // Unlike sendStreamingMessage, subscribing to a task already
            // in flight has no unary equivalent to fall back to - see
            // issue #11.
            return streamingUnsupportedError("subscribeToTask");
        }
        stream<StreamResponse, error?> rawStream = check self.openTaskSubscriptionStream(taskId, tenant);
        if self.maxReconnectAttempts <= 0 {
            return rawStream;
        }
        stream<StreamResponse, error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, self, taskId, self.maxReconnectAttempts, tenant = tenant));
        return wrapped;
    }

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + filter - Optional filter/pagination parameters
    # + tenant - Optional per-call tenant override
    # + return - A page of matching tasks, or a VersionNotSupportedError if
    #            the agent speaks A2A v0.3 (ListTasks has no v0.3 equivalent),
    #            or another typed A2AError
    isolated remote function listTasks(
            ListTasksFilter? filter = (),
            string? tenant = ()) returns ListTasksResult|A2AError {
        check guardListTasksSupported(self.mode);
        map<json> params = buildListTasksParams(filter, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("ListTasks", params);
        return decodeListTasksResult(result);
    }

    # Registers a webhook to receive updates for a task.
    #
    # + config - The webhook configuration; config.taskId identifies the task
    # + tenant - Optional per-call tenant override
    # + return - The created config as the server persisted it, or a
    #            PushNotificationNotSupportedError (or other typed A2AError)
    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|A2AError {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("createTaskPushNotificationConfig");
        }
        map<json> params = check buildCreateTaskPushNotificationConfigParams(
                config, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("CreateTaskPushNotificationConfig", params);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    # Retrieves a previously registered push-notification webhook config.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier, from its creation response
    # + tenant - Optional per-call tenant override
    # + return - The config, or a PushNotificationNotSupportedError/
    #            TaskNotFoundError (or other typed A2AError)
    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|A2AError {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("getTaskPushNotificationConfig");
        }
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("GetTaskPushNotificationConfig", params);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    # Lists all push-notification webhook configs registered for a task.
    #
    # + taskId - The task to list configs for
    # + pageSize - Maximum results per page
    # + pageToken - Opaque cursor from a previous result's nextPageToken
    # + tenant - Optional per-call tenant override
    # + return - A page of matching configs, or a
    #            PushNotificationNotSupportedError (or other typed A2AError)
    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|A2AError {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("listTaskPushNotificationConfigs");
        }
        map<json> params = buildListTaskPushNotificationConfigsParams(
                taskId, pageSize, pageToken, tenant ?: self.tenant, self.mode);
        json result = check self.grpcCall("ListTaskPushNotificationConfigs", params);
        return decodeListTaskPushNotificationConfigsResult(result, self.mode);
    }

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10.
    #
    # deleteTaskPushNotificationConfig is deliberately NOT gated on
    # capabilities.pushNotifications - deletion is idempotent per
    # specification section 3.1.10, so a card that (perhaps stale-ly)
    # denies the capability shouldn't block a call that's a legitimate
    # no-op either way. See issue #11.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier
    # + tenant - Optional per-call tenant override
    # + return - nil on success, or a typed A2AError
    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns A2AError? {
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json _ = check self.grpcCall("DeleteTaskPushNotificationConfig", params);
    }

    # Retrieves the agent's extended AgentCard.
    #
    # + tenant - Optional per-call tenant override
    # + return - The extended AgentCard, the already-held card when that
    #            card declares no extended-card support, or a typed A2AError
    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|A2AError {
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
