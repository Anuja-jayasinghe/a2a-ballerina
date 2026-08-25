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

import ballerina/test;

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
    test:assertTrue(resp?.result is json, "result should be present on a success response");
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
