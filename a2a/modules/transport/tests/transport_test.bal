import ballerina/test;
import ballerina/a2a;

@test:Config {}
function testJsonRpcRequestEncodesPerWireExample() returns error? {
    JsonRpcRequest req = {
        id: "550e8400-e29b-41d4-a716-446655440000",
        method: "message/send",
        params: {
            message: {
                messageId: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
                role: "ROLE_USER",
                parts: [{text: "What is the weather in Colombo?"}]
            },
            configuration: {
                acceptedOutputModes: ["text"],
                returnImmediately: false
            },
            tenant: "acme-corp"
        }
    };

    json expected = {
        jsonrpc: "2.0",
        id: "550e8400-e29b-41d4-a716-446655440000",
        method: "message/send",
        params: {
            message: {
                messageId: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
                role: "ROLE_USER",
                parts: [{text: "What is the weather in Colombo?"}]
            },
            configuration: {
                acceptedOutputModes: ["text"],
                returnImmediately: false
            },
            tenant: "acme-corp"
        }
    };

    test:assertEquals(req.toJson(), expected);
}

@test:Config {}
function testJsonRpcResponseDecodesSuccessExample() returns error? {
    json payload = {
        jsonrpc: "2.0",
        id: "550e8400-e29b-41d4-a716-446655440000",
        result: {
            id: "task-7f3a9b2c",
            contextId: "ctx-4e8d1a6f",
            status: {
                state: "TASK_STATE_COMPLETED",
                timestamp: "2026-07-20T14:32:11Z"
            },
            artifacts: [{
                artifactId: "art-9c2e",
                parts: [{text: "29 degrees Celsius and partly cloudy."}]
            }]
        }
    };

    JsonRpcResponse resp = check payload.cloneWithType(JsonRpcResponse);

    test:assertEquals(resp.id, "550e8400-e29b-41d4-a716-446655440000");
    test:assertTrue(resp?.'error is (), "error should be nil on a success response");

    json? result = resp?.result;
    test:assertTrue(result is json, "result should be present on a success response");
    a2a:Task task = check (<json>result).cloneWithType(a2a:Task);
    test:assertEquals(task.id, "task-7f3a9b2c");
    test:assertEquals(task.status.state, a2a:TASK_STATE_COMPLETED);
    test:assertEquals(task.artifacts.length(), 1);
}

@test:Config {}
function testJsonRpcResponseDecodesErrorExample() returns error? {
    json payload = {
        jsonrpc: "2.0",
        id: "550e8400-e29b-41d4-a716-446655440000",
        'error: {
            code: -32001,
            message: "Task not found",
            data: {taskId: "task-unknown"}
        }
    };

    JsonRpcResponse resp = check payload.cloneWithType(JsonRpcResponse);

    test:assertTrue(resp?.result is (), "result should be nil on an error response");

    JsonRpcError? rpcErr = resp?.'error;
    test:assertTrue(rpcErr is JsonRpcError, "error should be present on an error response");
    JsonRpcError err = <JsonRpcError>rpcErr;
    test:assertEquals(err.code, -32001);
    test:assertEquals(err.message, "Task not found");
}

@test:Config {}
function testToA2AErrorMapsTaskNotFound() {
    a2a:A2AError err = toA2AError({code: -32001, message: "Task not found"});
    test:assertTrue(err is a2a:TaskNotFoundError, "should map to TaskNotFoundError");
}

@test:Config {}
function testToA2AErrorMapsTaskNotCancelable() {
    a2a:A2AError err = toA2AError({code: -32002, message: "Task not cancelable"});
    test:assertTrue(err is a2a:TaskNotCancelableError, "should map to TaskNotCancelableError");
}

@test:Config {}
function testToA2AErrorMapsPushNotificationNotSupported() {
    a2a:A2AError err = toA2AError({code: -32003, message: "Push notifications not supported"});
    test:assertTrue(err is a2a:PushNotificationNotSupportedError, "should map to PushNotificationNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsUnsupportedOperation() {
    a2a:A2AError err = toA2AError({code: -32004, message: "Unsupported operation"});
    test:assertTrue(err is a2a:UnsupportedOperationError, "should map to UnsupportedOperationError");
}

@test:Config {}
function testToA2AErrorMapsContentTypeNotSupported() {
    a2a:A2AError err = toA2AError({code: -32005, message: "Content type not supported"});
    test:assertTrue(err is a2a:ContentTypeNotSupportedError, "should map to ContentTypeNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsInvalidAgentResponse() {
    a2a:A2AError err = toA2AError({code: -32006, message: "Invalid agent response"});
    test:assertTrue(err is a2a:InvalidAgentResponseError, "should map to InvalidAgentResponseError");
}

@test:Config {}
function testToA2AErrorMapsExtendedAgentCardNotConfiguredToUnsupportedOperation() {
    a2a:A2AError err = toA2AError({code: -32007, message: "Extended agent card not configured"});
    test:assertTrue(err is a2a:UnsupportedOperationError, "-32007 should map to UnsupportedOperationError");
}

@test:Config {}
function testToA2AErrorMapsExtensionSupportRequiredToUnsupportedOperation() {
    a2a:A2AError err = toA2AError({code: -32008, message: "Extension support required"});
    test:assertTrue(err is a2a:UnsupportedOperationError, "-32008 should map to UnsupportedOperationError");
}

@test:Config {}
function testToA2AErrorMapsVersionNotSupported() {
    a2a:A2AError err = toA2AError({code: -32009, message: "Version not supported"});
    test:assertTrue(err is a2a:VersionNotSupportedError, "should map to VersionNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsUnrecognizedCodeToInternalError() {
    a2a:A2AError err = toA2AError({code: -32600, message: "Invalid Request"});
    test:assertTrue(err is a2a:A2AInternalError, "unrecognised codes should map to A2AInternalError");
    a2a:A2AInternalError internalErr = <a2a:A2AInternalError>err;
    test:assertEquals(internalErr.detail().code, -32600);
}
