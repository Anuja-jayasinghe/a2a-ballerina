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

@test:Config {}
function testSendMessageHappyPath() returns error? {
    setNextJsonResponse({
        jsonrpc: "2.0",
        id: "1",
        result: {
            id: "task-1",
            contextId: "ctx-1",
            status: {state: "TASK_STATE_COMPLETED"},
            artifacts: [
                {artifactId: "art-1", parts: [{text: "29 degrees Celsius and partly cloudy."}]}
            ]
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
    http:SseEvent[] minimalSseResponse = [
        {data: string `{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"task-tenant","contextId":"ctx-tenant","status":{"state":"TASK_STATE_WORKING"}}}}`}
    ];

    setNextJsonResponse(validTaskResponse);
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
        result: {id: "task-tenant-2", status: {state: "TASK_STATE_COMPLETED"}}
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
