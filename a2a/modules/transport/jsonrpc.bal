// JSON-RPC transport for the A2A client.
//
// Pure wire-format types only — no dependency on the root a2a module.
// This submodule must not import ballerina/a2a: the root module already
// imports ballerina/a2a.transport for these types, and Ballerina forbids
// cyclic module dependencies within a package. Error-code-to-A2AError
// mapping (toA2AError) and SSE decoding live in the root module instead
// (errors.bal and sse.bal) precisely because they need to construct root
// a2a types. See LEARNING_LOG.md.

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
