// Agent Card resolution, interface selection, and the common Client that
// delegates to whichever transport-specific client the card prefers.
//
// The transport marshaling that used to live here now sits with the client
// that owns it: jsonrpc_client.bal, rest_client.bal, grpc_client.bal.

import ballerina/http;

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

# Maps a pre-v1.0 card's top-level `supportsAuthenticatedExtendedCard`
# field onto v1.0's `capabilities.extendedAgentCard`, in place on the raw
# card map.
#
# v0.3 declares this capability as a sibling of `url`/`capabilities`, not
# nested inside `capabilities` itself (confirmed against the Java SDK's
# v0.3 compat test fixtures - the reference a2a-python SDK performs the
# same mapping in its own card parser). Left untranslated, it lands in
# the open record's rest field and is never read:
# `capabilities.extendedAgentCard` stays at its default `false`, so
# `getExtendedAgentCard` on every one of the three transport clients
# short-circuits and returns the held card instead of ever fetching the
# real extended one - a v0.3 agent that genuinely supports extended
# cards would have that support permanently invisible to this client.
#
# Only ever sets the flag to `true`: an absent or `false` legacy field
# means nothing to say, since `extendedAgentCard`'s own default is
# already `false`. A v1.0-native card has no `supportsAuthenticatedExtendedCard`
# field at all, so this is a no-op for it.
#
# + cardMap - the raw card map, mutated in place
isolated function normalizeLegacyExtendedCardSupport(map<json> cardMap) {
    json? legacyJson = cardMap["supportsAuthenticatedExtendedCard"];
    if legacyJson != true {
        return;
    }
    json? capabilitiesJson = cardMap["capabilities"];
    if capabilitiesJson is map<json> {
        capabilitiesJson["extendedAgentCard"] = true;
    } else {
        cardMap["capabilities"] = {extendedAgentCard: true};
    }
}

