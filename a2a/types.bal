// Spec-facing types for the A2A protocol.

import ballerina/lang.array;

public enum Role {
    ROLE_UNSPECIFIED,
    ROLE_USER,
    ROLE_AGENT
}

# One unit of content within a Message.
#
# Per specification section 4.1.6, exactly one of `text`, `raw`, `url`, or
# `data` is set. Version 1.0 removed the `kind` discriminator field in
# favour of member-presence detection — the variant is determined by which
# field is non-nil, not by a tag.
public type Part record {|
    # Text content
    string? text?;
    # Inline file bytes; base64 on the wire
    byte[]? raw?;
    # File by reference
    string? url?;
    # Arbitrary structured data
    json? data?;
    # Applies to file variants (raw/url)
    string? filename?;
    # MIME type; applies to all variants
    string? mediaType?;
    # Free-form metadata attached to this part
    map<json>? metadata?;
    // newer specification version can have additional fields
    json...;
|};

# The set of field names that can hold, directly or transitively, a Part
# (or a structure containing one) somewhere in the v1.0 type hierarchy:
# Message.parts, Artifact.parts, Task.history (Message[]), Task.artifacts
# (Artifact[]), TaskStatus.message, TaskStatusUpdateEvent.status,
# TaskArtifactUpdateEvent.artifact, StreamResponse.task/.message/
# .statusUpdate/.artifactUpdate, SendMessageResult.task/.message, and
# ListTasksResult.tasks. `encodeRawBytesForWire`/`decodeRawBytesFromWire`
# only ever recurse into these exact key names — this is what keeps the
# walkers from touching free-form fields such as `metadata` (map<json> on
# Message/Task/Artifact/the two update events) or a data-Part's own
# `data` field, even when those free-form trees happen to contain a key
# literally named "raw" that has nothing to do with Part.raw.
final readonly & string[] partBearingContainerKeys = [
    "history", "artifacts", "message", "status", "task", "statusUpdate",
    "artifactUpdate", "artifact", "tasks"
];

isolated function isPartBearingContainerKey(string k) returns boolean {
    return partBearingContainerKeys.indexOf(k) is int;
}

# Rewrites the "raw" field of each Part-shaped element of a `parts` array
# (as produced by Message.parts/Artifact.parts) from the integer-array
# shape Ballerina's default byte[] serialization produces into a base64
# string. Only ever touches the "raw" key directly on a Part object; a
# Part's own `data`/`metadata` fields are left completely untouched, so a
# data-Part whose arbitrary JSON payload happens to contain a "raw" key is
# never mistaken for Part.raw.
#
# + partsValue - the json value of a `parts` field; expected to be a
#                json[] of Part-shaped objects, but tolerates other shapes
#                by returning them unchanged
# + return - the same array with every Part.raw integer-array rewritten to
#            a base64 string
isolated function encodePartsRawField(json partsValue) returns json {
    if partsValue !is json[] {
        return partsValue;
    }
    json[] result = [];
    foreach json part in partsValue {
        if part !is map<json> {
            result.push(part);
            continue;
        }
        map<json> partResult = {};
        foreach [string, json] [pk, pv] in part.entries() {
            if pk == "raw" && pv is json[] {
                byte[]|error asBytes = trap pv.cloneWithType();
                if asBytes is byte[] {
                    partResult[pk] = array:toBase64(asBytes);
                    continue;
                }
            }
            partResult[pk] = pv;
        }
        result.push(partResult);
    }
    return result;
}

# The reverse of encodePartsRawField: converts each Part-shaped element's
# "raw" field, when it is a base64 string, back into the integer-array
# shape cloneWithType expects for a byte[] field.
#
# + partsValue - the json value of a `parts` field
# + return - the same array with every Part.raw base64 string rewritten to
#            an integer-array, or an error if a "raw" string on an actual
#            Part isn't valid base64
isolated function decodePartsRawField(json partsValue) returns json|error {
    if partsValue !is json[] {
        return partsValue;
    }
    json[] result = [];
    foreach json part in partsValue {
        if part !is map<json> {
            result.push(part);
            continue;
        }
        map<json> partResult = {};
        foreach [string, json] [pk, pv] in part.entries() {
            if pk == "raw" && pv is string {
                byte[] decoded = check array:fromBase64(pv);
                partResult[pk] = decoded.toJson();
                continue;
            }
            partResult[pk] = pv;
        }
        result.push(partResult);
    }
    return result;
}

