# Phase 27.5 — Proof Infrastructure

## Problem

Doxa's tactic infrastructure is a skeleton. Seven tactic primitives exist in `tactic.dart`. Five are wired to the REPL. Two (`rewrite`, `induction`) are implemented in the tactic library but return `"not yet implemented in this version"` from the REPL. The conversion check used by tactics is naive structural term equality — not the kernel's `_Conv` with WHNF normalization, eta reduction, and proof irrelevance. No `cases`/`destruct`, `constructor`, or `simpl` tactics exist. The REPL proof loop (`:goal`, `:step`, `:undo`, `:qed`) is present but cannot express a non-trivial proof strategy because the primitives are too weak.

Beyond tactics, `Acc.rec` crashes on any use (`_Apply(VData(Bool))` during `_QPiCod` quoting). This makes well-founded recursion unavailable to interactive proofs. The standard library lacks `∃` (existential), `∧`/`∨`/`¬` as `Prop`-sorted connectives (`Sigma` is `Type`-sorted).

Phase 28 (tactic expansion: `induction on arbitrary inductives`, `apply with hole-filling`, `:search`, `simp`) and Phase 29 (`auto`, `omega`) cannot be built on these foundations without first fixing the infrastructure.

## Scope

| Task | Effort | Description |
|------|--------|-------------|
| 1. Fix `Acc.rec` kernel bug | 1 session | VRecursorType TPi-walking — evaluate recursor types at use-site depth instead of pre-evaluating into VPi closures |
| 2. Wire `rewrite` + `induction` to REPL | 30 min | Remove the `"not yet implemented"` guards in `repl.dart` and connect the existing tactic implementations |
| 3. Replace tactic conv with kernel `_Conv` | 1 session | Call `conv(level, a, b, dataDecls: ...)` instead of `_driveConvert`'s structural term equality |
| 4. `cases` tactic | 1 session | Destruct an inductive hypothesis into one subgoal per constructor, using the existing induction infrastructure |
| 5. `constructor` tactic | 30 min | Build the first constructor of the goal's inductive type by checking each field against a fresh subgoal |
| 6. `simpl` tactic | 30 min | Normalize the goal via `nf()` (eval then quote at level 0) |
| 7. Propositional connectives | 1 session | Add `∃` (`Exists`), `∧` (`And`), `∨` (`Or`), `¬` (`Not`) as `Prop`-sorted inductives to the standard library |
| **Total** | **~5 sessions** | |

## Dependencies

```
Task 1 (Acc.rec) — independent
Task 2 (REPL wiring) — independent, but needs Task 3 for correct conversion
Task 3 (tactic conv) — independent, enables Tasks 2, 4, 5, 6
Task 4 (cases) — depends on Task 3
Task 5 (constructor) — depends on Task 3
Task 6 (simpl) — depends on Task 3
Task 7 (connectives) — independent
```

Execute Tasks 1 and 3 first (unblock everything). Then Tasks 2, 4, 5, 6 in any order. Task 7 last.

---

## Task 1: Fix `Acc.rec` kernel bug

### Root cause

`Acc.rec Bool` crashes with `_Apply(VData(Bool), VNeutral)` during `_QPiCod` quoting. The recursor type term (from `synthRecursorType`) is evaluated into VPi closures at `toCtx()` time under `ENil` (depth 0). The closures capture depth 0. When the SApp handler opens them via `headVAsPi.codomain.env.extend(argV)`, the env depth is too shallow for the method type's TBound references. When `_QPiCod` later quotes the VPi chain, further NVars are added, shifting all positions. `motiveDepthAtInner = 6` resolves to `env[5]` (an index NVar) instead of `env[6]` (the motive). The deepest entry is `VData(Bool)` (the param), which ends up in function position.

### Fix

Store recursor type Terms as `VRecursorType` sentinels at `toCtx()` time. At each SApp use site, evaluate the TPi term one Pi at a time under the current elaboration env. This produces VPi closures with the correct captured depth. Subsequent argument applications use normal VPi handling — only the first peel needs VRecursorType treatment. The `_Quote` path evaluates the wrapped term under an env with NVars at levels 0..level-1, then quotes the result.

