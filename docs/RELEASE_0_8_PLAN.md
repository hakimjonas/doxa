# Doxa Release Plan (0.8.x)

All feature work ships in 0.8.x. 0.9.x is reserved for refinement, bug fixes,
performance, and polish.

## 0.8.0 — Preview ✓ (shipped)

Kernel + tooling + stdlib + VS Code extension. 157 stdlib declarations, 976 tests.

## 0.8.1 — Infrastructure ✓ (shipped)

ImportResolver + ImportState, GPL-3.0-or-later license, AOT binary.

## 0.8.2 — Fuel desugaring ✓ (implemented, not yet released)

For every `fun f(args): T termination_by (x) = body`, the elaborator emits two
computable bindings:

1. `f_fuel(fuel: Nat, args): T` — structurally recursive on fuel
2. `f(args): T = f_fuel x args` — non-opaque public wrapper

Any return sort (Type, Prop, SProp). The Prop-into-Type restriction is
bypassed (fuel uses Nat directly, never Lt or Acc).

Also: LSP `id` field accepts `int | string | null` per JSON-RPC 2.0 spec.
    `Nat` scope diagnostic before fuel generation.

`strong_ind_impl` / `strong_ind_impl_help` mutually-recursive block
restructured: the helper receives the induction function as an explicit
parameter, breaking the mutual dependency. `strong_ind_impl` is now a
standalone `termination_by (n)` function handled by fuel desugaring.
`strong_ind` (the public wrapper) is now computable. proofs.doxa: 82 decls.

## 0.8.3 — strong_ind desugaring

For Prop-returning `termination_by` functions, the elaborator desugars to a
`strong_ind` call. Each recursive self-call becomes an induction-hypothesis
call with a meta-obligation for the Lt proof. The REPL presents these metas
interactively.

### Motivation

Fuel desugaring (0.8.2) makes functions computable but produces no termination
proof. `strong_ind` desugaring (0.8.3) proves termination via the existing
`strong_ind` principle in proofs.doxa. The two paths are complementary:

| | Fuel (0.8.2) | strong_ind (0.8.3) |
|---|---|---|
| Return sort | Any (Type, Prop, SProp) | Prop only |
| Produces | Computable function | Termination proof |
| Meta-obligations | None | Lt proofs (REPL-interactive) |

### Desugaring

For a function:
```doxa
fun f(x: Nat) : P x termination_by (x) = match x {
  case zero => base
  case succ n => step n (f n)
}
```

The elaborator produces:
```doxa
fun f(x: Nat) : P x = strong_ind
  ((n: Nat) => P n)      -- motive
  ((n: Nat) =>
    (ih: (k: Nat) -> Lt k n -> P k) =>
    match n {
      case zero => base
      case succ n_ => step n_ (ih n_ ?lt_proof)
    })
  x
```

Where `?lt_proof` is a fresh meta-obligation of type `Lt n_ (succ n_)`.
The REPL presents this as a goal to the user.

### Implementation

#### Step 1: detect route

In `_elabDecl`, after extracting `termination_by`:

```dart
if (tby != null && tby.length == 1) {
  // Elaborate the return type first to check the sort
  final retTerm = _elabExpr(...);
  final retVal = eval(retTerm, ...);
  final retSort = infer(ctx, retTerm);
  if (_isPropSorted(retSort)) {
    return _desugarStrongInd(topEnv, decl.span, kind, metas: metas);
  }
  return _desugarFuel(topEnv, decl.span, kind, metas: metas);
}
```

#### Step 2: `_desugarStrongInd`

1. Elaborate the function's return type as the motive
2. Build the step function body:
   - Walk the original body with an `SExpr` transformer
   - Replace self-calls `f(e)` with `ih e <freshMeta>` where `<freshMeta>` has
     type `Lt e <tby_param>`
3. Construct the `strong_ind` call: `strong_ind motive step <tby_param>`
4. Elaborate the call as the function's term (replacing the original body)
5. Return a `DeclResult` with the single binding

#### Step 3: `_replaceSelfCallsWithIh`

SExpr walker similar to `_replaceSelfCalls` (0.8.2), but:
- Replaces `f(e)` with `ih e ?m` where `?m` is a fresh meta
- The meta type is `Lt e <tby_param>`, created via `metas.insert'`
- Handles shadow tracking for lambda / let / match binders

#### Step 4: REPL meta-solve

Existing REPL infrastructure handles unsolved metas as proof goals.
After strong_ind desugaring, the metas are of type `Lt a b`. The user
fills them with `lt_succ`, `lt_trans`, etc.

### Test plan

1. `fun f(x: Nat) : Prop termination_by (x) = ...` → strong_ind path
2. `fun f(x: Nat) : Nat termination_by (x) = ...` → fuel path (existing)
3. `fun f(x: Nat) : P n termination_by (x) = ...` where P is Prop → strong_ind
4. Self-calls with multiple arguments
5. Shadowing of `f` / `ih` in nested lambdas
6. Meta-obligation generation for each recursive call
7. REPL interaction: `:step` shows the Lt proof goal

### Known limitations

- Single-param `termination_by` only (multi-param deferred to 0.8.4)
- The fuel version for Prop-returning functions is not emitted (strong_ind
  replaces it). If computability is needed for a Prop function, the user can
  rewrite it to return Type with a Prop witness.

## 0.8.4 — Well-founded definitions + correctness proofs

### Well-founded definitions

Rewrite `gcd`, `mod`, `div` using `termination_by` instead of accumulator
helpers. The `*_acc` functions in nat.doxa become:

```doxa
fun gcd(a: Nat, b: Nat) : Nat termination_by (a) = match a {
  case zero => b
  case succ a_ => gcd (mod (succ a_) b) (succ a_)
}
```

### Correctness proofs

`gcd_comm`, `gcd_divides`, `mod_div_identities` — proofs that the new
well-founded definitions satisfy the expected properties. Uses `strong_ind`
for proofs about well-founded functions.

## 0.8.5 — Infinite primes + LSP proof state

### Second case study

Euclid's construction: there are infinitely many primes. Builds on gcd,
mod, div proofs from 0.8.4.

### LSP proof state

Push goal and context to editor after `:step` in REPL. The LSP's existing
diagnostic infrastructure is extended to report open goals and their types.

## 0.8.6 — Code actions + hole interaction + edges

### Code actions

"Case split" and "Apply induction" triggers in the editor. The LSP server
receives these commands, runs the corresponding tactic, and sends back the
updated proof state.

### Hole interaction

Hover on `_` shows the hole's expected type, drawn from the semantic
metadata already produced by Phase 3a.

### Ergonomic edges

Local `let rec`, per-member `{struct <name>}`, and other small improvements
from the Consolidated Plan Phase 19.

## 0.9.x — Refinement (post-feature)

After 0.8.6, no new features are added. 0.9.x releases contain:

- Bug fixes
- Diagnostic improvements (better error messages, correct line attribution)
- Performance (parser throughput, evaluator optimization)
- Documentation (tutorial updates, doctest examples)
- Deprecation and cleanup of dead paths
