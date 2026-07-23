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
    map<json>? metadata?; #newer spec version can have additional fields
    json...;
|};
