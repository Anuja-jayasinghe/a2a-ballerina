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
    // Discover the agent's capabilities and preferred transport
    a2a:AgentCard card = check a2a:resolveAgentCard("https://example.com/agent");
    a2a:Client agentClient = check new ("https://example.com/agent", agentCard = card);

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

**All three transport bindings** (§5) — a caller picks per-`Client`:
```ballerina
check new (url, agentCard = card, binding = "JSONRPC");  // default
check new (url, agentCard = card, binding = "HTTP+JSON"); // REST
check new (url, agentCard = card, binding = "GRPC");
```

**Both wire dialects** — current v1.0 and the legacy v0.3 dialect (different
JSON-RPC method names, enum casing, response wrapping) — detected from the
resolved `AgentCard`, translated transparently, zero caller-visible branching.

**Hardening features**, each opt-in/backward-compatible with pre-existing
callers:
- **`A2A-Extensions` header** — advertise/request extensions, capture what
  the server actually granted (JSON-RPC/REST header and gRPC metadata both).
- **AgentCard signature (JWS) verification** — `verifyAgentCardSignature`
  (RFC 7515, RS256/ES256), fail-closed. Known limitation: doesn't yet perform
  RFC 8785 JSON Canonicalization, so it only verifies signatures computed over
  this library's own JSON serialization, not a real external signer's — see
  the function's doc comment in `signature.bal` for the full reasoning.
- **AgentCard caching** — `resolveAgentCardCached`, ETag/`304`-aware.
- **Automatic SSE reconnection** — `maxReconnectAttempts` on
  `sendStreamingMessage`/`subscribeToTask`; opt-in, default `0` preserves the
  original manual-reconnect behavior.
- **Automatic client-auth wiring** — `buildAuthFromCard` (`auth.bal`) turns a
  parsed `AgentCard`'s API-key/HTTP-auth security scheme into a working
  `http:ClientConfiguration` automatically. OAuth2/OIDC/mTLS remain
  caller-wired by design — they need more than a single credential string.

**Genuinely still open**: mutual TLS — `MutualTlsSecurityScheme` is fully
typed in the data model, but `buildAuthFromCard` deliberately doesn't
auto-wire it (a client certificate isn't a single credential string the way
API-key/HTTP-auth are — see `auth.bal`'s module doc comment), and there's no
higher-level helper for it beyond what `http:ClientConfiguration.secureSocket`
already offers generically. Plus the JWS canonicalization gap noted above.
Full, current status: [`docs/A2A_Technical_Design.md`](docs/A2A_Technical_Design.md) §12.1
— though treat that section as a snapshot to re-verify against source, not a
live source of truth (parts of this design doc predate later features and
haven't all been updated to match).

## Testing

354 tests passing, 0 failing (`bal test --sticky` — see the note on `http`
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
