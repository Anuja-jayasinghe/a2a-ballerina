// A2A error types.

import ballerina/a2a.transport;
import ballerina/grpc;

# Detail attached to every A2AError.
public type A2AErrorDetail record {|
    # Originating JSON-RPC code, preserved for diagnostics
    int code?;
    # Human-readable error message
    string message?;
    # Structured error details from the server
    json data?;
    json...;
|};

# Base type for every A2A protocol error. Distinct so that `is A2AError`
# reliably matches any of its subtypes, and each subtype below is in turn
# distinguishable from its siblings via `is`.
public type A2AError distinct error<A2AErrorDetail>;

# Each specific error derives from A2AError — adding a new one later means
# adding one line here, nothing else in the codebase changes.
public type TaskNotFoundError distinct A2AError;

public type TaskNotCancelableError distinct A2AError;

public type UnsupportedOperationError distinct A2AError;

public type ContentTypeNotSupportedError distinct A2AError;

public type InvalidAgentResponseError distinct A2AError;

public type VersionNotSupportedError distinct A2AError;

public type PushNotificationNotSupportedError distinct A2AError;

public type ExtendedAgentCardNotConfiguredError distinct A2AError;

public type ExtensionSupportRequiredError distinct A2AError;

public type A2AInternalError distinct A2AError;

