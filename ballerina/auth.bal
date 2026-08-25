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
# distributions: grpc:ClientAuthConfig and http:ClientAuthConfig are the
# *same* union - CredentialsConfig|BearerTokenConfig|JwtIssuerConfig|
# OAuth2GrantConfig - and every member on the grpc side is defined as a
# bare `record {| *http_or_shared_base; |}` wrapping the identical
# `auth:CredentialsConfig`/`jwt:IssuerConfig`/`oauth2:*GrantConfig` base
# type the http side wraps, with no additional fields either side. All
# four shapes therefore project directly, OAuth2 and JWT included -
# per spec section 7.3, credential transmission applies "for every A2A
# request", not just HTTP-bound ones. This closes what was previously an
# artificial gRPC-only limitation (see design spec, gRPC auth parity).
#
# OAuth2's automatic token refresh (ballerina/oauth2's TokenCache,
# regenerated per request) and JWT issuance both keep working unchanged
# here, since projection is structural, not a one-time credential
# extraction - the grpc:Client re-invokes the same provider machinery
# http:Client would.
#
# Every branch of http:ClientAuthConfig now has a grpc:ClientAuthConfig
# equivalent (see doc comment above), so this can no longer fail —
# unlike its predecessor, which returned AuthResolutionError for
# OAuth2/JWT. That type had no other caller and was removed with it.
#
# + clientConfig - the effective http:ClientConfiguration the client was
#                  constructed with
# + return - the equivalent grpc:ClientConfiguration
isolated function projectToGrpcClientConfig(http:ClientConfiguration clientConfig) returns grpc:ClientConfiguration {
    grpc:ClientConfiguration result = {};
    http:ClientAuthConfig? auth = clientConfig?.auth;
    if auth is http:CredentialsConfig {
        result.auth = {username: auth.username, password: auth.password};
    } else if auth is http:BearerTokenConfig {
        result.auth = {token: auth.token};
    } else if auth is http:JwtIssuerConfig {
        result.auth = auth;
    } else if auth is http:OAuth2ClientCredentialsGrantConfig
            || auth is http:OAuth2PasswordGrantConfig
            || auth is http:OAuth2RefreshTokenGrantConfig
            || auth is http:OAuth2JwtBearerGrantConfig {
        result.auth = auth;
    }
    // else: auth is () — no auth configured, nothing to project.
    return result;
}
