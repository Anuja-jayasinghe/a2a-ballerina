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

import ballerina/a2a.grpcstub;
import ballerina/test;
import ballerina/time;

@test:Config {groups: ["grpc"]}
function testGrpcKvToMapStringValues() {
    record {|string key; string value;|}[] kv = [{key: "a", value: "1"}, {key: "b", value: "2"}];
    map<string> result = grpcKvToMap(kv);
    test:assertEquals(result, {"a": "1", "b": "2"});
}

@test:Config {groups: ["grpc"]}
function testMapToGrpcKvStringValues() {
    map<string> m = {"a": "1", "b": "2"};
    record {|string key; string value;|}[] result = mapToGrpcKv(m);
    test:assertEquals(result.length(), 2);
    map<string> roundTripped = grpcKvToMap(result);
    test:assertEquals(roundTripped, m);
}

@test:Config {groups: ["grpc"]}
function testGrpcTimestampToStringDefaultIsAbsent() {
    time:Utc zeroTimestamp = [0, 0.0d];
    test:assertEquals(grpcTimestampToString(zeroTimestamp), ());
}

@test:Config {groups: ["grpc"]}
function testGrpcTimestampToStringRealValue() returns error? {
    time:Utc ts = check time:utcFromString("2023-10-27T10:00:00Z");
    test:assertEquals(grpcTimestampToString(ts), "2023-10-27T10:00:00Z");
}

@test:Config {groups: ["grpc"]}
function testStringToGrpcTimestampRoundTrips() returns error? {
    time:Utc ts = check stringToGrpcTimestamp("2023-10-27T10:00:00Z");
    test:assertEquals(grpcTimestampToString(ts), "2023-10-27T10:00:00Z");
}

@test:Config {groups: ["grpc"]}
function testGrpcTimestampToStringSubSecondPrecision() returns error? {
    // Regression test: the millisecond-suffix logic previously treated
    // ts[1] (the fractional-second component, range [0, 1)) as if it were
    // nanoseconds, and then appended a manual ".000Z" suffix on top of
    // time:utcToString's own correct fractional rendering -- producing a
    // doubly-fractioned string like "...10:00:00.500.000Z" that failed to
    // parse back via stringToGrpcTimestamp.
    time:Utc ts500 = check stringToGrpcTimestamp("2023-10-27T10:00:00.500Z");
    string? str500 = grpcTimestampToString(ts500);
    test:assertEquals(str500, "2023-10-27T10:00:00.500Z");
    time:Utc roundTripped500 = check stringToGrpcTimestamp(str500);
    test:assertEquals(roundTripped500, ts500);

    time:Utc ts123 = check stringToGrpcTimestamp("2023-10-27T10:00:00.123Z");
    string? str123 = grpcTimestampToString(ts123);
    test:assertEquals(str123, "2023-10-27T10:00:00.123Z");
    time:Utc roundTripped123 = check stringToGrpcTimestamp(str123);
    test:assertEquals(roundTripped123, ts123);
}

@test:Config {groups: ["grpc"]}
function testStringToGrpcTimestampAbsentIsZero() returns error? {
    time:Utc ts = check stringToGrpcTimestamp(());
    test:assertEquals(ts, [0, 0.0d]);
}

@test:Config {groups: ["grpc"]}
function testEmptyGrpcStringToNil() {
    test:assertEquals(emptyGrpcStringToNil(""), ());
    test:assertEquals(emptyGrpcStringToNil("x"), "x");
}

@test:Config {groups: ["grpc"]}
function testGrpcStructRoundTrip() returns error? {
    map<json> original = {"a": 1, "b": "two", "c": {"nested": true}};
    map<anydata> struct = jsonToGrpcStruct(original);
    map<json>? back = check grpcStructToJson(struct);
    test:assertEquals(back, original);
}

