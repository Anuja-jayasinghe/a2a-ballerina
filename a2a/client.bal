// A2A client implementation.

import ballerina/http;

# Fetches and parses a remote agent's Agent Card from its well-known
# endpoint.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers, for API key authentication
# + return - The parsed AgentCard, or an error if the fetch or parse fails
public isolated function resolveAgentCard(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns AgentCard|error {
    http:Client discoveryClient = check new (agentBaseUrl, clientConfig);
    map<string> reqHeaders = {"A2A-Version": "1.0"};
    foreach [string, string] [k, v] in headers.entries() {
        reqHeaders[k] = v;
    }
    http:Response resp = check discoveryClient->get(
        "/.well-known/agent-card.json", reqHeaders
    );
    if resp.statusCode != 200 {
        return error A2AInternalError(
            string `Agent Card fetch failed with HTTP ${resp.statusCode}`,
            code = resp.statusCode
        );
    }
    json body = check resp.getJsonPayload();
    return check body.cloneWithType(AgentCard);
}
