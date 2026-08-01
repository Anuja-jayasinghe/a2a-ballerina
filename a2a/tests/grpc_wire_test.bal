// Mandatory gate test: proves Part.data's anydata rewrite (Task 1's
// google_protobuf_Value -> anydata workaround) actually round-trips real
// data through the real generated protobuf marshaller/mock service on
// localhost:19198, not just in-memory value construction/comparison. See
// the design spec's Design decision 1 and this branch's Global Constraints:
// if any case here genuinely fails (not a test-authoring bug), stop and
// revisit the anydata rewrite before any further gRPC work.
import ballerina/a2a.grpcstub;
import ballerina/test;

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripJsonObject() returns error? {
    check assertPartDataRoundTrips({"key": "value", "nested": {"n": 1}});
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripJsonArray() returns error? {
    check assertPartDataRoundTrips([1, 2, "three", true, null]);
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripString() returns error? {
    check assertPartDataRoundTrips("plain string");
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripNumber() returns error? {
    check assertPartDataRoundTrips(42.5);
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripBoolean() returns error? {
    check assertPartDataRoundTrips(false);
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripNull() returns error? {
    check assertPartDataRoundTrips(null);
}

@test:Config {groups: ["grpc"]}
function testPartUnsetDataRoundTrips() returns error? {
    grpcstub:Part sentPart = {text: "hello, no data field"};
    grpcstub:SendMessageResponse echoed = check sendPartThroughGrpcMock(sentPart);
    grpcstub:Message? msg = echoed?.message;
    test:assertTrue(msg is grpcstub:Message, "expected a message back");
    grpcstub:Part[] parts = (<grpcstub:Message>msg).parts;
    test:assertEquals(parts.length(), 1);
    test:assertTrue(parts[0]?.data is (), "data must not be fabricated for a Part that never set it");
}

isolated function assertPartDataRoundTrips(anydata dataValue) returns error? {
    grpcstub:Part sentPart = {data: dataValue};
    grpcstub:SendMessageResponse echoed = check sendPartThroughGrpcMock(sentPart);
    grpcstub:Message? msg = echoed?.message;
    test:assertTrue(msg is grpcstub:Message, "expected a message back");
    grpcstub:Part[] parts = (<grpcstub:Message>msg).parts;
    test:assertEquals(parts.length(), 1);
    test:assertEquals(parts[0]?.data, dataValue, "Part.data did not round-trip byte-equal");
}

// Sends a single-Part Message through the real generated grpc:Client against
// the mock service (which echoes whatever it's asked to via
// setNextGrpcResponse -- scripted here to echo the same Part back inside a
// Message), exercising the real protobuf marshaller both directions. This is
// the one test in the whole gRPC binding that a pure unit-level mock cannot
// satisfy, per the design spec: the defect under test is in marshalling
// against the embedded descriptor, so the codec has to actually run.
isolated function sendPartThroughGrpcMock(grpcstub:Part part) returns grpcstub:SendMessageResponse|error {
    grpcstub:A2AServiceClient grpcClient = check new (getGrpcMockUrl());
    grpcstub:Message echoMessage = {message_id: "m1", role: grpcstub:ROLE_AGENT, parts: [part]};
    grpcstub:SendMessageResponse scripted = {message: echoMessage};
    setNextGrpcResponse(scripted);
    grpcstub:SendMessageRequest req = {message: {message_id: "m1", role: grpcstub:ROLE_USER, parts: [part]}};
    return grpcClient->SendMessage(req);
}
