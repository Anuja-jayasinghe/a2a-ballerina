import ballerina/lang.array;
import ballerina/test;

@test:Config {}
function testDetectProtocolModeFromSupportedInterfaces() returns error? {
    AgentCard v1Card = {
        name: "x", description: "x", version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [{url: "http://x", protocolBinding: "JSONRPC", protocolVersion: "1.0"}],
        skills: []
    };
    test:assertEquals(detectProtocolMode(v1Card), "V1_0");

    AgentCard v03InterfaceCard = {
        name: "x", description: "x", version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [{url: "http://x", protocolBinding: "JSONRPC", protocolVersion: "0.3.0"}],
        skills: []
    };
    test:assertEquals(detectProtocolMode(v03InterfaceCard), "V0_3");
}

@test:Config {}
function testDetectProtocolModeFromLegacyTopLevelField() returns error? {
    AgentCard legacyV03Card = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };
    test:assertEquals(detectProtocolMode(legacyV03Card), "V0_3");
}

@test:Config {}
function testDetectProtocolModeDefaultsLegacyCardWithNoProtocolVersionToV03() returns error? {
    // No supportedInterfaces AND no top-level protocolVersion: the currency
    // agent's exact shape isn't quite this (it does set protocolVersion),
    // but a legacy card that omits it entirely still lacks the one thing
    // that marks it v1.0-native (supportedInterfaces), so it defaults to
    // V0_3 rather than assuming v1.0.
    AgentCard bareLegacyCard = {
        name: "x", description: "x", version: "1.0.0",
        capabilities: {},
        skills: []
    };
    test:assertEquals(detectProtocolMode(bareLegacyCard), "V0_3");
}

@test:Config {}
function testDetectProtocolModeLegacyCardWithNonV03ProtocolVersionToV1() returns error? {
    // No supportedInterfaces, but an explicit top-level protocolVersion that
    // does not start with "0." should be treated as v1.0-native.
    AgentCard legacyV1Card = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "1.0.0",
        capabilities: {},
        skills: []
    };
    test:assertEquals(detectProtocolMode(legacyV1Card), "V1_0");
}

@test:Config {}
function testV03MethodNameTranslation() returns error? {
    test:assertEquals(v03MethodName("SendMessage"), "message/send");
    test:assertEquals(v03MethodName("SendStreamingMessage"), "message/stream");
    test:assertEquals(v03MethodName("GetTask"), "tasks/get");
    test:assertEquals(v03MethodName("CancelTask"), "tasks/cancel");
    test:assertEquals(v03MethodName("SubscribeToTask"), "tasks/resubscribe");
}

@test:Config {}
function testMapV03Role() returns error? {
    test:assertEquals(check mapV03Role("user"), ROLE_USER);
    test:assertEquals(check mapV03Role("agent"), ROLE_AGENT);

    Role|error result = mapV03Role("nonsense");
    test:assertTrue(result is error, "an unrecognized v0.3 role should surface as an error, not silently default");
}

@test:Config {}
function testMapV03State() returns error? {
    test:assertEquals(check mapV03State("submitted"), TASK_STATE_SUBMITTED);
    test:assertEquals(check mapV03State("working"), TASK_STATE_WORKING);
    test:assertEquals(check mapV03State("completed"), TASK_STATE_COMPLETED);
    test:assertEquals(check mapV03State("failed"), TASK_STATE_FAILED);
    test:assertEquals(check mapV03State("canceled"), TASK_STATE_CANCELED);
    test:assertEquals(check mapV03State("rejected"), TASK_STATE_REJECTED);
    test:assertEquals(check mapV03State("input-required"), TASK_STATE_INPUT_REQUIRED);
    test:assertEquals(check mapV03State("auth-required"), TASK_STATE_AUTH_REQUIRED);

    TaskState|error result = mapV03State("nonsense");
    test:assertTrue(result is error, "an unrecognized v0.3 state should surface as an error, not silently default");
}

@test:Config {}
function testParseV03PartText() returns error? {
    Part part = check parseV03Part({"kind": "text", "text": "hello"});
    test:assertEquals(part?.text, "hello");
}

