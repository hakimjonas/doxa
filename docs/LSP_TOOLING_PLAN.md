# Doxa LSP and editor tooling plan

## Decision

The Doxa LSP server is the semantic authority for every editor client. VS Code
is the reference client because its standard language client adds little
client-specific protocol or scheduling logic. Zed and Helix are the next
editor targets: they are platforms Doxa users may choose directly, and they
exercise the standard LSP contract without an IntelliJ-specific adapter.

JetBrains support remains compatible with IntelliJ Community Edition and
Android Studio. It uses LSP over stdio and IntelliJ Platform APIs that are
available in Community Edition. It is deferred until the VS Code, Zed, and
Helix support paths are implemented and validated. JetBrains work is not a
gate for the open-editor tooling release.

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

The current server baseline also includes:

- Per-URI document state, versioned diagnostics, and open-document import
  overrides.
- Rumil token- and declaration-level reparsing plus a persistent semantic
  session that reuses an unchanged declaration prefix.
- Imported-file invalidation for open documents and watched-file events.
- Semantic hover and definition, semantic tokens, formatting, references, and
  safe rename for source-backed top-level declarations.
- Cross-file references and rename through the transitive resolved import
  closure. Imported disk snapshots participate only when no open document owns
  that URI.

The tooling suite, VS Code extension test, and executable check pass for this
baseline. VS Code manual validation is the next gate. Zed and Helix have not
yet received a support decision or integration work.

## Current work sequence

1. Complete the VS Code manual checklist and add regressions for any LSP or
   adapter defect found there.
2. Run the two-working-day Zed and Helix discovery.
3. Implement and validate the support path selected for each editor.
4. Resume the JetBrains client only after the preceding open-editor work is
   complete.

The server keeps state per URI. Clients use versioned asynchronous snapshots;
no client may block its UI thread on server I/O. Semantic tokens, folding
ranges, document symbols, and inlay hints are refreshed asynchronously. The
protocol suite and a real standard-client validation are the primary evidence
that server behavior follows LSP rather than one client's assumptions.

## Architecture contract

### Incremental syntax and checking

Rumil's green/red tree and incremental reparse facilities are a required part
of Doxa's compiler and editor architecture. They were introduced so Doxa can
retain syntax structure across edits, avoid parsing an entire document for a
local change, and provide editor feedback at interactive latency. They must not
remain an auxiliary CST used only by experiments or tests.

The current LSP retains a green tree and applies Rumil `TextEdit`s, including
declaration-level reparsers. It constructs a fresh surface AST for each valid
source revision, then compares complete declarations with the persistent
semantic session. The session reconstructs the unchanged prefix environment
from retained declaration deltas and re-elaborates the changed suffix. Import
caching avoids repeated resolution until a root import or imported dependency
changes.

#### Syntax contract

- Retain source text, green tree, parsed declaration sequence, and checker
  session state for each open URI. Red trees are transient offset views and are
  constructed only for a position query or reparse operation.
- A token-level Rumil update is valid only when local retokenization proves
  that the edited region remains one token of the same simple token class and
  has the same boundaries. Text heuristics such as a punctuation regular
  expression are insufficient: an identifier edit can form a keyword or a
  comment delimiter.
- `rumil_tokens.Identifier` maps to `DoxaToken.ident`. Unrecognized token
  classes must not silently enter the error-token fast path.
- A declaration reparser must consume exactly one declaration region. Leading
  and trailing whitespace may be sibling tokens at the source-file level. If
  an edit splits, merges, or leaves recovery text around a declaration, it
  must fall back to a whole-source Rumil reparse. The lossless invariant remains
  `green.toSource() == source` for valid and invalid text.
- Green-node identity is a reuse hint only. Rumil preserves off-path siblings
  during a splice, but interning can make equal nodes identical and a result
  does not report its changed path. Semantic invalidation uses the parsed
  declaration sequence and exact unchanged source prefixes.

#### Incremental semantic session

`web_check.dart` owns an internal persistent `IncrementalCheckSession`.
The public `checkSourceOutput`, `checkSourceWithCache`, JSON, and CLI APIs keep
their fresh-check behavior until callers explicitly opt into a session.

