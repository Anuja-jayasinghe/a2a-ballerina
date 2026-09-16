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

// The server's strongest single check: this library's own Client driving
// this library's own Listener, in one process. If the two halves disagree on
// any part of the wire, this fails.
//
// One listener for the whole suite (a port cannot host two), started in
// @test:BeforeSuite and stopped in @test:AfterSuite.

import ballerina/test;

const int SERVER_TEST_PORT = 19234;
final string serverUrl = string `http://localhost:${SERVER_TEST_PORT}`;

listener Listener echoListener = new (SERVER_TEST_PORT, agentCard = {
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    // Placeholders: the listener derives both from what it serves.
    capabilities: {},
    supportedInterfaces: []
});

// A minimal agent: echoes the inbound text back as a completed task's
// artifact, unless the text is "ping", which gets a direct Message reply.
isolated service class EchoAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater)
            returns Message|Error? {
        string text = "";
        foreach Part part in context.message.parts {
            string? t = part?.text;
            if t is string {
                text += t;
            }
        }
        if text == "ping" {
            return {messageId: "reply-1", role: ROLE_AGENT, parts: [{text: "pong"}]};
        }
        check updater->working();
        check updater->addArtifact([{text: string `echo: ${text}`}]);
        check updater->complete();
        return ();
    }
}

@test:BeforeSuite
function startEchoServer() returns error? {
    check echoListener.attach(new EchoAgent());
}

isolated function echoClient() returns Client|error => new (serverUrl);

@test:Config {}
function testServerServesAgentCardForClientDiscovery() returns error? {
    AgentCard card = check resolveAgentCard(serverUrl);
    test:assertEquals(card.name, "Echo Agent");
    test:assertEquals(card.supportedInterfaces.length(), 1);
    test:assertEquals(card.supportedInterfaces[0].protocolBinding, "HTTP+JSON",
            "the served card must declare the HTTP+JSON interface");
    test:assertEquals(card.supportedInterfaces[0].protocolVersion, "1.0");
    test:assertFalse(card.capabilities.streaming,
            "streaming is not wired yet, so the derived card must not claim it");
}

@test:Config {}
function testServerRoundTripSendMessageReturnsTask() returns error? {
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(reply is Task, "a non-ping message must come back as a completed task");
    Task task = <Task>reply;
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    Artifact[] artifacts = task.artifacts ?: [];
    test:assertEquals(artifacts.length(), 1);
    test:assertEquals(artifacts[0].parts[0]?.text, "echo: hello");
}

@test:Config {}
function testServerRoundTripDirectMessageReply() returns error? {
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ping"}]}
    });
    test:assertTrue(reply is Message, "\"ping\" must come back as a direct Message, not a Task");
    test:assertEquals((<Message>reply).parts[0]?.text, "pong");
}

@test:Config {}
function testServerRoundTripGetTask() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "remember me"}]}
    });
    Task fetched = check c->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "getTask must return the task sendMessage created");
    test:assertEquals(fetched.status.state, TASK_STATE_COMPLETED);
}

@test:Config {}
function testServerRoundTripGetUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    Task|Error result = c->getTask({id: "does-not-exist"});
    test:assertTrue(result is TaskNotFoundError,
            "an unknown task must round-trip as a2a:TaskNotFoundError through the google.rpc.Status body");
}

@test:Config {}
function testServerRoundTripCancelTask() returns error? {
    Client c = check echoClient();
    // The echo agent completes synchronously, so the task is already terminal;
    // canceling it must be refused as TaskNotCancelableError.
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "done fast"}]}
    });
    Task|Error canceled = c->cancelTask({id: created.id});
    test:assertTrue(canceled is TaskNotCancelableError,
            "a completed task cannot be canceled; the server must say so");
}

@test:Config {}
function testServerRoundTripListTasks() returns error? {
    Client c = check echoClient();
    Task|Message _ = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "one"}]}
    });
    Task|Message _ = check c->sendMessage({
        message: {messageId: "m2", role: ROLE_USER, parts: [{text: "two"}]}
    });
    ListTasksResponse page = check c->listTasks({pageSize: 10});
    test:assertTrue(page.totalSize >= 2, "listTasks must see the tasks that were created");
    test:assertEquals(page.nextPageToken, "", "a full page must end with an empty nextPageToken");
}

@test:AfterSuite
function stopEchoServer() returns error? {
    check echoListener.gracefulStop();
}