# Parses a raw AgentCard JSON body into a typed AgentCard, applying the
# v0.3 security field-name rename and the tolerant parsing of
# securitySchemes, securityRequirements, signatures, and each skill's
# securityRequirements before the main typed clone, so neither a
# v0.3-dialect card nor a card carrying one malformed entry in any of
# those four fields fails to parse entirely.
#
# Public so a caller who separately fetched the raw body via
# fetchAgentCardBody (typically to verify its signature first, via
# signature.bal) can still get the typed AgentCard afterward without a
# second network round trip.
#
# + body - the raw JSON AgentCard body, straight off the wire
# + return - the parsed AgentCard, or an error if the remainder of the
#            card (everything but the four tolerantly-parsed fields)
#            doesn't match the AgentCard shape
public isolated function parseAgentCardBody(json body) returns AgentCard|error {
    json renamed = renameV03SecurityField(body);
    map<json> cardMap = check renamed.ensureType();
    normalizeLegacyInterfaces(cardMap);
    normalizeLegacyExtendedCardSupport(cardMap);

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

# Fetches a remote agent's Agent Card as raw, unparsed JSON from its
# well-known endpoint.
#
# Per spec 8.2 the canonical discovery path is
# /.well-known/agent-card.json relative to the agent's base URL. That
# endpoint is public and unauthenticated by design (spec 14.3), so the
# headers parameter is for proxy or tracing use rather than credentials.
#
# This always fetches fresh. For conditional-GET reuse of a previous
# fetch, see resolveAgentCardCached - kept separate rather than folded in
# here since caching needs the response's ETag header and 304 handling,
# neither of which the json-only return type below can express.
#
# Exists as its own function, separate from resolveAgentCard, because
# verifyAgentCardSignature (signature.bal) needs the response exactly as
# received: canonicalizing a parsed AgentCard record instead would inject
# every field's Ballerina-side default (e.g. requestedExtensions = [],
# securitySchemes = {}) whether or not the signer actually included it,
# guaranteeing signature verification failure against a spec-conformant
# signer. Most callers still want resolveAgentCard's typed result;
# reach for this only when the raw body itself is needed.
#
# A card's own `url` field commonly carries a trailing slash (nothing in
# the spec forbids it), and callers are expected to pass that value
# straight back in as `agentBaseUrl` on a follow-up resolve — see
# `Client.init`, which does exactly this. Without stripping it here,
# `http:Client` joins a base ending in `/` with a request path starting
# in `/.well-known/...` into a double slash, which 404s against every
# well-known-endpoint server tested (confirmed against a real agent
# whose card declares `url: "http://host:port/"`). Both discovery
# entry points share this helper since both hit the same join.
#
# + url - a base URL, possibly with a trailing slash
# + return - the same URL with any single trailing slash removed
isolated function stripTrailingSlash(string url) returns string {
    if url.endsWith("/") {
        return url.substring(0, url.length() - 1);
    }
    return url;
}

# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers
# + return - The raw JSON AgentCard body exactly as received, or an
#            error. Note this is a bare `error` rather than a narrowed
#            A2A error union: raw un-wrapped http errors (connection
#            failures) propagate via `check` alongside the typed
#            A2AInternalError constructed here, so a caller needing to
#            tell them apart must pattern-match on the concrete type.
public isolated function fetchAgentCardBody(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns json|error {
    http:Client discoveryClient = check new (stripTrailingSlash(agentBaseUrl), clientConfig);
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
    return resp.getJsonPayload();
}

# Fetches and parses a remote agent's Agent Card from its well-known
# endpoint.
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
    json body = check fetchAgentCardBody(agentBaseUrl, clientConfig, headers);
    return parseAgentCardBody(body);
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
# server confirms nothing changed (HTTP 304), per standard HTTP caching.
#
# Spec 8.6.2 says clients "SHOULD cache Agent Cards locally to reduce
# network requests" but does not mandate a mechanism; ETag/If-None-Match
# is this library's own choice of standard HTTP caching to satisfy that
# SHOULD, opt-in and additive - resolveAgentCard's own behavior
# (always fetch fresh) is unchanged, and unaffected by whether a caller
# ever reaches for this function at all.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers
# + previous - A card previously returned by this function, to enable a
#              conditional (If-None-Match) request
# + return - The parsed AgentCard plus its caching metadata, or an error.
#            Note: like resolveAgentCard, this is a bare `error` rather
#            than a narrowed A2A error union - raw un-wrapped http/JSON
#            errors (connection failures, malformed JSON) propagate via
#            `check` alongside the typed A2AInternalError constructed
#            here, so a caller needing to tell them apart must
#            pattern-match on the concrete type.
public isolated function resolveAgentCardCached(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        CachedAgentCard? previous = ()) returns CachedAgentCard|error {
    http:Client discoveryClient = check new (stripTrailingSlash(agentBaseUrl), clientConfig);
    map<string> reqHeaders = {"A2A-Version": "1.0"};
    foreach [string, string] [k, v] in headers.entries() {
        reqHeaders[k] = v;
    }
    string? conditionalEtag = previous?.etag;
    if conditionalEtag is string {
        reqHeaders["If-None-Match"] = conditionalEtag;
    }
    http:Response resp = check discoveryClient->get(
        "/.well-known/agent-card.json", reqHeaders
    );
    if resp.statusCode == 304 && previous is CachedAgentCard {
        return previous;
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
    return {card, etag: etagHeader is string ? etagHeader : ()};
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
# accepts, and likewise a bare "host:port" with no scheme at all -- gRPC's
# own convention (e.g. `grpc.Dial("host:port")`) omits the scheme
# entirely, unlike HTTP. Confirmed against a real agent card (dice_agent,
# from a2a-samples' Java multi-transport reference): its GRPC interface
# publishes exactly this schemeless shape, which ballerina/grpc's client
# construction rejects outright ("Malformed URL") without this. A
# conformant card's GRPC interface url is already http(s), in which case
# this is a no-op.
#
# + url - the GRPC interface's url, as published on the AgentCard
# + return - the url with any grpc/grpcs scheme, or no scheme at all,
#            rewritten to http/https
isolated function normalizeGrpcSchemeUrl(string url) returns string {
    if url.startsWith("grpcs://") {
        return "https://" + url.substring(8);
    }
    if url.startsWith("grpc://") {
        return "http://" + url.substring(7);
    }
    if url.startsWith("http://") || url.startsWith("https://") {
        return url;
    }
    // Absence of a scheme carries no TLS signal either way, so this
    // defaults to http (unencrypted) - the same default "grpc://" above
    // already uses.
    return "http://" + url;
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
