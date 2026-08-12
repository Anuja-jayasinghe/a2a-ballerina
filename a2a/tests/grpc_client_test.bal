// GrpcClient: the transport-specific client for the gRPC binding.
//
// Constructed from getServerBaseUrl() throughout: the Agent Card is always
// fetched over HTTP from the well-known endpoint (that is what discovery
// is), and the mock card's GRPC interface points at the separate gRPC mock
// port, which is where the operations then go. The gRPC mock serves no
// well-known endpoint of its own, so a URL aimed straight at it could not
// resolve a card.

import ballerina/grpc;
import ballerina/test;

import ballerina/a2a.grpcstub;

# A scripted gRPC Task response. Built as a typed grpcstub value rather
# than a plain map: the grpc runtime marshals by the value's real runtime
# type identity, so an untyped literal would not go onto the wire
# correctly.
#
# + id - the task identifier to stamp on the response
# + return - the scripted response value
isolated function grpcTaskResponse(string id) returns grpcstub:Task =>
    {id, status: {state: grpcstub:TASK_STATE_COMPLETED}};

@test:Config {groups: ["grpc"]}
function testGrpcClientConstructsFromUrl() returns error? {
    setNextGrpcResponse(grpcTaskResponse("task-1"));
    GrpcClient c = check new (getServerBaseUrl());
    Task t = check c->getTask("task-1");
    test:assertEquals(t.id, "task-1");
}

@test:Config {groups: ["grpc"]}
function testGrpcClientConstructsFromAgentCard() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());
    setNextGrpcResponse(grpcTaskResponse("task-1"));
    GrpcClient c = check new (card);
    Task t = check c->getTask("task-1");
    test:assertEquals(t.id, "task-1");
}

@test:Config {groups: ["grpc"]}
function testGrpcClientRejectsCardWithoutGrpcInterface() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc-only.example", protocolBinding: "JSONRPC"}
        ],
        skills: []
    };
    GrpcClient|error result = new (card);
    test:assertTrue(result is error,
            "a card declaring no GRPC interface must fail construction");
}

# v0.3 defines a gRPC binding, but this library translates the JSON-RPC
# dialect only, so this must fail fast rather than marshalling v0.3 JSON
# shapes through a stub generated from v1.0's proto. See issue #31.
@test:Config {groups: ["grpc"]}
function testGrpcClientRejectsV03Card() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: getGrpcMockUrl(), protocolBinding: "GRPC", protocolVersion: "0.3"}
        ],
        skills: []
    };
    GrpcClient|error result = new (card);
    test:assertTrue(result is VersionNotSupportedError,
            "a card resolving to v0.3 must be rejected with a typed error, since this library implements v0.3 over JSON-RPC only");
}

@test:Config {groups: ["grpc"]}
function testGrpcClientUnaryOperationsRoundTrip() returns error? {
    GrpcClient c = check new (getServerBaseUrl());

    setNextGrpcResponse(grpcTaskResponse("task-1"));
    Task got = check c->getTask("task-1");
    test:assertEquals(got.id, "task-1");

    setNextGrpcResponse(grpcTaskResponse("task-1"));
    Task cancelled = check c->cancelTask("task-1");
    test:assertEquals(cancelled.id, "task-1");
}

# gRPC carries no structured error details this library can read, so
# mapping is by status code alone — deliberately coarser than the other
# two bindings.
@test:Config {groups: ["grpc"]}
function testGrpcClientMapsStatusCodeToTypedError() returns error? {
    GrpcClient c = check new (getServerBaseUrl());
    setNextGrpcError(error grpc:NotFoundError("no such task"));
    Task|error result = c->getTask("missing");
    test:assertTrue(result is TaskNotFoundError,
            "a gRPC NOT_FOUND status must map onto TaskNotFoundError");
}

# Metadata, not HTTP headers: this binding reads granted extensions off the
# call's response metadata.
#
# Uses sendMessage rather than getTask because only the mock's SendMessage
# returns a Context-wrapped response; the other rpcs return a plain value
# and so have no way to carry response metadata back. The key is scripted
# lowercase to match real HTTP/2 wire casing (RFC 7540 section 8.1.2),
# which is what the client's case-insensitive lookup has to cope with.
@test:Config {groups: ["grpc"]}
function testGrpcClientCapturesGrantedExtensionsFromMetadata() returns error? {
    GrpcClient c = check new (getServerBaseUrl(), requestedExtensions = ["urn:example:ext-a"]);
    setNextGrpcResponseMetadata({"a2a-extensions": "urn:example:ext-a"});
    setNextGrpcResponse(<grpcstub:SendMessageResponse>{
        task: {id: "t1", status: {state: grpcstub:TASK_STATE_COMPLETED}}
    });
    Task|Message _ = check c->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});

    test:assertEquals(c.lastGrantedExtensions(), ["urn:example:ext-a"],
            "granted extensions must be read from gRPC response metadata");
    map<string|string[]> sent = getLastGrpcMetadata();
    test:assertTrue(sent.hasKey("a2a-extensions"),
            "requested extensions must be advertised as outbound metadata (lowercased on the wire)");
}

@test:Config {groups: ["grpc"]}
function testGrpcClientSatisfiesAgentClient() returns error? {
    setNextGrpcResponse(grpcTaskResponse("task-1"));
    AgentClient c = check new GrpcClient(getServerBaseUrl());
    Task t = check c->getTask("task-1");
    test:assertEquals(t.id, "task-1", "a GrpcClient must be usable through the AgentClient interface type");
}
