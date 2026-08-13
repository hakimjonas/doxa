# Doxa LSP and editor tooling plan

## Decision

Doxa supports IntelliJ Community Edition and Android Studio. The JetBrains
plugin therefore remains independent of JetBrains' commercial-only LSP API.
It uses standard LSP over stdio and IntelliJ Platform APIs that are available
in Community Edition.

The Doxa LSP server is the semantic authority for VS Code and JetBrains. The
JetBrains plugin retains native support only for file recognition and editor
behavior that does not require semantic analysis: file type, lexical tokens,
comments, brace matching, and fallback highlighting.

The goal is correct, dependable, ergonomic tooling. A feature is incomplete
until its protocol behavior, IDE behavior, failure mode, and tests are in
place.

## Current baseline

The first repair pass completed these items:

- UTF-8 byte-counted `Content-Length` framing in the Dart server and Kotlin
  client.
- Generic JSON-RPC result handling rather than object-only results.
- Correct result-shape handling for definition, hover, formatting, folding,
  document symbols, Code Lens, and inlay hints.
- Rename without the unsupported `textDocument/prepareRename` gate, with
  reverse-ordered edits in an IntelliJ write command.
- Document versions, basic diagnostic caching, and removal of fixed sleeps.
- Basic lexer tokens for comments, strings, whitespace, and paired braces.
- JetBrains plugin packaging against IntelliJ Community 2025.1.

The server keeps state per URI. JetBrains background providers use versioned
asynchronous snapshots; explicit user actions such as navigation and hover may
wait for their own result away from the UI thread. Semantic tokens, folding
ranges, document symbols, and inlay hints are refreshed asynchronously. The
LSP protocol suite is only beginning.

## Architecture contract

### Incremental syntax and checking

Rumil's green/red tree and incremental reparse facilities are a required part
of Doxa's compiler and editor architecture. They were introduced so Doxa can
retain syntax structure across edits, avoid parsing an entire document for a
local change, and provide editor feedback at interactive latency. They must not
remain an auxiliary CST used only by experiments or tests.

The current LSP path still reparses and re-elaborates the full open document on
each change. Import caching avoids repeated import resolution but does not make
the edited document incremental. This is a known architectural gap.

- Retain the prior source text, green tree, red tree, and parsed declaration
  sequence for each open URI.
- Apply LSP changes as Rumil `TextEdit`s and use incremental reparse on every
  compatible edit.
- Register declaration-level reparse parsers for Doxa syntax kinds. The current
  `byKind: const {}` fallback is not sufficient.
- Reuse unchanged declarations and their elaboration outputs. An edit to
  declaration `n` invalidates that declaration and dependent later
  declarations; declarations before `n` keep their checked environment and
  semantic metadata.
- Fall back to a full parse and check only for import changes,
  declaration-boundary changes, parser recovery, or an invalid incremental
  result.
- Measure persistent LSP timings for parse, elaboration, diagnostics, and
  semantic-token publication. Do not infer editor latency from one-shot CLI
  process timings.

Completion criteria:

- A local expression edit uses Rumil incremental reparse and preserves green
  node identity outside the reparse boundary.
- The LSP re-elaborates only the edited declaration and declarations that
  depend on it.
- Parser and checker timing telemetry identifies the invalidation boundary for
  each edit.
- Tests cover simple-token edits, declaration-body edits, declaration-boundary
  edits, recovery after an invalid edit, and fallback to full parsing.

### Server

- Maintain document state per URI: text, version, diagnostic state, semantic
  result, import cache, and completion ranking data.
- Resolve every text-document request against the URI in its parameters.
- Use LSP's negotiated UTF-16 position encoding. Convert positions carefully
  at the boundary; Doxa internals may continue to use their own offsets.
- Honor document lifecycle notifications and reject or safely handle requests
  for unknown documents.
- Publish diagnostics for the URI and version that was checked. Do not let a
  later edit publish stale diagnostics over newer content.
- Support cancellation at request boundaries. Long-running checks must be
  cancellable or their obsolete result must be discarded.
- Return standard LSP response shapes and JSON-RPC errors. Do not rely on
  client-specific behavior.

### JetBrains client

- Use one project-scoped server process and a tested JSON-RPC transport.
- Synchronize open, change, close, save, and relevant external file events.
- Do not block the UI thread. Requests must be asynchronous, cancellable, and
  bounded by feature-appropriate deadlines.
- Preserve IDE cancellation and freshness semantics: a response for an old
  document version must not alter the current editor state.
- Report missing binaries, failed initialization, and server exits through
  actionable IDE notifications and logs.
- Restart the server after a crash or binary-path change without requiring a
  project restart.
- Apply workspace edits through IDE commands with correct URI handling,
  descending ranges, undo grouping, and support for all standard edit forms.

## Work sequence

### 1. Server document correctness

Refactor `doxa_tooling/lib/src/lsp/handler.dart` from singleton document fields
to a URI-indexed document store. Make all current handlers select the requested
document explicitly. Preserve import caching only where the cache belongs to
the same document and dependency state.

Completion criteria:

- Two open `.doxa` files retain independent text, diagnostics, semantic data,
  and versions.
- Requests for either URI return results for that URI after interleaved edits.
- UTF-16 positions work for non-ASCII source text.
- Server integration tests cover interleaved multi-file traffic.

### 2. Tested LSP protocol boundary

Build server tests around a subprocess or in-memory framed transport. Cover
framing across arbitrary byte boundaries, non-ASCII JSON, malformed messages,
JSON-RPC errors, request cancellation, and the document lifecycle.

