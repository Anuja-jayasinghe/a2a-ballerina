// Conversion layer between the generated grpcstub:* protobuf types and
// this library's own types.bal domain types. Mirrors compat_v03.bal's
// encodeV03*/parseV03* pattern for the same reason: the generated records
// are structurally incompatible with types.bal (snake_case fields, closed
// records, sentinel-default presence, map fields as key/value arrays,
// google.protobuf.Timestamp as a time:Utc tuple) — see the design spec's
// Finding 4 for the full enumeration. No amount of cloneWithType bridges
// that.
import ballerina/a2a.grpcstub;
import ballerina/time;

# Converts a generated proto map field (a key/value record array, since
# protobuf maps generate that shape rather than a real Ballerina map — see
# design spec Finding 4d) into a real map<string>.
#
# + kv - the generated key/value array
# + return - an equivalent map<string>
isolated function grpcKvToMap(record {|string key; string value;|}[] kv) returns map<string> {
    map<string> result = {};
    foreach var entry in kv {
        result[entry.key] = entry.value;
    }
    return result;
}

# The reverse of grpcKvToMap: builds the key/value array shape a generated
# proto map field expects from a real map<string>.
#
# + m - the map to convert
# + return - the equivalent key/value array
isolated function mapToGrpcKv(map<string> m) returns record {|string key; string value;|}[] {
    record {|string key; string value;|}[] result = [];
    foreach [string, string] [k, v] in m.entries() {
        result.push({key: k, value: v});
    }
    return result;
}

# Converts a generated google.protobuf.Timestamp (time:Utc tuple) into an
# RFC 3339 string, per types.bal's string? timestamp field convention.
# The proto3 sentinel default [0, 0.0d] (Unix epoch) decodes to () rather
# than to "1970-01-01T00:00:00Z" — per design spec Design decision 5, rule
# 3, this is the highest-risk silent-corruption case in the whole layer: a
# TaskStatus.timestamp of [0, 0.0d] means "field not set", not "set to the
# epoch."
#
# + ts - the generated timestamp value
# + return - the RFC 3339 string, or () if ts is the proto3 zero-default
isolated function grpcTimestampToString(time:Utc ts) returns string? {
    if ts[0] == 0 && ts[1] == 0.0d {
        return ();
    }
    // time:utcToString already renders the fractional-second component
    // (ts[1], a decimal in [0, 1)) correctly when non-zero, e.g.
    // "2023-10-27T10:00:00.500Z". No manual millisecond suffix is needed
    // -- appending one here would double up the fractional part and
    // produce a string that stringToGrpcTimestamp can't parse back.
    return time:utcToString(ts);
}

# The reverse of grpcTimestampToString: () encodes to the proto3
# zero-default [0, 0.0d], matching what an unset non-optional Timestamp
# field looks like on the wire.
#
# + s - the RFC 3339 string, or ()
# + return - the equivalent time:Utc tuple, or an error if s is a non-()
#            value that isn't valid RFC 3339
isolated function stringToGrpcTimestamp(string? s) returns time:Utc|error {
    if s is () {
        return [0, 0.0d];
    }
    return check time:utcFromString(s);
}

# Non-optional proto3 string fields default to "" when unset; types.bal
# models the same fields as string?. Per design spec Design decision 5,
# rule 1, "" always decodes to () for these fields — there is no way on
# the wire to distinguish "explicitly set to empty string" from "unset",
# so () is the only correct decoding.
#
# + s - the generated string field's value
# + return - s unchanged, or () if s is empty
isolated function emptyGrpcStringToNil(string s) returns string? {
    return s.length() == 0 ? () : s;
}

# Converts a generated google.protobuf.Struct field (map<anydata>, per
# design spec Finding 4d) into map<json>?, matching types.bal's metadata/
# params/header field convention. An empty struct decodes to () rather
# than {} — per Design decision 5 rule 2, an all-defaults nested message
# means "not set," and an empty Struct is exactly that case for this
# field type.
#
# + struct - the generated Struct field's value
# + return - the equivalent map<json>, or () if struct is empty, or an
#            error if a value inside it falls outside json's value space
isolated function grpcStructToJson(map<anydata> struct) returns map<json>?|error {
    if struct.length() == 0 {
        return ();
    }
    json|error asJson = struct.cloneWithType(json);
    if asJson is error {
        return error InvalidAgentResponseError(
            string `struct field could not be narrowed to json: ${asJson.message()}`,
            message = string `struct field could not be narrowed to json: ${asJson.message()}`
        );
    }
    map<json>|error result = asJson.ensureType();
    if result is error {
        return error InvalidAgentResponseError(
            string `struct field could not be narrowed to json: ${result.message()}`,
            message = string `struct field could not be narrowed to json: ${result.message()}`
        );
    }
    return result;
}

