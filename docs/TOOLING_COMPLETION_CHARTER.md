# Tooling Completion Charter — Pre-Phase-25

## Status

Items 1-5 are complete. Item 9 (browser demo) is deferred. This charter
covers the remaining items (6, 7, 8, 10) plus IDE plugins, with session
estimates and implementation order.

---

## Item 6 — Multi-Error Reporting

**Current state.** `checkSource` stops at the first error and returns
exit 1. The user fixes it, re-runs, hits the next error, fixes it, etc.
For a file with 5 errors, that's 5 check-fix-check cycles.

**Target.** `checkSource` collects ALL errors in a single pass and
reports them together, each with its own source context snippet. Errors
are separated by a blank line. Exit code 1 if any error exists.

**Architecture.** The hard part: Doxa uses exceptions for error
reporting. `checkDeclResult` throws `DoxaCheckError` or `ElabError`.
The pipeline `for (final decl in prog.decls) { ... }` catches the first
error and returns. To collect multiple errors, the pipeline must:

1. Catch errors per-declaration but CONTINUE to the next declaration
2. Accumulate error messages in a list
3. After all declarations: if the list is non-empty, print all errors
4. Skip subsequent declarations that depend on a failed one (e.g., a
   `val` referencing a `data` that failed to elaborate)

**Design:** A `Diagnostic` accumulator passed through the pipeline. Each
error caught adds a diagnostic and marks the problematic binding as
"poisoned." Subsequent declarations that reference poisoned names skip
elaboration with an "unknown reference" diagnostic rather than crashing.

**Files:** `doxa_tooling/bin/doxa.dart`, `doxa/lib/src/elab.dart`,
`doxa/lib/src/report.dart`

**Session estimate:** 4-6

---

## Item 7 — REPL `:browse` / `:search` / History

### 7a. `:browse` and `:search`

**`:browse`** — lists all names currently in scope with their types:

```
> :browse
Bool : Type (data, 2 ctors)
true_ : Bool
false_ : Bool
Nat : Type (data, 2 ctors)
zero : Nat
succ : Nat -> Nat
plus : Nat -> Nat -> Nat
...
```

**`:search <substring>`** — filters the browse list to names containing
the substring (case-insensitive):

```
> :search plus
plus : Nat -> Nat -> Nat
plus_comm : Eq[Nat] (plus m n) (plus n m)
```

**Implementation:** Walk `ReplSession.bindings` and `.dataDecls` to
collect names + types. Pretty-print types via the existing
`prettyTerm()` path. Sort alphabetically. `:search` applies a
substring filter.

**Files:** `doxa_tooling/lib/src/repl.dart`, `doxa_tooling/bin/doxa.dart`

**Session estimate:** 1

### 7b. REPL History

**Target:** Persistent command history across sessions, stored in
`~/.doxa_history`. Handled by the Dart `readline`-style approach or
the terminal driver's built-in line editing (which already works on
Linux/macOS).

**Minimum viable:** On platforms where `stdin.hasTerminal`, the default
line discipline already provides up-arrow history within a session.
Persistent history across sessions requires either:
- Writing to a history file and reading it on startup
- Using a package like `dart_readline` or `repl`

**Recommendation:** Accept the current in-session history (terminal
driver provides it for free) for now. Persistent cross-session history
is a quality-of-life item that doesn't gate Phase 25. Add a note to
the REPL banner.

**Session estimate:** 0 (deferred to a follow-on)

---

## Item 8 — LSP: Semantic Tokens, References, Rename

### 8a. Semantic Tokens

**Current state.** LSP provides hover, go-to-definition, completion,
and push diagnostics. No semantic highlighting.

**Target.** `textDocument/semanticTokens/full` returns token
classifications so editors can color identifiers by kind (type,
constructor, variable, keyword, etc.).

**Implementation.** The `SemInfo` data already classifies every
identifier with `SemInfoKind` (topBinding, dataType, constructor,
fieldProj, localVar, classMethod, implicitArg). The LSP handler
walks the semInfo list, maps each entry to a semantic token with
the appropriate token type and modifier, and returns the encoded
token array.

