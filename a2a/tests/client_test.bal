import ballerina/http;
import ballerina/test;
import ballerina/time;

@test:Config {}
function testResolveAgentCardSuccess() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());

    test:assertEquals(card.name, "Mock Weather Agent");
    test:assertEquals(card.capabilities.streaming, true);
    test:assertEquals(card.skills.length(), 1);
    test:assertEquals(card.skills[0].id, "weather-lookup");
}

@test:Config {}
function testResolveAgentCardUnreachableEndpoint() returns error? {
    AgentCard|error result = resolveAgentCard("http://localhost:1");

    test:assertTrue(result is error, "unreachable endpoint should surface as an error, not panic");
}

@test:Config {}
function testResolveAgentCardNon200Status() returns error? {
    setWellKnownOverride({message: "not found"}, 404);

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    test:assertTrue(result is error, "a non-200 well-known response should surface as an error");
    test:assertTrue(result is A2AInternalError, "non-200 well-known response should map to A2AInternalError");
}

@test:Config {}
function testResolveAgentCardMalformedJson() returns error? {
    setWellKnownOverride({"totally": "not an agent card"});

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    test:assertTrue(result is error, "a well-known body that doesn't decode as AgentCard should surface as an error");
}

# v1.0 removed AgentCard.url as a required field — the real reference
# server never sends it, only supportedInterfaces[0].url. Regression test
# for that: resolveAgentCard must succeed against a card with no url at
# all, and primaryUrl() must fall back to supportedInterfaces correctly.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testResolveAgentCardSucceedsWithoutLegacyUrl() returns error? {
    setWellKnownOverride({
        name: "Mock Weather Agent",
        description: "A scripted mock agent used by Client tests",
        version: "1.0.0",
        capabilities: {streaming: true},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC"}
        ],
        skills: [
            {id: "weather-lookup", name: "Weather Lookup", description: "Reports current weather for a city"}
        ]
    });

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    if result is error {
        test:assertFail("resolveAgentCard should succeed against a card with no legacy url field: " + result.message());
    }
    AgentCard card = result;
    test:assertTrue(card?.url is (), "url should be nil, not defaulted, when the server never sent it");
    test:assertEquals(check primaryUrl(card), "http://localhost:19199");
}

@test:Config {}
function testPrimaryUrlPrefersSupportedInterfaces() returns error? {
    AgentCard card = {
        name: "x",
        description: "x",
        version: "1.0.0",
        url: "https://legacy.example.com",
        capabilities: {},
        supportedInterfaces: [
            {url: "https://primary.example.com", protocolBinding: "JSONRPC"},
            {url: "https://secondary.example.com", protocolBinding: "JSONRPC"}
        ],
        skills: []
    };

    test:assertEquals(check primaryUrl(card), "https://primary.example.com");
}

# Confirms primaryUrl filters by protocolBinding rather than blindly
# taking supportedInterfaces[0] — a card listing a binding this Client
# doesn't speak (e.g. GRPC) before its JSONRPC entry must still resolve
# to the JSONRPC one, not fail non-obviously on the first real request.
#
# + return - an error if any step other than the assertion itself fails
@test:Config {}
function testPrimaryUrlSkipsNonJsonRpcInterfaces() returns error? {
    AgentCard card = {
        name: "x",
        description: "x",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [
            {url: "https://grpc.example.com", protocolBinding: "GRPC"},
            {url: "https://jsonrpc.example.com", protocolBinding: "JSONRPC"}
        ],
        skills: []
    };

    test:assertEquals(check primaryUrl(card), "https://jsonrpc.example.com");
}

@test:Config {}
function testPrimaryUrlFallsBackToLegacyUrl() returns error? {
    AgentCard card = {
        name: "x",
        description: "x",
        version: "1.0.0",
        url: "https://legacy.example.com",
        capabilities: {},
        skills: []
    };

    test:assertEquals(check primaryUrl(card), "https://legacy.example.com");
}

@test:Config {}
function testPrimaryUrlErrorsWhenNeitherIsSet() {
    AgentCard card = {
        name: "x",
        description: "x",
        version: "1.0.0",
        capabilities: {},
        skills: []
    };

    string|error result = primaryUrl(card);

    test:assertTrue(result is error, "primaryUrl should error when the card has neither supportedInterfaces nor a legacy url");
}

@test:Config {}
function testSendMessageHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0",
        id: "1",
        result: {
            task: {
                id: "task-1",
                contextId: "ctx-1",
                status: {state: "TASK_STATE_COMPLETED"},
                artifacts: [
                    {artifactId: "art-1", parts: [{text: "29 degrees Celsius and partly cloudy."}]}
                ]
            }
        }
    });

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-1",
        role: ROLE_USER,
        parts: [{text: "What is the weather in Colombo?"}]
    };

    Task|Message result = check c->sendMessage(msg);

    test:assertTrue(result is Task, "mock returned a Task, so sendMessage should decode it as one");
    Task task = <Task>result;
    assertValidTask(task);
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    test:assertEquals(extractArtifactText(task.artifacts[0]), "29 degrees Celsius and partly cloudy.");
}

