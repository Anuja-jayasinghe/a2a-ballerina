# A2A v0.3 client compatibility — design

## Context

Testing `ballerina/a2a`'s `Client` against the `adk_currency_agent` reference
agent (from `a2aproject/a2a-samples`, used to prepare for an upcoming demo)
surfaced a real interop blocker, not just another vendor quirk like the
`helloworld` server's non-conformances: this agent's `AgentCard` declares
`"protocolVersion": "0.3.0"`, and it genuinely only understands the older
A2A protocol v0.3 wire format. Confirmed empirically:

- Card discovery succeeds (the card has no `supportedInterfaces`, only a
  legacy top-level `url`, and `primaryUrl()`'s existing fallback already
  handles that case correctly).
- Every actual RPC call fails: sending `SendMessage` (our client's v1.0
  method name) gets back `{"error":{"code":-32601,"message":"Method not
  found"}}`. The same request with `message/send` (the v0.3 method name)
  succeeds and returns a real currency conversion.

`ballerina/a2a`'s `Client` currently only ever speaks v1.0 (PascalCase
JSON-RPC method names, wrapped `SendMessage` responses, `SCREAMING_SNAKE_CASE`
enum values). This design adds v0.3 compatibility so the client can talk to
either kind of server, with the version difference fully absorbed inside the
client — callers write identical code regardless of which protocol version
the remote agent speaks.

## Decisions made during brainstorming

- **Detection**: auto-detect from `AgentCard.protocolVersion` rather than an
  explicit caller-supplied flag or a fallback-on-error retry.
- **Scope**: all 5 operations (`sendMessage`, `sendMessageStream`, `getTask`,
  `cancelTask`, `subscribeToTask`), not just enough to unblock the demo's
  happy path.
- **Type mapping**: v0.3 responses are translated into the exact same
  `Task`/`Message`/`Role`/`TaskState`/`StreamResponse` types the client
  already returns for v1.0 servers — no parallel v0.3-flavored result types.
  Callers never branch on which protocol version they're talking to.
- **Card plumbing**: `Client.init` gains an optional `AgentCard? agentCard`
  parameter. Omitting it keeps today's exact v1.0-only behavior (fully
  backward compatible with every existing caller); passing the card the
  caller already got from `resolveAgentCard` triggers auto-detection.

## Spec grounding