### Files

| File | What | Lines (approx.) |
|------|------|-----------------|
| `doxa/lib/src/value.dart` | `VRecursorType` sentinel class (after `VRec`) | 6 |
| `doxa/lib/src/elab.dart` | `toCtx()` — store `VRecursorType(b.type)` for recursor bindings, pass `typeTerm: b.type` | 3 |
| `doxa/lib/src/elab.dart` | SApp handler — VRecursorType branch: extract domain from TPi, check arg, eval codomain under `ctx.env.extend(argV)` | 25 |
| `doxa/lib/src/eval.dart` | `_Apply` — add `VRecursorType()` to non-function error list | 1 |
| `doxa/lib/src/eval.dart` | `_Quote` — `VRecursorType` case: build env with NVars at 0..level-1, eval term, quote result | 10 |
| `doxa/lib/src/eval.dart` | `_inferValueType`, `_isPropSorted`, `_isSPropSorted` — add `VRecursorType()` to wildcard/default cases | 3 |
| **Total** | | **~48** |

### Key logic — `_Quote` VRecursorType handler

```dart
case VRecursorType(:final term):
  var evalEnv = ENil.withRegistries(
    dataDecls: dataDecls ?? const [],
    topBindings: topBindings ?? const {},
  ) as Env;
  for (var j = 0; j < level; j++) {
    evalEnv = evalEnv.extend(VNeutral(NVar(j)));
  }
  step = _Quote(eval(term, evalEnv), level);
```

### Key logic — SApp handler VRecursorType branch

```dart
if (headV is VRecursorType) {
  final tpi = (headV as VRecursorType).term as TPi;
  final domainV = eval(tpi.domain, state.ctx.env);
  argT = _checkExpr(state, argExprs[i], domainV);
  final argV = eval(argT, state.ctx.env);
  recursorResultV = eval(tpi.codomain, state.ctx.env.extend(argV));
}
```

After the first peel, `recursorResultV` is a VPi chain with correct captured depth. The existing `headVAsPi` path handles subsequent iterations.

### Verification

Run `Acc.rec Bool` without crash:

```bash
echo 'import "prelude.doxa"; import "nat.doxa"; val t : Type = Acc.rec Bool' > /tmp/t.doxa
dart run doxa_tooling/bin/doxa.dart check /tmp/t.doxa
# Expected: OK: 1 declaration checked
```

Then run full verification:

```bash
dart analyze doxa/ && dart test doxa/ && dart test doxa_tooling/
doxa check lib/stdlib/case_study.doxa
doxa check lib/stdlib/proofs.doxa
```

---

## Task 2: Wire `rewrite` + `induction` to REPL

### What to change

**File:** `doxa_tooling/lib/src/repl.dart`

Remove the `"not yet implemented"` guards at lines 597 and 599-601 and connect the existing tactic implementations.

At line 597 (`rewrite`), replace:

```dart
case 'rewrite':
  return Left('rewrite: not yet implemented in this version');
```

With a call to the tactic library's `rewrite` function (already imported or importable from `doxa/lib/src/tactic.dart`). The function signature is:

```dart
TacticResult rewrite(TacticState state, int equationIndex)
```

The REPL's `_handleStep` receives a tactic name and arguments. The `rewrite` tactic takes an equation index (which hypothesis in the context). The REPL needs to parse the argument and pass it through.

Similarly for `induction` at lines 599-601:

```dart
case 'induction':
  return Left('induction: not yet implemented in this version');
```

The tactic library already has:

```dart
TacticResult induction(TacticState state, String varName)
```

The REPL needs to parse the variable name from the `:step induction n` command.

### Implementation notes

The REPL's existing `_handleStep` (lines 585-605) dispatches `intro`, `exact`, `apply`, `refl`, `trivial` by name. The pattern is:

```dart
case 'exact':
  // parse argument, call tactic, update state
```