@test:Config {}
function testParseV03PartFileWithUri() returns error? {
    Part part = check parseV03Part({
        "kind": "file",
        "file": {"uri": "https://example.com/report.pdf", "mime_type": "application/pdf", "name": "report.pdf"}
    });
    test:assertEquals(part?.url, "https://example.com/report.pdf");
    test:assertEquals(part?.mediaType, "application/pdf");
    test:assertEquals(part?.filename, "report.pdf");
}

@test:Config {}
function testParseV03PartFileWithBytes() returns error? {
    // "aGVsbG8=" base64-decodes to "hello"
    Part part = check parseV03Part({
        "kind": "file",
        "file": {"bytes": "aGVsbG8=", "mime_type": "text/plain"}
    });
    byte[]? raw = part?.raw;
    test:assertTrue(raw is byte[], "file-with-bytes should decode into Part.raw");
    test:assertEquals(string:fromBytes(<byte[]>raw), "hello");
}

@test:Config {}
function testParseV03PartFileWithMalformedBytesIsError() returns error? {
    Part|error result = parseV03Part({
        "kind": "file",
        "file": {"bytes": "not valid base64!!!", "mime_type": "text/plain"}
    });
    test:assertTrue(result is error, "malformed base64 in file bytes should surface as an error");
}

@test:Config {}
function testParseV03PartData() returns error? {
    Part part = check parseV03Part({"kind": "data", "data": {"amount": 100, "currency": "USD"}});
    json? data = part?.data;
    test:assertEquals(data, {"amount": 100, "currency": "USD"});
}

@test:Config {}
function testParseV03PartRejectsUnrecognizedKind() returns error? {
    Part|error result = parseV03Part({"kind": "video", "url": "x"});
    test:assertTrue(result is error, "an unrecognized v0.3 Part kind should surface as an error");
}

@test:Config {}
function testParseV03Message() returns error? {
    Message msg = check parseV03Message({
        "messageId": "msg-1",
        "role": "user",
        "parts": [{"kind": "text", "text": "Convert 100 USD to EUR"}],
        "contextId": "ctx-1",
        "kind": "message"
    });
    test:assertEquals(msg.messageId, "msg-1");
    test:assertEquals(msg.role, ROLE_USER);
    test:assertEquals(msg.parts.length(), 1);
    test:assertEquals(msg.parts[0]?.text, "Convert 100 USD to EUR");
    test:assertEquals(msg?.contextId, "ctx-1");
}

@test:Config {}
function testParseV03TaskStatus() returns error? {
    TaskStatus status = check parseV03TaskStatus({
        "state": "completed",
        "timestamp": "2026-07-28T03:18:13.954298+00:00",
        "message": {
            "messageId": "msg-2", "role": "agent",
            "parts": [{"kind": "text", "text": "100 USD is equal to 87.80 EUR."}],
            "kind": "message"
        }
    });
    test:assertEquals(status.state, TASK_STATE_COMPLETED);
    test:assertEquals(status?.timestamp, "2026-07-28T03:18:13.954298+00:00");
    Message? statusMessage = status?.message;
    test:assertTrue(statusMessage is Message, "TaskStatus.message should be parsed, not dropped");
    test:assertEquals((<Message>statusMessage).role, ROLE_AGENT);
}

@test:Config {}
function testParseV03Artifact() returns error? {
    Artifact artifact = check parseV03Artifact({
        "artifactId": "art-1",
        "name": "conversion_result",
        "parts": [{"kind": "text", "text": "100 USD is equal to 87.80 EUR."}]
    });
    test:assertEquals(artifact.artifactId, "art-1");
    test:assertEquals(artifact?.name, "conversion_result");
    test:assertEquals(artifact.parts[0]?.text, "100 USD is equal to 87.80 EUR.");
}