- Resolve the root file's imports into a frozen import baseline. The baseline
  contains finalized imported bindings, data declarations, namespaces,
  typeclass registry, and source provenance. A check creates a fresh
  `ImportState`; mutable import maps and lists are never shared with an earlier
  check.
- Record one result for each complete top-level `SDecl`: its source slice and
  structural fingerprint, finalized binding and data-declaration deltas,
  class-registry and namespace deltas, declaration summaries, semantic
  metadata, and diagnostics. A failed declaration records diagnostics but adds
  no declarations to the environment.
- Do not store `TopEnv`, `Ctx`, `Env`, `MetaContext`, or `DeclResult` in a
  checkpoint. Meta contexts are per declaration, and only
  `checkDeclResult`'s finalized bindings are valid in a later declaration.
- Do not retain full environment snapshots after every declaration. Rebuild the
  required prefix environment from the frozen import baseline and the retained
  declaration deltas. This avoids quadratic retained memory while still
  avoiding prefix elaboration.
- On a valid edit, compare the old and newly parsed complete declarations and
  reuse the longest prefix whose source text, structure, and absolute spans are
  unchanged. Re-elaborate from the first changed declaration through EOF.
  This conservative suffix rule is required until Doxa has a semantic
  dependency graph: later declarations may depend on earlier transparent
  definitions, namespaces, class instances, and duplicate-name state.
- A full Rumil reparse does not by itself require a full semantic check. If the
  newly parsed program proves an unchanged declaration prefix, the session can
  reuse it. A root import change, changed filename or configuration, changed
  imported dependency, or changed import-resolution baseline invalidates all
  declaration records.
- If whole-source parsing fails, publish only parse diagnostics and retain the
  prior records privately as candidates for a later valid source revision.
  Do not expose stale semantic information through hover, definition, symbols,
  hints, or semantic tokens after a failed check.
- Mutual `fun` and `data` blocks are one `SDecl` and must be re-elaborated as
  one atomic unit. A declaration may produce multiple bindings, data
  declarations, constructors, generated recursors, or typeclass entries, so
  invalidation and metrics count both surface declarations and produced output
  separately.
- Normal forms are evaluated in the final environment. Preserve completed
  normal forms for the unchanged prefix and compute normal forms for the
  rechecked suffix only after the final environment is available.

#### Imported-file invalidation

- Track the resolved import paths used by every open document.
- A changed open import or `workspace/didChangeWatchedFiles` notification
  invalidates the dependent documents' import baselines and sessions before
  they are rechecked.
- Publish diagnostics with the checked document version. Future asynchronous
  checking must discard results whose version is no longer current.

#### Validation and telemetry

- Compare every incremental session result with a cold `checkSourceOutput` run
  for the same source, including error ordering and spans.
- Test token edits that preserve and change lexical class; declaration-body
  edits; declaration insertion, removal, split, and merge; parse failure and
  repair; typeclass and namespace changes; mutual blocks; import-path changes;
  changed imported files; and non-BMP UTF-16 positions.
- Test Rumil source reconstruction after token-level, declaration-level, and
  full reparses.
- Under `DOXA_LSP_TRACE_TIMING=1`, report parse time, check time, total time,
  Rumil strategy, recheck start index, reused declaration count, rechecked
  declaration count, and any full-fallback reason. Persistent LSP timings,
  rather than one-shot CLI timings, are the editor latency measure.

Completion criteria:

- A local edit preserves green siblings outside Rumil's reparse region and
  never violates lossless source reconstruction.
- A semantic session reuses the unchanged declaration prefix and produces the
  same output as a cold check.
- A root import or imported-file change invalidates every affected session.
- Parser and checker telemetry identifies the syntax strategy, semantic
  invalidation boundary, reused prefix, and fallback reason for each edit.

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

### Editor clients

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

### Syntax infrastructure

Rumil and Doxa own the authoritative surface syntax, semantic parser, and
incremental editor tree. Tree-sitter is an interoperability backend for editors
that require a Tree-sitter grammar; it does not replace Rumil or elaborate
Doxa source.

- Do not attempt to serialize the current executable `Parser` ADT directly.
  Its predicates, deferred rules, semantic actions, and Pratt callbacks are
  arbitrary Dart closures.
