import ballerina/test;
import ballerina/time;

@test:Config {groups: ["grpc"]}
function testGrpcKvToMapStringValues() {
    record {|string key; string value;|}[] kv = [{key: "a", value: "1"}, {key: "b", value: "2"}];
    map<string> result = grpcKvToMap(kv);
    test:assertEquals(result, {"a": "1", "b": "2"});
}

@test:Config {groups: ["grpc"]}
function testMapToGrpcKvStringValues() {
    map<string> m = {"a": "1", "b": "2"};
    record {|string key; string value;|}[] result = mapToGrpcKv(m);
    test:assertEquals(result.length(), 2);
    map<string> roundTripped = grpcKvToMap(result);
    test:assertEquals(roundTripped, m);
}

@test:Config {groups: ["grpc"]}
function testGrpcTimestampToStringDefaultIsAbsent() {
    time:Utc zeroTimestamp = [0, 0.0d];
    test:assertEquals(grpcTimestampToString(zeroTimestamp), ());
}

@test:Config {groups: ["grpc"]}
function testGrpcTimestampToStringRealValue() returns error? {
    time:Utc ts = check time:utcFromString("2023-10-27T10:00:00Z");
    test:assertEquals(grpcTimestampToString(ts), "2023-10-27T10:00:00.000Z");
}

@test:Config {groups: ["grpc"]}
function testStringToGrpcTimestampRoundTrips() returns error? {
    time:Utc ts = check stringToGrpcTimestamp("2023-10-27T10:00:00Z");
    test:assertEquals(grpcTimestampToString(ts), "2023-10-27T10:00:00.000Z");
}

@test:Config {groups: ["grpc"]}
function testStringToGrpcTimestampAbsentIsZero() returns error? {
    time:Utc ts = check stringToGrpcTimestamp(());
    test:assertEquals(ts, [0, 0.0d]);
}

@test:Config {groups: ["grpc"]}
function testEmptyGrpcStringToNil() {
    test:assertEquals(emptyGrpcStringToNil(""), ());
    test:assertEquals(emptyGrpcStringToNil("x"), "x");
}

@test:Config {groups: ["grpc"]}
function testGrpcStructRoundTrip() returns error? {
    map<json> original = {"a": 1, "b": "two", "c": {"nested": true}};
    map<anydata> struct = jsonToGrpcStruct(original);
    map<json>? back = check grpcStructToJson(struct);
    test:assertEquals(back, original);
}

@test:Config {groups: ["grpc"]}
function testGrpcStructEmptyMapIsAbsent() returns error? {
    map<anydata> struct = {};
    map<json>? back = check grpcStructToJson(struct);
    test:assertEquals(back, ());
}
