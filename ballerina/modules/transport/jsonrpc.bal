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

// JSON-RPC transport for the A2A client.
//
// Pure wire-format types only — no dependency on the root a2a module.
// This submodule must not import ballerina/a2a: the root module already
// imports ballerina/a2a.transport for these types, and Ballerina forbids
// cyclic module dependencies within a package. Error-code-to-A2AError
// mapping (toA2AError) and SSE decoding live in the root module instead
// (errors.bal and sse.bal) precisely because they need to construct root
// a2a types.

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
