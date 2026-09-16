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

// Runs the task lifecycle for an `a2a:Service`.
//
// This is the `DefaultRequestHandler` equivalent: the developer's
// `onMessage` is the only business logic, and this turns its result into the
// ten operations a client can call. sendMessage creates a task and drives it
// (or passes a direct Message straight back); getTask/cancelTask/listTasks
// read and mutate through the `TaskStore`.

import ballerina/time;
import ballerina/uuid;

isolated class DefaultHandler {
    private final Service agentService;
    private final TaskStore store;

    isolated function init(Service agentService, TaskStore store) {
        self.agentService = agentService;
        self.store = store;
    }

    # Handles sendMessage: create a task, run the developer's `onMessage`
    # against it, and return the finished task — or the direct `Message` the
    # agent returned instead.
    #
    # A client-supplied `contextId` is honoured; otherwise one is generated and
    # carried on the task, as section 3.4.1 requires.
    #
    # + request - The decoded send request
    # + tenant - The tenant the request was routed under, or `()`
    # + return - The finished Task or a direct Message, or an error
    isolated function sendMessage(SendMessageRequest request, string? tenant) returns Task|Message|Error {
        check validateOutboundMessage(request.message);

        string contextId = request.message?.contextId ?: uuid:createType4AsString();
        string taskId = uuid:createType4AsString();

        // Seed the task as submitted before handing control to the agent, so a
        // concurrent getTask sees it exists.
        Task seed = {
            id: taskId,
            contextId,
            status: {state: TASK_STATE_SUBMITTED, timestamp: time:utcToString(time:utcNow())}
        };
        check self.store.put(seed);

        RequestContext context = {
            message: request.message,
            tenant,
            configuration: request?.configuration
        };
        TaskUpdater updater = new (taskId, contextId, self.store);

        Message|Error? direct = self.agentService->onMessage(context, updater);
        if direct is Error {
            return direct;
        }
        if direct is Message {
            // A direct reply: the seeded task is not part of the conversation,
            // so drop it and hand the Message back.
            check self.store.remove(taskId);
            return direct;
        }

        // The agent drove the task through `updater`. Return its final state.
        Task? finished = check self.store.get(taskId);
        if finished is () {
            return invalidAgentResponse(
                    string `onMessage returned without driving the task to a state for ${taskId}`);
        }
        return finished;
    }

    # Handles sendStreamingMessage: like `sendMessage`, but returns every
    # event `onMessage` produced, in generation order, for the caller to
    # frame as SSE.
    #
    # `onMessage` runs to completion before this returns -- there is no
    # concurrent task execution in this release, so the stream this produces
    # is a replay of what already happened, not a live feed. What the client
    # sees on the wire is identical either way: per specification 3.1.2, the
    # stream begins with the Task object (here, its just-seeded SUBMITTED
    # state) followed by the status/artifact events `onMessage` drove the
    # task through, or -- for a direct reply -- exactly one Message event.
    #
    # + request - The decoded send request
    # + tenant - The tenant the request was routed under, or `()`
    # + return - The events to stream, in order, or an error
    isolated function sendStreamingMessage(SendMessageRequest request, string? tenant) returns StreamResponse[]|Error {
        check validateOutboundMessage(request.message);

        string contextId = request.message?.contextId ?: uuid:createType4AsString();
        string taskId = uuid:createType4AsString();

        Task seed = {
            id: taskId,
            contextId,
            status: {state: TASK_STATE_SUBMITTED, timestamp: time:utcToString(time:utcNow())}
        };
        check self.store.put(seed);

        RequestContext context = {
            message: request.message,
            tenant,
            configuration: request?.configuration
        };
        TaskUpdater updater = new (taskId, contextId, self.store);

        Message|Error? direct = self.agentService->onMessage(context, updater);
        if direct is Error {
            return direct;
        }
        if direct is Message {
            check self.store.remove(taskId);
            return [direct];
        }

        StreamResponse[] events = [seed];
        events.push(...updater.drainEvents());
        if events.length() == 1 {
            return invalidAgentResponse(
                    string `onMessage returned without driving the task to a state for ${taskId}`);
        }
        return events;
    }

    # Handles subscribeToTask: the task's current state, as a one-event
    # stream.
    #
    # Per specification 3.1.6, the first event on a genuine subscribe is the
    # task's current state. This release has no live cross-request following
    # of a task still being driven by another in-flight call -- `onMessage`
    # always finishes inside the request that started it (see
    # `sendStreamingMessage`), so by the time a separate subscribeToTask
    # request can reach the server the task is already in the state that
    # request's own `sendMessage`/`sendStreamingMessage` call left it in, and
    # that snapshot is all there ever will be to see. The stream is therefore
    # always exactly one event, closing immediately after -- correct for a
    # task already terminal, and a documented scope boundary (not a bug) for
    # one still notionally in progress on another connection.
    #
    # + request - The task identifier
    # + return - The one-event stream, or a TaskNotFoundError
    isolated function subscribeToTask(SubscribeToTaskRequest request) returns StreamResponse[]|Error {
        Task? task = check self.store.get(request.id);
        if task is () {
            return taskNotFound(request.id);
        }
        return [task];
    }

    # Handles getTask.
    #
    # + request - The task identifier and optional history length
    # + return - The task, or a TaskNotFoundError
    isolated function getTask(GetTaskRequest request) returns Task|Error {
        Task? task = check self.store.get(request.id);
        if task is () {
            return taskNotFound(request.id);
        }
        int? historyLength = request?.historyLength;
        if historyLength is int {
            Message[]? history = task?.history;
            if history is Message[] && history.length() > historyLength {
                task.history = historyLength <= 0 ? []
                    : history.slice(history.length() - historyLength);
            }
        }
        return task;
    }

    # Handles cancelTask.
    #
    # A task already in a terminal state cannot be canceled (section 3.1.1), so
    # that is a TaskNotCancelableError.
    #
    # + request - The task identifier
    # + return - The canceled task, or an error
    isolated function cancelTask(CancelTaskRequest request) returns Task|Error {
        Task? task = check self.store.get(request.id);
        if task is () {
            return taskNotFound(request.id);
        }
        if isTerminalState(task.status.state) {
            string msg = string `task ${request.id} is in terminal state ${task.status.state} `
                + string `and cannot be canceled`;
            return error TaskNotCancelableError(msg, message = msg, code = -32002);
        }
        task.status = {state: TASK_STATE_CANCELED, timestamp: time:utcToString(time:utcNow())};
        check self.store.put(task);
        return task;
    }

    # Handles listTasks.
    #
    # + request - The filter and pagination parameters
    # + return - A page of tasks
    isolated function listTasks(ListTasksRequest request) returns ListTasksResponse|Error {
        return self.store.list(request);
    }
}

# Builds a TaskNotFoundError for an unknown task id.
#
# + id - The id that was not found
# + return - The typed error
isolated function taskNotFound(string id) returns TaskNotFoundError {
    string msg = string `no task with id ${id}`;
    return error TaskNotFoundError(msg, message = msg, code = -32001);
}
