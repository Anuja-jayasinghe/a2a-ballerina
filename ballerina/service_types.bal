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

// What a developer implements to serve an A2A agent.
//
// Two shapes, the same split `ballerina/mcp` draws between `Service` and
// `AdvancedService`, and the same split the reference SDKs draw between an
// `AgentExecutor` and a `RequestHandler`:
//
//   `a2a:Service`         - implement one method, `onMessage`; the library
//                           runs the task lifecycle, listTasks, the push-config
//                           store, and the extended card around it.
//   `a2a:AdvancedService` - implement all eleven operations directly, for an
//                           agent that owns its own storage.
//
// Only `a2a:Service` is wired in this release; `a2a:AdvancedService` is
// declared so the shape is fixed, and gains its dispatch in a later change.

# An A2A agent that implements the single message entry point and lets the
# library run everything else.
#
# The developer implements `onMessage`. For a long-running task it drives the
# supplied `a2a:TaskUpdater` through the lifecycle; for a simple exchange it
# returns a `a2a:Message` directly.
public type Service distinct isolated service object {

    # Handles one inbound message.
    #
    # + context - The message and the request that carried it
    # + updater - Drives the task this message creates, or is left unused when
    #             the reply is a direct `a2a:Message`
    # + return - A direct `a2a:Message` reply, `()` when the task was driven
    #            through `updater` instead, or an `a2a:Error`
    remote isolated function onMessage(RequestContext context, TaskUpdater updater)
        returns Message|Error?;
};

# An A2A agent that implements every operation itself.
#
# For agents that keep their own task storage and want no lifecycle
# management from the library. Declared now so the contract is stable;
# dispatch to it arrives in a later release.
public type AdvancedService distinct isolated service object {

    # Sends a message to the agent.
    #
    # + request - The message and its send options
    # + return - A `a2a:Task` or a `a2a:Message`, or an `a2a:Error`
    remote isolated function onSendMessage(SendMessageRequest request) returns Task|Message|Error;

    # Retrieves a task by id.
    #
    # + request - The task identifier and optional history length
    # + return - The task, or an `a2a:Error`
    remote isolated function onGetTask(GetTaskRequest request) returns Task|Error;

    # Requests cancellation of a task.
    #
    # + request - The task identifier and any additional context
    # + return - The updated task, or an `a2a:Error`
    remote isolated function onCancelTask(CancelTaskRequest request) returns Task|Error;

    # Lists tasks matching a filter.
    #
    # + request - The filter and pagination parameters
    # + return - A page of tasks, or an `a2a:Error`
    remote isolated function onListTasks(ListTasksRequest request) returns ListTasksResponse|Error;
};

# The inbound message and the context of the request that delivered it.
#
# Passed to `a2a:Service.onMessage`. Holds the message the client sent, the
# effective tenant the request was routed under (or `()` when none), and any
# `configuration` the client attached.
public type RequestContext record {|
    # The message the client sent
    Message message;
    # The tenant segment the request arrived under, or `()`
    string? tenant;
    # The send configuration the client attached, if any
    SendMessageConfiguration? configuration;
|};