**Token type mapping:**
| SemInfoKind | Semantic Token Type |
|---|---|
| `dataType` | `type` |
| `constructor` | `enumMember` |
| `topBinding` (val) | `variable` (mutable?) → `variable.readonly` |
| `topBinding` (fun) | `function` |
| `topBinding` (type alias) | `type` |
| `localVar` | `variable` |
| `classMethod` | `method` |
| `implicitArg` | `parameter` |
| `fieldProj` | `property` |

**Files:** `doxa_tooling/lib/src/lsp/handler.dart`

**Session estimate:** 1-2

### 8b. References (`textDocument/references`)

**Target.** Given a cursor position on an identifier, return all
locations where that identifier is referenced across the file.

**Implementation.** Currently the LSP handler only processes one file
at a time (no workspace support). For single-file references:
1. Find the definition at the cursor position
2. Walk the AST or semInfo list to find all references to that name
3. Return their spans as `LspLocation` list

For multi-file (workspace) references, a workspace index is needed.
Deferred to a follow-on.

**Session estimate:** 2-3 (single-file)

### 8c. Rename (`textDocument/rename`)

**Target.** Rename an identifier everywhere in the file. Returns a
`WorkspaceEdit` with all the text replacements.

**Implementation.** Builds on references: find all references, produce
a `WorkspaceEdit` with text edits replacing each occurrence with the
new name. Validate that the new name doesn't shadow or conflict.

**Session estimate:** 1-2 (single-file, depends on 8b)

---

## Item 10 — CI/CD + Fuzz Testing

### 10a. GitHub Actions CI

**Target.** A GitHub Actions workflow that runs on every push and PR:
- `dart analyze doxa/ doxa_tooling/`
- `dart test` (both packages)
- `dart format --set-exit-if-changed`
- `doxa fmt --check` on all `.doxa` files
- `doxa check` on all stdlib and example files

**Files:** `.github/workflows/ci.yml`

**Session estimate:** 0.5

### 10b. Fuzz Testing

**Target.** Property-based testing for the kernel: random terms,
random programs, assert invariants (evaluation terminates, conversion
is an equivalence relation, quoting round-trips).

**Approach:** Start with simple generators:
1. Generate random well-typed terms in a known environment
2. Check that `eval` always terminates
3. Check that `conv(a, a)` is always `ConvOk`
4. Check that `quote(level, eval(term, env))` produces a term that
   re-evaluates to the same value

**Files:** `doxa/test/fuzz_test.dart`

**Session estimate:** 2-3

---

## IDE Plugins

### Plugin A: VS Code Extension

**Scope.** A minimal but complete VS Code extension in a new `vscode/`
directory at the repo root.

**Deliverables:**
1. `vscode/package.json` — extension manifest, activation on `.doxa`
   files, commands registered
2. `vscode/extension.js` (or `.ts` compiled to `.js`) — spawns
   `doxa lsp`, manages the client lifecycle
3. `vscode/language-configuration.json` — bracket matching (`{`/`}`,
   `[`/`]`, `(`/`)`), comment toggling (`//`), auto-closing pairs
4. `vscode/syntaxes/doxa.tmLanguage.json` — TextMate grammar for
   syntax highlighting (keywords, types, comments, strings)
5. `.vscodeignore` — exclude files not needed in the extension bundle
6. README section — installation instructions (clone, `npm run`,
   symlink or `.vsix` install)

**Key: the extension ships the LSP server.** The simplest approach:
the extension expects `doxa` on the user's `PATH`. On activation,
it runs `doxa lsp` as a child process. This avoids bundling the
Dart runtime and compiled kernel.

Alternative: bundle a compiled `doxa_lsp` binary. Deferred.

**Session estimate:** 2-3

### Plugin B: Vim/Neovim

**Scope.** A configuration snippet that users can drop into their
editor config. Not a full plugin — just documentation + a one-liner.

For Neovim (native LSP, nvim-lspconfig):
```lua
require('lspconfig').doxa.setup({
  cmd = { 'doxa', 'lsp' },
  filetypes = { 'doxa' },
  root_dir = require('lspconfig.util').root_pattern('.git'),
})
```