# SendMessageRequest.metadata (specification section 3.2.1) is a
# request-level field, distinct from Message.metadata — confirms it's
# actually placed at the top level of params, not nested under "message".
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testSendMessageIncludesRequestLevelMetadataWhenSet() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {task: {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}}
    });

    Client c = check new (getServerBaseUrl());
    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg, metadata = {"traceId": "abc-123"});

    json lastRequest = getLastRequestBody();
    json requestMetadata = check lastRequest.params.metadata;
    test:assertEquals(requestMetadata, {"traceId": "abc-123"});
}

@test:Config {}
function testSendMessageOmitsRequestLevelMetadataWhenUnset() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {task: {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}}
    });

    Client c = check new (getServerBaseUrl());
    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg);

    json params = check getLastRequestBody().params;
    map<json> paramsMap = check params.ensureType();
    test:assertFalse(paramsMap.hasKey("metadata"), "request-level metadata should be absent when the caller didn't set it");
}

# The real reference server's SendMessage response wraps the payload —
# {"result": {"task": {...}}} or {"result": {"message": {...}}} — never a
# flat Task/Message. The happy-path test above only ever exercised the
# task branch; this covers the message branch of that same wrapper.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testSendMessageHappyPathMessageVariant() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0",
        id: "1",
        result: {
            message: {
                messageId: "reply-msg-1",
                role: "ROLE_AGENT",
                parts: [{text: "Hi there!"}]
            }
        }
    });

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-1a",
        role: ROLE_USER,
        parts: [{text: "hi"}]
    };

    Task|Message result = check c->sendMessage(msg);

    test:assertTrue(result is Message, "mock returned a Message, so sendMessage should decode it as one");
    Message reply = <Message>result;
    test:assertEquals(reply.messageId, "reply-msg-1");
    test:assertEquals(reply.parts[0]?.text, "Hi there!");
}

# A conforming server can't produce this (task/message form a real
# protobuf oneof upstream), but SendMessageResult is a plain open record on
# our side with no such enforcement — a non-conforming server sending both
# should be treated as a malformed response, not silently resolved by
# preferring one field over the other.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testSendMessageRejectsResponseWithBothTaskAndMessage() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0",
        id: "1",
        result: {
            task: {id: "task-ambiguous", status: {state: "TASK_STATE_COMPLETED"}},
            message: {messageId: "reply-ambiguous", role: "ROLE_AGENT", parts: [{text: "Hi there!"}]}
        }
    });

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-ambiguous",
        role: ROLE_USER,
        parts: [{text: "hi"}]
    };

    Task|Message|error result = c->sendMessage(msg);

    test:assertTrue(result is error, "a response with both task and message set should surface as an error");
    test:assertTrue(result is InvalidAgentResponseError, "should map to InvalidAgentResponseError, not silently prefer task");
}

