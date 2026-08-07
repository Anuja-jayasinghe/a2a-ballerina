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
function testBuildAuthFromCardHttpBasicPasswordWithColonSucceeds() returns error? {
    // RFC 7617 forbids ':' in the username but explicitly allows it in the
    // password — splitting on every colon (instead of just the first) would
    // wrongly reject or truncate a password like this one.
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "basicAuth": {'type: "http", scheme: "Basic"}
        },
        securityRequirements: [{"basicAuth": []}],
        skills: []
    };
    ResolvedAuth resolved = check buildAuthFromCard(card, {"basicAuth": "alice:s3:cret"});
    http:ClientAuthConfig? auth = resolved.clientConfig.auth;
    test:assertTrue(auth is http:CredentialsConfig, "http+Basic scheme should resolve to CredentialsConfig");
    if auth is http:CredentialsConfig {
        test:assertEquals(auth.username, "alice");
        test:assertEquals(auth.password, "s3:cret");
    }
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

// The tests above all build their AgentCard from typed records directly, which
// bypasses parseSecuritySchemes entirely. The ones below go through
// parseAgentCardBody first, so they exercise the real path a v1.0 agent's card
// takes: raw oneof-wrapped JSON off the wire, then auth resolution. That whole
// path used to fail — every wrapper-form scheme parsed as MutualTlsSecurityScheme,
// so buildAuthFromCard rejected it as un-automatable.

# A v1.0 AgentCard body carrying one oneof-wrapped security scheme.
isolated function v10CardWithScheme(string schemeName, json scheme) returns json => {
    "name": "n",
    "description": "d",
    "version": "1.0.0",
    "capabilities": {},
    "supportedInterfaces": [{"url": "http://localhost:19199", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}],
    "securitySchemes": {[schemeName]: scheme},
    "securityRequirements": [{[schemeName]: []}],
    "skills": []
};

@test:Config {}
function testBuildAuthFromCardV10WrapperApiKey() returns error? {
    AgentCard card = check parseAgentCardBody(v10CardWithScheme(
        "apiKeyAuth", {"apiKeySecurityScheme": {"location": "header", "name": "X-Api-Key"}}));

    test:assertTrue(card.securitySchemes.get("apiKeyAuth") is ApiKeySecurityScheme,
        "a v1.0 oneof-wrapped apiKey scheme must parse as ApiKeySecurityScheme, not be swallowed by MutualTlsSecurityScheme");

    ResolvedAuth resolved = check buildAuthFromCard(card, {"apiKeyAuth": "secret-123"});
    test:assertEquals(resolved.headers["X-Api-Key"], "secret-123");
}

@test:Config {}
function testBuildAuthFromCardV10WrapperHttpBearer() returns error? {
    AgentCard card = check parseAgentCardBody(v10CardWithScheme(
        "bearerAuth", {"httpAuthSecurityScheme": {"scheme": "bearer", "bearerFormat": "JWT"}}));

    test:assertTrue(card.securitySchemes.get("bearerAuth") is HttpAuthSecurityScheme,
        "a v1.0 oneof-wrapped http scheme must parse as HttpAuthSecurityScheme");

    ResolvedAuth resolved = check buildAuthFromCard(card, {"bearerAuth": "tok-abc"});
    http:ClientAuthConfig? auth = resolved.clientConfig.auth;
    test:assertTrue(auth is http:BearerTokenConfig, "v1.0 http+Bearer scheme should resolve to BearerTokenConfig");
    if auth is http:BearerTokenConfig {
        test:assertEquals(auth.token, "tok-abc");
    }
}

@test:Config {}
function testBuildAuthFromCardV10WrapperSnakeCaseApiKey() returns error? {
    // The spec's SecurityScheme schema accepts each arm under a snake_case
    // spelling too, via patternProperties — a server emitting protobuf JSON
    // with original field names sends this form.
    AgentCard card = check parseAgentCardBody(v10CardWithScheme(
        "apiKeyAuth", {"api_key_security_scheme": {"location": "header", "name": "X-Api-Key"}}));

    test:assertTrue(card.securitySchemes.get("apiKeyAuth") is ApiKeySecurityScheme,
        "the snake_case arm spelling must parse identically to the camelCase one");

    ResolvedAuth resolved = check buildAuthFromCard(card, {"apiKeyAuth": "secret-123"});
    test:assertEquals(resolved.headers["X-Api-Key"], "secret-123");
}

@test:Config {}
function testBuildAuthFromCardV10WrapperReservedHeaderStillGuarded() returns error? {
    // The reserved-header collision guard must apply to the v1.0 form too —
    // an unverified card must not be able to override A2A-Version.
    AgentCard card = check parseAgentCardBody(v10CardWithScheme(
        "apiKeyAuth", {"apiKeySecurityScheme": {"location": "header", "name": "A2A-Version"}}));

    ResolvedAuth|AuthResolutionError result = buildAuthFromCard(card, {"apiKeyAuth": "malicious"});
    test:assertTrue(result is AuthResolutionError,
        "an apiKey scheme declaring a protocol-reserved header name must be refused, on the v1.0 form as much as the v0.3 one");
}
