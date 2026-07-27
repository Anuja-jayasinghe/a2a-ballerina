# Phase 1: Client Techn…

# **A2A Library for Ballerina — Phase 1: Client Technical Design**

*Scope: **a2a:Client** and supporting data model only. Phase 2 (Listener, TaskStore, service pattern) is a separate document.*  
*Target specification: A2A Protocol v1.0.0 — https://a2a-protocol.org/latest/specification/*  
*Package: **ballerina/a2a** (working name)*  
*Version: 1.0 (Phase 1 Client)*

# ---

**1\. Scope and objectives**

This document covers everything required to build, test, and ship the client side of the **ballerina/a2a** library. The goal is a working **a2a:Client** that a Ballerina developer can point at any A2A v1.0-compliant server — written in any language — and call correctly.  
Phase 1 is deliberately client-only. The library is built and validated against existing third-party A2A servers (the Google Python reference agents and the Java SDK reference server) before any server-side work begins. This sequencing means the data model and wire format are proven correct against real implementations before we depend on them for our own server.

## **1.1 In scope**

> * Complete core data model — AgentCard, Message, Part, Task, TaskStatus, TaskState, Artifact, TaskStatusUpdateEvent, TaskArtifactUpdateEvent, StreamResponse, SendMessageConfiguration, push notification config types, and all error types  
> * **resolveAgentCard** — discovers and parses a remote agent's Agent Card from its well-known endpoint  
> * **isolated client class Client** — outbound connector with five remote methods: sendMessage, sendMessageStream, getTask, cancelTask, subscribeToTask  
> * JSON-RPC 2.0 request and response serialization (internal submodule)  
> * **A2A-Version: 1.0** header on every request, per specification section 3.6.1  
> * **tenant** parameter support on all operations for multi-tenant routing  
> * Authentication via http:ClientConfiguration plus optional default headers  
> * contextId and taskId threading for multi-turn conversations

## **1.2 Out of scope — deferred to Phase 2**

> * a2a:Listener, the service object contract, onTask and onCancel  
> * TaskStore interface and InMemoryTaskStore default implementation  
> * Agent Card and skills authoring guide (server-side concern)  
> * Push notification webhook receiver — Phase 1 only sends push config to a server, it does not host an endpoint  
> * extendedAgentCard retrieval  
> * listTasks operation  
> * gRPC and HTTP+JSON/REST protocol bindings — Phase 1 implements the JSON-RPC binding only  
> * Agent Card JWS signature verification

# ---

**2\. Module layout**

Proposed package: **ballerina/a2a**, mirroring the file-per-concern convention already used in ballerina/mcp so the two agent-protocol libraries read consistently.

```
ballerina/a2a/
  Ballerina.toml
  types.bal          — all public data model types
  client.bal         — isolated client class Client + resolveAgentCard
  errors.bal         — A2AError hierarchy and toA2AError JSON-RPC error code mapping
  sse.bal            — A2AStreamGenerator / readSseStream: decodes each SSE event's
                       JSON-RPC envelope into a StreamResponse and closes the
                       stream on a terminal status
  modules/
    transport/
      jsonrpc.bal    — JSON-RPC 2.0 envelope types only: JsonRpcRequest,
                       JsonRpcResponse, JsonRpcError
```

*Each file owns one concern, but the split between the root module and modules/transport/ is drawn on module-dependency direction, not just topic:*

* ***modules/transport/ is a pure wire-format leaf.*** *It contains only the JSON-RPC envelope types (JsonRpcRequest, JsonRpcResponse, JsonRpcError) and has zero dependency on the root a2a module. It does not build request envelopes, parse responses into domain types, or map error codes — anything that would require referencing A2AError, StreamResponse, Task, or any other root-level type stays out of transport/.*
* ***Protocol-semantic logic lives in the root module, not in transport.*** *toA2AError (errors.bal) and SSE-to-StreamResponse decoding (sse.bal, via A2AStreamGenerator) both construct root-level types — A2AError subtypes and StreamResponse — from transport's wire types. Since the root module already imports ballerina/a2a.transport for the envelope types, transport cannot import the root module back without creating a cyclic module dependency, which bal build rejects outright. Placing this logic in the root module (importing transport, never the reverse) is what keeps the dependency graph a single direction.*

**Note (see commit e4bf7d8):** an earlier draft of this layout had toA2AError and the SSE decoder living inside modules/transport/, with transport importing the root a2a module to construct A2AError/StreamResponse values — while client.bal separately imported modules/transport/ for the envelope types. That is exactly the cyclic dependency described above, and it does not compile. Do not move error mapping or SSE decoding back into modules/transport/ in a future phase without re-establishing this constraint; if new protocol-semantic logic needs wire-format types, add it to the root module (or a new root-level file) and have it import transport, not the other way around.

Everything under modules/transport/ is an unexported submodule — its types are internal plumbing and never form part of the supported public API. Phase 2 adds listener.bal and task\_store.bal to this same package.  
**Public API surface for Phase 1:** the Client class, the resolveAgentCard function, all data model types in types.bal, and all error types in errors.bal. Nothing else is exported.

# ---

# **3\. Core data model**

## **3.1 Open records — a deliberate requirement**

All specification-facing types are declared as **open records** using **record { ... }** rather than closed records using **record {| ... |}**.  
This is required,The specification states that implementations should ignore unrecognised fields to allow forward compatibility as the protocol evolves. A closed record in Ballerina throws a conversion error the moment it encounters an unrecognised field. Since the client deserializes Agent Cards and Tasks produced by arbitrary third-party servers — servers which may be running a newer specification revision or emitting vendor extensions — a closed record would cause the client to fail on perfectly valid payloads.  
Each open record also declares an explicit **json...;** rest field. Dropping the pipes alone would default the rest type to anydata, which tolerates unknown fields but makes them awkward to inspect. Declaring json...; means unknown fields are preserved as inspectable, re-serializable JSON — important when a client fetches a card and forwards it elsewhere.

## **3.2 Agent discovery types**

```
public type AgentProvider record {    string organization;    string url;    string? contactEmail?;    json...;};public type AgentExtension record {    string uri;    string? description?;    boolean required = false;    json...;};public type AgentCapabilities record {    boolean streaming = false;    boolean pushNotifications = false;    boolean stateTransitionHistory = false;    boolean extendedAgentCard = false;    AgentExtension[] extensions = [];    json...;};public type AgentSkill record {    string id;    string name;    string description;    string[] tags = [];    string[] inputModes = [];    string[] outputModes = [];    string[] examples = [];    json...;};public type AgentInterface record {    string url;    string protocolBinding;    string? protocolVersion?;    string? tenant?;    json...;};public type AgentCard record {    string name;    string description;    string version;    string? url?;          // legacy; superseded by supportedInterfaces[0].url, use primaryUrl()    AgentProvider? provider?;    string? documentationUrl?;    string? iconUrl?;    AgentCapabilities capabilities;    AgentInterface[] supportedInterfaces = [];    map<json> securitySchemes = {};    json[] security = [];    string[] defaultInputModes = ["text"];    string[] defaultOutputModes = ["text"];    AgentSkill[] skills;    json[] signatures = [];    json...;};
```

*The AgentCard is the document a remote agent publishes to describe itself. The client fetches it to discover capabilities, the service URL, available skills, and required authentication. Note AgentInterface.tenant — when a selected interface declares a tenant value, the client must echo that value in every subsequent operation.*  
**A note on securitySchemes:** the specification defines five distinct scheme shapes (API key, HTTP auth, OAuth2, OpenID Connect, mutual TLS), each with different fields. Modelling that union properly is a project of its own. Phase 1 types it as map\<json\> so the field is present and readable rather than buried in the rest field, with full typing deferred. This is a known simplification, tracked in section 13\.
**A note on url (superseded):** v1.0 removed AgentCard.url as a required field — the primary endpoint now lives at supportedInterfaces[0].url. url is kept here only as optional, for servers still sending the legacy field. Callers should use the primaryUrl(card) helper (client.bal) rather than reading either field directly, since it applies the correct precedence (supportedInterfaces[0].url first, url as fallback, error if neither is set) — verified necessary because the real Python reference server never sends url at all.

## **3.3 Message and content types**

```
public enum Role {    ROLE_UNSPECIFIED,    ROLE_USER,    ROLE_AGENT}# Part represents one unit of content. Per specification section 4.1.6,# exactly one of text, raw, url, or data must be set. Version 1.0 removed# the 'kind' discriminator field in favour of member-presence detection # the variant is determined by which field is non-nil, not by a tag.public type Part record {    string? text?;         // text content    byte[]? raw?;          // inline file bytes; base64 on the wire    string? url?;          // file by reference    json? data?;           // arbitrary structured data    string? filename?;     // optional, applies to file variants    string? mediaType?;    // MIME type, applies to all variants    map<json>? metadata?;    json...;};public type Message record {    string messageId;                    // required; caller generates a UUID    Role role;                           // ROLE_USER for outbound messages    Part[] parts;    string? contextId?;                  // groups related tasks and messages    string? taskId?;                     // set when continuing an existing task    string[] referenceTaskIds = [];      // other tasks this message references    string[] extensions = [];            // extension URIs for this message    map<json>? metadata?;    json...;};
```

*A Message is one turn of communication. Part is its content container. Determining a Part's variant is done by field presence — if text is non-nil it is a text part, if url or raw is non-nil it is a file part, if data is non-nil it is a structured data part. This maps naturally onto Ballerina optional fields and matches the v1.0 wire format exactly.*

## **3.4 Task lifecycle types**

```
public enum TaskState {    TASK_STATE_UNSPECIFIED,    TASK_STATE_SUBMITTED,    TASK_STATE_WORKING,    TASK_STATE_COMPLETED,        // terminal    TASK_STATE_FAILED,           // terminal    TASK_STATE_CANCELED,         // terminal    TASK_STATE_REJECTED,         // terminal    TASK_STATE_INPUT_REQUIRED,   // interrupted — awaiting client input    TASK_STATE_AUTH_REQUIRED     // interrupted — awaiting authentication}public type TaskStatus record {    TaskState state;    Message? message?;      // rich message, not a plain string    string? timestamp?;     // ISO 8601, e.g. "2023-10-27T10:00:00Z"    json...;};public type Artifact record {    string artifactId;      // unique within the task; this is the identifier    string? name?;          // human-readable label, not an identifier    string? description?;    Part[] parts;           // must contain at least one part    map<json>? metadata?;    string[] extensions = [];    json...;};public type Task record {    string id;              // server-generated; clients never create this    string? contextId?;    TaskStatus status;    Message[] history = [];    Artifact[] artifacts = [];    map<json>? metadata?;    json...;};
```

*Task is the stateful unit of work. TaskStatus.message is typed as a full Message object rather than a plain string — this is what allows an agent entering TASK\_STATE\_INPUT\_REQUIRED to attach a structured prompt explaining exactly what input it needs. Artifact.artifactId is the real identifier; name is only a display label.*  
**Terminal versus interrupted states.** Four states are terminal: COMPLETED, FAILED, CANCELED, REJECTED. A stream closes when one of these is reached, and no further messages can be sent to the task. Two states are interrupted: INPUT\_REQUIRED and AUTH\_REQUIRED. These pause the task but allow it to resume when the client sends a follow-up message with the same taskId. This distinction drives the stream-close logic in section 8\.

## **3.5 Streaming event types**

```
public type TaskStatusUpdateEvent record {    string taskId;    string contextId;    TaskStatus status;    map<json>? metadata?;    json...;};public type TaskArtifactUpdateEvent record {    string taskId;    string contextId;    Artifact artifact;    boolean append = false;      // append to a previous artifact of same id    boolean lastChunk = false;   // final chunk of this artifact    map<json>? metadata?;    json...;};# StreamResponse is the wrapper delivered by streaming operations.# Exactly one field is non-nil per event, per specification section 3.2.3.public type StreamResponse record {    Task? task?;    Message? message?;    TaskStatusUpdateEvent? statusUpdate?;    TaskArtifactUpdateEvent? artifactUpdate?;    json...;};# SendMessageResult is the wrapper returned by a unary sendMessage call —# a narrower sibling of StreamResponse with the streaming-only fields# (statusUpdate/artifactUpdate) omitted, since a unary reply can only# ever be a Task or a Message.# Exactly one field is non-nil, per specification section 3.1.1.public type SendMessageResult record {    Task? task?;    Message? message?;    json...;};
```

*The two event types are kept separate because they carry structurally different payloads. A status update reports a lifecycle transition; an artifact update delivers output content and supports chunked delivery via append and lastChunk. Merging them into a single type with optional fields would silently discard chunked-artifact support and would not round-trip correctly to the wire format.*  
**On SendMessageResult vs. StreamResponse:** the real reference server's SendMessage response wraps its payload exactly like a StreamResponse's first event does — `{"task": {...}}` or `{"message": {...}}` — never a flat Task or Message. Verified empirically against the official Python reference server (see §7.3); this is not something the earlier draft of this section anticipated. SendMessageResult exists as its own type, rather than reusing StreamResponse directly, so a unary reply's static type can't accidentally carry a statusUpdate or artifactUpdate that would never actually be present.  
**Correction against the previous draft:** an earlier version of this design included an index field on TaskArtifactUpdateEvent. Specification section 4.2.2 defines only taskId, contextId, artifact, append, lastChunk, and metadata. There is no index field in v1.0 and it has been removed. Ordering is guaranteed by the specification requirement that events must be delivered in generation order.

## **3.6 Push notification and request configuration types**

These are included in Phase 1 because SendMessageConfiguration can carry a push notification config that the client sends to the server. The client does not host a webhook receiver — that is Phase 2 work — but it must be able to register one.

```
public type AuthenticationInfo record {    string scheme;             // IANA HTTP auth scheme, e.g. "Bearer"    string? credentials?;    json...;};public type TaskPushNotificationConfig record {    string url;                          // webhook the server will POST to    string? id?;    string? taskId?;                     // leave unset in a sendMessage request    string? token?;    AuthenticationInfo? authentication?;    json...;};public type SendMessageConfiguration record {    string[] acceptedOutputModes = ["text"];    int? historyLength = ();    boolean returnImmediately = false;    TaskPushNotificationConfig? taskPushNotificationConfig = ();    json...;};
```

**Blocking semantics.** Per specification section 3.2.2, returnImmediately defaults to false, meaning sendMessage blocks until the task reaches a terminal or interrupted state. Setting it true returns as soon as the task is created, leaving the caller responsible for polling via getTask, subscribing via subscribeToTask, or receiving push notifications. This default matches the specification and is deliberately not changed.  
**History length semantics.** An unset value imposes no limit. A value of zero requests that history be omitted entirely. A positive value requests at most that many recent messages. The server must not return more than requested but may return fewer.

# ---

# **4\. Error types**

```
// errors.balpublic type A2AErrorDetail record {    string message;    int code?;        // originating JSON-RPC code, preserved for diagnostics    json data?;       // structured error details from the server};public type TaskNotFoundError                 error<A2AErrorDetail>;public type TaskNotCancelableError            error<A2AErrorDetail>;public type UnsupportedOperationError         error<A2AErrorDetail>;public type ContentTypeNotSupportedError      error<A2AErrorDetail>;public type InvalidAgentResponseError         error<A2AErrorDetail>;public type VersionNotSupportedError          error<A2AErrorDetail>;public type PushNotificationNotSupportedError error<A2AErrorDetail>;public type A2AInternalError                  error<A2AErrorDetail>;# Union of every A2A protocol error. Lets callers narrow with a single# type test rather than checking each subtype individually.public type A2AError TaskNotFoundError                   | TaskNotCancelableError                   | UnsupportedOperationError                   | ContentTypeNotSupportedError                   | InvalidAgentResponseError                   | VersionNotSupportedError                   | PushNotificationNotSupportedError                   | A2AInternalError;
```

## **4.1 JSON-RPC error code mapping**

The transport submodule maps every incoming JSON-RPC error code to a typed Ballerina error. Unrecognised codes map to A2AInternalError with the original code preserved in A2AErrorDetail.code so no diagnostic information is lost.

| JSON-RPC code | A2A error name | Ballerina type |
| :---- | :---- | :---- |
| \-32001 | TaskNotFoundError | TaskNotFoundError |
| \-32002 | TaskNotCancelableError | TaskNotCancelableError |
| \-32003 | PushNotificationNotSupportedError | PushNotificationNotSupportedError |
| \-32004 | UnsupportedOperationError | UnsupportedOperationError |
| \-32005 | ContentTypeNotSupportedError | ContentTypeNotSupportedError |
| \-32006 | InvalidAgentResponseError | InvalidAgentResponseError |
| \-32007 | ExtendedAgentCardNotConfiguredError | UnsupportedOperationError |
| \-32008 | ExtensionSupportRequiredError | UnsupportedOperationError |
| \-32009 | VersionNotSupportedError | VersionNotSupportedError |
| \-32600 | Invalid Request | A2AInternalError |
| \-32602 | Invalid params | A2AInternalError |
| \-32603 | Internal error | A2AInternalError |
| any other | unrecognised | A2AInternalError (code preserved) |

# ---

**5\. Client design**

## **5.1 Class declaration**

```
// client.balimport ballerina/http;import ballerina/uuid;import ballerina/a2a.transport;# An A2A protocol client for calling remote agents.## Declared as 'isolated client class'. The 'client' keyword makes this a# proper Ballerina connector — it enables remote call syntax and registers# the type as a connector for Central and Choreo tooling. The 'isolated'# keyword guarantees the object is safe to share across concurrent strands# without locking, which the compiler enforces by requiring every field to# be final and every field type to be isolated or readonly.## Both fields satisfy those constraints: http:Client is itself declared# isolated in the standard library, and an intersection with readonly# produces an immutable map.public isolated client class Client {    private final http:Client httpClient;    private final map<string> & readonly defaultHeaders;    private final string? tenant;    # Creates a client pointed at a remote A2A agent.    #    # + serviceUrl - Base URL of the remote agent's A2A endpoint    # + clientConfig - Full http:ClientConfiguration. Covers auth, TLS,    #                  retry, circuit breaker, proxy, timeouts, and    #                  connection pooling.    # + headers - Default headers merged into every outbound request. Use    #             for API key schemes requiring a custom header name.    #             Bearer and OAuth2 auth belong in clientConfig.auth.    # + tenant - Optional multi-tenant routing identifier. When the selected    #            AgentInterface in the Agent Card declares a tenant value,    #            that value must be supplied here so it is sent with every    #            operation. Leave unset for single-tenant agents.    # + return - error if the underlying http:Client cannot be created    public isolated function init(        string serviceUrl,        http:ClientConfiguration clientConfig = {},        map<string> headers = {},        string? tenant = ()    ) returns error? {        self.httpClient = check new (serviceUrl, clientConfig);        self.defaultHeaders = headers.cloneReadOnly();        self.tenant = tenant;    }}
```

