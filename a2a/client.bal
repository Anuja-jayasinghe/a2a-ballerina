// A2A client implementation.

import ballerina/a2a.transport;
import ballerina/http;
import ballerina/uuid;

# Parses a raw AgentCard JSON body into a typed AgentCard, applying the
# v0.3 security field-name rename and the tolerant parsing of
# securitySchemes, securityRequirements, signatures, and each skill's
# securityRequirements before the main typed clone, so neither a
# v0.3-dialect card nor a card carrying one malformed entry in any of
# those four fields fails to parse entirely.
#
# + body - the raw JSON AgentCard body, straight off the wire
# + return - the parsed AgentCard, or an error if the remainder of the
#            card (everything but the four tolerantly-parsed fields)
#            doesn't match the AgentCard shape
isolated function parseAgentCardBody(json body) returns AgentCard|error {
    json renamed = renameV03SecurityField(body);
    map<json> cardMap = check renamed.ensureType();

    boolean hasSecuritySchemes = cardMap.hasKey("securitySchemes");
    json securitySchemesJson = hasSecuritySchemes ? cardMap.remove("securitySchemes") : {};

    boolean hasSecurityRequirements = cardMap.hasKey("securityRequirements");
    json securityRequirementsJson = hasSecurityRequirements ? cardMap.remove("securityRequirements") : [];

    boolean hasSignatures = cardMap.hasKey("signatures");
    json signaturesJson = hasSignatures ? cardMap.remove("signatures") : [];

    // Skill-level securityRequirements needs the same tolerant treatment,
    // but every other AgentSkill field should still be strictly validated
    // by the main clone below -- so only that one sub-field is pulled out
    // of each skill first, not the whole skill.
    json? skillsField = cardMap["skills"];
    SecurityRequirement[][] perSkillSecurityRequirements = [];
    if skillsField is json[] {
        json[] strippedSkills = [];
        foreach json skillJson in skillsField {
            if skillJson is map<json> {
                map<json> skillMap = skillJson.clone();
                json skillSecurityRequirementsJson = skillMap.hasKey("securityRequirements")
                    ? skillMap.remove("securityRequirements") : [];
                perSkillSecurityRequirements.push(check parseSecurityRequirements(skillSecurityRequirementsJson));
                strippedSkills.push(skillMap);
            } else {
                perSkillSecurityRequirements.push([]);
                strippedSkills.push(skillJson);
            }
        }
        cardMap["skills"] = strippedSkills;
    }

    AgentCard card = check cardMap.cloneWithType(AgentCard);

    if hasSecuritySchemes {
        card.securitySchemes = check parseSecuritySchemes(securitySchemesJson);
    }
    if hasSecurityRequirements {
        card.securityRequirements = check parseSecurityRequirements(securityRequirementsJson);
    }
    if hasSignatures {
        card.signatures = check parseAgentCardSignatures(signaturesJson);
    }
    foreach int i in 0 ..< card.skills.length() {
        if i < perSkillSecurityRequirements.length() {
            card.skills[i].securityRequirements = perSkillSecurityRequirements[i];
        }
    }

    return card;
}

# Internal helper that fetches and parses an Agent Card with optional
# conditional-request support. Shared by resolveAgentCard and
# resolveAgentCardCached.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers, for API key authentication
# + conditionalEtag - Optional ETag value to send in If-None-Match header
# + return - A tuple of {card?, etag, notModified} where card is nil for 304
#            responses, or an error
isolated function fetchAgentCardWithCaching(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig,
        map<string> headers,
        string? conditionalEtag = ()) returns record {|AgentCard? card; string? etag; boolean notModified;|}|error {
    http:Client discoveryClient = check new (agentBaseUrl, clientConfig);
    map<string> reqHeaders = {"A2A-Version": "1.0"};
    foreach [string, string] [k, v] in headers.entries() {
        reqHeaders[k] = v;
    }
    if conditionalEtag is string {
        reqHeaders["If-None-Match"] = conditionalEtag;
    }
    http:Response resp = check discoveryClient->get(
        "/.well-known/agent-card.json", reqHeaders
    );
    if resp.statusCode == 304 && conditionalEtag is string {
        return {card: (), etag: conditionalEtag, notModified: true};
    }
    if resp.statusCode != 200 {
        return error A2AInternalError(
            string `Agent Card fetch failed with HTTP ${resp.statusCode}`,
            code = resp.statusCode
        );
    }
    json body = check resp.getJsonPayload();
    AgentCard card = check parseAgentCardBody(body);
    string|http:HeaderNotFoundError etagHeader = resp.getHeader("ETag");
    return {card, etag: etagHeader is string ? etagHeader : (), notModified: false};
}

