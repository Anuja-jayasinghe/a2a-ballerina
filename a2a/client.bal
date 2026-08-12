// Agent Card resolution, interface selection, the REST request table, and
// the common Client that delegates to whichever transport-specific client
// the card prefers.
//
// The transport marshaling that used to live here now sits with the client
// that owns it: jsonrpc_client.bal, rest_client.bal, grpc_client.bal.

import ballerina/http;
import ballerina/url;

# Rewrites a pre-v1.0 card's transport declarations into the v1.0
# `supportedInterfaces` shape, in place on the raw card map.
#
# A2A v0.3 declares transports with `preferredTransport` (defaulting to
# "JSONRPC", naming what is served at the top-level `url`) plus an
# `additionalInterfaces` array of `{url, transport}` objects. v1.0 replaced
# both with `supportedInterfaces`, an ordered array of
# `{url, protocolBinding, protocolVersion}`.
#
# Without this, a v0.3 card's transports are invisible: AgentCard is an open
# record, so both fields land in the rest field and are never read,
# `supportedInterfaces` stays empty, and selection falls through to the
# legacy-url branch and answers "JSONRPC" — even for a card whose `url` is a
# gRPC endpoint. That produced a JSON-RPC client aimed at a gRPC address
# which constructed fine and failed at the first call.
#
# Contrary to what this module's comments claimed until now, v0.3 does
# define all three transports; it is this library that implements v0.3 over
# JSON-RPC only. Normalizing here does not change that. It makes the card
# legible so the existing selection rules can act on it correctly: a v0.3
# gRPC interface becomes a declared-but-unserviceable entry that selection
# skips, landing on the card's real JSON-RPC endpoint instead of pointing
# JSON-RPC at the gRPC one.
#
# + cardMap - the raw card map, mutated in place
isolated function normalizeLegacyInterfaces(map<json> cardMap) {
    // Only pre-v1.0 cards carry these two fields; v1.0 removed them. Their
    // absence means there is nothing here to translate, and a card already
    // declaring supportedInterfaces is v1.0-native and left untouched.
    boolean hasLegacyTransportFields =
        cardMap.hasKey("preferredTransport") || cardMap.hasKey("additionalInterfaces");
    if !hasLegacyTransportFields {
        return;
    }
    json? existing = cardMap["supportedInterfaces"];
    if existing is json[] && existing.length() > 0 {
        return;
    }

    // Their presence also dates the card: both were dropped in v1.0, so a
    // card carrying them and no explicit protocolVersion is pre-1.0. Saying
    // so explicitly matters because detectProtocolModeForBinding reads the
    // version off the matched interface first, and an interface with no
    // version at all would resolve V1_0 — silently upgrading a v0.3 agent.
    json? versionJson = cardMap["protocolVersion"];
    string protocolVersion = versionJson is string ? versionJson : "0.3";

    json[] interfaces = [];
    string[] seen = [];

    // The preferred interface goes first: selection takes the earliest
    // serviceable entry, and specification section 5.6.4 says a client
    // SHOULD use the main url when it can speak preferredTransport.
    json? preferredJson = cardMap["preferredTransport"];
    string preferred = preferredJson is string ? preferredJson : "JSONRPC";
    json? urlJson = cardMap["url"];
    if urlJson is string {
        interfaces.push({url: urlJson, protocolBinding: preferred, protocolVersion});
        seen.push(string `${preferred}|${urlJson}`);
    }

    // additionalInterfaces SHOULD repeat the main url's transport "for
    // completeness" per the v0.3 schema, so entries already added above are
    // dropped rather than duplicated into the ordered list.
    json? additional = cardMap["additionalInterfaces"];
    if additional is json[] {
        foreach json entry in additional {
            if entry !is map<json> {
                continue;
            }
            json? entryUrl = entry["url"];
            json? entryTransport = entry["transport"];
            if entryUrl !is string || entryTransport !is string {
                continue;
            }
            string key = string `${entryTransport}|${entryUrl}`;
            if seen.indexOf(key) is int {
                continue;
            }
            interfaces.push({url: entryUrl, protocolBinding: entryTransport, protocolVersion});
            seen.push(key);
        }
    }

    if interfaces.length() > 0 {
        cardMap["supportedInterfaces"] = interfaces;
    }
}

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
    normalizeLegacyInterfaces(cardMap);

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

