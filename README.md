# ballerina/a2a
A Ballerina client library for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org)
— the open standard that lets AI agents built by different teams, in different
languages, discover and call each other over a shared wire protocol.

`ballerina/a2a` is the client half: given any A2A-compliant agent's URL, discover
its capabilities and call it — send messages, stream responses, manage tasks,
configure push notifications — the same way regardless of which language,
framework, or protocol dialect that agent happens to speak underneath.

**Status**: client-side is complete and verified against real,
independently-built reference agents, not just this library's own mocks.
Server/listener support — letting a Ballerina program *be* an A2A agent,
not just call one — is the next phase; see [Roadmap](#roadmap).

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
dialect or the legacy v0.3 one, and translates transparently — the calling
code above is identical either way.

## What's here

- **All 11 spec operations** (§9.4) — `sendMessage`, `sendStreamingMessage`,
  `getTask`, `cancelTask`, `subscribeToTask`, `listTasks`, the three
  push-notification-config operations, and `getExtendedAgentCard`.
- **All three transport bindings** (§5), each its own client type
  (`JsonRpcClient`, `RestClient`, `GrpcClient`), plus `Client`, which lets
  the Agent Card pick the binding automatically. All four implement the
  shared `AgentClient` interface.
- **Both wire dialects** — current v1.0 and the legacy v0.3 dialect —
  detected from the resolved `AgentCard` and translated transparently.
- Hardening features: extension negotiation, automatic SSE reconnection,
  AgentCard signature verification, and AgentCard caching — all opt-in.

## Repo layout

- `*.bal` (root) — the library itself: the four client types, the shared
  error hierarchy (`errors.bal`), the v0.3 compatibility layer
  (`compat_v03.bal`), and the transport-agnostic request/response plumbing
  (`operations.bal`) they all share.
- `modules/transport/`, `modules/grpcstub/` — internal wire-format types
  (hand-written JSON-RPC envelope, and the protoc-generated gRPC stub);
  neither is exported at the package boundary.
- `tests/` — the package's own mock-based test suite.
- `proto/` — the vendored A2A gRPC proto, source of `modules/grpcstub/`.
- `scripts/` — dev tooling: regenerating the gRPC stub, mutation testing.

## Testing

441 tests passing, 0 failing (`bal test --sticky` — see the note on `http`
pinning in `Ballerina.toml` for why `--sticky` matters here). Real-server
proof against independently-built agents lives in the companion
[`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests)
repo, deliberately kept separate.

## Roadmap

Deliberately deferred to a later phase (not started): `a2a:Listener` and a
service-object contract for exposing a Ballerina program as an A2A agent, a
`TaskStore` abstraction, and a push notification webhook receiver.

## Documentation

Full technical design, public-API provenance, and build history live in the
companion [`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests)
repo, under
[`docs/a2a-ballerina-design/`](https://github.com/Anuja-jayasinghe/a2a-interop-tests/tree/main/docs/a2a-ballerina-design).
