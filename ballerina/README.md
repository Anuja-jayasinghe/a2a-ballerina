## Overview

This module provides a client for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org)
— the open standard that lets AI agents built by different teams, in
different languages, discover and call each other over a shared wire
protocol.

`ballerina/a2a` gives a Ballerina program both halves of the protocol:
call any A2A-compliant agent's URL — send messages, stream responses,
manage tasks, configure push notifications — the same way regardless of
which language, framework, or protocol dialect that agent happens to
speak underneath; or *be* one, by implementing one method on an
`a2a:Service` and letting an `a2a:Listener` run the rest of the protocol
around it.

**Client-side: complete and verified against real, independently-built
agents** — not just this library's own mocks. All 11 spec operations, all
three transport bindings, both A2A protocol wire dialects (current v1.0
and legacy v0.3), verified end-to-end in a companion repo
([`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests))
against four independently-built reference agents (three Python, one
Java) — see that repo's `VERIFICATION_EVIDENCE.md` for real captured
proof, not just test counts.

**Server-side: HTTP+JSON binding, protocol v1.0.** All 11 operations —
`sendMessage`/`sendStreamingMessage` through a developer's `onMessage`,
`getTask`/`cancelTask`/`listTasks` over a pluggable `a2a:TaskStore`,
`subscribeToTask`, push-notification config CRUD (stored, not yet
delivered — see [Roadmap](#roadmap)), and the extended Agent Card.
JSON-RPC and gRPC server bindings, and A2A v0.3 server support, are later
phases; see [Roadmap](#roadmap).

It includes capabilities for:

1. **Getting Started** – Constructing a client and picking a transport
   binding.
2. **Sending Messages and Managing Tasks** – The core request/response
   and task-lifecycle operations.
3. **Streaming and Push Notifications** – Real-time updates and
   out-of-band task notifications.
4. **Authentication** – Wiring credentials for every scheme an agent
   might declare.
5. **AgentCard Resolution and Verification** – Discovering and trusting
   an agent's capabilities.
6. **Serving an Agent** – Implementing and running one, over HTTP+JSON.

## 1. Getting Started

```bash
bal add ballerina/a2a
```

```ballerina
import ballerina/a2a;
import ballerina/uuid;

public function main() returns error? {
    // Pass a URL and the client resolves the Agent Card itself...
    a2a:Client agentClient = check new ("https://example.com/agent");

    // ...or resolve it yourself first and hand it over — never both.
    a2a:AgentCard card = check a2a:resolveAgentCard("https://example.com/agent");
    a2a:Client fromCard = check new (card);
}
```

`Client` auto-detects whether the target agent speaks the current v1.0
wire dialect or the legacy v0.3 one (from the resolved `AgentCard`) and
translates transparently — calling code is identical either way.

### 1.1 Picking a Transport Binding

Each of the three bindings the spec defines (§5) is its own client type,
and whether the agent or the caller chooses is expressed by which type
you construct:

```ballerina
// the agent's preference wins: Client walks the card's supportedInterfaces
// in order and speaks the first binding this library supports (spec §8.3.2)
a2a:Client agent = check new (url);

// the caller's preference wins: bypasses the card's ordering entirely
a2a:JsonRpcClient j = check new (url);
a2a:RestClient    r = check new (url);
a2a:GrpcClient    g = check new (url);
```

There is no `binding` parameter — picking a type *is* how you pick a
binding. All four share the same method signatures, so writing
binding-agnostic code against any of them doesn't need this library to
export a common type: Ballerina's structural typing already lets a
caller declare their own local type covering whichever methods they
use, and any of the four satisfies it automatically:

```ballerina
type MyClient isolated client object {
    isolated remote function sendMessage(a2a:Message message, a2a:SendMessageConfiguration? config = (),
            string? tenant = (), map<json>? metadata = ()) returns a2a:Task|a2a:Message|error;
};

MyClient c = check new a2a:Client(url); // or RestClient/JsonRpcClient/GrpcClient
```

This is the main divergence from the reference Python and Java SDKs,
which keep the equivalent internal too, just via each language's own
abstract-base-class mechanism rather than structural typing.

v0.3 is supported **over JSON-RPC only** — `RestClient` and `GrpcClient`
reject a v0.3 card at construction (issue #31). A v0.3 card declaring
several transports is still read correctly: its `preferredTransport`/
`additionalInterfaces` are normalized into `supportedInterfaces`, and
`Client` picks the JSON-RPC one.

## 2. Sending Messages and Managing Tasks

```ballerina
a2a:Message msg = {
    messageId: uuid:createType4AsString(),
    role: a2a:ROLE_USER,
    parts: [{text: "Hello!"}]
};

// A quick request gets back a Message; a longer-running one gets back
// a Task you can poll, cancel, or list alongside others.
a2a:Task|a2a:Message result = check agentClient->sendMessage(msg);

match result {
    a2a:Task task => {
        a2a:Task status = check agentClient->getTask(task.id);
        // or: check agentClient->cancelTask(task.id);
    }
    a2a:Message message => {
        // Use the direct reply, for example: message.parts[0].text
    }
}

a2a:ListTasksResult allTasks = check agentClient->listTasks();
```

## 3. Streaming and Push Notifications

```ballerina
// Opt-in automatic reconnection: the client detects a dropped stream and
// resubscribes on the caller's behalf, up to the configured attempt count.
a2a:Client resilientClient = check new (url, maxReconnectAttempts = 3);

stream<a2a:StreamResponse, error?> events = check resilientClient->sendStreamingMessage(msg);
while true {
    record {|a2a:StreamResponse value;|}|error? item = events.next();
    if item is () {
        break;
    }
    if item is error {
        return item;
    }
    a2a:StreamResponse event = item.value;
    // handle each event as it arrives
}
```

`subscribeToTask` resumes streaming for a task already in flight the
same way. Push-notification config CRUD
(`createTaskPushNotificationConfig`/`getTaskPushNotificationConfig`/
`listTaskPushNotificationConfigs`/`deleteTaskPushNotificationConfig`)
lets an agent notify a webhook out-of-band instead of holding a stream
open.

Also available: the `A2A-Extensions` header (advertise/request
extensions via `requestedExtensions`).

## 4. Authentication

Two routes, and which one you want depends on the scheme. Credential
*acquisition* is out-of-band either way — spec §7.3 puts it there
explicitly; only *transmission* is in scope for this library.

### 4.1 `clientConfig.auth` and `headers` — the direct route

Configured the same way as any other Ballerina client, and the **only**
route for OAuth2, OpenID Connect, and mutual TLS, which need a live token
exchange or a client certificate rather than a single string. What
`clientConfig.auth` accepts per scheme type, and what a card's
`securitySchemes` entry looks like for each:

| Card scheme (`type`) | `clientConfig.auth` |
|---|---|
| `http` (`scheme: "basic"`) | `{username, password}` (`http:CredentialsConfig`) |
| `http` (`scheme: "bearer"`) | `{token}` (`http:BearerTokenConfig`) |
| `oauth2` | an `http:OAuth2GrantConfig` variant matching the card's declared flow (client credentials, password, refresh token, or JWT bearer) — token fetch and refresh are automatic (`ballerina/oauth2`'s own token cache), not something this library needs to manage |
| `apiKey`, `in: "header"` | not `clientConfig.auth` — set the named header directly via the `headers` constructor parameter |
| `apiKey`, `in: "query"` or `"cookie"` | no direct equivalent; `clientConfig`/`headers` cover headers only, so this needs caller-side request shaping this library doesn't provide |
| `openIdConnect`, `mutualTLS` | no `http:ClientConfiguration.auth` equivalent; OIDC typically resolves to a bearer token obtained out-of-band (use the `http`/bearer row above once you have one), mTLS is configured via `clientConfig.secureSocket`, not `.auth` |

All of the above work identically across `JsonRpcClient` and
`RestClient`. `GrpcClient` supports the full same set
(`CredentialsConfig`, `BearerTokenConfig`, and every
`OAuth2GrantConfig`/`JwtIssuerConfig` variant) — `grpc:ClientAuthConfig`
and `http:ClientAuthConfig` are the same union over structurally
identical types, so whatever you configure for the HTTP bindings
projects onto gRPC unchanged.

**Genuinely still open**: mutual TLS has no higher-level helper beyond
what `http:ClientConfiguration.secureSocket` already offers generically
(see issue #13).

### 4.2 `CredentialProvider` — card-driven, opt-in

A single `headers` map is keyed by HTTP header name, so it cannot hold two
different credentials of the same kind — two bearer tokens for one agent,
say. A `CredentialProvider` is keyed by *security-scheme name* instead, so
it can:

```ballerina
a2a:InMemoryCredentialStore store = new ({
    "bearer-staff": "tok_staff",
    "bearer-admin": "tok_admin"
});
a2a:Client agent = check new ("https://agent.example.com", credentials = store);

// A refreshed token does not need a new client.
store.setCredential("bearer-admin", "tok_admin_v2");
```

The provider is consulted per request. The client resolves the first
card-level `securityRequirements` entry it can satisfy in full (the list
is an OR; each entry is an AND across the scheme names it lists) and
attaches the resulting headers.

Scoped deliberately to the schemes that reduce to one string —
API-key-in-header and HTTP bearer/basic. Anything else is declined rather
than guessed at, and belongs on `clientConfig.auth` per §4.1. Returning
`()` from `getCredential` is normal, not an error: the request is sent
without that credential and the agent decides how to answer.

Two safeguards worth knowing: a resolved credential can never occupy
`A2A-Version`, `Content-Type`, or `A2A-Extensions` (an API-key scheme
names its own header, and cards are not necessarily signature-verified),
and an explicit `headers` entry always wins over a card-resolved one.

### 4.3 Finding out what a skill requires

`securityRequirements` names schemes but does not describe them, and the
name is arbitrary — `"bearer-admin"` says nothing on its own about whether
a bearer token or an API key is wanted. Resolve it against the card:

```ballerina
a2a:SecurityRequirement[] required = check a2a:skillSecurityRequirements(card, "case-escalation");
foreach a2a:SecurityRequirement requirement in required {
    map<a2a:SecurityScheme> schemes = check a2a:resolveSecuritySchemes(card, requirement);
    // schemes["bearer-admin"] is an a2a:HttpAuthSecurityScheme with scheme: "Bearer"
}
```

A skill declaring no requirements of its own inherits the card-level ones.
That rule is forced rather than chosen: protobuf3 `repeated` fields carry
no presence information, so "declares nothing" and "declares an empty
list" are the same value on the wire.

### 4.4 When the agent asks mid-task

A client cannot say which skill it is invoking — `Message` carries no
skill identifier, in this library or in the spec's own proto — so
per-skill credentials cannot be selected automatically at send time. The
spec's own answer is for the agent to ask when it finds out (§7.6): it
moves the task to `TASK_STATE_AUTH_REQUIRED` and waits.

```ballerina
if a2a:isAuthorizationRequired(task) {
    a2a:Message? prompt = a2a:authorizationPrompt(task);
    // Satisfy out-of-band, or reply to the same taskId to negotiate or reject.
}
```

The state is not terminal, so a stream stays open across the pause. A
client with no open stream can miss the resume; §7.6.2 names three ways
to avoid that — `subscribeToTask`, a push notification config, or polling
`getTask`.

### 4.5 Limitation: this library cannot enforce anything

Everything above is about what a **client** sends. Deciding whether a
caller may actually use a guarded skill is the **server's** job — spec
§7.5 makes authorization implementation-specific to the agent, and §13.1
requires servers to "implement authorization checks on every request".
`a2a:Listener` surfaces the hooks (an unauthenticated request reaches
`onMessage` exactly like an authenticated one) but does not enforce
anything itself — checking `RequestContext` and calling `requireAuth`
when a request isn't entitled is the agent author's own responsibility,
same as every reference SDK leaves it. Hiding a skill from an
unauthenticated card does not prevent anyone from invoking it; only the
agent implementation can do that.

## 5. AgentCard Resolution and Verification

```ballerina
// Fetches fresh every call.
a2a:AgentCard card = check a2a:resolveAgentCard(url);

// Opt-in HTTP ETag/If-None-Match conditional GET (spec §8.6.2);
// reuses the cached body on a 304.
a2a:CachedAgentCard cached = check a2a:resolveAgentCardCached(url);

// RS256/ES256, RFC 8785 (JCS) canonicalization (spec §8.4.3). Takes the
// card's raw json plus a caller-supplied key-resolution callback rather
// than fetching the card's `jku` itself, matching both reference SDKs'
// own verifiers. Returns nil on success, a typed error otherwise.
check a2a:verifyAgentCardSignature(rawCardJson, function(string kid, string? jku) returns crypto:PublicKey|error {
    // resolve and return the signer's public key for this `kid`
    return myPublicKey;
});
```

When the held `AgentCard`'s `capabilities.extendedAgentCard` is `false`,
`getExtendedAgentCard` returns that held card instead of issuing a
request the card has already said will fail (matching the reference
Python SDK). A successful fetch replaces the held card, so later calls
reason about the extended one.

## 6. Serving an Agent

```ballerina
listener a2a:Listener agent = new (9090, agentCard = {
    name: "Weather Agent",
    description: "Answers weather questions",
    version: "1.0.0",
    skills: [{id: "forecast", name: "Forecast", description: "Multi-day forecasts", tags: ["weather"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},         // derived by the listener from what it implements
    supportedInterfaces: []   // derived by the listener; fills in at request time
});

isolated service class WeatherAgent {
    *a2a:Service;

    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        // A quick exchange: reply directly, no task created.
        // return {messageId: uuid:createType4AsString(), role: a2a:ROLE_AGENT, parts: [{text: "..."}]};

        // A longer-running one: drive the task the listener already seeded.
        check updater->working();
        check updater->addArtifact([{text: "Sunny, 22°C"}]);
        check updater->complete();
        return ();
    }
}

public function main() returns error? {
    check agent.attach(new WeatherAgent());
    check agent.'start();
}
```

One method, `onMessage`, is the entire agent. The listener runs the rest
of the protocol around it: `getTask`/`cancelTask`/`listTasks` over the
task `onMessage` created; `sendStreamingMessage`/`subscribeToTask` replay
the same events as SSE; push-notification config CRUD; the well-known
discovery endpoint; version and capability gating (§3.3.4, §3.6.2); and
error serialization matching exactly what the client half of this same
library decodes, so a self-round-trip (this library's `Client` against
this library's `Listener`) is how the two halves are verified against
each other — see [Testing](#testing).

`supportedInterfaces` and `capabilities` on the card you pass are
placeholders — the listener overrides both to match what is actually
implemented, so the served card can never advertise something the server
doesn't do. Only `HTTP+JSON` at protocol `1.0` is served in this release;
a client resolving the card sees exactly that one interface.

### 6.1 Driving a task

`a2a:TaskUpdater` is what `onMessage` drives a long-running task through:

```ballerina
check updater->working();                          // TASK_STATE_WORKING
check updater->addArtifact([{text: "partial..."}]); // one TaskArtifactUpdateEvent
check updater->requireInput(promptMessage);         // TASK_STATE_INPUT_REQUIRED, pauses
// ... on a later message to the same taskId, onMessage runs again ...
check updater->complete();                          // TASK_STATE_COMPLETED
```

Every call also persists through the attached `a2a:TaskStore`, so a
concurrent `getTask` sees each update as it happens. `onMessage` always
runs to completion inside the request that started it — there is no
concurrent task execution in this release — so `sendStreamingMessage`'s
stream and `subscribeToTask`'s snapshot are both built from what
`onMessage` already did, not a live feed from a still-running one; the
wire looks the same to a client either way. `requireAuth` is the same
shape as `requireInput`, for §7.6's in-task authorization pause.

### 6.2 Task storage

```ballerina
listener a2a:Listener agent = new (9090, agentCard = {...}, taskStore = new MyDatabaseTaskStore());
```

`a2a:InMemoryTaskStore` is the default — tasks do not survive a restart.
Implement `a2a:TaskStore` (`put`/`get`/`list`/`remove`) to back an agent
with real storage; `list` must sort by status timestamp descending and
omit `artifacts` unless asked, per specification §3.1.4.

### 6.3 The extended Agent Card

```ballerina
listener a2a:Listener agent = new (9090, agentCard = publicCard, extendedAgentCard = richerCard);
```

Unset (the default), `capabilities.extendedAgentCard` is `false` and a
request for it fails with `a2a:ExtendedAgentCardNotConfiguredError` — the
listener never advertises a capability it cannot back. Configuring one
flips the capability true and serves it from `GET /extendedAgentCard`.

### 6.4 Push notifications: registered, not yet delivered

The four config operations work — an agent can register, read, list, and
remove a task's webhook configuration — but this release never actually
calls one; outbound delivery is a later phase (see
[Roadmap](#roadmap)). `capabilities.pushNotifications` stays `false`
accordingly, so this library's own `Client`/`RestClient` refuse those
four calls client-side rather than let a caller register a webhook that
will never fire. A caller speaking the wire directly can still use them.

## Roadmap

Deliberately deferred to a later phase: JSON-RPC and gRPC server
bindings, A2A v0.3 server support, outbound push-notification delivery
(config CRUD is implemented; the actual webhook call is not), and an
Agent Card/skills authoring guide.

**Not planned**, unlike `ballerina/mcp`'s equivalent: an `AdvancedService`
escape hatch for implementing all eleven operations directly. Considered
and declined — A2A's eleven operations are a fixed protocol surface
around one piece of business logic, `onMessage`, not a registry of
developer-defined tools a library might need to get out of the way of.

## Client Lifecycle

`Client` has no `close` and needs none. A Ballerina `http:Client` routes
through the process-wide connection pool, which evicts idle connections
itself — there is no per-instance resource to release, and neither
`http:Client` nor `grpc:Client` exposes a client-side close.

Two things still worth doing:

- **Reuse a `Client` per agent** rather than constructing one per
  request. Construction builds an `http:Client` — and, for the `GRPC`
  binding, a gRPC channel — which is wasted work per call even though it
  leaks nothing.
- **If you set `poolConfig`** inside `clientConfig`, that `Client` gets
  its own private pool instead of the shared one, and that pool cannot
  be released. Reuse the `Client` in that case; don't create them per
  request.

**Deliberately not implemented** (present in the reference Python SDK,
all additive, none required by the spec): a client-call interceptor
pipeline, a per-call context carrying timeouts and headers, transport
negotiation from the Agent Card with a pluggable transport registry,
client-level send defaults, OpenTelemetry tracing, and pluggable/async
credential resolution. Auth is supplied once at construction via
`clientConfig.auth`/`headers` rather than resolved per call, so rotating
a credential means constructing a new client.

## Testing

518 tests passing, 0 failing (515 in the main package + 3 in
`a2a.transport`; `bal test --sticky` — see the note on `http` pinning in
`Ballerina.toml` for why `--sticky` matters here) — fast, deterministic,
and mostly mock-based, except the server tests, which are the one place a
mock would prove less than the real thing: they run this library's own
`Client` against this library's own `Listener`, in-process, exercising
all eleven operations end to end. If the two halves disagree about any
part of the wire — a field name, an error shape, an SSE framing detail —
that fails, the same way a real second implementation would catch it.
Real-server proof for the *client* half against independently-built
agents lives in the companion
[`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests)
repo, deliberately kept separate: testing only against your own mocks
validates your own misreadings of the spec.
