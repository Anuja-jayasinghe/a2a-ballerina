// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// projectToGrpcClientConfig (auth.bal): projecting a caller-supplied
// http:ClientConfiguration.auth value onto the structurally equivalent
// grpc:ClientAuthConfig union.
//
// Direct unit tests against the module-private function, not through a
// full GrpcClient construction - no network I/O, no mock server needed.
// Before the gRPC auth parity fix, OAuth2/JWT configs made this function
// return AuthResolutionError; that branch (and the type) no longer exist,
// so these tests assert the positive projection for every branch instead.

import ballerina/grpc;
import ballerina/http;
import ballerina/test;

@test:Config {}
function testProjectToGrpcClientConfigProjectsCredentials() {
    http:ClientConfiguration config = {auth: {username: "u", password: "p"}};
    grpc:ClientConfiguration result = projectToGrpcClientConfig(config);
    grpc:ClientAuthConfig? auth = result?.auth;
    test:assertTrue(auth is grpc:CredentialsConfig, "http Basic auth must project to grpc:CredentialsConfig");
    grpc:CredentialsConfig creds = <grpc:CredentialsConfig>auth;
    test:assertEquals(creds.username, "u");
    test:assertEquals(creds.password, "p");
}

@test:Config {}
function testProjectToGrpcClientConfigProjectsBearerToken() {
    http:ClientConfiguration config = {auth: {token: "tok-123"}};
    grpc:ClientConfiguration result = projectToGrpcClientConfig(config);
    grpc:ClientAuthConfig? auth = result?.auth;
    test:assertTrue(auth is grpc:BearerTokenConfig, "http Bearer auth must project to grpc:BearerTokenConfig");
    test:assertEquals((<grpc:BearerTokenConfig>auth).token, "tok-123");
}

@test:Config {}
function testProjectToGrpcClientConfigProjectsJwtIssuerConfig() {
    // All jwt:IssuerConfig fields are optional; issuer alone is enough to
    // prove the value survives projection intact.
    http:ClientConfiguration config = {auth: {issuer: "a2a-test-issuer"}};
    grpc:ClientConfiguration result = projectToGrpcClientConfig(config);
    grpc:ClientAuthConfig? auth = result?.auth;
    test:assertTrue(auth is grpc:JwtIssuerConfig,
            "http JwtIssuerConfig auth must now project to grpc:JwtIssuerConfig, not error - the gRPC auth parity fix");
    test:assertEquals((<grpc:JwtIssuerConfig>auth).issuer, "a2a-test-issuer");
}

@test:Config {}
function testProjectToGrpcClientConfigProjectsOAuth2ClientCredentialsGrant() {
    // No network I/O here: projection only restates the config in the
    // gRPC stack's types, it never triggers a token fetch. tokenUrl is
    // deliberately unreachable/fake - that's fine, nothing calls it.
    http:ClientConfiguration config = {
        auth: {tokenUrl: "https://auth.example.com/token", clientId: "id", clientSecret: "secret"}
    };
    grpc:ClientConfiguration result = projectToGrpcClientConfig(config);
    grpc:ClientAuthConfig? auth = result?.auth;
    test:assertTrue(auth is grpc:OAuth2ClientCredentialsGrantConfig,
            "http OAuth2ClientCredentialsGrantConfig auth must now project to gRPC, not error - previously the AuthResolutionError case");
    grpc:OAuth2ClientCredentialsGrantConfig oauth2Config = <grpc:OAuth2ClientCredentialsGrantConfig>auth;
    test:assertEquals(oauth2Config.tokenUrl, "https://auth.example.com/token");
    test:assertEquals(oauth2Config.clientId, "id");
}

@test:Config {}
function testProjectToGrpcClientConfigWithNoAuthConfigured() {
    http:ClientConfiguration config = {};
    grpc:ClientConfiguration result = projectToGrpcClientConfig(config);
    test:assertTrue(result?.auth is (), "no auth configured must project to no auth, not an error");
}

// resolveCredentialHeaders / credentialHeadersFor (auth.bal): turning a
// card's declared securityRequirements plus a CredentialProvider into the
// headers a request actually carries.
//
// Direct unit tests against the module-private resolution functions - no
// client construction, no network I/O. Each card below declares only what
// the case under test needs.

# Builds a card declaring the given schemes and card-level requirements.
#
# + schemes - securitySchemes to declare, keyed by scheme name
# + requirements - securityRequirements, an OR across the list
# + return - a minimal card carrying exactly those declarations
isolated function cardWithSecurity(map<SecurityScheme> schemes, SecurityRequirement[] requirements)
        returns AgentCard {
    return {
        name: "secured",
        description: "x",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [{url: "https://agent.example.com", protocolBinding: "JSONRPC"}],
        skills: [],
        securitySchemes: schemes,
        securityRequirements: requirements
    };
}