# Recursively walks a json value (already produced by a type's default
# .toJson()), converting any Part's raw field from the integer-array shape
# Ballerina's default byte[] serialization produces into a base64 string —
# the wire encoding every other A2A implementation expects for bytes
# fields (protobuf JSON mapping), and the only shape a real server can
# parse. Applied once, after toJson(), to any v1.0 Message/Task/Artifact/
# StreamResponse/etc. tree before it is sent — the v0.3 compat layer
# (compat_v03.bal's encodeV03Part) already handles this correctly on its
# own dialect-specific path and needs no change.
#
# Structure-aware, not key-name-driven: this only ever recurses into the
# fixed set of key names that can actually hold a Part somewhere beneath
# them (see `partBearingContainerKeys`), and within a `parts` array only
# ever touches the "raw" key of each Part-shaped element. Free-form
# fields — `metadata` on Message/Task/Artifact/the update events, and a
# data-Part's own `data` field — are never in that allow-list, so a
# caller's own JSON containing an unrelated key named "raw" (e.g.
# `metadata: {"raw": [1, 2, 3]}`) is passed through completely unchanged
# instead of being silently mistaken for Part.raw.
#
# + value - a json value (or subtree) to walk
# + return - the same tree with every Part.raw integer-array rewritten to
#            a base64 string
isolated function encodeRawBytesForWire(json value) returns json {
    if value is json[] {
        json[] result = [];
        foreach json v in value {
            result.push(encodeRawBytesForWire(v));
        }
        return result;
    }
    if value is map<json> {
        map<json> result = {};
        foreach [string, json] [k, v] in value.entries() {
            if k == "parts" {
                result[k] = encodePartsRawField(v);
            } else if isPartBearingContainerKey(k) {
                result[k] = encodeRawBytesForWire(v);
            } else {
                result[k] = v;
            }
        }
        return result;
    }
    return value;
}

# The reverse of encodeRawBytesForWire: converts any "raw" field that is a
# base64 string back into the integer-array shape cloneWithType expects
# for a byte[] field — Ballerina's cloneWithType cannot decode a base64
# string into byte[] itself (confirmed empirically: it requires an
# integer-array json shape), so this must run on every inbound v1.0
# Message/Task/Artifact/StreamResponse/etc. tree before cloneWithType is
# called, or a real server's base64-encoded response would fail to parse
# entirely.
#
# Structure-aware, not key-name-driven: same traversal allow-list as
# encodeRawBytesForWire (see `partBearingContainerKeys`), so a response
# whose free-form `metadata` happens to contain a "raw" key holding
# arbitrary non-base64 text no longer fails to decode — that key is
# simply never visited, because `metadata` is not in the allow-list.
#
# + value - a json value (or subtree) to walk
# + return - the same tree with every Part.raw base64 string rewritten to
#            an integer-array, or an error if a "raw" string on an actual
#            Part isn't valid base64
isolated function decodeRawBytesFromWire(json value) returns json|error {
    if value is json[] {
        json[] result = [];
        foreach json v in value {
            result.push(check decodeRawBytesFromWire(v));
        }
        return result;
    }
    if value is map<json> {
        map<json> result = {};
        foreach [string, json] [k, v] in value.entries() {
            if k == "parts" {
                result[k] = check decodePartsRawField(v);
            } else if isPartBearingContainerKey(k) {
                result[k] = check decodeRawBytesFromWire(v);
            } else {
                result[k] = v;
            }
        }
        return result;
    }
    return value;
}

# One turn of communication between a client and an agent.
public type Message record {|
    # Required; caller generates a UUID
    string messageId;
    # ROLE_USER for outbound messages
    Role role;
    # Content of this message
    Part[] parts;
    # Groups related tasks and messages
    string? contextId?;
    # Set when continuing an existing task
    string? taskId?;
    # Other tasks this message references
    string[] referenceTaskIds = [];
    # Extension URIs for this message
    string[] extensions = [];
    # Free-form metadata attached to this message
    map<json>? metadata?;
    // newer specification version can have additional fields
    json...;
|};

