# Doxa Release Plan (0.8.x → 0.9.0)

> Target: first public release with verified theorems, competitive tooling.
> 2026-08-09: 0.8.1 merged. Fuel-based termination_by computation deferred
> to 0.8.2.

## 0.8.1 — Shipped ✓

- ImportResolver: pre-resolution, topological sort, single-pass check.
- ImportState: eliminated 3 mutable module-level globals, carried on TopEnv.
- match-motive bug in import chains fixed (Int/package.doxa passes).
- Error-location routing to correct SourceFile for imported spans.
- GPL-3.0-or-later license.
- JetBrains extension moved to `doxa-jetbrains` repo.

## 0.8.2 — Planned: Fuel desugaring

For every `fun f(args): T termination_by (x) = body`, the elaborator
generates two bindings:
1. `f_fuel(fuel: Nat, args): T` — structurally recursive on `fuel`,
   body rewritten to replace self-calls `f(e)` with `f_fuel(fuel-1, e)`
2. `f(args): T = f_fuel x args` — public wrapper, non-opaque

This makes `termination_by` functions computable (fixes the opaque
NTop stuck-neutral problem) and bypasses the Prop-into-Type restriction
on `Lt` (fuel is structural recursion on `Nat` — no `Lt`/`Acc` needed).

After this lands, `*_acc` functions in nat.doxa can be rewritten to use
clean `termination_by` annotations.

## Dependency chain (0.9.0)

```
Level 1: Infrastructure        [DONE ✓]
  ├ Lt in nat.doxa
  ├ strong_ind in proofs.doxa
  ├ termination_by parsing + pre-seeding
  └ Acc in prelude

Level 2: Auto-desugaring       [IN PROGRESS]
  ├ Elaborator wraps body in strong_ind
  ├ Creates meta obligations for Lt proofs
  └ Self-references replaced with ih calls

Level 3: Well-founded defs     [Gated by Level 2]
  ├ gcd_wf, mod_wf, div_wf
  └ Clean Euclid, no accumulator hacks

Level 4: Correctness proofs    [Gated by Level 3]
  ├ gcd_comm, gcd_divides
  └ mod/div identities

Level 5: Case studies          [Gated by Level 4]
  ├ Infinite primes
  └ sqrt2 (already done ✓)
```

## Part A — Core correctness

| # | Item | Level | Deliverable |
|---|------|-------|-------------|
| A | Lt in nat.doxa + strong_ind in proofs.doxa | 1 | Done |
| B | REPL import support | 1 | Done |
| **2** | **auto-desugar termination_by → strong_ind** | **2** | `fun f(x:T): R termination_by (x) = body` compiles. Each recursive `f y ...` becomes `ih y ?lt_proof`. `?lt_proof` is a fresh meta obligation the user solves in REPL. |
| 3 | Well-founded gcd, mod, div | 3 | Clean Euclid definitions, no accumulator workarounds |
| 4 | gcd correctness + prime lemmas | 4 | gcd_comm, gcd_divides, prime_two, infinite primes |
| 5 | Infinite primes proof | 5 | Second case study: Euclid's construction |

## Part B — Tooling

| # | Item | Deliverable |
|---|------|-------------|
| 6 | Proof state in LSP | Goal + context pushed to editor after `:step` |
| 7 | Code actions | "Case split", "Apply induction" in editor |
| 8 | Hole interaction | Hover on `_` shows expected type |

## Part C — Ship

| # | Item |
|---|------|
| 9 | VS Code extension |
| 10 | WASM playground smoke test |
| 11 | Version bump + CHANGELOG → 0.9.0 |

## Session totals

| Part | Items | Sessions |
|------|-------|----------|
| A | 2-5 | 6-10 |
| B | 6-8 | 3-5 |
| C | 9-11 | 2-3 |
| **Total** | | **11-18** |
