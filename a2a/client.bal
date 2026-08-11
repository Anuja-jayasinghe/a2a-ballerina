// A2A client implementation.

import ballerina/a2a.grpcstub;
import ballerina/a2a.transport;
import ballerina/grpc;
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
public type TransportBinding "JSONRPC"|"HTTP+JSON"|"GRPC";

# Ranks an AgentInterface's protocolVersion for selectInterface's
# preference order, per the comparison against the reference Python SDK's
# _find_best_interface: exactly "1.0" first, then anything newer, then the
# "0.x" pre-1.0 tier, then unversioned last (never a hard error, since one
# odd version string on a card shouldn't fail selection).
#
# + protocolVersion - the interface's protocolVersion field, if any
# + return - higher is more preferred
isolated function protocolVersionRank(string? protocolVersion) returns int {
    if protocolVersion is () {
        return 0;
    }
    if protocolVersion == "1.0" {
        return 3;
    }
    string[] parts = re `\.`.split(protocolVersion);
    if parts.length() >= 1 {
        int|error major = int:fromString(parts[0]);
        if major is int {
            int minor = 0;
            if parts.length() >= 2 {
                int|error parsedMinor = int:fromString(parts[1]);
                if parsedMinor is int {
                    minor = parsedMinor;
                }
            }
            if major > 1 || (major == 1 && minor > 0) {
                return 2;
            }
            if major >= 0 {
                return 1;
            }
        }
    }
    return 0;
}

