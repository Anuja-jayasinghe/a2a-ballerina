import ballerina/test;
import ballerina/a2a.grpcstub;

@test:Config {groups: ["grpc"]}
function testRoleEnumParity() {
    string[] libraryMembers = ["ROLE_UNSPECIFIED", "ROLE_USER", "ROLE_AGENT"];
    foreach string m in libraryMembers {
        test:assertTrue(grpcRoleHasMember(m), string `grpcstub:Role missing member ${m} present in types.bal Role`);
    }
}

@test:Config {groups: ["grpc"]}
function testTaskStateEnumParity() {
    string[] libraryMembers = [
        "TASK_STATE_UNSPECIFIED", "TASK_STATE_SUBMITTED", "TASK_STATE_WORKING",
        "TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED",
        "TASK_STATE_REJECTED", "TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"
    ];
    foreach string m in libraryMembers {
        test:assertTrue(grpcTaskStateHasMember(m), string `grpcstub:TaskState missing member ${m} present in types.bal TaskState`);
    }
}

isolated function grpcRoleHasMember(string name) returns boolean {
    grpcstub:Role|error r = trap name.ensureType(grpcstub:Role);
    return r is grpcstub:Role;
}

isolated function grpcTaskStateHasMember(string name) returns boolean {
    grpcstub:TaskState|error s = trap name.ensureType(grpcstub:TaskState);
    return s is grpcstub:TaskState;
}
