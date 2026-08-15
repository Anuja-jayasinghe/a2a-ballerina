# ballerina/a2a

[![CI](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/ci.yml/badge.svg)](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/ci.yml)

A Ballerina client library for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org)
— the open standard that lets AI agents built by different teams, in different
languages, discover and call each other over a shared wire protocol.

`ballerina/a2a` is the client half: given any A2A-compliant agent's URL, discover
its capabilities and call it — send messages, stream responses, manage tasks,
configure push notifications — the same way regardless of which language,
framework, or protocol dialect that agent happens to speak underneath.

## Status

**Client-side: complete and verified against real, independently-built agents**
— not just this library's own mocks. All 11 spec operations, all three transport
bindings, both A2A protocol wire dialects (current v1.0 and legacy v0.3),
verified end-to-end in a companion repo
([`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests))
against four independently-built reference agents (three Python, one Java) —
see that repo's `VERIFICATION_EVIDENCE.md` for real captured proof, not just
test counts.

Server/listener support — letting a Ballerina program *be* an A2A agent, not
just call one — is deliberately out of scope for this phase; see
[Roadmap](#roadmap).

## Quick start

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

    // Send a message and get back a Task or a plain Message
    a2a:Message msg = {
        messageId: uuid:createType4AsString(),
        role: a2a:ROLE_USER,
        parts: [{text: "Hello!"}]
    };
    a2a:Task|a2a:Message result = check agentClient->sendMessage(msg);
}
```

`Client` auto-detects whether the target agent speaks the current v1.0 wire
dialect or the legacy v0.3 one (from the resolved `AgentCard`) and translates
transparently — the calling code above is identical either way.

## What's implemented

**All 11 spec operations** (§9.4): `sendMessage`, `sendStreamingMessage`,
`getTask`, `cancelTask`, `subscribeToTask`, `listTasks`,
`createTaskPushNotificationConfig`, `getTaskPushNotificationConfig`,
`listTaskPushNotificationConfigs`, `deleteTaskPushNotificationConfig`,
`getExtendedAgentCard`.

**All three transport bindings** (§5) — each is its own client type, and
whether the agent or the caller chooses is expressed by which type you
construct:
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
binding. All four implement `a2a:AgentClient`, so binding-agnostic code is
written against that one type regardless of which it holds:
```ballerina
a2a:AgentClient c = check new a2a:Client(url);
```

**Both wire dialects** — current v1.0 and the legacy v0.3 dialect (different
JSON-RPC method names, enum casing, response wrapping) — detected from the
resolved `AgentCard`, translated transparently, zero caller-visible branching.

v0.3 is supported **over JSON-RPC only**. v0.3 does define all three
bindings, but the compatibility layer translates the JSON-RPC dialect
alone, so `RestClient` and `GrpcClient` reject a v0.3 card at construction
(issue #31). A v0.3 card declaring several transports is still read
correctly: its `preferredTransport`/`additionalInterfaces` are normalized
into `supportedInterfaces`, and `Client` picks the JSON-RPC one.

**Hardening features**, each opt-in/backward-compatible with pre-existing
callers:
- **`A2A-Extensions` header** — advertise/request extensions via
  `requestedExtensions`. Reading back what the server granted was removed
  before release for lack of spec/SDK precedent; see issue #33.
- **Automatic SSE reconnection** — `maxReconnectAttempts` on
  `sendStreamingMessage`/`subscribeToTask`; opt-in, default `0` preserves the
  original manual-reconnect behavior.
- **AgentCard signature verification** (spec §8.4.3) — `verifyAgentCardSignature`,
  RS256/ES256, RFC 8785 (JCS) canonicalization. Doesn't fetch a card's `jku`
  itself; takes a caller-supplied key-resolution callback, matching both
  reference SDKs' own verifiers.
- **AgentCard caching** (spec §8.6.2) — `resolveAgentCardCached`, standard
  HTTP ETag/If-None-Match conditional GET. Opt-in; `resolveAgentCard` is
  unaffected and always fetches fresh.

### Authentication

Configured through `clientConfig.auth` and `headers`, the same way as any
other Ballerina client — this library does not wire auth from a card's
`securitySchemes` automatically (spec §7.3 puts credential *acquisition*
explicitly out-of-band; only *transmission*, which `clientConfig.auth`
already does, is in scope). What `clientConfig.auth` accepts per scheme
type, and what a card's `securitySchemes` entry looks like for each:

| Card scheme (`type`) | `clientConfig.auth` |
|---|---|
| `http` (`scheme: "basic"`) | `{username, password}` (`http:CredentialsConfig`) |
| `http` (`scheme: "bearer"`) | `{token}` (`http:BearerTokenConfig`) |
| `oauth2` | an `http:OAuth2GrantConfig` variant matching the card's declared flow (client credentials, password, refresh token, or JWT bearer) — token fetch and refresh are automatic (`ballerina/oauth2`'s own token cache), not something this library needs to manage |
| `apiKey`, `in: "header"` | not `clientConfig.auth` — set the named header directly via the `headers` constructor parameter |
| `apiKey`, `in: "query"` or `"cookie"` | no direct equivalent; `clientConfig`/`headers` cover headers only, so this needs caller-side request shaping this library doesn't provide |
| `openIdConnect`, `mutualTLS` | no `http:ClientConfiguration.auth` equivalent; OIDC typically resolves to a bearer token obtained out-of-band (use the `http`/bearer row above once you have one), mTLS is configured via `clientConfig.secureSocket`, not `.auth` |

All of the above work identically across `JsonRpcClient` and `RestClient`.
`GrpcClient` supports the full same set (`CredentialsConfig`,
`BearerTokenConfig`, and every `OAuth2GrantConfig`/`JwtIssuerConfig`
variant) — `grpc:ClientAuthConfig` and `http:ClientAuthConfig` are the
same union over structurally identical types, so whatever you configure
for the HTTP bindings projects onto gRPC unchanged.

## Why each public symbol exists

`docs/API_PROVENANCE.md` classifies every public symbol as spec-mandated,
borrowed from a reference SDK convention the spec doesn't define, or
invented here — with the justification, and the cost, for everything in the
last two categories. Worth reading before relying on anything that isn't
straight from the specification.

The short version: 52 of 63 public symbols are spec-mandated. The main
divergence from the Python and Java SDKs is that this library exposes
per-transport client types (`JsonRpcClient`, `RestClient`, `GrpcClient`)
where they keep the equivalent internal — which is what lets client
transport preference be a type choice rather than a configuration flag.

## Client lifecycle

`Client` has no `close` and needs none. A Ballerina `http:Client` routes through
the process-wide connection pool, which evicts idle connections itself — there
is no per-instance resource to release, and neither `http:Client` nor
`grpc:Client` exposes a client-side close. (The A2A spec governs the wire, not
SDK object lifetimes, so it asks for nothing here either.)

Two things still worth doing:

- **Reuse a `Client` per agent** rather than constructing one per request.
  Construction builds an `http:Client` — and, for the `GRPC` binding, a gRPC
  channel — which is wasted work per call even though it leaks nothing.
- **If you set `poolConfig`** inside `clientConfig`, that `Client` gets its own
  private pool instead of the shared one, and that pool cannot be released.
  Reuse the `Client` in that case; don't create them per request.

**Deliberately not implemented** (present in the reference Python SDK, all
additive, none required by the spec): a client-call interceptor pipeline, a
per-call context carrying timeouts and headers, transport negotiation from the
Agent Card with a pluggable transport registry, client-level send defaults,
OpenTelemetry tracing, and pluggable/async credential resolution. Auth is
supplied once at construction via `clientConfig.auth`/`headers` rather than
resolved per call, so rotating a credential means constructing a new client.

**Genuinely still open**: mutual TLS — `MutualTlsSecurityScheme` is fully
typed in the data model, but there's no higher-level helper for it beyond
what `http:ClientConfiguration.secureSocket` already offers generically.
(This library no longer derives any auth from the card, so mTLS is wired the
same way as every other scheme: by the caller. See issue #13.) Plus the JWS
canonicalization gap noted above.
Full, current status: [`docs/A2A_Technical_Design.md`](docs/A2A_Technical_Design.md) §12.1
— though treat that section as a snapshot to re-verify against source, not a
live source of truth (parts of this design doc predate later features and
haven't all been updated to match).

## Testing

436 tests passing, 0 failing (`bal test --sticky` — see the note on `http`
pinning in `Ballerina.toml` for why `--sticky` matters here) — this
package's own fast, deterministic, mock-based suite. Real-server proof
against independently-built agents lives in the companion
[`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests)
repo, deliberately kept separate: testing only against your own mocks
validates your own misreadings of the spec.

## Roadmap

Deliberately deferred to a later phase (not started): `a2a:Listener` and a
service-object contract for exposing a Ballerina program as an A2A agent, a
`TaskStore` abstraction, an Agent Card/skills authoring guide, and a push
notification webhook receiver. See
[`docs/A2A_Technical_Design.md`](docs/A2A_Technical_Design.md) §12.2.

## Documentation

- [`docs/A2A_Technical_Design.md`](docs/A2A_Technical_Design.md) — full
  technical design: data model, client methods, transport layer, error
  mapping, and the current known-gaps list (§12).
- [`LEARNING_LOG.md`](LEARNING_LOG.md) — accumulated lessons from building
  this library.