@test:Config {groups: ["grpc"]}
function testGrpcStructEmptyMapIsAbsent() returns error? {
    map<anydata> struct = {};
    map<json>? back = check grpcStructToJson(struct);
    test:assertEquals(back, ());
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartTextRoundTrips() returns error? {
    Part original = {text: "hello", mediaType: "text/plain"};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartRawBytesRoundTrips() returns error? {
    byte[] bytes = "raw bytes here".toBytes();
    Part original = {raw: bytes, filename: "f.bin", mediaType: "application/octet-stream"};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    test:assertEquals(encoded.raw, bytes, "encodeGrpcPart must assign raw bytes directly, no base64");
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartUrlRoundTrips() returns error? {
    Part original = {url: "https://example.com/f.png", mediaType: "image/png"};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartDataRoundTrips() returns error? {
    Part original = {data: {"k": "v", "n": 1}};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePartMetadataRoundTrips() returns error? {
    Part original = {text: "with metadata", metadata: {"trace": "abc"}};
    grpcstub:Part encoded = check encodeGrpcPart(original);
    Part decoded = check decodeGrpcPart(encoded, 0);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcPartRejectsZeroVariantsSet() {
    Part empty = {};
    grpcstub:Part|error result = encodeGrpcPart(empty);
    test:assertTrue(result is A2AInternalError, "a caller-constructed Part with none of text/raw/url/data set is an internal, not agent, error");
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcPartRejectsMultipleVariantsSet() {
    Part ambiguous = {text: "hi", url: "https://example.com/x"};
    grpcstub:Part|error result = encodeGrpcPart(ambiguous);
    test:assertTrue(result is A2AInternalError, "a caller-constructed Part with more than one of text/raw/url/data set must be rejected, not silently narrowed to one");
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcPartRejectsZeroVariantsSet() {
    grpcstub:Part empty = {};
    Part|error result = decodeGrpcPart(empty, 0);
    test:assertTrue(result is InvalidAgentResponseError, "an agent sending a Part with none of text/raw/url/data set is the agent's fault, not ours");
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcPartRejectsMultipleVariantsSet() {
    grpcstub:Part ambiguous = {text: "hi", url: "https://example.com/x"};
    Part|error result = decodeGrpcPart(ambiguous, 0);
    test:assertTrue(result is InvalidAgentResponseError, "an agent sending a Part with more than one of text/raw/url/data set must be rejected, not silently narrowed to one");
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodeMessageRoundTrips() returns error? {
    Message original = {
        messageId: "m1", role: ROLE_USER,
        parts: [{text: "hi"}, {url: "https://example.com/x"}],
        contextId: "ctx1", taskId: "task1",
        referenceTaskIds: ["task0"], extensions: ["urn:ext:one"],
        metadata: {"k": "v"}
    };
    grpcstub:Message encoded = check encodeGrpcMessage(original);
    Message decoded = check decodeGrpcMessage(encoded);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodeMessageMinimalRoundTrips() returns error? {
    Message original = {messageId: "m2", role: ROLE_AGENT, parts: [{text: "hi"}]};
    grpcstub:Message encoded = check encodeGrpcMessage(original);
    Message decoded = check decodeGrpcMessage(encoded);
    test:assertEquals(decoded.messageId, original.messageId);
    test:assertEquals(decoded.role, original.role);
    test:assertEquals(decoded.parts, original.parts);
    test:assertEquals(decoded?.contextId, ());
    test:assertEquals(decoded?.taskId, ());
    test:assertEquals(decoded.referenceTaskIds, []);
    test:assertEquals(decoded.extensions, []);
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcSendConfiguration() returns error? {
    SendMessageConfiguration config = {
        acceptedOutputModes: ["text", "image/png"],
        historyLength: 5,
        returnImmediately: true,
        taskPushNotificationConfig: {url: "https://cb.example.com", taskId: "t1"}
    };
    grpcstub:SendMessageConfiguration encoded = check encodeGrpcSendConfiguration(config);
    test:assertEquals(encoded.accepted_output_modes, ["text", "image/png"]);
    test:assertEquals(encoded.history_length, 5);
    test:assertEquals(encoded.return_immediately, true);
    grpcstub:TaskPushNotificationConfig? cb = encoded?.task_push_notification_config;
    test:assertTrue(cb is grpcstub:TaskPushNotificationConfig);
    test:assertEquals((<grpcstub:TaskPushNotificationConfig>cb).url, "https://cb.example.com");
}

@test:Config {groups: ["grpc"]}
function testEncodeDecodePushConfigRoundTrips() returns error? {
    TaskPushNotificationConfig original = {
        url: "https://cb.example.com", id: "cfg1", taskId: "task1",
        token: "tok", authentication: {scheme: "Bearer", credentials: "abc"},
        tenant: "tenant1"
    };
    grpcstub:TaskPushNotificationConfig encoded = check encodeGrpcPushConfig(original);
    TaskPushNotificationConfig decoded = check decodeGrpcPushConfig(encoded);
    test:assertEquals(decoded, original);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcPartDataNarrowingFailureReturnsTypedError() {
    // A value outside json's value space: a table, which anydata admits
    // but json does not.
    table<map<anydata>> notJson = table [{"x": 1}];
    grpcstub:Part malformed = {data: notJson};
    Part|error decoded = decodeGrpcPart(malformed, 3);
    test:assertTrue(decoded is InvalidAgentResponseError, "expected InvalidAgentResponseError for a data value outside json's value space");
    if decoded is InvalidAgentResponseError {
        string msg = decoded.message();
        test:assertTrue(msg.includes("3"), "error message should name the offending part index");
    }
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcTaskStatusAllDefaultsIsNoMessage() returns error? {
    grpcstub:TaskStatus grpcStatus = {state: grpcstub:TASK_STATE_WORKING};
    TaskStatus status = check decodeGrpcTaskStatus(grpcStatus);
    test:assertEquals(status.state, TASK_STATE_WORKING);
    test:assertEquals(status?.message, (), "an all-defaults nested Message must decode to () per rule 2");
    test:assertEquals(status?.timestamp, ());
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcTaskStatusWithMessageAndTimestamp() returns error? {
    grpcstub:TaskStatus grpcStatus = {
        state: grpcstub:TASK_STATE_INPUT_REQUIRED,
        message: {message_id: "m1", role: grpcstub:ROLE_AGENT, parts: [{text: "need more info"}]},
        timestamp: check stringToGrpcTimestamp("2023-10-27T10:00:00Z")
    };
    TaskStatus status = check decodeGrpcTaskStatus(grpcStatus);
    test:assertEquals(status.state, TASK_STATE_INPUT_REQUIRED);
    test:assertTrue(status?.message is Message);
    // grpcTimestampToString (Task 6) delegates to time:utcToString, which
    // omits the fractional-second suffix entirely when it's zero -- see
    // that function's doc comment. ".000Z" is not what it produces.
    test:assertEquals(status?.timestamp, "2023-10-27T10:00:00Z");
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcArtifact() returns error? {
    grpcstub:Artifact grpcArtifact = {
        artifact_id: "a1", name: "result.txt", description: "the output",
        parts: [{text: "content"}], extensions: ["urn:ext:one"]
    };
    Artifact artifact = check decodeGrpcArtifact(grpcArtifact);
    test:assertEquals(artifact.artifactId, "a1");
    test:assertEquals(artifact?.name, "result.txt");
    test:assertEquals(artifact?.description, "the output");
    test:assertEquals(artifact.parts.length(), 1);
    test:assertEquals(artifact.extensions, ["urn:ext:one"]);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcTask() returns error? {
    grpcstub:Task grpcTask = {
        id: "t1", context_id: "ctx1",
        status: {state: grpcstub:TASK_STATE_WORKING},
        history: [{message_id: "m1", role: grpcstub:ROLE_USER, parts: [{text: "hi"}]}],
        artifacts: [{artifact_id: "a1", parts: [{text: "out"}]}]
    };
    Task task = check decodeGrpcTask(grpcTask);
    test:assertEquals(task.id, "t1");
    test:assertEquals(task?.contextId, "ctx1");
    test:assertEquals(task.status.state, TASK_STATE_WORKING);
    test:assertEquals(task.history.length(), 1);
    test:assertEquals(task.artifacts.length(), 1);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcStatusUpdate() returns error? {
    grpcstub:TaskStatusUpdateEvent grpcEvent = {
        task_id: "t1", context_id: "ctx1", status: {state: grpcstub:TASK_STATE_COMPLETED}
    };
    TaskStatusUpdateEvent event = check decodeGrpcStatusUpdate(grpcEvent);
    test:assertEquals(event.taskId, "t1");
    test:assertEquals(event.contextId, "ctx1");
    test:assertEquals(event.status.state, TASK_STATE_COMPLETED);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcArtifactUpdate() returns error? {
    grpcstub:TaskArtifactUpdateEvent grpcEvent = {
        task_id: "t1", context_id: "ctx1",
        artifact: {artifact_id: "a1", parts: [{text: "chunk"}]},
        append: true, last_chunk: false
    };
    TaskArtifactUpdateEvent event = check decodeGrpcArtifactUpdate(grpcEvent);
    test:assertEquals(event.taskId, "t1");
    test:assertEquals(event.artifact.artifactId, "a1");
    test:assertEquals(event.append, true);
    test:assertEquals(event.lastChunk, false);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcSendResultTask() returns error? {
    grpcstub:SendMessageResponse resp = {task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}};
    Task|Message result = check decodeGrpcSendResult(resp);
    test:assertTrue(result is Task);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcSendResultMessage() returns error? {
    grpcstub:SendMessageResponse resp = {message: {message_id: "m1", role: grpcstub:ROLE_AGENT, parts: [{text: "hi"}]}};
    Task|Message result = check decodeGrpcSendResult(resp);
    test:assertTrue(result is Message);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcSendResultNeitherIsInvalidAgentResponse() {
    grpcstub:SendMessageResponse resp = {};
    Task|Message|error result = decodeGrpcSendResult(resp);
    test:assertTrue(result is InvalidAgentResponseError);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcStreamResponseEachVariant() returns error? {
    StreamResponse r1 = check decodeGrpcStreamResponse({task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}});
    test:assertTrue(r1?.task is Task);
    StreamResponse r2 = check decodeGrpcStreamResponse({message: {message_id: "m1", role: grpcstub:ROLE_AGENT, parts: [{text: "hi"}]}});
    test:assertTrue(r2?.message is Message);
    StreamResponse r3 = check decodeGrpcStreamResponse({status_update: {task_id: "t1", context_id: "c1", status: {state: grpcstub:TASK_STATE_WORKING}}});
    test:assertTrue(r3?.statusUpdate is TaskStatusUpdateEvent);
    StreamResponse r4 = check decodeGrpcStreamResponse({artifact_update: {task_id: "t1", context_id: "c1", artifact: {artifact_id: "a1", parts: [{text: "x"}]}}});
    test:assertTrue(r4?.artifactUpdate is TaskArtifactUpdateEvent);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcListTasksResult() returns error? {
    grpcstub:ListTasksResponse resp = {
        tasks: [{id: "t1", status: {state: grpcstub:TASK_STATE_WORKING}}],
        next_page_token: "cursor1", page_size: 10, total_size: 1
    };
    ListTasksResult result = check decodeGrpcListTasksResult(resp);
    test:assertEquals(result.tasks.length(), 1);
    test:assertEquals(result.nextPageToken, "cursor1");
    test:assertEquals(result.pageSize, 10);
    test:assertEquals(result.totalSize, 1);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcListPushConfigsResult() returns error? {
    grpcstub:ListTaskPushNotificationConfigsResponse resp = {
        configs: [{url: "https://cb.example.com", task_id: "t1"}],
        next_page_token: "cursor2"
    };
    ListTaskPushNotificationConfigsResult result = check decodeGrpcListPushConfigsResult(resp);
    test:assertEquals(result.configs.length(), 1);
    test:assertEquals(result.nextPageToken, "cursor2");
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardMinimal() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0",
        capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"],
        skills: []
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    test:assertEquals(card.name, "agent");
    test:assertEquals(card.capabilities.streaming, false);
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardApiKeyScheme() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0", capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"], skills: [],
        security_schemes: [{key: "apiKeyAuth", value: {api_key_security_scheme: {location: "header", name: "X-API-Key"}}}]
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    SecurityScheme scheme = card.securitySchemes.get("apiKeyAuth");
    test:assertTrue(scheme is ApiKeySecurityScheme);
    if scheme is ApiKeySecurityScheme {
        test:assertEquals(scheme.'in, "header");
        test:assertEquals(scheme.name, "X-API-Key");
    }
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcSecuritySchemeInvalidApiKeyLocationIsInvalidAgentResponse() {
    grpcstub:SecurityScheme s = {api_key_security_scheme: {location: "invalid-location", name: "X-API-Key"}};
    SecurityScheme|error decoded = decodeGrpcSecurityScheme(s);
    test:assertTrue(decoded is InvalidAgentResponseError,
            "expected InvalidAgentResponseError for an invalid api_key_security_scheme.location value");
    if decoded is InvalidAgentResponseError {
        string msg = decoded.message();
        test:assertTrue(msg.includes("invalid-location"), "error message should name the offending location value");
    }
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardOAuth2AuthorizationCodeFlow() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0", capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"], skills: [],
        security_schemes: [{key: "oauth2", value: {oauth2_security_scheme: {
            flows: {authorization_code: {
                authorization_url: "https://auth.example.com/authorize",
                token_url: "https://auth.example.com/token",
                scopes: [{key: "read", value: "Read access"}, {key: "write", value: "Write access"}]
            }}
        }}}]
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    SecurityScheme scheme = card.securitySchemes.get("oauth2");
    test:assertTrue(scheme is OAuth2SecurityScheme);
    if scheme is OAuth2SecurityScheme {
        AuthorizationCodeOAuthFlow? flow = scheme.flows?.authorizationCode;
        test:assertTrue(flow is AuthorizationCodeOAuthFlow);
        if flow is AuthorizationCodeOAuthFlow {
            test:assertEquals(flow.scopes, {"read": "Read access", "write": "Write access"});
        }
    }
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardSecurityRequirements() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0", capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"], skills: [],
        security_requirements: [{schemes: [{key: "apiKeyAuth", value: {list: []}}]}]
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    test:assertEquals(card.securityRequirements.length(), 1);
    test:assertEquals(card.securityRequirements[0], {"apiKeyAuth": []});
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcAgentCardSkillsAndInterfaces() returns error? {
    grpcstub:AgentCard grpcCard = {
        name: "agent", description: "d", version: "1.0", capabilities: {},
        default_input_modes: ["text"], default_output_modes: ["text"],
        skills: [{id: "s1", name: "Skill One", description: "does one thing", tags: ["tag1"]}],
        supported_interfaces: [{url: "http://localhost:9090", protocol_binding: "GRPC", protocol_version: "1.0"}]
    };
    AgentCard card = check decodeGrpcAgentCard(grpcCard);
    test:assertEquals(card.skills.length(), 1);
    test:assertEquals(card.skills[0].id, "s1");
    test:assertEquals(card.supportedInterfaces.length(), 1);
    test:assertEquals(card.supportedInterfaces[0].protocolBinding, "GRPC");
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcRequestGetTask() returns error? {
    map<json> params = {"id": "t1", "historyLength": 5, "tenant": "tenant1"};
    anydata req = check encodeGrpcRequest("GetTask", params);
    grpcstub:GetTaskRequest typed = check req.ensureType(grpcstub:GetTaskRequest);
    test:assertEquals(typed.id, "t1");
    test:assertEquals(typed?.history_length, 5);
    test:assertEquals(typed.tenant, "tenant1");
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcRequestSendMessageUndoesBase64() returns error? {
    byte[] rawBytes = "hello bytes".toBytes();
    json messageJson = check encodeRawBytesForWire({
        messageId: "m1", role: "ROLE_USER",
        parts: [{raw: rawBytes.toJson()}]
    }.toJson());
    // messageJson now has parts[0].raw as a base64 string, matching what
    // sendMessage actually builds before calling rpcCall.
    map<json> params = {"message": messageJson};
    anydata req = check encodeGrpcRequest("SendMessage", params);
    grpcstub:SendMessageRequest typed = check req.ensureType(grpcstub:SendMessageRequest);
    grpcstub:Part firstPart = typed.message.parts[0];
    test:assertEquals(firstPart.raw, rawBytes, "encodeGrpcRequest must undo the base64 encoding applied upstream");
}

@test:Config {groups: ["grpc"]}
function testDecodeGrpcResponseGetTask() returns error? {
    grpcstub:Task grpcTask = {id: "t1", status: {state: grpcstub:TASK_STATE_WORKING}};
    json result = check decodeGrpcResponse("GetTask", grpcTask);
    Task decoded = check (check decodeRawBytesFromWire(result)).cloneWithType(Task);
    test:assertEquals(decoded.id, "t1");
}

@test:Config {groups: ["grpc"]}
function testEncodeGrpcRequestUnknownOperationErrors() {
    anydata|error result = encodeGrpcRequest("NotARealOperation", {});
    test:assertTrue(result is A2AInternalError);
}
