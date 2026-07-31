// A2A client implementation.

import ballerina/a2a.transport;
import ballerina/http;
import ballerina/url;
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
# + return - The parsed AgentCard plus its caching metadata, or an error.
#            Note: like resolveAgentCard, this is a bare `error` rather
#            than a narrowed A2A error union — it shares
#            fetchAgentCardWithCaching with resolveAgentCard, which
#            propagates raw, un-wrapped http/JSON errors (e.g. connection
#            failures, malformed JSON) via `check` alongside the typed
#            A2AInternalError cases it constructs itself. Callers that
#            need to distinguish typed A2A errors from these raw
#            passthroughs must still pattern-match on the concrete error
#            type.
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

# The A2A transport bindings this library can speak.
public type TransportBinding "JSONRPC"|"HTTP+JSON";

# Resolves the whole matched AgentInterface for a preferred binding, not
# just its url — callers need the interface's own tenant and
# protocolVersion, which must come from the same entry the url did, not
# be independently re-derived (a card can list several interfaces with
# different tenant/version values).
#
# + card - the agent card to read the endpoint from
# + preferredBinding - which transport binding to look for; defaults to
#                      "JSONRPC", preserving every existing single-binding
#                      caller's behavior unchanged
# + return - the first supportedInterfaces entry declaring the matching
#            protocolBinding, or an error if none exists. The legacy
#            top-level url field is never treated as a match for
#            "HTTP+JSON" — it predates that binding entirely — so only
#            "JSONRPC" callers fall back to it (see primaryUrl)
public isolated function selectInterface(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns AgentInterface|error {
    foreach AgentInterface iface in card.supportedInterfaces {
        if iface.protocolBinding == preferredBinding {
            return iface;
        }
    }
    return error(string `AgentCard has no ${preferredBinding} entry in supportedInterfaces`);
}

# Resolves the URL to construct a Client against, per v1.0's removal of
# AgentCard.url as a required field.
#
# + card - the agent card to read the endpoint from
# + preferredBinding - which transport binding to resolve a URL for;
#                      defaults to "JSONRPC", preserving every existing
#                      caller's behavior unchanged
# + return - the matching supportedInterfaces entry's url, the legacy url
#            field if preferredBinding is "JSONRPC" and no such entry
#            exists, or an error if neither is present
public isolated function primaryUrl(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns string|error {
    AgentInterface|error iface = selectInterface(card, preferredBinding);
    if iface is AgentInterface {
        return iface.url;
    }
    if preferredBinding == "JSONRPC" {
        string? legacyUrl = card?.url;
        if legacyUrl is string {
            return legacyUrl;
        }
    }
    return error(string `AgentCard has no ${preferredBinding} entry in supportedInterfaces and no legacy url field`);
}

# How one operation maps onto the REST binding.
type RestOperation record {|
    string httpMethod;
    string pathTemplate;
    string[] pathParams;
    boolean hasBody;
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
#            remote function already passes to rpcCall/openSseStream
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
        if pValue is string {
            // Plain string substitution, not regex: pathTemplate never
            // contains a literal "{"/"}" outside of exactly these
            // placeholder markers, so there's no need for regex escaping
            // here. lang.string has no plain literal-replace function
            // (only regex-based replaceAll/replaceFirst), so the
            // placeholder is substituted manually via indexOf/substring.
            string placeholder = string `{${pName}}`;
            int? idx = path.indexOf(placeholder);
            if idx is int {
                path = path.substring(0, idx) + pValue + path.substring(idx + placeholder.length());
            }
            if !op.hasBody {
                _ = workingParams.remove(pName);
            }
        }
    }

    if tenant is string {
        path = string `/${tenant}${path}`;
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

# An A2A protocol client for calling remote agents.
public isolated client class Client {
    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;
    private final ProtocolMode mode;
    private final string[] & readonly requestedExtensions;
    private string[] grantedExtensions = [];
    private final int maxReconnectAttempts;
    private final TransportBinding binding;

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
    # + maxReconnectAttempts - Opt-in automatic SSE reconnection. When 0
    #                          (the default), sendMessageStream and
    #                          subscribeToTask behave exactly as before —
    #                          a dropped connection surfaces its error
    #                          immediately. When positive, the returned
    #                          stream transparently resubscribes to the
    #                          task via subscribeToTask up to this many
    #                          times if the underlying stream ends with an
    #                          error (not a clean terminal-state close)
    #                          before giving up and surfacing the error.
    # + binding - Which transport binding this Client speaks. Defaults to
    #             "JSONRPC", preserving today's behavior exactly. When
    #             agentCard is given, the matching supportedInterfaces
    #             entry for this binding determines self.mode; v0.3 has no
    #             REST/HTTP+JSON binding equivalent, so "HTTP+JSON"
    #             combined with a card that resolves to v0.3 is rejected.
    # + return - error if the underlying http:Client cannot be created, or
    #            if credentials is non-empty but does not satisfy any of
    #            agentCard's declared SecurityRequirements, or if binding
    #            is "HTTP+JSON" and agentCard resolves to A2A v0.3
    public isolated function init(
            string serviceUrl,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            AgentCard? agentCard = (),
            string[] requestedExtensions = [],
            map<string> credentials = {},
            int maxReconnectAttempts = 0,
            TransportBinding binding = "JSONRPC") returns error? {
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
        self.binding = binding;
        self.mode = agentCard is AgentCard
            ? detectProtocolModeForBinding(agentCard, binding)
            : "V1_0";
        if self.mode == "V0_3" && binding == "HTTP+JSON" {
            return error VersionNotSupportedError(
                "A2A protocol v0.3 has no REST/HTTP+JSON binding equivalent",
                message = "A2A protocol v0.3 has no REST/HTTP+JSON binding equivalent"
            );
        }
        self.requestedExtensions = requestedExtensions.cloneReadOnly();
        self.maxReconnectAttempts = maxReconnectAttempts;
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
    # call that reported them, per the response's A2A-Extensions header.
    # Empty until the first call completes. Note: a call whose response
    # omits the header does not clear a previous grant — this reflects the
    # most recent call that reported an A2A-Extensions header, not
    # necessarily literally the single most recent call.
    #
    # + return - the granted extension URIs
    public isolated function lastGrantedExtensions() returns string[] {
        lock {
            return self.grantedExtensions.clone();
        }
    }

    # Captures the response's A2A-Extensions header, if present, into
    # self.grantedExtensions. Shared by rpcCall and openSseStream, since
    # both read a granted-extensions header off their respective
    # http:Response before doing anything else with it.
    #
    # Per spec §14.2.2, the request and response directions use the exact
    # same header name (`A2A-Extensions`, not the deprecated `X-`-prefixed
    # convention) — this reads that name first, falling back to the
    # legacy `X-A2A-Extensions` spelling only for non-conformant servers
    # that still send it.
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

    # Performs a unary JSON-RPC call and returns the unwrapped result.
    #
    # + method - the JSON-RPC method name
    # + params - the JSON-RPC method parameters
    # + return - the unwrapped result, or an error
    private isolated function rpcCall(string method, map<json> params) returns json|error {
        if self.binding == "HTTP+JSON" {
            return self.restCall(method, params);
        }
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

    # Performs one REST binding call and returns the unwrapped result, or
    # (), matching rpcCall's contract for callers that only need the
    # unwrapped result on the JSON-RPC side. DeleteTaskPushNotificationConfig
    # returns google.protobuf.Empty over the wire — an absent or empty
    # body must be tolerated here rather than treated as
    # InvalidAgentResponseError, unlike a genuinely malformed response.
    #
    # + method - the JSON-RPC-style method name (see buildRestRequest)
    # + params - the same params map the JSON-RPC binding would build
    # + return - the unwrapped result json (or an empty map for a bodiless
    #            success response), or a typed A2AError
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
            // No parseable body (e.g. 204 No Content) — treat as an
            // empty successful result. Callers of a void operation like
            // deleteTaskPushNotificationConfig discard this; callers of
            // an operation expecting real content will fail their own
            // cloneWithType, which is the correct place for that failure
            // to surface, not here.
            return {};
        }
        json? errorBody = resp.getJsonPayload() is json ? check resp.getJsonPayload() : ();
        return toA2AErrorFromRest(resp.statusCode, errorBody);
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
        if self.binding == "HTTP+JSON" {
            return self.openRestSseStream(method, params);
        }
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

        return readSseStream(resp, self.mode, self.binding);
    }

    # Opens a REST binding SSE stream for a streaming operation
    # (SendStreamingMessage or SubscribeToTask).
    #
    # + method - the JSON-RPC-style method name (see buildRestRequest)
    # + params - the same params map the JSON-RPC binding would build
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
        return readSseStream(resp, self.mode, self.binding);
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
        stream<StreamResponse, error?> rawStream = check self.openSseStream("SendStreamingMessage", params);
        if self.maxReconnectAttempts <= 0 {
            return rawStream;
        }

        // Peek the first event to find the taskId to resubscribe to on a
        // dropped connection. A bare Message (no task) carries nothing to
        // reconnect against, so wrapping is a no-op in that case: the raw
        // stream is returned untouched, with the peeked value re-spliced
        // back on as ReconnectingStreamGenerator's buffered first result
        // (with maxAttempts 0, so it never actually attempts a reconnect)
        // so the caller never observes that a peek happened either way.
        record {| StreamResponse value; |}|error? peeked = rawStream.next();
        if peeked is error {
            return peeked;
        }
        if peeked is () {
            stream<StreamResponse, error?> wrapped = new (new ReconnectingStreamGenerator(rawStream, self, "", 0, tenant = effectiveTenant));
            return wrapped;
        }
        Task? maybeTask = peeked.value?.task;
        if maybeTask is Task {
            stream<StreamResponse, error?> wrapped =
                new (new ReconnectingStreamGenerator(rawStream, self, maybeTask.id, self.maxReconnectAttempts, peeked, effectiveTenant));
            return wrapped;
        }
        // A stream can also legitimately open with a status update rather
        // than a Task (e.g. resubscribing to an already-created task), and
        // that update still carries a taskId worth reconnecting against —
        // so this isn't limited to the first-event-is-a-Task case above.
        string? maybeTaskId = peeked.value?.statusUpdate?.taskId;
        if maybeTaskId is string {
            stream<StreamResponse, error?> wrapped =
                new (new ReconnectingStreamGenerator(rawStream, self, maybeTaskId, self.maxReconnectAttempts, peeked, effectiveTenant));
            return wrapped;
        }
        stream<StreamResponse, error?> wrapped = new (new ReconnectingStreamGenerator(rawStream, self, "", 0, peeked, effectiveTenant));
        return wrapped;
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
        stream<StreamResponse, error?> rawStream = check self.openTaskSubscriptionStream(taskId, tenant);
        if self.maxReconnectAttempts <= 0 {
            return rawStream;
        }
        stream<StreamResponse, error?> wrapped = new (new ReconnectingStreamGenerator(rawStream, self, taskId, self.maxReconnectAttempts, tenant = tenant));
        return wrapped;
    }

    # Opens the raw, unwrapped subscribeToTask stream — the same request
    # subscribeToTask itself sends, but without any reconnect wrapping.
    #
    # Used internally by both subscribeToTask (which wraps this in a
    # ReconnectingStreamGenerator when maxReconnectAttempts > 0) and by
    # ReconnectingStreamGenerator itself when it resubscribes on a drop.
    # The latter must go through this raw helper rather than the public
    # subscribeToTask remote function: calling the public
    # subscribeToTask would construct a brand-new
    # ReconnectingStreamGenerator with its own fresh
    # attemptsUsed/maxAttempts budget on every single reconnect, silently
    # resetting the attempt count each time and defeating
    # maxReconnectAttempts entirely — against a persistently-failing
    # agent, reconnection would recurse without bound instead of ever
    # giving up. Going through this raw helper keeps exactly one budget
    # (the outer generator's own) governing the whole reconnect chain.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated function openTaskSubscriptionStream(string taskId, string? tenant = ()) returns stream<StreamResponse, error?>|error {
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
