# Doxa Release Plan (post-0.8.x)

> All feature work ships in 0.8.x. 0.9.x is refinement, bug fixes, and polish.
> See `docs/RELEASE_0_8_PLAN.md` for the 0.8.x feature roadmap.

## 0.8.1 — Shipped ✓

- ImportResolver: pre-resolution, topological sort, single-pass check.
- ImportState: eliminated 3 mutable module-level globals, carried on TopEnv.
- match-motive bug in import chains fixed (Int/package.doxa passes).
- Error-location routing to correct SourceFile for imported spans.
- GPL-3.0-or-later license.
- JetBrains extension moved to `doxa-jetbrains` repo.

## Architecture: two complementary desugaring paths

`termination_by` serves **two distinct purposes**. Each has its own
desugaring path; they are complementary, not competing.

| | Fuel desugaring (0.8.2) | strong_ind desugaring (0.9.0) |
|---|---|---|
| **Purpose** | Makes functions **computable** | Proves functions **terminate** |
| **Return sort** | Any (Type, Prop, SProp) | Prop only |
| **Mechanism** | `f_fuel(fuel, args)` — structurally recursive on fuel | `strong_ind (motive) (step) n` — elimination on Nat via Lt proofs |
| **Self-calls** | Replaced by `f_fuel(fuel-1, e)` | Replaced by `ih e ?lt_proof` with meta-obligation |
| **User-facing** | Automatic, no user input | REPL fills `Lt` proof obligations interactively |
| **What it fixes** | Opaque NTop stubs (bug 2) + Prop-into-Type restriction (bug 3) | Termination proofs for well-founded functions |
| **Kernel changes** | None (pure elaborator) | None (uses existing `strong_ind` and `MetaContext`) |
| **Lean 4 analogue** | `Nat.fix` (fuel-based, kernel-recursive) | `WellFounded.fix` (Acc-based, for proofs) |

A future release (0.10.x or later) may introduce a kernel-level `fix`
primitive that unifies both paths, matching Lean 4's architecture
where both `Nat.fix` and `WellFounded.fix` are kernel-recognised
constants.

### Why not `WellFounded.fix` / `Acc.rect` today

Doxa's recursor synthesis produces motives indexed by the full `Acc`
proof term (`P R x (acc : Acc A R x)` rather than `P x`).  This makes
the induction hypothesis type contain `P R y (f y lt)` — a 3-argument
application of the motive — which the kernel checker cannot reduce or
unify with the user's expected return type.  Coq and Lean avoid this
by using a different recursor typing for `Acc`.  Changing Doxa's
recursor synthesis to match would be a kernel-level change with
implications for all inductive types; this is deferred.

## 0.8.2 — Fuel desugaring (computability) ✓

For every `fun f(args): T termination_by (x) = body`, the elaborator
emits two bindings:

1. `f_fuel(fuel: Nat, args): T` — structurally recursive on `fuel`.
   The body is rewritten: every self-call `f(e1, e2, ...)` becomes
   `f_fuel(fuel-1, e1, e2, ...)`.  The zero-fuel branch is unreachable
   at runtime (fuel starts at the decreasing-parameter value) and
   returns the original body unchanged.

2. `f(args): T = f_fuel x args` — non-opaque public wrapper.  The
   initial fuel is the value of the decreasing parameter `x`.

Neither binding is opaque.  Functions compute immediately.  The
Prop-into-Type restriction is bypassed: fuel recursion uses `Nat`
directly, never `Lt` or `Acc`.

After this lands, `*_acc` functions in `nat.doxa` can be rewritten to
use `termination_by` directly, e.g. `fun gcd(a, b): Nat
termination_by (a) = match a { ... }`.

### Known limitations

- Mutual blocks (`fun f ... and g ...`) where one member has
  `termination_by` keep existing opaque behaviour.  Single-function
  `termination_by` is fully desugared.

- `strong_ind_impl` in `proofs.doxa` is in a mutual block with
  `strong_ind_impl_help`.  Restructuring the helper to receive the
  induction function explicitly would make `strong_ind_impl` a
  standalone `termination_by` function that fuel desugaring handles
  directly.  This is blocked by a pre-existing parser edge case
  (deeply nested Pi types after `{struct}` functions) that needs
  its own investigation.

- Multi-parameter `termination_by` (lexicographic) is deferred to
  0.9.0.

## Dependency chain (0.9.0)

```
Level 1: Infrastructure        [DONE ✓]
  ├ Lt in nat.doxa
  ├ strong_ind in proofs.doxa
  ├ termination_by parsing + pre-seeding
  └ Acc in prelude

Level 2: strong_ind desugaring  [0.9.0]
  ├ Elaborator wraps body in strong_ind
  ├ Creates meta obligations for Lt proofs (REPL-interactive)
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

## Part A — Core correctness (0.9.0)

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
