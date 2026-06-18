# Doxa Tooling Plan

A phased plan for building modern language tooling on the Doxa kernel,
dogfooding the rumil-dart ecosystem. The architecture anticipates future
expansion (modules, imports, tactics, multi-file projects) without
over-building for them today.

## Development discipline (read before every piece of work)

Before any piece of work is considered complete, all three of these must
be green:

```shell
dart analyze lib/      # 0 issues (not 0 errors — 0 issues total)
dart format lib/ test/ # no unformatted files
dart test              # all tests pass, no regressions
```

"Info" lints from the project's `analysis_options.yaml` count as issues.
A lint like `public_member_api_docs` means every public member needs a
doc comment. Do not waive or suppress lints — fix them.

The user rejects work that lands with analyze warnings, unformatted code,
or test failures. This is a hard gate.

---

## Principles

1. **Dogfood rumil-dart.** Doxa already uses `rumil` for parsing. Every
   new piece of tooling uses an existing rumil package or adds a Doxa
   grammar to one. No hand-rolled alternatives unless rumil genuinely
   cannot do it.

2. **The website is a dumb renderer.** The kernel/WASM produces
   structured data (JSON). The arda-web demo parses it and renders it.
   No semantic logic in JS, no regex-parsing of flat error strings.

3. **Layers, not a monolith.** Each phase builds a self-contained
   capability on top of the previous layer. A phase can ship and be
   useful without the later phases.

4. **Anticipate future expansion.** Every architectural decision works
   for the current single-file Doxa AND scales to multi-file projects,
   modules, tactics, and a full LSP server — without a rewrite.

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│  Layer 3: Semantic Metadata (InfoTree)           │
│  Per-position types, names, scopes               │
│  ─ Powers: hover, goto-def, completion           │
├──────────────────────────────────────────────────┤
│  Layer 2: Structured Check Output                │
│  Per-declaration summary: name, type, normal     │
│  form, span. Errors with kind/expected/actual.   │
│  ─ Powers: expandable declaration view, rich     │
│    success output, machine-readable diagnostics  │
├──────────────────────────────────────────────────┤
│  Layer 1: GreenNode Parse Tree (CST)             │
│  Lossless concrete syntax tree, incremental      │
│  reparse, position-indexed access.               │
│  ─ Powers: go-to-definition substrate,           │
│    precise error spans, source reconstruction    │
├──────────────────────────────────────────────────┤
│  Layer 0: Tokenizer & Highlighting               │
│  Classified token spans from rumil_tokens.       │
│  ─ Powers: syntax highlighting everywhere        │
│    (server, playground, cells), editor theming   │
└──────────────────────────────────────────────────┘
```

Each layer depends on the layers below it. Layers 0 and 2 can be built
in parallel. Layer 1 is needed for Layer 3 but not for Layer 2.

## Phase 0 — Tokenizer & Highlighting

**Goal:** Replace the hand-written Doxa lexer (duplicated in 3 places:
server-side Dart, playground JS, cells JS) with a single Doxa grammar
for `rumil_tokens`, the existing rumil package for lossless source
tokenization.

**Status:** `rumil_tokens` 0.10.0 exists. No Doxa grammar yet.

### Deliverables

1. **Doxa token grammar** in `rumil_tokens` format. A token alphabet
   and parser for the Doxa surface language that classifies every
   source span as one of:

   | Token class     | Examples                                      |
   |-----------------|-----------------------------------------------|
   | `keyword`       | `fun`, `data`, `val`, `type`, `match`, `case`, `returning`, `and` |
   | `sort`          | `Type`, `Prop` (universe sorts)               |
   | `type-name`     | Capitalized identifiers (`Nat`, `List`, `Bool`, `Vec`, `Eq`) |
   | `constructor`   | Lowercase identifiers known to be ctors (`zero`, `succ`, `nil`, `cons`, `refl`, `vnil`, `vcons`) |
   | `binder`        | Identifiers in binder position (lambda/Pi params, `fun` params, match binders) |
   | `comment`       | `//` line comments, `/* */` block comments (nestable) |
   | `number`        | Universe level numbers (`Type 0`, `Type 1`)   |
   | `punctuation`   | `(){}[]:;,|.`, `->`, `=>`                     |
   | `identifier`    | Everything else                               |
   | `error`         | Unexpected characters (resilient recovery)    |

   Notes:
   - `constructor` tokens require context (whether a lowercase ident
     names a constructor). The tokenizer may not have this context at
     lex time. Two options: (a) keep it as `identifier` and let
     semantic metadata refine it later, or (b) accept that the
     tokenizer is approximate (it's cosmetic). Lean toward (a) for
     now — tokenizer is lossless and cosmetic; semantic refinement
     comes in Layer 3.
   - The `binder` token class requires grammatical position (which
     identifiers introduce binders). The tokenizer can approximate
     this (identifiers immediately after `(`, after `fun`, or before
     `:` in a Pi/lambda are binders). The GreenNode tree in Layer 1
   gives us this precisely.

2. **Integration into arda-web.** Replace the three hand-written lexers
   with calls to the rumil_tokens Doxa grammar (or its pre-computed
   output). The tokenizer can run:
   - Client-side in WASM (fast, same dart2wasm path as the checker)
   - Or server-side at build time for static code blocks
   - Or both (same grammar, same output format)

3. **Unified CSS class names.** Settle on one set of CSS class names
   (`tok-keyword`, `tok-type`, `tok-comment`, etc.) across all
   rendering contexts.

### What this unlocks

- Single source of truth for highlighting everywhere
- Adding a new keyword in one place propagates to all renderers
- The tokenizer uses rumil's resilient parsing (handles incomplete/
  malformed source gracefully, always produces valid token spans)
