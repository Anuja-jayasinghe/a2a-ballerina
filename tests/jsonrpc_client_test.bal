// JsonRpcClient: the transport-specific client for the JSON-RPC binding.
//
// These exercise the class directly, without going through Client, since
// the whole point of the type is that it can be constructed and used on
// its own. Coverage of the shared protocol logic (param building, v0.3
// translation, response decoding) lives with the operations it belongs to
// in client_test.bal — repeating it here would be testing operations.bal
// three times over rather than testing this class.

import ballerina/test;

@test:Config {}
function testJsonRpcClientConstructsFromUrl() returns error? {
    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {task: defaultTaskJson()}});
    JsonRpcClient c = check new (getServerBaseUrl());
    Task|Message result = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    test:assertTrue(result is Task, "a JsonRpcClient built from a URL should resolve the card and reach the mock");
}

@test:Config {}
function testJsonRpcClientConstructsFromAgentCard() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());
    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {task: defaultTaskJson()}});
    JsonRpcClient c = check new (card);
    Task|Message result = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    test:assertTrue(result is Task);
}

# The binding is fixed by the type, so a card offering no JSONRPC interface
# is unusable here — and must say so at construction rather than at the
# first call.
@test:Config {}
function testJsonRpcClientRejectsCardWithoutJsonRpcInterface() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://rest-only.example", protocolBinding: "HTTP+JSON"}
        ],
        skills: []
    };
    JsonRpcClient|error result = new (card);
    test:assertTrue(result is error,
            "a card declaring no JSONRPC interface must fail construction, not defer the failure to the first call");
}

@test:Config {}
function testJsonRpcClientAutoWiresTenantFromCard() returns error? {
    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {task: defaultTaskJson()}});
    JsonRpcClient c = check new (cardWithTenant("acme-corp"));
    Task|Message _ = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    json params = check getLastRequestBody().params;
    test:assertEquals(check params.tenant, "acme-corp");
}

@test:Config {}
function testJsonRpcClientExplicitTenantOverridesCard() returns error? {
    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {task: defaultTaskJson()}});
    JsonRpcClient c = check new (cardWithTenant("acme-corp"), tenant = "explicit");
    Task|Message _ = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    json params = check getLastRequestBody().params;
    test:assertEquals(check params.tenant, "explicit");
}

# Every operation must reach the wire under the right method name. This is
# the check that the class is wired up completely, rather than a per-
# operation behaviour test — that belongs with the shared logic.
@test:Config {}
function testJsonRpcClientSendsCorrectMethodNamePerOperation() returns error? {
    JsonRpcClient c = check new (getServerBaseUrl());

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: defaultTaskJson()});
    Task _ = check c->getTask("task-1");
    test:assertEquals(check getLastRequestBody().method, "GetTask");

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: defaultTaskJson()});
    Task _ = check c->cancelTask("task-1");
    test:assertEquals(check getLastRequestBody().method, "CancelTask");

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {tasks: [], nextPageToken: "", pageSize: 0, totalSize: 0}});
    ListTasksResult _ = check c->listTasks();
    test:assertEquals(check getLastRequestBody().method, "ListTasks");

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {url: "https://hook.example", taskId: "task-1"}});
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig({url: "https://hook.example", taskId: "task-1"});
    test:assertEquals(check getLastRequestBody().method, "CreateTaskPushNotificationConfig");

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {url: "https://hook.example", taskId: "task-1"}});
    TaskPushNotificationConfig _ = check c->getTaskPushNotificationConfig("task-1", "cfg-1");
    test:assertEquals(check getLastRequestBody().method, "GetTaskPushNotificationConfig");

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {configs: [], nextPageToken: ""}});
    ListTaskPushNotificationConfigsResult _ = check c->listTaskPushNotificationConfigs("task-1");
    test:assertEquals(check getLastRequestBody().method, "ListTaskPushNotificationConfigs");

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {}});
    check c->deleteTaskPushNotificationConfig("task-1", "cfg-1");
    test:assertEquals(check getLastRequestBody().method, "DeleteTaskPushNotificationConfig");
}

@test:Config {}
function testJsonRpcClientMapsErrorCodesToTypedErrors() returns error? {
    JsonRpcClient c = check new (getServerBaseUrl());
    setNextJsonResponse({jsonrpc: "2.0", id: "1", 'error: {code: -32001, message: "Task not found"}});
    Task|error result = c->getTask("missing");
    test:assertTrue(result is TaskNotFoundError,
            "the JSON-RPC error code table must map through this class exactly as it did before the split");
}

@test:Config {}
function testJsonRpcClientStreams() returns error? {
    JsonRpcClient c = check new (getServerBaseUrl());
    // taskJson/statusUpdateJson already return the complete JSON-RPC
    // envelope, so they are the SSE data payload as-is.
    setNextSseResponse([
        {data: taskJson("task-s1")},
        {data: statusUpdateJson("task-s1", "TASK_STATE_COMPLETED")}
    ]);
    stream<StreamResponse, error?> s = check c->sendStreamingMessage(
            {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    int count = 0;
    check from StreamResponse _ in s
        do {
            count += 1;
        };
    test:assertEquals(count, 2, "both scripted events should be delivered");
}

@test:Config {}
function testJsonRpcClientAdvertisesRequestedExtensions() returns error? {
    JsonRpcClient c = check new (getServerBaseUrl(), requestedExtensions = ["urn:example:ext-a"]);
    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {task: defaultTaskJson()}});
    Task|Message _ = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});

    test:assertEquals(getLastRequestHeaders()["a2a-extensions"], "urn:example:ext-a",
            "requested extensions must be advertised on the request");
}

# A v0.3 card must still work over JSON-RPC — this is the one binding with
# a v0.3 equivalent, and the compat layer keys off the dialect rather than
# the transport, so the split must not have disturbed it.
@test:Config {}
function testJsonRpcClientSpeaksV03Dialect() returns error? {
    AgentCard legacyCard = {
        name: "x", description: "x", version: "1.0.0",
        url: "http://localhost:19199",
        protocolVersion: "0.3.0",
        capabilities: {},
        skills: []
    };
    JsonRpcClient c = check new (legacyCard);
    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-1", kind: "task", status: {state: "completed"}}
    });
    Task _ = check c->getTask("task-1");
    test:assertEquals(check getLastRequestBody().method, "tasks/get",
            "a v0.3 card must produce v0.3 wire method names through this class");
}

# AgentClient is the point of the split: binding-agnostic code holds the
# interface, not a concrete class.
@test:Config {}
function testJsonRpcClientSatisfiesAgentClient() returns error? {
    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {task: defaultTaskJson()}});
    AgentClient c = check new JsonRpcClient(getServerBaseUrl());
    Task|Message result = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    test:assertTrue(result is Task, "a JsonRpcClient must be usable through the AgentClient interface type");
}
