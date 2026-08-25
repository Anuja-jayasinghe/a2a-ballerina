// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

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
type ProtocolMode "V1_0"|"V0_3";

# Resolves the wire dialect for the interface matching preferredBinding,
# rather than assuming supportedInterfaces[0] — the same interface
# selectInterface would return for this binding, so a REST client and a
# JSON-RPC client on the same multi-interface card each read their own
# interface's protocolVersion, not whichever happens to sit at index 0.
# Falls back to the existing index-0/legacy behavior when the card
# declares no matching interface (this function has no error return type
# to report "not found" through, so falling back rather than defaulting
# blindly to V1_0 preserves the existing single-binding-card semantics).
#
# + card - the agent card fetched via resolveAgentCard
# + preferredBinding - which transport binding's interface to read
#                      protocolVersion from; defaults to "JSONRPC"
# + return - V0_3 or V1_0, per the matched interface's protocolVersion,
#            or the existing index-0/legacy rules if no interface matches
isolated function detectProtocolModeForBinding(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns ProtocolMode {
    AgentInterface|error iface = selectInterface(card, preferredBinding);
    if iface is AgentInterface {
        string? v = iface?.protocolVersion;
        return (v is string && v.startsWith("0.")) ? "V0_3" : "V1_0";
    }
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
        "CreateTaskPushNotificationConfig" => {
            return "tasks/pushNotificationConfig/set";
        }
        "GetTaskPushNotificationConfig" => {
            return "tasks/pushNotificationConfig/get";
        }
        "ListTaskPushNotificationConfigs" => {
            return "tasks/pushNotificationConfig/list";
        }
        "DeleteTaskPushNotificationConfig" => {
            return "tasks/pushNotificationConfig/delete";
        }
        "GetExtendedAgentCard" => {
            return "agent/getAuthenticatedExtendedCard";
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

# + role - the outbound v1.0 Role to encode
# + return - the equivalent v0.3 wire role string, or an error for
#            ROLE_UNSPECIFIED (or anything else unrecognized) — the mirror
#            image of mapV03Role, which errors the same way on decode
isolated function encodeV03Role(Role role) returns string|error {
    match role {
        ROLE_USER => {
            return "user";
        }
        ROLE_AGENT => {
            return "agent";
        }
        _ => {
            return error(string `Cannot encode v0.3 message: unrecognized or unspecified role ${role}`);
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
    if m.hasKey("referenceTaskIds") {
        v1Shape["referenceTaskIds"] = m["referenceTaskIds"];
    }
    if m.hasKey("extensions") {
        v1Shape["extensions"] = m["extensions"];
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
    if m.hasKey("extensions") {
        v1Shape["extensions"] = m["extensions"];
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

# Encodes an outbound v1.0-shaped Part into the v0.3 kind-discriminated
# wire shape, the mirror image of parseV03Part.
#
# + part - the outbound Part, in v1.0 field-presence-discriminated shape
# + return - the equivalent v0.3 Part JSON, or an error if none of
#            text/raw/url/data is actually set
isolated function encodeV03Part(Part part) returns json|error {
    map<json> result = {};
    string? partText = part?.text;
    byte[]? raw = part?.raw;
    string? url = part?.url;
    json? data = part?.data;
    if partText is string {
        result["kind"] = "text";
        result["text"] = partText;
    } else if raw is byte[] {
        map<json> file = {bytes: array:toBase64(raw)};
        string? filename = part?.filename;
        string? mediaType = part?.mediaType;
        if filename is string {
            file["name"] = filename;
        }
        if mediaType is string {
            file["mimeType"] = mediaType;
        }
        result["kind"] = "file";
        result["file"] = file;
    } else if url is string {
        map<json> file = {uri: url};
        string? filename = part?.filename;
        string? mediaType = part?.mediaType;
        if filename is string {
            file["name"] = filename;
        }
        if mediaType is string {
            file["mimeType"] = mediaType;
        }
        result["kind"] = "file";
        result["file"] = file;
    } else if data !is () {
        result["kind"] = "data";
        result["data"] = data;
    } else {
        return error("Cannot encode v0.3 Part: none of text, raw, url, or data is set");
    }
    map<json>? partMetadata = part?.metadata;
    if partMetadata is map<json> {
        result["metadata"] = partMetadata;
    }
    return result;
}

# Encodes an outbound v1.0-shaped Message into the v0.3 wire shape, the
# mirror image of parseV03Message: role becomes lowercase "user"/"agent",
# every Part gets its "kind" discriminator, and the message itself is
# tagged "kind":"message" per the wire evidence in
# servers/adk_currency_agent/findings.md (a2a-interop-tests).
#
# + message - the outbound Message, in v1.0 shape as built by the caller
# + return - the equivalent v0.3 Message JSON to send on the wire, or an
#            error if the role is ROLE_UNSPECIFIED (or otherwise
#            unrecognized) or a Part can't be encoded
isolated function encodeV03Message(Message message) returns json|error {
    string wireRole = check encodeV03Role(message.role);

    json[] parts = [];
    foreach Part p in message.parts {
        parts.push(check encodeV03Part(p));
    }
    map<json> result = {
        messageId: message.messageId,
        role: wireRole,
        parts: parts,
        kind: "message"
    };
    string? contextId = message?.contextId;
    string? taskId = message?.taskId;
    map<json>? metadata = message?.metadata;
    if contextId is string {
        result["contextId"] = contextId;
    }
    if taskId is string {
        result["taskId"] = taskId;
    }
    if metadata is map<json> {
        result["metadata"] = metadata;
    }
    if message.referenceTaskIds.length() > 0 {
        result["referenceTaskIds"] = message.referenceTaskIds.toJson();
    }
    if message.extensions.length() > 0 {
        result["extensions"] = message.extensions.toJson();
    }
    return result;
}

# Encodes an outbound v1.0-shaped SendMessageConfiguration into the v0.3
# wire shape.
#
# `returnImmediately` and v0.3's `blocking` are inverted senses of the same
# switch (v1.0 defaults to blocking; v0.3 names the field after what it does
# when true), so this negates rather than renames.
# `taskPushNotificationConfig` is renamed to `pushNotificationConfig`, and
# its v1.0-only `taskId` sub-field is dropped: TaskPushNotificationConfig.taskId
# is documented ("Leave unset in a sendMessage request") as not applicable
# in this position, so it's never forwarded even if a caller set it.
# `acceptedOutputModes` and `historyLength` pass through unchanged.
#
# + config - the outbound SendMessageConfiguration, in v1.0 shape
# + return - the equivalent v0.3 configuration JSON to send on the wire
isolated function encodeV03SendConfiguration(SendMessageConfiguration config) returns json {
    map<json> result = {
        acceptedOutputModes: config.acceptedOutputModes.toJson(),
        blocking: !config.returnImmediately
    };
    int? historyLength = config?.historyLength;
    if historyLength is int {
        result["historyLength"] = historyLength;
    }
    TaskPushNotificationConfig? pushConfig = config?.taskPushNotificationConfig;
    if pushConfig is TaskPushNotificationConfig {
        map<json> wirePushConfig = {url: pushConfig.url};
        string? id = pushConfig?.id;
        string? token = pushConfig?.token;
        AuthenticationInfo? authentication = pushConfig?.authentication;
        if id is string {
            wirePushConfig["id"] = id;
        }
        if token is string {
            wirePushConfig["token"] = token;
        }
        if authentication is AuthenticationInfo {
            wirePushConfig["authentication"] = authentication.toJson();
        }
        result["pushNotificationConfig"] = wirePushConfig;
    }
    return result;
}

# Decodes a v0.3 sendMessage/message-send result, which is unwrapped and
# kind-tagged (unlike v1.0's {"task":...}/{"message":...} wrapper).
#
# + result - the raw JSON-RPC result field
# + return - the equivalent Task or Message, or an error
isolated function decodeV03SendResult(json result) returns Task|Message|error {
    map<json> m = check result.ensureType();
    string kind = check m["kind"].ensureType();
    match kind {
        "task" => {
            return parseV03Task(result);
        }
        "message" => {
            return parseV03Message(result);
        }
        _ => {
            return error(string `Unrecognized v0.3 sendMessage result kind: ${kind}`);
        }
    }
}

# Decodes one v0.3 stream event (kind-discriminated) into the same
# StreamResponse shape v1.0 streams already produce.
#
# + result - the raw JSON-RPC result field for one SSE event
# + return - the equivalent StreamResponse, or an error
isolated function decodeV03StreamEvent(json result) returns StreamResponse|error {
    map<json> m = check result.ensureType();
    string kind = check m["kind"].ensureType();

    match kind {
        "task" => {
            Task t = check parseV03Task(result);
            return {task: t};
        }
        "message" => {
            Message msg = check parseV03Message(result);
            return {message: msg};
        }
        "status-update" => {
            TaskStatus status = check parseV03TaskStatus(m["status"]);
            map<json> v1Shape = {
                taskId: check m["taskId"].ensureType(),
                contextId: check m["contextId"].ensureType(),
                status: status.toJson()
            };
            if m.hasKey("metadata") {
                v1Shape["metadata"] = m["metadata"];
            }
            // "final" (v0.3-only) is deliberately not copied across — see
            // the design spec's evidence that it's pure derived redundancy
            // and testDecodeV03StreamEventIgnoresFinalField above.
            TaskStatusUpdateEvent event = check v1Shape.cloneWithType(TaskStatusUpdateEvent);
            return {statusUpdate: event};
        }
        "artifact-update" => {
            Artifact artifact = check parseV03Artifact(m["artifact"]);
            map<json> v1Shape = {
                taskId: check m["taskId"].ensureType(),
                contextId: check m["contextId"].ensureType(),
                artifact: artifact.toJson()
            };
            if m.hasKey("append") {
                v1Shape["append"] = m["append"];
            }
            if m.hasKey("lastChunk") {
                v1Shape["lastChunk"] = m["lastChunk"];
            }
            if m.hasKey("metadata") {
                v1Shape["metadata"] = m["metadata"];
            }
            TaskArtifactUpdateEvent event = check v1Shape.cloneWithType(TaskArtifactUpdateEvent);
            return {artifactUpdate: event};
        }
        _ => {
            return error(string `Unrecognized v0.3 stream event kind: ${kind}`);
        }
    }
}

# Converts a v0.3 TaskPushNotificationConfig into the v1.0 shape.
#
# Verified against a2a-sdk 0.3.23's types.py: v0.3's
# TaskPushNotificationConfig is a NESTED wrapper with exactly two
# top-level fields — task_id (wire "taskId") and push_notification_config
# (wire "pushNotificationConfig", itself holding url/id/token/authentication)
# — unlike v1.0's flat record. There is no "tenant" field in v0.3 at all
# (per-AgentInterface tenant routing is a v1.0-only concept), so none is
# read here.
#
# + configJson - the raw v0.3 TaskPushNotificationConfig JSON
# + return - the equivalent v1.0 TaskPushNotificationConfig, or an error if malformed
isolated function parseV03TaskPushNotificationConfig(json configJson) returns TaskPushNotificationConfig|error {
    map<json> m = check configJson.ensureType();
    map<json> pushConfig = check m["pushNotificationConfig"].ensureType();
    map<json> v1Shape = {
        url: check pushConfig["url"].ensureType()
    };
    if pushConfig.hasKey("id") {
        v1Shape["id"] = pushConfig["id"];
    }
    if pushConfig.hasKey("token") {
        v1Shape["token"] = pushConfig["token"];
    }
    if pushConfig.hasKey("authentication") {
        v1Shape["authentication"] = pushConfig["authentication"];
    }
    if m.hasKey("taskId") {
        v1Shape["taskId"] = m["taskId"];
    }
    return check v1Shape.cloneWithType(TaskPushNotificationConfig);
}

# Mirror image of parseV03TaskPushNotificationConfig. Returns map<json>
# rather than the bare json most other encodeV03* functions return,
# because this one is used as the ENTIRE outbound params map (the spec's
# request IS a TaskPushNotificationConfig, no wrapper) rather than
# nested under a key the way encodeV03Message is under "message" —
# callers need an assignable map<json>, not a widened json value.
#
# Builds the same nested {"taskId":..., "pushNotificationConfig": {url,
# id, token, authentication}} shape as encodeV03SendConfiguration already
# does for SendMessageConfiguration.taskPushNotificationConfig — this is
# that same nesting, just used as the top-level params map instead of a
# nested field. tenant is deliberately never copied across: v0.3 has no
# wire counterpart for it (per-AgentInterface tenant routing is a
# v1.0-only concept), the same rule every other v0.3-mode method in this
# codebase follows.
#
# + config - the outbound TaskPushNotificationConfig, in v1.0 shape
# + return - the equivalent v0.3 TaskPushNotificationConfig JSON
isolated function encodeV03TaskPushNotificationConfig(TaskPushNotificationConfig config) returns map<json> {
    map<json> wirePushConfig = {url: config.url};
    string? id = config?.id;
    string? token = config?.token;
    AuthenticationInfo? authentication = config?.authentication;
    if id is string {
        wirePushConfig["id"] = id;
    }
    if token is string {
        wirePushConfig["token"] = token;
    }
    if authentication is AuthenticationInfo {
        wirePushConfig["authentication"] = authentication.toJson();
    }

    map<json> result = {pushNotificationConfig: wirePushConfig};
    string? taskId = config?.taskId;
    if taskId is string {
        result["taskId"] = taskId;
    }
    return result;
}

# Verified against a2a-sdk 0.3.23's types.py:
# ListTaskPushNotificationConfigSuccessResponse.result is a BARE JSON
# array of TaskPushNotificationConfig, not a {configs, nextPageToken}
# wrapper — v0.3 has no pagination concept for this operation at all, so
# nextPageToken is synthesized as "" here rather than read from the wire.
#
# + resultJson - the raw v0.3 ListTaskPushNotificationConfigs result JSON (a bare array)
# + return - the equivalent v1.0 ListTaskPushNotificationConfigsResult, or an error if malformed
isolated function parseV03ListTaskPushNotificationConfigsResult(json resultJson) returns ListTaskPushNotificationConfigsResult|error {
    json[] rawConfigs = check resultJson.ensureType();
    TaskPushNotificationConfig[] configs = [];
    foreach json c in rawConfigs {
        configs.push(check parseV03TaskPushNotificationConfig(c));
    }
    return {configs, nextPageToken: ""};
}

# Renames the v0.3-dialect `security` key to the v1.0 field name
# `securityRequirements`, at the AgentCard's top level and within each
# element of `skills`, so a v0.3 server's security-requirement data
# populates the typed field instead of falling into the open record's
# untyped rest fields. Presence-based rather than mode-based: this must
# run before an AgentCard is typed-parsed at all, before the protocol
# dialect can be detected from the parsed card, so it looks at the raw
# JSON shape directly instead. A no-op when `securityRequirements` is
# already present (v1.0 cards) or `security` is absent (cards with no
# security fields at all).
#
# + raw - the raw JSON AgentCard body, before typed parsing
# + return - the body with `security` renamed to `securityRequirements`
#            wherever applicable
isolated function renameV03SecurityField(json raw) returns json {
    if raw !is map<json> {
        return raw;
    }
    map<json> cardMap = raw.clone();
    if cardMap.hasKey("security") && !cardMap.hasKey("securityRequirements") {
        cardMap["securityRequirements"] = cardMap.remove("security");
    }

    json? skillsField = cardMap["skills"];
    if skillsField is json[] {
        json[] renamedSkills = [];
        foreach json skillJson in skillsField {
            if skillJson is map<json> {
                map<json> skillMap = skillJson.clone();
                if skillMap.hasKey("security") && !skillMap.hasKey("securityRequirements") {
                    skillMap["securityRequirements"] = skillMap.remove("security");
                }
                renamedSkills.push(skillMap);
            } else {
                renamedSkills.push(skillJson);
            }
        }
        cardMap["skills"] = renamedSkills;
    }

    return cardMap;
}