# The organization publishing an AgentCard.
public type AgentProvider record {|
    # Publisher name
    string organization;
    # Publisher URL
    string url;
    # Publisher contact email
    string? contactEmail?;
    json...;
|};

# A protocol extension an agent supports, identified by URI.
public type AgentExtension record {|
    # Extension identifier
    string uri;
    # Human-readable summary of what this extension does
    string? description?;
    # Whether a client must understand this extension to interact with the agent
    boolean required = false;
    # Extension-specific configuration; shape is defined by the extension itself
    map<json>? params?;
    json...;
|};

# Feature flags describing what an agent supports.
public type AgentCapabilities record {|
    # Whether sendStreamingMessage/subscribeToTask are supported
    boolean streaming = false;
    # Whether push-notification webhooks are supported
    boolean pushNotifications = false;
    # Whether the extended agent card endpoint is available
    boolean extendedAgentCard = false;
    # Protocol extensions this agent supports
    AgentExtension[] extensions = [];
    json...;
|};

# One capability an agent exposes.
public type AgentSkill record {|
    # Unique within the agent
    string id;
    # Human-readable name
    string name;
    # Human-readable summary of what this skill does
    string description;
    # Categorization tags
    string[] tags = [];
    # Content types this skill accepts
    string[] inputModes = [];
    # Content types this skill produces
    string[] outputModes = [];
    # Example prompts illustrating this skill
    string[] examples = [];
    # Per-skill security override, following the same OR-of-ANDs semantics as AgentCard.securityRequirements
    SecurityRequirement[] securityRequirements = [];
    json...;
|};

# One transport binding an agent is reachable on.
public type AgentInterface record {|
    # Service URL for this interface
    string url;
    # e.g. "JSONRPC", "GRPC", "HTTP+JSON"
    string protocolBinding;
    # Protocol version served on this interface, if it differs from the card's default
    string? protocolVersion?;
    # When set, must be echoed on every subsequent operation against this interface
    string? tenant?;
    json...;
|};

# The document a remote agent publishes to describe itself: capabilities,
# service URL, available skills, and required authentication.
public type AgentCard record {|
    # Human-readable agent name
    string name;
    # Human-readable summary of what this agent does
    string description;
    # Agent's own version, not the protocol version
    string version;
    # Legacy top-level protocol version field, from before v1.0 moved this
    # into each AgentInterface.protocolVersion. A card with no
    # supportedInterfaces (see url below) is a legacy card; this field
    # helps detectProtocolModeForBinding (compat_v03.bal) confirm which dialect it
    # declares. v1.0-native cards omit this and set
    # supportedInterfaces[0].protocolVersion instead.
    string? protocolVersion?;
    # Legacy primary service URL. Removed as a required field in v1.0 —
    # servers now publish the primary endpoint as supportedInterfaces[0].url
    # instead. Kept optional here only for servers still sending it; use
    # primaryUrl(card) rather than reading this field directly.
    string? url?;
    # Organization publishing this agent
    AgentProvider? provider?;
    # Link to human-readable documentation
    string? documentationUrl?;
    # Link to an icon representing this agent
    string? iconUrl?;
    # Feature flags describing what this agent supports
    AgentCapabilities capabilities;
    # Alternative transport bindings this agent supports, beyond `url`
    AgentInterface[] supportedInterfaces = [];
    # Security schemes available to authorize requests, keyed by scheme name
    map<SecurityScheme> securitySchemes = {};
    # Which security schemes apply; a logical OR across the list, each
    # entry a logical AND of the schemes it names
    SecurityRequirement[] securityRequirements = [];
    # Content types this agent accepts by default
    string[] defaultInputModes = ["text"];
    # Content types this agent produces by default
    string[] defaultOutputModes = ["text"];
    # Capabilities this agent exposes
    AgentSkill[] skills;
    # JWS signatures over this card. This library captures the shape only;
    # it does not verify signatures — see issue #12.
    AgentCardSignature[] signatures = [];
    json...;
|};

