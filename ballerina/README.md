## Overview

This module provides a client for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org)
— the open standard that lets AI agents built by different teams, in
different languages, discover and call each other over a shared wire
protocol.

`ballerina/a2a` is the client half: given any A2A-compliant agent's URL,
discover its capabilities and call it — send messages, stream responses,
manage tasks, configure push notifications — the same way regardless of
which language, framework, or protocol dialect that agent happens to
speak underneath.

**Client-side: complete and verified against real, independently-built
agents** — not just this library's own mocks. All 11 spec operations, all
three transport bindings, both A2A protocol wire dialects (current v1.0
and legacy v0.3), verified end-to-end in a companion repo
([`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests))
against four independently-built reference agents (three Python, one
Java) — see that repo's `VERIFICATION_EVIDENCE.md` for real captured
proof, not just test counts.

Server/listener support — letting a Ballerina program *be* an A2A agent,
not just call one — is deliberately out of scope for this phase; see
[Roadmap](#roadmap).

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

if result is a2a:Task {
    a2a:Task status = check agentClient->getTask(result.id);
    // or: check agentClient->cancelTask(result.id);
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
This library has no server side (see Roadmap), so hiding a skill from an
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

## Roadmap

Deliberately deferred to a later phase (not started): `a2a:Listener` and
a service-object contract for exposing a Ballerina program as an A2A
agent, a `TaskStore` abstraction, an Agent Card/skills authoring guide,
and a push notification webhook receiver.

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

444 tests passing, 0 failing (441 in the main package + 3 in
`a2a.transport`; `bal test --sticky` — see the note on `http` pinning in
`Ballerina.toml` for why `--sticky` matters here) — this package's own
fast, deterministic, mock-based suite. Real-server proof against
independently-built agents lives in the companion
[`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests)
repo, deliberately kept separate: testing only against your own mocks
validates your own misreadings of the spec.
