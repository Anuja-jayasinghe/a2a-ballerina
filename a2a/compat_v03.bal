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

# Decodes a base64-encoded string to a byte array using bitwise operations.
# While the spec prefers library functions, Ballerina's standard library does not
# include a base64 decoder, so this uses bitwise operations.
# + encoded - base64-encoded string
# + return - decoded byte array, or an error if malformed
isolated function decodeBase64(string encoded) returns byte[]|error {
    int len = encoded.length();
    byte[] result = [];
    int[] buf = [0, 0, 0, 0];
    int bufLen = 0;

    foreach int i in 0 ..< len {
        int codePoint = encoded.getCodePoint(i);

        if codePoint >= 65 && codePoint <= 90 {
            // A-Z: 0-25
            buf[bufLen] = codePoint - 65;
            bufLen = bufLen + 1;
        } else if codePoint >= 97 && codePoint <= 122 {
            // a-z: 26-51
            buf[bufLen] = 26 + (codePoint - 97);
            bufLen = bufLen + 1;
        } else if codePoint >= 48 && codePoint <= 57 {
            // 0-9: 52-61
            buf[bufLen] = 52 + (codePoint - 48);
            bufLen = bufLen + 1;
        } else if codePoint == 43 {
            // +: 62
            buf[bufLen] = 62;
            bufLen = bufLen + 1;
        } else if codePoint == 47 {
            // /: 63
            buf[bufLen] = 63;
            bufLen = bufLen + 1;
        } else if codePoint == 61 {
            // =: padding, stop here
            break;
        }
        // else: skip whitespace and other characters

        if bufLen == 4 {
            int b1 = (buf[0] << 2) | (buf[1] >> 4);
            int b2 = ((buf[1] & 0x0f) << 4) | (buf[2] >> 2);
            int b3 = ((buf[2] & 0x03) << 6) | buf[3];

            result.push(<byte>(b1 & 0xff));
            result.push(<byte>(b2 & 0xff));
            result.push(<byte>(b3 & 0xff));

            bufLen = 0;
        }
    }

    if bufLen > 0 {
        if bufLen == 2 {
            int b1 = (buf[0] << 2) | (buf[1] >> 4);
            result.push(<byte>(b1 & 0xff));
        } else if bufLen == 3 {
            int b1 = (buf[0] << 2) | (buf[1] >> 4);
            int b2 = ((buf[1] & 0x0f) << 4) | (buf[2] >> 2);
            result.push(<byte>(b1 & 0xff));
            result.push(<byte>(b2 & 0xff));
        }
    }

    return result;
}

# Converts a v0.3 Part (kind-discriminated: text/file/data) into the v1.0
# Part shape (field-presence discriminated). File variants nest bytes/uri
# one level deeper in v0.3 (under a "file" object) than v1.0's flat
# raw/url fields; base64-encoded bytes are decoded using standard bitwise
# operations rather than relying on external base64 decoder availability.
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
                v1Shape["raw"] = check decodeBase64(encodedBytes);
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
