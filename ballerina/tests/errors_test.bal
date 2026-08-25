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

import ballerina/grpc;
import ballerina/test;

@test:Config {}
function testToA2AErrorMapsTaskNotFound() {
    A2AError err = toA2AError({code: -32001, message: "Task not found"});
    test:assertTrue(err is TaskNotFoundError, "should map to TaskNotFoundError");
}

@test:Config {}
function testToA2AErrorMapsTaskNotCancelable() {
    A2AError err = toA2AError({code: -32002, message: "Task not cancelable"});
    test:assertTrue(err is TaskNotCancelableError, "should map to TaskNotCancelableError");
}

@test:Config {}
function testToA2AErrorMapsPushNotificationNotSupported() {
    A2AError err = toA2AError({code: -32003, message: "Push notifications not supported"});
    test:assertTrue(err is PushNotificationNotSupportedError, "should map to PushNotificationNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsUnsupportedOperation() {
    A2AError err = toA2AError({code: -32004, message: "Unsupported operation"});
    test:assertTrue(err is UnsupportedOperationError, "should map to UnsupportedOperationError");
}

@test:Config {}
function testToA2AErrorMapsContentTypeNotSupported() {
    A2AError err = toA2AError({code: -32005, message: "Content type not supported"});
    test:assertTrue(err is ContentTypeNotSupportedError, "should map to ContentTypeNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsInvalidAgentResponse() {
    A2AError err = toA2AError({code: -32006, message: "Invalid agent response"});
    test:assertTrue(err is InvalidAgentResponseError, "should map to InvalidAgentResponseError");
}

@test:Config {}
function testToA2AErrorMapsExtendedAgentCardNotConfigured() {
    A2AError err = toA2AError({code: -32007, message: "Extended agent card not configured"});
    test:assertTrue(err is ExtendedAgentCardNotConfiguredError, "-32007 should map to its own dedicated type, per spec §5.4");
}

@test:Config {}
function testToA2AErrorMapsExtensionSupportRequired() {
    A2AError err = toA2AError({code: -32008, message: "Extension support required"});
    test:assertTrue(err is ExtensionSupportRequiredError, "-32008 should map to its own dedicated type, per spec §5.4");
}

@test:Config {}
function testToA2AErrorMapsVersionNotSupported() {
    A2AError err = toA2AError({code: -32009, message: "Version not supported"});
    test:assertTrue(err is VersionNotSupportedError, "should map to VersionNotSupportedError");
}

@test:Config {}
function testToA2AErrorMapsUnrecognizedCodeToInternalError() {
    A2AError err = toA2AError({code: -32600, message: "Invalid Request"});
    test:assertTrue(err is A2AInternalError, "unrecognised codes should map to A2AInternalError");
    A2AInternalError internalErr = <A2AInternalError>err;
    test:assertEquals(internalErr.detail().code, -32600);
}

# Regression test: toA2AError passes the JSON-RPC error message both as
# the error's own reason string and as A2AErrorDetail.message. Nothing
# previously verified these stay in sync — a caller reading err.message()
# (idiomatic Ballerina) must see the same text as err.detail().message.
@test:Config {}
function testToA2AErrorMessageMatchesDetailMessage() {
    A2AError err = toA2AError({code: -32001, message: "Task not found"});

    test:assertEquals(err.message(), "Task not found");
    test:assertEquals(err.detail().message, "Task not found");
    test:assertEquals(err.message(), err.detail().message);
}

# Regression test: A2AError's 8 subtypes must be nominally distinct
# (declared with `distinct`), not plain aliases for `error<A2AErrorDetail>`.
# Without `distinct`, every subtype is structurally identical and `is`
# checks between siblings are always true regardless of which error was
# actually constructed — this previously let every testToA2AErrorMaps*
# test above pass for the wrong reason.
@test:Config {}
function testA2AErrorSubtypesAreMutuallyDistinguishable() {
    A2AError taskNotFound = toA2AError({code: -32001, message: "Task not found"});

    test:assertTrue(taskNotFound is A2AError, "every subtype must still satisfy the common base type");
    test:assertTrue(taskNotFound is TaskNotFoundError, "should be its own mapped type");
    test:assertFalse(taskNotFound is PushNotificationNotSupportedError, "must not match an unrelated sibling type");
    test:assertFalse(taskNotFound is A2AInternalError, "must not match an unrelated sibling type");
}

@test:Config {}
function testToA2AErrorFromRestMapsTaskNotCancelableByReason() returns error? {
    json body = {
        "error": {
            "message": "task already completed",
            "details": [
                {"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_CANCELABLE", "metadata": {}}
            ]
        }
    };
    A2AError err = toA2AErrorFromRest(400, body);
    test:assertTrue(err is TaskNotCancelableError, "reason TASK_NOT_CANCELABLE must map to the typed TaskNotCancelableError, not fall back to a generic 400 error");
    test:assertEquals(err.detail().code, -32002, "the synthesized JSON-RPC code must match what the same error would carry over the JSON-RPC binding, so callers checking detail.code see identical behavior regardless of binding");
}

@test:Config {}
function testToA2AErrorFromRestDisambiguatesThreeDistinct400s() returns error? {
    json cancelBody = {"error": {"message": "m1", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_CANCELABLE"}]}};
    json unsupportedBody = {"error": {"message": "m2", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "UNSUPPORTED_OPERATION"}]}};
    json versionBody = {"error": {"message": "m3", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "VERSION_NOT_SUPPORTED"}]}};
    test:assertTrue(toA2AErrorFromRest(400, cancelBody) is TaskNotCancelableError);
    test:assertTrue(toA2AErrorFromRest(400, unsupportedBody) is UnsupportedOperationError);
    test:assertTrue(toA2AErrorFromRest(400, versionBody) is VersionNotSupportedError);
}