## **5.2 Why http:ClientConfiguration is accepted directly**

An earlier design defined a bespoke ClientConfig record with three hand-picked fields: auth, timeout, and retryConfig. That subset was chosen by intuition rather than by working through what **http:ClientConfiguration** already provides.  
http:ClientConfiguration already covers every configuration concern this client has: auth (with http:ClientAuthConfig spanning basic credentials, bearer token, JWT issuer, and four OAuth2 grant types), secureSocket for TLS, retryConfig, circuitBreaker, proxy, timeout, poolConfig, followRedirects, compression, and HTTP/1.1 and HTTP/2 settings. All of it is implemented and maintained by the standard library.  
Accepting the type directly, rather than wrapping or including it, has three advantages. It reuses battle-tested authentication code rather than a thinner reimplementation. It avoids the field-name collision that including via \*http:ClientConfiguration would create with a custom auth field. And it means a developer who already knows how to configure any Ballerina HTTP connector already knows how to configure this one.

## **5.3 Agent Card discovery**

```
# Fetches and parses a remote agent's Agent Card from its well-known endpoint.# Per specification section 8.2 the canonical discovery path is# /.well-known/agent-card.json relative to the agent's base URL.## + agentBaseUrl - Root URL of the agent with no path component# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy# + headers - Optional default headers, for API key authentication# + return - The parsed AgentCard, or an error if the fetch or parse failspublic isolated function resolveAgentCard(    string agentBaseUrl,    http:ClientConfiguration clientConfig = {},    map<string> headers = {}) returns AgentCard|error {    http:Client discoveryClient = check new (agentBaseUrl, clientConfig);    map<string> reqHeaders = {"A2A-Version": "1.0"};    foreach [string, string] [k, v] in headers.entries() {        reqHeaders[k] = v;    }    http:Response resp = check discoveryClient->get(        "/.well-known/agent-card.json", reqHeaders    );    if resp.statusCode != 200 {        return error A2AInternalError(            string `Agent Card fetch failed with HTTP ${resp.statusCode}`,            code = resp.statusCode        );    }    json body = check resp.getJsonPayload();    return check body.cloneWithType(AgentCard);}
```

*Discovery is deliberately a standalone function rather than a method on Client. A caller needs the card before they can construct a client, because the card supplies the service URL, tells them which authentication scheme is required, and declares which capabilities the agent supports.*

# ---

# **6\. Client methods**

All five methods are isolated remote functions. Each accepts an optional tenant override; when omitted, the client-level tenant supplied at construction is used. Every request carries the mandatory A2A-Version: 1.0 header.

## **6.1 sendMessage**

```
# Sends a message to the remote agent.## Blocking by default: the call does not return until the task reaches a# terminal or interrupted state. Set config.returnImmediately to true for# non-blocking behaviour, then poll with getTask or subscribe with# subscribeToTask.## The agent may respond with a Task for tracked work, or with a Message for# a simple direct reply that needs no task lifecycle. Both are valid per# specification section 3.1.1, so the return type covers both.## + message - The message to send; messageId must be set by the caller# + config - Optional send configuration# + tenant - Optional per-call tenant override# + return - A Task or a Message on success, or an A2AError on failureisolated remote function sendMessage(    Message message,    SendMessageConfiguration? config = (),    string? tenant = ()) returns Task|Message|error {    map<json> params = {"message": message.toJson()};    if config is SendMessageConfiguration {        params["configuration"] = config.toJson();    }    string? effectiveTenant = tenant ?: self.tenant;    if effectiveTenant is string {        params["tenant"] = effectiveTenant;    }    json result = check self.rpcCall("SendMessage", params);    // The wire response wraps the payload -- {"task": {...}} or    // {"message": {...}} -- rather than returning either one flat.    SendMessageResult wrapped = check result.cloneWithType(SendMessageResult);    Task? maybeTask = wrapped?.task;    if maybeTask is Task {        return maybeTask;    }    Message? maybeMessage = wrapped?.message;    if maybeMessage is Message {        return maybeMessage;    }    return error InvalidAgentResponseError(        "Response contained neither a task nor a message"    );}
```

## **6.2 sendMessageStream**

```
# Sends a message and receives updates in real time over SSE.## Requires the remote agent to declare capabilities.streaming as true;# otherwise the agent returns UnsupportedOperationError.## The stream opens with a Task or a Message, then delivers zero or more# TaskStatusUpdateEvent and TaskArtifactUpdateEvent values, and closes when# the task reaches a terminal state. Each StreamResponse carries exactly# one non-nil field.## + message - The message to send# + config - Optional send configuration# + tenant - Optional per-call tenant override# + return - A stream of StreamResponse values, or an errorisolated remote function sendMessageStream(    Message message,    SendMessageConfiguration? config = (),    string? tenant = ()) returns stream<StreamResponse, error?>|error {    map<json> params = {"message": message.toJson()};    if config is SendMessageConfiguration {        params["configuration"] = config.toJson();    }    string? effectiveTenant = tenant ?: self.tenant;    if effectiveTenant is string {        params["tenant"] = effectiveTenant;    }    return self.openSseStream("SendStreamingMessage", params);}
```

## **6.3 getTask**

```
# Retrieves the current state of a task.## Used for polling after a non-blocking send, for fetching final state after# a push notification, or for inspecting a task after a stream has ended.## + taskId - The task identifier returned by a previous sendMessage# + historyLength - Maximum messages to include in task.history. Unset means#                   no limit; zero requests that history be omitted.# + tenant - Optional per-call tenant override# + return - The current Task, or TaskNotFoundError if unknownisolated remote function getTask(    string taskId,    int? historyLength = (),    string? tenant = ()) returns Task|error {    map<json> params = {"id": taskId};    if historyLength is int {        params["historyLength"] = historyLength;    }    string? effectiveTenant = tenant ?: self.tenant;    if effectiveTenant is string {        params["tenant"] = effectiveTenant;    }    json result = check self.rpcCall("GetTask", params);    return check result.cloneWithType(Task);}
```

## **6.4 cancelTask**

```
# Requests cancellation of an in-progress task.## Cancellation is best effort. If the task has already reached a terminal# state the agent returns TaskNotCancelableError.## + taskId - The task to cancel# + metadata - Optional additional context passed to the agent# + tenant - Optional per-call tenant override# + return - The updated Task, or TaskNotCancelableErrorisolated remote function cancelTask(    string taskId,    map<json>? metadata = (),    string? tenant = ()) returns Task|error {    map<json> params = {"id": taskId};    if metadata is map<json> {        params["metadata"] = metadata;    }    string? effectiveTenant = tenant ?: self.tenant;    if effectiveTenant is string {        params["tenant"] = effectiveTenant;    }    json result = check self.rpcCall("CancelTask", params);    return check result.cloneWithType(Task);}
```

## **6.5 subscribeToTask**

## 

```
# Opens a stream on an existing task.## The primary use is recovering from a dropped sendMessageStream connection.# Per specification section 3.1.6 the first event delivered is always the# task's current state, which prevents information loss between calling# getTask and re-subscribing.## Requires capabilities.streaming to be true. Returns# UnsupportedOperationError if attempted on a task already in a terminal# state.## + taskId - The task to subscribe to# + tenant - Optional per-call tenant override# + return - A stream of StreamResponse values, or an errorisolated remote function subscribeToTask(    string taskId,    string? tenant = ()) returns stream<StreamResponse, error?>|error {    map<json> params = {"id": taskId};    string? effectiveTenant = tenant ?: self.tenant;    if effectiveTenant is string {        params["tenant"] = effectiveTenant;    }    return self.openSseStream("SubscribeToTask", params);}
```

## **6.6 Operation to wire mapping**

| Client method | JSON-RPC method | HTTP | Response type |
| :---- | :---- | :---- | :---- |
| resolveAgentCard | none | GET /.well-known/agent-card.json | application/json |
| sendMessage | SendMessage | POST | application/json |
| sendMessageStream | SendStreamingMessage | POST | text/event-stream |
| getTask | GetTask | POST | application/json |
| cancelTask | CancelTask | POST | application/json |
| subscribeToTask | SubscribeToTask | POST | text/event-stream |

# ---

# 

# **7\. Transport layer**

## **7.1 JSON-RPC envelope types**

```
// modules/transport/jsonrpc.bal — internal, not exportedpublic type JsonRpcRequest record {|    string jsonrpc = "2.0";    string id;    string method;    map<json> params;|};public type JsonRpcError record {|    int code;    string message;    json data?;|};public type JsonRpcResponse record {|    string jsonrpc;    string id;    json result?;    JsonRpcError 'error?;|};
```

## **7.2 Shared request helpers**

```
// Private methods on Client# Builds the header map for an outbound request. The A2A-Version header is# mandatory on every request per specification section 3.6.1; an agent# receiving an empty value assumes protocol version 0.3, which would# silently downgrade the interaction.private isolated function buildHeaders() returns map<string> {    map<string> headers = {        "Content-Type": "application/json",        "A2A-Version": "1.0"    };    foreach [string, string] [k, v] in self.defaultHeaders.entries() {        headers[k] = v;    }    return headers;}# Performs a unary JSON-RPC call and returns the unwrapped result.private isolated function rpcCall(    string method,    map<json> params) returns json|error {    transport:JsonRpcRequest req = {        id: uuid:createType4AsString(),        method: method,        params: params    };    http:Response resp = check self.httpClient->post(        "", req.toJson(), self.buildHeaders()    );    json body = check resp.getJsonPayload();    transport:JsonRpcResponse rpcResp =        check body.cloneWithType(transport:JsonRpcResponse);    transport:JsonRpcError? rpcErr = rpcResp?.'error;    if rpcErr is transport:JsonRpcError {        return transport:toA2AError(rpcErr);    }    json? result = rpcResp?.result;    if result is () {        return error InvalidAgentResponseError(            "JSON-RPC response contained neither result nor error"        );    }    return result;}
```

## **7.3 Concrete wire examples**

**sendMessage request**

```
POST / HTTP/1.1Host: agent.example.comContent-Type: application/jsonA2A-Version: 1.0Authorization: Bearer eyJhbGciOiJIUzI1NiIs...{  "jsonrpc": "2.0",  "id": "550e8400-e29b-41d4-a716-446655440000",  "method": "SendMessage",  "params": {    "message": {      "messageId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",      "role": "ROLE_USER",      "parts": [{"text": "What is the weather in Colombo?"}]    },    "configuration": {      "acceptedOutputModes": ["text"],      "returnImmediately": false    },    "tenant": "acme-corp"  }}
```

**Successful response**

```
{  "jsonrpc": "2.0",  "id": "550e8400-e29b-41d4-a716-446655440000",  "result": {    "task": {      "id": "task-7f3a9b2c",      "contextId": "ctx-4e8d1a6f",      "status": {        "state": "TASK_STATE_COMPLETED",        "timestamp": "2026-07-20T14:32:11.412967Z"      },      "artifacts": [{        "artifactId": "art-9c2e",        "parts": [{"text": "29 degrees Celsius and partly cloudy."}]      }]    }  }}
```

**Error response**

```
{  "jsonrpc": "2.0",  "id": "550e8400-e29b-41d4-a716-446655440000",  "error": {    "code": -32001,    "message": "Task not found",    "data": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND", "domain": "a2a-protocol.org", "metadata": {}}]  }}
```