@test:Config {}
function testSendMessageStreamHappyPath() returns error? {
    setNextSseResponse([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-2","contextId":"ctx-2","status":{"state":"TASK_STATE_WORKING"}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"artifactUpdate":{"taskId":"task-2","contextId":"ctx-2","artifact":{"artifactId":"art-2","parts":[{"text":"29 degrees Celsius and partly cloudy."}]}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-2","contextId":"ctx-2","status":{"state":"TASK_STATE_COMPLETED"}}}}`}
    ]);

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-2",
        role: ROLE_USER,
        parts: [{text: "What is the weather in Colombo?"}]
    };

    stream<StreamResponse, error?> events = check c->sendMessageStream(msg);

    StreamResponse first = check expectValue(events.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(events.next());
    TaskArtifactUpdateEvent artifactEvent = <TaskArtifactUpdateEvent>second?.artifactUpdate;
    test:assertEquals(extractArtifactText(artifactEvent.artifact), "29 degrees Celsius and partly cloudy.");

    StreamResponse third = check expectValue(events.next());
    test:assertEquals((<TaskStatusUpdateEvent>third?.statusUpdate).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? fourth = events.next();
    test:assertTrue(fourth is (), "stream should close after the terminal status");
}

@test:Config {}
function testSendMessageStreamPausesAtInputRequiredThenResumes() returns error? {
    setNextSseResponse([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-3","contextId":"ctx-3","status":{"state":"TASK_STATE_WORKING"}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-3","contextId":"ctx-3","status":{"state":"TASK_STATE_INPUT_REQUIRED"}}}}`}
    ]);

    Client c = check new (getServerBaseUrl());
    Message turn1 = {
        messageId: "msg-3",
        role: ROLE_USER,
        parts: [{text: "Research quantum error correction advances in 2024"}]
    };

    stream<StreamResponse, error?> firstStream = check c->sendMessageStream(turn1);

    StreamResponse working = check expectValue(firstStream.next());
    test:assertEquals((<TaskStatusUpdateEvent>working?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse inputRequired = check expectValue(firstStream.next());
    TaskStatusUpdateEvent inputRequiredEvent = <TaskStatusUpdateEvent>inputRequired?.statusUpdate;
    test:assertEquals(inputRequiredEvent.status.state, TASK_STATE_INPUT_REQUIRED);

    record {| StreamResponse value; |}|error? afterPause = firstStream.next();
    test:assertTrue(afterPause is (), "no more events scripted after INPUT_REQUIRED for the first turn");

    // Resume with the same taskId/contextId, as design §9.3 shows.
    setNextSseResponse([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-3","contextId":"ctx-3","status":{"state":"TASK_STATE_WORKING"}}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-3","contextId":"ctx-3","status":{"state":"TASK_STATE_COMPLETED"}}}}`}
    ]);

    Message turn2 = {
        messageId: "msg-4",
        role: ROLE_USER,
        contextId: inputRequiredEvent.contextId,
        taskId: inputRequiredEvent.taskId,
        parts: [{text: "Focus on surface codes and topological qubits"}]
    };

    stream<StreamResponse, error?> secondStream = check c->sendMessageStream(turn2);

    StreamResponse resumedWorking = check expectValue(secondStream.next());
    test:assertEquals((<TaskStatusUpdateEvent>resumedWorking?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse completed = check expectValue(secondStream.next());
    TaskStatusUpdateEvent completedEvent = <TaskStatusUpdateEvent>completed?.statusUpdate;
    test:assertEquals(completedEvent.status.state, TASK_STATE_COMPLETED);
    test:assertEquals(completedEvent.taskId, "task-3");
    test:assertEquals(completedEvent.contextId, "ctx-3");
}

@test:Config {}
function testGetTaskNotFoundErrorMapping() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0",
        id: "1",
        'error: {code: -32001, message: "Task not found", data: {taskId: "task-unknown"}}
    });

    Client c = check new (getServerBaseUrl());
    Task|error result = c->getTask("task-unknown");

    test:assertTrue(result is error, "an unknown task should surface as an error");
    test:assertTrue(result is TaskNotFoundError, "code -32001 should map to TaskNotFoundError");
}

@test:Config {}
function testSendMessageMalformedEnvelopeMapping() returns error? {
    // Neither result nor error — a malformed JSON-RPC envelope.
    setNextJsonResponse({jsonrpc: "2.0", id: "1"});

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-5",
        role: ROLE_USER,
        parts: [{text: "hello"}]
    };
    Task|Message|error result = c->sendMessage(msg);

    test:assertTrue(result is error, "a malformed envelope should surface as an error");
    test:assertTrue(result is InvalidAgentResponseError, "a malformed envelope should map to InvalidAgentResponseError");
}

@test:Config {}
function testTenantPropagatesOnEveryMethod() returns error? {
    string tenant = "acme-corp";
    Client c = check new (getServerBaseUrl(), tenant = tenant);
    Message msg = {
        messageId: "msg-tenant",
        role: ROLE_USER,
        parts: [{text: "hello"}]
    };
    json validTaskResponse = {
        jsonrpc: "2.0",
        id: "1",
        result: {id: "task-tenant", status: {state: "TASK_STATE_COMPLETED"}}
    };
    // sendMessage's response wraps the Task, unlike getTask/cancelTask.
    json wrappedTaskResponse = {
        jsonrpc: "2.0",
        id: "1",
        result: {task: {id: "task-tenant", status: {state: "TASK_STATE_COMPLETED"}}}
    };
    http:SseEvent[] minimalSseResponse = [
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-tenant","contextId":"ctx-tenant","status":{"state":"TASK_STATE_WORKING"}}}}`}
    ];

    setNextJsonResponse(wrappedTaskResponse);
    Task|Message|error sendMessageResult = c->sendMessage(msg);
    check assertLastRequestTenant(tenant, "sendMessage");

    setNextSseResponse(minimalSseResponse);
    stream<StreamResponse, error?>|error sendMessageStreamResult = c->sendMessageStream(msg);
    check assertLastRequestTenant(tenant, "sendMessageStream");
    check closeIfStream(sendMessageStreamResult);

    setNextJsonResponse(validTaskResponse);
    Task|error getTaskResult = c->getTask("task-tenant");
    check assertLastRequestTenant(tenant, "getTask");

    setNextJsonResponse(validTaskResponse);
    Task|error cancelTaskResult = c->cancelTask("task-tenant");
    check assertLastRequestTenant(tenant, "cancelTask");

    setNextSseResponse(minimalSseResponse);
    stream<StreamResponse, error?>|error subscribeToTaskResult = c->subscribeToTask("task-tenant");
    check assertLastRequestTenant(tenant, "subscribeToTask");
    check closeIfStream(subscribeToTaskResult);

    // listTasks has no v0.3 equivalent, so it only works in V1_0 mode —
    // same as the other five calls above, c is already a V1_0-mode client
    // (no agentCard was supplied to its constructor).
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {tasks: [], nextPageToken: "", pageSize: 20, totalSize: 0}
    });
    ListTasksResult|error listTasksResult = c->listTasks();
    check assertLastRequestTenant(tenant, "listTasks");

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-tenant"}
    });
    TaskPushNotificationConfig|error createConfigResult = c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-tenant"
    });
    check assertLastRequestTenant(tenant, "createTaskPushNotificationConfig");

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-tenant"}
    });
    TaskPushNotificationConfig|error getConfigResult = c->getTaskPushNotificationConfig("task-tenant", "webhook-1");
    check assertLastRequestTenant(tenant, "getTaskPushNotificationConfig");

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            configs: [{url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}],
            nextPageToken: ""
        }
    });
    ListTaskPushNotificationConfigsResult|error listConfigsResult = c->listTaskPushNotificationConfigs("task-tenant");
    check assertLastRequestTenant(tenant, "listTaskPushNotificationConfigs");

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {}
    });
    error? deleteConfigResult = c->deleteTaskPushNotificationConfig("task-tenant", "webhook-1");
    check assertLastRequestTenant(tenant, "deleteTaskPushNotificationConfig");

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            name: "Mock Weather Agent (extended)",
            description: "A scripted mock agent used by Client tests",
            version: "1.0.0",
            capabilities: {extendedAgentCard: true},
            skills: []
        }
    });
    AgentCard|error getExtendedAgentCardResult = c->getExtendedAgentCard();
    check assertLastRequestTenant(tenant, "getExtendedAgentCard");
}

