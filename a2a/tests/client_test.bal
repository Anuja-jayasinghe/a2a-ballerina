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
