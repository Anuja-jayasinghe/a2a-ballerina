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

import ballerina/a2a.grpcstub;
import ballerina/grpc;
import ballerina/test;

@test:Config {groups: ["grpc"]}
function testGrpcStreamAdapterDecodesAndClosesOnTerminal() returns error? {
    grpcstub:StreamResponse[] scripted = [
        {task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}},
        {status_update: {task_id: "t1", context_id: "c1", status: {state: grpcstub:TASK_STATE_WORKING}}},
        {status_update: {task_id: "t1", context_id: "c1", status: {state: grpcstub:TASK_STATE_COMPLETED}}}
    ];
    stream<grpcstub:StreamResponse, error?> upstream = scripted.toStream();
    GrpcStreamAdapter adapter = new (upstream);
    record {|StreamResponse value;|}? r1 = check adapter.next();
    test:assertTrue(r1 is record {|StreamResponse value;|});
    record {|StreamResponse value;|}? r2 = check adapter.next();
    test:assertTrue(r2 is record {|StreamResponse value;|});
    record {|StreamResponse value;|}? r3 = check adapter.next();
    test:assertTrue(r3 is record {|StreamResponse value;|});
    if r3 is record {|StreamResponse value;|} {
        test:assertEquals(r3.value?.statusUpdate?.status?.state, TASK_STATE_COMPLETED);
    }
    // Terminal event reached — a well-behaved upstream would end here too,
    // but assert the adapter itself also treats this as closed:
    record {|StreamResponse value;|}|error? r4 = adapter.next();
    test:assertEquals(r4, ());
}

@test:Config {groups: ["grpc"]}
function testGrpcStreamAdapterSurfacesMidStreamError() returns error? {
    ErroringStreamGenerator gen = new ({task: {id: "t1", status: {state: grpcstub:TASK_STATE_SUBMITTED}}});
    stream<grpcstub:StreamResponse, error?> upstream = new (gen);
    GrpcStreamAdapter adapter = new (upstream);
    record {|StreamResponse value;|}? r1 = check adapter.next();
    test:assertTrue(r1 is record {|StreamResponse value;|});
    record {|StreamResponse value;|}|error? r2 = adapter.next();
    test:assertTrue(r2 is A2AError, "a mid-stream grpc:Error must surface as a typed A2AError");
}

// Test-only generator that yields one value then a grpc:Error, to exercise
// the mid-stream-error path without a real network stream.
isolated class ErroringStreamGenerator {
    private final grpcstub:StreamResponse & readonly first;
    private boolean firstServed = false;

    isolated function init(grpcstub:StreamResponse first) {
        self.first = first.cloneReadOnly();
    }

    public isolated function next() returns record {|grpcstub:StreamResponse value;|}|grpc:Error? {
        boolean alreadyServed;
        lock {
            alreadyServed = self.firstServed;
            self.firstServed = true;
        }
        if !alreadyServed {
            return {value: self.first};
        }
        return error grpc:UnavailableError("connection dropped");
    }
}