# tenant is a v1.0-only concept (a per-AgentInterface routing value); v0.3
# has no wire counterpart, so a Client configured with a tenant must not
# send it when talking to a v0.3 server.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testTenantOmittedInV03Mode() returns error? {
    AgentCard legacyCard = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };
    Client c = check new (getServerBaseUrl(), tenant = "acme-corp", agentCard = legacyCard);

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-tenant-v03", kind: "task", status: {state: "completed"}}
    });

    Task _ = check c->getTask("task-tenant-v03");

    json params = check getLastRequestBody().params;
    map<json> paramsMap = check params.ensureType();
    test:assertFalse(paramsMap.hasKey("tenant"), "tenant should be omitted from v0.3 requests, not sent as an unrecognized param");
}

# Confirms method-name translation actually happens on the wire, not just
# that decoding tolerates it — asserts what the mock server actually
# received via getLastRequestBody(), the same pattern
# testTenantPropagatesOnEveryMethod already uses.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testV03ModeTranslatesSendMessageMethodName() returns error? {
    // Since Task 8, sendMessage's response decoding branches on mode, so a
    // V0_3 client now goes through decodeV03SendResult, which expects the
    // unwrapped {"kind": "task", ...} shape rather than the v1.0
    // {"task": {...}} wrapper. This test only cares about the wire method
    // name, so the response body just needs to be shaped so decoding
    // succeeds.
    AgentCard legacyCard = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };
    Client c = check new (getServerBaseUrl(), agentCard = legacyCard);

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-1", kind: "task", status: {state: "completed"}}
    });

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg);

    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "message/send");

    // Prove the outbound body is actually v0.3-shaped on the wire, not just
    // that the right method name was sent.
    json wireParams = check lastRequest.params;
    json wireMessage = check wireParams.message;
    json[] wireParts = check wireMessage.parts.ensureType();
    json wirePart0 = wireParts[0];
    test:assertEquals(check wirePart0.kind, "text");
    test:assertEquals(check wirePart0.text, "hi");
    test:assertEquals(check wireMessage.role, "user");
    test:assertEquals(check wireMessage.kind, "message");
}

# Same proof as testV03ModeTranslatesSendMessageMethodName, but for
# sendMessageStream: the outbound body sent over the SSE-opening request
# must also be v0.3-shaped, not just method-translated.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testV03ModeTranslatesSendMessageStreamRequestBody() returns error? {
    AgentCard legacyCard = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {streaming: true},
        skills: []
    };
    Client c = check new (getServerBaseUrl(), agentCard = legacyCard);

    http:SseEvent[] v03SseResponse = [
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-stream-1","contextId":"ctx-stream-1","status":{"state":"working"}}}`}
    ];
    setNextSseResponse(v03SseResponse);
    Message msg = {messageId: "msg-stream-1", role: ROLE_USER, parts: [{text: "hello stream"}]};
    stream<StreamResponse, error?>|error result = c->sendMessageStream(msg);
    check closeIfStream(result);

    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "message/stream");
    json wireParams = check lastRequest.params;
    json wireMessage = check wireParams.message;
    json[] wireParts = check wireMessage.parts.ensureType();
    json wirePart0 = wireParts[0];
    test:assertEquals(check wirePart0.kind, "text");
    test:assertEquals(check wirePart0.text, "hello stream");
    test:assertEquals(check wireMessage.role, "user");
    test:assertEquals(check wireMessage.kind, "message");
}

@test:Config {}
function testV1ModeStillSendsPascalCaseMethodNameByDefault() returns error? {
    // No agentCard passed at all — confirms omitting the new parameter
    // preserves today's exact v1.0-only behavior.
    Client c = check new (getServerBaseUrl());

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {task: {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}}
    });

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage(msg);

    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "SendMessage");
}

# Drains and closes a possibly-opened SSE stream so the mock server isn't
# left trying to write to an abandoned connection between tests.
#
# + result - the raw remote-call result, only acted on if it's a stream
# + return - an error if closing the stream fails
isolated function closeIfStream(stream<StreamResponse, error?>|error result) returns error? {
    if result is stream<StreamResponse, error?> {
        record {| StreamResponse value; |}|error? next = result.next();
        while next is record {| StreamResponse value; |} {
            next = result.next();
        }
        check result.close();
    }
}