# Full round-trip against the actual raw response recorded in
# a2a-interop-tests/servers/adk_currency_agent/findings.md, minus the
# outer JSON-RPC envelope (that's rpcCall's job, not parseV03Task's).
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testParseV03TaskFromRealCurrencyAgentResponse() returns error? {
    Task task = check parseV03Task({
        "artifacts": [
            {"artifactId": "d9d3ff03-bf6c-4c68-ac46-b56a3088349c", "name": "conversion_result",
             "parts": [{"kind": "text", "text": "100 USD is equal to 87.80 EUR."}]}
        ],
        "contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684",
        "history": [
            {"contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684", "kind": "message",
             "messageId": "probe-msg-2", "parts": [{"kind": "text", "text": "Convert 100 USD to EUR"}],
             "role": "user", "taskId": "6ea25505-6764-4b29-9932-0227e2cf7e3e"}
        ],
        "id": "6ea25505-6764-4b29-9932-0227e2cf7e3e",
        "kind": "task",
        "status": {
            "message": {"contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684", "kind": "message",
                        "messageId": "e754dd1e-61b7-4968-a36f-7c4ea0ec14fa",
                        "parts": [{"kind": "text", "text": "100 USD is equal to 87.80 EUR."}],
                        "role": "agent", "taskId": "6ea25505-6764-4b29-9932-0227e2cf7e3e"},
            "state": "completed",
            "timestamp": "2026-07-28T03:18:13.954298+00:00"
        }
    });

    test:assertEquals(task.id, "6ea25505-6764-4b29-9932-0227e2cf7e3e");
    test:assertEquals(task?.contextId, "1b4188cb-0bc7-48ea-a3e6-177fa50f1684");
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    test:assertEquals(task.history.length(), 1);
    test:assertEquals(task.history[0].role, ROLE_USER);
    test:assertEquals(task.artifacts.length(), 1);
    test:assertEquals(task.artifacts[0].parts[0]?.text, "100 USD is equal to 87.80 EUR.");
}

@test:Config {}
function testDecodeV03SendResultTask() returns error? {
    Task|Message result = check decodeV03SendResult({
        "id": "task-1", "kind": "task",
        "status": {"state": "completed"}
    });
    test:assertTrue(result is Task, "kind:task should decode as a Task");
}

@test:Config {}
function testDecodeV03SendResultMessage() returns error? {
    Task|Message result = check decodeV03SendResult({
        "messageId": "msg-1", "kind": "message", "role": "agent",
        "parts": [{"kind": "text", "text": "hi"}]
    });
    test:assertTrue(result is Message, "kind:message should decode as a Message");
}

@test:Config {}
function testDecodeV03SendResultRejectsUnrecognizedKind() returns error? {
    Task|Message|error result = decodeV03SendResult({"kind": "artifact-update"});
    test:assertTrue(result is error, "an unrecognized top-level kind should surface as an error");
}

@test:Config {}
function testDecodeV03StreamEventStatusUpdate() returns error? {
    StreamResponse event = check decodeV03StreamEvent({
        "kind": "status-update",
        "taskId": "task-1", "contextId": "ctx-1",
        "status": {"state": "working"},
        "final": false
    });
    TaskStatusUpdateEvent? update = event?.statusUpdate;
    test:assertTrue(update is TaskStatusUpdateEvent, "status-update should decode into StreamResponse.statusUpdate");
    test:assertEquals((<TaskStatusUpdateEvent>update).status.state, TASK_STATE_WORKING);
}

@test:Config {}
function testDecodeV03StreamEventArtifactUpdate() returns error? {
    StreamResponse event = check decodeV03StreamEvent({
        "kind": "artifact-update",
        "taskId": "task-1", "contextId": "ctx-1",
        "artifact": {"artifactId": "art-1", "parts": [{"kind": "text", "text": "partial"}]},
        "lastChunk": true
    });
    TaskArtifactUpdateEvent? update = event?.artifactUpdate;
    test:assertTrue(update is TaskArtifactUpdateEvent, "artifact-update should decode into StreamResponse.artifactUpdate");
    test:assertEquals((<TaskArtifactUpdateEvent>update).lastChunk, true);
}

# Confirms the client ignores v0.3's redundant "final" field entirely and
# derives terminal-ness solely from the translated TaskState, matching the
# reference SDK's own v0.3->v1.0 conversion behavior (see design spec).
# final:true here is deliberately paired with a non-terminal state
# ("working") to prove it has no effect on the decoded event.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testDecodeV03StreamEventIgnoresFinalField() returns error? {
    StreamResponse event = check decodeV03StreamEvent({
        "kind": "status-update",
        "taskId": "task-1", "contextId": "ctx-1",
        "status": {"state": "working"},
        "final": true
    });
    TaskStatusUpdateEvent update = <TaskStatusUpdateEvent>event?.statusUpdate;
    test:assertEquals(update.status.state, TASK_STATE_WORKING, "final:true on a non-terminal state must not change the decoded TaskState");
}

