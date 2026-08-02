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
