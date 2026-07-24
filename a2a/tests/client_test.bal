import ballerina/test;

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
