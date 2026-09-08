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

// The operation set every A2A client type implements, regardless of which
// transport binding it speaks.

# The client-side A2A operation set (specification section 9.4), declared
# once here and mixed into every client type in this module via `*ClientMethods;`,
# instead of repeating all eleven signatures four times.
#
# `JsonRpcClient`, `RestClient`, and `GrpcClient` each implement it over
# exactly one transport binding. `Client` implements it too, by resolving
# an Agent Card, picking the binding the card prefers, and delegating.
#
# **Not public, deliberately.** Ballerina object types are structurally
# typed: a caller who wants to write binding-agnostic code across two or
# more of this library's client types does not need this library to
# export a named interface for that — they can declare their own local
# object type covering whichever methods they actually use, and any of
# `Client`/`RestClient`/`JsonRpcClient`/`GrpcClient` satisfies it
# automatically, with no dependency on this type. Confirmed directly: a
# scratch package assigning a real `RestClient` to a locally-declared
# type with a matching `getTask` signature compiles with no reference to
# this type at all. Exporting it would only have saved a caller from
# writing that one-time local declaration themselves — not enabled
# anything otherwise impossible — and no real caller (internal test
# aside) has needed it. Revisit only if that changes: adding `public`
# back later is additive, not breaking; the reverse would not be.
#
# **Error contract: every method below returns a narrowed Error, never
# a bare `error`.** The `+ return` doc on each names the specific
# Error subtype(s) (errors.bal) a protocol-level failure produces (the
# agent rejected the request, or a capability check short-circuited it
# client-side) — but a caller that only checks for those named subtypes
# still sees every other failure as an Error too. A raw transport or
# decode error — a connection failure, a malformed response body, an
# unexpected shape `cloneWithType` rejects — comes from
# `ballerina/http`/`ballerina/grpc`/`ballerina/mime`, which return plain
# `error`, not this library's own type; each binding's implementation
# wraps that at the boundary via `wrapTransportError` (errors.bal) into
# an InternalError before it ever reaches a caller, the same way
# `fetchAgentCardBody`/`resolveAgentCard` (client.bal) already do. A
# caller that needs to tell a protocol failure apart from a transport
# failure still pattern-matches on the concrete type
# (`result is a2a:TaskNotFoundError`, etc.) — only the fallback case
# changed, from an untyped `error` to `a2a:InternalError`.
type ClientMethods isolated client object {

    # Sends a message to the remote agent.
    #
    # + message - The message to send; messageId must be set by the caller
    # + config - Optional send configuration
    # + tenant - Optional per-call tenant override
    # + metadata - Optional request-level metadata, per SendMessageRequest
    #              (specification section 3.2.1) — distinct from
    #              message.metadata, which is metadata on the Message itself
    # + return - A Task or a Message on success, or an error on failure
    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|Error;

    # Sends a message and receives updates as they happen.
    #
    # + message - The message to send
    # + config - Optional send configuration
    # + tenant - Optional per-call tenant override
    # + metadata - Optional request-level metadata
    # + return - A stream of StreamResponse values, or an error
    isolated remote function sendStreamingMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|Error;

    # Retrieves the current state of a task.
    #
    # + taskId - The task identifier returned by a previous sendMessage
    # + historyLength - Maximum messages to include in task.history
    # + tenant - Optional per-call tenant override
    # + return - The current Task, or an error if unknown
    isolated remote function getTask(string taskId, int? historyLength = (), string? tenant = ()) returns Task|Error;

    # Requests cancellation of an in-progress task.
    #
    # + taskId - The task to cancel
    # + metadata - Optional additional context passed to the agent
    # + tenant - Optional per-call tenant override
    # + return - The updated Task, or an error
    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|Error;

    # Opens a stream on an existing task.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated remote function subscribeToTask(
            string taskId,
            string? tenant = ()) returns stream<StreamResponse, error?>|Error;

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + filter - Optional filter/pagination parameters
    # + tenant - Optional per-call tenant override
    # + return - A page of matching tasks, or an error
    isolated remote function listTasks(ListTasksFilter? filter = (), string? tenant = ()) returns ListTasksResult|Error;

    # Registers a webhook to receive updates for a task.
    #
    # + config - The webhook configuration; config.taskId identifies the task
    # + tenant - Optional per-call tenant override
    # + return - The created config as the server persisted it, or an error
    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|Error;

    # Retrieves a previously registered push-notification webhook config.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier, from its creation response
    # + tenant - Optional per-call tenant override
    # + return - The config, or an error
    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|Error;

    # Lists all push-notification webhook configs registered for a task.
    #
    # + taskId - The task to list configs for
    # + pageSize - Maximum results per page
    # + pageToken - Opaque cursor from a previous result's nextPageToken
    # + tenant - Optional per-call tenant override
    # + return - A page of matching configs, or an error
    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|Error;

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier
    # + tenant - Optional per-call tenant override
    # + return - nil on success, or an error
    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns Error?;

    # Retrieves the agent's extended AgentCard.
    #
    # + tenant - Optional per-call tenant override
    # + return - The extended AgentCard, the already-held card when that
    #            card declares no extended-card support, or an error
    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|Error;
};