# Fetches and parses a remote agent's Agent Card from its well-known
# endpoint.
#
# Per spec 8.2 the canonical discovery path is
# /.well-known/agent-card.json relative to the agent's base URL. That
# endpoint is public and unauthenticated by design (spec 14.3), so the
# headers parameter is for proxy or tracing use rather than credentials.
#
# This always fetches fresh. An earlier ETag-aware conditional-GET variant
# was removed before release - see issue #14.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers
# + return - The parsed AgentCard, or an error. Note this is a bare
#            `error` rather than a narrowed A2A error union: raw
#            un-wrapped http/JSON errors (connection failures, malformed
#            JSON) propagate via `check` alongside the typed
#            A2AInternalError constructed here, so a caller needing to
#            tell them apart must pattern-match on the concrete type.
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
    return parseAgentCardBody(body);
}

# The A2A transport bindings this library can speak.
#
# Not public: with Client taking its binding from the Agent Card rather
# than from a parameter, this name appears in no public signature. A caller
# selects a binding by choosing JsonRpcClient, RestClient, or GrpcClient,
# never by naming one.
type TransportBinding "JSONRPC"|"HTTP+JSON"|"GRPC";

# Resolves the whole matched AgentInterface for a preferred binding, not
# just its url — callers need the interface's own tenant and
# protocolVersion, which must come from the same entry the url did, not
# be independently re-derived (a card can list several interfaces with
# different tenant/version values).
#
# Among multiple entries declaring the same protocolBinding, the earliest
# on the card wins. Per spec 8.3.2 the supportedInterfaces array is ordered
# by the server's own preference — "the first entry represents the
# preferred interface", and a client should "prefer earlier entries in the
# ordered list" — so the order is the server's decision to make, not this
# library's to second-guess. The reference Java SDK reads it the same way,
# keeping only the first entry per binding.
#
# + card - the agent card to read the endpoint from
# + preferredBinding - which transport binding to look for; defaults to
#                      "JSONRPC", preserving every existing single-binding
#                      caller's behavior unchanged
# + return - the best-ranked supportedInterfaces entry declaring the
#            matching protocolBinding, or an error if none exists. The
#            legacy top-level url field is never treated as a match for
#            "HTTP+JSON" — it predates that binding entirely — so only
#            "JSONRPC" callers fall back to it (see primaryUrl)
isolated function selectInterface(
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
isolated function primaryUrl(
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

# Normalizes a non-normative grpc://\grpcs:// scheme (observed in the wild
# on some AgentCards) to the http://\https:// form grpc:Client actually
# accepts. A conformant card's GRPC interface url is already http(s), in
# which case this is a no-op.
#
# + url - the GRPC interface's url, as published on the AgentCard
# + return - the url with any grpc/grpcs scheme rewritten to http/https
isolated function normalizeGrpcSchemeUrl(string url) returns string {
    if url.startsWith("grpcs://") {
        return "https://" + url.substring(8);
    }
    if url.startsWith("grpc://") {
        return "http://" + url.substring(7);
    }
    return url;
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

# Chooses which transport binding to speak, from the Agent Card alone.
#
# Per spec section 8.3.2 the card decides, not the client: "select the
# first supported transport", preferring "earlier entries in the ordered
# list", because supportedInterfaces is ordered by the server's own
# preference and "the first entry represents the preferred interface".
# So this walks the card in order and takes the first binding this library
# can speak, rather than consulting any preference of its own.
#
# A caller who does want to express a preference constructs
# JsonRpcClient/RestClient/GrpcClient directly - that is what the
# transport-specific types are for, and why this client takes no binding
# parameter to override the card with.
#
# + card - the resolved Agent Card
# + return - the binding to use, or an error if the card declares no
#            interface this library can speak
isolated function selectBindingFromCard(AgentCard card) returns TransportBinding|error {
    foreach AgentInterface iface in card.supportedInterfaces {
        string declared = iface.protocolBinding;
        if declared != "JSONRPC" && declared != "HTTP+JSON" && declared != "GRPC" {
            continue;
        }
        TransportBinding binding = <TransportBinding>declared;
        // "First *supported* transport" has to mean supported in practice,
        // not merely a binding name this library recognises. v0.3 defines
        // all three bindings, but this library implements v0.3 over
        // JSON-RPC only, so a v0.3 REST or gRPC interface is something the
        // matching client would reject at construction.
        // Skipping it here lets a card that lists one ahead of a
        // serviceable interface still connect, instead of failing outright
        // on an entry no client could ever have used.
        //
        // The mode is resolved per binding rather than off this entry, so
        // the judgement matches exactly what the concrete client will
        // resolve: both go through selectInterface, which takes the first
        // interface declaring that binding.
        if binding == "JSONRPC" || detectProtocolModeForBinding(card, binding) == "V1_0" {
            return binding;
        }
    }
    // A pre-1.0 card may declare no interfaces at all, only a top-level
    // url, which predates every binding but JSON-RPC.
    //
    // Guarded on the list being empty, which is what the fallback was always
    // described as covering. Unguarded, it also fired when the card DID
    // declare interfaces and none of them were serviceable — answering
    // "JSONRPC" for a card whose url is a gRPC or REST endpoint. That was
    // unreachable while v0.3 cards parsed with an empty list; normalizing
    // their transports makes it reachable, and wrong.
    if card.supportedInterfaces.length() == 0 && card?.url is string {
        return "JSONRPC";
    }
    return error(
        "AgentCard declares no supportedInterfaces entry this library can speak (JSONRPC, HTTP+JSON, or GRPC) and no legacy url field");
}

# Constructs the transport-specific client for a chosen binding, handing it
# the already-resolved card so it is not fetched a second time.
#
# + card - the already-resolved Agent Card
# + binding - the binding chosen from that card
# + clientConfig - as accepted by every client type
# + headers - as accepted by every client type
# + tenant - as accepted by every client type
# + requestedExtensions - as accepted by every client type
# + maxReconnectAttempts - as accepted by every client type
# + return - the constructed client, or an error from its own construction
isolated function buildDelegate(
        AgentCard card,
        TransportBinding binding,
        http:ClientConfiguration clientConfig,
        map<string> headers,
        string? tenant,
        string[] requestedExtensions,
        int maxReconnectAttempts) returns AgentClient|error {
    if binding == "HTTP+JSON" {
        return new RestClient(card, clientConfig, headers, tenant, requestedExtensions, maxReconnectAttempts);
    }
    if binding == "GRPC" {
        return new GrpcClient(card, clientConfig, headers, tenant, requestedExtensions, maxReconnectAttempts);
    }
    return new JsonRpcClient(card, clientConfig, headers, tenant, requestedExtensions, maxReconnectAttempts);
}

# An A2A protocol client that speaks whichever transport binding the agent
# prefers.
#
# Resolves the Agent Card, reads the binding the card lists first, builds
# the matching transport-specific client, and delegates every operation to
# it. Binding selection happens once, at construction - there is no
# per-call dispatch.
#
# ```ballerina
# a2a:Client agent = check new ("https://agent.example.com");
# a2a:Task|a2a:Message reply = check agent->sendMessage(msg);
# ```
#
# There is deliberately no `binding` parameter. Expressing a client-side
# preference is what the transport-specific types are for: construct
# `JsonRpcClient`, `RestClient`, or `GrpcClient` directly and the card's
# ordering is bypassed. Use this type when the agent's own preference
# should win, which is the spec's default (section 8.3.2).
#
# Since all four types implement `AgentClient`, code that does not care can
# hold the interface and be handed either.
#
# LIFECYCLE: there is deliberately no `close`. Unlike the reference a2a-sdk
# (Python), whose `Client.close()` disposes the `httpx.AsyncClient` it was
# handed, a Ballerina `http:Client` holds no per-instance connection state to
# dispose: it routes through the process-wide `globalHttpClientConnPool`, which
# evicts idle connections on its own. Neither `http:Client` nor `grpc:Client`
# exposes a client-side close for this reason, so there is no underlying call
# to make. The A2A specification says nothing about client resource release
# either - it governs the wire, not SDK object lifetimes.
#
# A Client is therefore cheap to construct and needs no teardown. Two caveats
# worth knowing:
#
# - Prefer one long-lived Client per agent over constructing one per request.
#   Construction still builds an `http:Client` (and, for the GRPC binding, a
#   gRPC channel), which is wasted work per call even though it leaks nothing.
# - Setting `poolConfig` inside `clientConfig` opts that Client out of the
#   shared pool and gives it a private one, which *cannot* be released. If you
#   do that, reuse the Client - do not create them per request.
public isolated client class Client {
    *AgentClient;

    private final AgentClient delegate;

    # Creates a client pointed at a remote A2A agent, speaking whichever
    # binding the agent's card prefers.
    #
    # Accepts either the agent's base URL or an already-resolved AgentCard.
    # Given a URL the card is always resolved first: it is what determines
    # the binding, the service URL, the protocol version, and the tenant.
    # Given a card, it is passed straight to the transport-specific client,
    # so it is never fetched twice.
    #
    # + agent - the agent's base URL, or an AgentCard already resolved via
    #           resolveAgentCard
    # + clientConfig - Full http:ClientConfiguration. Covers auth, TLS,
    #                  retry, circuit breaker, proxy, timeouts, and
    #                  connection pooling.
    # + headers - Default headers merged into every outbound request
    # + tenant - Optional multi-tenant routing identifier; the selected
    #            interface supplies one automatically when it declares it,
    #            and an explicit value wins
    # + requestedExtensions - Optional A2A extension URIs to request
    # + maxReconnectAttempts - Opt-in automatic stream reconnection
    # + return - an error from resolveAgentCard, if the card declares no
    #            binding this library can speak, or from the underlying
    #            transport-specific client's own construction
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
        TransportBinding binding = check selectBindingFromCard(card);
        self.delegate = check buildDelegate(
                card, binding, clientConfig, headers, tenant,
                requestedExtensions, maxReconnectAttempts);
    }

    public isolated function lastGrantedExtensions() returns string[] {
        return self.delegate.lastGrantedExtensions();
    }

    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|error {
        return self.delegate->sendMessage(message, config, tenant, metadata);
    }

    isolated remote function sendStreamingMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|error {
        return self.delegate->sendStreamingMessage(message, config, tenant, metadata);
    }

    isolated remote function getTask(
            string taskId,
            int? historyLength = (),
            string? tenant = ()) returns Task|error {
        return self.delegate->getTask(taskId, historyLength, tenant);
    }

    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|error {
        return self.delegate->cancelTask(taskId, metadata, tenant);
    }

    isolated remote function subscribeToTask(
            string taskId,
            string? tenant = ()) returns stream<StreamResponse, error?>|error {
        return self.delegate->subscribeToTask(taskId, tenant);
    }

    isolated remote function listTasks(
            ListTasksFilter? filter = (),
            string? tenant = ()) returns ListTasksResult|error {
        return self.delegate->listTasks(filter, tenant);
    }

    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        return self.delegate->createTaskPushNotificationConfig(config, tenant);
    }

    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|error {
        return self.delegate->getTaskPushNotificationConfig(taskId, id, tenant);
    }

    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error {
        return self.delegate->listTaskPushNotificationConfigs(taskId, pageSize, pageToken, tenant);
    }

    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns error? {
        return self.delegate->deleteTaskPushNotificationConfig(taskId, id, tenant);
    }

    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error {
        return self.delegate->getExtendedAgentCard(tenant);
    }
}
