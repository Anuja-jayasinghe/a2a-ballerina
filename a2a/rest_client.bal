// The REST (HTTP+JSON) transport binding.
//
// Same shape as JsonRpcClient: one binding, no branch. What differs is the
// marshaling — an operation becomes an HTTP method, a templated path, and
// optionally a body (REST_OPERATIONS/buildRestRequest in client.bal),
// rather than a JSON-RPC envelope posted to a single endpoint.

import ballerina/http;

# An A2A client that speaks the REST (HTTP+JSON) binding.
#
# Construct this directly when the agent is known to serve HTTP+JSON, or
# when that binding is wanted regardless of what the Agent Card lists
# first. To let the card decide instead, use `Client`.
#
# ```ballerina
# a2a:RestClient agent = check new ("https://agent.example.com");
# a2a:Task|a2a:Message reply = check agent->sendMessage(msg);
# ```
#
# A2A v0.3 does define a REST binding, but this library does not implement
# it: `compat_v03.bal` is a JSON-RPC dialect translator (v0.3 method names
# like `tasks/get` have no meaning as a REST path), and the operation-to-path
# table here is v1.0's. A card resolving to v0.3 is therefore rejected at
# construction rather than at the first call. Use `JsonRpcClient` for a v0.3
# agent. See issue #31.
public isolated client class RestClient {
    *AgentClient;

    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;
    # Always "V1_0" — construction rejects anything else, since v0.3 has
    # no REST equivalent. Kept as a field rather than assumed, so the
    # shared operation helpers are called with what was actually detected.
    private final ProtocolMode mode;
    private final string[] & readonly requestedExtensions;
    private string[] grantedExtensions = [];
    private final int maxReconnectAttempts;
    # The most recent AgentCard this client knows about; replaced by the
    # extended card once getExtendedAgentCard fetches one.
    private AgentCard? agentCard;

    # Creates a REST client pointed at a remote A2A agent.
    #
    # + agent - the agent's base URL, or an AgentCard already resolved via
    #           resolveAgentCard
    # + clientConfig - Full http:ClientConfiguration. Also used for the
    #                  card fetch when agent is a URL.
    # + headers - Default headers merged into every outbound request
    # + tenant - Optional multi-tenant routing identifier; the card's
    #            HTTP+JSON interface supplies one automatically when it
    #            declares it, and an explicit value wins
    # + requestedExtensions - Optional A2A extension URIs to request
    # + maxReconnectAttempts - Opt-in automatic SSE reconnection
    # + return - an error from resolveAgentCard, from URL derivation when
    #            the card declares no HTTP+JSON interface, if the card
    #            resolves to A2A v0.3, or if the http:Client cannot be
    #            created
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
        string serviceUrl = check primaryUrl(card, "HTTP+JSON");
        string? effectiveTenant = tenant;
        if effectiveTenant is () {
            AgentInterface|error iface = selectInterface(card, "HTTP+JSON");
            if iface is AgentInterface {
                effectiveTenant = iface?.tenant;
            }
        }
        ProtocolMode detected = detectProtocolModeForBinding(card, "HTTP+JSON");
        if detected == "V0_3" {
            return error VersionNotSupportedError(
                "this library does not implement A2A v0.3 over the REST/HTTP+JSON binding; use JsonRpcClient for a v0.3 agent",
                message = "this library does not implement A2A v0.3 over the REST/HTTP+JSON binding; use JsonRpcClient for a v0.3 agent"
            );
        }
        http:ClientConfiguration effectiveClientConfig = {...clientConfig};
        self.httpClient = check new (serviceUrl, effectiveClientConfig);
        self.defaultHeaders = headers.clone().cloneReadOnly();
        self.tenant = effectiveTenant;
        self.mode = detected;
        self.requestedExtensions = requestedExtensions.cloneReadOnly();
        self.maxReconnectAttempts = maxReconnectAttempts;
        self.agentCard = card.clone();
    }

    # + return - the headers to send with the request
    private isolated function buildHeaders() returns map<string> {
        map<string> headers = {
            "A2A-Version": "1.0",
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

    public isolated function lastGrantedExtensions() returns string[] {
        lock {
            return self.grantedExtensions.clone();
        }
    }

    # Captures the response's A2A-Extensions header, if present. Per spec
    # section 14.2.2 both directions use the same header name; the legacy
    # `X-` spelling is read only as a fallback for non-conformant servers.
    #
    # + resp - the response just received from the remote agent
    private isolated function captureGrantedExtensions(http:Response resp) {
        string|error extHeader = resp.getHeader("A2A-Extensions");
        if extHeader is error {
            extHeader = resp.getHeader("X-A2A-Extensions");
        }
        if extHeader is string {
            string[] granted = [];
            if extHeader.length() > 0 {
                foreach string entry in re `,`.split(extHeader) {
                    granted.push(entry.trim());
                }
            }
            lock {
                self.grantedExtensions = granted.clone();
            }
        }
    }

    # Performs one REST call and returns the unwrapped result.
    #
    # DeleteTaskPushNotificationConfig returns google.protobuf.Empty over
    # the wire, so an absent or unparseable body on a 2xx is an empty
    # success rather than a malformed response. An operation that expects
    # real content fails its own cloneWithType instead, which is the right
    # place for that failure to surface.
    #
    # + method - the operation name (see REST_OPERATIONS)
    # + params - the same params map every binding builds
    # + return - the unwrapped result json, or a typed A2AError
    private isolated function restCall(string method, map<json> params) returns json|error {
        [string, json?] [path, body] = check buildRestRequest(method, params);
        RestOperation op = REST_OPERATIONS.get(method);
        map<string> headers = self.buildHeaders();
        http:Response resp;
        if op.httpMethod == "GET" {
            resp = check self.httpClient->get(path, headers);
        } else if op.httpMethod == "DELETE" {
            resp = check self.httpClient->delete(path, headers = headers);
        } else {
            resp = check self.httpClient->post(path, body ?: {}, headers);
        }
        self.captureGrantedExtensions(resp);
        if resp.statusCode >= 200 && resp.statusCode < 300 {
            json|error payload = resp.getJsonPayload();
            if payload is json {
                return payload;
            }
            return {};
        }
        json? errorBody = resp.getJsonPayload() is json ? check resp.getJsonPayload() : ();
        return toA2AErrorFromRest(resp.statusCode, errorBody);
    }

    # Opens a REST SSE stream for a streaming operation.
    #
    # + method - "SendStreamingMessage" or "SubscribeToTask"
    # + params - the same params map every binding builds
    # + return - a stream of StreamResponse values, or a typed A2AError
    private isolated function openRestSseStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        [string, json?] [path, body] = check buildRestRequest(method, params);
        RestOperation op = REST_OPERATIONS.get(method);
        map<string> headers = self.buildHeaders();
        headers["Accept"] = "text/event-stream";
        http:Response resp;
        if op.httpMethod == "GET" {
            resp = check self.httpClient->get(path, headers);
            // SubscribeToTask's proto annotation says GET, but a
            // non-reference server that hand-rolled its REST routes
            // following the reference *client* (which sends POST) might
            // only have registered POST. Scoped to exactly this one
            // operation — retrying broadly for every operation would
            // mask genuine method-not-allowed errors elsewhere.
            if method == "SubscribeToTask" && (resp.statusCode == 404 || resp.statusCode == 405 || resp.statusCode == 501) {
                resp = check self.httpClient->post(path, body ?: {}, headers);
            }
        } else {
            resp = check self.httpClient->post(path, body ?: {}, headers);
        }
        self.captureGrantedExtensions(resp);
        if !resp.getContentType().startsWith("text/event-stream") {
            json|error errBody = resp.getJsonPayload();
            return toA2AErrorFromRest(resp.statusCode, errBody is json ? errBody : ());
        }
        return readSseStream(resp, self.mode, "HTTP+JSON");
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
        return self.openRestSseStream("SubscribeToTask", params);
    }

    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|error {
        map<json> params = check buildSendMessageParams(
                message, config, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("SendMessage", params);
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
        stream<StreamResponse, error?> rawStream = check self.openRestSseStream("SendStreamingMessage", params);
        return wrapReconnecting(rawStream, self, self.maxReconnectAttempts, effectiveTenant);
    }

    isolated remote function getTask(
            string taskId,
            int? historyLength = (),
            string? tenant = ()) returns Task|error {
        map<json> params = buildGetTaskParams(taskId, historyLength, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("GetTask", params);
        return decodeTaskResult(result, self.mode);
    }

    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|error {
        map<json> params = buildCancelTaskParams(taskId, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("CancelTask", params);
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
        json result = check self.restCall("ListTasks", params);
        return decodeListTasksResult(result);
    }

    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = check buildCreateTaskPushNotificationConfigParams(
                config, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("CreateTaskPushNotificationConfig", params);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("GetTaskPushNotificationConfig", params);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error {
        map<json> params = buildListTaskPushNotificationConfigsParams(
                taskId, pageSize, pageToken, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("ListTaskPushNotificationConfigs", params);
        return decodeListTaskPushNotificationConfigsResult(result, self.mode);
    }

    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns error? {
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json _ = check self.restCall("DeleteTaskPushNotificationConfig", params);
    }

    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error {
        lock {
            AgentCard? held = self.agentCard;
            if held is AgentCard && !held.capabilities.extendedAgentCard {
                return held.clone();
            }
        }
        map<json> params = buildGetExtendedAgentCardParams(tenant ?: self.tenant, self.mode);
        json result = check self.restCall("GetExtendedAgentCard", params);
        AgentCard fetched = check parseAgentCardBody(result);
        lock {
            self.agentCard = fetched.clone();
        }
        return fetched;
    }
}