# Four states are terminal (COMPLETED, FAILED, CANCELED, REJECTED); two are
# interrupted and allow the task to resume on a follow-up message with the
# same taskId (INPUT_REQUIRED, AUTH_REQUIRED).
public enum TaskState {
    TASK_STATE_UNSPECIFIED,
    TASK_STATE_SUBMITTED,
    TASK_STATE_WORKING,
    TASK_STATE_COMPLETED,
    TASK_STATE_FAILED,
    TASK_STATE_CANCELED,
    TASK_STATE_REJECTED,
    TASK_STATE_INPUT_REQUIRED,
    TASK_STATE_AUTH_REQUIRED
}

# A Task's current lifecycle state.
public type TaskStatus record {|
    # Current lifecycle state
    TaskState state;
    # A rich message, not a plain string — lets an agent entering
    # TASK_STATE_INPUT_REQUIRED attach a structured prompt
    Message? message?;
    # ISO 8601, e.g. "2023-10-27T10:00:00Z"
    string? timestamp?;
    json...;
|};

# One piece of output content produced by a task.
public type Artifact record {|
    # Unique within the task; this is the identifier
    string artifactId;
    # Human-readable label, not an identifier
    string? name?;
    # Human-readable summary of this artifact
    string? description?;
    # Must contain at least one part
    Part[] parts;
    # Free-form metadata attached to this artifact
    map<json>? metadata?;
    # Extension URIs relevant to this artifact
    string[] extensions = [];
    json...;
|};

# The stateful unit of work tracked by the A2A protocol.
public type Task record {|
    # Server-generated; clients never create this
    string id;
    # Groups related tasks and messages
    string? contextId?;
    # Current lifecycle state
    TaskStatus status;
    # Prior messages exchanged for this task
    Message[] history = [];
    # Output produced so far
    Artifact[] artifacts = [];
    # Free-form metadata attached to this task
    map<json>? metadata?;
    json...;
|};

# A lifecycle transition on a task, delivered over a stream.
public type TaskStatusUpdateEvent record {|
    # Task this event applies to
    string taskId;
    # Context this event's task belongs to
    string contextId;
    # New lifecycle state
    TaskStatus status;
    # Free-form metadata attached to this event
    map<json>? metadata?;
    json...;
|};

# Delivered output content, delivered over a stream; supports chunked
# delivery via append/lastChunk.
public type TaskArtifactUpdateEvent record {|
    # Task this event applies to
    string taskId;
    # Context this event's task belongs to
    string contextId;
    # Output content delivered by this event
    Artifact artifact;
    # Append to a previous artifact of the same id
    boolean append = false;
    # Final chunk of this artifact
    boolean lastChunk = false;
    # Free-form metadata attached to this event
    map<json>? metadata?;
    json...;
|};

# The wrapper delivered by streaming operations.
#
# Exactly one field is non-nil per event, per specification section 3.2.3.
public type StreamResponse record {|
    # Present when a task is first created
    Task? task?;
    # Present for a plain conversational reply with no task
    Message? message?;
    # Present on a lifecycle transition
    TaskStatusUpdateEvent? statusUpdate?;
    # Present on delivered output content
    TaskArtifactUpdateEvent? artifactUpdate?;
    json...;
|};

# The wrapper returned by a unary sendMessage call. A narrower sibling of
# StreamResponse: a non-streaming reply can only ever be a Task or a
# Message, never a status or artifact update, so those two fields are
# omitted here rather than left perpetually nil.
#
# Exactly one field is non-nil, per specification section 3.1.1.
public type SendMessageResult record {|
    # Present when the agent creates or continues a tracked task
    Task? task?;
    # Present for a plain conversational reply with no task
    Message? message?;
    json...;
|};

# Credentials the client presents to a push-notification webhook it registers.
public type AuthenticationInfo record {|
    # IANA HTTP auth scheme, e.g. "Bearer"
    string scheme;
    # Credential value matching `scheme`
    string? credentials?;
    json...;
|};

# A webhook the server will POST task updates to.
public type TaskPushNotificationConfig record {|
    # Webhook URL the server will POST to
    string url;
    # Identifier for this push notification config
    string? id?;
    # Leave unset in a sendMessage request
    string? taskId?;
    # Opaque token the server echoes back on each push, for correlation
    string? token?;
    # How the server should authenticate to this webhook
    AuthenticationInfo? authentication?;
    # Must match the tenant value from the selected AgentInterface, when
    # that field is set
    string? tenant?;
    json...;
|};