# The reverse of grpcStructToJson: () or an empty map both encode to an
# empty map<anydata> (the proto3 wire representation of "no Struct set").
#
# + j - the map<json>? field's value
# + return - the equivalent map<anydata>
isolated function jsonToGrpcStruct(map<json>? j) returns map<anydata> {
    if j is () {
        return {};
    }
    return j;
}

# Converts a typed Part into the generated grpcstub:Part shape.
#
# Callers must pass an already-typed Part (raw as byte[]?, not a base64
# string) — this function does not undo base64 encoding. That undoing, if
# needed, happens one layer up in encodeGrpcRequest (see its doc comment),
# not here, because this function's contract is "typed Part in, typed
# grpcstub:Part out," and base64 is a JSON-RPC/REST wire concern that
# never should have reached a typed Part value in the first place.
#
# + p - the Part to encode
# + return - the equivalent grpcstub:Part, or an error if p.data cannot be
#            widened (it always can: json is a strict subtype of anydata)
isolated function encodeGrpcPart(Part p) returns grpcstub:Part|error {
    grpcstub:Part result = {
        metadata: jsonToGrpcStruct(p?.metadata)
    };
    string? text = p?.text;
    byte[]? raw = p?.raw;
    string? url = p?.url;
    json? data = p?.data;
    if text is string {
        result.text = text;
    } else if raw is byte[] {
        result.raw = raw;
    } else if url is string {
        result.url = url;
    } else if data !is () {
        // json is a strict subtype of anydata, so this widening is total
        // and lossless (design spec Design decision 5, rule 5).
        result.data = data;
    }
    string? filename = p?.filename;
    if filename is string {
        result.filename = filename;
    }
    string? mediaType = p?.mediaType;
    if mediaType is string {
        result.media_type = mediaType;
    }
    return result;
}

