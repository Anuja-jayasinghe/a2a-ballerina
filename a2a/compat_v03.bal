// A2A protocol v0.3 compatibility layer.
//
// Lives in the root module, not modules/, for the same reason sse.bal and
// errors.bal do: a submodule under modules/ cannot import the root a2a
// module without a cyclic dependency, and this file needs to construct
// Task/Message/Role/TaskState/StreamResponse values directly. See
// docs/superpowers/specs/2026-07-28-v03-client-compat-design.md for the
// full design and the evidence behind every mapping below.

# Which A2A wire dialect a Client speaks to a given server.
public type ProtocolMode "V1_0"|"V0_3";

# Detects which wire dialect to use, from a resolved AgentCard.
#
# + card - the agent card fetched via resolveAgentCard
# + return - V0_3 for a legacy card (no supportedInterfaces) unless its
#            legacy top-level protocolVersion explicitly says otherwise, or
#            for a card whose first supportedInterfaces entry declares a
#            "0.x" protocolVersion; V1_0 otherwise
public isolated function detectProtocolMode(AgentCard card) returns ProtocolMode {
    if card.supportedInterfaces.length() > 0 {
        string? v = card.supportedInterfaces[0]?.protocolVersion;
        return (v is string && v.startsWith("0.")) ? "V0_3" : "V1_0";
    }
    string? v = card?.protocolVersion;
    return (v is string && !v.startsWith("0.")) ? "V1_0" : "V0_3";
}
