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

// The internal HTTP service the Listener attaches.
//
// It owns the A2A wire: it serves the Agent Card at the well-known path,
// routes the operation endpoints (both the bare and the /{tenant}-prefixed
// forms the proto's additional_bindings define), runs the capability and
// version gates, and turns an `a2a:Error` into the google.rpc.Status body the
// client decodes. The task lifecycle itself lives in `default_handler.bal`;
// this file is transport.
//
// A single catch-all resource matches every request and dispatches on the raw
// path. The A2A paths use literal colons (`/message:send`, `/tasks/{id}:cancel`)
// which are not ordinary path segments, so matching the raw path is simpler
// and more faithful than trying to express them as typed resource paths.

import ballerina/http;

isolated service class DispatcherService {
    *http:Service;

    private final AgentCard & readonly card;
    private final DefaultHandler handler;

    isolated function init(AgentCard card, DefaultHandler handler) {
        self.card = card.cloneReadOnly();
        self.handler = handler;
    }

    isolated resource function get [string... path](http:Request req) returns http:Response {
        return self.dispatch("GET", "/" + string:'join("/", ...path), req);
    }

    isolated resource function post [string... path](http:Request req) returns http:Response {
        return self.dispatch("POST", "/" + string:'join("/", ...path), req);
    }

    isolated resource function delete [string... path](http:Request req) returns http:Response {
        return self.dispatch("DELETE", "/" + string:'join("/", ...path), req);
    }

    # Routes one request to the operation its method and path name, applying
    # the tenant, version, and capability gates first.
    #
    # + method - The HTTP method
    # + rawPath - The request path with a leading slash, tenant prefix intact
    # + req - The HTTP request
    # + return - The response to send
    private isolated function dispatch(string method, string rawPath, http:Request req) returns http:Response {
        // Discovery is unversioned and untenanted. The served card's
        // interface URL is filled from the Host the client reached us on —
        // the server knows its port but not its externally-visible host, so
        // the request that fetches the card is what reveals it. This is how a
        // client that resolves the card then gets a usable URL to call.
        if method == "GET" && rawPath == "/.well-known/agent-card.json" {
            http:Response cardResponse = new;
            cardResponse.setJsonPayload(self.cardForHost(req).toJson());
            return cardResponse;
        }

        Error? versionError = self.checkVersion(req);
        if versionError is Error {
            return toRestErrorResponse(versionError);
        }

        // Strip a leading /{tenant} segment. The tenant must match the card's
        // declared one; the untenanted form carries no tenant.
        [string, string?]|Error routed = self.stripTenant(rawPath);
        if routed is Error {
            return toRestErrorResponse(routed);
        }
        [string, string?] [path, tenant] = routed;

        http:Response|Error result = self.route(method, path, tenant, req);
        return result is http:Response ? result : toRestErrorResponse(result);
    }

    # The served card with its HTTP+JSON interface URL filled from the
    # request's Host header.
    #
    # + req - The discovery request
    # + return - A copy of the card with a usable interface URL
    private isolated function cardForHost(http:Request req) returns AgentCard {
        string|http:HeaderNotFoundError host = req.getHeader("Host");
        if host !is string {
            return self.card;
        }
        // The held card is readonly, so round-trip through JSON for a fresh
        // mutable copy, then fill the HTTP+JSON interface's URL.
        // `deriveServedCard` put a single such entry there.
        AgentCard|error served = self.card.toJson().cloneWithType(AgentCard);
        if served is error {
            return self.card;
        }
        foreach int i in 0 ..< served.supportedInterfaces.length() {
            if served.supportedInterfaces[i].protocolBinding == "HTTP+JSON" {
                served.supportedInterfaces[i].url = string `http://${host}`;
            }
        }
        return served;
    }

    # Rejects a request whose A2A-Version header names anything but exactly
    # 1.0. An absent header means 0.3 (section 3.6.2), which this v1.0-only
    # server does not serve. Specification section 3.6.2 requires Major.Minor
    # to match exactly and gives no guarantee that a later 1.x minor stays
    # wire-compatible with 1.0 -- so "1.1" is exactly as unsafe to accept as
    # "2.0" or "0.3" is. Matches the client-side requireV1Interface check.
    #
    # + req - The HTTP request
    # + return - A VersionNotSupportedError when the version is unsupported
    private isolated function checkVersion(http:Request req) returns Error? {
        string|http:HeaderNotFoundError header = req.getHeader("A2A-Version");
        string version = header is string ? header : "0.3";
        if version != "1.0" {
            string msg = string `A2A protocol version ${version} is not supported; `
                + string `this interface serves v1.0`;
            return error VersionNotSupportedError(msg, message = msg);
        }
        return;
    }

    # Splits an optional leading /{tenant} segment off the path.
    #
    # The proto gives every operation a /{tenant}-prefixed additional binding.
    # A prefixed request must carry the tenant the card declares, or it is
    # rejected; the bare form carries no tenant.
    #
    # + rawPath - The request path
    # + return - The path with any tenant prefix removed, and the tenant (or
    #            `()`); or an error if a tenant prefix does not match the card
    private isolated function stripTenant(string rawPath) returns [string, string?]|Error {
        // The known operation paths all begin with one of these.
        foreach string known in ["/message:", "/tasks", "/extendedAgentCard"] {
            if rawPath.startsWith(known) {
                return [rawPath, ()];
            }
        }
        // Otherwise the first segment is a tenant: /{tenant}/rest...
        int? secondSlash = rawPath.indexOf("/", 1);
        if secondSlash is int {
            string tenant = rawPath.substring(1, secondSlash);
            string rest = rawPath.substring(secondSlash);
            string? declared = declaredTenant(self.card);
            if declared is () || declared != tenant {
                string msg = string `request routed under tenant "${tenant}", which the agent does not serve`;
                return error InvalidAgentResponseError(msg, message = msg);
            }
            return [rest, tenant];
        }
        return [rawPath, ()];
    }

    # Dispatches a tenant-stripped path to its operation.
    #
    # Only the unary operations are wired in this release; streaming, the
    # push-config store, and the extended card are added in later changes,
    # and an unmatched path is a 404-shaped InternalError.
    #
    # + method - The HTTP method
    # + path - The path with no tenant prefix
    # + tenant - The matched tenant, or `()`
    # + req - The HTTP request
    # + return - The response, or an error to serialise
    private isolated function route(string method, string path, string? tenant, http:Request req)
            returns http:Response|Error {
        if method == "POST" && path == "/message:send" {
            return self.onSendMessage(tenant, req);
        }
        if method == "POST" && path.startsWith("/tasks/") && path.endsWith(":cancel") {
            string id = path.substring("/tasks/".length(), path.length() - ":cancel".length());
            return jsonResponse((check self.handler.cancelTask({id})).toJson());
        }
        if method == "GET" && path == "/tasks" {
            ListTasksRequest filter = queryToListFilter(req);
            return jsonResponse((check self.handler.listTasks(filter)).toJson());
        }
        if method == "GET" && path.startsWith("/tasks/") && !path.includes(":")
                && !path.includes("/pushNotificationConfigs") {
            string id = path.substring("/tasks/".length());
            int? historyLength = queryInt(req, "historyLength");
            return jsonResponse((check self.handler.getTask({id, historyLength})).toJson());
        }
        string msg = string `no A2A operation at ${method} ${path}`;
        return error InternalError(msg, message = msg, code = http:STATUS_NOT_FOUND);
    }

    # Handles POST /message:send: decode the request, run onMessage through
    # the default handler, and serialise the Task or Message it returns.
    #
    # + tenant - The matched tenant, or `()`
    # + req - The HTTP request
    # + return - The response, or an error
    private isolated function onSendMessage(string? tenant, http:Request req) returns http:Response|Error {
        json|error payload = req.getJsonPayload();
        if payload is error {
            return invalidAgentResponse(string `request body is not valid JSON: ${payload.message()}`);
        }
        SendMessageRequest|error request = payload.cloneWithType(SendMessageRequest);
        if request is error {
            return invalidAgentResponse(
                    string `request body did not match SendMessageRequest: ${request.message()}`);
        }
        Task|Message result = check self.handler.sendMessage(request, tenant);
        // The wire wraps the result in its oneof arm, matching what the client
        // decodes: {"task": ...} or {"message": ...}.
        string arm = result is Task ? "task" : "message";
        json|error wired = encodeRawBytesForWire(result.toJson());
        if wired is error {
            return wrapTransportError(wired);
        }
        return jsonResponse({[arm]: wired});
    }
}

# Reads the tenant a card declares on its HTTP+JSON interface, or `()`.
#
# + card - The agent card
# + return - The declared tenant, or `()` if the interface declares none
isolated function declaredTenant(AgentCard card) returns string? {
    foreach AgentInterface iface in card.supportedInterfaces {
        if iface.protocolBinding == "HTTP+JSON" {
            return iface?.tenant;
        }
    }
    return ();
}

# Builds a JSON 200 response.
#
# + body - The JSON body
# + return - The response
isolated function jsonResponse(json body) returns http:Response {
    http:Response response = new;
    response.setJsonPayload(body);
    return response;
}

# Reads an integer query parameter, or `()` if absent or unparseable.
#
# + req - The request
# + name - The parameter name
# + return - The integer value, or `()`
isolated function queryInt(http:Request req, string name) returns int? {
    string? raw = req.getQueryParamValue(name);
    if raw is () {
        return ();
    }
    int|error parsed = int:fromString(raw);
    return parsed is int ? parsed : ();
}

# Builds a ListTasksRequest from the query string of a GET /tasks request.
#
# + req - The request
# + return - The filter
isolated function queryToListFilter(http:Request req) returns ListTasksRequest {
    ListTasksRequest filter = {};
    string? contextId = req.getQueryParamValue("contextId");
    if contextId is string {
        filter.contextId = contextId;
    }
    string? status = req.getQueryParamValue("status");
    if status is string {
        TaskState|error state = status.ensureType();
        if state is TaskState {
            filter.status = state;
        }
    }
    int? pageSize = queryInt(req, "pageSize");
    if pageSize is int {
        filter.pageSize = pageSize;
    }
    string? pageToken = req.getQueryParamValue("pageToken");
    if pageToken is string {
        filter.pageToken = pageToken;
    }
    int? historyLength = queryInt(req, "historyLength");
    if historyLength is int {
        filter.historyLength = historyLength;
    }
    string? after = req.getQueryParamValue("statusTimestampAfter");
    if after is string {
        filter.statusTimestampAfter = after;
    }
    string? includeArtifacts = req.getQueryParamValue("includeArtifacts");
    if includeArtifacts is string {
        filter.includeArtifacts = includeArtifacts == "true";
    }
    return filter;
}
