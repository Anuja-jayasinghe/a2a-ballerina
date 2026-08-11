// Auth adaptation between the HTTP and gRPC client stacks.
//
// This library does not derive auth configuration from an AgentCard's
// declared security schemes. The spec models securitySchemes/
// securityRequirements as card *data*; it defines no client-side API for
// turning a credential bag into wired-up transport auth, and neither
// reference SDK (Python a2a-sdk, Java) does so either — both accept auth
// configuration directly on their client builders. A prior
// buildAuthFromCard/ResolvedAuth pair here was removed before release;
// see issue #13.
//
// Callers configure auth through clientConfig.auth and headers, the same
// way as with any other Ballerina client. What remains below is the one
// piece that cannot be pushed onto the caller: the gRPC binding needs a
// grpc:ClientConfiguration, not an http:ClientConfiguration, so a
// caller-supplied auth value has to be projected across.

import ballerina/grpc;
import ballerina/http;

# Projects a caller-supplied http:ClientConfiguration.auth value onto the
# structurally equivalent grpc:ClientAuthConfig union, so the gRPC binding
# can honour auth configured the same way as for the HTTP bindings.
#
# This is a projection, not a resolution path: it reads whatever the
# caller already set and restates it in the gRPC stack's types.
#
# Confirmed against the real `ballerina/grpc:1.14.6` and `ballerina/http`
# distributions: grpc:CredentialsConfig has `username`/`password` fields
# (via `*auth:CredentialsConfig`) and grpc:BearerTokenConfig has a
# `token` field, both matching http:CredentialsConfig/http:BearerTokenConfig
# exactly. Those two shapes are therefore the ones projected; anything
# else (OAuth2/JWT auth configs) has no structural equivalent here.
#
# + clientConfig - the effective http:ClientConfiguration the client was
#                  constructed with
# + return - the equivalent grpc:ClientConfiguration, or an error if
#            clientConfig.auth is set to a shape this adapter doesn't
#            recognize
isolated function projectToGrpcClientConfig(http:ClientConfiguration clientConfig) returns grpc:ClientConfiguration|error {
    grpc:ClientConfiguration result = {};
    http:ClientAuthConfig? auth = clientConfig?.auth;
    if auth is http:CredentialsConfig {
        result.auth = {username: auth.username, password: auth.password};
    } else if auth is http:BearerTokenConfig {
        result.auth = {token: auth.token};
    } else if auth is () {
        // no auth configured — nothing to project
    } else {
        return error AuthResolutionError(
            "grpc binding only supports HTTP Basic/Bearer auth projected from http:ClientConfiguration.auth; the configured auth type is not automated for gRPC");
    }
    return result;
}
