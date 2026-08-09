# Doxa 0.9.0 Release Plan

> Target: first public release with verified theorems, competitive tooling.

## Part A — Core correctness

| # | Item | Sessions | Deliverable |
|---|------|----------|-------------|
| 1 | **Acc.rec desugaring from termination_by** | 2-3 | `fun gcd(a,b): Nat termination_by (a,b) = match a { ... }` compiles with direct recursive calls. Elaborator synthesizes `Acc.rec` application automatically. Currently the plumbing allows self-reference but users must write recursion manually via `Nat.ind`/`Acc.rec`. |
| 2 | **gcd correctness theorems** | 2-3 | `divides (gcd a b) a`, `divides (gcd a b) b`, `gcd a b = gcd b a`, and `d` divides both `a` and `b` → `d` divides `gcd a b`. New file or additions to `proofs.doxa`, 4-6 theorems. |
| 3 | **Infinite primes proof** | 3-4 | Second major case study alongside sqrt2: for any `n`, there exists a prime `p > n`. Euclid's construction: `(p1·...·pk) + 1`. New file `lib/stdlib/Primes/primes.doxa`. |

## Part B — Tooling that rivals mature projects

| # | Item | Sessions | Deliverable |
|---|------|----------|-------------|
| 4 | **Proof state in editor** | 1-2 | `$/doxa/proofState` LSP notification pushing current goal type + context binders to VS Code after each `:step`. Data exists in `MetaContext`/`TacticState`. Needs a bridge between REPL and LSP (pipe/socket) or LSP-side proof tracking. |
| 5 | **Code actions** | 1-2 | `textDocument/codeAction` on identifiers: "Case split this variable", "Apply induction", "Rewrite using this lemma". LSP handler inspects `SemInfo` at cursor, looks up inductive type, generates code edits. |
| 6 | **Hole interaction** | 1 | Hover on `_` shows expected type from meta context. Needs a mapping from source offset → meta ID (currently `_` entries aren't tracked in `SemInfo` — they're `TMeta` renders, not identifiers). |

## Part C — Ship

| # | Item | Sessions | Deliverable |
|---|------|----------|-------------|
| 7 | **VS Code extension** | 1-2 | `vscode/` directory: `package.json`, `extension.js` (spawns `doxa lsp`), `syntaxes/doxa.tmLanguage.json` (syntax highlighting), `.vsix` build. |
| 8 | **WASM playground smoke test** | 0.5 | Compile `doxa_check.wasm`, load in browser, verify expandable declaration list with stdlib input. |
| 9 | **Version bump + CHANGELOG** | 0.5 | `0.9.0` in both `pubspec.yaml`, `v0.9.0` CHANGELOG entry, git tag. |

## Session totals

| Part | Items | Sessions |
|------|-------|----------|
| A — Core | 1-3 | 7-10 |
| B — Tooling | 4-6 | 3-5 |
| C — Ship | 7-9 | 2-3 |
| **Total** | | **12-18** |

## Ordering

Items 1-3 (core) first — they need the most thinking and they enable items 4-6 (tooling) to be demoed effectively. Items 4-6 can be built in parallel or interleaved with 2-3. Items 7-9 are the release mechanics, done last.

After this plan completes: Doxa ships as `0.9.0` — feature-complete kernel, two verified case-study theorems, competitive editor integration, and a deployed playground.
