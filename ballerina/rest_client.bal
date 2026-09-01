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

// The REST (HTTP+JSON) transport binding.
//
// Same shape as JsonRpcClient: one binding, no branch. What differs is the
// marshaling — an operation becomes an HTTP method, a templated path, and
// optionally a body (REST_OPERATIONS/buildRestRequest, below), rather
// than a JSON-RPC envelope posted to a single endpoint.

import ballerina/http;
import ballerina/url;

# How one operation maps onto the REST binding.
type RestOperation record {|
    # HTTP verb to send, e.g. "GET" or "POST"
    string httpMethod;
    # Path template with "{param}" placeholders, e.g. "/tasks/{id}"
    string pathTemplate;
    # Names of the pathTemplate placeholders to substitute from params
    string[] pathParams;
    # Whether this operation sends params as a JSON body (true) or a query
    # string (false)
    boolean hasBody;
    # Whether this operation opens an SSE stream rather than returning a
    # single JSON response
    boolean streaming;
|};

final readonly & map<RestOperation> REST_OPERATIONS = {
    "SendMessage": {httpMethod: "POST", pathTemplate: "/message:send", pathParams: [], hasBody: true, streaming: false},
    "SendStreamingMessage": {httpMethod: "POST", pathTemplate: "/message:stream", pathParams: [], hasBody: true, streaming: true},
    "GetTask": {httpMethod: "GET", pathTemplate: "/tasks/{id}", pathParams: ["id"], hasBody: false, streaming: false},
    "ListTasks": {httpMethod: "GET", pathTemplate: "/tasks", pathParams: [], hasBody: false, streaming: false},
    "CancelTask": {httpMethod: "POST", pathTemplate: "/tasks/{id}:cancel", pathParams: ["id"], hasBody: true, streaming: false},
    "SubscribeToTask": {httpMethod: "GET", pathTemplate: "/tasks/{id}:subscribe", pathParams: ["id"], hasBody: false, streaming: true},
    "CreateTaskPushNotificationConfig": {httpMethod: "POST", pathTemplate: "/tasks/{taskId}/pushNotificationConfigs", pathParams: ["taskId"], hasBody: true, streaming: false},
    "GetTaskPushNotificationConfig": {httpMethod: "GET", pathTemplate: "/tasks/{taskId}/pushNotificationConfigs/{id}", pathParams: ["taskId", "id"], hasBody: false, streaming: false},
    "ListTaskPushNotificationConfigs": {httpMethod: "GET", pathTemplate: "/tasks/{taskId}/pushNotificationConfigs", pathParams: ["taskId"], hasBody: false, streaming: false},
    "GetExtendedAgentCard": {httpMethod: "GET", pathTemplate: "/extendedAgentCard", pathParams: [], hasBody: false, streaming: false},
    "DeleteTaskPushNotificationConfig": {httpMethod: "DELETE", pathTemplate: "/tasks/{taskId}/pushNotificationConfigs/{id}", pathParams: ["taskId", "id"], hasBody: false, streaming: false}
};

