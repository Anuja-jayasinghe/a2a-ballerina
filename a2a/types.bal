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