# Per-request options for a sendMessage call.
public type SendMessageConfiguration record {|
    # Content types the caller can accept in the response
    string[] acceptedOutputModes = ["text"];
    # Unset imposes no limit; zero omits history entirely; a positive value
    # requests at most that many recent messages
    int? historyLength = ();
    # False (default) blocks until the task reaches a terminal or
    # interrupted state; true returns as soon as the task is created
    boolean returnImmediately = false;
    # Webhook to register for this task's updates
    TaskPushNotificationConfig? taskPushNotificationConfig = ();
    json...;
|};

# Filter and pagination parameters for a listTasks call.
public type ListTasksFilter record {|
    # Restrict to tasks in this context
    string? contextId?;
    # Restrict to tasks in this lifecycle state
    TaskState? status?;
    # Maximum results per page
    int? pageSize?;
    # Opaque cursor from a previous ListTasksResult.nextPageToken
    string? pageToken?;
    # Same semantics as getTask's historyLength
    int? historyLength?;
    # ISO 8601 — only tasks whose status changed after this timestamp
    string? statusTimestampAfter?;
    # Whether to include each task's artifacts in the response
    boolean? includeArtifacts?;
    json...;
|};

# Paginated result of a listTasks call.
public type ListTasksResult record {|
    Task[] tasks;
    # Opaque cursor for the next page; empty when there are no more results
    string nextPageToken;
    # Echoes the effective page size used
    int pageSize;
    # Total matching tasks across all pages
    int totalSize;
    json...;
|};

# Paginated result of a listTaskPushNotificationConfigs call.
public type ListTaskPushNotificationConfigsResult record {|
    TaskPushNotificationConfig[] configs;
    string nextPageToken;
    json...;
|};

# Configuration for one OAuth 2.0 Authorization Code flow.
public type AuthorizationCodeOAuthFlow record {|
    # The authorization URL for this flow
    string authorizationUrl;
    # URL for obtaining refresh tokens
    string? refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    # The token URL for this flow
    string tokenUrl;
    json...;
|};

# Configuration for one OAuth 2.0 Client Credentials flow.
public type ClientCredentialsOAuthFlow record {|
    # URL for obtaining refresh tokens
    string? refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    # The token URL for this flow
    string tokenUrl;
    json...;
|};

# Configuration for one OAuth 2.0 Implicit flow.
public type ImplicitOAuthFlow record {|
    # The authorization URL for this flow
    string authorizationUrl;
    # URL for obtaining refresh tokens
    string? refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    json...;
|};

# Configuration for one OAuth 2.0 Resource Owner Password flow.
public type PasswordOAuthFlow record {|
    # URL for obtaining refresh tokens
    string? refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    # The token URL for this flow
    string tokenUrl;
    json...;
|};

# The set of OAuth 2.0 flows an OAuth2SecurityScheme supports. Each is
# independently optional; a scheme may support one or several.
public type OAuthFlows record {|
    AuthorizationCodeOAuthFlow? authorizationCode?;
    ClientCredentialsOAuthFlow? clientCredentials?;
    ImplicitOAuthFlow? implicit?;
    PasswordOAuthFlow? password?;
    json...;
|};

# A security scheme using an API key, per OpenAPI 3.0's Security Scheme
# Object.
public type ApiKeySecurityScheme record {|
    string? description?;
    # Where the API key is sent
    "query"|"header"|"cookie" 'in;
    # The header, query, or cookie parameter name
    string name;
    "apiKey" 'type = "apiKey";
    json...;
|};

# A security scheme using HTTP authentication (e.g. Bearer, Basic), per
# OpenAPI 3.0's Security Scheme Object.
public type HttpAuthSecurityScheme record {|
    string? description?;
    # The IANA HTTP Authentication Scheme name, e.g. "Bearer"
    string scheme;
    # Hint for how the bearer token is formatted, e.g. "JWT"
    string? bearerFormat?;
    "http" 'type = "http";
    json...;
|};

