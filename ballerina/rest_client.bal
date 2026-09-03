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
// marshaling — an operation becomes an HTTP method, a path built directly
// from that operation's own parameters, and optionally a body, rather than
// a JSON-RPC envelope posted to a single endpoint. Each operation builds
// its own request directly (see prefixTenant/buildQueryString, below)
// rather than going through a shared method-name-keyed table — per review
// feedback that the table added indirection without buying much. The two
// pieces of logic every operation still needs in common (the
// tenant-in-path rule, 415-retry-and-remember) stay centralized, just as
// plain functions instead of a data table.

import ballerina/http;
import ballerina/url;

# Percent-encodes a value for use in a REST request path or query string,
# wrapping any encoding failure into this library's own error type.
#
# + value - the raw value to encode
# + return - the percent-encoded value, or a typed Error if it can't be
#            encoded
isolated function urlEncodeOrWrap(string value) returns string|Error {
    string|error encoded = url:encode(value, "UTF-8");
    if encoded is error {
        return wrapTransportError(encoded);
    }
    return encoded;
}

# Prepends the tenant routing segment to a request path, per the REST
# binding's path-prefix convention (`/{tenant}{path}`). A no-op when no
# tenant applies.
#
# + path - the request path, before any tenant prefix
# + tenant - the effective tenant for this call, or () if none applies
# + return - the path with the tenant segment prepended, or unchanged if
#            tenant is (), or a typed Error if tenant can't be encoded
isolated function prefixTenant(string path, string? tenant) returns string|Error {
    if tenant is () {
        return path;
    }
    string encodedTenant = check urlEncodeOrWrap(tenant);
    return string `/${encodedTenant}${path}`;
}

