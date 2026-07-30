import ballerina/test;
import ballerina/http;

@test:Config {}
function testBuildAuthFromCardApiKeyHeader() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "apiKeyAuth": {'type: "apiKey", 'in: "header", name: "X-Api-Key"}
        },
        securityRequirements: [{"apiKeyAuth": []}],
        skills: []
    };
    ResolvedAuth resolved = check buildAuthFromCard(card, {"apiKeyAuth": "secret-123"});
    test:assertEquals(resolved.headers["X-Api-Key"], "secret-123");
}

@test:Config {}
function testBuildAuthFromCardHttpBearer() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "bearerAuth": {'type: "http", scheme: "Bearer"}
        },
        securityRequirements: [{"bearerAuth": []}],
        skills: []
    };
    ResolvedAuth resolved = check buildAuthFromCard(card, {"bearerAuth": "tok-abc"});
    http:ClientAuthConfig? auth = resolved.clientConfig.auth;
    test:assertTrue(auth is http:BearerTokenConfig, "http+Bearer scheme should resolve to BearerTokenConfig");
    if auth is http:BearerTokenConfig {
        test:assertEquals(auth.token, "tok-abc");
    }
}

@test:Config {}
function testBuildAuthFromCardMissingCredentialErrors() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {"apiKeyAuth": {'type: "apiKey", 'in: "header", name: "X-Api-Key"}},
        securityRequirements: [{"apiKeyAuth": []}],
        skills: []
    };
    ResolvedAuth|error result = buildAuthFromCard(card, {});
    test:assertTrue(result is error, "missing a required scheme's credential should error, not silently send an unauthenticated request");
}
