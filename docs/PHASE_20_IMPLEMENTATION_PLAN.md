# Phase 20 — Tactics

## Part A: Design Note (prior-work study)

### Four reference models

**Lean 4** (47+ tactic files, `Elab/Tactic/*.lean`):
Tactics are elaborator functions in the `TacticM` monad, deeply integrated
with the elaborator pipeline. Tactic blocks use `by { ... }`. Backtracking
via meta-context snapshot/restore. The `TacticM` monad threads the goal list,
the local context, and the elaborator state. Composition: `;` (sequence),
`<;>` (parallel sequence), `<|>` (alternative).

**Coq/Ltac/Ltac2** (`coq.inria.fr/doc/refman/proof-engine/ltac.html`):
Tactics are written in a separate programming language — Ltac1 (domain-specific,
backtracking-focused) or Ltac2 (ML-family, typed). Tactics operate on a goal
stack, producing proof terms via `refine`/`apply`. Composition: `;` (sequence),
`||` (alternative), `+` (backtracking). The richest tactic language in the field,
but also the heaviest — a full programming language embedded in the proof
assistant.

**Agda** (reflection-based, `language/reflection.html`):
Macros are regular Agda functions `Term → TC ⊤`. The `TC` monad provides ~30
primitives: `unify`, `checkType`, `inferType`, `normalise`, `getContext`,
`freshName`, `declareDef`, `defineFun`, `declareData`, etc. Tactics produce
terms by solving metavariables. No separate tactic language — metaprograms
are Agda code. This is the **most minimal** approach in the field.

**Idris 2** (`Elab/Interface.idr`):
Elaborator reflection — similar to Agda but tightly integrated with the
elaborator pipeline. Tactics are Idris functions manipulating the elaborator
state through a small API. The `Elab` monad provides `check`, `getEnv`,
`getGoal`, `claim`, `focus`, etc.

### Decision: Agda's reflection model (macro-based)

**Why not Lean 4:**
Lean 4's `TacticM` monad is a 47-file subsystem deeply embedded in the
elaborator. Doxa's elaborator is a different architecture (defunctionalized
driver, `_elabDecl` → `_inferExpr` / `_checkExpr`). Adopting Lean's tactic
architecture would require a reshape of the elaborator — out of scope for
Phase 20.

**Why not Coq/Ltac:**
A separate embedded programming language (Ltac) is orders of magnitude
beyond what Phase 20 needs. Doxa needs a minimal proof-writing tool, not
a tactic programming language.

**Why Agda:**
1. **Minimal API.** ~10 primitives on the meta-context suffice for the
   initial tactic set (intro, exact, apply, refl, rewrite, induction, trivial).
2. **Reuses existing infrastructure.** Doxa's `MetaContext` (Phase 13) IS the
   "observable state." Tactics just solve metavariables.
3. **Syntactic sugar is thin.** `by { tactic }` desugars to a metaprogram
   that produces a term for the current goal's meta.
4. **Fungal-compatible surface syntax.** `by { intro; induction n; refl | rewrite ih }`
   uses Fungal's `|` for alternative (same symbol as data constructors).
5. **No separate language.** Tactics are implemented in Dart (the host),
   not as an embedded DSL. Users write tactic sequences, not tactic programs.

### Doxa-specific adaptation

Agda's reflection model gives direct access to the IR (`Term`, `Pattern`,
`Clause` types). In Doxa, tactics operate at the **elaborator level** —
they manipulate the `MetaContext` to produce elaborated kernel terms.
The tactic block is an alternative to writing the proof term by hand.

**Core design:**

```
theorem name : T := by {
  intro x;
  induction x;
  refl | rewrite ih
}
```

Desugars to: the elaborator creates a `TMeta` for the goal, invokes the
tactic sequence against it, and the tactic solves the meta by producing
a term.

**Primitive operations** (implemented in Dart, exposed via the tactic engine):

| Primitive | Type | What it does |
|-----------|------|-------------|
| `intro` | None (modifies context) | Introduces a Pi binder into the context |
| `exact e` | `Term → Tactic Term` | Provides an explicit proof term |
| `apply f` | `Term → Tactic Term` | Applies lemma `f`, creating subgoals for its arguments |
| `refl` | `Tactic Term` | Closes `Eq A x x` by `refl` |
| `rewrite p` | `Term → Tactic Term` | Rewrites with an equality proof `p` |
| `induction x` | `String → Tactic Term` | Produces subgoals per constructor of `x`'s type |
| `trivial` | `Tactic Term` | Tries `refl` + trivially-true lookups |

**Composition:**

| Combinator | Syntax | Meaning |
|-----------|--------|---------|
| Sequence | `t1; t2` | Run `t1`, then `t2` on remaining subgoals |
| Alternative | `t1 \| t2` | Try `t1`; if it fails, try `t2` |

### Surface syntax (Fungal-compatible)

```
theorem name : T := by {
  intro x;
  intro y;
  rewrite H;
  refl
}
```

Or with alternatives:
```
theorem name : T := by {
  intro n;
  induction n;
  refl | rewrite ih
}
```

