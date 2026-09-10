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

# Unwraps a protobuf `oneof` envelope into the single arm it carries.
#
# Several specification messages are `oneof`s whose arms serialize as a
# wrapper object keyed by the arm's own name — `SendMessageResponse` is
# `{"task": {...}}` or `{"message": {...}}`, `StreamResponse` adds
# `statusUpdate` and `artifactUpdate`. Exactly one arm is set in a
# conformant payload.
#
# Presence is decided by member presence, not by a non-nil value, because
# that is what the specification says the discriminator is
# (`specification.md`, "member presence acts as discriminator"). Testing for
# a non-nil value instead would misread a legitimately-null arm as absent.
#
# + envelope - the raw envelope object
# + arms - the arm names this caller understands, in specification order
# + return - the matched arm's name and payload; `()` when the envelope
#            carries no arm this caller recognizes, which a newer
#            specification revision can legitimately produce; or an
#            InvalidAgentResponseError when more than one arm is set
isolated function oneofArm(json envelope, string[] arms) returns [string, json]?|Error {
    map<json>|error asMap = envelope.ensureType();
    if asMap is error {
        return invalidAgentResponse(
                string `expected a oneof envelope object, found ${(typeof envelope).toString()}`);
    }
    string[] present = from string arm in arms
        where asMap.hasKey(arm)
        select arm;
    if present.length() > 1 {
        return invalidAgentResponse(
                string `oneof envelope set more than one arm: ${string:'join(", ", ...present)}`);
    }
    if present.length() == 0 {
        return ();
    }
    return [present[0], asMap.get(present[0])];
}

# Decodes one v1.0 StreamResponse envelope into its single arm.
#
# + envelope - the raw `{"task": {...}}` / `{"statusUpdate": {...}}` object
# + return - the decoded arm; `()` when the envelope carries no arm this
#            client recognizes, so the caller can skip the event and read
#            on; or an InvalidAgentResponseError if the arm's payload does
#            not match its type
isolated function decodeStreamResponseEnvelope(json envelope) returns StreamResponse?|Error {
    [string, json]? arm = check oneofArm(
            envelope, ["task", "message", "statusUpdate", "artifactUpdate"]);
    if arm is () {
        return ();
    }
    [string, json] [name, payload] = arm;
    anydata|error decoded;
    match name {
        "task" => {
            decoded = payload.cloneWithType(Task);
        }
        "message" => {
            decoded = payload.cloneWithType(Message);
        }
        "statusUpdate" => {
            decoded = payload.cloneWithType(TaskStatusUpdateEvent);
        }
        _ => {
            decoded = payload.cloneWithType(TaskArtifactUpdateEvent);
        }
    }
    if decoded is error {
        return invalidAgentResponse(
                string `stream event "${name}" did not match the expected shape: ${decoded.message()}`);
    }
    return <StreamResponse>decoded;
}

# Enforces non-emptiness on the two arrays the specification actually
# requires it for.
#
# Section 5.7 contains a blanket sentence -- "Arrays marked as required MUST
# contain at least one element" -- which cannot be read literally. The
# specification's own canonicalization example in section 8.4.1 publishes a
# conformant AgentCard carrying `"skills": []` and annotates it "REQUIRED
# field -> include", with a canonical output that keeps the empty array. A
# rule the specification's own example violates is not the rule: REQUIRED
# means the field must be *present*, which the type system already enforces.
#
# Non-emptiness is enforced only where the specification says so per field,
# or where the reference implementation corroborates it:
#
#   Artifact.parts  - the proto states "Must contain at least one part", the
#                     only such statement in the whole file; a2a-java
#                     enforces it (Artifact.java:52)
#   Message.parts   - no proto statement, but it is the message's content
#                     container and a2a-java enforces it (Message.java:70)
#
# a2a-java has no non-empty check on AgentCard or AgentSkill at all, which
# matches the section 8.4.1 example.
#
# Validated in both directions: section 5.7 asks implementations to "reject
# messages with missing required fields" -- messages, not only responses --
# and checking outbound turns a network round trip and whatever error the
# agent chooses into an immediate, local, precise one.
#
# + name - the field's dotted name, for the message
# + length - the array's actual length
# + inbound - true when validating what an agent sent us, false for what a
#             caller is about to send
# + return - an error when the array is empty, otherwise nil
isolated function requireNonEmpty(string name, int length, boolean inbound) returns Error? {
    if length > 0 {
        return ();
    }
    string message = string `${name} is a required array and must contain at least one element `
        + string `(specification section 5.7)`;
    // Inbound is the agent's fault; outbound is the caller's. InternalError
    // is this library's catch-all for a client-side precondition failure --
    // the specification defines no error for one, since section 3.3.2 and
    // section 5.4 both describe server behaviour, and the same choice is
    // already made by outboundPartVariantError.
    return inbound
        ? invalidAgentResponse(message)
        : error InternalError(message, message = message);
}

