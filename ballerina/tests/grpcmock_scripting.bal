// Scriptable state for the gRPC mock service, mirroring tests/testutil.bal's
// HTTP mock pattern: tests call setNextGrpcResponse/setNextGrpcError before
// invoking a Client against getGrpcMockUrl(), and the mock service consults
// this state to decide what to return.
import ballerina/grpc;

isolated int grpcMockPort = GRPC_MOCK_PORT;

# Base URL for the scripted mock gRPC A2AService used by gRPC-binding Client
# tests, mirroring testutil.bal's getServerBaseUrl() for the HTTP mock.
#
# + return - the base URL to run gRPC tests against
public isolated function getGrpcMockUrl() returns string {
    lock {
        return string `http://localhost:${grpcMockPort}`;
    }
}

// Tagged union of every response shape a mock rpc might need to return.
// anydata (not a concrete grpcstub type) so this module doesn't have to
// import grpcstub — it's populated with grpcstub:* values by the test that
// calls setNextGrpcResponse, and consumed with a runtime type check on the
// mock service side, which does import grpcstub.
//
// response and err are bundled into a single record behind a single
// isolated variable -- as tests/testutil.bal's own HTTP mock does for the
// same reason -- since Ballerina's `lock` statement rejects touching more
// than one isolated variable in one block.
type GrpcMockScript record {|
    anydata? response = ();
    grpc:Error? err = ();
|};

isolated GrpcMockScript grpcScript = {};
isolated map<string|string[]> lastGrpcMetadata = {};

# Scripts the next gRPC rpc call to succeed with the given response value.
# The mock service ensureType()s this against whatever concrete grpcstub
# response type the invoked rpc expects.
#
# + value - the response value to return from the next rpc call
public isolated function setNextGrpcResponse(anydata value) {
    lock {
        grpcScript = {response: value.clone(), err: ()};
    }
}

# Scripts the next gRPC rpc call to fail with the given error.
#
# + err - the grpc:Error to return from the next rpc call
public isolated function setNextGrpcError(grpc:Error err) {
    lock {
        grpcScript = {response: (), err};
    }
}

# Returns the metadata (headers) of the last request the mock gRPC service
# received, so tests can assert on outbound gRPC metadata.
#
# + return - the last received request's metadata
public isolated function getLastGrpcMetadata() returns map<string|string[]> {
    lock {
        return lastGrpcMetadata.clone();
    }
}

isolated function takeNextGrpcResponse() returns anydata|error {
    lock {
        grpc:Error? err = grpcScript.err;
        if err is grpc:Error {
            return err;
        }
        anydata? resp = grpcScript.response;
        if resp is () {
            return error("grpcmock: no scripted response set for this call");
        }
        return resp.clone();
    }
}

isolated function recordGrpcMetadata(map<string|string[]> headers) {
    lock {
        lastGrpcMetadata = headers.clone();
    }
}