Key syntactic choices:
- `by { ... }` — Fungal-idiomatic block syntax (same as `fun` body braces from Phase 21.5)
- `;` — sequence combiner (same as Fungal's semicolon)
- `|` — alternative combiner (same as Fungal's data variant separator from Phase 21.5)
- No `<|>` — that was a Lean-ism, not Fungal syntax

---

## Part B: Implementation Plan (~200 lines, 8-12 sessions)

### Step 0 — Tactic engine core (`doxa/lib/src/tactic.dart`, ~60 lines)

#### 0a. `TacticState` and `TacticResult`

```dart
/// The state a tactic operates on: the current meta to solve plus the
/// elaborator context.
final class TacticState {
  final MetaContext metas;
  final Ctx ctx;
  final int currentMeta;  // ID of the meta being solved
  const TacticState(this.metas, this.ctx, this.currentMeta);
}

/// The result of running a tactic.
sealed class TacticResult {
  const TacticResult();
}

/// The tactic succeeded, producing a term that solves the current meta.
final class TacticOk extends TacticResult {
  final Term term;           // The proof term
  final MetaContext metas;   // Updated metas (subgoals added)
  const TacticOk(this.term, this.metas);
}

/// The tactic failed with a diagnostic.
final class TacticFail extends TacticResult {
  final String message;
  const TacticFail(this.message);
}
```

#### 0b. `Tactic` type and combinators

```dart
/// A tactic is a function from state to result.
typedef Tactic = TacticResult Function(TacticState state);

/// Sequence: run t1, then t2 on remaining subgoals.
Tactic seq(Tactic t1, Tactic t2) => (s) {
  final r1 = t1(s);
  return switch (r1) {
    TacticOk(:final term, :final metas) =>
      t2(TacticState(metas, s.ctx, s.currentMeta)),
    TacticFail _ => r1,
  };
};

/// Alternative: try t1, if it fails, try t2.
Tactic alt(Tactic t1, Tactic t2) => (s) {
  final r1 = t1(s);
  if (r1 is TacticOk) return r1;
  return t2(s);
};
```

#### 0c. Primitive tactics

```dart
/// `intro`: introduces a Pi binder. Creates a fresh name, extends ctx,
/// and produces a lambda body with a fresh subgoal for the codomain.
Tactic intro(TacticState s) {
  final metaEntry = s.metas.lookup(s.currentMeta);
  final expectedType = metaEntry.typeExpected;
  if (expectedType is! VPi) {
    return TacticFail('intro: goal is not a Pi type');
  }
  final freshName = 'h${s.metas.nextId}';
  final freshNeutral = VNeutral(NVar(s.ctx.level));
  // Extend context, create subgoal for codomain
  // ...
}

/// `exact term`: provides an explicit proof term.
Tactic Function(Term) exact = (term) => (s) {
  // Check that term's type converts with the goal type
  final inferred = infer(s.ctx, term);
  if (conv(0, inferred, s.metas.lookup(s.currentMeta).typeExpected) is ConvOk) {
    return TacticOk(term, s.metas);
  }
  return TacticFail('exact: type mismatch');
};

/// `refl`: closes Eq A x x goals.
Tactic refl(TacticState s) {
  final goalType = s.metas.lookup(s.currentMeta).typeExpected;
  // If goalType is Eq A x x, synthesize refl x
  // ...
}

/// `apply f`: applies lemma f, creates subgoals for arguments.
Tactic Function(Term) apply = (lemma) => (s) {
  final lemmaType = infer(s.ctx, lemma);
  // Walk Pi chain, create metas for each argument
  // ...
};

/// `rewrite p`: rewrites with equality proof p.
Tactic Function(Term) rewrite = (proof) => (s) { /* ... */ };

/// `induction x`: produces subgoals per constructor of x's type.
Tactic Function(String) induction = (varName) => (s) { /* ... */ };

/// `trivial`: tries refl + simple lookups.
Tactic trivial(TacticState s) {
  return alt(refl, exact(s.ctx.lookupFirstMatching(s.currentMeta)))(s);
}
```

---

### Step 1 — Surface syntax + parser (~30 lines)

#### 1a. `SByKind` surface node (surface.dart)

```dart
/// A tactic block: `by { tactic; tactic; ... }`.
final class SByKind extends SExprKind {
  final List<TacticStep> steps;
  const SByKind(this.steps);
}
```

#### 1b. Tactic step parser (parse.dart)

```
tactic_step ::= 'intro' ident? (';')?
              | 'exact' expr (';')?
              | 'apply' expr (';')?
              | 'refl' (';')?
              | 'rewrite' expr (';')?
              | 'induction' ident (';')?
              | 'trivial' (';')?
```

Implemented as parser combinators with `;` as sequence separator and `|` as
alternative separator.

#### 1c. `by` block parser

The `by` keyword followed by a `{ ... }` block:

```dart
final _byBlock = _keyword('by')
    .skipThen(_blockExpr)  // or a dedicated _tacticBlock
    .map((body) => SExpr(SByKind(body), ...));
```

Added to the atom parser alongside `match`, `if`, etc.

---

### Step 2 — Elaborator integration (~40 lines)

#### 2a. `theorem` keyword

Add `theorem` as a declaration kind alongside `val`:

```dart
// theorem name : T := by { ... }
// theorem name : T := expr  (explicit proof term, same as val)
```

Parser: `_theoremDecl` → `keyword('theorem') . skipThen(_valDecl)`.
The `theorem` keyword is Fungal-compatible (present in Fungal's keyword list).

#### 2b. `SByKind` elaboration

In `_elabExpr` / `_inferExpr`:

```dart
case SByKind(:final steps):
  // Create a fresh meta for the goal
  final metaId = metas.freshTermMeta(expectedType, ctx);
  // Run the tactic sequence against it
  final result = _runTactics(steps, TacticState(metas, ctx, metaId));
  return switch (result) {
    TacticOk(:final term, :final newMetas) =>
      (term, expectedType),  // the tactic produced the proof
    TacticFail(:final message) =>
      throw TacticFailed(message, expr.span),
  };
```

#### 2c. Tactic runner

```dart
Term _runTactics(List<TacticStep> steps, TacticState state) {
  var s = state;
  for (final step in steps) {
    final tactic = _compileStep(step);
    final r = tactic(s);
    switch (r) {
      case TacticOk(:final term, :final metas):
        s = TacticState(metas, s.ctx, s.currentMeta);
        // Continue with remaining steps on any unsolved subgoals
      case TacticFail(:final message):
        throw TacticFailed(message, step.span);
    }
  }
  // The final step must have solved all metas
  final solution = s.metas.solutionOf(state.currentMeta);
  if (solution == null) throw TacticIncomplete(span);
  return solution;
}
```

---

### Step 3 — Tests (~50 lines)

Create `doxa/test/tactic_test.dart`:

| # | Test | Expected |
|---|------|----------|
| 1 | `theorem triv : Eq[Nat] zero zero := by { refl }` | Type-checks |
| 2 | `theorem id : (A: Type) -> A -> A := by { intro A; intro x; exact x }` | Type-checks |
| 3 | `theorem sym : ... := by { intro a; intro b; intro h; induction h; refl }` | Type-checks |
| 4 | `theorem trans : ... := by { apply ... }` | Type-checks |
| 5 | `theorem plus_comm : ... := by { intro m; induction m; refl | rewrite ih }` | Type-checks |
| 6 | `theorem fail : Eq[Nat] zero (succ zero) := by { refl }` | TacticFailed |
| 7 | `trivial` on `Eq[Nat] zero zero` | Succeeds |
| 8 | `rewrite` with `plus_zero` | Does the rewrite |

---

### Step 4 — Exit verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All 418 doxa tests pass. New tactic tests pass. All 445 doxa_tooling tests pass.
`doxa check example/proofs.doxa` → OK.

---

## Files to modify

| File | Changes | Est. lines |
|------|---------|-----------|
| `doxa/lib/src/tactic.dart` | **New file** — TacticState, TacticResult, Tactic typedef, primitives, combinators | +60 |
| `doxa/lib/src/surface.dart` | `SByKind` class | +10 |
| `doxa/lib/src/parse.dart` | `_theoremDecl`, `_byBlock`, `_tacticStep` parsers | +25 |
| `doxa/lib/src/elab.dart` | `SByKind` elaboration, `_runTactics`, `TacticFailed`/`TacticIncomplete` errors | +40 |
| `doxa/lib/src/report.dart` | Tactic error formatting | +10 |
| `doxa_tooling/lib/src/web_check.dart` | New error kind mappings | +3 |
| `doxa_tooling/lib/src/syntax.dart` | `kwTheorem`, `kwBy` tokens | +3 |
| `doxa/test/tactic_test.dart` | **New file** — 8 tests | +50 |
| **Total** | | **~201** |

## Risk assessment

**Risk: Medium-High.** This is the first time Doxa gets an imperative-style
proof construction mechanism. The tactic engine must correctly thread the
meta-context, create subgoals, and handle failure/backtracking. The
`induction` tactic requires access to the data declaration registry and
the elaborator's pattern-matching infrastructure.

**Mitigations:**
- Build incrementally: `refl` first (simplest), then `intro`/`exact`/`apply`,
  then `rewrite`/`induction`, then `trivial`.
- The `MetaContext` already supports multiple unsolved metas — subgoals are
  just additional `TermMetaUnsolved` entries.
- Tactic failures are caught at elaboration time and surfaced as diagnostics
  — no runtime backtracking in the kernel.
- The initial implementation can be non-backtracking (`;` only, no `|`).
  Alternative combinator can be added later if needed.

## Session estimate

**8-12 sessions.** Break down:
- Step 0 (tactic engine core): 3-4 sessions
- Step 1 (surface syntax): 2-3 sessions
- Step 2 (elaborator integration): 2-3 sessions
- Step 3 (tests): 1-2 sessions
