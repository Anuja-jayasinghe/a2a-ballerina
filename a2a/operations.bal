// Transport-agnostic request building and response decoding for the
// eleven client operations.
//
// Every operation splits into three parts: build the parameter map, hand
// it to a transport, decode what comes back. Only the middle part depends
// on which binding is in use — the parameter shapes and response types are
// the protocol's, not the transport's, and the v0.3 compatibility layer
// keys off the wire dialect rather than the binding too.
//
// Keeping the first and third parts here is what lets each transport's
// client class hold only its own marshaling: the eleven operations are
// written once, not once per binding.

# Adds the tenant routing parameter when one applies.
#
# Tenant routing is a v1.0-only concept (per-AgentInterface tenant values).
# v0.3 has no wire counterpart, so it is omitted rather than sent as an
# unrecognized param a strict v0.3 server might reject.
#
# + params - the parameter map to add to, mutated in place
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the same map, for call-site chaining
isolated function applyTenant(map<json> params, string? effectiveTenant, ProtocolMode mode) returns map<json> {
    if effectiveTenant is string && mode == "V1_0" {
        params["tenant"] = effectiveTenant;
    }
    return params;
}

# + message - the message to send
# + config - optional send configuration
# + metadata - optional additional context
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map, or an error if the message can't be encoded
isolated function buildSendMessageParams(
        Message message,
        SendMessageConfiguration? config,
        map<json>? metadata,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json>|error {
    json messageJson = mode == "V0_3"
        ? check encodeV03Message(message)
        : encodeRawBytesForWire(message.toJson());
    map<json> params = {"message": messageJson};
    if config is SendMessageConfiguration {
        params["configuration"] = mode == "V0_3"
            ? encodeV03SendConfiguration(config)
            : config.toJson();
    }
    if metadata is map<json> {
        params["metadata"] = metadata;
    }
    return applyTenant(params, effectiveTenant, mode);
}

# Unwraps a unary sendMessage response.
#
# + result - the raw result payload
# + mode - the wire dialect this client speaks
# + return - the Task or Message the agent replied with, or an error
isolated function decodeSendMessageResult(json result, ProtocolMode mode) returns Task|Message|error {
    if mode == "V0_3" {
        return decodeV03SendResult(result);
    }

    // The wire response wraps the payload — {"task": {...}} or
    // {"message": {...}} — rather than returning either one flat.
    SendMessageResult wrapped = check (check decodeRawBytesFromWire(result)).cloneWithType(SendMessageResult);
    Task? maybeTask = wrapped?.task;
    Message? maybeMessage = wrapped?.message;

    // A conforming server can't produce this — task/message form a real
    // protobuf oneof upstream, which makes both being set structurally
    // impossible in a well-formed response. But SendMessageResult is a
    // plain open record on our side, not an actual oneof, so nothing
    // stops a non-conforming server from sending both. Rather than
    // silently preferring one, treat it as the malformed response it is.
    if maybeTask is Task && maybeMessage is Message {
        return error InvalidAgentResponseError(
            "Response contained both a task and a message"
        );
    }
    if maybeTask is Task {
        return maybeTask;
    }
    if maybeMessage is Message {
        return maybeMessage;
    }
    return error InvalidAgentResponseError(
        "Response contained neither a task nor a message"
    );
}

# Decodes a response whose payload is a bare Task. Shared by getTask and
# cancelTask, which differ only in the request they send.
#
# + result - the raw result payload
# + mode - the wire dialect this client speaks
# + return - the decoded Task, or an error
isolated function decodeTaskResult(json result, ProtocolMode mode) returns Task|error {
    return mode == "V0_3"
        ? parseV03Task(result)
        : (check decodeRawBytesFromWire(result)).cloneWithType(Task);
}

# + taskId - the task identifier
# + historyLength - maximum messages to include in task.history
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildGetTaskParams(
        string taskId,
        int? historyLength,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json> {
    map<json> params = {"id": taskId};
    if historyLength is int {
        params["historyLength"] = historyLength;
    }
    return applyTenant(params, effectiveTenant, mode);
}

# + taskId - the task to cancel
# + metadata - optional additional context passed to the agent
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildCancelTaskParams(
        string taskId,
        map<json>? metadata,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json> {
    map<json> params = {"id": taskId};
    if metadata is map<json> {
        params["metadata"] = metadata;
    }
    return applyTenant(params, effectiveTenant, mode);
}

# + taskId - the task to subscribe to
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildSubscribeToTaskParams(
        string taskId,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json> {
    return applyTenant({"id": taskId}, effectiveTenant, mode);
}

# ListTasks has no equivalent in A2A protocol v0.3 (confirmed new in
# v1.0), so a client speaking v0.3 fails immediately rather than sending a
# request the server can't possibly understand.
#
# + mode - the wire dialect this client speaks
# + return - an error when the dialect is v0.3, otherwise nil
isolated function guardListTasksSupported(ProtocolMode mode) returns error? {
    if mode == "V0_3" {
        return error VersionNotSupportedError(
            "ListTasks has no equivalent in A2A protocol v0.3",
            message = "ListTasks has no equivalent in A2A protocol v0.3"
        );
    }
}

# Whether the held Agent Card rules out streaming, per issue #11.
#
# "Denied" rather than "allowed" is the load-bearing framing: this answers
# true only when a card exists AND explicitly says streaming is
# unsupported. Every transport-specific client always holds the card it
# was constructed or resolved with, so `card` is never actually `()` in
# practice; the `AgentCard?` parameter exists so this reads the same way
# as the `extendedAgentCard` check it's modeled on, and stays correct if
# that ever changes. `AgentCapabilities.streaming` defaults to `false`
# (types.bal), so a card that omits the field is treated as not
# supporting streaming - the same staleness trade-off `extendedAgentCard`
# already makes.
#
# + card - the client's held AgentCard, or () if it has none
# + return - true if streaming should be short-circuited client-side
isolated function cardDeniesStreaming(AgentCard? card) returns boolean {
    return card is AgentCard && !card.capabilities.streaming;
}

# Whether the held Agent Card rules out push notifications, per issue #11.
# Same "denied" framing as cardDeniesStreaming.
#
# Deliberately not consulted by deleteTaskPushNotificationConfig:
# deletion is idempotent per specification section 3.1.10, so gating it
# would turn a legitimate no-op into a client-side failure instead of
# letting it reach the server (which is where correctness lives anyway).
#
# + card - the client's held AgentCard, or () if it has none
# + return - true if the push-notification-config operations should be
#            short-circuited client-side
isolated function cardDeniesPushNotifications(AgentCard? card) returns boolean {
    return card is AgentCard && !card.capabilities.pushNotifications;
}

# Builds the client-side rejection for a streaming call the held card says
# is unsupported. Carries the same UnsupportedOperationError type and JSON-RPC
# code (-32004) the server's own rejection would per errors.bal, so callers
# matching on `detail().code` see one case either way; the message says
# explicitly that this never reached the network, so a caller inspecting the
# error text (e.g. in logs) can still tell the two apart.
#
# + operation - the operation name, for the error text (e.g. "subscribeToTask")
# + return - a typed, client-side UnsupportedOperationError
isolated function streamingUnsupportedError(string operation) returns error {
    string message = string `${operation}: AgentCard.capabilities.streaming is false - rejected client-side, no request sent`;
    return error UnsupportedOperationError(message, message = message, code = -32004);
}

# Builds the client-side rejection for a push-notification-config call the
# held card says is unsupported. Same rationale as streamingUnsupportedError.
#
# + operation - the operation name, for the error text
# + return - a typed, client-side PushNotificationNotSupportedError
isolated function pushNotificationsUnsupportedError(string operation) returns error {
    string message = string `${operation}: AgentCard.capabilities.pushNotifications is false - rejected client-side, no request sent`;
    return error PushNotificationNotSupportedError(message, message = message, code = -32003);
}

# + filter - optional filter/pagination parameters
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildListTasksParams(
        ListTasksFilter? filter,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json> {
    map<json> params = {};
    if filter is ListTasksFilter {
        string? contextId = filter?.contextId;
        TaskState? status = filter?.status;
        int? pageSize = filter?.pageSize;
        string? pageToken = filter?.pageToken;
        int? historyLength = filter?.historyLength;
        string? statusTimestampAfter = filter?.statusTimestampAfter;
        boolean? includeArtifacts = filter?.includeArtifacts;
        if contextId is string {
            params["contextId"] = contextId;
        }
        if status is TaskState {
            params["status"] = status;
        }
        if pageSize is int {
            params["pageSize"] = pageSize;
        }
        if pageToken is string {
            params["pageToken"] = pageToken;
        }
        if historyLength is int {
            params["historyLength"] = historyLength;
        }
        if statusTimestampAfter is string {
            params["statusTimestampAfter"] = statusTimestampAfter;
        }
        if includeArtifacts is boolean {
            params["includeArtifacts"] = includeArtifacts;
        }
    }
    return applyTenant(params, effectiveTenant, mode);
}

# + result - the raw result payload
# + return - the decoded page of tasks, or an error
isolated function decodeListTasksResult(json result) returns ListTasksResult|error {
    return (check decodeRawBytesFromWire(result)).cloneWithType(ListTasksResult);
}

# + config - the webhook configuration to register
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map, or an error if the config can't be encoded
isolated function buildCreateTaskPushNotificationConfigParams(
        TaskPushNotificationConfig config,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json>|error {
    map<json> params = mode == "V0_3"
        ? encodeV03TaskPushNotificationConfig(config)
        : check config.toJson().ensureType();
    return applyTenant(params, effectiveTenant, mode);
}

# v0.3's Get/DeleteTaskPushNotificationConfigParams is
# {id: <taskId>, pushNotificationConfigId: <id>} — not {taskId, id} like
# v1.0 — per a2a-sdk 0.3.23. Both operations take the identical shape, so
# they share this builder.
#
# + taskId - the task the config was registered against
# + id - the config's identifier
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildPushNotificationConfigRefParams(
        string taskId,
        string id,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json> {
    map<json> params = mode == "V0_3"
        ? {id: taskId, pushNotificationConfigId: id}
        : {taskId, id};
    return applyTenant(params, effectiveTenant, mode);
}

# + result - the raw result payload
# + mode - the wire dialect this client speaks
# + return - the decoded config, or an error
isolated function decodeTaskPushNotificationConfig(json result, ProtocolMode mode) returns TaskPushNotificationConfig|error {
    return mode == "V0_3"
        ? parseV03TaskPushNotificationConfig(result)
        : result.cloneWithType(TaskPushNotificationConfig);
}

# v0.3's ListTaskPushNotificationConfigParams is {id: <taskId>} only — no
# pageSize/pageToken, since v0.3 has no pagination concept for this
# operation — per a2a-sdk 0.3.23.
#
# + taskId - the task to list configs for
# + pageSize - maximum results per page
# + pageToken - opaque cursor from a previous result's nextPageToken
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildListTaskPushNotificationConfigsParams(
        string taskId,
        int? pageSize,
        string? pageToken,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json> {
    map<json> params = mode == "V0_3" ? {id: taskId} : {taskId};
    if mode == "V1_0" {
        if pageSize is int {
            params["pageSize"] = pageSize;
        }
        if pageToken is string {
            params["pageToken"] = pageToken;
        }
    }
    return applyTenant(params, effectiveTenant, mode);
}

# + result - the raw result payload
# + mode - the wire dialect this client speaks
# + return - the decoded page of configs, or an error
isolated function decodeListTaskPushNotificationConfigsResult(json result, ProtocolMode mode) returns ListTaskPushNotificationConfigsResult|error {
    return mode == "V0_3"
        ? parseV03ListTaskPushNotificationConfigsResult(result)
        : result.cloneWithType(ListTaskPushNotificationConfigsResult);
}

# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildGetExtendedAgentCardParams(
        string? effectiveTenant,
        ProtocolMode mode) returns map<json> {
    return applyTenant({}, effectiveTenant, mode);
}
