# Best practices

A living reference for the conventions this codebase follows, distilled from
real review feedback (the `module-ballerina-a2a` PR #3 client review) and
from auditing the server implementation against those same rules before its
own first release. Not aspirational — every rule here was either corrected
into the code at least once, or explicitly confirmed as the right call when
a simpler alternative was considered and rejected.

**Keep this updated.** When a review (a human's or a self-audit) surfaces a
new convention, or corrects an assumption in this file, update it in the
same commit or PR that applies the fix — don't let it drift from what the
code actually does.

## Control flow

- **`return;`, never `return ();`.** A function returning `T?`/`Error?`
  signals "nothing" with a bare `return;`. `return ();` is the same value,
  spelled with a needless nil literal.
- **No trailing `return ();`/`return;`** at the very end of a function body
  either — if control simply falls off the end, the implicit nil return
  already does the job; don't write it out.

## Formatting

- **120-column limit.** Don't wrap a line that fits within 120 columns —
  breaking short lines for no reason adds noise. Do wrap anything over 120,
  typically by moving the parameter list or a trailing clause to a
  continuation line indented one extra level.
- The one standing exception: a markdown `[label](url)` link in a doc
  comment is atomic and cannot be wrapped without breaking the link;
  spec-citation doc comments are allowed to run long for this reason alone.

## Naming

- Every function and variable name is a meaningful verb or noun that reads
  clearly at the call site (Clean Code, Robert C. Martin) — rename on sight
  if a name requires the reader to open the function body to know what it
  does.
- Match the file's own established naming pattern for sibling functions —
  e.g. every dispatcher operation handler is `onXxx`, every default-handler
  operation is the bare operation name (`getTask`, `cancelTask`).

## DRY — constants over repeated literals

- A literal used more than once — a header name, a path segment, a protocol
  version string, a media type — becomes a `const`, not a copy-pasted string.
- **Check for an existing constant before adding a new one.** Ballerina has
  no file-private scope: a `const`/function without `public` is
  package-private, visible from every file in the package. `HTTP_JSON`
  already lives in `client.bal`; server code reuses it rather than
  redeclaring `"HTTP+JSON"`.
- Place a new constant near where it's primarily used, not in a dedicated
  `constants.bal` by default — this codebase doesn't keep one, and a grab-bag
  file of unrelated literals is worse for locality than a constant declared
  at the top of the file that owns the concept it names.

## Simplification

- **Don't hand-write a stream generator class for a sequence you already
  have in full.** If every element is already computed before the stream is
  returned, build the array (or transform it in a loop) and call
  `.toStream()` — a class implementing `next()` that just pops off an
  in-memory list is machinery a language primitive already provides. (Cut
  twice in this codebase: the client's `SingleEventStreamGenerator` and the
  server's `StreamResponseEventGenerator`, both replaced by
  `array.toStream()` once a reviewer — or a self-audit — asked why they
  existed.)
- **Don't add a wrapper/delegate layer with only one real implementation
  behind it.** A `Client` that only ever forwards to one `HttpClient` is
  pure indirection; collapse it into the one concrete type. Reintroduce the
  wrapper when a second real implementation exists to select between (e.g.
  a future JSON-RPC or gRPC server binding) — the seam should follow the
  need, not precede it speculatively.
- **One method per operation**, not one method with nested `if`/`else`
  dispatching across several operations. If a routing function ends up
  branching into four genuinely different pieces of logic (as the
  push-notification-config CRUD paths did), split it into four small
  functions once the shared routing prefix has picked one.
- Before writing a new helper, grep for one that already does it. A second,
  slightly different reimplementation of query-parameter parsing (or
  anything else) is a sign the first one should just be reused.

## Ballerina-specific idioms

- **`ensureType` vs `cloneWithType`.** `ensureType` is a checked *cast*: it
  succeeds only if the value's existing runtime shape already satisfies the
  target type (e.g. `json` → `map<json>`, or `string` → a string-literal
  union/enum — no reshaping needed either way). `cloneWithType` is a
  structural *conversion*: it builds a new value of the target type,
  matching fields by name — the only correct choice whenever the target is
  a specific record type built from generic JSON (`json[]` → a typed record
  array, `map<json>` → an `AgentCard`, etc.). Using `ensureType` where
  `cloneWithType` is needed doesn't just fail to validate — it throws a
  `TypeCastError` at runtime, on every input, valid or not.
- **`lock` and value transfer.** A value born inside a `lock` block can't be
  returned (transferred) out of it directly unless the compiler can prove
  it's isolated; the working pattern is to declare the variable outside the
  lock, build/clone the value inside, assign it to the outer variable, and
  use it after the lock closes. Don't fight the isolation checker with casts
  — restructure around this pattern instead.
- **Isolated object/service typing.** An `isolated` object that holds
  another object and calls its methods needs that held object typed as
  `isolated object`/`isolated service object`, not the bare interface —
  otherwise the compiler can't prove the call itself is isolation-safe.
- **Package-private by default.** Omit `public` on anything only this
  package's own files need — a type, a function, a constant. Ballerina
  doesn't scope by file, so this doesn't block same-package access, but it
  keeps the package's actual public surface honest.

## Testing

- Prefer a **self-round-trip** over a mock wherever the codebase can
  provide one: this library's own client driving this library's own server
  in one process, exercising the real wire format both ends actually speak.
  A mock only proves the code matches what the mock was told to expect; a
  real second implementation (even this project's own) catches a
  disagreement a mock can't.
- Where a client-side self-gate makes an operation unreachable through the
  typed client (e.g. `capabilities.pushNotifications` staying `false` on
  purpose), verify the server's own behavior with a raw `http:Client`
  instead of skipping the test — the operation still needs proving even
  though the typed client won't exercise it.
- A branch that becomes unreachable by the codebase's own construction (an
  error path a capability flag ties off by design) still gets a direct unit
  test against the function, not the wire — it's real code serving a real
  future case, even if today's wiring never reaches it.

## Documentation

- Every public symbol needs a complete doc comment — `bal build` warns on
  anything undocumented, and a warning-clean build is the bar, not an
  aspiration. This is enforced continuously, not as a separate pass at the
  end.
- A doc comment that cites a specification section links to it
  (`https://a2a-protocol.org/latest/specification/#<anchor>`), not just the
  bare section number — fetch the real anchor from the spec rather than
  guessing one.
