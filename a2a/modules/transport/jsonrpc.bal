// JSON-RPC transport for the A2A client.

import ballerina/a2a;

# The outbound JSON-RPC 2.0 request envelope.
public type JsonRpcRequest record {|
    # Protocol identifier, always "2.0"
    string jsonrpc = "2.0";
    # Correlates this request with its response
    string id;
    # A2A operation name, e.g. "message/send"
    string method;
    # A2A operation parameters
    map<json> params;
|};

# One JSON-RPC 2.0 error object.
public type JsonRpcError record {|
    # JSON-RPC/A2A error code
    int code;
    # Human-readable error message
    string message;
    # Structured error details from the server
    json data?;
|};

# The inbound JSON-RPC 2.0 response envelope.
public type JsonRpcResponse record {|
    # Protocol identifier, always "2.0"
    string jsonrpc;
    # Correlates this response with its request
    string id;
    # Present on success
    json result?;
    # Present on failure
    JsonRpcError 'error?;
|};

# Maps a JSON-RPC error code to its typed A2AError, per the error code
# table in design doc §4.1. Unrecognised codes map to A2AInternalError
# with the original code preserved in A2AErrorDetail.code.
#
# + err - the JSON-RPC error object received on the wire
# + return - the corresponding typed A2AError
public isolated function toA2AError(JsonRpcError err) returns a2a:A2AError {
    match err.code {
        -32001 => {
            return error a2a:TaskNotFoundError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32002 => {
            return error a2a:TaskNotCancelableError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32003 => {
            return error a2a:PushNotificationNotSupportedError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32004 => {
            return error a2a:UnsupportedOperationError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32005 => {
            return error a2a:ContentTypeNotSupportedError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32006 => {
            return error a2a:InvalidAgentResponseError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32007 => {
            // ExtendedAgentCardNotConfiguredError has no dedicated Ballerina type
            return error a2a:UnsupportedOperationError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32008 => {
            // ExtensionSupportRequiredError has no dedicated Ballerina type
            return error a2a:UnsupportedOperationError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        -32009 => {
            return error a2a:VersionNotSupportedError(err.message, message = err.message, code = err.code, data = err?.data);
        }
        _ => {
            return error a2a:A2AInternalError(err.message, message = err.message, code = err.code, data = err?.data);
        }
    }
}