For Vim (coc.nvim):
```json
{
  "languageserver": {
    "doxa": {
      "command": "doxa",
      "args": ["lsp"],
      "filetypes": ["doxa"]
    }
  }
}
```

Add a `contrib/` directory with these snippets and a README.

**Session estimate:** 0.5

### Plugin C: JetBrains + Emacs

**Scope.** Documentation, not plugins. Both have generic LSP clients
that can connect to `doxa lsp`.

- **JetBrains (IntelliJ, CLion, etc.):** Install the LSP4IJ plugin,
  add a "Doxa" server definition pointing at `doxa lsp`, associate
  `.doxa` files. Document in README.
- **Emacs (eglot):** `(add-to-list 'eglot-server-programs '(doxa-mode . ("doxa" "lsp")))`. Document in README.
- **Emacs (lsp-mode):** `(lsp-register-client (make-lsp-client ...))` snippet.

**Session estimate:** 0.5

---

## Implementation Order

| Order | Item | Sessions | Rationale |
|-------|------|----------|-----------|
| 1 | **Multi-error reporting** (Item 6) | 4-6 | Biggest impact on Phase 25 proof-writing velocity. Fix-all-errors-at-once. |
| 2 | **REPL `:browse`/`:search`** (Item 7a) | 1 | Quick win. Lemma discovery in the REPL helps stdlib development. |
| 3 | **LSP semantic tokens** (Item 8a) | 1-2 | Enables color-coded identifiers in VS Code. Immediate visual payoff. |
| 4 | **VS Code extension** (Plugin A) | 2-3 | Gives Doxa a proper editor experience. Syntax highlighting + LSP. |
| 5 | **Vim/Neovim + JetBrains/Emacs** (Plugins B, C) | 1 | Documentation + snippets. Low effort. |
| 6 | **LSP references + rename** (Items 8b, 8c) | 3-5 | Solid editor refactoring. Builds on semInfo data. |
| 7 | **CI/CD** (Item 10a) | 0.5 | GitHub Actions. Cements quality guarantees. |
| 8 | **Fuzz testing** (Item 10b) | 2-3 | Long-term quality. Can run in CI. |
| **Total** | | **15-22** | |

---

## What's explicitly deferred

| Item | Reason |
|------|--------|
| Persistent REPL history | Terminal driver provides in-session history for free. Cross-session is nice-to-have. |
| LSP workspace support | Multi-file references requires a project model. Single-file references cover 80% of use. |
| Browser demo | Lives outside the project, works today. |
| Formatter negative test support | Parse errors prevent formatting. `--force` with Partial results is future work. |
| LSP completion with type info | Names-only completion is functional. Rich completion items are polish. |

---

## Exit Criteria for Each Item

### Multi-error
- [ ] All errors in a file reported in one pass
- [ ] Errors separated by blank line, each with source context
- [ ] Subsequent declarations after a failed one gracefully skipped
- [ ] Existing single-error tests pass unchanged
- [ ] New multi-error test: a file with 3 errors produces 3 diagnostics

### REPL browse/search
- [ ] `:browse` lists all names + types, sorted alphabetically
- [ ] `:search plus` shows only names containing "plus"
- [ ] Data types show constructor count
- [ ] Output is readable (one name per line)

### LSP semantic tokens
- [ ] VS Code highlights Doxa identifiers by kind
- [ ] Data types are colored differently from variables
- [ ] Constructors are colored differently from functions
- [ ] Token encoding is correct (delta-encoded line/col pairs)

### VS Code extension
- [ ] `.doxa` files open with syntax highlighting
- [ ] Bracket matching works for `{}`, `[]`, `()`
- [ ] Comment toggling with `Ctrl+/` produces `//`
- [ ] LSP diagnostics appear on save
- [ ] Hover shows types
- [ ] Go-to-definition works
- [ ] Completion shows names in scope

### CI/CD
- [ ] GitHub Actions runs on push/PR
- [ ] `dart analyze` step
- [ ] `dart test` step
- [ ] `dart format --set-exit-if-changed` step
- [ ] `doxa fmt --check` step
- [ ] Build badge in README
