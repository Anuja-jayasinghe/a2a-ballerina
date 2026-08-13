// Whole-client integration: the common Client end to end, across all
// three bindings.
//
// The per-binding classes are tested individually in jsonrpc_client_test,
// rest_client_test, and grpc_client_test. What is only testable here is
// the layer above them: that Client picks the binding the card asks for,
// and that each of its eleven delegations is wired to the operation it
// claims to be.

import ballerina/test;

import ballerina/a2a.grpcstub;

# A card declaring exactly one interface, for pinning which binding Client
# selects. Points at whichever mock serves that binding.
#
# + binding - the single protocolBinding to declare
# + return - a minimal card offering only that binding
isolated function cardForBinding(TransportBinding binding) returns AgentCard => {
    name: "n", description: "d", version: "1.0.0",
    capabilities: {streaming: true, pushNotifications: true, extendedAgentCard: true},
    supportedInterfaces: [
        {
            url: binding == "GRPC" ? getGrpcMockUrl() : getServerBaseUrl(),
            protocolBinding: binding
        }
    ],
    skills: []
};

// ---- binding selection reaches the right transport --------------------

@test:Config {}
function testClientSelectsJsonRpcAndSpeaksIt() returns error? {
    Client c = check new (cardForBinding("JSONRPC"));
    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: defaultTaskJson()});
    Task _ = check c->getTask("task-1");
    test:assertEquals(check getLastRequestBody().method, "GetTask",
            "a JSONRPC card must produce a client that posts a JSON-RPC envelope");
}

@test:Config {}
function testClientSelectsRestAndSpeaksIt() returns error? {
    Client c = check new (cardForBinding("HTTP+JSON"));
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask("task-1");
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1",
            "an HTTP+JSON card must produce a client that uses REST paths");
}

@test:Config {groups: ["grpc"]}
function testClientSelectsGrpcAndSpeaksIt() returns error? {
    Client c = check new (cardForBinding("GRPC"));
    setNextGrpcResponse(<grpcstub:Task>{id: "task-1", status: {state: grpcstub:TASK_STATE_COMPLETED}});
    Task t = check c->getTask("task-1");
    test:assertEquals(t.id, "task-1");
    test:assertTrue(getLastGrpcMetadata().hasKey("a2a-version"),
            "a GRPC card must produce a client that calls over gRPC, carrying A2A-Version as metadata");
}

// ---- every delegation is wired to the operation it claims to be -------

# Client has eleven hand-written one-line delegations. A copy-paste slip -
# getTask forwarding to cancelTask, say - would compile, return the right
# type, and pass every per-binding test, because the concrete clients are
# all correct. Only asserting the method name each Client call actually
# puts on the wire catches it.
@test:Config {}
function testClientDelegatesEachOperationToItsOwnMethod() returns error? {
    Client c = check new (cardForBinding("JSONRPC"));

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {task: defaultTaskJson()}});
    Task|Message _ = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    test:assertEquals(check getLastRequestBody().method, "SendMessage");

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
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig(
            {url: "https://hook.example", taskId: "task-1"});
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

    setNextJsonResponse({jsonrpc: "2.0", id: "1",
        result: {name: "Extended", description: "d", version: "1.0.0", capabilities: {}, skills: []}});
    AgentCard _ = check c->getExtendedAgentCard();
    test:assertEquals(check getLastRequestBody().method, "GetExtendedAgentCard");
}

# The two streaming operations, which delegate a stream rather than a
# value and so cannot be covered by the unary sweep above.
@test:Config {}
function testClientDelegatesStreamingOperations() returns error? {
    Client c = check new (cardForBinding("JSONRPC"));

    setNextSseResponse([
        {data: taskJson("task-s1")},
        {data: statusUpdateJson("task-s1", "TASK_STATE_COMPLETED")}
    ]);
    stream<StreamResponse, error?> sent = check c->sendStreamingMessage(
            {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});
    int sentCount = 0;
    check from StreamResponse _ in sent
        do {
            sentCount += 1;
        };
    test:assertEquals(sentCount, 2);
    test:assertEquals(check getLastRequestBody().method, "SendStreamingMessage");

    setNextSseResponse([
        {data: statusUpdateJson("task-s2", "TASK_STATE_COMPLETED")}
    ]);
    stream<StreamResponse, error?> subscribed = check c->subscribeToTask("task-s2");
    int subCount = 0;
    check from StreamResponse _ in subscribed
        do {
            subCount += 1;
        };
    test:assertEquals(subCount, 1);
    test:assertEquals(check getLastRequestBody().method, "SubscribeToTask");
}

// ---- delegation carries arguments and state faithfully ---------------