# Converts a generated grpcstub:Part into a typed Part.
#
# + p - the generated Part to decode
# + partIndex - this part's index within its containing parts array, used
#               only to name the offending part in a narrowing-failure
#               error message
# + return - the equivalent typed Part, or InvalidAgentResponseError if
#            p.data (typed anydata on the wire, per the
#            google_protobuf_Value -> anydata workaround) holds a runtime
#            value json cannot represent — see design spec Design decision
#            5, rule 5, for why this is a real possible failure and not a
#            defensive check against something that can't happen
isolated function decodeGrpcPart(grpcstub:Part p, int partIndex) returns Part|error {
    Part result = {};
    string? text = p?.text;
    byte[]? raw = p?.raw;
    string? url = p?.url;
    anydata? data = p?.data;
    if text is string {
        result.text = text;
    } else if raw is byte[] {
        result.raw = raw;
    } else if url is string {
        result.url = url;
    } else if data !is () {
        json|error narrowed = trap data.cloneWithType(json);
        if narrowed is error {
            return error InvalidAgentResponseError(
                string `Part[${partIndex}].data holds a value that cannot be represented as json: ${narrowed.message()}`,
                message = string `Part[${partIndex}].data holds a value that cannot be represented as json: ${narrowed.message()}`,
                code = -32006
            );
        }
        result.data = narrowed;
    }
    string? filename = emptyGrpcStringToNil(p.filename);
    if filename is string {
        result.filename = filename;
    }
    string? mediaType = emptyGrpcStringToNil(p.media_type);
    if mediaType is string {
        result.mediaType = mediaType;
    }
    map<json>? metadata = check grpcStructToJson(p.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# Converts a typed Message into the generated grpcstub:Message shape.
#
# + m - the Message to encode
# + return - the equivalent grpcstub:Message
isolated function encodeGrpcMessage(Message m) returns grpcstub:Message|error {
    grpcstub:Part[] parts = [];
    foreach Part p in m.parts {
        parts.push(check encodeGrpcPart(p));
    }
    grpcstub:Message result = {
        message_id: m.messageId,
        role: <grpcstub:Role>m.role,
        parts: parts,
        reference_task_ids: m.referenceTaskIds,
        extensions: m.extensions,
        metadata: jsonToGrpcStruct(m?.metadata)
    };
    string? contextId = m?.contextId;
    if contextId is string {
        result.context_id = contextId;
    }
    string? taskId = m?.taskId;
    if taskId is string {
        result.task_id = taskId;
    }
    return result;
}

# Converts a generated grpcstub:Message into a typed Message.
#
# + m - the generated grpcstub:Message to decode
# + return - the equivalent typed Message
isolated function decodeGrpcMessage(grpcstub:Message m) returns Message|error {
    Part[] parts = [];
    foreach grpcstub:Part p in m.parts {
        parts.push(check decodeGrpcPart(p, parts.length()));
    }
    Message result = {
        messageId: m.message_id,
        role: <Role>m.role,
        parts: parts,
        referenceTaskIds: m.reference_task_ids,
        extensions: m.extensions
    };
    string? contextId = emptyGrpcStringToNil(m.context_id);
    if contextId is string {
        result.contextId = contextId;
    }
    string? taskId = emptyGrpcStringToNil(m.task_id);
    if taskId is string {
        result.taskId = taskId;
    }
    map<json>? metadata = check grpcStructToJson(m.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# Converts a typed SendMessageConfiguration into the generated
# grpcstub:SendMessageConfiguration shape.
#
# + c - the SendMessageConfiguration to encode
# + return - the equivalent grpcstub:SendMessageConfiguration
isolated function encodeGrpcSendConfiguration(SendMessageConfiguration c) returns grpcstub:SendMessageConfiguration|error {
    grpcstub:SendMessageConfiguration result = {
        accepted_output_modes: c.acceptedOutputModes,
        return_immediately: c.returnImmediately
    };
    int? historyLength = c?.historyLength;
    if historyLength is int {
        result.history_length = historyLength;
    }
    TaskPushNotificationConfig? cb = c?.taskPushNotificationConfig;
    if cb is TaskPushNotificationConfig {
        result.task_push_notification_config = check encodeGrpcPushConfig(cb);
    }
    return result;
}

# Converts a typed TaskPushNotificationConfig into the generated
# grpcstub:TaskPushNotificationConfig shape.
#
# + c - the TaskPushNotificationConfig to encode
# + return - the equivalent grpcstub:TaskPushNotificationConfig
isolated function encodeGrpcPushConfig(TaskPushNotificationConfig c) returns grpcstub:TaskPushNotificationConfig|error {
    grpcstub:TaskPushNotificationConfig result = {url: c.url};
    string? id = c?.id;
    if id is string {
        result.id = id;
    }
    string? taskId = c?.taskId;
    if taskId is string {
        result.task_id = taskId;
    }
    string? token = c?.token;
    if token is string {
        result.token = token;
    }
    AuthenticationInfo? auth = c?.authentication;
    if auth is AuthenticationInfo {
        grpcstub:AuthenticationInfo grpcAuth = {scheme: auth.scheme};
        string? credentials = auth?.credentials;
        if credentials is string {
            grpcAuth.credentials = credentials;
        }
        result.authentication = grpcAuth;
    }
    string? tenant = c?.tenant;
    if tenant is string {
        result.tenant = tenant;
    }
    return result;
}

# Converts a generated grpcstub:TaskPushNotificationConfig into a typed
# TaskPushNotificationConfig.
#
# grpcstub:TaskPushNotificationConfig.authentication is a non-optional
# AuthenticationInfo field defaulting to {scheme: "", credentials: ""} when
# unset (proto3 nested-message zero value), not an optional field -- so
# `c?.authentication` alone never yields (), it always yields that
# zero-value record. Per design spec Design decision 5 rule 2, an
# all-defaults nested message means "not set", and the only field of
# AuthenticationInfo that's required in the typed domain type is `scheme`,
# so an empty scheme is what "not set" looks like here. Guarding on
# emptyGrpcStringToNil(grpcAuth.scheme) is what actually distinguishes
# "caller set authentication" from "caller left it unset" -- checking
# `is grpcstub:AuthenticationInfo` alone (as opposed to a plain type check)
# would always be true and wrongly decode every unset config into
# {scheme: ""}, which also isn't a legal AuthenticationInfo (scheme is
# required and non-empty by convention).
#
# + c - the generated grpcstub:TaskPushNotificationConfig to decode
# + return - the equivalent typed TaskPushNotificationConfig
isolated function decodeGrpcPushConfig(grpcstub:TaskPushNotificationConfig c) returns TaskPushNotificationConfig|error {
    TaskPushNotificationConfig result = {url: c.url};
    string? id = emptyGrpcStringToNil(c.id);
    if id is string {
        result.id = id;
    }
    string? taskId = emptyGrpcStringToNil(c.task_id);
    if taskId is string {
        result.taskId = taskId;
    }
    string? token = emptyGrpcStringToNil(c.token);
    if token is string {
        result.token = token;
    }
    grpcstub:AuthenticationInfo grpcAuth = c.authentication;
    string? scheme = emptyGrpcStringToNil(grpcAuth.scheme);
    if scheme is string {
        AuthenticationInfo auth = {scheme: scheme};
        string? credentials = emptyGrpcStringToNil(grpcAuth.credentials);
        if credentials is string {
            auth.credentials = credentials;
        }
        result.authentication = auth;
    }
    string? tenant = emptyGrpcStringToNil(c.tenant);
    if tenant is string {
        result.tenant = tenant;
    }
    return result;
}

# Converts a generated grpcstub:TaskStatus into a typed TaskStatus.
#
# grpcstub:TaskStatus.message and .timestamp are both non-optional fields
# with proto3 zero-value defaults ({message_id: "", role: ROLE_UNSPECIFIED,
# parts: []} and [0, 0.0d] respectively), not real Ballerina optional
# fields -- so `s?.message`/`s?.timestamp` never yield (), they always
# yield the zero-value record/tuple when unset. Per design spec Design
# decision 5 rule 2, an all-defaults nested Message means "not set": since
# Message has no single required field the way AuthenticationInfo has
# `scheme`, message_id and parts together are what "someone actually built
# this Message" looks like (role alone, e.g. ROLE_USER with no id/parts,
# is not a case the wire produces on decode of a genuinely-set message).
# timestamp reuses grpcTimestampToString, which already implements rule 3
# for the exact same [0, 0.0d] sentinel.
#
# + s - the generated grpcstub:TaskStatus to decode
# + return - the equivalent typed TaskStatus
isolated function decodeGrpcTaskStatus(grpcstub:TaskStatus s) returns TaskStatus|error {
    TaskStatus result = {state: <TaskState>s.state};
    grpcstub:Message msg = s.message;
    if msg.message_id.length() > 0 || msg.parts.length() > 0 {
        result.message = check decodeGrpcMessage(msg);
    }
    string? tsString = grpcTimestampToString(s.timestamp);
    if tsString is string {
        result.timestamp = tsString;
    }
    return result;
}

# Converts a generated grpcstub:Artifact into a typed Artifact.
#
# + a - the generated grpcstub:Artifact to decode
# + return - the equivalent typed Artifact
isolated function decodeGrpcArtifact(grpcstub:Artifact a) returns Artifact|error {
    Part[] parts = [];
    foreach grpcstub:Part p in a.parts {
        parts.push(check decodeGrpcPart(p, parts.length()));
    }
    Artifact result = {artifactId: a.artifact_id, parts, extensions: a.extensions};
    string? name = emptyGrpcStringToNil(a.name);
    if name is string {
        result.name = name;
    }
    string? description = emptyGrpcStringToNil(a.description);
    if description is string {
        result.description = description;
    }
    map<json>? metadata = check grpcStructToJson(a.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# Converts a generated grpcstub:Task into a typed Task.
#
# + t - the generated grpcstub:Task to decode
# + return - the equivalent typed Task
isolated function decodeGrpcTask(grpcstub:Task t) returns Task|error {
    Message[] history = [];
    foreach grpcstub:Message m in t.history {
        history.push(check decodeGrpcMessage(m));
    }
    Artifact[] artifacts = [];
    foreach grpcstub:Artifact a in t.artifacts {
        artifacts.push(check decodeGrpcArtifact(a));
    }
    Task result = {
        id: t.id,
        status: check decodeGrpcTaskStatus(t.status),
        history,
        artifacts
    };
    string? contextId = emptyGrpcStringToNil(t.context_id);
    if contextId is string {
        result.contextId = contextId;
    }
    map<json>? metadata = check grpcStructToJson(t.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# Converts a generated grpcstub:TaskStatusUpdateEvent into a typed
# TaskStatusUpdateEvent.
#
# + e - the generated grpcstub:TaskStatusUpdateEvent to decode
# + return - the equivalent typed TaskStatusUpdateEvent
isolated function decodeGrpcStatusUpdate(grpcstub:TaskStatusUpdateEvent e) returns TaskStatusUpdateEvent|error {
    TaskStatusUpdateEvent result = {
        taskId: e.task_id,
        contextId: e.context_id,
        status: check decodeGrpcTaskStatus(e.status)
    };
    map<json>? metadata = check grpcStructToJson(e.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# Converts a generated grpcstub:TaskArtifactUpdateEvent into a typed
# TaskArtifactUpdateEvent.
#
# + e - the generated grpcstub:TaskArtifactUpdateEvent to decode
# + return - the equivalent typed TaskArtifactUpdateEvent
isolated function decodeGrpcArtifactUpdate(grpcstub:TaskArtifactUpdateEvent e) returns TaskArtifactUpdateEvent|error {
    TaskArtifactUpdateEvent result = {
        taskId: e.task_id,
        contextId: e.context_id,
        artifact: check decodeGrpcArtifact(e.artifact),
        append: e.append,
        lastChunk: e.last_chunk
    };
    map<json>? metadata = check grpcStructToJson(e.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}

# Converts a generated grpcstub:SendMessageResponse into the Task or
# Message it wraps.
#
# grpcstub:SendMessageResponse.task and .message are both genuinely
# proto3-optional (a real oneof), unlike the mandatory-with-zero-value
# fields elsewhere in this file -- so `resp?.task`/`resp?.message` do
# correctly yield () when unset, and a plain `is` check is the right tool
# here, not emptyGrpcStringToNil or the all-defaults pattern.
#
# + resp - the generated grpcstub:SendMessageResponse to decode
# + return - the Task or Message it wraps, or InvalidAgentResponseError if
#            neither is set — mirroring rpcCall's own JSON-RPC-side check
#            for the identical malformed-response shape
isolated function decodeGrpcSendResult(grpcstub:SendMessageResponse resp) returns Task|Message|error {
    grpcstub:Task? t = resp?.task;
    grpcstub:Message? m = resp?.message;
    if t is grpcstub:Task {
        return decodeGrpcTask(t);
    }
    if m is grpcstub:Message {
        return decodeGrpcMessage(m);
    }
    return error InvalidAgentResponseError(
        "gRPC SendMessageResponse contained neither a task nor a message",
        message = "gRPC SendMessageResponse contained neither a task nor a message"
    );
}

# Converts a generated grpcstub:StreamResponse into a typed StreamResponse.
#
# grpcstub:StreamResponse's four fields are all genuinely proto3-optional
# (a real oneof, same as SendMessageResponse above), so a plain `is` check
# per field is correct here too.
#
# + resp - the generated grpcstub:StreamResponse to decode
# + return - the equivalent typed StreamResponse, with exactly the one
#            field set that the oneof carried
isolated function decodeGrpcStreamResponse(grpcstub:StreamResponse resp) returns StreamResponse|error {
    grpcstub:Task? t = resp?.task;
    if t is grpcstub:Task {
        return {task: check decodeGrpcTask(t)};
    }
    grpcstub:Message? m = resp?.message;
    if m is grpcstub:Message {
        return {message: check decodeGrpcMessage(m)};
    }
    grpcstub:TaskStatusUpdateEvent? su = resp?.status_update;
    if su is grpcstub:TaskStatusUpdateEvent {
        return {statusUpdate: check decodeGrpcStatusUpdate(su)};
    }
    grpcstub:TaskArtifactUpdateEvent? au = resp?.artifact_update;
    if au is grpcstub:TaskArtifactUpdateEvent {
        return {artifactUpdate: check decodeGrpcArtifactUpdate(au)};
    }
    return error InvalidAgentResponseError(
        "gRPC StreamResponse contained none of task/message/status_update/artifact_update",
        message = "gRPC StreamResponse contained none of task/message/status_update/artifact_update"
    );
}

# + resp - the generated grpcstub:ListTasksResponse to decode
# + return - the equivalent typed ListTasksResult
isolated function decodeGrpcListTasksResult(grpcstub:ListTasksResponse resp) returns ListTasksResult|error {
    Task[] tasks = [];
    foreach grpcstub:Task t in resp.tasks {
        tasks.push(check decodeGrpcTask(t));
    }
    return {
        tasks,
        nextPageToken: resp.next_page_token,
        pageSize: resp.page_size,
        totalSize: resp.total_size
    };
}

# + resp - the generated grpcstub:ListTaskPushNotificationConfigsResponse to decode
# + return - the equivalent typed ListTaskPushNotificationConfigsResult
isolated function decodeGrpcListPushConfigsResult(grpcstub:ListTaskPushNotificationConfigsResponse resp) returns ListTaskPushNotificationConfigsResult|error {
    TaskPushNotificationConfig[] configs = [];
    foreach grpcstub:TaskPushNotificationConfig c in resp.configs {
        configs.push(check decodeGrpcPushConfig(c));
    }
    return {configs, nextPageToken: resp.next_page_token};
}
