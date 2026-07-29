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

@test:Config {}
function testAgentProviderRoundTrip() returns error? {
    AgentProvider original = {organization: "Acme Corp", url: "https://acme.example.com", contactEmail: "support@acme.example.com"};
    AgentProvider decoded = check original.toJson().cloneWithType(AgentProvider);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentProviderToleratesUnrecognizedField() returns error? {
    json payload = {
        organization: "Acme Corp",
        url: "https://acme.example.com",
        futureField: "some value from a newer spec revision"
    };

    AgentProvider decoded = check payload.cloneWithType(AgentProvider);

    test:assertEquals(decoded.organization, "Acme Corp");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentExtensionRoundTrip() returns error? {
    AgentExtension original = {
        uri: "https://example.com/extensions/weather",
        description: "Weather lookups",
        required: true,
        params: {"unit": "celsius"}
    };
    AgentExtension decoded = check original.toJson().cloneWithType(AgentExtension);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentExtensionToleratesUnrecognizedField() returns error? {
    json payload = {
        uri: "https://example.com/extensions/weather",
        futureField: "some value from a newer spec revision"
    };

    AgentExtension decoded = check payload.cloneWithType(AgentExtension);

    test:assertEquals(decoded.uri, "https://example.com/extensions/weather");
    test:assertEquals(decoded.required, false);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentCapabilitiesRoundTrip() returns error? {
    AgentCapabilities original = {
        streaming: true,
        pushNotifications: true,
        extendedAgentCard: true,
        extensions: [{uri: "https://example.com/extensions/weather"}]
    };
    AgentCapabilities decoded = check original.toJson().cloneWithType(AgentCapabilities);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentCapabilitiesToleratesUnrecognizedField() returns error? {
    json payload = {futureField: "some value from a newer spec revision"};

    AgentCapabilities decoded = check payload.cloneWithType(AgentCapabilities);

    test:assertEquals(decoded.streaming, false);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentSkillRoundTrip() returns error? {
    AgentSkill original = {
        id: "weather-lookup",
        name: "Weather Lookup",
        description: "Reports current weather for a city",
        tags: ["weather"],
        inputModes: ["text"],
        outputModes: ["text"],
        examples: ["What is the weather in Colombo?"],
        securityRequirements: [{"bearerAuth": []}]
    };
    AgentSkill decoded = check original.toJson().cloneWithType(AgentSkill);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentSkillToleratesUnrecognizedField() returns error? {
    json payload = {
        id: "weather-lookup",
        name: "Weather Lookup",
        description: "Reports current weather for a city",
        futureField: "some value from a newer spec revision"
    };

    AgentSkill decoded = check payload.cloneWithType(AgentSkill);

    test:assertEquals(decoded.id, "weather-lookup");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentInterfaceRoundTrip() returns error? {
    AgentInterface original = {
        url: "https://acme.example.com/a2a",
        protocolBinding: "JSONRPC",
        protocolVersion: "1.0",
        tenant: "acme-corp"
    };
    AgentInterface decoded = check original.toJson().cloneWithType(AgentInterface);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentInterfaceToleratesUnrecognizedField() returns error? {
    json payload = {
        url: "https://acme.example.com/a2a",
        protocolBinding: "JSONRPC",
        futureField: "some value from a newer spec revision"
    };

    AgentInterface decoded = check payload.cloneWithType(AgentInterface);

    test:assertEquals(decoded.protocolBinding, "JSONRPC");
    test:assertTrue(decoded?.tenant is (), "tenant should be nil");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentCardCompositeRoundTrip() returns error? {
    AgentCard original = {
        name: "Weather Agent",
        description: "Reports current weather conditions",
        version: "1.2.0",
        url: "https://weather.example.com/a2a",
        provider: {organization: "Acme Corp", url: "https://acme.example.com"},
        documentationUrl: "https://weather.example.com/docs",
        capabilities: {streaming: true, pushNotifications: true},
        supportedInterfaces: [
            {url: "https://weather.example.com/a2a", protocolBinding: "JSONRPC"},
            {url: "https://weather.example.com/tenant/acme", protocolBinding: "JSONRPC", tenant: "acme-corp"}
        ],
        securitySchemes: {"bearerAuth": {"type": "http", "scheme": "bearer"}},
        securityRequirements: [{"bearerAuth": []}],
        skills: [
            {
                id: "weather-lookup",
                name: "Weather Lookup",
                description: "Reports current weather for a city",
                tags: ["weather"],
                examples: ["What is the weather in Colombo?"]
            },
            {
                id: "forecast",
                name: "Forecast",
                description: "Reports a multi-day forecast for a city",
                tags: ["weather", "forecast"]
            }
        ]
    };
    AgentCard decoded = check original.toJson().cloneWithType(AgentCard);

    test:assertEquals(decoded, original);
}

# v1.0 removed AgentCard.url as a required field; real v1.0 servers only
# publish supportedInterfaces[0].url. url must round-trip fine when absent.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testAgentCardRoundTripWithoutLegacyUrl() returns error? {
    AgentCard original = {
        name: "Weather Agent",
        description: "Reports current weather conditions",
        version: "1.2.0",
        capabilities: {streaming: true},
        supportedInterfaces: [
            {url: "https://weather.example.com/a2a", protocolBinding: "JSONRPC"}
        ],
        skills: []
    };
    AgentCard decoded = check original.toJson().cloneWithType(AgentCard);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.url is (), "url should be nil when never set");
}

@test:Config {}
function testAgentCardRoundTripWithProtocolVersion() returns error? {
    AgentCard original = {
        name: "Legacy Agent",
        description: "A v0.3-style agent",
        version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };

    AgentCard decoded = check original.toJson().cloneWithType(AgentCard);

    test:assertEquals(decoded?.protocolVersion, "0.3.0");
}

@test:Config {}
function testAgentCardToleratesMissingProtocolVersion() returns error? {
    json payload = {
        name: "v1.0 Agent",
        description: "A v1.0 agent that omits the legacy field",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: []
    };

    AgentCard decoded = check payload.cloneWithType(AgentCard);

    test:assertTrue(decoded?.protocolVersion is (), "protocolVersion should be nil, not defaulted, when the server never sent it");
}

@test:Config {}
function testAgentCardToleratesUnrecognizedField() returns error? {
    json payload = {
        name: "Weather Agent",
        description: "Reports current weather conditions",
        version: "1.2.0",
        url: "https://weather.example.com/a2a",
        capabilities: {},
        skills: [],
        futureField: "some value from a newer spec revision"
    };

    AgentCard decoded = check payload.cloneWithType(AgentCard);

    test:assertEquals(decoded.name, "Weather Agent");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskStatusRoundTrip() returns error? {
    TaskStatus original = {
        state: TASK_STATE_INPUT_REQUIRED,
        message: {messageId: "msg-1", role: ROLE_AGENT, parts: [{text: "Which city?"}]},
        timestamp: "2023-10-27T10:00:00Z"
    };
    TaskStatus decoded = check original.toJson().cloneWithType(TaskStatus);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testTaskStatusToleratesUnrecognizedField() returns error? {
    json payload = {
        state: "TASK_STATE_WORKING",
        futureField: "some value from a newer spec revision"
    };

    TaskStatus decoded = check payload.cloneWithType(TaskStatus);

    test:assertEquals(decoded.state, TASK_STATE_WORKING);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testArtifactRoundTrip() returns error? {
    Artifact original = {
        artifactId: "art-1",
        name: "Forecast",
        description: "Three-day forecast",
        parts: [{text: "29 degrees Celsius and partly cloudy."}],
        metadata: {"units": "celsius"},
        extensions: ["https://example.com/extensions/weather"]
    };
    Artifact decoded = check original.toJson().cloneWithType(Artifact);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testArtifactToleratesUnrecognizedField() returns error? {
    json payload = {
        artifactId: "art-1",
        parts: [{text: "29 degrees Celsius and partly cloudy."}],
        futureField: "some value from a newer spec revision"
    };

    Artifact decoded = check payload.cloneWithType(Artifact);

    test:assertEquals(decoded.artifactId, "art-1");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskCompositeRoundTrip() returns error? {
    Task original = {
        id: "task-7f3a9b2c",
        contextId: "ctx-4e8d1a6f",
        status: {state: TASK_STATE_COMPLETED, timestamp: "2026-07-20T14:32:11Z"},
        history: [
            {messageId: "msg-1", role: ROLE_USER, parts: [{text: "What is the weather in Colombo?"}]},
            {messageId: "msg-2", role: ROLE_AGENT, parts: [{text: "Let me check that for you."}]}
        ],
        artifacts: [
            {artifactId: "art-9c2e", parts: [{text: "29 degrees Celsius and partly cloudy."}]},
            {
                artifactId: "art-9c2f",
                name: "Forecast chart",
                parts: [{url: "https://weather.example.com/chart.png", mediaType: "image/png"}],
                extensions: ["https://example.com/extensions/weather"]
            }
        ],
        metadata: {"source": "weather-agent"}
    };
    Task decoded = check original.toJson().cloneWithType(Task);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testTaskToleratesUnrecognizedField() returns error? {
    json payload = {
        id: "task-1",
        status: {state: "TASK_STATE_SUBMITTED"},
        futureField: "some value from a newer spec revision"
    };

    Task decoded = check payload.cloneWithType(Task);

    test:assertEquals(decoded.id, "task-1");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskStatusUpdateEventRoundTrip() returns error? {
    TaskStatusUpdateEvent original = {
        taskId: "task-1",
        contextId: "ctx-1",
        status: {state: TASK_STATE_WORKING},
        metadata: {"progress": 0.5}
    };
    TaskStatusUpdateEvent decoded = check original.toJson().cloneWithType(TaskStatusUpdateEvent);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testTaskStatusUpdateEventToleratesUnrecognizedField() returns error? {
    json payload = {
        taskId: "task-1",
        contextId: "ctx-1",
        status: {state: "TASK_STATE_WORKING"},
        futureField: "some value from a newer spec revision"
    };

    TaskStatusUpdateEvent decoded = check payload.cloneWithType(TaskStatusUpdateEvent);

    test:assertEquals(decoded.taskId, "task-1");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskArtifactUpdateEventRoundTrip() returns error? {
    TaskArtifactUpdateEvent original = {
        taskId: "task-1",
        contextId: "ctx-1",
        artifact: {artifactId: "art-1", parts: [{text: "29 degrees Celsius"}]},
        append: true,
        lastChunk: true,
        metadata: {"chunk": 2}
    };
    TaskArtifactUpdateEvent decoded = check original.toJson().cloneWithType(TaskArtifactUpdateEvent);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testTaskArtifactUpdateEventToleratesUnrecognizedField() returns error? {
    json payload = {
        taskId: "task-1",
        contextId: "ctx-1",
        artifact: {artifactId: "art-1", parts: [{text: "29 degrees Celsius"}]},
        futureField: "some value from a newer spec revision"
    };

    TaskArtifactUpdateEvent decoded = check payload.cloneWithType(TaskArtifactUpdateEvent);

    test:assertEquals(decoded.taskId, "task-1");
    test:assertEquals(decoded.append, false);
    test:assertEquals(decoded.lastChunk, false);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testStreamResponseRoundTrip() returns error? {
    StreamResponse original = {
        statusUpdate: {taskId: "task-1", contextId: "ctx-1", status: {state: TASK_STATE_COMPLETED}}
    };
    StreamResponse decoded = check original.toJson().cloneWithType(StreamResponse);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.task is (), "task should be nil");
    test:assertTrue(decoded?.message is (), "message should be nil");
    test:assertTrue(decoded?.artifactUpdate is (), "artifactUpdate should be nil");
}

@test:Config {}
function testStreamResponseToleratesUnrecognizedField() returns error? {
    json payload = {
        message: {messageId: "msg-1", role: "ROLE_AGENT", parts: [{text: "Hello"}]},
        futureField: "some value from a newer spec revision"
    };

    StreamResponse decoded = check payload.cloneWithType(StreamResponse);

    test:assertTrue(decoded?.message is Message, "message should decode");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAuthenticationInfoRoundTrip() returns error? {
    AuthenticationInfo original = {scheme: "Bearer", credentials: "eyJhbGciOiJIUzI1NiIs..."};
    AuthenticationInfo decoded = check original.toJson().cloneWithType(AuthenticationInfo);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAuthenticationInfoToleratesUnrecognizedField() returns error? {
    json payload = {
        scheme: "Bearer",
        futureField: "some value from a newer spec revision"
    };

    AuthenticationInfo decoded = check payload.cloneWithType(AuthenticationInfo);

    test:assertEquals(decoded.scheme, "Bearer");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskPushNotificationConfigRoundTrip() returns error? {
    TaskPushNotificationConfig original = {
        url: "https://client.example.com/webhooks/a2a",
        id: "webhook-1",
        token: "correlation-token",
        authentication: {scheme: "Bearer", credentials: "eyJhbGciOiJIUzI1NiIs..."},
        tenant: "acme-corp"
    };
    TaskPushNotificationConfig decoded = check original.toJson().cloneWithType(TaskPushNotificationConfig);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.taskId is (), "taskId should be nil in a sendMessage-style config");
}

@test:Config {}
function testTaskPushNotificationConfigToleratesUnrecognizedField() returns error? {
    json payload = {
        url: "https://client.example.com/webhooks/a2a",
        futureField: "some value from a newer spec revision"
    };

    TaskPushNotificationConfig decoded = check payload.cloneWithType(TaskPushNotificationConfig);

    test:assertEquals(decoded.url, "https://client.example.com/webhooks/a2a");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testSendMessageConfigurationRoundTrip() returns error? {
    SendMessageConfiguration original = {
        acceptedOutputModes: ["text", "image/png"],
        historyLength: 5,
        returnImmediately: true,
        taskPushNotificationConfig: {url: "https://client.example.com/webhooks/a2a"}
    };
    SendMessageConfiguration decoded = check original.toJson().cloneWithType(SendMessageConfiguration);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testSendMessageConfigurationDefaults() returns error? {
    json payload = {};

    SendMessageConfiguration decoded = check payload.cloneWithType(SendMessageConfiguration);

    test:assertEquals(decoded.acceptedOutputModes, ["text"]);
    test:assertTrue(decoded?.historyLength is (), "historyLength should be unset by default");
    test:assertEquals(decoded.returnImmediately, false);
    test:assertTrue(decoded?.taskPushNotificationConfig is (), "taskPushNotificationConfig should be unset by default");
}

@test:Config {}
function testSendMessageConfigurationToleratesUnrecognizedField() returns error? {
    json payload = {
        futureField: "some value from a newer spec revision"
    };

    SendMessageConfiguration decoded = check payload.cloneWithType(SendMessageConfiguration);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testListTasksFilterRoundTrip() returns error? {
    ListTasksFilter original = {
        contextId: "ctx-1",
        status: TASK_STATE_COMPLETED,
        pageSize: 20,
        pageToken: "cursor-abc",
        historyLength: 10,
        statusTimestampAfter: "2026-07-29T00:00:00Z",
        includeArtifacts: true
    };
    ListTasksFilter decoded = check original.toJson().cloneWithType(ListTasksFilter);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testListTasksFilterToleratesUnrecognizedField() returns error? {
    json payload = {futureField: "some value from a newer spec revision"};

    ListTasksFilter decoded = check payload.cloneWithType(ListTasksFilter);

    test:assertTrue(decoded?.contextId is (), "contextId should be nil, not defaulted");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testListTasksResultRoundTrip() returns error? {
    ListTasksResult original = {
        tasks: [
            {id: "task-1", status: {state: TASK_STATE_COMPLETED}}
        ],
        nextPageToken: "cursor-def",
        pageSize: 20,
        totalSize: 1
    };
    ListTasksResult decoded = check original.toJson().cloneWithType(ListTasksResult);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testListTaskPushNotificationConfigsResultRoundTrip() returns error? {
    ListTaskPushNotificationConfigsResult original = {
        configs: [
            {url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}
        ],
        nextPageToken: "cursor-ghi"
    };
    ListTaskPushNotificationConfigsResult decoded = check original.toJson().cloneWithType(ListTaskPushNotificationConfigsResult);

    test:assertEquals(decoded, original);
}