Follow the same pattern for `rewrite` and `induction`. Parse the argument from the command string (split on whitespace), call the tactic, update the REPL proof state.

### Verification

Start a REPL session, enter a proof, and run `:step rewrite 0` and `:step induction n`. Both should advance the proof state.

---

## Task 3: Replace tactic conv with kernel `_Conv`

### Problem

`_driveConvert` in `doxa/lib/src/tactic.dart` (lines 632-643) uses structural term equality:

```dart
final termA = _drive(_Quote(a, 0), <_Frame>[], null) as Term;
final termB = _drive(_Quote(b, 0), <_Frame>[], null) as Term;
if (termA != termB) {
  throw Exception('conversion mismatch');
}
```

This is weaker than the kernel's `_Conv` (`conv()` at `eval.dart:1348`). It does not perform WHNF normalization (stuck applications with beta-reducible heads), eta reduction (lambda equality), or proof irrelevance (Prop-sorted values). The `rewrite`, `apply`, and `induction` tactics rely on this check to verify that the lemma's conclusion matches the goal. With weak conversion, these tactics fail on goals that the kernel would accept.

### Fix

Replace `_driveConvert` with a call to the kernel's `conv()` function.

**File:** `doxa/lib/src/tactic.dart`

Replace the body of `_driveConvert` (lines 632-643) with:

```dart
bool _convert(Value a, Value b, List<DataDecl>? dataDecls) {
  final result = conv(0, a, b, dataDecls: dataDecls);
  return result is ConvOk;
}
```

The `conv` function is already imported. It takes `(int level, Value a, Value b, {List<DataDecl>? dataDecls, MetaContext? metas, Map<String, TopBindingEntry>? topBindings})` and returns `ConvResult` (either `ConvOk` or `ConvMismatch`).

Update all call sites that used `_driveConvert` to use `_convert`. The call sites are:

- `tacticApply` (line 244): `_driveConvert(goalType, concl, dataDecls)`
- `rewrite` (line 282): `_driveConvert(goalType, rewrittenGoal, dataDecls)`
- `induction` (line ~390): `_driveConvert(motiveResult, armGoal, dataDecls)`

### Verification

Write a tactic test that uses `rewrite` with a lemma where the goal requires beta reduction to match. Before the fix, `_driveConvert` would reject it. After the fix, the kernel's `conv()` handles WHNF and accepts it.

---

## Task 4: `cases` tactic

### What it does

Given a hypothesis `h : T` where `T` is an inductive type, destruct `h` into one subgoal per constructor of `T`. Each subgoal has `h` replaced by the constructor pattern with fresh binders for the constructor's fields. The subgoal's type is the original goal with `h` substituted by the constructor instance.

### Implementation

**File:** `doxa/lib/src/tactic.dart`

The existing `induction` tactic already walks inductive constructors and generates subgoals. `cases` is a simpler variant: it destructs the hypothesis but does not add induction hypotheses for recursive arguments.

```dart
TacticResult cases(TacticState state, String varName) {
  // 1. Look up varName in the tactic context
  // 2. Get the type of the variable
  // 3. If the type is an inductive (VData), get its constructors
  // 4. For each constructor:
  //    a. Create fresh binders for the constructor's fields
  //    b. Substitute the hypothesis with the constructor instance
  //    c. Create a subgoal
  // 5. Return the list of subgoals
}
```

Reuse `_typeMentionsData` (line 476) and the constructor-walking logic from `induction` (lines 339-472). The difference: `induction` adds an induction hypothesis for each recursive field. `cases` does not.

### Verification

Write a test that destructs `h : Bool` into `true` and `false` subgoals. Verify both subgoals are created with the correct types.

---

## Task 5: `constructor` tactic

### What it does

When the goal type is an inductive type `T` with constructors `C1 ... Ck`, apply the first constructor `C1`. For each field of `C1`, create a fresh subgoal. If `C1` has no fields, the goal is solved.

### Implementation

**File:** `doxa/lib/src/tactic.dart`