**Note — verified against the live reference server, not assumed from the v1.0 migration guide.** An earlier draft of this section used v0.3-era method names (`message/send`, `tasks/get`, etc.) and assumed a flat `Task`/`Message` result. Both were wrong for v1.0: the official Python reference server (`a2a-sdk`, via `a2a-samples/samples/python/agents/helloworld`) only accepts the PascalCase method names shown above, and its `SendMessage` response wraps the payload (`{"task": {...}}` / `{"message": {...}}`) exactly as shown — confirmed by sending real requests and reading real responses, not by trusting the v1.0 migration guide (https://a2a-protocol.org/latest/whats-new-v1/)'s illustrative examples. That guide's own JSON examples for streaming events (`taskStatusUpdate`/`taskArtifactUpdate` keys, plus a claimed `index` field on artifact updates) do **not** match the real server's wire format either — the real keys are `statusUpdate`/`artifactUpdate` with no `index` field, exactly as §3.5 and §8 already document. Do not "fix" sse.bal or the streaming types toward the migration guide's examples; they are the imprecise ones here, not this document.

# ---

# **8\. SSE stream handling —** 

# **Server-Sent Events use the clientconfig wrapper** 

## **8.1 Stream termination**

The stream closes under any of three conditions:

> * A TaskStatusUpdateEvent arrives carrying a terminal state: TASK\_STATE\_COMPLETED, TASK\_STATE\_FAILED, TASK\_STATE\_CANCELED, or TASK\_STATE\_REJECTED. This event is delivered to the caller first, then the stream ends.  
> * The server closes the underlying connection.  
> * The caller closes the stream explicitly.

A TaskArtifactUpdateEvent never closes the stream, even when lastChunk is true — that flag marks the end of one artifact, not the end of the task. Interrupted states (INPUT\_REQUIRED, AUTH\_REQUIRED) also do not close the stream, since the task may resume.

## **8.2 sse.bal implementation**

```
// modules/transport/sse.bal — internal, not exported

import ballerina/http;

# Wraps the standard library SSE event stream, decoding each event's
# JSON-RPC envelope into a StreamResponse and closing the stream once a
# terminal task status is reached.
public isolated function readSseStream(http:Response resp)
        returns stream<a2a:StreamResponse, error?>|error {
    stream<http:SseEvent, error?> sseStream = check resp.getSseEventStream();
    A2AStreamGenerator generator = new (sseStream);
    return new (generator);
}

class A2AStreamGenerator {
    private stream<http:SseEvent, error?> sseStream;
    private boolean closed = false;

    isolated function init(stream<http:SseEvent, error?> sseStream) {
        self.sseStream = sseStream;
    }

    public isolated function next()
            returns record {| a2a:StreamResponse value; |}|error? {
        if self.closed {
            return ();
        }

        while true {
            record {| http:SseEvent value; |}|error? chunk = self.sseStream.next();

            if chunk is () {
                self.closed = true;
                return ();
            }
            if chunk is error {
                self.closed = true;
                return chunk;
            }

            string? data = chunk.value.data;
            if data is () {
                // Comment / keep-alive frame — no payload, pull the next one
                continue;
            }

            a2a:StreamResponse|error result = self.decodeEvent(data);
            if result is error {
                self.closed = true;
                return result;
            }

            if isTerminalEvent(result) {
                self.closed = true;
            }
            return {value: result};
        }
    }

    private isolated function decodeEvent(string data) returns a2a:StreamResponse|error {
        json envelope = check data.fromJsonString();
        JsonRpcResponse rpcResp = check envelope.cloneWithType(JsonRpcResponse);

        JsonRpcError? rpcErr = rpcResp?.'error;
        if rpcErr is JsonRpcError {
            return toA2AError(rpcErr);
        }

        json? result = rpcResp?.result;
        if result is () {
            return error a2a:InvalidAgentResponseError(
                "SSE event contained neither result nor error"
            );
        }
        return check result.cloneWithType(a2a:StreamResponse);
    }

    public isolated function close() returns error? {
        self.closed = true;
        return self.sseStream.close();
    }
}

# A stream terminates only on a status update carrying a terminal state.
isolated function isTerminalEvent(a2a:StreamResponse event) returns boolean {
    a2a:TaskStatusUpdateEvent? statusUpdate = event?.statusUpdate;
    if statusUpdate is () {
        return false;
    }
    a2a:TaskState state = statusUpdate.status.state;
    return state == a2a:TASK_STATE_COMPLETED
        || state == a2a:TASK_STATE_FAILED
        || state == a2a:TASK_STATE_CANCELED
        || state == a2a:TASK_STATE_REJECTED;
}

```

## **8.3 Opening a stream**

```
// Private method on Clientprivate isolated function openSseStream(    string method,    map<json> params) returns stream<StreamResponse, error?>|error {    transport:JsonRpcRequest req = {        id: uuid:createType4AsString(),        method: method,        params: params    };    map<string> headers = self.buildHeaders();    headers["Accept"] = "text/event-stream";    http:Response resp = check self.httpClient->post(        "", req.toJson(), headers    );    if resp.statusCode != 200 {        return error A2AInternalError(            string `Stream request failed with HTTP ${resp.statusCode}`,            code = resp.statusCode        );    }    return transport:readSseStream(resp);}
```

*The request carries Content-Type: application/json because the body is a JSON-RPC envelope, and Accept: text/event-stream to signal that a streamed response is expected.*

# ---

# **9\. Multi-turn conversations and tenant routing**

## **9.1 contextId semantics**

A contextId groups related tasks and messages into one logical conversation. Per specification section 3.4.1 the generation rules are strict and the client must respect them:

> * The agent generates a contextId when it receives a message without one, and must return it in the response.  
> * A client should not invent its own contextId unless it knows how the specific server will treat it. Server-generated values are opaque identifiers from the client's perspective.  
> * An agent that cannot accept a client-supplied contextId must reject the request rather than silently substituting its own.

## **9.2 taskId semantics**

Task identifiers are always server-generated. A client must never invent a taskId to create a new task — the specification explicitly does not support this. When a client includes a taskId in a message it must reference an existing task, and the agent returns TaskNotFoundError otherwise.  
If both taskId and contextId are supplied they must be consistent; the agent rejects a mismatch. Supplying taskId alone is sufficient, since the agent infers the context from the task.

## **9.3 Worked multi-turn example**

```
// Turn one — new conversation, no contextId supplieda2a:Message turn1 = {    messageId: uuid:createType4AsString(),    role: a2a:ROLE_USER,    parts: [{text: "Research quantum error correction advances in 2024"}]};a2a:Task|a2a:Message result1 = check a2aClient->sendMessage(turn1);if result1 is a2a:Task {    // The agent may pause and ask for clarification    if result1.status.state == a2a:TASK_STATE_INPUT_REQUIRED {        a2a:Message? prompt = result1.status?.message;        if prompt is a2a:Message {            io:println("Agent asks: ", prompt.parts[0]?.text);        }        // Turn two — continue the same task. Echo back both identifiers        // exactly as received.        a2a:Message turn2 = {            messageId: uuid:createType4AsString(),            role: a2a:ROLE_USER,            contextId: result1?.contextId,            taskId: result1.id,            parts: [{text: "Focus on surface codes and topological qubits"}]        };        a2a:Task|a2a:Message result2 = check a2aClient->sendMessage(turn2);        io:println("Resumed and completed");    }}
```

## **9.4 tenant semantics**

The tenant field is an structurally non-transparent routing identifier used by multi-tenant agent deployments. Its value must match the tenant declared on the AgentInterface the client selected from the Agent Card, when that field is set.  
The client supports it at two levels. Supplying it to the constructor sets a default applied to every operation, which suits the common case of a client bound to one tenant for its lifetime. Supplying it to an individual method overrides the default for that call, which supports a single client instance addressing multiple tenants.

```
// Discover the agent and read its declared interfacesa2a:AgentCard card = check a2a:resolveAgentCard("https://agent.example.com");// Select the JSON-RPC interface and pick up its tenant, if declaredstring? tenant = ();foreach a2a:AgentInterface iface in card.supportedInterfaces {    if iface.protocolBinding == "JSONRPC" {        tenant = iface?.tenant;        break;    }}// Client-level default: every call carries this tenanta2a:Client a2aClient = check new (check a2a:primaryUrl(card), tenant = tenant);// Per-call override for a different tenant on the same deploymenta2a:Task|a2a:Message result =    check a2aClient->sendMessage(msg, tenant = "other-tenant");
```

# ---

# **10\. Authentication**

Authentication is handled entirely through http:ClientConfiguration and the optional headers map. No A2A-specific authentication types are defined, because none are needed.

```
// Bearer token — the most common A2A patterna2a:Client c = check new ("https://agent.example.com/a2a", {    auth: {token: "eyJhbGciOiJIUzI1NiIs..."}});// OAuth2 client credentials, for service-to-service callsa2a:Client c = check new ("https://agent.example.com/a2a", {    auth: {        tokenUrl: "https://auth.example.com/oauth2/token",        clientId: "my-client-id",        clientSecret: "my-client-secret",        scopes: ["a2a:invoke"]    }});// Basic credentialsa2a:Client c = check new ("https://agent.example.com/a2a", {    auth: {username: "user", password: "pass"}});// API key in a custom headera2a:Client c = check new (    "https://agent.example.com/a2a",    headers = {"X-API-Key": "my-api-key"});// TLS with a custom certificate authoritya2a:Client c = check new ("https://agent.example.com/a2a", {    secureSocket: {cert: "/path/to/ca.crt"}});// Combined: OAuth2, TLS, retry, and timeouta2a:Client c = check new ("https://agent.example.com/a2a", {    auth: {        tokenUrl: "https://auth.example.com/oauth2/token",        clientId: "id",        clientSecret: "secret"    },    secureSocket: {cert: "/path/to/ca.crt"},    retryConfig: {count: 3, interval: 2},    timeout: 120});
```

## **10.1 Discovering authentication requirements**

An Agent Card declares which authentication schemes it accepts through securitySchemes and which are active through security. A client can inspect these before constructing itself.

a2a:AgentCard card \= check a2a:resolveAgentCard("https://agent.example.com");

io:println("Accepted schemes: ", card.securitySchemes.keys());  
io:println("Active security: ", card.security);

// Configure the client based on what the card declares

Phase 1 types securitySchemes as map\<json\> rather than a fully modelled union of the five scheme shapes. Automatic configuration of a client from a fetched card is therefore not provided; the developer reads the declared schemes and configures the client themselves. Full scheme typing and automatic configuration are tracked in section 13\.

# ---

# **11\. Testing and interoperability strategy**

## **11.1 Unit tests**

> * **Serialization round-trips.** Every data model type is serialized to JSON and deserialized back, asserting field-level equality. Fixtures are taken from the worked examples in specification section 6 rather than written by hand, so the tests validate against the specification's own payloads.  
> * **Open-record tolerance.** Each type is deserialized from JSON containing additional unrecognised fields. The test asserts no error is raised, known fields are populated correctly, and unknown fields survive a re-serialization round trip.  
> * **Part variant detection.** Each of the four Part variants is round-tripped, asserting that exactly one content field is non-nil and the others remain nil.  
> * **Error code mapping.** A synthetic JSON-RPC error response is produced for every code in the section 4.1 table, asserting the correct typed error is returned and the original code is preserved.  
> * **Header injection.** Every one of the five methods plus resolveAgentCard is invoked against a mock server that asserts A2A-Version: 1.0 is present.  
> * **Tenant propagation.** Tests cover client-level default applied, per-call override taking precedence, and absence of the field when no tenant is configured.

## **11.2 SSE parser tests**

The parser is tested in isolation against synthetic byte streams, since these edge cases are difficult to trigger reliably against a live server:

> * Single-line data payload  
> * Multi-line data payload split across several data: lines  
> * CRLF line terminators as well as LF  
> * Comment lines interleaved as keep-alive heartbeats  
> * event:, id:, and retry: lines present and correctly ignored  
> * A JSON payload split across two byte chunks mid-token, verifying the buffer handles partial reads  
> * Terminal status event closing the stream, with the terminal event itself still delivered to the caller  
> * lastChunk: true on an artifact event not closing the stream  
> * Interrupted states not closing the stream  
> * Abrupt connection close mid-event, asserting a clean error rather than a hang  
> * Ten artifact chunks delivered in order, asserting order is preserved

## **11.3 Interoperability tests**

These are the tests that actually validate specification compliance. Testing only against our own mocks would validate our own misreadings of the specification, so the primary targets are third-party reference implementations.

| Scenario | Reference server | Validates |
| :---- | :---- | :---- |
| Card discovery | Python hello-world | well-known path, card parsing |
| Sync single turn | Python hello-world | sendMessage returning Task |
| Direct message reply | Python hello-world | sendMessage returning Message |
| Streaming | Python streaming agent | SSE parse, both event types, ordering |
| Chunked artifacts | Python streaming agent | append and lastChunk handling |
| Stream reconnect | Python streaming agent | subscribeToTask after forced drop |
| Polling | Python hello-world | returnImmediately then getTask |
| Cancellation | Python long-running agent | cancelTask mid-execution |
| Multi-turn | Python human-in-the-loop | input-required, contextId, taskId |
| Rich field tolerance | Java SDK reference | open records with provider, signatures |
| Error responses | Python hello-world | typed error mapping |

The Java reference server is a deliberate secondary target because it emits a richer field set than the Python samples — including provider, signatures, and populated securitySchemes — which exercises open-record tolerance against fields the Python samples never send.

## **11.4 Definition of done for Phase 1**

Phase 1 is complete when every scenario in the interoperability table passes against live reference servers, the SSE parser passes every edge case in section 12.2, and the full unit test suite passes. At that point the data model and wire format are proven correct against third-party implementations, and Phase 2 server work can proceed on a validated foundation.

# ---

# **12\. Open questions and known gaps**

## **12.1 Known simplifications**

> * **securitySchemes typing.** Typed as map\<json\> rather than a modelled union of the five scheme shapes. Consequence: no automatic client configuration from a fetched Agent Card. Deferred to a follow-up.  
> * **Agent Card signature verification.** The signatures field is captured but never verified. A malicious actor could serve a forged card. Deferred pending a security review and crypto integration.  
> * **Agent Card caching.** resolveAgentCard fetches on every call with no cache and no respect for HTTP cache headers. Acceptable for Phase 1 where discovery happens once at startup; worth revisiting if discovery becomes a hot path.  
> * **listTasks not implemented.** The specification defines a tasks/list operation with filtering and cursor pagination. Omitted from Phase 1 as it is not required for the core call-and-respond flow.  
> * **Single protocol binding.** Only the JSON-RPC binding is implemented. Agents exposing only gRPC or HTTP+JSON/REST cannot be reached. AgentInterface.protocolBinding is captured in the data model so a client can at least detect this and fail with a clear message.  
> * **No automatic reconnection.** subscribeToTask enables manual recovery from a dropped stream, but the client does not detect drops or reconnect on its own. The caller implements the retry policy.

## **12.2 Deliberately deferred to Phase 2**

> * a2a:Listener, service object contract, and task handler pattern  
> * TaskStore interface and in-memory default  
> * Agent Card and skills authoring guide  
> * Push notification webhook receiver  
> * extendedAgentCard retrieval  
> * A Ballerina-native equivalent of the emitter pattern for server-side streaming

---

*Phase 1 Client Technical Design. Specification-verified against A2A Protocol v1.0.0. Three implementation questions in section 12.1 require confirmation before coding begins; everything else is settled and ready to build.*

---

> ⚠️ **SUPERSEDED — do not implement from this section.**
>
> Everything from here down to "Task Delegation Lifecycle" below is an
> earlier, unversioned draft of this design, superseded by the
> "Phase 1: Client Technical Design" section above. It disagrees with
> the Phase 1 draft in at least three confirmed places, independently
> verified against the live A2A spec
> (https://a2a-protocol.org/latest/specification/) — the Phase 1 draft
> is correct in all three:
>
> - **`AgentInterface.tenant`** — this draft's `AgentInterface` omits the
>   `tenant` field entirely; Phase 1 §3.2 includes it, and the client's
>   tenant-routing design (§9.4) depends on it.
> - **`AgentProvider.url`** — this draft makes it optional
>   (`string? url?`); Phase 1 §3.2 makes it required (`string url`).
> - **`TaskArtifactUpdateEvent.index`** — this draft still carries an
>   `index` field; Phase 1 §3.5 contains an explicit correction note
>   removing it, since specification §4.2.2 defines no such field.
>
> This section also sketches Phase 2 (Listener/service) material that is
> out of scope for Phase 1 regardless of the above. Kept here for
> historical reference only — always implement from the Phase 1 section
> above, per `a2a/CLAUDE.md`.

---

# A2A Library for Ballerina — Technical Design1

**A2A Library for Ballerina — Technical Design**1\. Scope & recap

The design outline proposed an A2A library for Ballerina with three public surfaces: a2a:Client (outbound calls to other agents), a2a:Listener (hosting an A2A-reachable agent).This document picks up from that conclusion and works through how each piece is actually built.

* In scope: module layout, the core data model, client design, listener/service design and the task lifecycle, the task store, transport/streaming mechanics, and security configuration.

* Out of scope (carried over from the outline's open questions): automatic name-based task dispatch, a hardened mTLS implementation, a persistent (non-in-memory) task store implementation, and Choreo agent-directory integration. Each is restated under Open Questions (11) with what would need to happen to unblock it.

# **2\. Module layout**

Proposed package: ballerina/a2a, mirroring the file-per-concern convention already used in ballerina/mcp so the two agent-protocol libraries read consistently.

```
ballerina/a2a/
  types.bal       — AgentCard, AgentSkill, Message, Part,
                    Task, TaskStatus, Artifact,
                    TaskStatusUpdateEvent, TaskArtifactUpdateEvent
  client.bal      — a2a:Client class
  listener.bal    — a2a:Listener class + service-object contract
  task_store.bal  — TaskStore interface + InMemoryTaskStore default
  errors.bal      — a2a:Error subtypes, mapped to JSON-RPC error codes
  modules/
  	transport/      — internal JSON-RPC ↔ SSE plumbing (not exported)
	  jsonrpc.bal
	  sse.bal
```

*What this shows: each file owns one concern, and TaskStore is the only piece adopters are meant to extend themselves.*

* **Task, Client,** and **Listener** are marked **public** in the package's default module that's the supported surface. **Wire-format** and **transport** internals live in the transport submodule and aren't part of the supported API

* TaskStore is the one extension point exposed for production use — everything else in the module is consumed as-is.

# **3\. Core data model**

These mirror the A2A spec's JSON objects field-for-field, expressed as Ballerina records:

```
public type AgentCard record {
    string name;
    string description;
    string version;
    string url;
    AgentProvider? provider?;
    string? documentationUrl?;
    string? iconUrl?;
    AgentCapabilities capabilities;
    AgentInterface[] supportedInterfaces = [];
    map<json> securitySchemes = {};
    json[] security = [];
    string[] defaultInputModes = ["text"];
    string[] defaultOutputModes = ["text"];
    AgentSkill[] skills;
    json[] signatures = [];
    json...;
};
 
public type AgentSkill record {
    string id;
    string name;
    string description;
    string[] tags = [];
    string[] inputModes = [];
    string[] outputModes = [];
    string[] examples = [];
    json...;
};

public type AgentExtension record {
    string uri;
    string? description?;
    boolean required = false;
    json...;
};

public type AgentCapabilities record {
    boolean streaming = false;
    boolean pushNotifications = false;
    boolean stateTransitionHistory = false;
    boolean extendedAgentCard = false;
    AgentExtension[] extensions = [];
    json...;
};

public type AgentProvider record {
    string organization;
    string? url?;
    string? contactEmail?;
    json...;
};

public type AgentInterface record {
    string url;
    string protocolBinding;
    string? protocolVersion?;
    json...;
};

```

*AgentCard is the document other agents fetch to learn what this agent can do; each AgentSkill in it is one capability they're allowed to invoke.*

```
public enum Role {
    ROLE_UNSPECIFIED,
    ROLE_USER,
    ROLE_AGENT
};

public type Message record {
    string messageId;
    Role role;
    Part[] parts;
    string? contextId?;
    string? taskId?;
    string[] referenceTaskIds = [];
    string[] extensions = [];
    map<json>? metadata?;
    json...;
};

public type Part record {
    string? text?;
    string? url?;
    byte[]? raw?;
    string? filename?;
    string? mediaType?;
    json? data?;
    map<json>? metadata?;
    json...;
};
```

*Message is one turn in the exchange; Part is the union type holding its actual content — plain text, file bytes, or structured data.*

```
public type Task record {
    string id;
    string? contextId?;
    TaskStatus status;
    Message[] history = [];
    Artifact[] artifacts = [];
    map<json>? metadata?;
    json...;
};
 
public enum TaskState {
    TASK_STATE_UNSPECIFIED,
    TASK_STATE_SUBMITTED,
    TASK_STATE_WORKING,
    TASK_STATE_INPUT_REQUIRED,
    TASK_STATE_COMPLETED,
    TASK_STATE_FAILED,
    TASK_STATE_CANCELED,
    TASK_STATE_REJECTED,
    TASK_STATE_AUTH_REQUIRED
}

public type TaskStatus record {
    TaskState state;
    Message? message?;      
    string? timestamp?;
    json...;
};
 
public type Artifact record {
    string artifactId;
    string? name?;
    string? description?;
    Part[] parts;
    map<json>? metadata?;
    string[] extensions = [];
    json...;
};
 
public type TaskStatusUpdateEvent record {
    string taskId;
    string contextId;
    TaskStatus status;
    json...;
};

public type TaskArtifactUpdateEvent record {
    string taskId;
    string contextId;
    Artifact artifact;
    int index = 0;
    boolean append = false;
    boolean lastChunk = false;
    json...;
};
```

*Task is the unit of work and its full history; TaskStatus tracks where it sits in the lifecycle (5); TaskStatusUpdateEvent carries a state change, TaskArtifactUpdateEvent carries a new or updated* 

*artifact — the two are kept separate because artifact streaming supports chunked delivery (index, append, lastChunk) which has no equivalent in a status update.*

# **4\. Client design**

## **Configuration**

```
public type ClientConfig record {|
    *http:ClientConfiguration; 
|};
 
a2a:Client a2aClient= check new ("https://partner-agent/a2a", clientConfig);
```

*ClientConfig includes the full http:ClientConfiguration surface — auth, TLS, retry, circuit breaking, proxy, and more — so a2a:Client inherits the complete HTTP connector story rather than maintaining a hand-picked subset. If A2A-specific auth scheme restrictions are needed, the auth field can be narrowed in a follow-up (see 11).*

## **Methods**

```
// 1. Synchronous send — blocks until the task reaches a terminal state
a2a:Task task = check a2aClient->sendMessage(message);
 
// 2. Streaming send — yields status and artifact events as the remote agent works stream<a2a:TaskStatusUpdateEvent|a2a:TaskArtifactUpdateEvent, error?> updates = 
    check a2aClient->sendMessageStream(message);
check from a2a:TaskStatusUpdateEvent|a2a:TaskArtifactUpdateEvent event in updates
   do {
       if event is a2a:TaskStatusUpdateEvent {
           io:println(`task ${event.taskId} -> ${event.status.state}`);
       } else {
           io:println(`task ${event.taskId} -> artifact received (index:
     ${event.index})`);
       }
   };
 
// 3. Poll / fetch a task by id
a2a:Task current = check a2aClient->getTask(taskId);
 
// 4. Cancel an in-flight task
check a2aClient->cancelTask(taskId);
```

*The four things a caller can do with a remote agent: send and wait, send and stream updates as they happen, check on a task later, or cancel it.*

## **Wire mapping**

**Client method — JSON-RPC method — Transport**  
sendMessage — message/send — HTTP POST, single JSON response  
sendMessageStream — message/stream — HTTP POST, Server-Sent Events  
getTask — tasks/get — HTTP POST, single JSON response  
cancelTask — tasks/cancel — HTTP POST, single JSON response

# **5\. Listener & service design**

```
// Helper — pulls plain text content from a Message's Part list
function extractText(a2a:Message msg) returns string =>
    string:'join(" ", ...from a2a:Part p in msg.parts
        where p.text is string
        select p.text ?: "");


```

*What this helper does: iterates through a Message's Part list to concatenate all available text segments. This allows the **onTask** implementation to convert incoming structured payloads into a single string for **ai:Agent** consumption.*

```
// Agent Card declared manually in agent_card.bal — see §6
// Skills declared separately in skills.bal — referenced here, not redeclared
final ai:Agent myAiAgent = check new ({...});
listener a2a:Listener a2aEp = new (9090, agentCard = agentCard, taskStore = store);


service /a2a on a2aEp {
    remote function onTask(a2a:Task task) returns a2a:Task|error {
        a2a:Message[] history = task.history;
        if history.length() == 0 {
            return error a2a:InvalidParamsError("Task has no message to act on");
        }
        a2a:Message latest = history[history.length() - 1];
        string userText = extractText(latest);   // "What's the weather in Colombo?"

        // Same ai:Agent instance the AgentCard's skills were derived from —
        // it internally decides to call getWeather("Colombo") and composes a reply
        string aiReply = check myAiAgent.run(userText);

        task.status.state = a2a:TASK_STATE_COMPLETED;
        task.artifacts.push({
            artifactId: uuid:createType4AsString(),
            parts: [{ text: aiReply }]   // e.g. "It's 29°C and partly cloudy in Colombo."
        });
        return task;
    }

    remote function onCancel(string taskId) returns error? {
    }
}
```

*The listener receives a manually constructed AgentCard (see 6 for the full template) and the same ai:Agent instance that onTask will call into. The capabilities advertised on the card and the agent actually answering requests are the same object — keeping them consistent is the developer's responsibility, supported by the file conventions and startup validation in 6\.*

The listener owns the task lifecycle; a service only ever reacts to it. The state machine it enforces:

![][image1]

*Figure 1 — task states are owned by the Listener, not by the developer's onTask implementation; onTask returns a result, the Listener applies the corresponding transition.*

Internally, the Listener maps whatever **onTask** returns onto that state machine: an error becomes **failed**; a returned task already in **input-required** state is passed through unchanged, so the caller can supply more input before the task continues; anything else is marked **completed**. Each transition is persisted via the **TaskStore** and emitted as a TaskStatusUpdateEvent or TaskArtifactUpdateEvent to any open SSE subscribers on that task.

How a developer actually signals **input-required** from inside **onTask** — and how a follow-up message resumes that same task — isn't yet worked out; see section 11\.

![][image2]

*Figure 2 — a single inbound message, traced end to end through the Listener, Task Store, and developer-supplied Task Handler.*

# **6\. Agent Card and Skills — Developer guide**

Developers manually declare Agent Cards and skills, maintaining consistency with the Java, Python, and TypeScript SDKs. Automated derivation from internal tool implementations is avoided because skills define the agent’s public contract, whereas tools are private implementation details. This decoupling ensures that the mapping between the two is driven by developer intent rather than code structure; a single tool can fulfill multiple skills without risking unsafe inference by the library.

The library facilitates this process through specific file conventions, templates, and startup validation to ensure consistency across implementations.

---

## **Recommended file structure**

```
myagent/
  skills.bal        — AgentSkill[] declared once, owned here
  agent_card.bal    — AgentCard constructed here, references skills.bal
  agent.bal         — ai:Agent + @ai:AgentTool functions
  service.bal       — service /a2a on ep { onTask(...) }
```

*Skills and tools are maintained in separate files to eliminate coupling. The skill represents the public-facing contract, while tools remain internal implementation details. Modifying a tool function does not trigger a skill update; developers must update skills.bal intentionally to reflect capability changes.*

---

## **Template — skills.bal**

ballerina

```
// skills.bal
// Declare the skills this agent exposes to other A2A agents.
// Each skill is one coarse, externally-facing capability.
// Multiple internal tools may serve one skill — that is intentional.
// Define skills here once. Reference in agent_card.bal. Never redeclare.

import ballerinax/a2a;

public final a2a:AgentSkill[] agentSkills = [
    {
        id: "skill-id",         // unique, kebab-case — used for routing
        name: "Skill Name",     // human-readable, shown during discovery
        description: "What this skill does — be specific, this is what
                       other agents read to decide whether to route work here",
        tags: ["tag1", "tag2"],
        inputModes: ["text"],   // "text" | "file" | "data"
        outputModes: ["text"],
        examples: [             // sample prompts — orchestrators use these
            "Example request 1",
            "Example request 2"
        ]
    }
    // add more skills here if the agent offers multiple capabilities
];
```

---

## **Template — agent\_card.bal**

ballerina

```
// agent_card.bal
// The Agent Card is the public document other agents fetch to discover
// what this agent can do. Skills are referenced from skills.bal —
// never redeclared here. Change a skill once in skills.bal;
// the card reflects it automatically.

import ballerinax/a2a;

public final a2a:AgentCard agentCard = {
    name: "Your Agent Name",
    description: "What your agent does — concise and clear",
    version: "1.0.0",
    url: "https://your-agent-host/a2a",
    capabilities: {
        streaming: false,              // set true only if you handle sendMessageStream
        pushNotifications: false,      // leave false — not yet supported
        stateTransitionHistory: false, // leave false — not yet supported
        extendedAgentCard: false       // leave false — not yet supported
    },
    skills: agentSkills                // reference from skills.bal — not redeclared
};
```

---

## **Worked example — weather agent**

ballerina

```
// skills.bal
import ballerinax/a2a;

public final a2a:AgentSkill[] agentSkills = [
    {
        id: "weather-current",
        name: "Current Weather",
        description: "Gets current weather conditions for any city",
        tags: ["weather", "current"],
        inputModes: ["text"],
        outputModes: ["text"],
        examples: [
            "What's the weather in Colombo?",
            "Is it raining in London right now?"
        ]
    },
    {
        id: "weather-forecast",
        name: "Weather Forecast",
        description: "Gets multi-day weather forecasts for any city",
        tags: ["weather", "forecast"],
        inputModes: ["text"],
        outputModes: ["text"],
        examples: [
            "Will it rain in Colombo this week?",
            "What's the 5-day forecast for Tokyo?"
        ]
    }
];
```

ballerina

```
// agent_card.bal
import ballerinax/a2a;

public final a2a:AgentCard agentCard = {
    name: "Weather Assistant",
    description: "Provides current weather and forecasts for any city worldwide",
    version: "1.0.0",
    url: "https://weather-agent.example.com/a2a",
    capabilities: {
        streaming: false,
        pushNotifications: false,
        stateTransitionHistory: false,
        extendedAgentCard: false
    },
    skills: agentSkills
};
```

ballerina

```
// service.bal — card passed directly to listener
listener a2a:Listener ep = new (9090, agentCard = agentCard);
```

*This pattern uses skills declared once in skills.bal, which are then referenced by the card and consumed by the listener. By centralizing skill descriptions, changes can be managed in a single line without requiring additional updates throughout the codebase.*

---

## **Five rules for developers**

1. **Skills define the public contract, not the implementation.** Name skills based on the capabilities offered to external callers rather than internal function names. For instance, a skill named `getWeather` that mirrors a function of the same name should be avoided; focus on the capability itself.  
2. **Declare skills once in skills.bal and reference them.** Avoid duplicating skill definitions within agent\_card.bal. Centralized updates ensure that modifications to skill descriptions propagate automatically to the card.  
3. **Maintain decoupling between skills and tools.** Changes to private implementation details, such as renaming or altering tool functions, should not impact public-facing skills. Skills serve as a stable interface, while tools remain flexible.  
4. **Capabilities flags represent a public promise.** Set flags to `true` only when the library explicitly supports the feature. Currently, only `streaming` is fully implemented; the listener will issue warnings for unsupported flags like `pushNotifications`.  
5. **One card per listener.** Provide the Agent Card to the listener constructor. The listener handles the automated serving of the card at `/.well-known/agent-card.json`, removing the need for manual endpoint configuration.

# **7\. Task store**

```
public type ErrorDetail record {
    string message;
    error cause?;
};

public type TaskNotFoundError error<ErrorDetail>;
public type InvalidParamsError error<ErrorDetail>;
public type UnsupportedOperationError error<ErrorDetail>;
public type InternalError error<ErrorDetail>;

public type TaskStore object {
    function save(Task task) returns error?;
    function get(string taskId) returns Task|TaskNotFoundError;
    function update(Task task) returns error?;
    function delete(string taskId) returns error?;
};

// default, used when no taskStore is supplied to the Listener
class InMemoryTaskStore {
    private map<Task> tasks = {};
    function save(Task task) returns error? { self.tasks[task.id] = task; }
    function get(string taskId) returns Task|TaskNotFoundError =>
        self.tasks[taskId] ?: error TaskNotFoundError(`Task ${taskId} not found`);
    function update(Task task) returns error? { self.tasks[task.id] = task; }
    function delete(string taskId) returns error? { _ = self.tasks.remove(taskId); }}
```

*The contract any storage backend has to satisfy, and the simple map-backed version used until a persistent one is actually needed.*

A persistent implementation (Redis, a relational table, etc.) is just another type satisfying TaskStore — not part of this phase, but the interface is shaped so adding one later doesn't touch the Listener or Client at all.

# **8\. Transport & streaming details**

## **JSON-RPC error mapping**

**Internal a2a:Error — JSON-RPC error code — Meaning**  
TaskNotFoundError — \-32001 — Unknown task id  
InvalidParamsError — \-32602 — Malformed message/params  
UnsupportedOperationError — \-32004 — Skill/modality not supported  
InternalError — \-32603 — Unhandled error in onTask

## **SSE event loop (listener side)**

```
function streamTask(http:Caller caller, string taskId) {
    foreach TaskStatusUpdateEvent|TaskArtifactUpdateEvent event
            in subscribeTo(taskId) {
        caller->writeSseEvent(event.toJson());
        if event is TaskStatusUpdateEvent &&
           (event.status.state == TASK_STATE_COMPLETED ||
            event.status.state == TASK_STATE_FAILED ||
            event.status.state == TASK_STATE_CANCELED ||
            event.status.state == TASK_STATE_REJECTED) {
            break;   // close the stream on terminal state
        }
    }
}
```

*How an open stream gets fed: status changes and artifact updates are pushed as separate event types — the stream closes only when a TaskStatusUpdateEvent carries a terminal state, since TaskArtifactUpdateEvents never signal completion on their own.*

## **Push notifications**

Push notifications (webhook-based delivery) are deferred to a later phase — see §11. The synchronous (sendMessage) and streaming (sendMessageStream) paths cover the primary communication patterns for this phase. 

# **9\. Security**

```
// stubbed only — interface shape reserved, not hardened this phase
public type MtlsConfig record {|
    crypto:KeyStore keyStore;
    crypto:TrustStore trustStore;
|};
```

*Securing **a2a:Client** leverages the existing **http:ClientConfiguration** surface, ensuring that OAuth2, API keys, and bearer tokens are supported via the standard **http:ClientAuthConfig** integration (4). This avoids defining redundant A2A-specific authentication mechanisms. While **mTLS** remains in scope, it is currently limited to a reserved interface stub and is not hardened for this phase (11).*

# **10\. Testing & interop strategy**

* Unit tests per module: data-model (de)serialization round-trips against real A2A JSON fixtures, Listener state-machine transitions, TaskStore default implementation.

* Agent Card validation test: validate manually constructed AgentCards from representative sample agents against the A2A AgentCard JSON Schema directly — confirms that hand-authored cards are spec-compliant and that all required fields are present and correctly typed. Also verifies that capabilities flags set to true are backed by corresponding listener behavior.

* Interop tests: point a2a:Client at one of the public A2A reference sample agents (e.g. the Python SDK's sample agents) and vice versa — host a Ballerina agent and call it from the reference Python client. This is the real test of spec compliance; testing only against ourselves would let us validate our own misreadings of the spec.

* Streaming/cancellation tests run against a slow fake handler to exercise input-required and cancel-mid-task paths, which are easy to under-test otherwise.

# **1 1\. Open questions**

* **Dynamic task dispatch:** Investigation needed to determine if Ballerina can natively invoke functions via string-based skill IDs or if a Java interop bridge is required. Until this feasibility spike is resolved, **onTask** remains a manual developer-wired process.

* **Persistent TaskStore:** A reference implementation for non-in-memory storage (Redis/SQL) is deferred until a concrete use case requires task history to survive restarts. The current interface is designed to support this transition without requiring consumer rework.

* **mTLS hardening:** While the interface is reserved (9), the implementation is currently out of scope. A formal security review is required before moving beyond the existing stub.

* **Multi-turn input flow:** The mechanism for signaling **input-required** from within **onTask**, and the subsequent resumption of that task by the caller, lacks a final design. The state is represented in the lifecycle (5) but the developer-facing API is not yet defined.

* **Push notifications:** Webhook-based delivery is deferred. This requires a separate design pass for endpoint registration, retry logic, and security handling, none of which is addressed in the current phase.

* **AgentEmitter concept:** The synchronous return of **onTask** prevents intermediate artifact emission. A Ballerina-native equivalent to the Java SDK's AgentEmitter—expressed via concurrency and stream primitives—

* **Auth scheme narrowing:** While the full **http:ClientAuthConfig** surface is inherited (4), it remains to be decided if this should be restricted to a specific A2A-appropriate subset or left as-is for maximum flexibility.

# **12\. Pending decisions — needed before proposal is final**

The following design choices require formal team sign-off prior to the completion of the implementation phase:

6. **Agent Card construction (6):** Manual declaration of skills and cards is confirmed to maintain SDK parity. The library provides templates and validation instead of automated tool derivation.   
7. **Streaming control (11):** The current model's inability to emit real-time updates necessitates a native emitter pattern.  
8. **Object formalization:** Evaluating the elevation of **a2a:Client** and **a2a:Listener** to proper Ballerina objects for enhanced visibility and compiler-enforced contracts.

# **Gaps vs other SDKs — Priority Backlog**

* **Push notifications (🔴 Critical):** Deferred. This subsystem represents a major gap and requires a full registration architecture and delivery handling to reach parity with reference SDKs.

* **Real-time streaming (🔴 Critical):** Absence of the AgentEmitter concept blocks support for chunked artifacts and granular status updates during execution.

* **State history (🟡 Medium):** Implementation of underlying endpoints is pending; currently, the Listener issues warnings if this capability is enabled.

* **Extended Agent Card (🟡 Medium):** Design for this endpoint is pending. Requires a stub and auth enforcement similar to the Java implementation.

* **Discovery utility (🟡 Medium):** Decision required on implementing **resolveAgentCard** for automated fetching vs. maintaining the current direct URL approach.

* **Stream resiliency (🟡 Medium):** A **subscribeToTask** method is needed to handle reconnections, as dropped SSE events are currently treated as terminal.

* **Context threading (🟡 Medium):** Propagation logic for **contextId** is needed within the listener to support multi-turn agent correlation.

# **Future roadmap — Out of scope**

9. **Alternate Transports:** gRPC and REST support are deferred due to implementation overhead.  
10. **A2A v0.3 Compatibility:** Backward compatibility modules are not planned for this phase.  
11. **Cryptographic Signing:** JWS verification for Agent Cards is deferred pending security review.  
12. **Observability:** OpenTelemetry integration remains a requirement for future production releases but is currently deferred.

> ⚠️ **End of superseded section.** The walkthrough below has not been
> checked against the Phase 1 draft the way the three disagreements
> above were — treat it as illustrative narrative, not a source to
> implement types or code from.

# Task Delegation Lifecycle

# A2A Client — Task Delegation Lifecycle

How a Ballerina agent delegates a task to a remote A2A agent, end to end. Eight stages, in order: the agent is discovered, a client is built, a task is opened as a stream, the stream delivers status and artifact events as the remote agent works, and the task ends either by pausing for clarification or by reaching a terminal state. Each stage below pairs what happens on the wire with the `a2a:Client` code that produces it.

---

## Step 1 — Discover the remote agent

**What happens:** a plain `GET` to the agent's well-known endpoint, before any client exists. The response is parsed into an `AgentCard`, which is the only source of truth for whether streaming is even legal to attempt.

```
a2a:AgentCard card = check a2a:resolveAgentCard("https://research-agent.example.com");

if !card.capabilities.streaming {
    return error("This agent doesn't support streaming — fall back to sendMessage");
}
```

`resolveAgentCard` opens its own short-lived `http:Client` internally — it does not require (or reuse) the `a2a:Client` you're about to construct in Step 2\.

---

## Step 2 — Construct the client

**What happens:** the primary endpoint — `supportedInterfaces[0].url`, via the `primaryUrl()` helper, not the discovery URL — becomes the base for every subsequent call. Auth, TLS, retry, and timeout all flow through the standard `http:ClientConfiguration` — there's no A2A-specific auth type.

```
a2a:Client researchClient = check new (
    check a2a:primaryUrl(card),
    {auth: {token: check getResearchAgentToken()}}
);
```

---

## Step 3 — Send the task and open the stream

**What happens:** `sendMessageStream` builds a JSON-RPC `SendStreamingMessage` request, sets `Accept: text/event-stream`, and returns a live `stream<StreamResponse, error?>` the moment the connection opens — it does not wait for the task to finish.

```
a2a:Message msg = {
    messageId: uuid:createType4AsString(),
    role: a2a:ROLE_USER,
    parts: [{text: "Advances in surface-code quantum error correction, 2024"}]
};

stream<a2a:StreamResponse, error?> updates = check researchClient->sendMessageStream(msg);
```

---

## Step 4 — Handle the initial `Task` event

**What happens:** the first item on the stream is always the newly created `Task`, carrying the server-generated `taskId` and `contextId`. Both need to be captured now — they're required to resume the conversation later if the task pauses.

```
string? activeTaskId = ();
string? activeContextId = ();

check from a2a:StreamResponse event in updates
    do {
        if event.task is a2a:Task {
            a2a:Task t = <a2a:Task>event.task;
            activeTaskId = t.id;
            activeContextId = t.contextId;
            io:println("Task created: ", t.id);
        }
        // status/artifact handling continues below — same loop
    };
```

---

## Step 5 — Handle streaming status updates

**What happens:** each `TaskStatusUpdateEvent` reports a lifecycle transition (`SUBMITTED` → `WORKING` → ...). Four states are terminal (`COMPLETED`, `FAILED`, `CANCELED`, `REJECTED`); two are interrupted (`INPUT_REQUIRED`, `AUTH_REQUIRED`) and don't end the conversation, just this stream.

```
a2a:Message? clarificationPrompt = ();

// inside the same loop as Step 4:
else if event.statusUpdate is a2a:TaskStatusUpdateEvent {
    a2a:TaskStatusUpdateEvent su = <a2a:TaskStatusUpdateEvent>event.statusUpdate;
    io:println("Status: ", su.status.state);
    if su.status.state == a2a:TASK_STATE_INPUT_REQUIRED {
        clarificationPrompt = su.status?.message;
    }
}
```

---

## Step 6 — Handle streaming artifact updates (chunked)

**What happens:** report content arrives as `TaskArtifactUpdateEvent` frames, keyed by `artifactId`. `append: true` means "concatenate onto what you already have for this artifact"; `lastChunk: true` marks the end of *that artifact*, not the end of the task — more artifacts, or more status updates, can still follow.

```
map<string> reportChunks = {};

// inside the same loop as Steps 4–5:
else if event.artifactUpdate is a2a:TaskArtifactUpdateEvent {
    a2a:TaskArtifactUpdateEvent au = <a2a:TaskArtifactUpdateEvent>event.artifactUpdate;
    string existing = reportChunks[au.artifact.artifactId] ?: "";
    reportChunks[au.artifact.artifactId] =
        au.append ? existing + extractArtifactText(au.artifact) : extractArtifactText(au.artifact);
    if au.lastChunk {
        io:println("--- artifact '", au.artifact.artifactId, "' complete ---");
    }
}
```

---

## Step 7 — Resume on `INPUT_REQUIRED`

**What happens:** the stream from Step 3 has now ended (server closed the connection). If it ended because of `INPUT_REQUIRED`, this is **not** a new conversation — the same `taskId` and `contextId` from Step 4 are threaded into a fresh `sendMessageStream` call, and the whole loop (Steps 4–6) starts again on the new stream.

```
if clarificationPrompt is a2a:Message {
    io:println("Agent needs clarification: ", extractMessageText(clarificationPrompt));
    string answer = io:readln("Your answer > ");
    return runResearch(researchClient, answer, activeContextId, activeTaskId); // recurse
}
```

---

## Step 8 — Completion

**What happens:** the stream ended because the task hit a terminal state. Everything accumulated in `reportChunks` across every stream (including any resumptions from Step 7\) is now the final result.

```
io:println("Research complete. Report sections:");
foreach [string, string] [artifactId, text] in reportChunks.entries() {
    io:println("=== ", artifactId, " ===\n", text);
}
```

---

## Full assembled function

Steps 3–8 combined into one recursive function, as it would actually ship:

```
function runResearch(a2a:Client researchClient, string topic,
        string? contextId, string? taskId) returns error? {
    a2a:Message msg = {
        messageId: uuid:createType4AsString(),
        role: a2a:ROLE_USER,
        contextId: contextId,
        taskId: taskId,
        parts: [{text: topic}]
    };

    stream<a2a:StreamResponse, error?> updates = check researchClient->sendMessageStream(msg);

    map<string> reportChunks = {};
    string? activeTaskId = taskId;
    string? activeContextId = contextId;
    a2a:Message? clarificationPrompt = ();

    check from a2a:StreamResponse event in updates
        do {
            if event.task is a2a:Task {
                a2a:Task t = <a2a:Task>event.task;
                activeTaskId = t.id;
                activeContextId = t.contextId;
                io:println("Task created: ", t.id);
            } else if event.statusUpdate is a2a:TaskStatusUpdateEvent {
                a2a:TaskStatusUpdateEvent su = <a2a:TaskStatusUpdateEvent>event.statusUpdate;
                io:println("Status: ", su.status.state);
                if su.status.state == a2a:TASK_STATE_INPUT_REQUIRED {
                    clarificationPrompt = su.status?.message;
                }
            } else if event.artifactUpdate is a2a:TaskArtifactUpdateEvent {
                a2a:TaskArtifactUpdateEvent au = <a2a:TaskArtifactUpdateEvent>event.artifactUpdate;
                string existing = reportChunks[au.artifact.artifactId] ?: "";
                reportChunks[au.artifact.artifactId] =
                    au.append ? existing + extractArtifactText(au.artifact) : extractArtifactText(au.artifact);
                if au.lastChunk {
                    io:println("--- artifact '", au.artifact.artifactId, "' complete ---");
                }
            }
        };

    if clarificationPrompt is a2a:Message {
        io:println("Agent needs clarification: ", extractMessageText(clarificationPrompt));
        string answer = io:readln("Your answer > ");
        return runResearch(researchClient, answer, activeContextId, activeTaskId);
    }

    io:println("Research complete. Report sections:");
    foreach [string, string] [artifactId, text] in reportChunks.entries() {
        io:println("=== ", artifactId, " ===\n", text);
    }
}

function extractArtifactText(a2a:Artifact artifact) returns string {
    string[] chunks = [];
    foreach a2a:Part part in artifact.parts {
        string? t = part?.text;
        if t is string {
            chunks.push(t);
        }
    }
    return string:'join("", ...chunks);
}

function extractMessageText(a2a:Message message) returns string {
    string[] chunks = [];
    foreach a2a:Part part in message.parts {
        string? t = part?.text;
        if t is string {
            chunks.push(t);
        }
    }
    return string:'join(" ", ...chunks);
}
```

---

## Notes for review

- **Steps 4–6 are one loop, split here for exposition.** In real code, the `if`/`else if` branches on `event.task` / `event.statusUpdate` / `event.artifactUpdate` all live inside the same `check from ... do { }` block — see "Full assembled function" for the unsplit version.  
- **Step 7's recursion is a simplification.** It works for a demo but means stack depth grows with the number of clarification round trips. A production version would likely use an iterative loop instead.  
- **Optional-field access (`su.status?.message`, `part?.text`) needs a compiler check**

[image1]: <data:image/png;base64,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>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAArgAAAH/CAYAAAC8da5mAABTcElEQVR4Xu3dT6hda5rf98stpJZEFQ1R6IQEiTsIhmQgQQaBKhxkDK6ETtO6Nl22qgdqnEFhaLkxXBrcJeHbaeiOCoRUEIy66dCdIhQYuYyxBrfrTty47AIbVFRwe2BKjQeGyBqaq6EHO/mdqt+5z3nOu9b77nP22X+e9f3Ayzln/XnXn/Po3b+z1tpb762Sf/1n/2b1e996svqrX/vV1Zf/4l9a/Q9f/h9ptOOmmlBtqEZUK4eKOqfNtUOr8xf/8B+t/tav/53VX/4rv3jqWGg01YXqQ3VySBinaXOtN06/F3/QQr/4y7+y+r2//93Vy3/571b/6t//p9Wr/3dFox031YRqQzVyVCv/f80cGuqc1muHUuf//F/8cPXLf+1vrB785serP/4nP1z9s3/7H08dC42mulB9qE5UL6qbfcc4Teu13jh9HHB//Tc+Wn30975FEdGGm2pFNaPaORTUOW3dtq91/iff//ToypyCS95nGm2qqV5UN6qffcU4TVu3tcbpo4Cr1KsZeQUabaSpdvJfTvuIOqedp+1Tnb/+8z8/ukX34p/+2an9pNF6TXWj+lEd7RvGadp5Whyn39NzC7q0y19KtLM21Y5qqPUMzL6gzmnnbftU57/5dx+tvvX7/+DUPtJoo031ozraJ4zTtPO2OE6/p6Sr5xfyQjTaOk01tC9Xt1qoc9om2j7U+X94+/boFnPeNxpt3aY6Uj3tC8Zp2iaax+n39A40PaSbF6DR1mmqIdXSvqLOaZto+1DnenZSbxbK+0ajrdtUR/v0LC7jNG0TzeP0e/qYBW4H0M7bVEOqpX1FndM20fahzv/oj7+z+vjJH57aNxpt3aY6Uj3tC8Zp2iaax+n39KB5nkmjnaWplvYVdU7bVNt1nf/h//lHq//t2R+d2i8abd2mOlI97QvGadqmmmqJgEvbWNv1C/8c6py2qbbrOifg0jbVCLi0qo2AS9to2/UL/xzqnLaptus6J+DSNtUIuLSqjYBL22jb9Qv/HOqctqm26zon4NI21Qi4tKqNgEvbaNv1C/8c6py2qbbrOifg0jbVCLi0qo2AS9to2/UL/xzqnLaptus6J+DSNtUIuOPtf/mV+6v33nvvVPsv/+ubq+//+M2p5efa0//r5eq///Kd1Q9+8u7UPDf1qb61bJz+t7/5+Ghf8vJnaerb+z+yT4fUCLi0jbZdv/DPoc5pm2q7rnMCLm1TjYC7fpsKnuu0kTA5tR0C7lgj4NI22nb9wj+HOqdtqu26zgm4tE01Au76rRU89X28qut5CosKjZ6ucOrlHSa9TA6tre2o5YCrn9X3lavXVv/3n7w60Z+3G5fXMlrW01sBN++390Hr/hf/1Y2jdpYr19tsBFzaRtuuX/jnUOe0TbVd1zkBl7apRsBdv+Xg6dCnr/pZgdNBMYZRrafpMUx6Wg6xre24xT59BVbfa5qaw6n3Qcs4/LpPB+2pgOu+vA2v73Cc92kfGwGXttG26xf+OdQ5bVNt13VOwKVtqhFw129TwdMtBsV8tTUvc+d/unscNnPzdvIzv/mKrJu35YDrftXPX/jvbh8HVH3vK6/xZ+/TP/7h6xPH5/70cw7z+9wIuLSNtl2/8M+hzmmbaruucwIubVONgLt+awXc+DiAmgNunud19FU//6+/8fAo5Laee21tRy2G5vwoQQy4Xi8GXF/xHQm4OVRruzkg73Mj4NI22nb9wj+HOqdtqu26zgm4tE01Au76LQfPHBrjFdy8Xgya8XGA1lXcvB23GHD9OEScPhdwc0CdCrhePu9TXn+f284Crn9xrb925pp/AZ/+P29P/ALXadqO/mJq/fJcGPHyf/4LqbWv2g8/o5L7zMvlv4jivPMem9rUP5ZttF2/8M/ZRZ1vso3UYa/F56rcRgaskWWW1HZd54cacHMNx7ZuPecX8bnmN9Tk7VDXBNyztBw8Y8B1XbrO4uux5mt6DJNaZqoO83bcWgHXy/YCruet8wyu1vNzt1P7uo9tJwHXv4gYwvxL6g1wmwiB+gVN3RJw/2qepn3zvubi8DT1N/csjfuOITj3FYsrr7tOI+C2bbvON916dTjSWgF3pB3SoLaNtus6P9SAG5tq6jzP8uUX8amm/uMyqv9esFhSI+Cu33LwdC3qDyi9xv/W4+fHdeVl/QdWDMXx9T6G1qntuMVlvYyattvKRzHg6mcHVu3PX/+bD46WzQE3HlO8GHdI/2Z2EnBbYTYPVvoa/7rPRZF/gfEXlm8VaBDVPG9T03IhuWn63Hy1vP8OzH/wvT+d/MVPBZJYLGc5Nq2r5n9YWjYX5Dbbrl/452y7zs/apmo/t1iHeRCNg18c2FoBN9Zga1CLfbv+1q1Jzct9x/o+lI+dcdt1nVcNuKo310esnfhvwjXSes1o3UXT9FhT3u7/8d3vr1XXrdcR71N+PTukRsClVW1bD7h5UBppDn4eVHIIVIuDUQ6NcZ6+ar3Wi6iW9Yu/tpUHSi8T+9Ny8XGH2EdscZ/yvNj3eY7Nf9VxBbdtm3W+qRZrP0+fCoOaFkNtbL2A27qKkJfJ256b5/70s6ZrvqbHcaAVdPa97brOqwbc2GLttOrZNaQ36fTG1qngHGs3j9Fx/1p1Hf9dTv07PYRGwKVVbTsLuL0ApoHNA1L8C3kqBMZl4yCWBx5Nm3o8IW8z76P6ylcI9L3/4ndrBY/eYO7+z3NsBNx526zz87Rch/mFs1WHuU7y/Nh3DrD5hT1u34E0LpO3NVKTDrh5Pc3P2z+Etus6rxhw/doQ68O1GsdZ15eXV9OY7lrtNS0Xr9hO/XEWg3WrrnMtt8b9Q2gEXFrVtvWAq5b/+nXTYOZQl28P9QJuq7+8rrfdCn95sFWLL7papzWAtQJDK2BOBXv1p+keYM97bATcaduu87O0udrXz606dHjUsv65dcVLrVWvUwEz9pODwLo1ObdPU9vf57brOq8YcPPrgmsnr+fpHlNVc3M1lMfCqbrOfcT9m6rrvK1DbARcWtW2k4DrF+Q48MQX7vgiH/9Knwq4+QU+9+V11aY+PSEPrmruM4eOfBze7lxfalqu9UyiB8rzHJvnEXCnbbvOz9J6tT9Sh/rdn/UKbqwd/axt5xf/1vZ6NZm3rf60j1o+B4tDaLuu8+oB1zWmesn1oeXUYsDV9Klxz0HWP8d6bdW1+1B/+XXHdZ33PS6bt7/vjYBLq9p2EnDVPJi0bu944PKtz/iOxFYI1Dp+wYy3SzU9DkzxBTvui7eXB0cPWv/zh7966naUpv/vv/+iGTjii3c+bk1r3YKL+3qWY9PPDhP6qmXz8Wyj7fqFf84u6nzdNlf7+t226lDr+HeupmcSXT9aL145zX3kAJH/XboGPT0Gg3VqMh9brM8cYA6h7brOKwbcWHv66neE5/r2tBxwc63H5lp13661ubqOy+W69rRWn4fWCLgnW+t1U7/ri/gdH+LYpxb/GM3z3HRsU4+DbqvtLODSarZdv/DPoc5pm2q7rvMKAZe2H42A+3lTKGsFMgLuyTYScL1c6w+GbTUCLm2jbdcv/HOoc9qm2q7rnIBL21Qj4H7e4h3VeDVf0/MV/XxHIV/lj+E1372Kd2djwG3163V1Z877E0Oj9zPvX/5Yu3ic+W6J15u6gxH3TfN1ZTbvXz42b0fzdhXgCbi0jbZdv/DPoc5pm2q7rnMCLm1TjYD70+Yw5u8V8OLz2PExFj9a43Cn+ZoXH5GJj2fpq79XAPRjXTHgOlxqfuzX37e27/3UOvE58LiNfJzuz0HU+9k6ZvfX2jfPmzo2b0/zYujdZiPg0jbadv3CP4c6p22q7brOCbi0TTUC7k+bQpmuTPr7eGU1/pxvz/vKrd87o/kxRMYQquXjvNiv+4n9ar1//MPXx/16XxUa9bOXcfCNfeUrsPE4W49F5OkxSLf2TT9r36aOzf3u8jEFAi5to23XL/xzqHPaptqu65yAS9tUI+D+tDm0+ft86z4GXN+Od/Oyvhoal3fAzeto2dxvDJGe54AbQ2MMuLFPXz3NgTQfZyv85un66ivSed9ywG0dm/sl4NLKtF2/8M+hzmmbaruucwIubVONgPvTts4VXN+Sz83L6RNAvEwMilPL+6prDpGtK7i+SuqA2wqyU9PzNuemj17BnTo2NwIurUzb9Qv/HOqctqm26zon4NI21Qi4P20Kdr6CG0OkflZYbT0D63kOf14vv9kqPqeq9fw8awyVcbr7ic/gehtx+746rHW0r97HHEjzccbHCnx11ldj4zG7j7hO3p+pY4vHHn/eZiPg0jbadv3CP4c6p22q7brOCbi0TTUC7uctXpl1WFNY/et/88FRoPPVTQW2/HiC14tB09Ni8I238PNV09hvDs3aN8+LgdH7Gd/cNRdw87HlRzFa0/O+6RMd/Bm3U8em5j8a8tXibTUCLm2jbdcv/HOoc9qm2q7rnIBL21Qj4H7eFPCmQuGumgPkrq6Cnqft8vEENQIubaNt1y/8c6hz2qbaruucgEvbVCPgnmy7DGStdqgBV38s8D+Z0Uq1Xb/wz6HOaZtqu65zAi5tU42AS6vaCLi0jbZdv/DPoc5pm2q7rnMCLm1TjYBLq9oIuLSNtl2/8M+hzmmbaruucwIubVONgEur2gi4tI22Xb/wz6HOaZtqu65zAi5tU42AS6vajgLul//iX1r9q3//n07NpNHWaaoh1dK+os5pm2j7UOd/9MffWX385A9P7RuNtm5THame9gXjNG0TzeP0e3/1a7+6evkv/92pBWi0dZpqSLW0r6hz2ibaPtT5n3z/09WD3/z41L7RaOs21ZHqaV8wTtM20TxOv/d733qy+r2//91TC9Bo6zTVkGppX1HntE20fajz//D27eov/5VfPLVvNNq6TXWketoXjNO0TTSP0+/96z/7N6tf/OVf4bYA7cxNtaMaUi3tK+qcdt62T3X+m3/30epbv/8PTu0jjTbaVD+qo33COE07b4vj9HsqKiXdj/7et04tSKONNNXOrq9qjaDOaedp+1Tnr//8z4/eRPHin/7Zqf2k0XpNdaP6UR3tG8Zp2nlaHKePAq78+m98dDSDv5xoo021oppR7RwK6py2btvXOtezk7rF/Mf/5Ien9plGm2qqF9XNPj17mzFO09ZtrXH6OOCKUq8u7er5BT2kS3HRclNNqDZUI0e1sidXtNZBndN67VDq/J//ix+ufvmv/Y2jNwspuPyzf/sfTx0Ljaa6UH2oTlQvqpt9xzhN67XeOH0i4IqeW9BCegeaPmZBtzGW3P6bv/DfHrU8falNNaHaUI3sw7OIZ0Wdn2zU+cl2aHX+4h/+o9Xf+vW/c3RlLh/LUtt/dv0/PzVtqU11ofpQnRwSxunTjbH689Ybp08FXJz027/920cNqIw6RzXvvcfLG+phrB7HCNDx4sWLowZURp2jmq997Wt5EnDwGKvHEXABAABQCgEXAAAApRBwO/70T//0qAGVUeeohucUURFj9TgCbgcPdGMJqHNUw5vMUBFj9ThGgA6KCUtAnaMaAi4qYqwexwjQwe0ALAF1jmo+/vjjPAk4eIzV4wi4AAAAKIWACwAAgFIIuB3cDsASUOeohucUURFj9TgCbgcPdGMJqHNUw5vMUBFj9ThGgA6KCUtAnaMaAi4qYqwexwjQwe0ALAF1jmr4FAVUxFg9joALAACAUgi4AAAAKIWA28HtACwBdY5qeE4RFTFWjyPgdvBAN5aAOkc1vMkMFTFWj2ME6KCYsATUOaoh4KIixupxjAAd3A7AElDnqIZPUUBFjNXjCLgAAAAohYDbwV9LWALqHNVwGxcVMVaPI+B28LwLloA6RzU8g4uKGKvHMQJ0UExYAuoc1RBwURFj9ThGgA5uB2AJqHNUw5vMUBFj9TgCLgAAAEoh4AIAAKAUAm4HtwOwBNQ5quE5RVTEWD2OgNvBA91YAuoc1fAmM1TEWD2OEaCDYsISUOeohoCLihirxzECdHA7AEtAnaMaPkUBFTFWjyPgAgAAoBQCLgAAAEoh4HZwOwBLQJ2jGp5TREWM1eMIuB080I0loM5RDW8yQ0WM1eMYATooJiwBdY5qCLioiLF6HCNAB7cDsATUOarhUxRQEWP1OAIuAAAASiHgAgAAoBQCbge3A7AE1Dmq4TlFVMRYPY6A28ED3VgC6hzV8CYzVMRYPY4RoKNiMT1+/Hh1586d1du3b4++Xrt2bfXq1atTy+gFQl/3nfbxEPaz5+XLl6v79+/nyVtRsc6xbARcVMRYPY4RoKPi7YAccG/dunUiIL5792519+7d1Y0bN/Y+OCqYa1+1zxUo4CroblvFOsey8SkKqIixehwBd48p6OgqhNrNmzdXb968OZquMKdg6nkORAp7remxL12tVSCMAffhw4cnQqJDo5oD7tQ2RaHM0+MVyKnp8bhiX75q7H30Or1tx+O/ffv26sGDB8f9aJ7OXd4HLav5mj53bqeOPwZ/T4tXwtWft6v1tF+eN7Vtz6sU2AEA2AUC7p5S6ImhKN6GV1BzWFOAc7BSi8soWCkoOVBpWQc1NQfc58+fN7elPnrb1Pfejq/8zk1X05XhuC0tF6c7HHp7U9vWclrXAdHHGfc5npvcv4NxPFc+bon9T01XH95+3M/4vdaN+zy1bYnnCgAAnA0Bt2NXtwNywI3TY0ByYNXPDnISA2b8Ps5zwNXPDrMxYHna3DZz3zY1PfNyMUCKf57btvYxX3nO4TmGUp9PrRuvnGqa5uUgG01Nj+I+x9/d6LZNffh4t2VXdQ5cFJ5TREWM1eMIuB27fKBb4ce3sh0WHfh8WzzeMvcVQokB01dJ5wKuQ24MXDngtrYp+pqnzU1Xv7Ef7UO84ul1Y8BtbTuH6BwW5wJu7i8+XhD3LwbN1nRtO/bjcxiD9jrb9na2HXB3WefARdC/LaAaxupxjAAd+1JMU1cHo6mAm4NgK+BqPX2v51cdCmPAndpmFK+uTk1Xi1cwvS/5Cuno8eYruKMBN56PKVPbjtO1Dfcztc/rbpuAC5wfARcVMVaPYwTo2NXtgFZY81XQeLVTy/n52qmAq2m+ze+wqRYDrqfHq5MOuHPbjCFSffjxhqnpMeDGfdG8/IxsDNqtbTuU+5hb56wVcOP58HLep3jMsf+p6Q64c/usZaaewY3blniutmlXdQ5cFD5FARUxVo8j4O4xhR/fxlag8lW/GEbVHLymAq5/9vL+1IQYcL29GLZiqJva5nmmK/T5DW7i49U+xCvJU32JlvH+jwZcL+vHP+IjAg6g3pb7npvufdax+JzH5XUsI9v2PD5FAQCA8yHgYu840MYgO+UQAmG8at0TAzsAADgbAm4HtwO2I15hVvOV1xEKwiNheFvyFed8lXaKzsE6x71J1Dmq4TlFVMRYPY6A28ED3VgC6hzV6I9LoBrG6nGMAB0UE5aAOkc1BFxUxFg9jhGgg9sBWALqHNXwKQqoiLF6HAEXAAAApRBwD5Q/UssfS2Xx3fr5o61a7+SPH1nVenOXfs7r5Y/jmpL7bm1D38d5eVv5GPLxZn6jlrYd/zcx80ef5Te1xfbixYsTbxKLTdNfv359Yp/U4jHlfc4fvaZp+/SmOAAAqiHgduzr7YD4Ga+Rw5RDVgxS+XNuFfLyO/zVZwyRrUC2TsDNIdP75Y/CUv/xOPJn17aOYS7kal313dq25+dwmfchavWTj8GfmqCfp/Y5nvd9+9QH2dc6B86K5xRREWP1OAJux74+0N0LuL1gFkNZlKdrG/qc2djXeQKuxJCZw6W26wDbCrN5/yLN8/8CNrLtOK11LqXVTw644n5Hlt/HgLuvdQ6clf4wB6phrB7HCNCxr8XUC7jxs1hbYXAupMbA5+AWtze3bjQS9nK49M/r/GcPpu34P31obVsuIuC2/nCYOu9CwAUuHgEXFTFWj2ME6NjX2wG9gGsKWfFZUYeuuZAa+3YgjCFubt1Iy7WewY3hTv3Heb5iO3eldkoMjlPbztuXswbcuT6nzrvsY8Dd1zoHzopPUUBFjNXjCLgHajTgRjGszYXUVsAVPz6gf1xT60Y5HGr9vH9T4fIsV3DVTwzwOZh6mdzn1D5Iq598Bbcn97GPARcAgEoIuAdqKoQ6QCp85dAWr4pOXSHN02PfnqfHAM4ScEX9+Sqtf877adpuXNZikDXti5b1PrW2LRcdcHvnXQi4AABcLAJux77eDogBN37vQNgKYfo+fmpC/llaATSGMS2rdfKV2JaRcDgXLr1s3L6+b207B8vWtiUfj6dN7UOrn3wMUWtePs/7GHD3tc6Bs+I5RVTEWD2OgNuxrw90x1Ab39jUCmJ+DjSHWXFg9TI56LUC4VTIzFrhUOL6c+FS8jFMbTeHxqltt45nbh9a/bRCbJT3OZ/3vK8X5cmTJ6vPPvssT27a1zoHzkr/9oBqGKvHMQJ07GsxxYCLw7KtgHv16tXV5cuXV48ePeoG3X2tc+CsCLioiLF6HCMAUNj169ePryQr8F65cmUo8AIAcMgIuGekv6Dix0DRaPva3n///RM/66ruvXv3ckkDAFAGAbeDB7pxyEav4FLnqIbbuKiIsXocAbeD511wqJ49e3b0Bre5YGvUOarRH3VANYzV4xgBOigmHCreZIYlI+CiIsbqcYwAHdwOwKFa52PCqHNUw3/Vi4oYq8cRcAEAAFAKARcAAAClEHA7uB2AJaDOUQ3PKaIixupxBNwOHujGElDnqIY3maEixupxjAAdFBOWgDpHNQRcVMRYPY4RoIPbAVgC6hzV8CkKqIixehwBFwAAAKUQcAEAAFAKAbeD2wFYAuoc1fCcIipirB5HwO3ggW4sAXWOaniTGSpirB7HCNBBMWEJqHNUQ8BFRYzV4xgBOrgdgCWgzlENn6KAihirxxFwAQAAUAoBF8DBuXPnzurt27dHX69du7Z69erVifmPHz8+ukWtr/tO+3gI+9nz8uXL1f379/NkANgJAm4HtwOwBIdW5zHg3rp160RAfPfu3eru3burGzdu7H1wVDDXvmqfK1DAVdDdBzyniIoObazeJQJuBw90Ywkuos4VdHQVVe3mzZurN2/eHE1XmFMw9TwHIoW927dvN+fF/nTFNgbchw8fngiJDo1qDrhT2xSFMk+PVyCnpsfjyn35yrH2Udv3enH7edv5+B88eHDch+bp3OV90LKar+lz53bq+GPw9z57m74arj69be2Xp09t2/P2JbBr/4BqLmKsrooRoINiwhJsus4VemIoirfhFdQc1hTgHKocnOJyCmUKS56n5R3WHHCfP3/e3JbW721T33sbvvI7N11NV4bjtuI+ep7Dobfp7cdtaxmt64DYOv54bnLfDsbxPPm4JfY/Nd0B2vsQz1P8Pu7z1LYlnqtdI+Ciok2P1ZUxAnRwOwBLsOk6zwE3To8ByWFVP+fwGENm/F70vQOu5jnMxoDlaXPbzP3a1PQsLhdDpPjnuP18vPnKcw7PMZT6fOZQqmmal4NsNDU9i/scf38j2zat73O9S3yKAira9FhdGQEXwIVQ+PGtbIdAhz3fEo+3zHNYyuExBk59HwOuQ27sIwfc1jZFX/O0uenqN/bj/YpXPL1+DLh52zlE5+OfC7j5WOKjBXH/YtBsTXfgjn35PMawPbptb2cfAi6AZSPgArhwU1cGoxzwYgDMYTAHXK2j7/X8qkNhDLhT24zi1dWp6fkKZg7hUwG3tX39nK/gjgbceC6mTG03Ts9/OEzt8zrbJuAC2AcE3A5uB2AJNl3nrbDmq6DxSqeW87O1eZ0YpnwVVNMcOGPAjVciHa4ccOe2GUOk+vDjDVPTY8D1Nr2Pmp+fk41hWy1u26Hcx5uPfyrgxnPh5bxP8Zhj/1PTY8Cd2meZegY3blviudo1nlNERZseqysj4HbwQDeW4CLqXOHHt7EdoiSGUTUHrxzw8tVC/ex1FKJiwPX2YtiKoW5qm+eZrtDnN7jFUKp52o94NTmu575E873/+finAq6X9eMf8REBB1Dvt/sema6vOh6f8zhvZNuex6coABfnIsbqqhgBOigmLAF1vlkOtDHMtuxTIJwT/3CYEwP7rhFwURFj9ThGgA5uB2AJqPPzi1eY1Xz1tUchuBeEty1fwR555EDHP3rM28CnKKAixupxBFwAAACUQsAFAABAKQTcDm4HYAmoc1TDc4qoiLF6HAG3gwe6sQTUOarhTWaoiLF6HCNAB8WEJdh2nfvjtPyRVBY/Z1byx1vld/PHj6xqvbFLP7fWiR/HNSX33dqGvs/z8/biMeTjzfxGLW07/k9i5o8+y29oi+3Fixcn3iAWm6a/fv36xDl1i8eVz7uPx8e7b2+Ka9F+AtVse6w+ZIwAHdwOwBJsu87jZ7xGMeA6ZMUw5c+69bL5c1jVZwyRrUC2TsDNIdP75I/CUv/5OPLn18Zj0Ne5kKv11Hdr256fw2VrH6zVTz4G8acmaFreZ4mhfR8/9aGFT1FARdseqw8ZARfA1o0E3LlwFgNZlKdrG/qc2djPeQKuxJDZCpfatkNsDrR5/yLN8/8CNrLtOC3vg7X6aQVccd+tdeLyhxJwASwbARfA1o0E3PhZrDmMzYXUGPgc2uL25taNWkEvh8NWuPS00f/swbQd/6cPrW3LRQXcOG3uvAsBF8AhIOB2cDsAS7DtOh8JuHFafFZUP8+F1Ni3A2EMcHPrRlqu9QxuDHfqP8/3Fdu5q7UtMThObTtvX84acHv9xvMej+FQAi7PKaKibY/Vh4yA28ED3ViCbdf5OgE3ioFtKqS2Aq6obwVOvThMrRvlcNjat7lwue4VXPXjIJm3HZfJ/c3tQ6uf1hXcntjHoQRcBXOgmm2P1YeMEaCDYsISbLvO50KoQ6S+z8HNoXHq6mieHvv2PD0GcJaAK+rP2/fPeR8jbTsuLzHImvZFy3mfWtuWbQTc1nmP55SAC+zOtsfqQ8YI0MHtACzBtus8Btz8vQNhK4jpe926j9/3AmgMY1pW6+QrsS0j4XAuXIqX9z7oa2vbOVS2ti35eDxtah9a/eRjyFrz43k+lIDLpyigom2P1YeMgAtg62KojW9qyoHVYcvPgub5Dqyen4NeKxBOhcysFQ4lrj8XLi0ew9R2c2ic2nbreOb2odVPK8Bm+bzH9fO+7tqTJ09Wn332WZ4MYOEIuAC2LgZcHJZ9C7hXr15dXb58efXo0SOCLoBjBNwObgdgCbZd5wpIujKYn0/dpnz1N7Zd7tc+0x8lOj/7FHCfPn169HtU0L1y5cpx0OU5RVS07bH6kBFwO3igG0tAneOQXb9+/fiPEwddfc8VXVTDWD2OgNtBMWEJpupc0/LVTRptH9v7779/atq9e/dySQMHbWqsxmkEXADAwXr27FnzEQUAy0bABQAcLN5kBqCFgNvBA91YAuoch2rqY8K4jYuKGKvHEXA7eN4FS0Cdoxo9gwtUw1g9jhGgg2LCElDnqIaAi4oYq8cxAnRwOwBLQJ2jGv6rXlTEWD2OgAsAAIBSCLgAAAAohYDbwe0ALAF1jmp4ThEVMVaPI+B28EA3loA6RzW8yQwVMVaPYwTooJiwBNQ5qiHgoiLG6nGMAB3cDsASUOeohk9RQEWM1eMIuAAAACiFgAsAAIBSCLgd3A7AElDnqIbnFFERY/U4Am4HD3RjCahzVMObzFARY/U4RoAOiglLQJ2jGgIuKmKsHscI0MHtACwBdY5q+BQFVMRYPY6ACwAAgFIIuAAAACiFgNvB7QAsAXWOanhOERUxVo8j4HbwQDeWgDpHNbzJDBUxVo9jBOigmLAE1DmqIeCiIsbqcYwAHdwOwBJQ56iGT1FARYzV4wi4AAAAKIWACwAAgFIIuB3cDsASUOeohucUURFj9TgCbgcPdGMJqHNUw5vMUBFj9ThGgA6KCUtAnaMaAi4qYqwexwjQwe0ALAF1jn1x//79o3Ca282bN1dv3rzJi0/Spyiorxb1c+fOnaOvjx8/nlxuhNZVH5mmv3z5Mk8GzoWxehwBFwCwdxQ+FWrPExKngmsMnxcVcGOIBrB9BFwAwEbFq7AOf69evVrdvn37KPR53lx4bQVcfR+v6nqe+r527drRNH3Vz+Lg6vlaXt/fvXt39e7duxP9edmzbCMeo7cjmt4KvwAuHgG3g9sBWALqHJuiQOfHCXKw1PcOfAqGCrsKmi054Gr9GzduHAdL9aP13759e/TVy+mr+tZzivrqYO0rqTl0xiu4625DHHDzdtyfwzSwCYzV4wi4HTzQjSWgzrEp+Za9fnbQjOFRIXGdgJt5/Rw+zVdlFTq9TdG0uOzcIwq9bYjWffDgwantCI8pYNMYq8cRcDsoJiwBdY5NUFhVoGtdIc1XOM8ScNVPfHzA63tZTfPVYwdchU/vj/dvLuCusw0vr5/jdoyAi01jrB5HwO3gdgCWgDrHpsxdwT1PwNXXGCyn1vf03/qt3zrarpaPV1fnruCuuw1N9/Hm7QgBF5vGWD2OgAsA2BiFvalncDcVcH0lVu3169cngqWWc2D11xhi9X3rCrOcdRvuL18N5hlcYHcIuACAjYq3+R3+zhtwHTj9KQbPnz8/7k/LeHv58YG4roN2DJ1eV8uedRtTj0DkMA1gewi4HdwOwBJQ56hm7jnF/JjCReDxBFwExupxBNwOHujGElDnqEZXWqdsI3xuI0RjeRirx02PADhCMWEJqHNUMxdwgUPFWD2OEaCD2wFYAuoc1Xz88cd5EnDwGKvHEXABAABQCgEXAAAApRBwO7gdgCWgzlENzymiIsbqcQTcDh7oxhJQ56iGN5lh333729/Ok7oYq8cxAnTw1xKWgDpHNbzJDPvu+vXrR3+IfelLX1p95StfWX366ad5kVMYq8cRcAEAALbs2bNnqy9+8YvH/0PeOkEXfQRcAE0edGk0Go12Me3q1aunpl26dCkPxzgDAm4HtwOwBNQ5quE5Rey7s1zBZaweR8Dt4IFuLAF1jmoUGIB9dpZncBmrxzECdFBMWALqHNUQcLHP7t27t/q5n/u54WBrjNXjGAE6uB2AJaDOUQ2fooB9d5aPCWOsHkfABQAAQCkEXAAAAJRCwO3gdgCWgDpHNTyniIoYq8cRcDt4oBtLQJ2jGt5khooYq8cxAnRQTFgC6hzVEHBREWP1OEaADm4HYAmoc1TDpyigIsbqcQRcAAAAlELABQAAQCkE3A5uB2AJqHNUw3OKqIixehwBt4MHurEE1Dmq4U1mqIixehwjQAfFhCWgzlENARcVMVaPYwTo4HYAloA6RzV8igIqYqweR8AFAABAKQRcAAAAlELA7eB2AJaAOkc1PKeIihirxxFwO3igG0tAnaMa3mSGihirxzECdFBMWALqHNUQcFERY/U4RoAObgdgCahzVMOnKKAixupxBFwAAACUQsAFAABAKQTcDm4HYAmoc1TDc4qoiLF6HAG3gwe6sQTUOarhTWaoiLF6HCNAB8WEJaDOUQ0BFxUxVo9jBOjgdgCWgDpHNXyKAipirB5HwAUAAEApBFwAAACUQsDt4HYAloA6RzU8p4iKGKvHEXA7eKAbS0CdoxreZIaKGKvHMQJ0UExYAuoc1RBwURFj9ThGgA5uB2AJqHNUw6cooCLG6nEEXAAAAJRCwAUAAEApBNwObgdgCahz7ML9+/ePnpXN7ebNm6s3b97kxWepr8ePHx//7OcUNS32HZfR91pvX718+XLoXORjn/Pq1avV3bt3Vy9evDh13t203XWoz9u3b8/u57t371Z37tzpHs/osYwu16NjbdVGa35eRsd97dq1o+PS8ZmPVfO0jI5Xx53Ps2vP81vn3dvI62r5169fH20nz9M0zWtts7dPrX04VATcDh7oxhJQ59iluRf4UTnw6MVaYqDydrzc0gKugpfCrQJOpPXPcx5GAq6DdQyCLaPHMrrcHJ1fBz5RMMx/AMXz7+Dqc6X1bty4sbp169aJc6rvNU3zYpiM9e2+NK0137wN998aq/MyMtentOY7TE+tc2gIuB2tYgKqoc6xS60X23zlzPPiFa0YTmLg0TSvk4ObllGwiFcwY2Bx3zHYaL4Ci6Z7G5rm9aeClrYfr+45UDvcPHz48Hh7+cqg9yvuh5bxNn3scZr7iOcubr91PiQH3Hx1L86Lxx3PWwy4cZumZWLAjfvoY2wdy3mPeSoI+3eQz7uPQ03fx9AocbqXf/DgwYl+9L2meblWfYv3bWq+aP1tBVzR/rR+f4eIgNvBrVssAXWOXcovtvkF2y+6b9++Pfrq5WJgc1hw6Pjoo4+OpufAE2l5r+99cFDRdK8Xv/d6/lnbm7rq1Qu4DnbxeL0fEgOu+sqhOx+7xL7yFUd9be1n7CsHv9hfPB41Xw32Ode+uZ9Myzjg5vCobcXz7u83ccxTco1l+Xdn8fz4uJ8/f37qvGj9uYAbp7XmW97P1lidl5G5PmVqfvxdHjoCLgBgp6ZebM1hIwfcSIEmXjUzB5LW1b0YcPMLewwNcwFQYtiKckjKAbfVh/dD8j5Fcd/j9vU1bjOeu9bjCRKPL4thNB+PeT91/qf6ifubA240dS5l3WPO+xnNnVuZ6yP/rn70ox8dH4+azvNPfvKTUwHXNZivPs/Vv9ZvPYMbz3OsVZvapo9papu983JICLgAgJ1qvdjqBXzuhVnT8tU9/ZxvF2cxzMXApG3H/mIIi2EqB+ZW4LAcknLAzcer+d4PiWGjtd2psJf3Tf39+Mc/ng2Vcf+1D3H9+ChI7N/bdAjTudc+Zlou/05icIvnqHeu1znmuZDWCoVR/t1F3nb8/Wia1vHvONZPq76jufm9/ZTWMnN9ytT8/O/gkBFwO1q3A4BqqHPsUn6xzS+yU2EjTnfocLD4xje+cTQ9B4O4Tgy4+cpVDA2t0JWDQUvebwdJ95H7jKFJ4j5pXuwr7nsOezGsmtYbuYKbfxcxqEXxPOT9bJnaL5k7lvMc85z8OxDtv6bp69Rxx+nxuHUedH59TuJy+Zxmc/NzeG2N1XkZmetTpubnc37ICLgdrQe6gWqoc+xSfrGNAddBRE0ffRRDh5abCjy6iifxxdp9eZ0YjLwP7kPTvW7s2+t5Xl4v0v7lj2VSX/GY9H0MKJ4nWtbnobXN1rHnsJOPIwcaL5PPg5dTv/HNXV4uBuYY9NRi0DJN8zO4cXlRv/G8x9/jeY95Tvz9iNZx/6L+4x9auX7iceh79eXl1S4i4LbG6ryMzPUprfk+hql1Dg0Bt6P11xJQDXWOavb5v+p1UNp2kIihdNtiwMXZbXusfvTo0XHAPzQE3AYNOvl5HrV1B6P8V2rkv55azwvFv/zmjC7X0vrrTeJf6KOm+srmzof5L8h87uP52ZR8/vyi423FKwTrmHrxmpoumnaeYxzd19HlAFycubHgou0qaObxFftPvycF3ENFwJ0Rb9ucxVSgcyCMQSPeCsnBa8roci1ToXQfAm6+1XJR8vnLA/9Zw+BZXrwIuAAAbA4Bd4bCwFe/+tXj2wEOcr6qGIOgvs/Tc6DTdAWfH/zgB6dCnPvWh49rGfWTn92K/TtEeTn1qZ/dVwxurX2bCqUx4Gqe+lToy1dR4/b9V7n7ylfA9XM8BvcTr9a637mA2wqOMbDF7Wo5LR+fmZo7f9peDLjq08u7/zgtPrflaT6uvJ/6Gn9Hnh6PX/s0EnDjMXr50X3Ny8W+VC+ffPLJ8bqxtoFDlJ9TBCrY9iMKh4yAO0Mv8nrh10Dp0OIAEYOYg6ADVevB+xjEYrjKAVNiQJ3bbmu5vP7Uvo0G3BiaNN3zHNbVp5fT17h/7s/LxfORtx+XmQq4EvcvHmdcL4Zafx/3Nf7hMHoFV+vFAOpz4aAuWlYtBtx8/j3dxx/PbS/g5v319mRkX/Ny8Xx98MEHR30DVWhMAqppvckMbYwAM2LAzaZCZORAN/Xh1/EKWgy7OchEcd66ATf3MxJwY1Dy8eidzA5qEoNbFrfv9dVf7tvTtUzrGdzWPsW+Y5CO2/UHwzvUTZ0/iccuMQxmXtb7HPl86L/h9HHF6dq3eC4k/9yS9zca2VeJy8Xz9fWvf/0o5OY6AQ4VARcVEXDHMQLMUBiIjyjkQBpvUys0eLoDhMOaP/x6Lrxo2daVWZnablxuKuBKa9+0zEjAjSHIIUwfGB7XzQFX68f9dR8xxE0dUzwPLfHYYliLx+imfcxhfCrgav0cEGP/PsbYv8+TA7mP08uq+b9sjH3o5xzw47mZ45qK25PRfY3L5fP1C7/wC93tA4dinz9F4RDFMSp+H8ebeIFgROxH68bXVH3dxZvh9h2PKIwj4M7QPzj/g82BMIdIm7pKl4NjHgjiejmETW03fh8Drn5uhcS4jRxKLR5zDmH+OYfGueCmnzWvFXA9PZra90j7p6uj8eNu4vmN8nFOnT/JfcQwqK9xf/OycdpUDUxNl/zziLgPo/sal8v7DwBTpsYo/azxJk8fkfvU2OTxqfUzsA4C7owY9nLQ1D+6+OYdL6dQ0XoGNwerfPVU37euzOZl43bjcjHgjuybaHoMQpqu9bwtfdVf5f45no8YouJyMeB6n7xcPh/xuLyOlukFXG8v73tcz8eW/+/6fG5jwNXXqWdw4/F63zXf/XgZtRyq3U+c7u9j2Ix/GLTE8ydx8B/Z17xc63z52AEsg8dTtzj+a4zQa8KXv/zlo+81X+PJ97///aOxyHfzNN2vObE/9yV+ffHYrQslXtdjXxzTRNO07Ny4CEwh4M7Qi358REH/8PwPV1cQc1jxPP8DzYFEy+bg4XXirRn3F0Pq3Hbj7X0to0cicvDN+2Y6Rs/LA5K+Vz9qHpQcgGK/+upb8XG69uv58+enQm0Msx7wYsj0tNji+XE/+VjiwJpDdivgts5fDLg+7/oaf1/6quPy+fA2/fPUNuc+RSE+xpLrJoq14O3F6b19jcvF86XHE773ve8d9+VADBwqnlPs01gz9aZgjQ9x3I3jUvw+jqnuL/cVlxH/oZ3HOk3L47qWja9LS8cjCuMIuB1LfqA7BvIlyAF3l7b9v8csuc5Rk/5ww3rimK/v412lkYA711frtSQH3NZyrdC7ZIzV4xgBOpZcTK3BpjJfee09KnDRtO1t/+8xS65z1ETAHZPv4k2F0tGAG/vz+vFqbpQDrqflO2kE3M8xVo9jBOjgdgCWgDpHNXyKQl++Sjt31XUk4Lq/Xl+WA25rOQLuSYzV4wi4AAAsUAy4voM1FUrXCbi5L83Lb2r1m3R5BhcXhYALAFiczz77bPXkyZM8eVEcRPU4QX5TcA64muY3CftTFHLAdX+5L1F/+dGF2Ke+zwFX07Ss+wDWQcDt4HYAloA6RzVTzykq2OoZ90uXLq2uXr2aZ2OHcsDNP4Oxeh0E3I4lPtDtv8LjbSH/9Z2n5XfZxo/4yh81ld/M4KsGWs9/ycf+PU37os9MzG9kyG8Gy7e7PC3uU/zYGx+TB9D885Issc5Rm/4tRw62V65cOQq2GguePXt2Yhnsjsb0/LFk+/KpNvuEsXocAbdjqcUU/0MA0fe3bt06EVo1zT8rHMbBSTQv3uLyc1eR+vAtqBhw/bP3Id4GE4fluI854I6G8jiI5p+XYql1jroccHOw9R+7169fT2sA+4+xehwBt2OptwPi81dqCn35mSo//N+64it5eivgxlDqgOv18rNYOeBqn+IbF2JfrT4k71MOtPnnpVhqnaMuf4rCvXv3VpcvXz5x5+j9998/8TONtq8th1nG6nEEXDTFh/v9/U9+8pPj/+o3Bs585TSKobYVcPMV3O9+97tHP+flWgHXz2d52bgf+r73X/5KDrT5ZwCHjSu4wDIRcNEUr3SqOUQ6VMYgOBdwYwD1YwWx+XEBB1xPHw248cpvDrhxn3L/U48+5J8B1JCDrh6pevr0aV4MQBEE3I4l3w5wmFXzLX2H3Rh6c5iMcsD19/kRAgdQzff3vUcUPN+PU+j3NHIFN64rfgTDy+afl2DJdY6a8q1dc9DVYwt8igIODWP1OAJux5If6FbAUxiMYU/hUdMePnx4HHrzc62Wp8eAK+pTV1E0P16J9bwYUOcCrrej/ew9gytx3dxv/nkpllznqEl3aubwObg4RIzV4+ZHACy6mBT2HBz9TKq+OqjGK7YKppv8FAXPi48wTAVccViOn5CgvvQiF/v0NK+r9XgGd9l1jpp6ARc4RIzV4xgBOpZ+O2AulOYQ6JA59Rxtqy8H21bA9VVYTf/xj388G3AlBmJzv96nHMJzoM0/L8XS6xz1+FMUgEoYq8cRcLFoOdDmnwEAwOEh4GKx8uMK+WcAAHCYCLgd3A7AElDnqIbnFFERY/U4Am4HD3RjCahzVMObzFARY/U4RoAOiglLQJ2jGgIuKmKsHscI0MHtACwBdY5q+BQFVMRYPY6ACwAAgFIIuAAAACiFgNvB7QAsAXWOanhOERUxVo8j4Hac5YFu/o9zHJqz1Dmwz3iTGSpirB7HCNCxTjEp2D569Gh16dKl1dWrV/NsYG+tU+fAISDgoiLG6nGMAB0jtwMcbK9cuXIUbK9du7Z69uxZXgzYWyN1DhwSPkUBFTFWjyPgnkMOtrpioHb9+vW8KAAAALaEgHsO9+7dW12+fPk42Kp94QtfWH344YdH83UbwdPjLYWLnN6adijTW9MOZXpr2r5PBwCgKl7lOuZuB3AFF1XM1TlwiOIfdkAVjNXjCLgdGiR7A2UOunoG9+nTp3kxYG+N1DlwSLhLgYoYq8cxAnSsU0wOunpsgU9RwCFZp86BQ0DARUWM1eMYATrOcjuAz8HFoTlLnQP7jE9RQEWM1eMIuAAAACiFgAsAAIBSCLgd3A7AElDnqIbnFFERY/U4Am4HD3RjCahzVMObzFARY/U4RoAO/lrCElDnqIY3maEixupxBFwAAACUQsAFAABAKQTcDm4HYAmoc1TDc4qoiLF6HAG3gwe6sQTUOarhTWaoiLF6HCNAB8WEJaDOUQ0BFxUxVo9jBOjgdgCWgDpHNXyKAipirB5HwAUAAEApBFwAAACUQsDt4HYAloA6RzU8p4iKGKvHEXA7eKAbS0CdoxreZIaKGKvHMQJ0UExYAuoc1RBwURFj9ThGgA5uB2AJqHNUw6cooCLG6nEEXAAAAJRCwAUAAEApBNwObgdgCahzVMNziqiIsXocAbeDB7qxBNQ5quFNZqiIsXocI0AHxYQloM5RDQEXFTFWj2ME6OB2AJaAOkc1fIoCKmKsHkfABQAAQCkEXAAAAJRCwO3gdgCWgDpHNTyniIoYq8cRcDt4oBtLQJ2jGt5khooYq8cxAnRQTFgC6hzVEHBREWP1OEaADm4HYAmoc1RDCEBFjNXjCLgAAAAohYALAACAUgi4HdwOwBJQ56iGRxRQEWP1OAJuBw90Ywmoc1TDm8xQEWP1OEaADooJS0CdoxoCLipirB7HCNDB7QAsAXWOs3j8+PHq/v37efLGvHr1anXt2rWjsPro0aPVnTt3Vu/evcuLNX388cfH3798+fLUurHv3HRc61C/6l/bAS4SY/U4Ai4A4EwuOuAqMG6i/1bAjXQcc/N7CLjA/iHgAgBOUFC7cePG0RVOBzdf3XQQjNMUQnOIjOFXX2/dunV8dVQ/37179/gKaitc5m2+ePHieLm59eN6ap7W2oblgOvAmo9ZYv83b95cvXnz5lTA1Vftm64SA9gNAm4HtwOwBNQ5ohzQFHb1vYOcg2sMsTlE5oAb5+lnh0M/KtC6+hn7jN9Pra/vva96TlH7kNdtyQFX/XvftQ1tS33o+9u3bx+fF63nbTjg9rYFnAdj9TgCbgcPdGMJqHNECmkOkBIDWwxw6wRcf59/zlc/o7mA21tfV1g1La/bkgNuFPvPATcv8/Dhw6P5Pm/ApjFWjyPgdlBMWALqHFEOhPGWf7w1v07A1c8Wf54KqDIXcKfW17y4r3ndlhxwW29Ac/9xntfxPqjp0YnWsQCbwFg9joDbwe0ALAF1jigHwnj1NZoLuPEq67YCrprDtz5FQT/ndVtiwHV/rf4zH39cRgGYq7i4KIzV4wi4AIATciD0c62iQOd5OeD6uV0/t7rLgOvped2WuYCrdX0FN4dXLaOWjyEfL4DtI+ACAE7IgdAhLz6eEKfHIOtlHjx4sPWA6++1Dwrbz58/P9rXfDxZDLgSj1fbitvTV8/zOvkYpp7VBbA9BNwObgdgCahzVMNziqiIsXocAbeDB7qxBNQ5qtEVVqAaxupxjAAdFBOWgDpHNQRcVMRYPY4RoIPbAVgC6hzVEAJQEWP1OAIuAAAASiHgAgAAoBQCbgfPu2AJ1q3zb3/723kSsFd4BhcVrTtWLxkjQAfFhCUYrfNPP/109ZWvfGV1+fLl1b179/JsYG8QcFHR6FgNAm4XD3RjCXp17mD7pS996Sg4XL9+PS8C7BVCACrqjdX4HAEXwKQcbNW++MUvrp49e5YXBQBgbxBwAUy6dOnScbB1u3r16qlpNBqNRttsw/lwBju4HYAlmKpzruDiUPGIAiqaGqtxGgG3gwe6sQS9Os9Bl2dwse+4AoaKemM1PscI0EExYQlG65xPUcChIOCiotGxGgTcLm4HYAnWrXM+Bxf77uOPP86TgIO37li9ZARcAAAAlELABQAAQCkE3A5uB2AJqHNUw3OKqIixehwBt4MHurEE1Dmq4U1mqIixehwjQAfFhCWgzlENARcVMVaPYwTo4HYAloA6RzWEAFTEWD2OgAsAAIBSCLgAAAAoZfEB9/79+0fPauX25s2bo/mjtwPUz+PHj/PkY69evVpdu3Zt9fLlyzzrBPWhvkTr3L59+2hfvL72rddHFvtUXzdv3jzVR1xm1FRfWTyOKfH4YlP/c+udhfrT/mibLToebVvnZGTfp6ifO3furN69ezc0ffR8riPWZdyuvtf59jkYrXPp1TqwD3hEARWtM1Yv3eIDrk2Fi9EHunsv+prvNmcqaGq/WtNHHErAvXHjxmTo3KRewNV58DGN7PuUqSA7ZfR8rmOqLvO00TqXqT6BfcKbzFDROmP10jEC/EwOF76K5xYDj680xitg8UU/X61V3wo6P/rRj04FK61369ato/5+7dd+7Xh7mu5w9Z3vfOd4erwC19o/7YOn6fu4nPrMx2kx4OrrgwcPjpbzeqZtax+8L71z5u3pZ1+NjecwTpsKuN5m3Od4vuN2fX68jpaLxx/3P/7+Igfc1r63jjH2qda6Yhr3pzXd+9763bTE37OPw3216sm1oPm/8zu/c3w+pvqyeP60fq4vYF+pRoFqCLjjGAF+Jgc/hy3dCvjGN75xFAzevn179DUGuhgK9YLfuuIXl9MyMRhousOO53vZ2FcMRTkMah3P89d4lTL2mY/TcsB10MnLx/112NPXuX2KxzHVX14/y8fgY4vrxRDp7+O+xmPKf2hEDqES9z3vo48x75umxd+Zp8W68X5Nnc85mu/ALeojHrP3xfNcb3G7cZr6+t73vndU6+5Lpmox9gnsK0IAKuIRhXEE3J/JwStyMMgBN9KLvq56toJTDkx37949DrQxUMhUqIjhJGsFlygHsNZx5oDb2icHKK+bf47iPuXjiOHM8/S19Qyu9yOul483npf8u/L5iKF2LuDmeXHfM28rnrvWfP2+4+8l7+PI+ZyTfz9xWzGM5vPWkvtq7QsBFwCw7wi4P5ODn17EY9ByMPBympavoulnhdz44h+Xd5t6tEFiWMrB0Pvg9fL+KTC1gkfsMx9na5mpfcrr5hDU2qdWwI3LxPMxdwU3Bs+4f/qa+9M+vn79+sS+jQRcTdc6MczmgNs6xjzd2/SxPnz48MQfNf5dah/nzucULxf3YyqUxnPVCrhTfeXfdZTrAwCAfUPA/Zn8gu7wqlsBv/u7v3scDKIYGPyin8OTpuV1R8Kk5GDofvR9DNet4BLFPlshSDQ/7pO/jz/ndePPc/s0dRxRL+CK9sFhMZ7fuK+W93Uk4OblJO976xijuH6rPuJ6Z72Cm2vK56C1fmu7sU7c1yeffHJU63N9Wa5ZYB/xiAIq4hGFcQTcn5kKuN/85jdXH3zwwdGLva64xfCjZWMojKEhhoQcBmJQymFh3YDrbXiev8bjySFQ33s5bye+KU7z3X8+LzFcaZqvWM7tUzyOVn/6eSTgent53+N6PrYcHmPwzCE2Ux9eL/8OWscYf4eap2n5d5b78fSp8zknruPzORVKRwOu6vyjjz467svrxlr0ec41C+wj/VsCquFNZuMYAX4mBy+96GuAvHTp0uqXfumXToQT38qNV/Pii76DxtOnT5uhzdty8Ixhwf1r+lQocv9aTsH0+fPnx8tpPe9fDDbu0+JyOVRpnq6S+pnYuH9x2/qq5bTu3D75eH2+HKi9rH6O02KLj3PE8xa1fic57GmaQ63n5U8MsBhw4777sYfWMWp+Ppfxdyb+fU/9LuP5jPubxe3pq/ZD6+ZQL9qmf4etgBv7+vmf//njvvK+xeOKfcYaBfaJahSohoA7jhGgY4m3A3LoXpoYcHdJYbMVcC/Ceer80aNHBFzsHUIAKjrPWL00BFycsvSA6yvCuzwHunqq54199XdfKdgq4AIAsE8IuAAAACiFgNvB7QAsAXWOanhEARUxVo8j4HbwQDeWgDpHNbzJDBUxVo9jBOigmLAE1DmqIeCiIsbqcYwAHRd9O+Asb+jSm6DiR5SdR/x4rvgxYlM28bFQ+WO19FFUsom+o9H+zvI7mKK+pj5+zOY+oq03P89zO+/+X3SdA9tGCEBFjNXjCLgHaFMB10FT/fkzT3tBaTQ0TvE243b0vbZ/3r6z0f42GXBFfU31p235c2bFf2A4xI7MH/lDBACAJSPg7pjDlQNmvEIXg0y+0hoDblxHpv6DAS/r8JUDoKbH9Vpa63jb8cqlP2pLLe5raxv6Xsu77wcPHjT7ax3T3HnL++rwGP9Hurj/+l7b0X/OoW1r2RcvXjS3K/E/QohXWacC7tQfEQ6tvfn5ewAA0EbA7bjo2wEOnA43DlMKTA54+apnDLgxMGpZBy2HLC3j8JTl0DhyZTiGxry8w5d+jv8Ll/dlKsCZQ3w8zng+4r46aM6dt7ivPs8tcV5c3z+3tuv11PI6Pt4WTc9/vES9+RcVcC+6zoFt4xEFVMRYPY6A23HRD3TngOtgFENivhLpn/1fx8Yw5e/Vn/7bV12NjFcXIy0bw1sOrC15XyKHvxxwzcc4tT9aPv7XxjFcTgXNkfOmK8JzoTAH3HgOprbrPzo0Px9XXifzuvmK88h8fe/pbr1nfkdcdJ0D26Z/G0A1jNXjGAE6LrqYcsB1SIpBLYeuHHBj2IlhqBe08vy8nZYYcL3Pre1rOT9S4W3kMJrl8LxOwG2dN++DAq6WmTquHHDzOWltN4dQtXhc2rb+wJg699Y7J3m+tp0D8SZcdJ0D20bARUWM1eMYATou+nbASMDNwS8HXK8TaVnNU7ibCk+533xFtyWuk5d3+Mvi9LyO6Rjy/swFXAe90fM2tW+yTsD1duN2sryO+XeSg3YMzXPz5aIC7kXXObBthABUxFg9joC7YyMBt3UVr/UMrn/2MupL03UlsRXEtHy+zT4Vhi2Hxrht9aXt5qCq5dyvl4vb0feantfLATc/k7xOwI3Ts17AbW3X6/l44ycdxOPNckDN52Pd+QAA4DQC7o6NBFxxiNJtt3zLXX34NrmovxiCYtCLYc7z4qczWF7Ocmj0bXp9ff78+XE41LrepxgYJa7ndXPfksOmj1PL+7naufM21V/8FAXxvupr3ubUdsXbzo8nzAVcib+vvG5vfp7nRugFAOBzBNyOpd4OUPhTYMX6egF3Hy21zlEXjyigIsbqcQTcjqU+0K1w27qdj3m6krqJTzXYtqXWOerSnQ2gGsbqcYwAHRQTloA6RzUEXFTEWD2OEaCD2wFYAuoc1RACUBFj9TgCLgAAAEoh4AIAAKAUAm4Hz7tgCahzVMMzuKiIsXocI0AHxYQloM5RDQEXFTFWj2ME6Bh5oPuzzz5bPXnyJE8GDsZInQOHhBCAihirxxFwz0HB9tGjR6tLly6trl69mmcDAABgBwi4Z+Bge+XKlaNgqw/2f/bsWV4MAAAAO0DA7Yi3A3Kw1TNeatevXz+5EnBguO2FanhEARUxVo8j4HbEB7rv3bu3unz58nGwVfvCF76w+vDDD4+X9fQ4uG5zemva1LL7NL017VCmt6bt+/RM8+bmA4dGNQ9Uw1g9jhGgIxYTV3BRFYMmqiHgoiLG6nGMAB2t2wE56OoZ3KdPn55YBjgkrToHDhkhABUxVo8j4J6Dg64eW+BTFAAAAPYDAXcD+BxcAACA/UHA7eB2AJaAOkc1PKKAihirxxFwO3igG0tAnaMa3mSGihirxzECdFBMWALqHNUQcFERY/U4RoAObgdgCahzVEMIQEWM1eMIuAAAACiFgAsAAIBSCLgd3A7AElDnqIZHFFARY/U4Am4HD3RjCahzVMObzFARY/U4RoAOiglLQJ2jGgIuKmKsHscI0MHtACwBdY5qCAGoiLF6HAEXAAAApRBwAQAAUAoBt4PbAVgC6hzV8IgCKmKsHkfA7eCBbiwBdY5qeJMZKmKsHscI0EExYQmoc1RDwEVFjNXjGAE6uB2AJaDOUQ0hABUxVo8j4AIAAKAUAi4AAABKIeAGr169Wl27du3o2a3YvvGNb+RFZ7179251586d1cuXL/OsI/fv3z/Rf1xO8x4/fhyWbhtdrkXrqkU69tu3b6/evHlzYnqP9kHHqmOeoj7Vt7YxRcvcvHnz1LnX72NuvbOaO3+uAy0zsu9Tps7p1HQZOZ9TRvfVy0Xc9kI1PKKAihirxxFwJzhknOWB7rmAq9AUA4zDlJedC17R6HIt+xxwW+fsIsydP033vJF9n3KWczpyPqeM7msr4J6lzoF9xpvMUBFj9ThGgAkx4H7zm988+tlXFWMAUSDzdAU0hYcccPVVIfYHP/jB0fQcrBw4Nd196Xv3k7ebl1P/cZ7Da2vf4vaiGMb8/YMHD5pXUd2vpt+9e/d42/kqrLYRj8H95ONSf72AmwNpPE7/kZCPU33pONTi9vP5yxxwW/veOkbR1zwtB1xNV3+qgzh96nzOydtr7Ws+z/r+7du3x9P8O419bSLYA/tA9QxUQ8AdxwgwwSFDtwK++tWvHoeWGMRyCMjBSMvE8OllYgjKYpCLQTQHwLhcK+BO7Vvu13LA9S160Xru3/O0TR9nDE7ehpa7cePGcSiM+xK37/Cfjy+LxxjPb17PIVLLODjGffV24/nL4rmK++4+8jHmfVNI1bx4TuP2Wuc6n0/XS8vU9ubOc6tuxb/bTz75ZPUHf/AHJ+4mAIeMEICKeERhHAF3wlTIyOGqdZXLyzx8+PDElTpz2MhX/GQqeMXtyroBNxoJuA6nEvuK25L8s8V18vcxkPq48jmJVx21TNynuK/qJ161nZvncyOj53nuPHre1DnwvuhKeDzfeR9Hzmc0tczcvrbq1tPieZg6LwAAHBIC7oQYIBQYfAvczQEozvM6Dg5quro2d0Ush4x8pW9qu72Am9ePxzMScGMwj8HJV/xagUzfx32Nt/VzwM1BNgffLAa0eIx5m3G7OQj2Aq6W89VQy6Exb0/bEvXlafn3p4Cr/WiF8LnzOae1vbyvU/WTA24+f7k2AAA4NATcCQ4ZunWrMOAQEYNW5gAVl4lhRi0GnbyeOHjl4Ju3OxVwW+FV4jbi96Y+fLVT+xyv4MafcwDzz69fvz4RUHOobX0f9QKueL/VvFzenyjPa53nLJ/nvO+tY4ymfvdx23F63sf8c0/cXtzXufrJAVfTuO2FanhEARUxVo8j4E5wyNAbzD744IMTYdJXwmJQES0Tw6mDUAxTOYA6NMX5rYAbtxuX8zxftVRfmje1b3l58bZiANN8L6+vPh8x5Hk9tRxwtU7rCq7Ec+Bt5fDY4mXjYwd5PW3X83NYjCFzKuBKPFdzAdfHGPvVtlrP4MZ+8vTW+ZwLuFPbi9uYqx8v5760nOr8o48+OlGLwCFTvQPV8CazcYwAExwyVEhf//rXT9y+jeFIXz3P6+SA2wp48ZZwDBTuT18dSua265/dZ3zes7VvFvt2/+YApnU0LwbKvK6eM1bAUt9xe5ruc+Dz4cDrn72s1nPQi/vk5vOYg7g5+GrZGNznAm4+f5GmeXre99Yxto5HYpAV78/Upyi4T5/PqRA+tb28r1P14+Va9ejzk2sWODSqZ6AaAu44RoCOJd4OyMFsaWLA3SX9Hp4/f54nX4gl1jlqIwSgIsbqcQRcnLL0gOsrwvlK8bYp3HIFFQCA9RFwAQAAUAoBt4PbAVgC6hzV8IgCKmKsHkfA7eCBbiwBdY5qeJMZKmKsHscI0EExYQmoc1RDwEVFjNXjGAE6Dul2gN4U5o97ih+PZfHjtOJHQkn+iKkof6RW/pgztfhRYv5Iqmzqo8D8hq48PfY7NX9un1r7IP74rLlPSsjnKp/POD/Oy+u55Y9a2zeHVOfACEIAKmKsHkfALcLh0RTeYvBSqMvhVQHQyzjg3rp160Tw03R9Lqv+J7MYJnN41DxPa80X76M/17ZlapmpPi3Pn/rMXNN58OfNZg6pcR/iucrz87z4v8ABAIDtI+B2HMJfSw5zU1ck5z72y8HQfeijqeIH/PszYbXMXMCN01rzZSq8RlPLTPVprfk+ptyXzAVc70P+g2Bk/qEG3EOoc2AdXMFFRYzV4wi4HYfwvMtckJO5gOvwGvtwmPXVW62fA26+Be8rmJ6fw6ZMPaKgdfMy+Vha24wBs7XNufOi7fT+py4/mpG3lefHeb66m/c179u+OYQ6B9ahf3dANYzV4xgBOg6hmM5zBbcVcB1y43o54M4Ftqn5U+E1mlpmqk9rzZ/qy2KA71EfU8/RxnmHegX3EOocWAcBFxUxVo9jBOg4lNsBfuY2UuBT+Jq6khmnx+8V1PT9gwcPjkPjIQbcubA5dwXXj2VEcfk8P86b2+Y+O5Q6B0YRAlARY/U4Am4RDoamABavOCow5tvsCoQKsgq3rbCrKyAOmocWcH0MU+voPEw9g9sKqfF85vlz8wAAwPYRcAtRwPIzn63b6QpdvY8Jc7DMAXndgNt6BtXhNc+LtxLnAm5eJx5Da/7cPs4FXMnnKp/POD/Oy+u55T8uAADAxSHgdnA7oKZewF0a6hzV8IgCKmKsHkfA7eCB7np0dVhXVfNztktGnaMa/RsHqmGsHscI0EExYQmoc1RDwEVFjNXjGAE6uB2AJaDOUQ0hABUxVo8j4AIAAKAUAi4AAABKIeB2cDsAS0CdoxoeUUBFjNXjCLgdPNCNJaDOUQ1vMkNFjNXjGAE6KCYsAXWOagi4qIixehwjQMdZbgd89tlnqydPnuTJwN46S50D+4wQgIoYq8cRcDdIwfbRo0erS5cura5evZpnAwAAYAsIuBvgYHvlypWjYHvt2rXVs2fP8mIAAADYAgJux9ztgBxs9cyX2vXr1/OiwF6bq3PgEPGIAipirB5HwO2Ye6D73r17q8uXLx8HW7UvfOELqw8//PBovtbz9NjHRU5vTTuU6a1phzK9NW3fp0eaHpcDDl2ucaACxupxjAAdc8XEFVxUMVfnwCEi4KIixupxjAAdI7cDctDVM7hPnz7NiwF7a6TOgUNCCEBFjNXjCLgb5KCrxxb4FAUAAIDdIOBeAD4HFwAAYHcIuB3cDsASUOeohkcUUBFj9TgCbgcPdGMJqHNUw5vMUBFj9ThGgA6KCUtAnaMaAi4qYqwexwjQwe0ALAF1jmoIAaiIsXocARcAAAClEHABAABQCgG3g9sBWALqHNXwiAIqYqweR8Dt4IFuLAF1jmp4kxkqYqwexwjQQTFhCahzVEPARUWM1eMYATq4HYAloM5RDSEAFTFWjyPgAgAAoBQCLgAAAEoh4HZwOwBLQJ2jGh5RQEWM1eMIuB080I0loM5RDW8yQ0WM1eMYATooJiwBdY5qCLioiLF6HCNAB7cDsATUOaohBKAixupxBFwAAACUQsAFAABAKQTcDm4HYAmoc1TDIwqoiLF6HAG3gwe6sQTUOarhTWaoiLF6HCNAB8WEJaDOUQ0BFxUxVo9jBOjgdgCWgDpHNYQAVMRYPY6ACwAAgFIIuB38tYQloM5RDVdwURFj9TgCbgfPu2AJqHNUwzO4qIixehwjQAfFhCWgzlENARcVMVaPYwTo4HYAloA6RzWEAFTEWD2OgAsAAIBSCLgAAAAohYDbwe0ALAF1jmp4RAEVMVaPI+B28EA3loA6RzW8yQwVMVaPYwTooJiwBNQ5qiHgoiLG6nGMAB3cDsASUOeohhCAihirxxFwAQAAUAoBFwAAAKUQcDu4HYAloM5RDY8ooCLG6nEE3A4e6MYSUOeohjeZoSLG6nGMAB0UE5aAOkc1BFxUxFg9jhGgg9sBWALqHNUQAlARY/U4Ai4AAABKIeACAACgFAJuB7cDsATUOarhEQVUxFg9joDbwQPdWALqHNXwJjNUxFg9jhGgg2LCElDnqIaAi4oYq8cxAnRwOwBLQJ2jGkIAKmKsHkfABQAAQCn/H2cRWrvruv3IAAAAAElFTkSuQmCC>