@test:Config {}
function testPerCallTenantOverridesClientDefault() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0",
        id: "1",
        result: {task: {id: "task-tenant-2", status: {state: "TASK_STATE_COMPLETED"}}}
    });

    Client c = check new (getServerBaseUrl(), tenant = "default-tenant");
    Message msg = {
        messageId: "msg-tenant-2",
        role: ROLE_USER,
        parts: [{text: "hello"}]
    };

    Task|Message|error result = c->sendMessage(msg, tenant = "override-tenant");

    check assertLastRequestTenant("override-tenant", "sendMessage with a per-call override");
}

isolated function assertLastRequestTenant(string expectedTenant, string label) returns error? {
    json params = check getLastRequestBody().params;
    string tenantOnWire = check params.tenant;
    test:assertEquals(tenantOnWire, expectedTenant, string `${label} should echo the tenant on the wire`);
}

@test:Config {}
function testClientConfigTimeoutPassthrough() returns error? {
    // A generous delay/threshold gap (0.1s timeout vs. a 3s mock delay,
    // asserting well under that at 2s) so this doesn't flake under
    // scheduling jitter when the full suite runs concurrently.
    setNextDelay(3);
    setNextJsonResponse({
        jsonrpc: "2.0",
        id: "1",
        result: {id: "task-slow", status: {state: "TASK_STATE_COMPLETED"}}
    });

    Client c = check new (getServerBaseUrl(), {timeout: 0.1});

    decimal before = time:monotonicNow();
    Task|error result = c->getTask("task-slow");
    decimal elapsed = time:monotonicNow() - before;

    setNextDelay(0);

    test:assertTrue(result is error, "a client configured with a 0.1s timeout should time out against a slow mock response");
    test:assertTrue(elapsed < 2d, string `expected the timeout to fire well under the mock's 3s delay, took ${elapsed}s`);
}

isolated function v03Client() returns Client|error {
    AgentCard legacyCard = {
        name: "x", description: "x", version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };
    return new (getServerBaseUrl(), agentCard = legacyCard);
}

@test:Config {}
function testV03SendMessageDecodesUnwrappedTaskResponse() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            id: "task-1", kind: "task",
            status: {state: "completed"},
            artifacts: [{artifactId: "art-1", parts: [{kind: "text", text: "100 USD is equal to 87.80 EUR."}]}]
        }
    });

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "Convert 100 USD to EUR"}]};
    Task|Message result = check c->sendMessage(msg);

    test:assertTrue(result is Task, "an unwrapped kind:task v0.3 result should decode as a Task");
    Task task = <Task>result;
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    test:assertEquals(extractArtifactText(task.artifacts[0]), "100 USD is equal to 87.80 EUR.");
}

@test:Config {}
function testV03SendMessageDecodesUnwrappedMessageResponse() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            messageId: "reply-1", kind: "message", role: "agent",
            parts: [{kind: "text", text: "Sure, what currency?"}]
        }
    });

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "Convert some money"}]};
    Task|Message result = check c->sendMessage(msg);

    test:assertTrue(result is Message, "an unwrapped kind:message v0.3 result should decode as a Message");
    test:assertEquals((<Message>result).role, ROLE_AGENT);
}

@test:Config {}
function testV03GetTaskDecodesUnwrappedTask() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-1", kind: "task", status: {state: "completed"}}
    });

    Task task = check c->getTask("task-1");

    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
}

@test:Config {}
function testV03CancelTaskDecodesUnwrappedTask() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-1", kind: "task", status: {state: "canceled"}}
    });

    Task task = check c->cancelTask("task-1");

    test:assertEquals(task.status.state, TASK_STATE_CANCELED);
}

@test:Config {}
function testV03SendMessageStreamDecodesStatusAndArtifactUpdates() returns error? {
    Client c = check v03Client();
    setNextSseResponse([
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"working"}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"artifact-update","taskId":"task-1","contextId":"ctx-1","artifact":{"artifactId":"art-1","parts":[{"kind":"text","text":"100 USD is equal to 87.80 EUR."}]}}}`},
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"kind":"status-update","taskId":"task-1","contextId":"ctx-1","status":{"state":"completed"}}}`}
    ]);

    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "Convert 100 USD to EUR"}]};
    stream<StreamResponse, error?> events = check c->sendMessageStream(msg);

    StreamResponse first = check expectValue(events.next());
    test:assertEquals((<TaskStatusUpdateEvent>first?.statusUpdate).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(events.next());
    test:assertEquals(extractArtifactText((<TaskArtifactUpdateEvent>second?.artifactUpdate).artifact), "100 USD is equal to 87.80 EUR.");

    StreamResponse third = check expectValue(events.next());
    test:assertEquals((<TaskStatusUpdateEvent>third?.statusUpdate).status.state, TASK_STATE_COMPLETED);
}

@test:Config {}
function testListTasksHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            tasks: [{id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}],
            nextPageToken: "cursor-abc",
            pageSize: 20,
            totalSize: 1
        }
    });

    Client c = check new (getServerBaseUrl());
    ListTasksResult result = check c->listTasks();

    test:assertEquals(result.tasks.length(), 1);
    test:assertEquals(result.tasks[0].id, "task-1");
    test:assertEquals(result.nextPageToken, "cursor-abc");
    test:assertEquals(result.totalSize, 1);
}

