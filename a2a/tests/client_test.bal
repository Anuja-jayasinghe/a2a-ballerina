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
