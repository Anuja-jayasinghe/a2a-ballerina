// Scriptable mock A2AService gRPC implementation, mirroring the HTTP mock
// in tests/testutil.bal: every rpc records the caller's metadata and
// replays whatever the current test last scripted via
// setNextGrpcResponse/setNextGrpcError (see scripting.bal). Listens on
// localhost:19198, distinct from the HTTP mock's 19199.
//
// Every remote function takes the grpcstub:Context*Request variant of its
// request type (rather than the plain message type) so the mock can read
// the caller's gRPC metadata via req.headers -- confirmed against a
// scratch `bal grpc --mode service` run and
// ballerina/grpc's grpc-service-headers example, which shows headers
// arriving via a ContextXxx wrapper's `.headers` field rather than a
// second function parameter or a grpc:Caller.
//
// google.protobuf.Empty (DeleteTaskPushNotificationConfig's response) has no
// generated representation under the grpcstub: namespace with an "Empty"
// name -- it does exist as empty:ContextNil (via ballerina/protobuf.types.empty,
// used by the Context-variant remote function in a2a_pb.bal), but the client
// stub's non-Context DeleteTaskPushNotificationConfig remote function returns
// plain `grpc:Error?`, and the service-mode skeleton generated the same
// shape (`returns error?`), so this mock follows suit.
import ballerina/a2a.grpcstub;
import ballerina/grpc;

listener grpc:Listener grpcMockListener = new (GRPC_MOCK_PORT);

@grpc:Descriptor {value: grpcstub:A2A_DESC}
service "A2AService" on grpcMockListener {

    remote function SendMessage(grpcstub:ContextSendMessageRequest req)
            returns grpcstub:ContextSendMessageResponse|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        grpcstub:SendMessageResponse content = check resp.ensureType(grpcstub:SendMessageResponse);
        // Returning the Context-wrapped response (rather than the plain
        // SendMessageResponse the other mock methods return) lets tests
        // script response metadata via setNextGrpcResponseMetadata, per
        // ballerina/grpc's "use headers at the server side" pattern --
        // exercises the same result.headers path
        // captureGrantedExtensionsFromGrpc reads on a real gRPC server.
        return {content, headers: takeNextGrpcResponseMetadata()};
    }

    remote function SendStreamingMessage(grpcstub:ContextSendMessageRequest req)
            returns stream<grpcstub:StreamResponse, error?>|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        grpcstub:StreamResponse[] events = check resp.ensureType();
        return events.toStream();
    }

    remote function GetTask(grpcstub:ContextGetTaskRequest req)
            returns grpcstub:Task|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:Task);
    }

    remote function ListTasks(grpcstub:ContextListTasksRequest req)
            returns grpcstub:ListTasksResponse|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:ListTasksResponse);
    }

    remote function CancelTask(grpcstub:ContextCancelTaskRequest req)
            returns grpcstub:Task|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:Task);
    }

    remote function SubscribeToTask(grpcstub:ContextSubscribeToTaskRequest req)
            returns stream<grpcstub:StreamResponse, error?>|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        grpcstub:StreamResponse[] events = check resp.ensureType();
        return events.toStream();
    }

    remote function CreateTaskPushNotificationConfig(grpcstub:ContextTaskPushNotificationConfig req)
            returns grpcstub:TaskPushNotificationConfig|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:TaskPushNotificationConfig);
    }

    remote function GetTaskPushNotificationConfig(grpcstub:ContextGetTaskPushNotificationConfigRequest req)
            returns grpcstub:TaskPushNotificationConfig|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:TaskPushNotificationConfig);
    }

    remote function ListTaskPushNotificationConfigs(grpcstub:ContextListTaskPushNotificationConfigsRequest req)
            returns grpcstub:ListTaskPushNotificationConfigsResponse|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:ListTaskPushNotificationConfigsResponse);
    }

    remote function DeleteTaskPushNotificationConfig(grpcstub:ContextDeleteTaskPushNotificationConfigRequest req)
            returns error? {
        recordGrpcMetadata(req.headers);
        // google.protobuf.Empty carries no fields -- the scripted response
        // just needs to be *something* other than () (the "nothing
        // scripted" sentinel) to signal success; tests script this with
        // e.g. setNextGrpcResponse({}). A scripted grpc:Error still
        // short-circuits via takeNextGrpcResponse()'s `check`.
        _ = check takeNextGrpcResponse();
    }

    remote function GetExtendedAgentCard(grpcstub:ContextGetExtendedAgentCardRequest req)
            returns grpcstub:AgentCard|error {
        recordGrpcMetadata(req.headers);
        anydata resp = check takeNextGrpcResponse();
        return check resp.ensureType(grpcstub:AgentCard);
    }
}