# Confirms filter fields actually reach the wire — checks the mock's
# received request body, the same pattern testTenantPropagatesOnEveryMethod
# already uses via getLastRequestBody().
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testListTasksSendsFilterFieldsOnWire() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {tasks: [], nextPageToken: "", pageSize: 20, totalSize: 0}
    });

    Client c = check new (getServerBaseUrl());
    ListTasksResult _ = check c->listTasks({
        contextId: "ctx-1",
        status: TASK_STATE_COMPLETED,
        pageSize: 20,
        pageToken: "cursor-abc",
        includeArtifacts: true
    });

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.contextId, "ctx-1");
    test:assertEquals(check params.status, "TASK_STATE_COMPLETED");
    test:assertEquals(check params.pageSize, 20);
    test:assertEquals(check params.pageToken, "cursor-abc");
    test:assertEquals(check params.includeArtifacts, true);
}

@test:Config {}
function testListTasksOmitsUnsetFilterFields() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {tasks: [], nextPageToken: "", pageSize: 20, totalSize: 0}
    });

    Client c = check new (getServerBaseUrl());
    ListTasksResult _ = check c->listTasks();

    json params = check getLastRequestBody().params;
    map<json> paramsMap = check params.ensureType();
    test:assertFalse(paramsMap.hasKey("contextId"), "contextId should be absent when no filter is passed");
    test:assertFalse(paramsMap.hasKey("pageSize"), "pageSize should be absent when no filter is passed");
}

# ListTasks has no v0.3 equivalent (confirmed "(NEW)" in the migration
# table) — a V0_3-mode Client must fail client-side with
# VersionNotSupportedError before making any network call, per §3.6.3's
# principle against silent automatic fallback.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testListTasksErrorsImmediatelyInV03Mode() returns error? {
    Client c = check v03Client();

    ListTasksResult|error result = c->listTasks();

    test:assertTrue(result is error, "listTasks should fail in V0_3 mode, not attempt a network call");
    test:assertTrue(result is VersionNotSupportedError, "should map specifically to VersionNotSupportedError, not a generic error");
}

@test:Config {}
function testCreateTaskPushNotificationConfigHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-1"}
    });

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig config = check c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-1"
    });

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(config?.id, "webhook-1");
}

@test:Config {}
function testGetTaskPushNotificationConfigHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-1"}
    });

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig config = check c->getTaskPushNotificationConfig("task-1", "webhook-1");

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.taskId, "task-1");
    test:assertEquals(check params.id, "webhook-1");
}

@test:Config {}
function testCreateTaskPushNotificationConfigNotSupportedErrorMapping() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        'error: {code: -32003, message: "Push notifications not supported"}
    });

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig|error result = c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-1"
    });

    test:assertTrue(result is PushNotificationNotSupportedError, "code -32003 should map to PushNotificationNotSupportedError");
}

@test:Config {}
function testV03CreateTaskPushNotificationConfigTranslatesMethodAndBody() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            taskId: "task-1",
            pushNotificationConfig: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}
        }
    });

    TaskPushNotificationConfig config = check c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-1"
    });

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "tasks/pushNotificationConfig/set");

    // The outbound body must use v0.3's nested {taskId, pushNotificationConfig:
    // {url, ...}} shape, not v1.0's flat record.
    json params = check lastRequest.params;
    map<json> paramsMap = check params.ensureType();
    test:assertEquals(paramsMap["taskId"], "task-1");
    map<json> wireConfig = check paramsMap["pushNotificationConfig"].ensureType();
    test:assertEquals(wireConfig["url"], "https://client.example.com/webhooks/a2a");
}

@test:Config {}
function testV03GetTaskPushNotificationConfigTranslatesMethod() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            taskId: "task-1",
            pushNotificationConfig: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}
        }
    });

    TaskPushNotificationConfig config = check c->getTaskPushNotificationConfig("task-1", "webhook-1");

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "tasks/pushNotificationConfig/get");

    // v0.3's GetTaskPushNotificationConfigParams is {id: <taskId>,
    // pushNotificationConfigId: <id>}, not v1.0's {taskId, id}.
    json params = check lastRequest.params;
    map<json> paramsMap = check params.ensureType();
    test:assertEquals(paramsMap["id"], "task-1");
    test:assertEquals(paramsMap["pushNotificationConfigId"], "webhook-1");
    test:assertFalse(paramsMap.hasKey("taskId"), "v0.3 params must not use the v1.0 field name taskId");
}

@test:Config {}
function testListTaskPushNotificationConfigsHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            configs: [{url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}],
            nextPageToken: "cursor-abc"
        }
    });

    Client c = check new (getServerBaseUrl());
    ListTaskPushNotificationConfigsResult result = check c->listTaskPushNotificationConfigs("task-1");

    test:assertEquals(result.configs.length(), 1);
    test:assertEquals(result.configs[0].url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(result.nextPageToken, "cursor-abc");

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.taskId, "task-1");
}