- If shared syntax backends become necessary, first introduce a declarative
  Rumil grammar IR with named rules, explicit references, terminals, sequence,
  choice, repetition, precedence, fields, conflicts, trivia, aliases, and
  external tokens.
- Keep AST construction, source spans, desugaring, and elaboration as Dart
  semantic actions outside that IR. A Rumil lowering supplies those actions;
  a Tree-sitter lowering emits syntax only.
- Generate Tree-sitter `grammar.json` from the IR. External scanner behavior,
  such as Doxa's nested block comments, remains a separately tested C source.
- Test generated grammars against Doxa's existing stdlib and parser corpus.
  Until equivalence criteria are met, the Rumil parser remains authoritative.

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

### 3. Automated server workflows

Complete every advertised standard-LSP workflow against the server before
testing it in an editor. Exercise real stdio framing in addition to direct
handler calls, so protocol shape, ordering, cancellation, and lifecycle bugs
cannot hide behind a client adapter.

Completion criteria:

- The suite covers valid and invalid documents, server initialization and
  shutdown, open/change/close/reopen, arbitrary framing boundaries, malformed
  requests, notifications, cancellation, process restart, and UTF-16
  positions.
- Every advertised request has exact assertions for result shape, URI, range,
  document version, diagnostics, and empty/error behavior.
- Multi-file imports cover on-disk changes, unsaved open imports, close/revert
  behavior, and dependent-document invalidation.
- Server outputs are independent of the requesting editor client.

### 4. VS Code client validation

Use `editors/vscode/` as the first real editor client. It delegates normal
document synchronization, diagnostics, cancellation, and process lifecycle to
`vscode-languageclient`, so failures here distinguish a server/LSP defect from
an editor-adapter defect more directly than the JetBrains plugin.

Completion criteria:

- The extension bundles and packages successfully and starts the configured
  `doxa lsp` executable.
- Automated extension tests cover activation, document synchronization, and
  the core LSP workflows supported by VS Code.
- A manual VS Code pass occurs only after the server and extension suites are
  green. It covers startup failure, server restart, invalid and repaired text,
  cross-file imports, unsaved imported files, navigation, completion, hover,
  rename, formatting, semantic tokens, and diagnostics.
- Findings reproduce in the server suite when they concern the LSP contract;
  VS Code-specific behavior receives extension coverage.

### 5. Open-platform validation and syntax backends

#### Discovery, timeboxed to two working days

After VS Code manual validation, run a two-working-day discovery for Zed and
Helix before committing to either editor adapter. The discovery uses the
current `doxa lsp` executable and a representative multi-file workspace. It
records installation flow, language-server launch configuration, grammar and
highlighting requirements, semantic-token support, watched-file behavior,
workspace edits, restart behavior, extension distribution, and upstream
maintenance activity.

The discovery produces one of these support decisions for each editor:

1. Ship a first-party integration or upstream configuration and grammar
   contribution.
2. Publish and test a user configuration while a first-party path matures.
3. Defer support because the required editor workflow is unavailable or
   upstream maintenance does not justify an integration.

The discovery is complete when the repository records the evidence and support
tier for both editors. It does not include implementing a grammar or
integration.

Helix uses `languages.toml` for user and project-local language-server
configuration. Its documented LSP feature set includes formatting, navigation,
references, hover, completion, diagnostics, rename, and inlay hints. It does
not list semantic tokens, so a Doxa grammar and highlight queries remain the
expected presentation path there.

#### Native syntax and integrations, when selected by discovery

Do not write a standalone Doxa `grammar.js` as a competing syntax authority.
If an editor needs native syntax support, grammar work has two deliverables:

1. A Rumil-owned declarative grammar IR and lowering strategy, with explicit
   backend capability diagnostics.
2. A generated `tree-sitter-doxa` grammar plus queries and minimal Zed and
   Helix integrations that launch `doxa lsp`.

Completion criteria for native syntax and integrations:

- The IR has named recursive rules and can express Doxa's syntax without
  encoding semantic actions as closures.
- The Tree-sitter parser handles the accepted syntax corpus, incomplete text,
  and nested block comments through a tested external scanner.
- Tree-sitter highlighting, bracket matching, indentation, outline, and text
  objects use queries over the generated concrete tree.