@test:Config {}
function testResolveCredentialHeadersBuildsBearerHeader() {
    AgentCard card = cardWithSecurity(
            {"bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}},
            [{"bearer-admin": []}]);
    InMemoryCredentialStore store = new ({"bearer-admin": "tok_abc"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"Authorization": "Bearer tok_abc"});
}

@test:Config {}
function testResolveCredentialHeadersBuildsApiKeyHeaderUnderItsDeclaredName() {
    // The header name comes from the card, not from a fixed convention -
    // this is the whole reason an API-key scheme carries a `name` field.
    AgentCard card = cardWithSecurity(
            {"key": <ApiKeySecurityScheme>{'in: "header", name: "X-Payroll-Key"}},
            [{"key": []}]);
    InMemoryCredentialStore store = new ({"key": "k_123"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"X-Payroll-Key": "k_123"});
}

@test:Config {}
function testResolveCredentialHeadersBase64EncodesBasicCredentialWholesale() {
    // RFC 7617 permits ":" in the password but not the username, so a
    // naive split-on-colon corrupts exactly this credential. Nothing here
    // splits: the whole string is encoded as given.
    AgentCard card = cardWithSecurity(
            {"basic": <HttpAuthSecurityScheme>{scheme: "basic"}},
            [{"basic": []}]);
    InMemoryCredentialStore store = new ({"basic": "alice:pa:ss:word"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"Authorization": string `Basic ${"alice:pa:ss:word".toBytes().toBase64()}`});
}

@test:Config {}
function testResolveCredentialHeadersPicksFirstFullySatisfiableRequirement() {
    // securityRequirements is an OR, each entry an AND. The first entry
    // cannot be met (no credential for "mtls-internal"), so resolution
    // must fall through to the second rather than partially satisfying
    // the first.
    AgentCard card = cardWithSecurity(
            {
                "key": <ApiKeySecurityScheme>{'in: "header", name: "X-Key"},
                "mtls-internal": <MutualTlsSecurityScheme>{},
                "bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}
            },
            [{"key": [], "mtls-internal": []}, {"bearer-admin": []}]);
    InMemoryCredentialStore store = new ({"key": "k_123", "bearer-admin": "tok_abc"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"Authorization": "Bearer tok_abc"},
            "a partially satisfiable AND must be skipped entirely, not half-applied");
}

@test:Config {}
function testResolveCredentialHeadersSatisfiesEverySchemeInOneRequirement() {
    AgentCard card = cardWithSecurity(
            {
                "key": <ApiKeySecurityScheme>{'in: "header", name: "X-Key"},
                "bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}
            },
            [{"key": [], "bearer-admin": []}]);
    InMemoryCredentialStore store = new ({"key": "k_123", "bearer-admin": "tok_abc"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"X-Key": "k_123", "Authorization": "Bearer tok_abc"});
}

@test:Config {}
function testResolveCredentialHeadersRefusesToOccupyAReservedHeader() {
    // A card is not necessarily signature-verified, so an agent could
    // declare an API-key scheme whose header name is one this library
    // relies on and silently change every request's protocol version.
    AgentCard card = cardWithSecurity(
            {"sneaky": <ApiKeySecurityScheme>{'in: "header", name: "A2A-Version"}},
            [{"sneaky": []}]);
    InMemoryCredentialStore store = new ({"sneaky": "0.3"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {}, "a credential must never be allowed to occupy A2A-Version");
}

@test:Config {}
function testResolveCredentialHeadersSkipsSchemesNeedingATokenExchange() {
    // OAuth2/OIDC/mTLS do not reduce to one string; they belong on
    // clientConfig.auth. Resolution must decline rather than invent a
    // header for them.
    AgentCard card = cardWithSecurity(
            {"oidc": <OpenIdConnectSecurityScheme>{openIdConnectUrl: "https://idp.example.com/.well-known/openid-configuration"}},
            [{"oidc": []}]);
    InMemoryCredentialStore store = new ({"oidc": "tok_abc"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {}, "OpenID Connect must not be resolved into a bearer header here");
}

@test:Config {}
function testResolveCredentialHeadersSkipsApiKeyCarriedOutsideAHeader() {
    AgentCard card = cardWithSecurity(
            {"key": <ApiKeySecurityScheme>{'in: "query", name: "api_key"}},
            [{"key": []}]);
    InMemoryCredentialStore store = new ({"key": "k_123"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {}, "a query-borne API key cannot be satisfied through a header map");
}

@test:Config {}
function testResolveCredentialHeadersWithNoProviderOrNoCredential() {
    AgentCard card = cardWithSecurity(
            {"bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}},
            [{"bearer-admin": []}]);
    test:assertEquals(resolveCredentialHeaders(card, ()), {},
            "no provider must resolve to no headers, not an error");
    InMemoryCredentialStore empty = new ();
    test:assertEquals(resolveCredentialHeaders(card, empty), {},
            "an unsatisfiable requirement must send the request bare and let the agent answer, not fail locally");
}

@test:Config {}
function testResolveCredentialHeadersIgnoresUndeclaredScheme() {
    // A requirement naming a scheme the card never declared is malformed.
    // Resolution declines it rather than guessing at the scheme's kind.
    AgentCard card = cardWithSecurity({}, [{"ghost": []}]);
    InMemoryCredentialStore store = new ({"ghost": "tok_abc"});
    test:assertEquals(resolveCredentialHeaders(card, store), {});
}

@test:Config {}
function testInMemoryCredentialStoreReplacesCredentialAfterConstruction() {
    // The point of a provider over a static header map: a refreshed token
    // must not require building a new client.
    AgentCard card = cardWithSecurity(
            {"bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}},
            [{"bearer-admin": []}]);
    InMemoryCredentialStore store = new ({"bearer-admin": "tok_old"});
    test:assertEquals(resolveCredentialHeaders(card, store), {"Authorization": "Bearer tok_old"});
    store.setCredential("bearer-admin", "tok_new");
    test:assertEquals(resolveCredentialHeaders(card, store), {"Authorization": "Bearer tok_new"},
            "a replaced credential must be picked up on the next resolution");
}