# Maps a JSON-RPC error code to its typed A2AError, per the error code
# table in design doc §4.1. Unrecognised codes map to A2AInternalError
# with the original code preserved in A2AErrorDetail.code.
#
# Lives here rather than in modules/transport/ because it constructs
# A2AError subtypes directly, and modules/transport/ cannot import the
# root a2a module without creating a cyclic module dependency (the root
# module already imports modules/transport/ for the envelope types).
#
# + err - the JSON-RPC error object received on the wire
# + return - the corresponding typed A2AError
isolated function toA2AError(transport:JsonRpcError err) returns A2AError {
    match err.code {
        -32001 => {
            return error TaskNotFoundError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32002 => {
            return error TaskNotCancelableError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32003 => {
            return error PushNotificationNotSupportedError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32004 => {
            return error UnsupportedOperationError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32005 => {
            return error ContentTypeNotSupportedError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32006 => {
            return error InvalidAgentResponseError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32007 => {
            return error ExtendedAgentCardNotConfiguredError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32008 => {
            return error ExtensionSupportRequiredError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32009 => {
            return error VersionNotSupportedError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        _ => {
            return error A2AInternalError(err.message, message = err.message, code = err.code, data = err?.data);
        }
    }
}

# Maps a REST binding error response onto the same A2AError hierarchy the
# JSON-RPC binding maps onto, so callers handle errors identically
# regardless of which binding their Client negotiated. HTTP status alone
# is not sufficient to disambiguate — seven distinct A2A errors all return
# 400 — so the discriminator is the `reason` field of a
# google.rpc.ErrorInfo entry inside the error body's `details` array, per
# the reference a2a-python SDK's REST error-parsing shape.
#
# + statusCode - the HTTP status code the response carried
# + body - the parsed JSON error body, if any (absent for e.g. a stream
#          drop with no body available)
# + return - the corresponding typed A2AError, with detail.code synthesized
#            to the equivalent JSON-RPC code so a caller checking
#            detail.code sees identical values regardless of binding
isolated function toA2AErrorFromRest(int statusCode, json? body) returns A2AError {
    string? reason = extractRestErrorReason(body);
    string message = extractRestErrorMessage(body) ?: string `REST request failed with HTTP ${statusCode}`;
    json? data = extractRestErrorMetadata(body);

    if reason is string {
        match reason {
            "TASK_NOT_FOUND" => {
                return error TaskNotFoundError(message, message = message, code = -32001, data = data);
            }
            "TASK_NOT_CANCELABLE" => {
                return error TaskNotCancelableError(message, message = message, code = -32002, data = data);
            }
            "PUSH_NOTIFICATION_NOT_SUPPORTED" => {
                return error PushNotificationNotSupportedError(message, message = message, code = -32003, data = data);
            }
            "UNSUPPORTED_OPERATION" => {
                return error UnsupportedOperationError(message, message = message, code = -32004, data = data);
            }
            "CONTENT_TYPE_NOT_SUPPORTED" => {
                return error ContentTypeNotSupportedError(message, message = message, code = -32005, data = data);
            }
            "INVALID_AGENT_RESPONSE" => {
                return error InvalidAgentResponseError(message, message = message, code = -32006, data = data);
            }
            "EXTENDED_AGENT_CARD_NOT_CONFIGURED" => {
                return error ExtendedAgentCardNotConfiguredError(message, message = message, code = -32007, data = data);
            }
            "EXTENSION_SUPPORT_REQUIRED" => {
                return error ExtensionSupportRequiredError(message, message = message, code = -32008, data = data);
            }
            "VERSION_NOT_SUPPORTED" => {
                return error VersionNotSupportedError(message, message = message, code = -32009, data = data);
            }
            "INVALID_PARAMS" => {
                return error A2AInternalError(message, message = message, code = -32602, data = data);
            }
            "INVALID_REQUEST" => {
                return error A2AInternalError(message, message = message, code = -32600, data = data);
            }
            "METHOD_NOT_FOUND" => {
                return error A2AInternalError(message, message = message, code = -32601, data = data);
            }
            "INTERNAL_ERROR" => {
                return error A2AInternalError(message, message = message, code = -32603, data = data);
            }
        }
    }

    // No usable ErrorInfo reason — fall back on status code alone.
    if statusCode == 404 {
        return error TaskNotFoundError(message, message = message, code = -32001, data = data);
    }
    if statusCode >= 500 {
        return error A2AInternalError(message, message = message, code = -32603, data = data);
    }
    return error A2AInternalError(message, message = message, code = statusCode, data = data);
}

# Scans a REST error body's error.details array for the first
# google.rpc.ErrorInfo entry and returns its reason string, or () if the
# body has no usable ErrorInfo entry. json field access with an
# "@"-prefixed key ("@type") isn't valid dot-syntax, so this reads through
# a map<json> bracket index instead.
isolated function extractRestErrorDetail(json? body) returns map<json>? {
    if body is () {
        return ();
    }
    map<json>|error bodyMap = body.ensureType();
    if bodyMap is error {
        return ();
    }
    json? errObj = bodyMap["error"];
    if errObj is () {
        return ();
    }
    map<json>|error errMap = errObj.ensureType();
    if errMap is error {
        return ();
    }
    json? detailsJson = errMap["details"];
    if !(detailsJson is json[]) {
        return ();
    }
    foreach json detail in detailsJson {
        map<json>|error detailMap = detail.ensureType();
        if detailMap is map<json> {
            json? typeVal = detailMap["@type"];
            if typeVal is string && typeVal == "type.googleapis.com/google.rpc.ErrorInfo" {
                return detailMap;
            }
        }
    }
    return ();
}

isolated function extractRestErrorReason(json? body) returns string? {
    map<json>? detailMap = extractRestErrorDetail(body);
    if detailMap is () {
        return ();
    }
    json? reasonVal = detailMap["reason"];
    return reasonVal is string ? reasonVal : ();
}

isolated function extractRestErrorMessage(json? body) returns string? {
    if body is () {
        return ();
    }
    map<json>|error bodyMap = body.ensureType();
    if bodyMap is error {
        return ();
    }
    json? errObj = bodyMap["error"];
    if errObj is () {
        return ();
    }
    map<json>|error errMap = errObj.ensureType();
    if errMap is error {
        return ();
    }
    json? msg = errMap["message"];
    return msg is string ? msg : ();
}

isolated function extractRestErrorMetadata(json? body) returns json? {
    map<json>? detailMap = extractRestErrorDetail(body);
    return detailMap is () ? () : detailMap["metadata"];
}

# Maps a gRPC transport error onto the same A2AError hierarchy the
# JSON-RPC and REST bindings map onto. Status-code granularity only —
# ballerina/grpc:1.14.7 exposes no status details or trailing metadata
# (grpc:Error is a bare `distinct error` with no detail record), so five
# A2A errors that all share FAILED_PRECONDITION cannot be disambiguated
# here the way toA2AErrorFromRest disambiguates via
# google.rpc.ErrorInfo.reason. See design spec Design decision 6 for the
# full resolution-order rationale and the two out-of-scope ways to close
# this gap later (ballerina/grpc exposing status details; matching on
# status-message text, rejected as unreliable).
#
# + err - the gRPC transport error received from a grpcstub client call
# + return - the corresponding typed A2AError
isolated function toA2AErrorFromGrpc(grpc:Error err) returns A2AError {
    string message = err.message();
    if err is grpc:NotFoundError {
        return error TaskNotFoundError(message, message = message, code = -32001);
    }
    if err is grpc:InvalidArgumentError {
        return error A2AInternalError(message, message = message, code = -32602);
    }
    if err is grpc:FailedPreconditionError {
        return error UnsupportedOperationError(message, message = message, code = -32004);
    }
    if err is grpc:InternalError || err is grpc:DataLossError
            || err is grpc:UnKnownError || err is grpc:AbortedError {
        return error A2AInternalError(message, message = message, code = -32603);
    }
    // Transport-only statuses with no A2A error counterpart (e.g.
    // UNAVAILABLE, DEADLINE_EXCEEDED) - still A2AInternalError, and now
    // carrying the same -32603 code the "Internal" bucket above uses, so
    // detail().code is reliably populated on every arm of this function
    // rather than only most of them.
    return error A2AInternalError(message, message = message, code = -32603);
}