@test:Config {}
function testDecodeV03StreamEventTask() returns error? {
    StreamResponse event = check decodeV03StreamEvent({
        "kind": "task",
        "id": "task-1",
        "status": {"state": "completed"}
    });
    Task? task = event?.task;
    test:assertTrue(task is Task, "kind:task should decode into StreamResponse.task");
    test:assertEquals((<Task>task).id, "task-1");
    test:assertEquals((<Task>task).status.state, TASK_STATE_COMPLETED);
}

@test:Config {}
function testDecodeV03StreamEventMessage() returns error? {
    StreamResponse event = check decodeV03StreamEvent({
        "kind": "message",
        "messageId": "msg-1", "role": "agent",
        "parts": [{"kind": "text", "text": "hi"}]
    });
    Message? message = event?.message;
    test:assertTrue(message is Message, "kind:message should decode into StreamResponse.message");
    test:assertEquals((<Message>message).role, ROLE_AGENT);
}

@test:Config {}
function testDecodeV03StreamEventRejectsUnrecognizedKind() returns error? {
    StreamResponse|error result = decodeV03StreamEvent({"kind": "something-else"});
    test:assertTrue(result is error, "an unrecognized stream event kind should surface as an error");
}

@test:Config {}
function testEncodeV03PartText() returns error? {
    Part part = {text: "hello"};
    json result = check encodeV03Part(part);
    test:assertEquals(result, {"kind": "text", "text": "hello"});
}

@test:Config {}
function testEncodeV03PartFileWithBytes() returns error? {
    byte[] rawBytes = "hello".toBytes();
    Part part = {raw: rawBytes, filename: "report.pdf", mediaType: "application/pdf"};
    json result = check encodeV03Part(part);
    map<json> m = check result.ensureType();
    test:assertEquals(m["kind"], "file");
    map<json> file = check m["file"].ensureType();
    byte[] decoded = check array:fromBase64(check file["bytes"].ensureType());
    test:assertEquals(decoded, rawBytes);
    test:assertEquals(file["name"], "report.pdf");
    test:assertEquals(file["mimeType"], "application/pdf");
}

@test:Config {}
function testEncodeV03PartFileWithUrl() returns error? {
    Part part = {url: "https://example.com/report.pdf", filename: "report.pdf", mediaType: "application/pdf"};
    json result = check encodeV03Part(part);
    map<json> m = check result.ensureType();
    test:assertEquals(m["kind"], "file");
    map<json> file = check m["file"].ensureType();
    test:assertEquals(file["uri"], "https://example.com/report.pdf");
}

@test:Config {}
function testEncodeV03PartData() returns error? {
    Part part = {data: {"amount": 100, "currency": "USD"}};
    json result = check encodeV03Part(part);
    map<json> m = check result.ensureType();
    test:assertEquals(m["kind"], "data");
    test:assertEquals(m["data"], {"amount": 100, "currency": "USD"});
}

@test:Config {}
function testEncodeV03MessageUserRole() returns error? {
    Message msg = {
        messageId: "msg-1",
        role: ROLE_USER,
        parts: [{text: "Convert 100 USD to EUR"}]
    };
    json result = check encodeV03Message(msg);
    map<json> m = check result.ensureType();
    test:assertEquals(m["role"], "user");
    test:assertEquals(m["kind"], "message");
    test:assertEquals(m["messageId"], "msg-1");
    json[] parts = check m["parts"].ensureType();
    test:assertEquals(parts.length(), 1);
    test:assertEquals(parts[0], {"kind": "text", "text": "Convert 100 USD to EUR"});
}

@test:Config {}
function testEncodeV03MessageAgentRole() returns error? {
    Message msg = {
        messageId: "msg-2",
        role: ROLE_AGENT,
        parts: [{text: "100 USD is equal to 87.80 EUR."}, {data: {"amount": 87.80, "currency": "EUR"}}]
    };
    json result = check encodeV03Message(msg);
    map<json> m = check result.ensureType();
    test:assertEquals(m["role"], "agent");
    test:assertEquals(m["kind"], "message");
    json[] parts = check m["parts"].ensureType();
    test:assertEquals(parts.length(), 2);
    test:assertEquals(parts[0], {"kind": "text", "text": "100 USD is equal to 87.80 EUR."});
    test:assertEquals(parts[1], {"kind": "data", "data": {"amount": 87.80, "currency": "EUR"}});
}

