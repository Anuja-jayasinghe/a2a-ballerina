// A2A error types.

import ballerina/a2a.transport;

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