# Builds a URL query string from a set of already-stringified parameters —
# every value is percent-encoded, joined with `&`, and prefixed with `?`.
# Only called with parameters an operation actually has set; there's no
# generic "whatever's left over" set to iterate here, unlike the old
# table-driven version.
#
# + queryParams - the query parameters to include, already as strings
# + return - the query string including its leading `?`, or `""` if
#            queryParams is empty, or a typed Error if a value can't be
#            encoded
isolated function buildQueryString(map<string> queryParams) returns string|Error {
    string[] queryParts = [];
    foreach [string, string] [k, v] in queryParams.entries() {
        string encoded = check urlEncodeOrWrap(v);
        queryParts.push(string `${k}=${encoded}`);
    }
    if queryParts.length() == 0 {
        return "";
    }
    return "?" + string:'join("&", ...queryParts);
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
# like `tasks/get` have no meaning as a REST path), and the paths used
# below are v1.0's. A card resolving to v0.3 is therefore rejected at
# construction rather than at the first call. Use `JsonRpcClient` for a v0.3
# agent. See issue #31.
#
# See `ClientMethods`'s doc comment for this type's error contract: the
# Error subtype named on each method below is what a protocol-level
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
    # + return - a typed Error: from resolveAgentCard, from URL
    #            derivation when the card declares no HTTP+JSON
    #            interface, a VersionNotSupportedError if the card
    #            resolves to A2A v0.3, or an InternalError if the
    #            http:Client cannot be created
    public isolated function init(
            AgentCard|string agent,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            string[] requestedExtensions = [],
            int maxReconnectAttempts = 0) returns Error? {
        AgentCard card = agent is string
            ? check resolveAgentCard(agent, clientConfig, headers)
            : agent;
        string serviceUrl = check primaryUrl(card, HTTP_JSON);
        string? effectiveTenant = tenant;
        if effectiveTenant is () {
            AgentInterface|error iface = selectInterface(card, HTTP_JSON);
            if iface is AgentInterface {
                effectiveTenant = iface?.tenant;
            }
        }
        ProtocolMode detected = detectProtocolModeForBinding(card, HTTP_JSON);
        if detected == "V0_3" {
            return error VersionNotSupportedError(
                "this library does not implement A2A v0.3 over the REST/HTTP+JSON binding; use JsonRpcClient for a v0.3 agent",
                message = "this library does not implement A2A v0.3 over the REST/HTTP+JSON binding; use JsonRpcClient for a v0.3 agent"
            );
        }
        // http:ClientConfiguration isn't Cloneable (some of its fields
        // aren't pure data), so a mapping-constructor spread is used
        // instead of .clone() to shallow-copy it — otherwise this could
        // mutate the caller's own clientConfig in place.
        http:ClientConfiguration effectiveClientConfig = {...clientConfig};
        http:Client|error newHttpClient = new (serviceUrl, effectiveClientConfig);
        if newHttpClient is error {
            return wrapTransportError(newHttpClient);
        }
        self.httpClient = newHttpClient;
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

    # Issues one raw HTTP call, with no content-type negotiation --
    # callers that need negotiation go through performRestCallWithNegotiation
    # instead.
    #
    # + httpMethod - the HTTP verb to send, e.g. "GET" or "POST"
    # + path - the full request path, tenant prefix and path params already
    #          substituted
    # + body - the request body, or () for a bodiless request
    # + headers - the exact headers to send
    # + return - the raw HTTP response, or a transport-level error
    private isolated function rawRestCall(string httpMethod, string path, json? body, map<string> headers) returns http:Response|Error {
        http:Response|error result;
        if httpMethod == "GET" {
            result = self.httpClient->get(path, headers);
        } else if httpMethod == "DELETE" {
            result = self.httpClient->delete(path, headers = headers);
        } else {
            result = self.httpClient->post(path, body ?: {}, headers);
        }
        if result is error {
            return wrapTransportError(result);
        }
        return result;
    }

    # Issues one REST call, transparently retrying once with the legacy
    # application/json content type if the server rejects the spec-mandated
    # application/a2a+json with a 415 -- see buildHeaders' doc comment.
    #
    # + httpMethod - the HTTP verb to send, e.g. "GET" or "POST"
    # + path - the full request path, tenant prefix and path params already
    #          substituted
    # + body - the request body, or () for a bodiless request
    # + extraHeaders - additional headers merged in on top of buildHeaders'
    #                  defaults (e.g. Accept: text/event-stream)
    # + return - the raw HTTP response (from whichever attempt settled),
    #            or a transport-level error
    private isolated function performRestCallWithNegotiation(
            string httpMethod, string path, json? body, map<string> extraHeaders = {}) returns http:Response|Error {
        map<string> headers = self.buildHeaders();
        foreach [string, string] [k, v] in extraHeaders.entries() {
            headers[k] = v;
        }
        http:Response resp = check self.rawRestCall(httpMethod, path, body, headers);
        if resp.statusCode == 415 && headers["Content-Type"] != "application/json" {
            map<string> legacyHeaders = headers.clone();
            legacyHeaders["Content-Type"] = "application/json";
            http:Response retryResp = check self.rawRestCall(httpMethod, path, body, legacyHeaders);
            if retryResp.statusCode != 415 {
                lock {
                    self.useLegacyContentType = true;
                }
            }
            return retryResp;
        }
        return resp;
    }

    # Performs one non-streaming REST call and returns the unwrapped
    # result.
    #
    # DeleteTaskPushNotificationConfig returns google.protobuf.Empty over
    # the wire, so an absent or unparseable body on a 2xx is an empty
    # success rather than a malformed response. An operation that expects
    # real content fails its own cloneWithType instead, which is the right
    # place for that failure to surface.
    #
    # + httpMethod - the HTTP verb to send, e.g. "GET" or "POST"
    # + path - the full request path, tenant prefix and path params already
    #          substituted
    # + body - the request body, or () for a bodiless request
    # + return - the unwrapped result json, or a typed Error for a non-2xx
    #            response (via toA2AErrorFromRest) or a connection failure
    #            (wrapped as InternalError)
    private isolated function restCall(string httpMethod, string path, json? body) returns json|Error {
        http:Response resp = check self.performRestCallWithNegotiation(httpMethod, path, body);
        if resp.statusCode >= 200 && resp.statusCode < 300 {
            json|error payload = resp.getJsonPayload();
            if payload is json {
                return payload;
            }
            return {};
        }
        json|error errorBodyResult = resp.getJsonPayload();
        json? errorBody = errorBodyResult is json ? errorBodyResult : ();
        return toA2AErrorFromRest(resp.statusCode, errorBody);
    }

    # Validates that a REST response is a real SSE stream and decodes it,
    # shared by both streaming operations (sendStreamingMessage,
    # subscribeToTask) once each has already issued its own request --
    # any operation-specific retry (e.g. subscribeToTask's GET-then-POST
    # fallback) happens before this is called, not inside it.
    #
    # + resp - the HTTP response to an SSE request
    # + mode - the wire dialect this client speaks
    # + return - a stream of StreamResponse values, or a typed Error for a
    #            non-streaming error response (via toA2AErrorFromRest)
    private isolated function finishSseResponse(http:Response resp, ProtocolMode mode) returns stream<StreamResponse, error?>|Error {
        if !resp.getContentType().startsWith("text/event-stream") {
            json|error errBody = resp.getJsonPayload();
            return toA2AErrorFromRest(resp.statusCode, errBody is json ? errBody : ());
        }
        return readSseStream(resp, mode, HTTP_JSON);
    }

    # Opens the raw, unwrapped subscribeToTask stream. See
    # JsonRpcClient.openTaskSubscriptionStream for why reconnection must
    # resubscribe through this rather than the public remote function.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated function openTaskSubscriptionStream(string taskId, string? tenant = ()) returns stream<StreamResponse, error?>|Error {
        string encodedId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedId}:subscribe`, tenant ?: self.tenant);
        map<string> extraHeaders = {"Accept": "text/event-stream"};
        http:Response resp = check self.performRestCallWithNegotiation("GET", path, (), extraHeaders);
        // SubscribeToTask's proto annotation says GET, but a non-reference
        // server that hand-rolled its REST routes following the reference
        // *client* (which sends POST) might only have registered POST.
        // Scoped to exactly this one operation — retrying broadly for
        // every operation would mask genuine method-not-allowed errors
        // elsewhere.
        if resp.statusCode == 404 || resp.statusCode == 405 || resp.statusCode == 501 {
            resp = check self.performRestCallWithNegotiation("POST", path, (), extraHeaders);
        }
        return self.finishSseResponse(resp, self.mode);
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
            map<json>? metadata) returns Task|Message|Error {
        string? effectiveTenant = tenant ?: self.tenant;
        map<json> body = check buildSendMessageParams(
                message, config, metadata, effectiveTenant, self.mode);
        string path = check prefixTenant("/message:send", effectiveTenant);
        json result = check self.restCall("POST", path, body);
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
    # + return - A Task or a Message on success, or a typed Error on failure
    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|Error {
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
    # + return - A stream of StreamResponse values, or a typed Error
    isolated remote function sendStreamingMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|Error {
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
        map<json> body = check buildSendMessageParams(
                message, config, metadata, effectiveTenant, self.mode);
        string path = check prefixTenant("/message:stream", effectiveTenant);
        map<string> extraHeaders = {"Accept": "text/event-stream"};
        http:Response resp = check self.performRestCallWithNegotiation("POST", path, body, extraHeaders);
        stream<StreamResponse, error?> rawStream = check self.finishSseResponse(resp, self.mode);
        return wrapReconnecting(rawStream, self, self.maxReconnectAttempts, effectiveTenant);
    }

    # Retrieves the current state of a task.
    #
    # + taskId - The task identifier returned by a previous sendMessage
    # + historyLength - Maximum messages to include in task.history
    # + tenant - Optional per-call tenant override
    # + return - The current Task, or a TaskNotFoundError (or other typed
    #            Error) if unknown
    isolated remote function getTask(string taskId, int? historyLength = (), string? tenant = ()) returns Task|Error {
        string encodedId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedId}`, tenant ?: self.tenant);
        if historyLength is int {
            path = path + check buildQueryString({"historyLength": historyLength.toString()});
        }
        json result = check self.restCall("GET", path, ());
        return decodeTaskResult(result, self.mode);
    }

    # Requests cancellation of an in-progress task.
    #
    # + taskId - The task to cancel
    # + metadata - Optional additional context passed to the agent
    # + tenant - Optional per-call tenant override
    # + return - The updated Task, or a TaskNotFoundError/TaskNotCancelableError
    #            (or other typed Error)
    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|Error {
        string? effectiveTenant = tenant ?: self.tenant;
        map<json> body = buildCancelTaskParams(taskId, metadata, effectiveTenant, self.mode);
        string encodedId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedId}:cancel`, effectiveTenant);
        json result = check self.restCall("POST", path, body);
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
    # + return - A stream of StreamResponse values, or a typed Error
    isolated remote function subscribeToTask(
            string taskId,
            string? tenant = ()) returns stream<StreamResponse, error?>|Error {
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
    #            or another typed Error
    isolated remote function listTasks(
            ListTasksFilter? filter = (),
            string? tenant = ()) returns ListTasksResult|Error {
        check guardListTasksSupported(self.mode);
        map<string> queryParams = {};
        if filter is ListTasksFilter {
            string? contextId = filter?.contextId;
            if contextId is string {
                queryParams["contextId"] = contextId;
            }
            TaskState? status = filter?.status;
            if status is TaskState {
                queryParams["status"] = status;
            }
            int? pageSize = filter?.pageSize;
            if pageSize is int {
                queryParams["pageSize"] = pageSize.toString();
            }
            string? pageToken = filter?.pageToken;
            if pageToken is string {
                queryParams["pageToken"] = pageToken;
            }
            int? historyLength = filter?.historyLength;
            if historyLength is int {
                queryParams["historyLength"] = historyLength.toString();
            }
            string? statusTimestampAfter = filter?.statusTimestampAfter;
            if statusTimestampAfter is string {
                queryParams["statusTimestampAfter"] = statusTimestampAfter;
            }
            boolean? includeArtifacts = filter?.includeArtifacts;
            if includeArtifacts is boolean {
                queryParams["includeArtifacts"] = includeArtifacts.toString();
            }
        }
        string path = check prefixTenant("/tasks", tenant ?: self.tenant);
        path = path + check buildQueryString(queryParams);
        json result = check self.restCall("GET", path, ());
        return decodeListTasksResult(result);
    }

    # Registers a webhook to receive updates for a task.
    #
    # + config - The webhook configuration; config.taskId identifies the task
    # + tenant - Optional per-call tenant override
    # + return - The created config as the server persisted it, or a
    #            PushNotificationNotSupportedError (or other typed Error)
    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|Error {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("createTaskPushNotificationConfig");
        }
        string? effectiveTenant = tenant ?: self.tenant;
        map<json> body = check buildCreateTaskPushNotificationConfigParams(
                config, effectiveTenant, self.mode);
        string? taskId = config?.taskId;
        if taskId is () {
            return error InternalError(
                    "REST binding for \"CreateTaskPushNotificationConfig\" requires config.taskId to be set");
        }
        string encodedTaskId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedTaskId}/pushNotificationConfigs`, effectiveTenant);
        json result = check self.restCall("POST", path, body);
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    # Retrieves a previously registered push-notification webhook config.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier, from its creation response
    # + tenant - Optional per-call tenant override
    # + return - The config, or a PushNotificationNotSupportedError/
    #            TaskNotFoundError (or other typed Error)
    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|Error {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("getTaskPushNotificationConfig");
        }
        string encodedTaskId = check urlEncodeOrWrap(taskId);
        string encodedId = check urlEncodeOrWrap(id);
        string path = check prefixTenant(
                string `/tasks/${encodedTaskId}/pushNotificationConfigs/${encodedId}`, tenant ?: self.tenant);
        json result = check self.restCall("GET", path, ());
        return decodeTaskPushNotificationConfig(result, self.mode);
    }

    # Lists all push-notification webhook configs registered for a task.
    #
    # + taskId - The task to list configs for
    # + pageSize - Maximum results per page
    # + pageToken - Opaque cursor from a previous result's nextPageToken
    # + tenant - Optional per-call tenant override
    # + return - A page of matching configs, or a
    #            PushNotificationNotSupportedError (or other typed Error)
    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|Error {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("listTaskPushNotificationConfigs");
        }
        string encodedTaskId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedTaskId}/pushNotificationConfigs`, tenant ?: self.tenant);
        map<string> queryParams = {};
        if pageSize is int {
            queryParams["pageSize"] = pageSize.toString();
        }
        if pageToken is string {
            queryParams["pageToken"] = pageToken;
        }
        path = path + check buildQueryString(queryParams);
        json result = check self.restCall("GET", path, ());
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
    # + return - nil on success, or a typed Error
    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns Error? {
        string encodedTaskId = check urlEncodeOrWrap(taskId);
        string encodedId = check urlEncodeOrWrap(id);
        string path = check prefixTenant(
                string `/tasks/${encodedTaskId}/pushNotificationConfigs/${encodedId}`, tenant ?: self.tenant);
        json _ = check self.restCall("DELETE", path, ());
    }

    # Retrieves the agent's extended AgentCard.
    #
    # + tenant - Optional per-call tenant override
    # + return - The extended AgentCard, the already-held card when that
    #            card declares no extended-card support, or a typed Error
    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|Error {
        lock {
            AgentCard? held = self.agentCard;
            if held is AgentCard && !held.capabilities.extendedAgentCard {
                return held.clone();
            }
        }
        string path = check prefixTenant("/extendedAgentCard", tenant ?: self.tenant);
        json result = check self.restCall("GET", path, ());
        AgentCard fetched = check parseAgentCardBody(result);
        lock {
            self.agentCard = fetched.clone();
        }
        return fetched;
    }
}