- The Zed and Helix integrations only register Doxa, supply the grammar where
  required, and launch `doxa lsp`; semantic behavior remains standard LSP.
- The grammar corpus includes the Doxa stdlib and parser fixtures, with
  structural assertions for declarations, expressions, comments, and recovery.

### 6. Deferred JetBrains client

JetBrains work resumes only after the VS Code completion gate and the selected
Zed and Helix support paths are implemented and validated. It does not block
support for the open-editor set. The existing plugin remains in the repository
and its current behavior must continue to build, but it receives no new
workflow work during the open-editor phase.

#### Client foundation after resumption

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

#### Core editor workflows after resumption

Implement and verify the workflows Doxa users rely on daily before optional
presentation features:

1. Diagnostics and semantic highlighting.
2. Completion and hover.
3. Go to declaration and references/find usages.
4. Rename, including multi-file workspace edits.
5. Full-document formatting.
6. Document symbols, structure view, folding, and breadcrumbs where supported.
7. Signature help and inlay hints.

Code Lens remains unadvertised while it only repeats explicit declaration
types. Retain the server-side request path for future proof-tooling actions,
such as showing goals, normal forms, or generated eliminators. Do not expose
inert clickable-looking entries.

Completion criteria:

- Each workflow has a server test, a VS Code validation case, and a JetBrains
  integration or component test where the JetBrains adapter implements it.
- Unsupported server capabilities are not registered or advertised as working.
- Errors and empty results are distinguishable in logs and user-facing behavior.

### 7. Workspace behavior and proof-assistant ergonomics

Add watched-file notifications for imports, then evaluate Doxa-specific LSP
extensions only after the standard contract is stable. Candidate features
include goals at cursor, normalized types, proof-state views, and proof-aware
code actions. Each extension must have a stable protocol description before a
client consumes it.

Completion criteria:

- Imported-file edits cause dependent open files to be rechecked.
- Standard LSP behavior remains usable in the supported open editors without
  any Doxa-specific extension.
- Doxa-specific UI does not hide or replace ordinary diagnostics.

### 8. Semantic tooling and language documentation

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
5. Map the expanded semantic-token legend to each client without changing the
   server legend. Keep lexical highlighting as the immediate fallback while
   semantic results are pending.

Completion criteria:

- Hover succeeds for declaration names, resolved uses, all user-visible
  keywords, and compiler primitives.
- Source-backed symbols navigate to their declaration across files. Virtual
  built-ins navigate to a readable, stable documentation target when useful.
- Semantic-token tests assert declaration/reference roles, kinds, modifiers,
  ranges, and UTF-16 positions.
- Client tests assert that semantic colors replace, rather than erase, lexical
  fallback colors after a successful LSP response.
- No hover or navigation request exposes raw metavariables, generated names,
  or core syntax by default unless the user explicitly selects that view.

### 9. Release gate and hosted Wasm update

The hosted Wasm checker remains on its current version until the LSP work is
ready. Before updating `ardaproject.org/doxa`, verify that browser, CLI, VS
Code, and the selected Zed and Helix support paths use the same Doxa release
and agree on syntax, checking, diagnostics, and formatting. JetBrains joins
this gate when its deferred client phase resumes.

Completion criteria:

- Kernel and tooling tests pass, including the LSP suite.
- The VS Code extension passes its test suite. Zed and Helix meet the support
  tier selected by the discovery. JetBrains builds and passes its test suite
  when its deferred client phase resumes.
- The latest Wasm build is manually tested against representative standard
  library and proof examples.
- Website binary, package versions, extension metadata, and release notes are
  updated together.

## Compatibility and distribution

- VS Code is the reference client. Zed and Helix receive the support tier
  selected by the discovery before new JetBrains workflow work begins.
- The deferred JetBrains plugin targets IntelliJ Community Edition. Test
  commercial JetBrains IDEs as additional supported hosts where platform APIs
  permit.
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
- VS Code bundle, package, and extension test tasks once they are added.
- Tree-sitter generation and corpus tests once the grammar backend exists.
- `./gradlew buildPlugin` and JetBrains test tasks after the JetBrains phase.
- `git diff --check`.
- Manual smoke tests begin in VS Code after automated server and extension
  coverage is green. JetBrains manual tests follow its completion phase.
