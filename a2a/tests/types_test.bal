import ballerina/test;

@test:Config {}
function testPartTextVariantRoundTrip() returns error? {
    Part original = {text: "What is the weather in Colombo?"};
    Part decoded = check original.toJson().cloneWithType(Part);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.raw is (), "raw should be nil for a text Part");
    test:assertTrue(decoded?.url is (), "url should be nil for a text Part");
    test:assertTrue(decoded?.data is (), "data should be nil for a text Part");
}

@test:Config {}
function testPartRawVariantRoundTrip() returns error? {
    byte[] bytes = "some file content".toBytes();
    Part original = {raw: bytes, mediaType: "text/plain"};
    Part decoded = check original.toJson().cloneWithType(Part);

    test:assertEquals(decoded?.raw, bytes);
    test:assertTrue(decoded?.text is (), "text should be nil for a raw Part");
    test:assertTrue(decoded?.url is (), "url should be nil for a raw Part");
    test:assertTrue(decoded?.data is (), "data should be nil for a raw Part");
}

@test:Config {}
function testPartUrlVariantRoundTrip() returns error? {
    Part original = {url: "https://example.com/report.pdf", mediaType: "application/pdf"};
    Part decoded = check original.toJson().cloneWithType(Part);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.text is (), "text should be nil for a url Part");
    test:assertTrue(decoded?.raw is (), "raw should be nil for a url Part");
    test:assertTrue(decoded?.data is (), "data should be nil for a url Part");
}

@test:Config {}
function testPartDataVariantRoundTrip() returns error? {
    Part original = {data: {temperature: 29, condition: "partly cloudy"}};
    Part decoded = check original.toJson().cloneWithType(Part);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.text is (), "text should be nil for a data Part");
    test:assertTrue(decoded?.raw is (), "raw should be nil for a data Part");
    test:assertTrue(decoded?.url is (), "url should be nil for a data Part");
}

@test:Config {}
function testPartToleratesUnrecognizedField() returns error? {
    json payload = {
        text: "What is the weather in Colombo?",
        futureField: "some value from a newer spec revision"
    };

    Part decoded = check payload.cloneWithType(Part);

    test:assertEquals(decoded?.text, "What is the weather in Colombo?");

    json reserialized = decoded.toJson();
    test:assertEquals(
        (check reserialized.futureField),
        "some value from a newer spec revision"
    );
}

@test:Config {}
function testMessageMinimalRoundTrip() returns error? {
    Message original = {
        messageId: "msg-1",
        role: ROLE_USER,
        parts: [{text: "What is the weather in Colombo?"}]
    };
    Message decoded = check original.toJson().cloneWithType(Message);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.contextId is (), "contextId should be nil");
    test:assertTrue(decoded?.taskId is (), "taskId should be nil");
    test:assertTrue(decoded?.metadata is (), "metadata should be nil");
    test:assertEquals(decoded.referenceTaskIds, []);
    test:assertEquals(decoded.extensions, []);
}

@test:Config {}
function testMessageFullRoundTrip() returns error? {
    Message original = {
        messageId: "msg-2",
        role: ROLE_AGENT,
        parts: [
            {text: "Here is the forecast."},
            {data: {temperature: 29, condition: "partly cloudy"}}
        ],
        contextId: "ctx-1",
        taskId: "task-1",
        referenceTaskIds: ["task-0"],
        extensions: ["https://example.com/extensions/weather"],
        metadata: {"source": "weather-agent"}
    };
    Message decoded = check original.toJson().cloneWithType(Message);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testMessageToleratesUnrecognizedField() returns error? {
    json payload = {
        messageId: "msg-3",
        role: "ROLE_USER",
        parts: [{text: "What is the weather in Colombo?"}],
        futureField: "some value from a newer spec revision"
    };

    Message decoded = check payload.cloneWithType(Message);

    test:assertEquals(decoded.messageId, "msg-3");

    json reserialized = decoded.toJson();
    test:assertEquals(
        (check reserialized.futureField),
        "some value from a newer spec revision"
    );
}