- Foundation for GreenNode tree (Phase 1): the tokenizer's output is
  the leaf level of the CST

### Risks / unknowns

- The `binder` token class requires grammatical context. A pure lexer
  can only approximate. Accept this — the tokenizer is cosmetic.
  Layer 3 Semantic Metadata provides precise binder identity later.
- `constructor` identification may not be possible without the
  inductive registry. Keep them as `identifier` for Phase 0; refine
  in Layer 3.

## Phase 1 — GreenNode Parse Tree (CST)

**Goal:** Doxa's parser produces a lossless GreenNode concrete syntax
tree alongside the existing SExpr/SDecl abstract AST. This gives
position-indexed tree access, source reconstruction, and incremental
reparse.

**Status:** `rumil` 0.10.0 supports `treeOf`, `GreenNode`, `RedTree`,
`TextEdit`, and incremental reparse. Doxa's `parse.dart` currently
produces only `SExpr`/`SDecl`.

### Deliverables

1. **Token and syntax alphabets.** Define `enum DoxaToken` and
   `enum DoxaSyntax` for Doxa's surface grammar. Building on the
   token classes from Phase 0.

   ```
   enum DoxaToken { lparen, rparen, lbrace, rbrace, lbracket, rbracket,
     colon, semicolon, comma, pipe, dot, arrow, fatArrow,
     kwFun, kwData, kwVal, kwType, kwMatch, kwCase, kwReturning, kwAnd,
     sortType, sortProp,
     ident, number, comment, whitespace, error }

   enum DoxaSyntax { sourceFile, valDecl, typeDecl, funDecl, dataDecl,
     ctorDecl, lambda, piType, app, match, matchCase,
     block, blockBinding, typeParams, params, typeArgs,
     ident, number, universe }
   ```

2. **Grammar rewrite.** Modify `parse.dart` (or add a parallel
   `parse_tree.dart`) to use `treeOf` combinators instead of
   `map`/`capture` combinators. The existing `SExpr`/`SDecl` AST is
   still produced (via `.value`), but the parser also yields a
   `GreenNode<DoxaToken, DoxaSyntax>` tree.

   This is additive — existing callers of `parseProgram` and
   `parseExpr` are unaffected.