# Resolves the whole matched AgentInterface for a preferred binding, not
# just its url — callers need the interface's own tenant and
# protocolVersion, which must come from the same entry the url did, not
# be independently re-derived (a card can list several interfaces with
# different tenant/version values).
#
# Among multiple entries declaring the same protocolBinding, the one whose
# protocolVersion ranks highest per protocolVersionRank wins — not simply
# the first one on the card — so a card's supportedInterfaces ordering
# can't silently downgrade the protocol version a caller ends up talking.
# Ties (including cards with only one matching entry, the common case)
# keep the first-seen entry, so every single-entry-per-binding card
# behaves exactly as before.
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
    AgentInterface? best = ();
    int bestRank = -1;
    foreach AgentInterface iface in card.supportedInterfaces {
        if iface.protocolBinding == preferredBinding {
            int rank = protocolVersionRank(iface?.protocolVersion);
            if rank > bestRank {
                best = iface;
                bestRank = rank;
            }
        }
    }
    if best is AgentInterface {
        return best;
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

# Creates a Client from whichever of a URL or an already-resolved AgentCard
# the caller has in hand — never both. Which one varies by the discovery
# mechanism in use: a caller who only has a base URL lets newClient resolve
# the card itself; a caller who already resolved (or otherwise obtained) a
# card passes it directly and skips the extra round trip. Either way, the
# service URL is derived internally via primaryUrl/selectInterface rather
# than re-supplied by the caller, closing the double-pass this replaces
# (`card = check resolveAgentCard(url); client = check new (url, ...,
# agentCard = card)`).
#
# newClient is the recommended entry point for the common case — you have a
# URL or a card and want the SDK to derive the rest. It is not the only
# supported construction path, and `new (serviceUrl, ..., agentCard = card)`
# is not a deprecated fallback: it remains a fully supported, independently
# public low-level constructor, both for callers who've already resolved
# every argument themselves and for the cases where the client genuinely
# needs to point at a different URL than the one the card declares —
# proxies, tests, or a card with several interfaces where a non-preferred
# one is wanted deliberately. This mirrors how the reference `a2a-sdk`
# (Python) keeps its low-level `BaseClient` constructor fully public
# alongside the `create_client`/`ClientFactory` convenience layer, and how
# the Java SDK's `ClientBuilder` is itself a complete, independently usable
# public entry point rather than something the higher-level API hides.
#
# + agent - a base URL to discover the agent at, or an AgentCard already
#           resolved for it
# + clientConfig - Full http:ClientConfiguration, as accepted by Client.init.
#                  When agent is a URL, also used for the resolveAgentCard
#                  call that fetches the card
# + headers - Default headers, as accepted by Client.init. When agent is a
#             URL, also sent on the resolveAgentCard fetch
# + tenant - Optional multi-tenant routing identifier. When left unset and
#            the selected AgentInterface declares a tenant value, that
#            value is used automatically instead of requiring the caller to
#            copy it by hand; an explicitly-passed tenant always wins
# + requestedExtensions - as accepted by Client.init
# + maxReconnectAttempts - as accepted by Client.init
# + binding - Which transport binding this Client speaks, and which
#             supportedInterfaces entry to derive the service URL (and
#             default tenant) from. Defaults to "JSONRPC"
# + return - the constructed Client, or an error — propagated unchanged
#            from resolveAgentCard (when agent is a URL: unreachable
#            endpoint, non-200 status, or a body that doesn't parse as an
#            AgentCard), from primaryUrl (no supportedInterfaces entry
#            matching binding and no legacy url field to fall back to), or
#            from Client.init itself (see its own + return doc)
public isolated function newClient(
        AgentCard|string agent,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        string? tenant = (),
        string[] requestedExtensions = [],
        int maxReconnectAttempts = 0,
        TransportBinding binding = "JSONRPC") returns Client|error {
    AgentCard card = agent is string ? check resolveAgentCard(agent, clientConfig, headers) : agent;
    string serviceUrl = check primaryUrl(card, binding);
    string? effectiveTenant = tenant;
    if effectiveTenant is () {
        AgentInterface|error iface = selectInterface(card, binding);
        if iface is AgentInterface {
            effectiveTenant = iface?.tenant;
        }
    }
    return new Client(serviceUrl, clientConfig, headers, effectiveTenant, card,
        requestedExtensions, maxReconnectAttempts, binding);
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

# An A2A protocol client for calling remote agents.
#
# LIFECYCLE: there is deliberately no `close`. Unlike the reference a2a-sdk
# (Python), whose `Client.close()` disposes the `httpx.AsyncClient` it was
# handed, a Ballerina `http:Client` holds no per-instance connection state to
# dispose: it routes through the process-wide `globalHttpClientConnPool`, which
# evicts idle connections on its own. Neither `http:Client` nor `grpc:Client`
# exposes a client-side close for this reason, so there is no underlying call
# to make. The A2A specification says nothing about client resource release
# either — it governs the wire, not SDK object lifetimes.
#
# A Client is therefore cheap to construct and needs no teardown. Two caveats
# worth knowing:
#
# - Prefer one long-lived Client per agent over constructing one per request.
#   Construction still builds an `http:Client` (and, for the GRPC binding, a
#   gRPC channel), which is wasted work per call even though it leaks nothing.
# - Setting `poolConfig` inside `clientConfig` opts that Client out of the
#   shared pool and gives it a private one, which *cannot* be released. If you
#   do that, reuse the Client — don't create them per request.
public isolated client class Client {
    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;
    private final ProtocolMode mode;
    private final string[] & readonly requestedExtensions;
    private string[] grantedExtensions = [];
    private final int maxReconnectAttempts;
    private final TransportBinding binding;
    private final grpcstub:A2AServiceClient? grpcStub;
    # The most recent AgentCard this client knows about: the one supplied to
    # init, replaced by the extended card once getExtendedAgentCard fetches
    # one. Mutable (hence lock-guarded, like grantedExtensions) precisely so
    # that fetching an extended card updates what later calls reason about,
    # rather than leaving them on the public card forever.
    private AgentCard? agentCard;

    # Creates a client pointed at a remote A2A agent.
    #
    # This is the low-level constructor: it takes a concrete serviceUrl and
    # treats agentCard as an independent, optional argument that is never
    # used to derive the URL. For the common case — construct from a URL or
    # an already-resolved AgentCard, letting the SDK derive the rest — see
    # newClient instead. This constructor stays fully public and is not a
    # legacy path superseded by newClient: it's the right choice when the
    # caller has already resolved every argument itself, or needs to point
    # at a URL that deliberately differs from what an AgentCard declares
    # (proxies, tests, a non-preferred interface). newClient is implemented
    # in terms of this constructor, not a replacement for it — matching how
    # the reference `a2a-sdk` (Python) keeps its low-level `BaseClient`
    # constructor fully public alongside its `create_client` convenience
    # layer, and how the Java SDK's `ClientBuilder` is a complete,
    # independently usable public entry point in its own right.
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
    # + maxReconnectAttempts - Opt-in automatic SSE reconnection. When 0
    #                          (the default), sendStreamingMessage and
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
    #            if binding is "HTTP+JSON" and agentCard resolves to A2A v0.3
    public isolated function init(
            string serviceUrl,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            AgentCard? agentCard = (),
            string[] requestedExtensions = [],
            int maxReconnectAttempts = 0,
            TransportBinding binding = "JSONRPC") returns error? {
        // http:ClientConfiguration isn't Cloneable (some of its fields
        // aren't pure data), so a mapping-constructor spread is used
        // instead of .clone() to shallow-copy it — otherwise this could
        // mutate the caller's own clientConfig in place, corrupting it for
        // any other Client.init call that reuses the same variable.
        http:ClientConfiguration effectiveClientConfig = {...clientConfig};
        map<string> effectiveHeaders = headers.clone();
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
        if self.mode == "V0_3" && binding == "GRPC" {
            return error VersionNotSupportedError(
                "A2A protocol v0.3 has no gRPC binding equivalent",
                message = "A2A protocol v0.3 has no gRPC binding equivalent"
            );
        }
        if binding == "GRPC" {
            grpc:ClientConfiguration grpcConfig = check projectToGrpcClientConfig(effectiveClientConfig);
            self.grpcStub = check new (normalizeGrpcSchemeUrl(serviceUrl), grpcConfig);
        } else {
            self.grpcStub = ();
        }
        self.requestedExtensions = requestedExtensions.cloneReadOnly();
        self.maxReconnectAttempts = maxReconnectAttempts;
        self.agentCard = agentCard is AgentCard ? agentCard.clone() : ();
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
            "A2A-Version": self.mode == "V0_3" ? "0.3" : "1.0"
        };
        if self.binding != "GRPC" {
            headers["Content-Type"] = "application/json";
        }
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
    # self.grantedExtensions. Shared by rpcCall and openEventStream, since
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
        if self.binding == "GRPC" {
            return self.grpcCall(method, params);
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

    # Performs one gRPC binding call and returns the unwrapped result,
    # matching rpcCall's contract. Uses the generated *Context method
    # variants exclusively (never the plain ones) so response metadata —
    # specifically A2A-Extensions — is reachable; see design spec Design
    # decision 4.
    #
    # + method - the JSON-RPC-style method name (see encodeGrpcRequest)
    # + params - the same params map the JSON-RPC binding would build
    # + return - the unwrapped result json, or a typed A2AError
    private isolated function grpcCall(string method, map<json> params) returns json|error {
        grpcstub:A2AServiceClient stub = <grpcstub:A2AServiceClient>self.grpcStub;
        anydata req = check encodeGrpcRequest(method, params);
        map<string|string[]> headers = self.buildHeaders();
        anydata|grpc:Error response = self.dispatchGrpcContextCall(stub, method, req, headers);
        if response is grpc:Error {
            return toA2AErrorFromGrpc(response);
        }
        return decodeGrpcResponse(method, response);
    }

    # Dispatches to the correct generated *Context method for one unary
    # operation. A single match here (rather than a match inline in
    # grpcCall) keeps grpcCall's own control flow readable and gives the
    # streaming adapter (Task 14) an obvious place alongside this to add
    # its own two streaming-operation cases without touching this one.
    #
    # Every generated *Context remote function takes a single parameter —
    # a union of the plain request type or the corresponding
    # `grpcstub:Context{Operation}Request` wrapper record (`{content,
    # headers}`) — not a separate trailing headers parameter as originally
    # predicted. Outbound metadata is therefore sent by constructing that
    # wrapper record here, not by passing headers positionally. Confirmed
    # against the real generated `a2a/modules/grpcstub/a2a_pb.bal`.
    #
    # + stub - the generated gRPC client stub
    # + method - the JSON-RPC-style method name
    # + req - the typed grpcstub request value from encodeGrpcRequest
    # + headers - outbound metadata (A2A-Version, A2A-Extensions, auth headers)
    # + return - the typed grpcstub response value, or a grpc:Error
    private isolated function dispatchGrpcContextCall(
            grpcstub:A2AServiceClient stub, string method, anydata req,
            map<string|string[]> headers) returns anydata|grpc:Error {
        match method {
            "SendMessage" => {
                var result = stub->SendMessageContext({content: <grpcstub:SendMessageRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "GetTask" => {
                var result = stub->GetTaskContext({content: <grpcstub:GetTaskRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "CancelTask" => {
                var result = stub->CancelTaskContext({content: <grpcstub:CancelTaskRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "ListTasks" => {
                var result = stub->ListTasksContext({content: <grpcstub:ListTasksRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "CreateTaskPushNotificationConfig" => {
                var result = stub->CreateTaskPushNotificationConfigContext({content: <grpcstub:TaskPushNotificationConfig>req, headers});
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "GetTaskPushNotificationConfig" => {
                var result = stub->GetTaskPushNotificationConfigContext({content: <grpcstub:GetTaskPushNotificationConfigRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "ListTaskPushNotificationConfigs" => {
                var result = stub->ListTaskPushNotificationConfigsContext({content: <grpcstub:ListTaskPushNotificationConfigsRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            "DeleteTaskPushNotificationConfig" => {
                var result = stub->DeleteTaskPushNotificationConfigContext({content: <grpcstub:DeleteTaskPushNotificationConfigRequest>req, headers});
                if result is grpc:Error {
                    return result;
                }
                self.captureGrantedExtensionsFromGrpc(result.headers);
                // google.protobuf.Empty (empty:ContextNil) carries no
                // `content` field at all -- decodeGrpcResponse's
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
                self.captureGrantedExtensionsFromGrpc(result.headers);
                return result.content;
            }
            _ => {
                return error grpc:InternalError(string `no gRPC dispatch for unary method "${method}"`);
            }
        }
    }

    # gRPC analogue of captureGrantedExtensions — reads A2A-Extensions off
    # response metadata instead of an http:Response header, per design
    # spec Design decision 4 (only the *Context method variants surface
    # response metadata at all).
    #
    # Unlike http:Response.getHeader (case-insensitive), a map<string|
    # string[]> key lookup in Ballerina is exact-match. HTTP/2 mandates
    # lowercase header/metadata field names at the protocol level (RFC
    # 7540 §8.1.2), so a real, spec-conformant gRPC server sends this
    # metadata key as "a2a-extensions", not "A2A-Extensions" — the same
    # casing issue already fixed for outbound headers (see
    # testClientGrpcSendsMandatoryA2AVersionHeader, which asserts against
    # "a2a-version"). This scans entries for a case-insensitive match
    # instead of doing an exact-match lookup, so it actually finds the
    # header a real server sends.
    #
    # + headers - the response metadata from a *Context call
    private isolated function captureGrantedExtensionsFromGrpc(map<string|string[]> headers) {
        string|string[]? extHeader = ();
        foreach [string, string|string[]] [k, v] in headers.entries() {
            if k.toLowerAscii() == "a2a-extensions" {
                extHeader = v;
                break;
            }
        }
        string[] granted = [];
        if extHeader is string && extHeader.length() > 0 {
            foreach string entry in re `,`.split(extHeader) {
                granted.push(entry.trim());
            }
        } else if extHeader is string[] {
            granted = extHeader;
        }
        lock {
            self.grantedExtensions = granted.clone();
        }
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
        json messageJson = self.mode == "V0_3" ? check encodeV03Message(message) : encodeRawBytesForWire(message.toJson());
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
        SendMessageResult wrapped = check (check decodeRawBytesFromWire(result)).cloneWithType(SendMessageResult);
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
    # readSseStream. Shared by sendStreamingMessage and subscribeToTask.
    #
    # + method - the JSON-RPC method name
    # + params - the JSON-RPC method parameters
    # + return - a stream of StreamResponse values, or an error
    private isolated function openEventStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        if self.binding == "GRPC" {
            return self.openGrpcStream(method, params);
        }
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

    # Opens a gRPC streaming call and wraps it in a GrpcStreamAdapter.
    #
    # Uses the generated *Context method variants exclusively (never the
    # plain ones), matching grpcCall's rationale, so response metadata —
    # specifically A2A-Extensions — is reachable; see design spec Design
    # decision 4. Every generated *Context streaming remote function takes
    # a single parameter — a union of the plain request type or the
    # corresponding `grpcstub:Context{Operation}Request` wrapper record
    # (`{content, headers}`) — not a separate trailing headers parameter,
    # confirmed against the real generated `a2a/modules/grpcstub/a2a_pb.bal`
    # (same finding as dispatchGrpcContextCall for the unary methods).
    #
    # + method - "SendStreamingMessage" or "SubscribeToTask"
    # + params - the same params map the JSON-RPC binding would build
    # + return - a stream of StreamResponse values, or a typed A2AError
    private isolated function openGrpcStream(string method, map<json> params) returns stream<StreamResponse, error?>|error {
        grpcstub:A2AServiceClient stub = <grpcstub:A2AServiceClient>self.grpcStub;
        anydata req = check encodeGrpcRequest(method, params);
        map<string|string[]> headers = self.buildHeaders();
        if method == "SendStreamingMessage" {
            grpcstub:ContextStreamResponseStream|grpc:Error result =
                stub->SendStreamingMessageContext({content: <grpcstub:SendMessageRequest>req, headers});
            if result is grpc:Error {
                return toA2AErrorFromGrpc(result);
            }
            self.captureGrantedExtensionsFromGrpc(result.headers);
            stream<StreamResponse, error?> wrapped = new (new GrpcStreamAdapter(result.content));
            return wrapped;
        }
        grpcstub:ContextStreamResponseStream|grpc:Error result =
            stub->SubscribeToTaskContext({content: <grpcstub:SubscribeToTaskRequest>req, headers});
        if result is grpc:Error {
            return toA2AErrorFromGrpc(result);
        }
        self.captureGrantedExtensionsFromGrpc(result.headers);
        stream<StreamResponse, error?> wrapped = new (new GrpcStreamAdapter(result.content));
        return wrapped;
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
    isolated remote function sendStreamingMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|error {
        json messageJson = self.mode == "V0_3" ? check encodeV03Message(message) : encodeRawBytesForWire(message.toJson());
        map<json> params = {"message": messageJson};
        if config is SendMessageConfiguration {
            params["configuration"] = self.mode == "V0_3" ? encodeV03SendConfiguration(config) : config.toJson();
        }
        if metadata is map<json> {
            params["metadata"] = metadata;
        }
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }
        stream<StreamResponse, error?> rawStream = check self.openEventStream("SendStreamingMessage", params);
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
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }
        json result = check self.rpcCall("GetTask", params);
        return self.mode == "V0_3" ? check parseV03Task(result) : check (check decodeRawBytesFromWire(result)).cloneWithType(Task);
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
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }
        json result = check self.rpcCall("CancelTask", params);
        return self.mode == "V0_3" ? check parseV03Task(result) : check (check decodeRawBytesFromWire(result)).cloneWithType(Task);
    }

    # Opens a stream on an existing task.
    #
    # The primary use is recovering from a dropped sendStreamingMessage
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
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }
        return self.openEventStream("SubscribeToTask", params);
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
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("ListTasks", params);
        return check (check decodeRawBytesFromWire(result)).cloneWithType(ListTasksResult);
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
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
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
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
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
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
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
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
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
    # When this Client holds an AgentCard (one was passed to init, or a
    # previous call to this method fetched one) and that card declares
    # capabilities.extendedAgentCard as false, the held card is returned
    # directly and no request is sent: the card has already said the endpoint
    # isn't there, so calling it only converts a knowable no-op into a server
    # error. This matches the reference a2a-sdk (Python), whose
    # BaseClient.get_extended_agent_card returns the card it already holds in
    # exactly this case. A Client constructed without a card can't know, so it
    # still makes the call.
    #
    # On a successful fetch the returned card replaces the held one, so a
    # later call reflects the extended card rather than the public card the
    # Client started with.
    #
    # + tenant - Optional per-call tenant override
    # + return - The extended AgentCard, the already-held card when that card
    #            declares no extended-card support, or an error
    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error {
        lock {
            AgentCard? held = self.agentCard;
            if held is AgentCard && !held.capabilities.extendedAgentCard {
                return held.clone();
            }
        }

        map<json> params = {};
        string? effectiveTenant = tenant ?: self.tenant;
        // tenant routing: v0.3 has no wire counterpart, see the comment in sendMessage above.
        if effectiveTenant is string && self.mode == "V1_0" {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("GetExtendedAgentCard", params);
        AgentCard fetched = check parseAgentCardBody(result);
        lock {
            self.agentCard = fetched.clone();
        }
        return fetched;
    }
}
