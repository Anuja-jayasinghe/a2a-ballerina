// The gRPC binding's streaming adapter — the per-element analogue of
// sse.bal's A2AStreamGenerator for the JSON-RPC/REST bindings. Simpler at
// the stream layer than either (gRPC has no envelope and no mid-stream
// "error"-named frame to special-case — a transport error surfaces
// directly as a grpc:Error from upstream.next()) and more involved at the
// type layer (every element needs decodeGrpcStreamResponse). See design
// spec Design decision 4.
import ballerina/a2a.grpcstub;
import ballerina/grpc;

class GrpcStreamAdapter {
    private stream<grpcstub:StreamResponse, error?> upstream;
    private boolean closed = false;

    isolated function init(stream<grpcstub:StreamResponse, error?> upstream) {
        self.upstream = upstream;
    }

    public isolated function next() returns record {|StreamResponse value;|}|error? {
        if self.closed {
            return ();
        }
        record {|grpcstub:StreamResponse value;|}|error? chunk = self.upstream.next();
        if chunk is () {
            self.closed = true;
            return ();
        }
        if chunk is error {
            self.closed = true;
            if chunk is grpc:Error {
                return toA2AErrorFromGrpc(chunk);
            }
            return chunk;
        }
        StreamResponse|error decoded = decodeGrpcStreamResponse(chunk.value);
        if decoded is error {
            self.closed = true;
            return decoded;
        }
        if isTerminalEvent(decoded) {
            self.closed = true;
        }
        return {value: decoded};
    }

    public isolated function close() returns error? {
        self.closed = true;
        return self.upstream.close();
    }
}