# A security scheme using OAuth 2.0, per OpenAPI 3.0's Security Scheme
# Object.
public type OAuth2SecurityScheme record {|
    string? description?;
    # The OAuth 2.0 flows this scheme supports
    OAuthFlows flows;
    # URL to the OAuth2 authorization server's RFC 8414 metadata
    string? oauth2MetadataUrl?;
    "oauth2" 'type = "oauth2";
    json...;
|};

# A security scheme using OpenID Connect, per OpenAPI 3.0's Security
# Scheme Object.
public type OpenIdConnectSecurityScheme record {|
    string? description?;
    # The OpenID Connect Discovery URL for the provider's metadata
    string openIdConnectUrl;
    "openIdConnect" 'type = "openIdConnect";
    json...;
|};

# A security scheme using mutual TLS authentication, per OpenAPI 3.0's
# Security Scheme Object.
public type MutualTlsSecurityScheme record {|
    string? description?;
    "mutualTLS" 'type = "mutualTLS";
    json...;
|};

# A security scheme an agent declares as available to authorize requests.
# Discriminated by the `type` field's literal value; cloneWithType against
# this union selects the one variant whose `type` literal matches the JSON.
public type SecurityScheme ApiKeySecurityScheme|HttpAuthSecurityScheme|OAuth2SecurityScheme
    |OpenIdConnectSecurityScheme|MutualTlsSecurityScheme;

# One security requirement: a set of scheme names that must all be
# satisfied together (an AND), with each scheme's required OAuth scopes
# (empty for scheme types that don't use scopes). AgentCard/AgentSkill
# express a list of these, which is an OR across the list — "either this
# whole requirement, or that one."
public type SecurityRequirement map<string[]>;

# A JSON Web Signature (RFC 7515) computed over an AgentCard, for
# authenticity verification.
#
# This library captures the signature's shape so a card round-trips
# without loss, but does **not** verify it. Spec 8.4.3 mandates a
# canonicalize-and-verify procedure without defining an API for it, and
# no reference SDK implements one; a prior attempt here could not perform
# the RFC 8785 canonicalization the procedure requires. Callers needing
# verification must do it out-of-band for now. See issue #12.
public type AgentCardSignature record {|
    # Unprotected JWS header values
    map<json>? header?;
    # Base64url-encoded protected JWS header
    string protected;
    # Base64url-encoded computed signature
    string signature;
    json...;
|};

# Every JSON key that can introduce a v1.0 `SecurityScheme` oneof arm.
#
# A2A v1.0 models SecurityScheme as a protobuf `oneof` (see `proto/a2a.proto`),
# so the wire form is a single wrapper key — `{"apiKeySecurityScheme": {...}}` —
# not the v0.3/OpenAPI `type` discriminator this module's SecurityScheme union
# is shaped around. The spec's own JSON schema for SecurityScheme accepts each
# arm under two spellings: a lowerCamelCase one (its `properties`) and a
# snake_case one (its `patternProperties`), so both are recognized here.
final readonly & string[] V10_SECURITY_SCHEME_ARM_KEYS = [
    "apiKeySecurityScheme",
    "api_key_security_scheme",
    "httpAuthSecurityScheme",
    "http_auth_security_scheme",
    "oauth2SecurityScheme",
    "oauth2_security_scheme",
    "openIdConnectSecurityScheme",
    "open_id_connect_security_scheme",
    "mtlsSecurityScheme",
    "mtls_security_scheme"
];

# Whether a raw securitySchemes entry is in the v1.0 oneof-wrapper form.
#
# Checked separately from unwrapping so that an entry which *declares* an arm
# but carries a malformed payload is dropped outright rather than falling
# through to the v0.3 clone below — where `MutualTlsSecurityScheme` (no
# required fields, defaulted `type`) would match it and silently mislabel it.
#
# + entry - the raw securitySchemes entry
# + return - true if any of the ten recognized wrapper keys is present
isolated function hasV10SecuritySchemeArm(map<json> entry) returns boolean {
    foreach string armKey in V10_SECURITY_SCHEME_ARM_KEYS {
        if entry.hasKey(armKey) {
            return true;
        }
    }
    return false;
}

