// RestClient: the transport-specific client for the HTTP+JSON binding.
//
// As with jsonrpc_client_test.bal, these exercise the class directly.
// What is distinctive about this binding is the marshaling — an operation
// becomes a method plus a templated path rather than an envelope — so the
// path/method assertions carry most of the weight here.

import ballerina/test;

@test:Config {}
function testRestClientConstructsFromUrl() returns error? {
    setNextRestResponse({task: defaultTaskJson()});
    RestClient c = check new (getServerBaseUrl());
    Task|Message result = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    test:assertTrue(result is Task, "a RestClient built from a URL should resolve the card and reach the mock");
}

@test:Config {}
function testRestClientConstructsFromAgentCard() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());
    setNextRestResponse({task: defaultTaskJson()});
    RestClient c = check new (card);
    Task|Message result = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    test:assertTrue(result is Task);
}

@test:Config {}
function testRestClientRejectsCardWithoutRestInterface() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc-only.example", protocolBinding: "JSONRPC"}
        ],
        skills: []
    };
    RestClient|error result = new (card);
    test:assertTrue(result is error,
            "a card declaring no HTTP+JSON interface must fail construction");
}

# v0.3 defines a REST binding, but this library does not implement it —
# v0.3 method names have no meaning as REST paths — so this must fail at
# construction rather than sending v0.3 method names down REST paths.
@test:Config {}
function testRestClientRejectsV03Card() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "0.3"}
        ],
        skills: []
    };
    RestClient|error result = new (card);
    test:assertTrue(result is VersionNotSupportedError,
            "a card resolving to v0.3 must be rejected with a typed error, since this library implements v0.3 over JSON-RPC only");
}

# The defining behaviour of this binding: each operation maps onto an HTTP
# method and a templated path, rather than a method name in a body.
@test:Config {}
function testRestClientMapsOperationsToMethodAndPath() returns error? {
    RestClient c = check new (getServerBaseUrl());

    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask("task-123");
    var req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks/task-123");

    setNextRestResponse(defaultTaskJson());
    Task _ = check c->cancelTask("task-123");
    req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/tasks/task-123:cancel");

    setNextRestResponse({task: defaultTaskJson()});
    Task|Message _ = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/message:send");

    setNextRestResponse({tasks: [], nextPageToken: "", pageSize: 0, totalSize: 0});
    ListTasksResult _ = check c->listTasks();
    req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks");

    setNextRestResponse({url: "https://hook.example", taskId: "task-1"});
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig({url: "https://hook.example", taskId: "task-1"});
    req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs");

    setNextRestResponse({url: "https://hook.example", taskId: "task-1"});
    TaskPushNotificationConfig _ = check c->getTaskPushNotificationConfig("task-1", "cfg-1");
    req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs/cfg-1");

    setNextRestResponse({}, hasResponseBody = false);
    check c->deleteTaskPushNotificationConfig("task-1", "cfg-1");
    req = getLastRestRequest();
    test:assertEquals(req.method, "DELETE");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs/cfg-1");
}

# A tenant becomes a path prefix on this binding, not just a body field.
@test:Config {}
function testRestClientPrefixesPathWithTenant() returns error? {
    RestClient c = check new (getServerBaseUrl(), tenant = "acme-corp");
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask("task-1");
    test:assertEquals(getLastRestRequest().path, "/acme-corp/tasks/task-1");
}

# REST cannot distinguish A2A errors by HTTP status alone — seven map onto
# 400 — so the ErrorInfo reason field carries the discrimination.
@test:Config {}
function testRestClientMapsErrorInfoReasonToTypedError() returns error? {
    RestClient c = check new (getServerBaseUrl());
    setNextRestResponse({
        'error: {
            code: 404,
            message: "Task not found",
            details: [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", reason: "TASK_NOT_FOUND"}]
        }
    }, statusCode = 404);
    Task|error result = c->getTask("missing");
    test:assertTrue(result is TaskNotFoundError,
            "the REST binding must discriminate A2A errors via ErrorInfo.reason");
}

@test:Config {}
function testRestClientStreams() returns error? {
    RestClient c = check new (getServerBaseUrl());
    setNextRestSseResponse([
        {data: string `{"task":{"id":"task-s1","status":{"state":"TASK_STATE_SUBMITTED"}}}`},
        {data: string `{"statusUpdate":{"taskId":"task-s1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}`}
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
function testRestClientSatisfiesAgentClient() returns error? {
    setNextRestResponse({task: defaultTaskJson()});
    AgentClient c = check new RestClient(getServerBaseUrl());
    Task|Message result = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    test:assertTrue(result is Task, "a RestClient must be usable through the AgentClient interface type");
}
