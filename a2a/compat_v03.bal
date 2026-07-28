// A2A protocol v0.3 compatibility layer.
//
// Lives in the root module, not modules/, for the same reason sse.bal and
// errors.bal do: a submodule under modules/ cannot import the root a2a
// module without a cyclic dependency, and this file needs to construct
// Task/Message/Role/TaskState/StreamResponse values directly. See
// docs/superpowers/specs/2026-07-28-v03-client-compat-design.md for the
// full design and the evidence behind every mapping below.

import ballerina/lang.array;

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

# Translates a v1.0 PascalCase JSON-RPC method name to its v0.3 equivalent.
#
# + v1Method - the method name this client already builds for v1.0
# + return - the v0.3 wire method name
isolated function v03MethodName(string v1Method) returns string {
    match v1Method {
        "SendMessage" => {
            return "message/send";
        }
        "SendStreamingMessage" => {
            return "message/stream";
        }
        "GetTask" => {
            return "tasks/get";
        }
        "CancelTask" => {
            return "tasks/cancel";
        }
        "SubscribeToTask" => {
            return "tasks/resubscribe";
        }
        _ => {
            return v1Method;
        }
    }
}

# + role - the v0.3 wire role string ("user"/"agent")
# + return - the equivalent v1.0 Role, or an error if unrecognized
isolated function mapV03Role(string role) returns Role|error {
    match role {
        "user" => {
            return ROLE_USER;
        }
        "agent" => {
            return ROLE_AGENT;
        }
        _ => {
            return error(string `Unrecognized v0.3 role: ${role}`);
        }
    }
}

# + state - the v0.3 wire state string (e.g. "completed", "input-required")
# + return - the equivalent v1.0 TaskState, or an error if unrecognized
isolated function mapV03State(string state) returns TaskState|error {
    match state {
        "submitted" => {
            return TASK_STATE_SUBMITTED;
        }
        "working" => {
            return TASK_STATE_WORKING;
        }
        "completed" => {
            return TASK_STATE_COMPLETED;
        }
        "failed" => {
            return TASK_STATE_FAILED;
        }
        "canceled" => {
            return TASK_STATE_CANCELED;
        }
        "rejected" => {
            return TASK_STATE_REJECTED;
        }
        "input-required" => {
            return TASK_STATE_INPUT_REQUIRED;
        }
        "auth-required" => {
            return TASK_STATE_AUTH_REQUIRED;
        }
        _ => {
            return error(string `Unrecognized v0.3 task state: ${state}`);
        }
    }
}

# Converts a v0.3 Part (kind-discriminated: text/file/data) into the v1.0
# Part shape (field-presence discriminated). File variants nest bytes/uri
# one level deeper in v0.3 (under a "file" object) than v1.0's flat
# raw/url fields; base64-encoded bytes are decoded via ballerina/lang.array's
# fromBase64, which errors on malformed input rather than silently mangling it.
#
# + partJson - the raw v0.3 Part JSON
# + return - the equivalent v1.0 Part, or an error if malformed/unrecognized
isolated function parseV03Part(json partJson) returns Part|error {
    map<json> m = check partJson.ensureType();
    string kind = check m["kind"].ensureType();
    map<json> v1Shape = {};
    if m.hasKey("metadata") {
        v1Shape["metadata"] = m["metadata"];
    }

    match kind {
        "text" => {
            v1Shape["text"] = m["text"];
        }
        "data" => {
            v1Shape["data"] = m["data"];
        }
        "file" => {
            map<json> file = check m["file"].ensureType();
            if file.hasKey("bytes") {
                string encodedBytes = check file["bytes"].ensureType();
                v1Shape["raw"] = check array:fromBase64(encodedBytes);
            } else if file.hasKey("uri") {
                v1Shape["url"] = file["uri"];
            } else {
                return error("v0.3 FilePart.file has neither bytes nor uri");
            }
            if file.hasKey("name") {
                v1Shape["filename"] = file["name"];
            }
            if file.hasKey("mime_type") {
                v1Shape["mediaType"] = file["mime_type"];
            } else if file.hasKey("mimeType") {
                v1Shape["mediaType"] = file["mimeType"];
            }
        }
        _ => {
            return error(string `Unrecognized v0.3 Part kind: ${kind}`);
        }
    }

    return check v1Shape.cloneWithType(Part);
}

