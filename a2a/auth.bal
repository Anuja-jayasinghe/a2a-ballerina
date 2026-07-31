// Automatic client-auth wiring from an AgentCard's declared security
// schemes — closes the gap where a developer previously had to read
// card.securitySchemes by hand and build http:ClientConfiguration.auth
// themselves. Scoped to ApiKeySecurityScheme and HttpAuthSecurityScheme
// only: both reduce to "one credential string the caller already has."
// OAuth2/OpenIdConnect need a token-acquisition flow and MutualTLS needs a
// client certificate — none of those reduce to a single string, so they're
// deliberately left for the caller to wire through clientConfig directly,
// same as today.

import ballerina/http;

# HTTP client configuration resolved from an AgentCard's security
# requirements: http:ClientConfiguration.auth for scheme types it natively
# supports, plus a header map for scheme types (like API key) that don't
# map onto ClientConfiguration.auth at all.
public type ResolvedAuth record {|
    http:ClientConfiguration clientConfig;
    map<string> headers;
|};

# Resolves an AgentCard's first satisfiable SecurityRequirement (a logical
# OR across card.securityRequirements, each entry a logical AND of the
# scheme names it lists — spec section on SecurityRequirement) against a
# caller-supplied credential map, keyed by scheme name exactly as declared
# in card.securitySchemes.
#
# + card - the AgentCard whose securitySchemes/securityRequirements to read
# + credentials - one credential string per scheme name this call should
#                 satisfy; a scheme absent from securityRequirements is
#                 ignored even if a credential is supplied for it
# Only card.securityRequirements (the top-level AgentCard field) is
# considered — per-skill AgentSkill.securityRequirements is out of scope
# for this pass. A card that declares security only at the skill level
# currently fails auto-wiring here even with otherwise-valid credentials.
#
# + return - resolved auth config, or an AuthResolutionError if no
#            SecurityRequirement entry can be fully satisfied by the given
#            credentials
public isolated function buildAuthFromCard(AgentCard card, map<string> credentials) returns ResolvedAuth|AuthResolutionError {
    foreach SecurityRequirement requirement in card.securityRequirements {
        string[] schemeNames = requirement.keys();
        boolean allSatisfiable = true;
        foreach string schemeName in schemeNames {
            if !credentials.hasKey(schemeName) || !card.securitySchemes.hasKey(schemeName) {
                allSatisfiable = false;
                break;
            }
        }
        if !allSatisfiable {
            continue;
        }
        http:ClientConfiguration clientConfig = {};
        map<string> headers = {};
        foreach string schemeName in schemeNames {
            SecurityScheme scheme = card.securitySchemes.get(schemeName);
            string credential = credentials.get(schemeName);
            if scheme is ApiKeySecurityScheme {
                if scheme.'in == "header" {
                    // Reject a declared header name that collides with a
                    // protocol-reserved header. Client.buildHeaders()
                    // applies these auto-wired headers after
                    // defaultHeaders, so an unverified (potentially
                    // malicious or malformed) AgentCard's declared API-key
                    // header name could otherwise silently override
                    // A2A-Version or Content-Type on every outbound
                    // request.
                    string lowerName = scheme.name.toLowerAscii();
                    if lowerName == "a2a-version" || lowerName == "content-type" {
                        return error AuthResolutionError(
                            string `apiKey scheme "${schemeName}" declares header name "${scheme.name}", which collides with a protocol-reserved header — refusing to auto-wire it`);
                    }
                    headers[scheme.name] = credential;
                } else {
                    return error AuthResolutionError(
                        string `apiKey scheme "${schemeName}" uses 'in: "${scheme.'in}"', which buildAuthFromCard does not automate yet — set it manually via Client.init's headers or serviceUrl query string`);
                }
            } else if scheme is HttpAuthSecurityScheme {
                if scheme.scheme.toLowerAscii() == "bearer" {
                    clientConfig.auth = {token: credential};
                } else if scheme.scheme.toLowerAscii() == "basic" {
                    // http:CredentialsConfig expects username+password, not
                    // one combined string. Caller must instead have supplied
                    // "username:password" as the credential value. Split on
                    // the *first* colon only — RFC 7617 forbids ':' in the
                    // username but explicitly allows it in the password, so
                    // splitting on every colon would wrongly reject (or
                    // truncate) a password that itself contains one.
                    int? colonIndex = credential.indexOf(":");
                    if colonIndex is () {
                        return error AuthResolutionError(
                            string `http Basic scheme "${schemeName}" requires credential in "username:password" form`);
                    }
                    string username = credential.substring(0, colonIndex);
                    string password = credential.substring(colonIndex + 1);
                    clientConfig.auth = {username, password};
                } else {
                    return error AuthResolutionError(
                        string `http auth scheme "${scheme.scheme}" (name: "${schemeName}") is not automated yet`);
                }
            } else {
                return error AuthResolutionError(
                    string `security scheme "${schemeName}" (type ${scheme.'type}) is not automated yet — OAuth2/OpenIdConnect/mutualTLS need manual clientConfig wiring`);
            }
        }
        return {clientConfig, headers};
    }
    return error AuthResolutionError("no SecurityRequirement in the AgentCard could be satisfied by the given credentials");
}