@test:Config {}
function testEncodeV03MessageOmitsUnsetOptionalFields() returns error? {
    Message msg = {
        messageId: "msg-3",
        role: ROLE_USER,
        parts: [{text: "hi"}]
    };
    json result = check encodeV03Message(msg);
    map<json> m = check result.ensureType();
    test:assertTrue(m.hasKey("messageId"), "messageId should be present");
    test:assertTrue(!m.hasKey("contextId"), "contextId should be absent, not present-but-null, when unset");
    test:assertTrue(!m.hasKey("taskId"), "taskId should be absent, not present-but-null, when unset");
    test:assertTrue(!m.hasKey("metadata"), "metadata should be absent, not present-but-null, when unset");
    test:assertTrue(!m.hasKey("referenceTaskIds"), "referenceTaskIds should be absent when empty, not an empty array");
    test:assertTrue(!m.hasKey("extensions"), "extensions should be absent when empty, not an empty array");
}

@test:Config {}
function testEncodeV03MessageRejectsUnspecifiedRole() returns error? {
    Message msg = {
        messageId: "msg-4",
        role: ROLE_UNSPECIFIED,
        parts: [{text: "hi"}]
    };
    json|error result = encodeV03Message(msg);
    test:assertTrue(result is error, "ROLE_UNSPECIFIED must not silently encode as \"user\"");
}

@test:Config {}
function testEncodeV03PartRejectsEmptyPart() returns error? {
    // None of text/raw/url/data is set — encodeV03Part must reject this
    // rather than silently emitting {"kind":"data","data":null}.
    Part part = {};
    json|error result = encodeV03Part(part);
    test:assertTrue(result is error, "a Part with none of text/raw/url/data set should be rejected, not encoded as kind:data");
}

@test:Config {}
function testEncodeV03MessagePropagatesPartEncodingError() returns error? {
    Message msg = {
        messageId: "msg-5",
        role: ROLE_USER,
        parts: [{}]
    };
    json|error result = encodeV03Message(msg);
    test:assertTrue(result is error, "encodeV03Message must surface a part-encoding failure rather than swallow it");
}

@test:Config {}
function testMessageReferenceTaskIdsAndExtensionsRoundTrip() returns error? {
    Message original = {
        messageId: "msg-6",
        role: ROLE_USER,
        parts: [{text: "hi"}],
        referenceTaskIds: ["task-1", "task-2"],
        extensions: ["https://example.com/ext-a"]
    };

    json encoded = check encodeV03Message(original);
    map<json> m = check encoded.ensureType();
    test:assertEquals(m["referenceTaskIds"], ["task-1", "task-2"]);
    test:assertEquals(m["extensions"], ["https://example.com/ext-a"]);

    Message decoded = check parseV03Message(encoded);
    test:assertEquals(decoded.referenceTaskIds, ["task-1", "task-2"]);
    test:assertEquals(decoded.extensions, ["https://example.com/ext-a"]);
}

@test:Config {}
function testParseV03MessageDefaultsReferenceTaskIdsAndExtensionsWhenAbsent() returns error? {
    Message msg = check parseV03Message({
        "messageId": "msg-7",
        "role": "user",
        "parts": [{"kind": "text", "text": "hi"}]
    });
    test:assertEquals(msg.referenceTaskIds, []);
    test:assertEquals(msg.extensions, []);
}

@test:Config {}
function testParseV03ArtifactCarriesExtensions() returns error? {
    Artifact artifact = check parseV03Artifact({
        "artifactId": "art-2",
        "parts": [{"kind": "text", "text": "hi"}],
        "extensions": ["https://example.com/ext-b"]
    });
    test:assertEquals(artifact.extensions, ["https://example.com/ext-b"]);
}

