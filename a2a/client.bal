// A2A client implementation.

import ballerina/a2a.transport;
import ballerina/http;
import ballerina/uuid;

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

# An A2A protocol client for calling remote agents.
public isolated client class Client {
    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    private final string? tenant;

    # Creates a client pointed at a remote A2A agent.
    #
    # + serviceUrl - Base URL of the remote agent's A2A endpoint
    # + clientConfig - Full http:ClientConfiguration. Covers auth, TLS,
    #                  retry, circuit breaker, proxy, timeouts, and
    #                  connection pooling.
    # + headers - Default headers merged into every outbound request. Use
    #             for API key schemes requiring a custom header name.
    #             Bearer and OAuth2 auth belong in clientConfig.auth.
    # + tenant - Optional multi-tenant routing identifier. When the selected
    #            AgentInterface in the Agent Card declares a tenant value,
    #            that value must be supplied here so it is sent with every
    #            operation. Leave unset for single-tenant agents.
    # + return - error if the underlying http:Client cannot be created
    public isolated function init(
            string serviceUrl,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = ()) returns error? {
        self.httpClient = check new (serviceUrl, clientConfig);
        self.defaultHeaders = headers.cloneReadOnly();
        self.tenant = tenant;
    }

    # Builds the header map for an outbound request. The A2A-Version header
    # is mandatory on every request per specification section 3.6.1; an
    # agent receiving an empty value assumes protocol version 0.3, which
    # would silently downgrade the interaction.
    #
    # + return - the headers to send with the request
    private isolated function buildHeaders() returns map<string> {
        map<string> headers = {
            "Content-Type": "application/json",
            "A2A-Version": "1.0"
        };
        foreach [string, string] [k, v] in self.defaultHeaders.entries() {
            headers[k] = v;
        }
        return headers;
    }

    # Performs a unary JSON-RPC call and returns the unwrapped result.
    #
    # + method - the JSON-RPC method name
    # + params - the JSON-RPC method parameters
    # + return - the unwrapped result, or an error
    private isolated function rpcCall(string method, map<json> params) returns json|error {
        transport:JsonRpcRequest req = {
            id: uuid:createType4AsString(),
            method: method,
            params: params
        };
        http:Response resp = check self.httpClient->post(
            "", req.toJson(), self.buildHeaders()
        );
        json body = check resp.getJsonPayload();
        transport:JsonRpcResponse rpcResp =
            check body.cloneWithType(transport:JsonRpcResponse);
        transport:JsonRpcError? rpcErr = rpcResp?.'error;
        if rpcErr is transport:JsonRpcError {
            return toA2AError(rpcErr);
        }
        json? result = rpcResp?.result;
        if result is () {
            return error InvalidAgentResponseError(
                "JSON-RPC response contained neither result nor error"
            );
        }
        return result;
    }

    # Sends a message to the remote agent.
    #
    # Blocking by default: the call does not return until the task reaches
    # a terminal or interrupted state. Set config.returnImmediately to true
    # for non-blocking behaviour, then poll with getTask or subscribe with
    # subscribeToTask.
    #
    # The agent may respond with a Task for tracked work, or with a Message
    # for a simple direct reply that needs no task lifecycle. Both are
    # valid per specification section 3.1.1, so the return type covers
    # both.
    #
    # + message - The message to send; messageId must be set by the caller
    # + config - Optional send configuration
    # + tenant - Optional per-call tenant override
    # + return - A Task or a Message on success, or an error on failure
    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = ()) returns Task|Message|error {
        map<json> params = {"message": message.toJson()};
        if config is SendMessageConfiguration {
            params["configuration"] = config.toJson();
        }
        string? effectiveTenant = tenant ?: self.tenant;
        if effectiveTenant is string {
            params["tenant"] = effectiveTenant;
        }

        json result = check self.rpcCall("message/send", params);

        // Try Task first; fall back to Message. Both are valid responses.
        Task|error asTask = result.cloneWithType(Task);
        if asTask is Task {
            return asTask;
        }
        Message|error asMessage = result.cloneWithType(Message);
        if asMessage is Message {
            return asMessage;
        }
        return error InvalidAgentResponseError(
            "Response was neither a valid Task nor a valid Message"
        );
    }
}