@test:Config {}
function testToA2AErrorFromRestMapsAllNineReasons() returns error? {
    // Keyed by the numeric JSON-RPC code each reason must map to — the
    // actual signal callers branch on — rather than a type-name string
    // discarded by the loop, so this genuinely fails if any reason falls
    // through to the wrong mapping or the generic fallback.
    map<int> reasonToExpectedCode = {
        "TASK_NOT_FOUND": -32001,
        "TASK_NOT_CANCELABLE": -32002,
        "PUSH_NOTIFICATION_NOT_SUPPORTED": -32003,
        "UNSUPPORTED_OPERATION": -32004,
        "CONTENT_TYPE_NOT_SUPPORTED": -32005,
        "INVALID_AGENT_RESPONSE": -32006,
        "EXTENDED_AGENT_CARD_NOT_CONFIGURED": -32007,
        "EXTENSION_SUPPORT_REQUIRED": -32008,
        "VERSION_NOT_SUPPORTED": -32009
    };
    foreach [string, int] [reason, expectedCode] in reasonToExpectedCode.entries() {
        json body = {"error": {"message": "m", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason}]}};
        A2AError err = toA2AErrorFromRest(400, body);
        test:assertEquals(err.detail().code, expectedCode, "reason " + reason + " should map to code " + expectedCode.toString());
    }
}

@test:Config {}
function testToA2AErrorFromRestFallsBackToStatusWhenNoErrorInfo() returns error? {
    A2AError notFound = toA2AErrorFromRest(404, ());
    test:assertTrue(notFound is TaskNotFoundError, "a bare 404 with no ErrorInfo reason should still map to TaskNotFoundError");
    A2AError serverErr = toA2AErrorFromRest(503, ());
    test:assertTrue(serverErr is A2AInternalError);
    test:assertEquals(serverErr.detail().code, -32603);
    A2AError otherErr = toA2AErrorFromRest(418, ());
    test:assertTrue(otherErr is A2AInternalError);
    test:assertEquals(otherErr.detail().code, 418, "an unmapped status with no ErrorInfo should preserve the raw HTTP status in detail.code, not synthesize a JSON-RPC code that doesn't apply");
}

@test:Config {}
function testToA2AErrorFromRestAttachesMetadataAsData() returns error? {
    json body = {
        "error": {
            "message": "not found",
            "details": [
                {"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND", "metadata": {"taskId": "abc-123"}}
            ]
        }
    };
    A2AError err = toA2AErrorFromRest(404, body);
    test:assertEquals(err.detail()?.data, {"taskId": "abc-123"});
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcNotFound() {
    grpc:Error err = error grpc:NotFoundError("task not found");
    A2AError mapped = toA2AErrorFromGrpc(err);
    test:assertTrue(mapped is TaskNotFoundError);
    test:assertEquals(mapped.detail()?.code, -32001);
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcInvalidArgument() {
    grpc:Error err = error grpc:InvalidArgumentError("bad params");
    A2AError mapped = toA2AErrorFromGrpc(err);
    test:assertTrue(mapped is A2AInternalError);
    test:assertEquals(mapped.detail()?.code, -32602);
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcFailedPreconditionIsLossyByDesign() {
    // Documents the known loss from design spec Design decision 6: five
    // distinct A2A errors collapse into UnsupportedOperationError because
    // ballerina/grpc exposes no status details to disambiguate them. Do
    // not "fix" this without also fixing the upstream ballerina/grpc gap
    // that makes it necessary — see the design doc.
    grpc:Error err = error grpc:FailedPreconditionError("task is not cancelable");
    A2AError mapped = toA2AErrorFromGrpc(err);
    test:assertTrue(mapped is UnsupportedOperationError);
    test:assertEquals(mapped.detail()?.code, -32004);
    test:assertEquals(mapped.message(), "task is not cancelable");
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcInternalErrorFamily() {
    A2AError mapped1 = toA2AErrorFromGrpc(error grpc:InternalError("x"));
    test:assertTrue(mapped1 is A2AInternalError);
    A2AError mapped2 = toA2AErrorFromGrpc(error grpc:DataLossError("x"));
    test:assertTrue(mapped2 is A2AInternalError);
    A2AError mapped3 = toA2AErrorFromGrpc(error grpc:UnKnownError("x"));
    test:assertTrue(mapped3 is A2AInternalError);
    A2AError mapped4 = toA2AErrorFromGrpc(error grpc:AbortedError("x"));
    test:assertTrue(mapped4 is A2AInternalError);
}

@test:Config {groups: ["grpc"]}
function testToA2AErrorFromGrpcTransportOnlyStatusesFallThrough() {
    A2AError mapped = toA2AErrorFromGrpc(error grpc:UnavailableError("connection refused"));
    test:assertTrue(mapped is A2AInternalError);
    test:assertEquals(mapped.message(), "connection refused");
    test:assertEquals(mapped.detail()?.code, -32603,
            "the fallback arm must populate code like every other arm of toA2AErrorFromGrpc, not leave it unset");
}