@test:Config {}
function testEncodeV03SendConfigurationInvertsReturnImmediatelyToBlocking() returns error? {
    SendMessageConfiguration nonBlocking = {returnImmediately: true};
    json nonBlockingResult = encodeV03SendConfiguration(nonBlocking);
    map<json> nb = check nonBlockingResult.ensureType();
    test:assertEquals(nb["blocking"], false, "returnImmediately:true must encode as blocking:false");

    SendMessageConfiguration blocking = {returnImmediately: false};
    json blockingResult = encodeV03SendConfiguration(blocking);
    map<json> b = check blockingResult.ensureType();
    test:assertEquals(b["blocking"], true, "returnImmediately:false must encode as blocking:true");
}

@test:Config {}
function testEncodeV03SendConfigurationPassesThroughOutputModesAndHistoryLength() returns error? {
    SendMessageConfiguration config = {
        acceptedOutputModes: ["text", "image/png"],
        historyLength: 5
    };
    json result = encodeV03SendConfiguration(config);
    map<json> m = check result.ensureType();
    test:assertEquals(m["acceptedOutputModes"], ["text", "image/png"]);
    test:assertEquals(m["historyLength"], 5);
}

@test:Config {}
function testEncodeV03SendConfigurationRenamesPushNotificationConfigAndDropsTaskId() returns error? {
    SendMessageConfiguration config = {
        taskPushNotificationConfig: {
            url: "https://example.com/webhook",
            id: "config-1",
            taskId: "task-should-be-dropped",
            token: "secret-token"
        }
    };
    json result = encodeV03SendConfiguration(config);
    map<json> m = check result.ensureType();
    test:assertTrue(!m.hasKey("taskPushNotificationConfig"), "the v1.0 field name must not appear on the wire");
    test:assertTrue(m.hasKey("pushNotificationConfig"), "pushNotificationConfig must be present under its v0.3 name");
    map<json> wireConfig = check m["pushNotificationConfig"].ensureType();
    test:assertEquals(wireConfig["url"], "https://example.com/webhook");
    test:assertEquals(wireConfig["id"], "config-1");
    test:assertEquals(wireConfig["token"], "secret-token");
    test:assertTrue(!wireConfig.hasKey("taskId"), "the v1.0-only taskId sub-field must be dropped when encoding for v0.3");
}

@test:Config {}
function testEncodeV03SendConfigurationOmitsPushNotificationConfigWhenUnset() returns error? {
    SendMessageConfiguration config = {};
    json result = encodeV03SendConfiguration(config);
    map<json> m = check result.ensureType();
    test:assertTrue(!m.hasKey("pushNotificationConfig"), "pushNotificationConfig should be absent when the caller didn't set it");
}

// ---- Round-trip property tests ----------------------------------------
//
// encodeV03Message/parseV03Message are meant to be exact mirror images of
// each other. Every other test in this file exercises one direction at a
// time; these two exist as the cheapest ongoing guard against the two
// halves silently drifting apart from each other as either one changes
// independently in the future.

# Full round-trip: every Part variant, every optional Message field set.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testV03MessageRoundTripsThroughEncodeAndParse() returns error? {
    Message original = {
        messageId: "round-trip-1",
        role: ROLE_USER,
        parts: [
            {text: "hello"},
            {raw: "hello".toBytes(), filename: "greeting.txt", mediaType: "text/plain"},
            {url: "https://example.com/report.pdf", filename: "report.pdf", mediaType: "application/pdf"},
            {data: {"amount": 100, "currency": "USD"}}
        ],
        contextId: "ctx-1",
        taskId: "task-1",
        referenceTaskIds: ["task-0"],
        extensions: ["https://example.com/ext/v1"],
        metadata: {"note": "round-trip"}
    };

    json encoded = check encodeV03Message(original);
    Message decoded = check parseV03Message(encoded);

    test:assertEquals(decoded, original, "encoding then parsing a v1.0 Message should reproduce it exactly");
}

# Minimal round-trip: no optional fields set at all, proving omission on
# encode and defaulting-to-empty on decode agree with each other rather
# than one side leaving a stray null/empty value the other doesn't expect.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testV03MessageRoundTripsWithNoOptionalFields() returns error? {
    Message original = {
        messageId: "round-trip-2",
        role: ROLE_AGENT,
        parts: [{text: "hi"}]
    };

    json encoded = check encodeV03Message(original);
    Message decoded = check parseV03Message(encoded);

    test:assertEquals(decoded, original, "a Message with no optional fields set should round-trip exactly, including empty referenceTaskIds/extensions defaults");
}