# Returns one v1.0 oneof arm's payload as a mutable copy, looked up under
# either spelling the spec accepts for it.
#
# + entry - the raw securitySchemes entry
# + camelKey - the lowerCamelCase spelling, per the spec schema's `properties`
# + snakeKey - the snake_case spelling, per its `patternProperties`
# + return - the arm's payload, or () if this entry declares no such arm (or
#            declares it as something other than an object)
isolated function v10SecuritySchemeArm(map<json> entry, string camelKey, string snakeKey) returns map<json>? {
    json? value = entry[camelKey];
    if value is () {
        value = entry[snakeKey];
    }
    return value is map<json> ? value.clone() : ();
}

# Renames one field of a raw JSON object in place, where the v1.0 wire name
# differs from this module's record field name. A no-op when the source field
# is absent, and never overwrites an existing target field.
#
# + fields - the object to rewrite
# + wireName - the field name as it arrives on the wire
# + recordName - the field name this module's record declares
isolated function renameJsonField(map<json> fields, string wireName, string recordName) {
    if fields.hasKey(wireName) && !fields.hasKey(recordName) {
        fields[recordName] = fields.remove(wireName);
    }
}

# Converts one v1.0 oneof-wrapped securitySchemes entry into the equivalent
# typed SecurityScheme.
#
# Mirrors `decodeGrpcSecurityScheme` (grpc_binding.bal), which already performs
# this same arm-by-arm mapping for the gRPC binding — the two paths must agree
# on which arm means what, and on rejecting an out-of-range apiKey location.
#
# Only two kinds of field-name fixup are needed. `location` becomes `in`
# (a genuine rename between the v1.0 and OpenAPI spellings), and the three
# multi-word fields the spec also accepts in snake_case are normalized to their
# camelCase form. Every other field name already matches, since protobuf JSON
# emits lowerCamelCase.
#
# The apiKey `location` value is compared case-insensitively. The proto
# documents it as lowercase "query"/"header"/"cookie", but a server generating
# it from a protobuf enum can emit other casing, and the reference Python SDK
# likewise lowercases before comparing (`AuthInterceptor`).
#
# KNOWN LIMITATION: nested OAuth *flow* objects are not snake_case-normalized —
# only the scheme-level fields are. A v1.0 card sending
# `{"authorization_code": ...}` inside `flows` parses without error but leaves
# that flow in `OAuthFlows`' open rest field rather than its typed
# `authorizationCode` field. This library does not act on OAuth2 flows
# itself — auth is caller-configured (see auth.bal) — so this costs typing
# detail, not function.
#
# + entry - a raw securitySchemes entry already known to declare an arm
# + return - the typed SecurityScheme, or () if the arm's payload doesn't
#            match the shape that arm requires (the caller drops it)
isolated function unwrapV10SecurityScheme(map<json> entry) returns SecurityScheme? {
    map<json>? apiKey = v10SecuritySchemeArm(entry, "apiKeySecurityScheme", "api_key_security_scheme");
    if apiKey is map<json> {
        json? location = apiKey["location"];
        if location !is string {
            return ();
        }
        string normalized = location.toLowerAscii();
        if normalized != "query" && normalized != "header" && normalized != "cookie" {
            return ();
        }
        _ = apiKey.remove("location");
        apiKey["in"] = normalized;
        ApiKeySecurityScheme|error scheme = apiKey.cloneWithType(ApiKeySecurityScheme);
        return scheme is ApiKeySecurityScheme ? scheme : ();
    }

    map<json>? httpAuth = v10SecuritySchemeArm(entry, "httpAuthSecurityScheme", "http_auth_security_scheme");
    if httpAuth is map<json> {
        renameJsonField(httpAuth, "bearer_format", "bearerFormat");
        HttpAuthSecurityScheme|error scheme = httpAuth.cloneWithType(HttpAuthSecurityScheme);
        return scheme is HttpAuthSecurityScheme ? scheme : ();
    }

    map<json>? oauth2 = v10SecuritySchemeArm(entry, "oauth2SecurityScheme", "oauth2_security_scheme");
    if oauth2 is map<json> {
        renameJsonField(oauth2, "oauth2_metadata_url", "oauth2MetadataUrl");
        OAuth2SecurityScheme|error scheme = oauth2.cloneWithType(OAuth2SecurityScheme);
        return scheme is OAuth2SecurityScheme ? scheme : ();
    }

    map<json>? oidc = v10SecuritySchemeArm(entry, "openIdConnectSecurityScheme", "open_id_connect_security_scheme");
    if oidc is map<json> {
        renameJsonField(oidc, "open_id_connect_url", "openIdConnectUrl");
        OpenIdConnectSecurityScheme|error scheme = oidc.cloneWithType(OpenIdConnectSecurityScheme);
        return scheme is OpenIdConnectSecurityScheme ? scheme : ();
    }

    map<json>? mtls = v10SecuritySchemeArm(entry, "mtlsSecurityScheme", "mtls_security_scheme");
    if mtls is map<json> {
        MutualTlsSecurityScheme|error scheme = mtls.cloneWithType(MutualTlsSecurityScheme);
        return scheme is MutualTlsSecurityScheme ? scheme : ();
    }

    return ();
}

