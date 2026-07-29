// Spec-facing types for the A2A protocol.

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
    # Whether sendMessageStream/subscribeToTask are supported
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
    # Per-skill security override; untyped pending full SecurityRequirement
    # modelling, same as AgentCard.securitySchemes/securityRequirements
    json[] securityRequirements = [];
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
    # helps detectProtocolMode (compat_v03.bal) confirm which dialect it
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
    # Scheme shapes vary (API key, HTTP auth, OAuth2, OIDC, mTLS); untyped pending full modelling
    map<json> securitySchemes = {};
    # Which security schemes apply; untyped pending full SecurityRequirement
    # modelling, same as securitySchemes
    json[] securityRequirements = [];
    # Content types this agent accepts by default
    string[] defaultInputModes = ["text"];
    # Content types this agent produces by default
    string[] defaultOutputModes = ["text"];
    # Capabilities this agent exposes
    AgentSkill[] skills;
    # JWS signatures over this card, for authenticity verification
    json[] signatures = [];
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
