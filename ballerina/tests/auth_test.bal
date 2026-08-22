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