Completion criteria:

- `doxa_tooling/test` covers initialize, open/change/close, diagnostics,
  hover, definition, completion, semantic tokens, references, rename,
  formatting, folding, symbols, inlay hints, and shutdown.
- Tests assert protocol values, including URIs, versions, ranges, and UTF-16
  offsets, rather than only checking that a response exists.

### 3. JetBrains client foundation

Replace synchronous provider calls with a single asynchronous request layer.
Wire document and virtual-file lifecycle listeners. Add process monitoring,
restart behavior, configuration-change handling, and user-visible failures.

Completion criteria:

- No language feature blocks the UI thread on server I/O.
- Closing a file sends `didClose`; editor changes send correct ordered versions.
- The client recovers from a process exit and a changed binary setting.
- A missing or non-executable binary produces an installation/configuration
  notification, not only a log entry.
- Kotlin tests cover framing, response correlation, cancellation, process
  lifecycle, and document synchronization.

### 4. Core editor workflows

Implement and verify the workflows Doxa users rely on daily before optional
presentation features:

1. Diagnostics and semantic highlighting.
2. Completion and hover.
3. Go to declaration and references/find usages.
4. Rename, including multi-file workspace edits.
5. Full-document formatting.
6. Document symbols, structure view, folding, and breadcrumbs where supported.
7. Signature help and inlay hints.

Code Lens is presentation-only until Doxa defines commands with useful,
safe user actions. Do not expose inert clickable-looking entries.

Completion criteria:

- Each workflow has a server test and a JetBrains integration or component
  test.
- Unsupported server capabilities are not registered or advertised as working.
- Errors and empty results are distinguishable in logs and user-facing behavior.

### 5. Workspace behavior and proof-assistant ergonomics

Add watched-file notifications for imports, then evaluate Doxa-specific LSP
extensions only after the standard contract is stable. Candidate features
include goals at cursor, normalized types, proof-state views, and proof-aware
code actions. Each extension must have a stable protocol description before a
client consumes it.

Completion criteria:

- Imported-file edits cause dependent open files to be rechecked.
- Standard LSP behavior remains usable in VS Code and JetBrains without any
  Doxa-specific extension.
- Doxa-specific UI does not hide or replace ordinary diagnostics.

### 6. Semantic tooling and language documentation

Bring the semantic editor experience to the standard expected of modern
language tooling. LSP defines request and token formats; Doxa must supply
language-specific classification, documentation, instantiated types, and
source provenance.

1. Complete hover coverage for language keywords and compiler primitives.
   Keywords have documentation but no definition target. Compiler primitives
   without source declarations use stable virtual documentation URIs.
2. Preserve source provenance for source declarations, constructors,
   projections, generated recursors, and imported declarations. Go to
   Definition must distinguish source-backed targets from virtual targets.
3. Classify declaration and reference occurrences separately. Extend semantic
   metadata and token modifiers for declarations, reads, writes where Doxa
   permits writes, implicit parameters, type parameters, constructors,
   projections, generated declarations, and typeclass members.
4. Present dependent types readably. Hover shows the resolved declaration type
   instantiated at the cursor; normalization and implicit-argument detail are
   opt-in views rather than the default display.
5. Map the expanded semantic-token legend to independently configurable
   JetBrains attributes. Keep lexical highlighting as the immediate fallback
   while semantic results are pending.

Completion criteria:

- Hover succeeds for declaration names, resolved uses, all user-visible
  keywords, and compiler primitives.
- Source-backed symbols navigate to their declaration across files. Virtual
  built-ins navigate to a readable, stable documentation target when useful.
- Semantic-token tests assert declaration/reference roles, kinds, modifiers,
  ranges, and UTF-16 positions.
- JetBrains tests assert that semantic colors replace, rather than erase,
  lexical fallback colors after a successful LSP response.
- No hover or navigation request exposes raw metavariables, generated names,
  or core syntax by default unless the user explicitly selects that view.

### 7. Release gate and hosted Wasm update

The hosted Wasm checker remains on its current version until the LSP work is
ready. Before updating `ardaproject.org/doxa`, verify that browser, CLI, VS
Code, and JetBrains use the same Doxa release and agree on syntax, checking,
diagnostics, and formatting.

Completion criteria:

- Kernel and tooling tests pass, including the LSP suite.
- The JetBrains plugin builds and passes its test suite on the supported
  Community baseline.
- The latest Wasm build is manually tested against representative standard
  library and proof examples.
- Website binary, package versions, extension metadata, and release notes are
  updated together.

## Compatibility and distribution

- The plugin targets IntelliJ Community Edition first. Test commercial
  JetBrains IDEs as additional supported hosts where platform APIs permit.
- Do not depend on `com.intellij.modules.lsp`.
- The plugin starts `doxa lsp` from the configured executable path or PATH.
  Do not bundle platform-specific binaries without a separate distribution and
  update strategy.
- The monorepo at `editors/jetbrains/` is authoritative. The external
  `doxa-jetbrains` repository is superseded.

## Quality gates

- `dart format --set-exit-if-changed` and `dart analyze` for affected Dart
  packages. Existing warnings must be tracked separately; new warnings are not
  acceptable.
- `dart test` for kernel and tooling packages.
- `./gradlew buildPlugin` and JetBrains test tasks.
- `git diff --check`.
- Manual smoke tests in IntelliJ Community Edition with a missing binary, a
  valid binary, a server crash, one file, and two interleaved open files.
