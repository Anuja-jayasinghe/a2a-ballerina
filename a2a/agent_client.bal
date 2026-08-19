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
#
# **Error contract: every method below returns a bare `error`, not a
# narrowed A2AError union — the `+ return` doc on each names the specific
# A2AError subtype(s) (errors.bal) a protocol-level failure produces (the
# agent rejected the request, or a capability check short-circuited it
# client-side), but that named type is not the only possibility.** A raw
# transport or decode error — a connection failure, a malformed response
# body, an unexpected shape `cloneWithType` rejects — propagates via
# `check` alongside it, unwrapped, exactly as documented on
# `fetchAgentCardBody`/`resolveAgentCard` (client.bal) for the same
# reason: those failures come from `ballerina/http`/`ballerina/grpc`/
# `ballerina/mime`, which return plain `error`, not this library's
# distinct A2AError type, so `check`ing them straight through is what
# keeps every operation to three or four lines instead of a rewrap at
# every fallible call. A caller that needs to tell a protocol failure
# apart from a transport failure must pattern-match on the concrete
# type (`result is a2a:TaskNotFoundError`, etc.) rather than assume the
# error is always one of errors.bal's named types.
#
# **Stability note: implemented by this library only, not a stable
# extension point for external implementors.** It is a public, syntactically
# implementable object type — nothing stops a caller writing their own
# `AgentClient`, and holding one behind this type (as above) is exactly
# the supported way to accept any of this library's four client types
# interchangeably. What is *not* promised is that this method set stays
# fixed forever: a genuinely useful per-call addition (timeout, extra
# headers, tracing context — none of which the A2A specification defines,
# and none of which this library currently has a way to plumb through)
# would need a new parameter on some or all of these eleven methods, and
# adding one to a client object type is a breaking change for anyone who
# implemented it themselves. Held open deliberately rather than closed
# off with a speculative parameter nobody has asked for yet — see the
# design plan's discussion of per-call context for the tradeoff this
# balances.
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
};