3. **RedTree accessors.** Wrap the GreenNode in a RedTree for
   position-indexed queries:
   - `nodeAt(offset)` → the most specific syntax node at a position
   - `parent(node)` → walk up to enclosing declaration
   - `children(node)` → walk down into sub-expressions
   - `toSource()` → reconstruct original source text losslessly

4. **Incremental reparse.** Wire rumil's `TextEdit.applyEdit` so that
   edits to the source reparse only the affected region. This is
   already implemented in rumil; it needs the Doxa grammar in
   GreenNode form.

### What this unlocks

- Precise source spans for every syntactic construct (not just
  byte-offset ranges on `SExpr` wrappers)
- Source reconstruction for code generation / formatting
- Tree-aware error messages (cite the enclosing declaration, not
  just the offending token)
- Foundation for Layer 3 (position-indexed metadata can be
  stored on RedTree nodes)

### Risks / unknowns

- The grammar rewrite is mechanical but tedious. Every parser site
  in `parse.dart` (~800 lines) needs a `treeOf` counterpart.
- Incremental reparse correctness depends on the grammar's
  `reparseBoundary` annotations. Need to audit which Doxa syntax
  nodes form valid reparse boundaries.
- Performance: producing a GreenNode tree adds allocation overhead.
  The checker's hot path doesn't need the tree, so perhaps keep
  the tree optional / only produce it for tooling consumers.

## Phase 2 — Structured Check Output

**Goal:** The checker returns structured JSON instead of flat strings.
Per-declaration info (name, kind, type, normal form, span). Errors
with structured fields (kind, expected, actual, line, column, message).

**Status:** The checker already computes all this data (types, values,
spans, errors). It just discards it after formatting it into a string.

### Deliverables

1. **Output model.** `lib/src/output.dart` defining:

   ```dart
   sealed class CheckOutput { Map<String, dynamic> toJson(); }

   final class CheckSuccess extends CheckOutput {
     final List<DeclInfo> declarations;
     final int count;
   }

   final class DeclInfo {
     final String name;
     final String kind;        // "val", "fun", "type", "data"
     final String? type;       // pretty-printed type
     final String? normalForm; // pretty-printed normal form (val/fun)
     final DoxaSpan span;      // source location
   }

   final class CheckFailure extends CheckOutput {
     final String kind;        // "parse_error", "type_mismatch", …
     final int line, column;   // error location
     final String? expected;   // for type mismatches
     final String? actual;
     final String message;     // full formatted diagnostic
     final DoxaSpan? span;
   }
   ```

   Serialization via `dart:convert` (plain `Map<String, dynamic>` +
   `jsonEncode`). No new dependency.

2. **Refactor `web_check.dart`.** Change `checkSourceString()` to
   return structured JSON instead of flat strings. On success,
   iterate over checked bindings, quote types and values, pretty-print
   them, build `CheckSuccess`. On error, extract structured info from
   `DoxaCheckError`/`ElabError`/`ParseError`, build `CheckFailure`.

   The prelude bindings (`Eq`, `refl`) are excluded from the
   declaration list (matching current count behavior).

3. **WASM entry point.** The `doxaCheck` JS function now returns a
   JSON string. The signature is still `String -> String` (valid
   JSON is a string). No dart2wasm interop changes needed.

4. **CLI `--json` flag.** `doxa check --json FILE` outputs the same
   JSON to stdout. Default (no flag) keeps human-readable output.
   `doxa check FILE` unchanged.

5. **Update arda-web demo.** Parse JSON response. On success, render
   an expandable declaration list. Each row: `name : type`. Expand →
   see normal form. Proofs that normalize to `refl …` get a visual
   indicator (e.g. a checkmark or "definitional"). On error, use
   structured fields instead of regex-parsing the message string.

### What this unlocks

- Inspectable proof results: "you proved `Eq[Nat] (plus n zero) n`
  and the proof normalizes to `refl n`"
- Machine-readable diagnostics for CI/editor integration
- The demo becomes genuinely educational (not just "OK: N checked")
- Foundation for Layer 3 (declaration info is the top-level of the
  semantic metadata tree)

