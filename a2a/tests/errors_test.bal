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
function testToA2AErrorMapsExtendedAgentCardNotConfiguredToUnsupportedOperation() {
    A2AError err = toA2AError({code: -32007, message: "Extended agent card not configured"});
    test:assertTrue(err is UnsupportedOperationError, "-32007 should map to UnsupportedOperationError");
}

@test:Config {}
function testToA2AErrorMapsExtensionSupportRequiredToUnsupportedOperation() {
    A2AError err = toA2AError({code: -32008, message: "Extension support required"});
    test:assertTrue(err is UnsupportedOperationError, "-32008 should map to UnsupportedOperationError");
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