# Parses each entry of a raw securitySchemes JSON object independently,
# silently omitting entries that don't match any known SecurityScheme
# variant (unrecognized `type`, or otherwise malformed) rather than
# failing the whole AgentCard parse. This keeps AgentCard parsing
# forward-compatible with scheme kinds a server might add in the future.
#
# Handles both wire dialects. A v1.0 card wraps each scheme in one of the
# five oneof arm keys (see `unwrapV10SecurityScheme`); a v0.3 card
# discriminates on a `type` field, which clones into the SecurityScheme union
# directly. The two forms are distinguished up front rather than by trying the
# union first: `MutualTlsSecurityScheme` requires no fields and defaults its
# `type`, so it matches *any* object without a `type` key — which is exactly
# what a v1.0 wrapper is, and why every v1.0 scheme used to be silently
# mislabelled as mutual TLS.
#
# + raw - the raw JSON value of the AgentCard's `securitySchemes` field
# + return - a map containing only the entries that parsed successfully
isolated function parseSecuritySchemes(json raw) returns map<SecurityScheme>|error {
    map<json> rawMap = check raw.ensureType();
    map<SecurityScheme> result = {};
    foreach [string, json] [name, schemeJson] in rawMap.entries() {
        if schemeJson is map<json> && hasV10SecuritySchemeArm(schemeJson) {
            SecurityScheme? unwrapped = unwrapV10SecurityScheme(schemeJson);
            if unwrapped is SecurityScheme {
                result[name] = unwrapped;
            }
            // A declared-but-malformed arm is dropped here, never retried
            // against the union below — see hasV10SecuritySchemeArm.
            continue;
        }
        SecurityScheme|error scheme = schemeJson.cloneWithType(SecurityScheme);
        if scheme is SecurityScheme {
            result[name] = scheme;
        }
    }
    return result;
}

# Parses a raw JSON array into a list of SecurityRequirement values,
# silently dropping any entry that doesn't clone into map<string[]>.
# Used for both AgentCard.securityRequirements and each AgentSkill's
# securityRequirements, so one malformed entry can't fail the whole
# AgentCard parse.
#
# + raw - the raw JSON value of a securityRequirements field
# + return - a list containing only the entries that parsed successfully
isolated function parseSecurityRequirements(json raw) returns SecurityRequirement[]|error {
    json[] rawArray = check raw.ensureType();
    SecurityRequirement[] result = [];
    foreach json entry in rawArray {
        SecurityRequirement|error req = entry.cloneWithType(SecurityRequirement);
        if req is SecurityRequirement {
            result.push(req);
        }
    }
    return result;
}

# Parses a raw JSON array into a list of AgentCardSignature values,
# silently dropping any entry that doesn't match the AgentCardSignature
# shape, rather than failing the whole AgentCard parse over one
# malformed signature.
#
# + raw - the raw JSON value of the AgentCard's `signatures` field
# + return - a list containing only the entries that parsed successfully
isolated function parseAgentCardSignatures(json raw) returns AgentCardSignature[]|error {
    json[] rawArray = check raw.ensureType();
    AgentCardSignature[] result = [];
    foreach json entry in rawArray {
        AgentCardSignature|error sig = entry.cloneWithType(AgentCardSignature);
        if sig is AgentCardSignature {
            result.push(sig);
        }
    }
    return result;
}
