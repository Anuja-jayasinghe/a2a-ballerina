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

@test:Config {}
function testBuildAuthFromCardHttpBasicSuccess() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "basicAuth": {'type: "http", scheme: "Basic"}
        },
        securityRequirements: [{"basicAuth": []}],
        skills: []
    };
    ResolvedAuth resolved = check buildAuthFromCard(card, {"basicAuth": "alice:s3cret"});
    http:ClientAuthConfig? auth = resolved.clientConfig.auth;
    test:assertTrue(auth is http:CredentialsConfig, "http+Basic scheme should resolve to CredentialsConfig");
    if auth is http:CredentialsConfig {
        test:assertEquals(auth.username, "alice");
        test:assertEquals(auth.password, "s3cret");
    }
}

@test:Config {}
function testBuildAuthFromCardHttpBasicMalformedCredentialErrors() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "basicAuth": {'type: "http", scheme: "Basic"}
        },
        securityRequirements: [{"basicAuth": []}],
        skills: []
    };
    ResolvedAuth|AuthResolutionError result = buildAuthFromCard(card, {"basicAuth": "no-colon-here"});
    test:assertTrue(result is AuthResolutionError, "a Basic credential missing the \"username:password\" form should error");
}

@test:Config {}
function testBuildAuthFromCardOAuth2NotAutomatedErrors() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "oauth2Auth": {'type: "oauth2", flows: {}}
        },
        securityRequirements: [{"oauth2Auth": []}],
        skills: []
    };
    ResolvedAuth|AuthResolutionError result = buildAuthFromCard(card, {"oauth2Auth": "irrelevant"});
    test:assertTrue(result is AuthResolutionError, "OAuth2 scheme is out of scope for buildAuthFromCard and should error rather than being silently skipped");
}