# Fetches and parses a remote agent's Agent Card from its well-known
# endpoint.
#
# For cache-aware fetching with HTTP 304 support, see resolveAgentCardCached.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers, for API key authentication
# + return - The parsed AgentCard, or an error if the fetch or parse fails
public isolated function resolveAgentCard(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns AgentCard|error {
    record {|AgentCard? card; string? etag; boolean notModified;|} result =
        check fetchAgentCardWithCaching(agentBaseUrl, clientConfig, headers);
    return <AgentCard>result.card;
}

# An AgentCard together with the HTTP caching metadata needed to make a
# conditional follow-up request.
public type CachedAgentCard record {|
    # The parsed AgentCard
    AgentCard card;
    # The ETag header value from the response, if any, for use in conditional requests
    string? etag;
|};

# Fetches an agent's Agent Card, reusing a previous fetch's body when the
# server confirms nothing changed (HTTP 304), per standard HTTP caching —
# resolveAgentCard's original per-call fetch was always correct but never
# cheap; this adds the standard conditional-GET optimization on top without
# changing resolveAgentCard's own behavior.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers, for API key authentication
# + previous - A card previously returned by this function, to enable a
#              conditional (If-None-Match) request
# + return - The parsed AgentCard plus its caching metadata, or an error
public isolated function resolveAgentCardCached(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        CachedAgentCard? previous = ()) returns CachedAgentCard|error {
    record {|AgentCard? card; string? etag; boolean notModified;|} result =
        check fetchAgentCardWithCaching(agentBaseUrl, clientConfig, headers, previous?.etag);
    if result.notModified && previous is CachedAgentCard {
        return previous;
    }
    return {card: <AgentCard>result.card, etag: result.etag};
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
    private final string[] & readonly requestedExtensions;
    private string[] grantedExtensions = [];

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
    # + requestedExtensions - Optional A2A extension URIs to request from
    #                         the remote agent, sent as a comma-joined
    #                         A2A-Extensions header on every request. The
    #                         agent's response indicates which extensions
    #                         it actually granted; see lastGrantedExtensions.
    # + credentials - Optional credential strings, keyed by security scheme
    #                 name exactly as declared in agentCard.securitySchemes.
    #                 When agentCard is given and this is non-empty,
    #                 buildAuthFromCard resolves them into auth config and
    #                 headers, merged in underneath clientConfig and headers
    #                 respectively — an explicit value the caller already
    #                 set always wins over the auto-wired one. Ignored (no
    #                 error) when agentCard is not given, so passing
    #                 credentials without a card is a silent no-op rather
    #                 than a hard failure.
    # + return - error if the underlying http:Client cannot be created, or
    #            if credentials is non-empty but does not satisfy any of
    #            agentCard's declared SecurityRequirements
    public isolated function init(
            string serviceUrl,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            AgentCard? agentCard = (),
            string[] requestedExtensions = [],
            map<string> credentials = {}) returns error? {
        // http:ClientConfiguration isn't Cloneable (some of its fields
        // aren't pure data), so a mapping-constructor spread is used
        // instead of .clone() to shallow-copy it before mutating .auth —
        // otherwise this would mutate the caller's own clientConfig in
        // place, corrupting it for any other Client.init call that reuses
        // the same variable.
        http:ClientConfiguration effectiveClientConfig = {...clientConfig};
        map<string> effectiveHeaders = headers.clone();
        if agentCard is AgentCard && credentials.length() > 0 {
            ResolvedAuth resolved = check buildAuthFromCard(agentCard, credentials);
            if effectiveClientConfig.auth is () {
                effectiveClientConfig.auth = resolved.clientConfig.auth;
            }
            foreach [string, string] [k, v] in resolved.headers.entries() {
                if !effectiveHeaders.hasKey(k) {
                    effectiveHeaders[k] = v;
                }
            }
        }
        self.httpClient = check new (serviceUrl, effectiveClientConfig);
        self.defaultHeaders = effectiveHeaders.cloneReadOnly();
        self.tenant = tenant;
        self.mode = agentCard is AgentCard ? detectProtocolMode(agentCard) : "V1_0";
        self.requestedExtensions = requestedExtensions.cloneReadOnly();
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
        if self.requestedExtensions.length() > 0 {
            headers["A2A-Extensions"] = string:'join(",", ...self.requestedExtensions);
        }
        return headers;
    }

    # Returns the extensions the remote agent granted on the most recent
    # call, per the response's X-A2A-Extensions header. Empty until the
    # first call completes, or if the agent never sent the header.
    #
    # + return - the granted extension URIs
    public isolated function lastGrantedExtensions() returns string[] {
        lock {
            return self.grantedExtensions.clone();
        }
    }

    # Captures the response's X-A2A-Extensions header, if present, into
    # self.grantedExtensions. Shared by rpcCall and openSseStream, since
    # both read a granted-extensions header off their respective
    # http:Response before doing anything else with it.
    #
    # + resp - the response just received from the remote agent
    private isolated function captureGrantedExtensions(http:Response resp) {
        string|error extHeader = resp.getHeader("X-A2A-Extensions");
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
        self.captureGrantedExtensions(resp);
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
        self.captureGrantedExtensions(resp);
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

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # Has no equivalent in A2A protocol v0.3 (confirmed new in v1.0) — a
    # Client detected as V0_3 fails immediately with
    # VersionNotSupportedError rather than sending a request the server
    # can't possibly understand.
    #
    # + filter - Optional filter/pagination parameters
    # + tenant - Optional per-call tenant override
    # + return - A page of matching tasks, or an error
    isolated remote function listTasks(
            ListTasksFilter? filter = (),
            string? tenant = ()) returns ListTasksResult|error {
        if self.mode == "V0_3" {
            return error VersionNotSupportedError(
                "ListTasks has no equivalent in A2A protocol v0.3",
                message = "ListTasks has no equivalent in A2A protocol v0.3"
            );
        }

        map<json> params = {};
        if filter is ListTasksFilter {
            string? contextId = filter?.contextId;
            TaskState? status = filter?.status;
            int? pageSize = filter?.pageSize;
            string? pageToken = filter?.pageToken;
            int? historyLength = filter?.historyLength;
            string? statusTimestampAfter = filter?.statusTimestampAfter;
            boolean? includeArtifacts = filter?.includeArtifacts;
            if contextId is string {
                params["contextId"] = contextId;
            }
            if status is TaskState {
                params["status"] = status;
            }
            if pageSize is int {
                params["pageSize"] = pageSize;
            }
            if pageToken is string {
                params["pageToken"] = pageToken;
            }
            if historyLength is int {
                params["historyLength"] = historyLength;
            }
            if statusTimestampAfter is string {
                params["statusTimestampAfter"] = statusTimestampAfter;
            }
            if includeArtifacts is boolean {
                params["includeArtifacts"] = includeArtifacts;
            }
        }
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("ListTasks", params);
        return check result.cloneWithType(ListTasksResult);
    }

    # Registers a webhook to receive updates for a task.
    #
    # + config - The webhook configuration; config.taskId identifies the task
    # + tenant - Optional per-call tenant override
    # + return - The created config as the server persisted it, or an error
    #            (PushNotificationNotSupportedError if capabilities.pushNotifications is false)
    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        map<json> params = self.mode == "V0_3"
            ? encodeV03TaskPushNotificationConfig(config)
            : check config.toJson().ensureType();
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("CreateTaskPushNotificationConfig", params);
        return self.mode == "V0_3"
            ? check parseV03TaskPushNotificationConfig(result)
            : check result.cloneWithType(TaskPushNotificationConfig);
    }

    # Retrieves a previously registered push-notification webhook config.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier, from its creation response
    # + tenant - Optional per-call tenant override
    # + return - The config, or an error
    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        // v0.3's GetTaskPushNotificationConfigParams is {id: <taskId>,
        // pushNotificationConfigId: <id>} — not {taskId, id} like v1.0 —
        // per a2a-sdk 0.3.23's GetTaskPushNotificationConfigParams.
        map<json> params = self.mode == "V0_3"
            ? {id: taskId, pushNotificationConfigId: id}
            : {taskId, id};
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("GetTaskPushNotificationConfig", params);
        return self.mode == "V0_3"
            ? check parseV03TaskPushNotificationConfig(result)
            : check result.cloneWithType(TaskPushNotificationConfig);
    }

    # Lists all push-notification webhook configs registered for a task.
    #
    # + taskId - The task to list configs for
    # + pageSize - Maximum results per page
    # + pageToken - Opaque cursor from a previous result's nextPageToken
    # + tenant - Optional per-call tenant override
    # + return - A page of matching configs, or an error
    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error {
        // v0.3's ListTaskPushNotificationConfigParams is {id: <taskId>}
        // only — no pageSize/pageToken, since v0.3 has no pagination
        // concept for this operation — per a2a-sdk 0.3.23's
        // ListTaskPushNotificationConfigParams.
        map<json> params = self.mode == "V0_3" ? {id: taskId} : {taskId};
        if self.mode == "V1_0" {
            if pageSize is int {
                params["pageSize"] = pageSize;
            }
            if pageToken is string {
                params["pageToken"] = pageToken;
            }
        }
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("ListTaskPushNotificationConfigs", params);
        return self.mode == "V0_3"
            ? check parseV03ListTaskPushNotificationConfigsResult(result)
            : check result.cloneWithType(ListTaskPushNotificationConfigsResult);
    }

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10 — deleting an already-deleted or
    # nonexistent config is not an error.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier
    # + tenant - Optional per-call tenant override
    # + return - nil on success, or an error
    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns error? {
        // v0.3's DeleteTaskPushNotificationConfigParams is {id: <taskId>,
        // pushNotificationConfigId: <id>} — not {taskId, id} like v1.0 —
        // per a2a-sdk 0.3.23's DeleteTaskPushNotificationConfigParams.
        map<json> params = self.mode == "V0_3"
            ? {id: taskId, pushNotificationConfigId: id}
            : {taskId, id};
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json _ = check self.rpcCall("DeleteTaskPushNotificationConfig", params);
    }

    # Retrieves the agent's extended AgentCard, available after client
    # authentication (via the same http:ClientConfiguration.auth every
    # other operation already uses — no separate auth wiring needed).
    #
    # Requires capabilities.extendedAgentCard to be true; otherwise the
    # agent returns UnsupportedOperationError, or
    # ExtendedAgentCardNotConfiguredError if the capability is on but no
    # extended card is actually configured.
    #
    # + tenant - Optional per-call tenant override
    # + return - The extended AgentCard, or an error
    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error {
        map<json> params = {};
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing is a v1.0-only concept (per-AgentInterface tenant
        // values); v0.3 has no wire counterpart, so it's omitted rather
        // than sent as an unrecognized param a strict v0.3 server might
        // reject.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("GetExtendedAgentCard", params);
        return check parseAgentCardBody(result);
    }
}