```dart
TacticResult constructor(TacticState state) {
  // 1. Get the goal type
  // 2. If it's an inductive (VData), get its first constructor
  // 3. For each field of the constructor:
  //    a. Create a fresh subgoal with the field's type
  // 4. Return the list of subgoals
}
```

### Verification

Write a test where the goal is `Nat`. `constructor` closes it (zero has no fields). Then test where the goal is `Eq Nat zero zero`. `constructor` creates one subgoal (refl needs one argument: `zero`).

---

## Task 6: `simpl` tactic

### What it does

Normalize the goal type via `nf()` (evaluate under empty env, then quote at level 0). If the normalized type differs from the original, replace the goal type with the normalized form.

### Implementation

**File:** `doxa/lib/src/tactic.dart`

```dart
TacticResult simpl(TacticState state) {
  // 1. Get the current goal type
  // 2. Normalize it via nf(goalTypeTerm)
  // 3. If the normalized term differs from the original:
  //    a. Replace the goal type with the normalized term
  //    b. Return a single subgoal with the new type
  // 4. If unchanged, return success with no subgoals
}
```

The `nf()` function is already available in `eval.dart`:

```dart
Term nf(Term term) {
  final stack = <_Frame>[const _QuoteAt(0)];
  return _drive(_Eval(term, const ENil()), stack, null) as Term;
}
```

### Verification

Write a test with goal `Eq Nat (plus zero zero) zero`. `simpl` normalizes `plus zero zero` to `zero`, giving goal `Eq Nat zero zero`. Then `constructor` closes it.

---

## Task 7: Propositional connectives

### New file: `lib/stdlib/logic.doxa`

Add `Prop`-sorted connectives:

```doxa
// Existential quantifier: ∃ (x: A), P x
data Exists[A: Type] : (A -> Prop) -> Prop {
  ex_intro : (P: A -> Prop) -> (x: A) -> P x -> Exists A P;
}

// Conjunction: P ∧ Q
data And : Prop -> Prop -> Prop {
  conj : (P: Prop) -> (Q: Prop) -> P -> Q -> And P Q;
}

// Disjunction: P ∨ Q
data Or : Prop -> Prop -> Prop {
  or_inl : (P: Prop) -> (Q: Prop) -> P -> Or P Q;
  or_inr : (P: Prop) -> (Q: Prop) -> Q -> Or P Q;
}

// Negation: ¬ P
fun Not(P: Prop) : Prop = P -> False;
// (False is already available via False.rec / False.ind)
```

`Exists` uses `A: Type` as a parameter and `P: A -> Prop` as an index. This parallels the existing `Sigma` type but sorts in `Prop` instead of `Type`.

### Add to package re-exports

Create `lib/stdlib/Logic/package.doxa`:

```doxa
import "logic.doxa"
```

### Update proofs.doxa imports

Add `import "logic.doxa"` to `lib/stdlib/proofs.doxa` so the connectives are available in proofs.

### Verification

```bash
doxa check lib/stdlib/logic.doxa
# Expected: OK
doxa check lib/stdlib/proofs.doxa
# Expected: 62+ declarations OK
```

---

## Overall verification

After all tasks:

```bash
dart analyze doxa/                    # 0 errors
dart analyze doxa_tooling/           # 0 errors
dart test doxa/                       # all pass
dart test doxa_tooling/               # all pass
doxa check lib/stdlib/case_study.doxa
doxa check lib/stdlib/proofs.doxa
doxa check lib/stdlib/logic.doxa
echo 'import "prelude.doxa"; import "nat.doxa"; val t : Type = Acc.rec Bool' > /tmp/t.doxa
dart run doxa_tooling/bin/doxa.dart check /tmp/t.doxa
# Expected: OK
```

A manual REPL smoke test: start `doxa repl`, enter a proof, and exercise each tactic (`intro`, `exact`, `refl`, `apply`, `trivial`, `rewrite`, `induction`, `cases`, `constructor`, `simpl`) on a small goal.
