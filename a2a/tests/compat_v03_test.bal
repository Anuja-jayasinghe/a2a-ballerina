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
