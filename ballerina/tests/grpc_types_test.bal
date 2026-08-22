import ballerina/test;
import ballerina/a2a.grpcstub;

@test:Config {groups: ["grpc"]}
function testRoleEnumParity() {
    // grpc_binding.bal casts between Role and grpcstub:Role with unguarded
    // `<T>` expressions (e.g. `<grpcstub:Role>m.role`, `<Role>m.role`) rather
    // than a checked conversion, on the assumption that the two enums'
    // member sets are string-identical. That assumption only holds if this
    // test enforces parity in BOTH directions: a member added to one enum
    // (e.g. by regenerating grpcstub from an updated a2a.proto) without the
    // matching member on the other side would otherwise panic at runtime on
    // the unguarded cast instead of failing loudly here at test time.
    string[] libraryMembers = ["ROLE_UNSPECIFIED", "ROLE_USER", "ROLE_AGENT"];
    foreach string m in libraryMembers {
        test:assertTrue(grpcRoleHasMember(m), string `grpcstub:Role missing member ${m} present in types.bal Role`);
    }
    foreach string m in libraryMembers {
        test:assertTrue(libraryRoleHasMember(m), string `types.bal Role missing member ${m} present in grpcstub:Role`);
    }
}

@test:Config {groups: ["grpc"]}
function testTaskStateEnumParity() {
    // See testRoleEnumParity: grpc_binding.bal's TaskState casts are also
    // unguarded, so this test must check both directions of parity, not
    // just that types.bal's members are a subset of grpcstub's.
    string[] libraryMembers = [
        "TASK_STATE_UNSPECIFIED", "TASK_STATE_SUBMITTED", "TASK_STATE_WORKING",
        "TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED",
        "TASK_STATE_REJECTED", "TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"
    ];
    foreach string m in libraryMembers {
        test:assertTrue(grpcTaskStateHasMember(m), string `grpcstub:TaskState missing member ${m} present in types.bal TaskState`);
    }
    foreach string m in libraryMembers {
        test:assertTrue(libraryTaskStateHasMember(m), string `types.bal TaskState missing member ${m} present in grpcstub:TaskState`);
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

isolated function libraryRoleHasMember(string name) returns boolean {
    Role|error r = trap name.ensureType(Role);
    return r is Role;
}

isolated function libraryTaskStateHasMember(string name) returns boolean {
    TaskState|error s = trap name.ensureType(TaskState);
    return s is TaskState;
}
