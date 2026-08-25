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

// Mandatory gate test: proves Part.data actually round-trips real data
// through the real generated protobuf marshaller/mock service on
// localhost:19198, not just in-memory value construction/comparison. See
// the design spec's Design decision 1 and this branch's Global Constraints:
// if any case here genuinely fails (not a test-authoring bug), stop and
// revisit the stub's Part.data handling before any further gRPC work.
//
// These cases originally failed at runtime with
//   "Failed to frame message: Cannot invoke
//    Descriptors$FileDescriptor.findMessageTypeByName(String) because
//    fileDescriptor is null"
// because a2a.proto's google/protobuf/struct.proto dependency was never
// handed to grpc:Client.initStub, so google.protobuf.Value resolved to a
// protobuf *placeholder* descriptor that ballerina/grpc's
// StandardDescriptorBuilder has no message-name entry to rescue it with.
// Fixed by grpcstub's A2A_DESCRIPTOR_MAP -- see
// a2a/modules/grpcstub/wellknown_desc.bal for the full analysis.
import ballerina/a2a.grpcstub;
import ballerina/test;

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripJsonObject() returns error? {
    // The `1` is sent as a Ballerina int and comes back as a float. That is
    // google.protobuf.Value's own definition, not a defect in this binding:
    // its `kind` oneof has exactly one numeric arm, `double number_value`,
    // so no protobuf implementation of any language can carry the
    // int-vs-float distinction across a `Value`. Pinned explicitly by
    // testPartDataIntegersWidenToFloatOverGrpc below.
    check assertPartDataRoundTrips({"key": "value", "nested": {"n": 1}},
            {"key": "value", "nested": {"n": 1.0}});
}

@test:Config {groups: ["grpc"]}
function testPartDataRoundTripJsonArray() returns error? {
    // Ints widen to floats -- see the note in testPartDataRoundTripJsonObject.
    check assertPartDataRoundTrips([1, 2, "three", true, null],
            [1.0, 2.0, "three", true, null]);
}

// Pins the one documented fidelity loss on Part.data over gRPC, so that a
// future change either preserves it deliberately or fails here rather than
// silently altering payloads. google.protobuf.Value models every JSON number
// as a `double`; a Ballerina int therefore arrives back as a float of equal
// value. The JSON-RPC and HTTP+JSON bindings do NOT do this, so this is a
// real cross-binding behavioural difference -- see the gRPC transport
// binding design doc, "Known limitation 3".
@test:Config {groups: ["grpc"]}
function testPartDataIntegersWidenToFloatOverGrpc() returns error? {
    grpcstub:Part sentPart = {data: 7};
    grpcstub:SendMessageResponse echoed = check sendPartThroughGrpcMock(sentPart);
    anydata roundTripped = (<grpcstub:Message>echoed?.message).parts[0]?.data;
    test:assertTrue(roundTripped is float,
            "google.protobuf.Value has no integer kind; an int must come back as a float");
    test:assertEquals(roundTripped, 7.0, "the numeric value itself must be preserved exactly");
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

// Sends `dataValue` as Part.data and asserts what comes back equals
// `expected`. `expected` defaults to `dataValue` -- i.e. an exact round trip
// -- and is only ever passed explicitly for the int-widening cases that
// google.protobuf.Value's `double number_value` arm makes impossible to
// preserve (see testPartDataIntegersWidenToFloatOverGrpc).
isolated function assertPartDataRoundTrips(anydata dataValue, anydata? expected = ()) returns error? {
    anydata expectedValue = expected is () ? dataValue : expected;
    grpcstub:Part sentPart = {data: dataValue};
    grpcstub:SendMessageResponse echoed = check sendPartThroughGrpcMock(sentPart);
    grpcstub:Message? msg = echoed?.message;
    test:assertTrue(msg is grpcstub:Message, "expected a message back");
    grpcstub:Part[] parts = (<grpcstub:Message>msg).parts;
    test:assertEquals(parts.length(), 1);
    test:assertEquals(parts[0]?.data, expectedValue, "Part.data did not round-trip");
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