# Builds the path (with tenant prefix and path-param substitution) and
# body for one REST request, per the descriptor table above.
#
# Path params and tenant are substituted from `params`. Per the design
# spec's M3/M4 findings (matching the reference a2a-python SDK exactly,
# not "cleaning up" the duplication): for hasBody operations, tenant and
# path params stay in the body as well as the path; for bodiless
# operations, they are removed from the working param set so they don't
# leak into the query string. Bodiless operations serialize every
# remaining param as a URL-encoded query parameter; TaskState enum values
# serialize as their symbolic name (already what a bare enum value is in
# Ballerina — no conversion needed), and any value containing characters
# needing escaping (e.g. an RFC 3339 timestamp's `:`/`+`) goes through
# url:encode.
#
# + method - the JSON-RPC-style method name already used to key
#            REST_OPERATIONS (e.g. "GetTask") — the same string every
#            remote function already passes to rpcCall/openEventStream
# + params - the same params map the JSON-RPC binding would have sent
# + return - the full request path (including query string for bodiless
#            operations) and the JSON body to send (nil for bodiless
#            operations), or an error if method has no REST mapping
isolated function buildRestRequest(string method, map<json> params) returns [string, json?]|error {
    RestOperation? maybeOp = REST_OPERATIONS[method];
    if maybeOp is () {
        return error A2AInternalError(string `REST binding has no operation mapping for "${method}"`);
    }
    RestOperation op = maybeOp;
    map<json> workingParams = params.clone();

    string? tenant = ();
    json? tenantJson = workingParams["tenant"];
    if tenantJson is string {
        tenant = tenantJson;
        if !op.hasBody {
            _ = workingParams.remove("tenant");
        }
    }

    string path = op.pathTemplate;
    foreach string pName in op.pathParams {
        json? pValue = workingParams[pName];
        if pValue !is string {
            return error A2AInternalError(string `REST binding for "${method}" requires path parameter "${pName}", but it was missing or not a string`);
        }
        // Plain string substitution, not regex: pathTemplate never
        // contains a literal "{"/"}" outside of exactly these
        // placeholder markers, so there's no need for regex escaping
        // here. lang.string has no plain literal-replace function
        // (only regex-based replaceAll/replaceFirst), so the
        // placeholder is substituted manually via indexOf/substring.
        // The substituted value itself is percent-encoded so a value
        // containing "/", "?", "#", or "%" can't restructure the path
        // (e.g. break out into the query string, or shape a
        // path-traversal-looking segment) — only the literal template
        // text (e.g. ":cancel"/":subscribe") is left unencoded.
        string encodedValue = check url:encode(pValue, "UTF-8");
        string placeholder = string `{${pName}}`;
        int? idx = path.indexOf(placeholder);
        if idx is int {
            path = path.substring(0, idx) + encodedValue + path.substring(idx + placeholder.length());
        }
        if !op.hasBody {
            _ = workingParams.remove(pName);
        }
    }

    if tenant is string {
        string encodedTenant = check url:encode(tenant, "UTF-8");
        path = string `/${encodedTenant}${path}`;
    }

    if op.hasBody {
        return [path, workingParams];
    }

    string[] queryParts = [];
    foreach [string, json] [k, v] in workingParams.entries() {
        string stringValue = v is string ? v : v.toString();
        string encoded = check url:encode(stringValue, "UTF-8");
        queryParts.push(string `${k}=${encoded}`);
    }
    if queryParts.length() > 0 {
        path = path + "?" + string:'join("&", ...queryParts);
    }
    return [path, ()];
}

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
#
# See `ClientMethods`'s doc comment for this type's error contract: the
# A2AError subtype named on each method below is what a protocol-level
# failure produces, not the only kind of error that can come back.
public isolated client class RestClient {
    *ClientMethods;

    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;
    # Always "V1_0" — construction rejects anything else, since v0.3 has
    # no REST equivalent. Kept as a field rather than assumed, so the
    # shared operation helpers are called with what was actually detected.
    private final ProtocolMode mode;
    private final string[] & readonly requestedExtensions;
    private final int maxReconnectAttempts;
    # The most recent AgentCard this client knows about; replaced by the
    # extended card once getExtendedAgentCard fetches one.
    private AgentCard? agentCard;
    # Learned, not configured: flips to true the first time a server
    # rejects the spec-mandated application/a2a+json with a 415, so every
    # later call on this instance skips straight to the legacy
    # application/json instead of paying a 415 round trip each time. See
    # buildHeaders and performRestCallWithNegotiation.
    private boolean useLegacyContentType = false;

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
        // The A2A spec's REST/HTTP+JSON binding requires the
        // application/a2a+json media type, not plain application/json
        // (spec §11) -- verified against the real, current spec text --
        // and that's what this client sends by default. Some real,
        // currently-released servers haven't caught up yet: the reference
        // Java server (a2a-java-sdk-reference-rest:1.1.0.Final) rejects
        // application/a2a+json outright with a 415 (confirmed by
        // decompiling its route registration, which hardcodes
        // .consumes("application/json")). performRestCallWithNegotiation
        // retries once with application/json on a real 415 and flips
        // useLegacyContentType so every later call goes straight there --
        // this only reads that already-learned choice.
        boolean legacy;
        lock {
            legacy = self.useLegacyContentType;
        }
        map<string> headers = {
            "A2A-Version": "1.0",
            "Content-Type": legacy ? "application/json" : "application/a2a+json"
        };
        foreach [string, string] [k, v] in self.defaultHeaders.entries() {
            headers[k] = v;
        }
        if self.requestedExtensions.length() > 0 {
            headers["A2A-Extensions"] = string:'join(",", ...self.requestedExtensions);
        }
        return headers;
    }

    # Issues one raw HTTP call for a REST operation, with no content-type
    # negotiation -- callers that need negotiation go through
    # performRestCallWithNegotiation instead.
    #
    # + op - the operation descriptor (method/path already resolved)
    # + path - the request path built by buildRestRequest
    # + body - the request body, or () for a bodiless operation
    # + headers - the exact headers to send
    # + return - the raw HTTP response, or a transport-level error
    private isolated function rawRestCall(RestOperation op, string path, json? body, map<string> headers) returns http:Response|error {
        if op.httpMethod == "GET" {
            return self.httpClient->get(path, headers);
        } else if op.httpMethod == "DELETE" {
            return self.httpClient->delete(path, headers = headers);
        } else {
            return self.httpClient->post(path, body ?: {}, headers);
        }
    }

    # Issues one REST call, transparently retrying once with the legacy
    # application/json content type if the server rejects the spec-mandated
    # application/a2a+json with a 415 -- see buildHeaders' doc comment.
    #
    # + op - the operation descriptor (method/path already resolved)
    # + path - the request path built by buildRestRequest
    # + body - the request body, or () for a bodiless operation
    # + extraHeaders - additional headers merged in on top of buildHeaders'
    #                  defaults (e.g. Accept: text/event-stream)
    # + return - the raw HTTP response (from whichever attempt settled),
    #            or a transport-level error
    private isolated function performRestCallWithNegotiation(
            RestOperation op, string path, json? body, map<string> extraHeaders = {}) returns http:Response|error {
        map<string> headers = self.buildHeaders();
        foreach [string, string] [k, v] in extraHeaders.entries() {
            headers[k] = v;
        }
        http:Response resp = check self.rawRestCall(op, path, body, headers);
        if resp.statusCode == 415 && headers["Content-Type"] != "application/json" {
            map<string> legacyHeaders = headers.clone();
            legacyHeaders["Content-Type"] = "application/json";
            http:Response retryResp = check self.rawRestCall(op, path, body, legacyHeaders);
            if retryResp.statusCode != 415 {
                lock {
                    self.useLegacyContentType = true;
                }
            }
            return retryResp;
        }
        return resp;
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
    # + return - the unwrapped result json; a typed A2AError for a
    #            non-2xx response (via toA2AErrorFromRest) or a param this
    #            binding can't build a request for (via buildRestRequest);
    #            or the underlying http/mime/encode error, unwrapped, for a
    #            connection failure or an unencodable param value
    private isolated function restCall(string method, map<json> params) returns json|error {
        [string, json?] [path, body] = check buildRestRequest(method, params);
        RestOperation op = REST_OPERATIONS.get(method);
        http:Response resp = check self.performRestCallWithNegotiation(op, path, body);
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
    # + return - a stream of StreamResponse values; a typed A2AError for a
    #            non-streaming error response (via toA2AErrorFromRest); or
    #            the underlying http/mime/encode error, unwrapped, for a
    #            connection failure
    private isolated function openRestSseStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        [string, json?] [path, body] = check buildRestRequest(method, params);
        RestOperation op = REST_OPERATIONS.get(method);
        map<string> extraHeaders = {"Accept": "text/event-stream"};
        http:Response resp = check self.performRestCallWithNegotiation(op, path, body, extraHeaders);
        // SubscribeToTask's proto annotation says GET, but a non-reference
        // server that hand-rolled its REST routes following the reference
        // *client* (which sends POST) might only have registered POST.
        // Scoped to exactly this one operation — retrying broadly for
        // every operation would mask genuine method-not-allowed errors
        // elsewhere.
        if method == "SubscribeToTask" && op.httpMethod == "GET"
                && (resp.statusCode == 404 || resp.statusCode == 405 || resp.statusCode == 501) {
            RestOperation postOp = {
                httpMethod: "POST",
                pathTemplate: op.pathTemplate,
                pathParams: op.pathParams,
                hasBody: op.hasBody,
                streaming: op.streaming
            };
            resp = check self.performRestCallWithNegotiation(postOp, path, body, extraHeaders);
        }
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
            map<json>? metadata) returns Task|Message|error {
        map<json> params = check buildSendMessageParams(
                message, config, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("SendMessage", params);
        return decodeSendMessageResult(result, self.mode);
    }

    # Sends a message to the remote agent over REST (HTTP+JSON).
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
            map<json>? metadata = ()) returns Task|Message|error {
        return self.sendMessageUnary(message, config, tenant, metadata);
    }

    # Sends a message and receives updates as they happen, over REST SSE.
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
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|error {
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
        stream<StreamResponse, error?> rawStream = check self.openRestSseStream("SendStreamingMessage", params);
        return wrapReconnecting(rawStream, self, self.maxReconnectAttempts, effectiveTenant);
    }

    # Retrieves the current state of a task.
    #
    # + taskId - The task identifier returned by a previous sendMessage
    # + historyLength - Maximum messages to include in task.history
    # + tenant - Optional per-call tenant override
    # + return - The current Task, or a TaskNotFoundError (or other typed
    #            A2AError) if unknown
    isolated remote function getTask(string taskId, int? historyLength = (), string? tenant = ()) returns Task|error {
        map<json> params = buildGetTaskParams(taskId, historyLength, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("GetTask", params);
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
            string? tenant = ()) returns Task|error {
        map<json> params = buildCancelTaskParams(taskId, metadata, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("CancelTask", params);
        return decodeTaskResult(result, self.mode);
    }

    # Opens a stream on an existing task over REST SSE.
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
            string? tenant = ()) returns stream<StreamResponse, error?>|error {
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
            string? tenant = ()) returns ListTasksResult|error {
        check guardListTasksSupported(self.mode);
        map<json> params = buildListTasksParams(filter, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("ListTasks", params);
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
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("createTaskPushNotificationConfig");
        }
        map<json> params = check buildCreateTaskPushNotificationConfigParams(
                config, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("CreateTaskPushNotificationConfig", params);
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
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("getTaskPushNotificationConfig");
        }
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("GetTaskPushNotificationConfig", params);
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
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("listTaskPushNotificationConfigs");
        }
        map<json> params = buildListTaskPushNotificationConfigsParams(
                taskId, pageSize, pageToken, tenant ?: self.tenant, self.mode);
        json result = check self.restCall("ListTaskPushNotificationConfigs", params);
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
            string? tenant = ()) returns error? {
        map<json> params = buildPushNotificationConfigRefParams(
                taskId, id, tenant ?: self.tenant, self.mode);
        json _ = check self.restCall("DeleteTaskPushNotificationConfig", params);
    }

    # Retrieves the agent's extended AgentCard.
    #
    # + tenant - Optional per-call tenant override
    # + return - The extended AgentCard, the already-held card when that
    #            card declares no extended-card support, or a typed A2AError
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
