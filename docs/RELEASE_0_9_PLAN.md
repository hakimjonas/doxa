# Doxa 0.9.0 Release Plan

> Target: first public release with verified theorems, competitive tooling.
> Revised 2026-08-09: tooling-first order to unlock proof development.

## Part A — Foundation (prerequisites)

| # | Item | Sessions | Deliverable |
|---|------|----------|-------------|
| A | **Move `Lt` to prelude** | 0.25 | `Lt : Nat -> Nat -> Prop` with `lt_succ n : Lt n (succ n)` and `lt_trans` in `prelude.doxa`. Removed from `case_study.doxa` (imports prelude). |
| B | **Move `strong_ind` to proofs.doxa** | 0.25 | Generic well-founded induction lemma available alongside `plus_comm` etc. Currently in `case_study.doxa`. |

## Part A continued — Core correctness (tooling-enabled)

| # | Item | Sessions | Deliverable |
|---|------|----------|-------------|
| C | **Proof state in editor** | 1-2 | `$/doxa/proofState` LSP notification pushing current goal type + context binders to VS Code after each `:step`. |
| 1 | **Acc.rec desugaring from termination_by** | 2-3 | `fun gcd(a: Nat, b: Nat) : Nat termination_by (a, b) = match a { ... }` compiles with direct recursive calls. Elaborator synthesizes `strong_ind` application automatically. `Lt` available from prelude, `strong_ind` from proofs.doxa. |
| 2 | **gcd correctness theorems** | 2-3 | `divides (gcd a b) a`, `divides (gcd a b) b`, `gcd a b = gcd b a`, and `d` divides both `a` and `b` → `d` divides `gcd a b`. Written interactively using REPL proof mode + LSP proof state. |
| 3 | **Infinite primes proof** | 3-4 | Second major case study: for any `n`, there exists a prime `p > n`. Euclid's construction. |

## Part B — Tooling that rivals mature projects

| # | Item | Sessions | Deliverable |
|---|------|----------|-------------|
| 4 | **Code actions** | 1-2 | `textDocument/codeAction` on identifiers: "Case split this variable", "Apply induction", "Rewrite using this lemma". |
| 5 | **Hole interaction** | 1 | Hover on `_` shows expected type from meta context. |

## Part C — Ship

| # | Item | Sessions | Deliverable |
|---|------|----------|-------------|
| 6 | **VS Code extension** | 1-2 | `vscode/` directory: `package.json`, `extension.js`, `syntaxes/doxa.tmLanguage.json`, `.vsix` build. |
| 7 | **WASM playground smoke test** | 0.5 | Compile `doxa_check.wasm`, load in browser, verify expandable declaration list. |
| 8 | **Version bump + CHANGELOG** | 0.5 | `0.9.0` in both `pubspec.yaml`, CHANGELOG entry, git tag. |

## Session totals

| Part | Items | Sessions |
|------|-------|----------|
| A — Foundation | A, B | 0.5 |
| A — Core | C, 1, 2, 3 | 8-12 |
| B — Tooling | 4, 5 | 2-3 |
| C — Ship | 6, 7, 8 | 2-3 |
| **Total** | | **12.5-18.5** |

## Chain of dependencies

```
A (Lt in prelude) → B (strong_ind) → 1 (Acc.rec desugaring) → 2 (gcd proofs) → 3 (primes)
                                      ↗
                               C (proof state LSP)
```

Items C, 4, 5 are independent of A-3 and can be built in parallel.