# + msgJson - the raw v0.3 Message JSON
# + return - the equivalent v1.0 Message, or an error if malformed
isolated function parseV03Message(json msgJson) returns Message|error {
    map<json> m = check msgJson.ensureType();
    string role = check m["role"].ensureType();
    Role mappedRole = check mapV03Role(role);

    json[] rawParts = check m["parts"].ensureType();
    Part[] parts = [];
    foreach json p in rawParts {
        parts.push(check parseV03Part(p));
    }

    map<json> v1Shape = {
        messageId: check m["messageId"].ensureType(),
        role: mappedRole.toJson(),
        parts: parts.toJson()
    };
    if m.hasKey("contextId") {
        v1Shape["contextId"] = m["contextId"];
    }
    if m.hasKey("taskId") {
        v1Shape["taskId"] = m["taskId"];
    }
    if m.hasKey("metadata") {
        v1Shape["metadata"] = m["metadata"];
    }

    return check v1Shape.cloneWithType(Message);
}

# + statusJson - the raw v0.3 TaskStatus JSON
# + return - the equivalent v1.0 TaskStatus, or an error if malformed
isolated function parseV03TaskStatus(json statusJson) returns TaskStatus|error {
    map<json> m = check statusJson.ensureType();
    TaskState state = check mapV03State(check m["state"].ensureType());

    map<json> v1Shape = {state: state.toJson()};
    if m.hasKey("message") {
        Message msg = check parseV03Message(m["message"]);
        v1Shape["message"] = msg.toJson();
    }
    if m.hasKey("timestamp") {
        v1Shape["timestamp"] = m["timestamp"];
    }

    return check v1Shape.cloneWithType(TaskStatus);
}

# + artifactJson - the raw v0.3 Artifact JSON
# + return - the equivalent v1.0 Artifact, or an error if malformed
isolated function parseV03Artifact(json artifactJson) returns Artifact|error {
    map<json> m = check artifactJson.ensureType();

    json[] rawParts = check m["parts"].ensureType();
    Part[] parts = [];
    foreach json p in rawParts {
        parts.push(check parseV03Part(p));
    }

    map<json> v1Shape = {
        artifactId: check m["artifactId"].ensureType(),
        parts: parts.toJson()
    };
    if m.hasKey("name") {
        v1Shape["name"] = m["name"];
    }
    if m.hasKey("description") {
        v1Shape["description"] = m["description"];
    }
    if m.hasKey("metadata") {
        v1Shape["metadata"] = m["metadata"];
    }

    return check v1Shape.cloneWithType(Artifact);
}

# + taskJson - the raw v0.3 Task JSON (unwrapped — see decodeV03SendResult)
# + return - the equivalent v1.0 Task, or an error if malformed
isolated function parseV03Task(json taskJson) returns Task|error {
    map<json> m = check taskJson.ensureType();
    TaskStatus status = check parseV03TaskStatus(m["status"]);

    map<json> v1Shape = {
        id: check m["id"].ensureType(),
        status: status.toJson()
    };
    if m.hasKey("contextId") {
        v1Shape["contextId"] = m["contextId"];
    }
    if m.hasKey("metadata") {
        v1Shape["metadata"] = m["metadata"];
    }
    if m.hasKey("history") {
        json[] rawHistory = check m["history"].ensureType();
        Message[] history = [];
        foreach json hm in rawHistory {
            history.push(check parseV03Message(hm));
        }
        v1Shape["history"] = history.toJson();
    }
    if m.hasKey("artifacts") {
        json[] rawArtifacts = check m["artifacts"].ensureType();
        Artifact[] artifacts = [];
        foreach json am in rawArtifacts {
            artifacts.push(check parseV03Artifact(am));
        }
        v1Shape["artifacts"] = artifacts.toJson();
    }

    return check v1Shape.cloneWithType(Task);
}