### Risks / unknowns

- Pretty-printing must be deterministic for JSON output. Current
  `prettyTerm` is diagnostic-grade but not round-trip-safe. For JSON
  output we only need structural correctness, not round-trip parsing.
- Large normal forms (e.g. unfolded Church numerals) produce large
  JSON. Truncate or abbreviate with a `"…"` marker after N characters.
- The `nf` function may be expensive for some terms. Defer normal form
  computation — only compute when the user expands a declaration.

## Phase 3 — Position-Indexed Semantic Metadata (InfoTree)

**Goal:** During elaboration, record per-identifier metadata (resolved
name, type, source span). Expose it for hover, go-to-definition, and
completion queries. This is Doxa's equivalent of Lean 4's InfoTree.

**Status:** The elaborator resolves every identifier, determines its
type, and knows its source span (via `SExpr.span`). This info is
currently discarded after elaboration. The GreenNode tree from Phase 1
provides the substrate for attaching metadata at positions.

### Deliverables

1. **Semantic metadata model.** For each source position where an
   identifier occurs, record:

   ```dart
   final class SemInfo {
     final DoxaSpan span;        // where the identifier appears
     final String name;          // resolved name
     final SemInfoKind kind;     // local-var, top-binding, ctor,
                                 //   data-type, implicit-param
     final String type;          // pretty-printed type at this position
     final DoxaSpan? defSpan;    // span of the declaration site
   }

   enum SemInfoKind { localVar, topBinding, constructor,
     dataType, implicitParam }
   ```

2. **Collection during elaboration.** Modify `elab.dart` to
   accumulate `SemInfo` entries as it resolves identifiers.
   Each `_resolveName` call that succeeds records a `SemInfo`.
   The `MetaContext` already tracks implicitly-inserted parameters;
   those become `SemInfo` entries with `kind: implicitParam`.

   Collection is additive — no change to elaboration semantics.
   The `SemInfo` list is threaded through `_ElabState` alongside
   the meta context.

3. **Position-indexed query.** Build a lookup structure (sorted by
   span start offset) that maps a document position to the
   innermost `SemInfo` containing it:

   ```dart
   SemInfo? infoAt(int offset);
   List<SemInfo> allInRange(DoxaSpan span);
   ```

4. **Expose in structured output.** Extend the `CheckSuccess` JSON
   from Phase 2 with an optional `semInfo` field: per-position
   metadata for the whole file.

5. **Demo features.** Wired into the arda-web demo:
   - **Hover**: on any identifier, show its resolved name and type
   - **Go-to-definition**: on a `TTop` reference, jump to the
     declaration's source span
   - **Completion candidates**: names in scope at the cursor position

   These use the RedTree from Phase 1 for position lookup and the
   `SemInfo` map for semantic content.

6. **LSP server (future).** The `SemInfo` structure is already
   position-indexed and maps directly to LSP types:
   - `textDocument/hover` → `SemInfo.type` at the cursor position
   - `textDocument/definition` → `SemInfo.defSpan` → LSP `Location`
   - `textDocument/completion` → all `SemInfo` entries in scope
   - `textDocument/publishDiagnostics` → `CheckFailure` entries

### What this unlocks

- Full IDE-grade editor features
- The demo stops being a "textbox + checker" and starts being a
  lightweight IDE
- LSP implementation becomes a thin protocol layer over existing data

### Risks / unknowns

- Collecting `SemInfo` during elaboration adds allocation overhead.
  The checker is already fast; profile to ensure this doesn't
  regress the 6-15ms WASM baseline.
- For large files, the `SemInfo` list may be substantial. Use a
  compact representation (maybe a sorted `List<(int offset, SemInfo)>`).
- The elaborator currently runs to completion before any output is
  available. For IDE use, we'd want incremental elaboration (stop
  at the cursor position). Defer this — full-file elaboration is
  fine at current scale.

## Phase Dependencies