# Arguments have to survive the hop. A delegation that dropped or reordered
# a parameter would still compile.
@test:Config {}
function testClientDelegationPassesArgumentsThrough() returns error? {
    Client c = check new (cardForBinding("JSONRPC"));

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: defaultTaskJson()});
    Task _ = check c->getTask("task-42", historyLength = 7, tenant = "per-call-tenant");
    json params = check getLastRequestBody().params;
    test:assertEquals(check params.id, "task-42");
    test:assertEquals(check params.historyLength, 7);
    test:assertEquals(check params.tenant, "per-call-tenant",
            "a per-call tenant override must survive the delegation");

    setNextJsonResponse({jsonrpc: "2.0", id: "1", result: {configs: [], nextPageToken: ""}});
    ListTaskPushNotificationConfigsResult _ = check c->listTaskPushNotificationConfigs(
            "task-1", pageSize = 5, pageToken = "cursor-abc");
    params = check getLastRequestBody().params;
    test:assertEquals(check params.pageSize, 5);
    test:assertEquals(check params.pageToken, "cursor-abc");
}

# The card handed to Client is passed straight to the delegate, so a
# construction from an already-resolved card must not fetch it again.
@test:Config {}
function testClientFromCardDoesNotRefetchIt() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());

    // Make any further well-known fetch fail loudly. If construction
    // re-resolved the card it would surface this 500 as a construction
    // error rather than succeeding.
    setWellKnownOverride({message: "well-known must not be fetched again"}, 500);
    Client|error c = new (card);
    setWellKnownOverride(());

    test:assertTrue(c is Client,
            "a Client built from a resolved card must hand that card to its delegate rather than fetching a second time");
}

# Binding-agnostic code holds AgentClient and is handed any of the four.
@test:Config {}
function testAgentClientInterfaceAcceptsEveryImplementation() returns error? {
    AgentClient viaCommon = check new Client(cardForBinding("JSONRPC"));
    AgentClient viaJsonRpc = check new JsonRpcClient(getServerBaseUrl());
    AgentClient viaRest = check new RestClient(getServerBaseUrl());

    foreach AgentClient _ in [viaCommon, viaJsonRpc, viaRest] {
        // Holding them in one array is itself the assertion: it only
        // compiles because all three satisfy the interface type.
    }
    test:assertTrue(true);
}

// ---- selection skips interfaces no client could serve ----------------

# This library implements v0.3 over JSON-RPC only, so a v0.3 HTTP+JSON entry is one the
# matching client rejects at construction. Listing it first must not sink
# the whole card when a serviceable interface follows.
#
# Before this was handled, such a card failed outright with "A2A protocol
# does not implement v0.3 over REST/HTTP+JSON" even though its JSON-RPC
# interface was perfectly usable.
@test:Config {}
function testClientSkipsV03RestInterfaceAndFallsToJsonRpc() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "0.3"},
            {url: "http://localhost:19199", protocolBinding: "JSONRPC", protocolVersion: "0.3"}
        ],
        skills: []
    };
    Client c = check new (card);

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-1", kind: "task", status: {state: "completed"}}
    });
    Task _ = check c->getTask("task-1");
    test:assertEquals(check getLastRequestBody().method, "tasks/get",
            "the v0.3 JSONRPC interface behind the unusable REST one must be selected, and speak v0.3");
}

# The same rule for gRPC, which likewise has no v0.3 form.
@test:Config {}
function testClientSkipsV03GrpcInterfaceAndFallsToJsonRpc() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: getGrpcMockUrl(), protocolBinding: "GRPC", protocolVersion: "0.3"},
            {url: "http://localhost:19199", protocolBinding: "JSONRPC", protocolVersion: "0.3"}
        ],
        skills: []
    };
    Client c = check new (card);

    setNextJsonResponse({
        jsonrpc: "2.0", id: "1",
        result: {id: "task-1", kind: "task", status: {state: "completed"}}
    });
    Task _ = check c->getTask("task-1");
    test:assertEquals(check getLastRequestBody().method, "tasks/get");
}

# A card offering nothing serviceable at all must still fail, rather than
# the skipping rule quietly swallowing every entry.
@test:Config {}
function testClientErrorsWhenEveryInterfaceIsUnserviceable() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "0.3"},
            {url: getGrpcMockUrl(), protocolBinding: "GRPC", protocolVersion: "0.3"}
        ],
        skills: []
    };
    Client|error result = new (card);
    test:assertTrue(result is error,
            "a card whose every interface is an unserviceable v0.3 combination must fail construction");
}

# The skipping rule must not change which binding a healthy card selects.
@test:Config {}
function testClientStillTakesFirstServiceableEntry() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"},
            {url: "http://localhost:19199", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: []
    };
    Client c = check new (card);
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask("task-1");
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1",
            "a serviceable v1.0 REST entry listed first must still win");
}
