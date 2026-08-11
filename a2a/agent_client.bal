// The operation set every A2A client type implements, regardless of which
// transport binding it speaks.

# The client-side A2A operation set (specification section 9.4), declared
# once and implemented by every client type in this module.
#
# `JsonRpcClient`, `RestClient`, and `GrpcClient` each implement it over
# exactly one transport binding. `Client` implements it too, by resolving
# an Agent Card, picking the binding the card prefers, and delegating.
#
# Code that does not care which binding it is talking over should be
# written against this type — it works identically whether it holds the
# auto-detecting `Client` or a concrete client constructed directly:
#
# ```ballerina
# a2a:AgentClient agent = check new a2a:Client(url);   // card decides
# a2a:AgentClient agent = check new a2a:GrpcClient(url); // caller decides
# ```
public type AgentClient isolated client object {

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
            map<json>? metadata = ()) returns Task|Message|error;

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
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|error;

    # Retrieves the current state of a task.
    #
    # + taskId - The task identifier returned by a previous sendMessage
    # + historyLength - Maximum messages to include in task.history
    # + tenant - Optional per-call tenant override
    # + return - The current Task, or an error if unknown
    isolated remote function getTask(
            string taskId,
            int? historyLength = (),
            string? tenant = ()) returns Task|error;

    # Requests cancellation of an in-progress task.
    #
    # + taskId - The task to cancel
    # + metadata - Optional additional context passed to the agent
    # + tenant - Optional per-call tenant override
    # + return - The updated Task, or an error
    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|error;

    # Opens a stream on an existing task.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated remote function subscribeToTask(
            string taskId,
            string? tenant = ()) returns stream<StreamResponse, error?>|error;

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + filter - Optional filter/pagination parameters
    # + tenant - Optional per-call tenant override
    # + return - A page of matching tasks, or an error
    isolated remote function listTasks(
            ListTasksFilter? filter = (),
            string? tenant = ()) returns ListTasksResult|error;

    # Registers a webhook to receive updates for a task.
    #
    # + config - The webhook configuration; config.taskId identifies the task
    # + tenant - Optional per-call tenant override
    # + return - The created config as the server persisted it, or an error
    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|error;

    # Retrieves a previously registered push-notification webhook config.
    #
    # + taskId - The task the config was registered against
    # + id - The config's identifier, from its creation response
    # + tenant - Optional per-call tenant override
    # + return - The config, or an error
    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|error;

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
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error;

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
            string? tenant = ()) returns error?;

    # Retrieves the agent's extended AgentCard.
    #
    # + tenant - Optional per-call tenant override
    # + return - The extended AgentCard, the already-held card when that
    #            card declares no extended-card support, or an error
    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error;

    # Returns the extensions the remote agent granted on the most recent
    # call that reported them, per the response's A2A-Extensions header.
    #
    # + return - the granted extension URIs
    public isolated function lastGrantedExtensions() returns string[];
};