Confirmed against `https://a2a-protocol.org/latest/whats-new-v1/` and the
actual installed `a2a-sdk` Python package's `a2a/compat/v0_3/types.py`
(pydantic definitions — more authoritative than the doc's prose summary):

**Note on migration-guide reliability**: the same migration-guide page
repeats a streaming-event-shape claim (`taskStatusUpdate`/`taskArtifactUpdate`
keys, an `index` field) that this project already empirically disproved
against a real v1.0 server (see `a2a-interop-tests/servers/helloworld/
findings.md` — real shape is `statusUpdate`/`artifactUpdate`, no `index`).
This design trusts our own verified findings for the v1.0 side, not that
page, and treats the v0.3 side of the same page as needing the same
skepticism — hence cross-checking against the actual installed SDK source
below rather than relying on the guide's prose alone.

**Method names** (v0.3 → v1.0):

| v0.3 | v1.0 |
|---|---|
| `message/send` | `SendMessage` |
| `message/stream` | `SendStreamingMessage` |
| `tasks/get` | `GetTask` |
| `tasks/cancel` | `CancelTask` |
| `tasks/resubscribe` | `SubscribeToTask` |

**AgentCard**: v1.0 moved `protocolVersion` from the card's top level into
each `AgentInterface.protocolVersion` (already modeled in this codebase's
`AgentInterface` type) and moved `url` into `supportedInterfaces[0].url`
(already handled by `primaryUrl()`). A card with no `supportedInterfaces` is
a legacy (v0.3) card, which is the same signal `primaryUrl()` already relies
on for its own fallback.

**Role**: `"user"` → `ROLE_USER`, `"agent"` → `ROLE_AGENT`.

**TaskState** (8 states, confirmed against the spec page):

| v0.3 | v1.0 |
|---|---|
| `submitted` | `TASK_STATE_SUBMITTED` |
| `working` | `TASK_STATE_WORKING` |
| `completed` | `TASK_STATE_COMPLETED` |
| `failed` | `TASK_STATE_FAILED` |
| `canceled` | `TASK_STATE_CANCELED` |
| `rejected` | `TASK_STATE_REJECTED` |
| `input-required` | `TASK_STATE_INPUT_REQUIRED` |
| `auth-required` | `TASK_STATE_AUTH_REQUIRED` |

**Part** (confirmed against `a2a/compat/v0_3/types.py`'s `TextPart`,
`FilePart`, `FileWithBytes`, `FileWithUri`, `DataPart` classes): v0.3 uses a
`"kind"` discriminator instead of v1.0's field-presence discrimination.

| v0.3 wire shape | v1.0 `Part` fields |
|---|---|
| `{"kind":"text","text":"..."}` | `{text: "..."}` |
| `{"kind":"file","file":{"bytes":"...","mime_type"?,"name"?}}` | `{raw: <decoded bytes>, mediaType?, filename?}` |
| `{"kind":"file","file":{"uri":"...","mime_type"?,"name"?}}` | `{url: "...", mediaType?, filename?}` |
| `{"kind":"data","data":{...}}` | `{data: {...}}` |

**`sendMessage` response**: v0.3 is unwrapped — the JSON-RPC `result` *is*
the task or message directly, tagged `"kind":"task"`/`"kind":"message"` —
unlike v1.0's `{"task":{...}}`/`{"message":{...}}` wrapper
(`SendMessageResult`).

**Stream events** (confirmed against `a2a/compat/v0_3/types.py`'s
`TaskStatusUpdateEvent`/`TaskArtifactUpdateEvent` classes): discriminated by
`"kind"`: `task`, `message`, `status-update`, `artifact-update`. v0.3's
`TaskStatusUpdateEvent` also carries a `final: bool` field with no v1.0
equivalent — safe to drop, since terminal-ness is re-derived from the
translated `TaskState` the same way it already is for v1.0 streams.

**Header negotiation**: the spec describes per-interface `A2A-Version`
header validation. Empirically this didn't gate the currency agent's
behavior either way, but sending `A2A-Version: 0.3` in v0.3 mode is the
spec-correct thing to do and costs nothing.

## Architecture

One new file, `compat_v03.bal`, at the `a2a` package root — not a separate
submodule. `sse.bal`'s existing header comment explains why: a submodule
under `modules/` can't import the root module without a cyclic dependency,
which is exactly why SSE decoding and `toA2AError` already live at the root
instead of in `modules/transport/`. The same constraint rules out a
`modules/a2a.compat` submodule here.

`Client` gains a private field, `ProtocolMode mode` (a
`"V1_0"|"V0_3"` string union), detected once at construction and threaded
through every private helper (`rpcCall`, `openSseStream`) and into the SSE
generator. Every public method signature and every returned type (`Task`,
`Message`, `Role`, `TaskState`, `StreamResponse`, ...) is unchanged — mode
is purely an internal detail a caller never sees or branches on.

## Components & data flow

**`AgentCard` type change** (`types.bal`): add one new optional field,
`string? protocolVersion?;`, documented as the pre-v1.0 legacy top-level
location, superseded by `supportedInterfaces[].protocolVersion`, kept only
for detecting legacy cards.

**Detection** (`compat_v03.bal`):

```
public type ProtocolMode "V1_0"|"V0_3";

isolated function detectProtocolMode(AgentCard card) returns ProtocolMode {
    if card.supportedInterfaces.length() > 0 {
        string? v = card.supportedInterfaces[0]?.protocolVersion;
        return (v is string && v.startsWith("0.")) ? "V0_3" : "V1_0";
    }
    string? v = card?.protocolVersion;
    return (v is string && !v.startsWith("0.")) ? "V1_0" : "V0_3";
}
```

A card with `supportedInterfaces` set uses that interface's declared
version; a legacy card (no `supportedInterfaces` — the same signal
`primaryUrl()` already uses) defaults to `V0_3` unless its top-level
`protocolVersion` explicitly says otherwise.

**Client construction** (`client.bal`): `Client.init` gains
`AgentCard? agentCard = ()`. When given, `self.mode =
detectProtocolMode(agentCard)`; when omitted, `self.mode = "V1_0"` — today's
exact behavior, unchanged for every existing caller.

**Outbound method-name translation**: a lookup table,
`v03MethodName(string v1Method) returns string`, used by `rpcCall` and
`openSseStream` when `mode == "V0_3"` to substitute the wire method name
before building the JSON-RPC request. `buildHeaders()` sends
`A2A-Version: 0.3` instead of `1.0` in that mode.

**Inbound decoding** (`compat_v03.bal`), all converting straight into the
existing v1.0 types:

- `mapV03Role`, `mapV03State` — table lookups per the mappings above.
- `parseV03Part(json) returns Part|error` — dispatches on `"kind"`, maps
  `file`'s nested `bytes`/`uri` variants to `Part.raw`/`Part.url`.
- `parseV03Task`, `parseV03Message` — parse the unwrapped v0.3 shapes into
  the existing `Task`/`Message` records.
- `decodeV03SendResult(json) returns Task|Message|error` — reads the
  top-level `"kind"` to choose `parseV03Task` or `parseV03Message`; replaces
  `SendMessageResult.cloneWithType` for `sendMessage` in v0.3 mode.
- `decodeV03StreamEvent(json) returns StreamResponse|error` — same `"kind"`
  dispatch across `task`/`message`/`status-update`/`artifact-update`,
  producing the same `StreamResponse` type either mode returns.
- `decodeTaskResult(json) returns Task|error` — small shared helper used by
  `getTask`/`cancelTask`, branching between today's `cloneWithType(Task)`
  and `parseV03Task`.

**`sse.bal`**: `A2AStreamGenerator` gains the same `ProtocolMode`; its
`decodeEvent` branches between `cloneWithType(StreamResponse)` (v1.0) and
`decodeV03StreamEvent` (v0.3). `isTerminalEvent` needs no change — it runs
after translation, so it always sees v1.0-shaped `TaskState` values
regardless of which wire dialect produced the event.

## Error handling

No new `A2AError` subtypes. `-32601 Method not found` already falls through
`toA2AError`'s default case to `A2AInternalError`, which is correct, generic
behavior whether it comes from a genuine version-detection miss or an
actually-unsupported method. `compat_v03.bal`'s parse functions return a
plain `error` on malformed/unrecognized JSON (an unknown `"kind"` value, a
state string outside the mapping table), surfacing the same way today's
`cloneWithType` failures already do.

## Testing

- **Unit tests** (`tests/`, mock-based): extend `testutil.bal`'s scripting
  to script v0.3-shaped mock responses (unwrapped, lowercase enums, `"kind"`
  discriminators), and construct `Client` with a synthetic `AgentCard`
  forcing `V0_3` mode via both detection paths (`supportedInterfaces`
  present vs. legacy top-level `protocolVersion`). Cover all 5 operations,
  the full stream-event dispatch table, and `detectProtocolMode` directly.
- **Interop test** (separate `a2a-interop-tests` repo, matching the existing
  `servers/helloworld` pattern): a new `servers/adk_currency_agent/` with
  `setup.md` (the `uv sync` / `GOOGLE_API_KEY` / `uv run currency_agent`
  steps already exercised by hand) and `findings.md` documenting the v0.3
  discovery itself, plus new interop tests exercising `sendMessage`/
  `sendMessageStream` end-to-end against the real running agent — this is
  what actually proves the compat layer works, beyond mocks.