@test:Config {}
function testListTaskPushNotificationConfigsSendsPaginationFieldsWhenSet() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {configs: [], nextPageToken: ""}
    });

    Client c = check new (getServerBaseUrl());
    ListTaskPushNotificationConfigsResult _ = check c->listTaskPushNotificationConfigs("task-1", pageSize = 10, pageToken = "cursor-abc");

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.pageSize, 10);
    test:assertEquals(check params.pageToken, "cursor-abc");
}

@test:Config {}
function testDeleteTaskPushNotificationConfigHappyPathReturnsNil() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {}
    });

    Client c = check new (getServerBaseUrl());
    error? result = c->deleteTaskPushNotificationConfig("task-1", "webhook-1");

    test:assertTrue(result is (), "a successful delete should return nil, not an error");

    json params = check getLastRequestBody().params;
    test:assertEquals(check params.taskId, "task-1");
    test:assertEquals(check params.id, "webhook-1");
}

@test:Config {}
function testV03ListTaskPushNotificationConfigsTranslatesMethodAndDecodesUnwrappedResult() returns error? {
    Client c = check v03Client();
    // v0.3's ListTaskPushNotificationConfigSuccessResponse.result is a BARE
    // array, not a {configs, nextPageToken} wrapper.
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: [
            {
                taskId: "task-1",
                pushNotificationConfig: {url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}
            }
        ]
    });

    ListTaskPushNotificationConfigsResult result = check c->listTaskPushNotificationConfigs("task-1");

    test:assertEquals(result.configs.length(), 1);
    test:assertEquals(result.configs[0].url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(result.nextPageToken, "", "v0.3 has no pagination concept for this operation");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "tasks/pushNotificationConfig/list");

    // v0.3's ListTaskPushNotificationConfigParams is {id: <taskId>} only.
    json params = check lastRequest.params;
    map<json> paramsMap = check params.ensureType();
    test:assertEquals(paramsMap["id"], "task-1");
    test:assertFalse(paramsMap.hasKey("taskId"), "v0.3 params must not use the v1.0 field name taskId");
}

# v0.3 has no pagination concept for this operation at all — a strict
# server might reject unrecognized params, so pageSize/pageToken must be
# omitted entirely rather than sent, the same gating tenant already gets
# in every method.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {}
function testV03ListTaskPushNotificationConfigsOmitsPaginationFields() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: []
    });

    ListTaskPushNotificationConfigsResult _ = check c->listTaskPushNotificationConfigs("task-1", pageSize = 10, pageToken = "cursor-abc");

    json params = check getLastRequestBody().params;
    map<json> paramsMap = check params.ensureType();
    test:assertFalse(paramsMap.hasKey("pageSize"), "pageSize has no v0.3 wire counterpart and must be omitted");
    test:assertFalse(paramsMap.hasKey("pageToken"), "pageToken has no v0.3 wire counterpart and must be omitted");
}

@test:Config {}
function testV03DeleteTaskPushNotificationConfigTranslatesMethod() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {}
    });

    error? result = c->deleteTaskPushNotificationConfig("task-1", "webhook-1");

    test:assertTrue(result is (), "a successful delete should return nil in v0.3 mode too");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "tasks/pushNotificationConfig/delete");

    // v0.3's DeleteTaskPushNotificationConfigParams is {id: <taskId>,
    // pushNotificationConfigId: <id>}, not v1.0's {taskId, id}.
    json params = check lastRequest.params;
    map<json> paramsMap = check params.ensureType();
    test:assertEquals(paramsMap["id"], "task-1");
    test:assertEquals(paramsMap["pushNotificationConfigId"], "webhook-1");
    test:assertFalse(paramsMap.hasKey("taskId"), "v0.3 params must not use the v1.0 field name taskId");
}

@test:Config {}
function testGetExtendedAgentCardHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            name: "Mock Weather Agent (extended)",
            description: "A scripted mock agent used by Client tests",
            version: "1.0.0",
            capabilities: {extendedAgentCard: true},
            skills: [{id: "weather-lookup", name: "Weather Lookup", description: "Reports current weather for a city"}]
        }
    });

    Client c = check new (getServerBaseUrl());
    AgentCard card = check c->getExtendedAgentCard();

    test:assertEquals(card.name, "Mock Weather Agent (extended)");
}

@test:Config {}
function testGetExtendedAgentCardNotConfiguredErrorMapping() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        'error: {code: -32007, message: "Extended agent card not configured"}
    });

    Client c = check new (getServerBaseUrl());
    AgentCard|error result = c->getExtendedAgentCard();

    test:assertTrue(result is ExtendedAgentCardNotConfiguredError, "code -32007 should map to ExtendedAgentCardNotConfiguredError");
}

@test:Config {}
function testV03GetExtendedAgentCardTranslatesMethodName() returns error? {
    Client c = check v03Client();
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {
            name: "Legacy Agent (extended)",
            description: "x",
            version: "1.0.0",
            capabilities: {extendedAgentCard: true},
            skills: []
        }
    });

    AgentCard card = check c->getExtendedAgentCard();

    test:assertEquals(card.name, "Legacy Agent (extended)");
    json lastRequest = getLastRequestBody();
    test:assertEquals(check lastRequest.method, "agent/getAuthenticatedExtendedCard");
}

