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