# Validates a Message a caller is about to send.
#
# + message - the message to check
# + return - an error when it violates a specification requirement
isolated function validateOutboundMessage(Message message) returns Error? {
    check requireNonEmpty("Message.parts", message.parts.length(), false);
    foreach Part part in message.parts {
        int variants = countSetPartVariants(part);
        if variants != 1 {
            error variantError = outboundPartVariantError(variants);
            string m = variantError.message();
            return error InternalError(m, message = m);
        }
    }
    return ();
}

# Validates a Task an agent sent us, and the artifacts and history it carries.
#
# + task - the decoded task
# + return - an error when it violates a specification requirement
isolated function validateInboundTask(Task task) returns Error? {
    foreach Artifact artifact in task.artifacts ?: [] {
        check requireNonEmpty("Artifact.parts", artifact.parts.length(), true);
    }
    foreach Message historyMessage in task.history ?: [] {
        check requireNonEmpty("Message.parts", historyMessage.parts.length(), true);
    }
    return ();
}

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
        ProtocolMode mode) returns map<json>|Error {
    check validateOutboundMessage(message);
    json|error messageJsonResult = mode == "V0_3"
        ? encodeV03Message(message)
        : encodeRawBytesForWire(message.toJson());
    if messageJsonResult is error {
        return wrapTransportError(messageJsonResult);
    }
    json messageJson = messageJsonResult;
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
# + return - the Task or Message the agent replied with, or an
#            InvalidAgentResponseError if it doesn't match the expected shape
isolated function decodeSendMessageResult(json result, ProtocolMode mode) returns Task|Message|Error {
    if mode == "V0_3" {
        Task|Message|error v03Result = decodeV03SendResult(result);
        return v03Result is error ? wrapTransportError(v03Result) : v03Result;
    }

    // The wire response wraps the payload -- {"task": {...}} or
    // {"message": {...}} -- rather than returning either one flat.
    json|error rewired = decodeRawBytesFromWire(result);
    if rewired is error {
        return invalidAgentResponse(string `sendMessage response could not be decoded: ${rewired.message()}`);
    }
    [string, json]? arm = check oneofArm(rewired, ["task", "message"]);
    if arm is () {
        return invalidAgentResponse("Response contained neither a task nor a message");
    }
    [string, json] [name, payload] = arm;
    if name == "task" {
        Task|error task = payload.cloneWithType(Task);
        return task is error
            ? invalidAgentResponse(string `sendMessage response did not match the expected shape: ${task.message()}`)
            : task;
    }
    Message|error message = payload.cloneWithType(Message);
    return message is error
        ? invalidAgentResponse(string `sendMessage response did not match the expected shape: ${message.message()}`)
        : message;
}

# Decodes a response whose payload is a bare Task. Shared by getTask and
# cancelTask, which differ only in the request they send.
#
# + result - the raw result payload
# + mode - the wire dialect this client speaks
# + return - the decoded Task, or an InvalidAgentResponseError if it
#            doesn't match the expected shape
isolated function decodeTaskResult(json result, ProtocolMode mode) returns Task|Error {
    if mode == "V0_3" {
        Task|error v03Result = parseV03Task(result);
        return v03Result is error ? wrapTransportError(v03Result) : v03Result;
    }
    json|error rewired = decodeRawBytesFromWire(result);
    if rewired is error {
        return invalidAgentResponse(string `Task response could not be decoded: ${rewired.message()}`);
    }
    Task|error decoded = rewired.cloneWithType(Task);
    if decoded is error {
        return invalidAgentResponse(string `Task response did not match the expected shape: ${decoded.message()}`);
    }
    check validateInboundTask(decoded);
    return decoded;
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
isolated function guardListTasksSupported(ProtocolMode mode) returns Error? {
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
isolated function streamingUnsupportedError(string operation) returns UnsupportedOperationError {
    string message = string `${operation}: AgentCard.capabilities.streaming is false - rejected client-side, no request sent`;
    return error UnsupportedOperationError(message, message = message, code = -32004);
}

# Builds the client-side rejection for a getExtendedAgentCard call the held
# AgentCard says the agent does not support.
#
# Specification section 3.3.4 requires exactly this: "If
# AgentCard.capabilities.extendedAgentCard is false or not present, attempts
# to call the Get Extended Agent Card operation MUST return
# UnsupportedOperationError." Sections 3.1.11 and 13.3 say the same, and
# nowhere does the specification sanction returning the public card instead
# -- section 3.1.11 defines the output as the extended card *when the
# operation is available*, not a substitute when it is not.
#
# + return - the typed rejection
isolated function extendedCardUnsupportedError() returns UnsupportedOperationError {
    string message = "getExtendedAgentCard: AgentCard.capabilities.extendedAgentCard is false "
        + "or not present - rejected client-side, no request sent";
    return error UnsupportedOperationError(message, message = message, code = -32004);
}

# Builds the client-side rejection for a push-notification-config call the
# held card says is unsupported. Same rationale as streamingUnsupportedError.
#
# + operation - the operation name, for the error text
# + return - a typed, client-side PushNotificationNotSupportedError
isolated function pushNotificationsUnsupportedError(string operation) returns PushNotificationNotSupportedError {
    string message = string `${operation}: AgentCard.capabilities.pushNotifications is false - rejected client-side, no request sent`;
    return error PushNotificationNotSupportedError(message, message = message, code = -32003);
}

# + filter - optional filter/pagination parameters
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildListTasksParams(
        ListTasksRequest? filter,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json> {
    map<json> params = {};
    if filter is ListTasksRequest {
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
# + return - the decoded page of tasks, or an InvalidAgentResponseError if
#            it doesn't match the expected shape
isolated function decodeListTasksResponse(json result) returns ListTasksResponse|Error {
    json|error rewired = decodeRawBytesFromWire(result);
    if rewired is error {
        return invalidAgentResponse(string `ListTasks response could not be decoded: ${rewired.message()}`);
    }
    ListTasksResponse|error decoded = rewired.cloneWithType(ListTasksResponse);
    if decoded is error {
        return invalidAgentResponse(string `ListTasks response did not match the expected shape: ${decoded.message()}`);
    }
    // No non-empty check on `tasks`: an empty page is a legitimate "no
    // results matched". See requireNonEmpty for why section 5.7's blanket
    // sentence is not read literally.
    foreach Task task in decoded.tasks {
        check validateInboundTask(task);
    }
    return decoded;
}

# + config - the webhook configuration to register
# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map, or an error if the config can't be encoded
isolated function buildCreateTaskPushNotificationConfigParams(
        TaskPushNotificationConfig config,
        string? effectiveTenant,
        ProtocolMode mode) returns map<json>|Error {
    if mode == "V0_3" {
        return applyTenant(encodeV03TaskPushNotificationConfig(config), effectiveTenant, mode);
    }
    map<json>|error params = config.toJson().ensureType();
    if params is error {
        return wrapTransportError(params);
    }
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
# + return - the decoded config, or an InvalidAgentResponseError if it
#            doesn't match the expected shape
isolated function decodeTaskPushNotificationConfig(json result, ProtocolMode mode) returns TaskPushNotificationConfig|Error {
    if mode == "V0_3" {
        TaskPushNotificationConfig|error v03Result = parseV03TaskPushNotificationConfig(result);
        return v03Result is error ? wrapTransportError(v03Result) : v03Result;
    }
    TaskPushNotificationConfig|error decoded = result.cloneWithType(TaskPushNotificationConfig);
    if decoded is error {
        return invalidAgentResponse(string `TaskPushNotificationConfig response did not match the expected shape: ${decoded.message()}`);
    }
    return decoded;
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
# + return - the decoded page of configs, or an InvalidAgentResponseError
#            if it doesn't match the expected shape
isolated function decodeListTaskPushNotificationConfigsResponse(json result, ProtocolMode mode)
        returns ListTaskPushNotificationConfigsResponse|Error {
    if mode == "V0_3" {
        ListTaskPushNotificationConfigsResponse|error v03Result = parseV03ListTaskPushNotificationConfigsResponse(result);
        return v03Result is error ? wrapTransportError(v03Result) : v03Result;
    }
    ListTaskPushNotificationConfigsResponse|error decoded = result.cloneWithType(ListTaskPushNotificationConfigsResponse);
    if decoded is error {
        return invalidAgentResponse(
            string `ListTaskPushNotificationConfigs response did not match the expected shape: ${decoded.message()}`);
    }
    return decoded;
}

# + effectiveTenant - the per-call override, or the client's default
# + mode - the wire dialect this client speaks
# + return - the parameter map
isolated function buildGetExtendedAgentCardParams(string? effectiveTenant, ProtocolMode mode) returns map<json> {
    return applyTenant({}, effectiveTenant, mode);
}