@test:Config {}
function testResolveAgentCardParsesRichFieldSetWithTypedSecurity() returns error? {
    setWellKnownOverride({
        name: "Rich Agent",
        description: "An agent with a full field set",
        version: "2.0.0",
        provider: {organization: "Acme Corp", url: "https://acme.example.com"},
        capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC"}
        ],
        securitySchemes: {
            "bearerAuth": {"type": "http", "scheme": "bearer"},
            "apiKeyAuth": {"type": "apiKey", "in": "header", "name": "X-API-Key"}
        },
        securityRequirements: [{"bearerAuth": []}],
        signatures: [
            {protected: "eyJhbGciOiJSUzI1NiJ9", signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ"}
        ],
        skills: []
    });

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    AgentCard card = check result;
    test:assertEquals(card.securitySchemes.length(), 2);
    test:assertTrue(card.securitySchemes.get("bearerAuth") is HttpAuthSecurityScheme);
    test:assertTrue(card.securitySchemes.get("apiKeyAuth") is ApiKeySecurityScheme);
    test:assertEquals(card.securityRequirements, [{"bearerAuth": []}]);
    test:assertEquals(card.signatures.length(), 1);
    test:assertEquals(card?.provider?.organization, "Acme Corp");
}

@test:Config {}
function testResolveAgentCardDropsUnrecognizedSecuritySchemeEntry() returns error? {
    setWellKnownOverride({
        name: "Agent With Unknown Scheme",
        description: "Advertises a scheme type this client doesn't know",
        version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "bearerAuth": {"type": "http", "scheme": "bearer"},
            "quantumAuth": {"type": "quantumEntanglement", "someField": "value"}
        },
        skills: []
    });

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    AgentCard card = check result;
    test:assertEquals(card.securitySchemes.length(), 1);
    test:assertTrue(card.securitySchemes.hasKey("bearerAuth"));
    test:assertFalse(card.securitySchemes.hasKey("quantumAuth"));
}

@test:Config {}
function testResolveAgentCardTranslatesV03SecurityField() returns error? {
    setWellKnownOverride({
        name: "v0.3 Agent",
        description: "Uses the v0.3 dialect's security field name",
        version: "1.0.0",
        protocolVersion: "0.3.0",
        capabilities: {},
        security: [{"oauth": ["read"]}],
        skills: []
    });

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    AgentCard card = check result;
    test:assertEquals(card.securityRequirements, [{"oauth": ["read"]}]);
}

@test:Config {}
function testResolveAgentCardDropsMalformedSignatureAndSecurityRequirementEntries() returns error? {
    setWellKnownOverride({
        name: "Agent With Some Malformed Security Data",
        description: "Has one good and one bad entry in signatures, securityRequirements, and a skill's securityRequirements",
        version: "1.0.0",
        capabilities: {},
        securityRequirements: [
            {"oauth": ["read"]},
            {"apiKey": "not-an-array"}
        ],
        signatures: [
            {"protected": "eyJhbGciOiJSUzI1NiJ9", "signature": "dGhpcyBpcyBhIHNpZ25hdHVyZQ"},
            {"header": {"alg": "RS256"}}
        ],
        skills: [
            {
                id: "skill-1",
                name: "Skill One",
                description: "Has a mix of good and bad securityRequirements entries",
                securityRequirements: [
                    {"oauth": ["write"]},
                    {"broken": "not-an-array"}
                ]
            }
        ]
    });

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    test:assertEquals(card.securityRequirements.length(), 1);
    test:assertEquals(card.securityRequirements[0], {"oauth": ["read"]});
    test:assertEquals(card.signatures.length(), 1);
    test:assertEquals(card.signatures[0].protected, "eyJhbGciOiJSUzI1NiJ9");
    test:assertEquals(card.skills[0].securityRequirements.length(), 1);
    test:assertEquals(card.skills[0].securityRequirements[0], {"oauth": ["write"]});
}

@test:Config {}
function testResolveAgentCardHonors304() returns error? {
    setWellKnownOverride(defaultMockAgentCard(), 200);
    setWellKnownETag(DEFAULT_MOCK_CARD_ETAG);
    CachedAgentCard first = check resolveAgentCardCached(getServerBaseUrl());
    test:assertTrue(first.etag is string, "first fetch should capture an ETag if the mock sends one");

    setWellKnownConditionalOverride(304);
    CachedAgentCard second = check resolveAgentCardCached(getServerBaseUrl(), previous = first);
    test:assertEquals(second.card, first.card, "a 304 response should return the previously cached card unchanged");

    setWellKnownOverride(());
}

@test:Config {}
function testResolveAgentCardReturnsErrorOn304() returns error? {
    // Regression test: resolveAgentCard (non-cached) should never panic on 304.
    // If a non-compliant server sends 304 to an unconditional GET, it should
    // be treated as a non-200 error and return a typed A2AInternalError, not panic.
    setWellKnownOverride(defaultMockAgentCard(), 304);

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    test:assertTrue(result is error, "resolveAgentCard should return an error on 304, not panic");
    test:assertTrue(result is A2AInternalError, "304 should map to A2AInternalError for unconditional requests");
}
