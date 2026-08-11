// Equivalence tests proving the JSON-RPC and gRPC bindings return
// identical results for the same logical operation, using real Client
// instances against both the HTTP mock (tests/testutil.bal) and the gRPC
// mock (tests/grpcmock_scripting.bal) -- not mocked comparisons.
import ballerina/a2a.grpcstub;
import ballerina/grpc;
import ballerina/test;

@test:Config {groups: ["grpc"]}
function testJsonRpcAndGrpcReturnIdenticalSendMessageResult() returns error? {
    setNextJsonResponse({"jsonrpc": "2.0", "id": "x", "result": {"task": {"id": "t1", "status": {"state": "TASK_STATE_COMPLETED"}}}});
    Client jsonRpcClient = check new (getServerBaseUrl());
    Task|Message jsonRpcResult = check jsonRpcClient->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});

    setNextGrpcResponse(<grpcstub:SendMessageResponse>{task: {id: "t1", status: {state: grpcstub:TASK_STATE_COMPLETED}}});
    Client grpcClient = check new (getServerBaseUrl(), binding = "GRPC");
    Task|Message grpcResult = check grpcClient->sendMessage({messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]});

    test:assertTrue(jsonRpcResult is Task && grpcResult is Task);
    if jsonRpcResult is Task && grpcResult is Task {
        test:assertEquals(jsonRpcResult.id, grpcResult.id);
        test:assertEquals(jsonRpcResult.status.state, grpcResult.status.state);
    }
}

@test:Config {groups: ["grpc"]}
function testJsonRpcAndGrpcReturnIdenticalNotFoundErrorType() returns error? {
    setNextJsonResponse({"jsonrpc": "2.0", "id": "x", "error": {"code": -32001, "message": "not found"}});
    Client jsonRpcClient = check new (getServerBaseUrl());
    Task|error jsonRpcResult = jsonRpcClient->getTask("missing");

    setNextGrpcError(error grpc:NotFoundError("not found"));
    Client grpcClient = check new (getServerBaseUrl(), binding = "GRPC");
    Task|error grpcResult = grpcClient->getTask("missing");

    // Per design spec Design decision 6, the error half of this
    // equivalence assertion is deliberately narrowed to success paths and
    // NOT_FOUND only -- five other A2A errors collapse into
    // UnsupportedOperationError over gRPC because ballerina/grpc exposes
    // no status details, so e.g. TaskNotCancelableError parity cannot
    // hold and is not asserted here.
    test:assertTrue(jsonRpcResult is TaskNotFoundError);
    test:assertTrue(grpcResult is TaskNotFoundError);
}
