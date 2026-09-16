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
    test:assertTrue(card.capabilities.streaming,
            "streaming is wired, so the derived card must claim it");
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
function testServerRoundTripSendStreamingMessage() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "stream me"}]}
    });

    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Task, "the first event must be the newly created task");
    test:assertEquals((<Task>first).status.state, TASK_STATE_SUBMITTED);
    string taskId = (<Task>first).id;

    StreamResponse second = check expectStreamValue(events);
    test:assertTrue(second is TaskStatusUpdateEvent, "the second event must be the WORKING status");
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_WORKING);
    test:assertEquals((<TaskStatusUpdateEvent>second).taskId, taskId);

    StreamResponse third = check expectStreamValue(events);
    test:assertTrue(third is TaskArtifactUpdateEvent, "the third event must be the echoed artifact");
    test:assertEquals((<TaskArtifactUpdateEvent>third).artifact.parts[0]?.text, "echo: stream me");
    test:assertTrue((<TaskArtifactUpdateEvent>third).lastChunk, "a whole-artifact addArtifact call is its own last chunk");

    StreamResponse fourth = check expectStreamValue(events);
    test:assertTrue(fourth is TaskStatusUpdateEvent, "the fourth event must be the COMPLETED status");
    test:assertEquals((<TaskStatusUpdateEvent>fourth).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? fifth = events.next();
    test:assertTrue(fifth is (), "the stream must close after the terminal status");
}

@test:Config {}
function testServerRoundTripSendStreamingMessageDirectReply() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ping"}]}
    });

    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Message, "a direct reply must be the stream's one and only event");
    test:assertEquals((<Message>first).parts[0]?.text, "pong");

    record {| StreamResponse value; |}|error? second = events.next();
    test:assertTrue(second is (), "the stream must close immediately after the one Message event");
}

@test:Config {}
function testServerRoundTripSubscribeToTask() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "subscribe me"}]}
    });

    stream<StreamResponse, error?> events = check c->subscribeToTask({id: created.id});
    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Task, "subscribeToTask's first event must be the task's current state");
    test:assertEquals((<Task>first).id, created.id);
    test:assertEquals((<Task>first).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? second = events.next();
    test:assertTrue(second is (),
            "the echo agent always finishes inside its own sendMessage call, so a subsequent " +
            "subscribeToTask only ever sees a terminal snapshot and the stream closes immediately");
}

@test:Config {}
function testServerRoundTripSubscribeToUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?>|Error result = c->subscribeToTask({id: "does-not-exist"});
    test:assertTrue(result is TaskNotFoundError,
            "an unknown task must round-trip as a2a:TaskNotFoundError through the google.rpc.Status body");
}

isolated function expectStreamValue(stream<StreamResponse, error?> events) returns StreamResponse|error {
    record {| StreamResponse value; |}|error? result = events.next();
    if result is error {
        return result;
    }
    if result is () {
        return error("expected a value but the stream ended");
    }
    return result.value;
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