```
Phase 0 ─────────────────────────────────────────────┐
(Tokenizer)                                           │
     │                                                │
     └── Phase 1 ───────────┐                        │
         (GreenNode CST)     │                        │
              │              │                        │
              │              ├── Phase 3 ─────────────┤
              │              │   (Semantic Metadata)  │
              │              │                        │
              └──────────────┴────────────────────────┘
                                     │
Phase 2 ─────────────────────────────┘
(Structured Output)
```

- **Phase 0** has no dependencies. Can start immediately.
- **Phase 2** has no dependencies on Phase 0/1. Can start immediately.
  They can be built in parallel by different people or interleaved.
- **Phase 1** depends on Phase 0 (token alphabet).
- **Phase 3** depends on Phase 1 (GreenNode for position queries) and
  Phase 2 (structured output format to expose metadata).

## Recommended Ordering

| Step | What | Why first |
|---|---|---|
| Phase 0 | Tokenizer & highlighting | Eliminates 3-way lexer duplication immediately. Smallest change, highest visibility. Every other phase wants syntax highlighting. |
| Phase 2 | Structured check output | The demo goes from "OK: 26 checked" to inspectable results. Directly educational. Independent of Phase 0/1. |
| Phase 1 | GreenNode CST | Foundation for Phase 3. Also lets error messages cite the exact syntactic context. Larger change but mechanical. |
| Phase 3 | Semantic metadata | Full IDE features. Depends on Phase 1 and 2. |

Phases 0 and 2 can be built and shipped in parallel.

## Scaling Considerations

The architecture is designed to compose with future Doxa features:

| Future feature     | What's already handled                                |
|--------------------|-------------------------------------------------------|
| **Modules/imports** | GreenNode trees per file compose naturally. `SemInfo` includes cross-file references via URI + span. |
| **Tactics**        | The `InfoTree` collects metadata during elaboration, including tactic-produced subgoals and their contexts. Add `SemInfoKind.tacticGoal`. |
| **Multi-file projects** | Incremental reparse works per-file. The `TopEnv` accumulates across files. A project-level `CheckOutput` aggregates per-file results. |
| **LSP server**     | A `doxa lsp` CLI command wraps the Dart LSP package. `SemInfo` and `CheckOutput` are directly serializable to LSP types. No kernel changes needed. |
| **Universe polymorphism** | `SemInfo` records the resolved universe level for each type occurrence. |
| **Record types**   | `SemInfo` records field names and their types at each record literal. |
| **Typeclasses / instance search** | `SemInfo` records instance resolutions. The completion provider can filter by instance availability. |

## Non-Goals (deliberately excluded)

- **A full LSP server in this plan.** Phase 3 provides all the data
  an LSP server needs. The server itself is a thin protocol layer.
  Building it is tracked separately.
- **Code formatting.** GreenNode.toSource() gives lossless
  reproduction. A formatter needs a different pass (re-pretty-printing
  with canonical whitespace). Not in this plan.
- **A VS Code extension.** The TextMate grammar from Phase 0 is the
  first step. A full extension with LSP integration is tracked
  separately.
- **WebWorker-based WASM.** The current synchronous `doxaCheck` call
  works for a file that checks in 6-15ms. If/when checking times
  grow (larger files, more imports), move to a WebWorker. Not needed
  now.

## References

- **rumil-dart** (GitHub: `hakimjonas/rumil-dart`): core combinator
  library with GreenNode/RedTree, incremental reparse, and Pratt
  precedence. Published as `rumil` ^0.10.0 on pub.dev.
- **rumil_tokens** (pub.dev): lossless source tokenizer with
  classified token spans for syntax highlighting. ^0.10.0.
- **rust-analyzer architecture** (matklad, 2020): Three Architectures
  for a Responsive IDE. The GreenNode/RedTree pattern originates here.
- **Lean 4 Language Server** (src/Lean/Server/README.md): Watchdog +
  worker process separation, Snapshot-based incrementality, InfoTree
  for per-position metadata.
- **LSP Specification** (microsoft.github.io/language-server-protocol):
  Language-neutral protocol for editor ↔ server communication.
