# Phase 15 — Universe Polymorphism

## Part A: Design Note (prior-work study)

### Two reference models

**Model A: Lean 4 per-declaration level variables** (src: `level.h`, `level.cpp`)

The `Level` algebraic datatype has 6 constructors:
```
level ::= zero | succ(level) | max(level, level) | imax(level, level) | param(name) | mvar(name)
```
- `zero` = Level 0
- `succ(l)` = Level + 1
- `max(l1, l2)` = maximum of two levels (for Pi types, inductive parameters)
- `imax(l1, l2)` = "impredicative max" — 0 when l2=0, otherwise max(l1,l2). Used so `(Type u → Prop) : Type 0` not `Type u`
- `param(name)` = universe level parameter (bound per-declaration, name-keyed)
- `mvar(name)` = universe metavariable (solved by inference)

Level equality is structural (`l1 == l2` structurally, then normalization for `max`/`imax`). Subtype uses `is_geq(l1, l2)` which normalizes both and checks `>=` structurally. Parameters are declaration-scoped and instantiated via substitution.

Key properties:
- `max(1, 2)` simplifies to `max(1, 2)` (normal form reorders/flattens)
- `max(u, u)` → `u`, `max(0, u)` → `u`
- `imax(u, 0)` → `0` (Prop codomain → Pi is Prop, regardless of domain)
- `imax(0, u)` → `u`, `imax(1, u)` → `u`, `imax(u, u)` → `u`
- `imax(u, v)` when `v ≠ 0` → `max(u, v)`
- `succ^k(l)` is structurally `succ(succ(...(l)))` — depth counter

**Model B: Coq algebraic universes** (src: `uGraph.mli`)

Universe levels form expressions: `Set + n`, `max(l1, l2)`, `l + 1`, variables. A separate constraint graph tracks `<=` and `<` relations between levels. Type-checking produces constraints; a solver validates consistency. Universe polymorphism is template-based: declarations are parameterized over a list of universe variables with a constraint set.

Key properties:
- Full constraint-graph solver (union-find + Bellman-Ford for consistency)
- Constraint propagation: `u <= v, v <= w` → `u <= w`
- Template polymorphism: declarations carry a constraint set that must be satisfiable
- Universe instances are explicit at use sites: `list.{u}`

### Decision: Model A (Lean 4-style per-declaration level variables)

**Rationale:**

1. **Simplicity.** Lean 4's model is ~800 lines of C++ for the entire level subsystem (normalization, comparison, substitution). Coq's model requires a constraint-graph data structure, a solver, and explicit universe instance management at every use site — roughly 10x the code.

2. **Sufficiency.** Doxa's stdlib has 55 level-monomorphic sites and 42 declarations. None require the expressive power of Coq-style algebraic constraints (e.g., `u + 1 <= v`). The Pi-sort computation `max(domLevel, codLevel)` is the only non-trivial level combinator, and Lean 4 handles it with `imax`/`max` directly.

3. **Impedance match.** Doxa already uses name-keyed top-level bindings (`TTop(name)`). Lean 4's `param(name)` and `mvar(name)` fit naturally: level parameters become part of the top-binding's signature, resolved by name just like term parameters.

4. **Avoids constraint graph.** Doxa's kernel is deliberately minimal — no unification, no constraint solving. The elaborator handles all inference. Level variable inference can follow the same pattern: the elaborator assigns fresh level metavariables, unifies them structurally, and substitutes solutions before the kernel sees them. No graph needed.

5. **Conservative.** If later phases demand algebraic constraints, Coq-style universes can be ADDED as a new level constructor (`LMax(u, v)`, `LSucc(u)`) with a constraint graph bolted onto the meta-context. The Lean 4 per-declaration model is a strict subset.

### Level datatype for Doxa

```dart
sealed class Level {
  const Level();
}

/// Concrete integer level: `Type 0`, `Type 1`, ...
final class LLevel extends Level {
  final int level;
  const LLevel(this.level);
}

/// Level variable (declaration-scoped): bound per top-level declaration.
final class LVar extends Level {
  final String name;  // unique within the declaration's scope
  const LVar(this.name);
}

/// Maximum of two levels. Computed for Pi types and inductive parameters.
final class LMax extends Level {
  final Level lhs;
  final Level rhs;
  const LMax(this.lhs, this.rhs);
}

/// Impredicative maximum: `imax(u, v) = 0` when `v == 0`, else `max(u, v)`.
/// Used so `(Type u → Prop) : Type 0` not `Type u`. In Doxa, `Prop` is
/// level 0 for Pi-sort computation (as currently hardcoded in `_piSort`).
final class LImax extends Level {
  final Level lhs;
  final Level rhs;
  const LImax(this.lhs, this.rhs);
}
```

**Deliberately omitted:** `LSucc` and level metavariables. `LSucc` is not needed for Doxa's current stdlib (no level arithmetic), and level metavariables can be handled by the elaborator assigning fresh `LLevel(n)` values during inference — no kernel-level mvar needed. If a future phase needs them, they can be added additively.

### Key invariants

1. **Level equality** in `_Conv`: `_normalize(l1) == _normalize(l2)` with structural comparison. Two `LMax` with same args are equal; `imax` normalizes based on rhs being zero.
2. **Level subtype** in `_Subtype`: `_isGte(lg, le)` — normalized, then structural check: `LMax(l, r) >= target` iff `l >= target && r >= target` or `l >= target || r >= target` (at least one branch exceeds).
3. **Level variables** are bound per declaration. The elaborator assigns `LVar("u")` for each `Type` that appears in a declaration's signature. These are de Bruijn-indexed or name-scoped within the declaration.
4. **No constraint graph.** Level variable unification is structural identity: `LVar("u") == LVar("u")` succeeds, `LVar("u") == LVar("v")` fails. The elaborator resolves level variables by substitution (like term metas).

---

## Part B: Implementation Plan

### Step 0 — Kernel (`term.dart`, `value.dart`, `eval.dart`)

#### 0a. `Level` datatype (`doxa/lib/src/term.dart`)

Add the `Level` sealed class with 4 subclasses: `LLevel`, `LVar`, `LMax`, `LImax`. Place it near `Icit` (import arity-related types together).

```dart
sealed class Level {
  const Level();
}

final class LLevel extends Level {
  final int level;
  const LLevel(this.level);
  bool operator ==(Object other) => other is LLevel && other.level == level;
  int get hashCode => Object.hash('LLevel', level);
}

final class LVar extends Level {
  final String name;
  const LVar(this.name);
  bool operator ==(Object other) => other is LVar && other.name == name;
  int get hashCode => Object.hash('LVar', name);
}

final class LMax extends Level {
  final Level lhs, rhs;
  const LMax(this.lhs, this.rhs);
  bool operator ==(Object other) => other is LMax && other.lhs == lhs && other.rhs == rhs;
  int get hashCode => Object.hash('LMax', lhs, rhs);
}

final class LImax extends Level {
  final Level lhs, rhs;
  const LImax(this.lhs, this.rhs);
  bool operator ==(Object other) => other is LImax && other.lhs == lhs && other.rhs == rhs;
  int get hashCode => Object.hash('LImax', lhs, rhs);
}
```

#### 0b. Replace `int` with `Level` in `VType` / `TType`

- **`VType`** (value.dart): `final int level` → `final Level level`. Update const constructor, `==`, `hashCode`.
- **`TType`** (term.dart): `final int level` → `final Level level`. Update const constructor.
- **`_TypeN`** (eval.dart:4357): `final int level` → `final Level level`. Update usage.

#### 0c. Level normalization and comparison (`doxa/lib/src/eval.dart`)

Add helper functions (as private top-level functions in eval.dart):

```dart
/// Normalize a level expression: flatten max chains, sort args,
/// eliminate `max(u, u) → u`, `max(0, u) → u`, `imax(u, 0) → 0`, etc.
Level _normalizeLevel(Level l) { ... }

/// Structural `l1 <= l2` on normalized levels. For cumulativity in _Subtype.
bool _levelGte(Level a, Level b) { ... }

/// Structural `l1 == l2` on normalized levels. For strict equality in _Conv.
bool _levelEq(Level a, Level b) => _normalizeLevel(a) == _normalizeLevel(b);
```

Implementation sketch for `_normalizeLevel`:

```dart
Level _normalizeLevel(Level l) => switch (l) {
  LMax(lhs: final l1, rhs: final l2) => _normalizeMax(l1, l2),
  LImax(lhs: final l1, rhs: final l2) =>
    _normalizeLevel(l2) == LLevel(0) ? LLevel(0) : _normalizeMax(l1, l2),
  LVar() || LLevel() => l,
};

Level _normalizeMax(Level a, Level b) {
  final na = _normalizeLevel(a);
  final nb = _normalizeLevel(b);
  if (na == nb) return na;
  if (na is LLevel && na.level == 0) return nb;
  if (nb is LLevel && nb.level == 0) return na;
  // Collect LMax args, flatten, sort by structural order, rebuild
  final args = <Level>[];
  void collect(Level l) {
    if (l is LMax) { collect(l.lhs); collect(l.rhs); } else { args.add(l); }
  }
  collect(LMax(na, nb));
  args.sort(_levelCompare);
  // Deduplicate: remove args subsumed by others
  // ... (keep only args where no other arg is GTE it)
  return _rebuildMax(args);
}
```

For `_levelGte(a, b)`:

```dart
bool _levelGte(Level a, Level b) {
  final na = _normalizeLevel(a), nb = _normalizeLevel(b);
  if (na == nb) return true;
  // b is max(l1, ..., ln): a >= b iff a >= l1 && ... && a >= ln
  if (nb is LMax) return _levelGte(na, nb.lhs) && _levelGte(na, nb.rhs);
  // a is max: a >= b iff l1 >= b || ... || ln >= b
  if (na is LMax) return _levelGte(na.lhs, nb) || _levelGte(na.rhs, nb);
  // LLevel vs LVar: LLevel exact match only, LVar never >= LLevel(n>0)
  if (na is LLevel && nb is LLevel) return na.level >= nb.level;
  if (na is LVar && nb is LVar) return na.name == nb.name;
  return false;
}
```

#### 0d. Update `_Sort`, `_asSort`, `_sortToValue` (eval.dart:4348-4378)

```dart
final class _TypeN extends _Sort {
  final Level level;  // was int level
  const _TypeN(this.level);
}
```

#### 0e. Update `_piSort` / `_computePiSort`

- **`_piSort`** (eval.dart:6114): Replace `int` arithmetic with Level operations:
  ```dart
  Value _piSort(_Sort domSort, _Sort codSort) {
    if (codSort is _Prop) return VProp();
    // codSort is Type m
    final codLevel = (codSort as _TypeN).level;
    // Domain contributes its level; Prop → Level 0
    final domLevel = domSort is _Prop ? const LLevel(0) : (domSort as _TypeN).level;
    return VType(LImax(domLevel, codLevel));
  }
  ```
  Note: `LImax` correctly handles the `imax(u, 0) = 0` case for `Prop` codomains already — the `codSort is _Prop` early return is redundant but kept as a fast path.

- **`_computePiSort`** (elab.dart:1793): Same pattern — use `LImax`.

#### 0f. Update conv/subtype dispatch

- **`_Conv` VType case** (eval.dart:1638):
  ```dart
  case (VType(level: final la), VType(level: final lb)):
    step = _YieldC(
      _levelEq(la, lb) ? _ok : _mismatchOrIrrelevance(a, b, dataDecls),
    );
  ```
- **`_Subtype` VType case** (eval.dart:2240):
  ```dart
  case (VType(level: final lg), VType(level: final le)):
    step = _YieldC(
      _levelGte(lg, le) ? _ok : ConvMismatch(got, expected),
    );
  ```

#### 0g. Update all `VType(n)` / `TType(n)` sites

~30 sites across elab.dart and eval.dart. Replace `VType(0)` → `VType(LLevel(0))`, `VType(1)` → `VType(LLevel(1))`, `TType(0)` → `TType(const LLevel(0))`.

Use static constants to reduce churn:

```dart
const _l0 = LLevel(0);
const _l1 = LLevel(1);
const _vType0 = VType(_l0);
const _vType1 = VType(_l1);
```

Then `VType(0)` → `_vType0`, `VType(1)` → `_vType1`, `TType(0)` → `TType(_l0)`.

#### 0h. Update `TRec.motiveSort`

`TRec.motiveSort` currently alternates between `null` (standard .rec), `TProp()` (.ind), and `TType(0)` (.rect). Under universe polymorphism, use `Level? motiveLevel` instead — null for Prop-sorted motives (the data's own sort), a level variable for Type-sorted elimination into arbitrary universes.

---

### Step 1 — Elaborator level variable assignment (`elab.dart`)

#### 1a. `STypeKind` elaboration

Currently (elab.dart:1077-1079):
```dart
final n = level ?? 0;
return (TType(n), const VType(n + 1));
```

Under polymorphism, `level` becomes `Level?` — if null (bare `Type`), assign a **fresh level variable**:
```dart
final Level lv;
if (level != null) {
  lv = LLevel(level);
} else {
  lv = LVar(_freshLevelName());  // e.g., "u0", "u1", ...
}
// Type n : Type (n+1)
return (TType(lv), VType(LMax(lv, _l1)));  // or VType(_l1) for strict non-cumulative
```

Wait — Doxa is **non-cumulative** (SPEC §4.3). So `Type u : Type (u+1)` requires `LSucc`, which the simplified design omits. Options:
1. **Add LSucc** — requires 2 lines and subtree-aware normalization
2. **Keep simple** — Doxa's non-cumulativity means every `Type` is at an explicit level; bare `Type` can still map to `LLevel(0)` with explicit level annotations for polymorphism

Decision: **Add LSucc** but keep it minimal (used only for `Type n : Type (n+1)`). Normalization handles it: `succ(LLevel(n))` → `LLevel(n+1)`, `succ(LVar(u))` stays as `LSucc(LVar(u))`.

```dart
final class LSucc extends Level {
  final Level of;
  const LSucc(this.of);
}
```

Then `Type u : Type (succ(u))` = `VType(LSucc(lv))`.

#### 1b. Declaration-level level variables

Each declaration that uses `Type` gets fresh level variables assigned during elaboration. These are scoped to the declaration:

```dart
// In _elabDecl, before elaborating:
final levelVars = <String, Level>{};  // name → fresh LVar

String _freshLevelName() {
  final n = _levelCounter++;
  return 'u$n';
}
```

The level variables are NOT persisted in the kernel `TTop`/`TopBindingEntry` — they are fully resolved to concrete levels (or to universal variables) during elaboration. This matches Lean 4's approach: level parameters are part of the binder structure, not the kernel.

#### 1c. Level variable substitution

After elaboration and unification, substitute solved level variables:
- If all level variables resolve to concrete levels: replace `LVar("u")` → `LLevel(n)` throughout the term
- If a level variable remains unsolved: it becomes a **universe parameter** of the declaration

For Phase 15, we can require all level variables to resolve to concrete levels (monomorphic) — the "polymorphism" is in not requiring the USER to write levels, but the kernel still sees concrete levels. This is a valid stepping stone to full polymorphism in a follow-up phase.

#### 1d. `_elabDecl` level variable scoping

After `_elabDecl` produces the elaborated term, walk the term with `substLevelVar`:

```dart
Term substLevelVar(Term t, String varName, Level replacement) { ... }
```

This replaces `LVar(varName)` with `replacement` in all `TType(level)` nodes.

---

### Step 2 — Recursor bridge collapse

Currently `_makeRecBindings` (elab.dart:3325) emits 3 variants per inductive:
- `T.rec` — motiveSort = null (data's declared sort)
- `T.ind` — motiveSort = TProp() (for Type-sorted data)
- `T.rect` — motiveSort = TType(0) (for Prop-sorted singleton-elim inductives)

Under universe polymorphism, emit a SINGLE `T.rec` with a level-polymorphic motive sort:
- `TRec(motiveLevel: null, ...)` — Prop-sorted elimination (data's own sort)
- `TRec(motiveLevel: LVar("umotive"), ...)` — Type-sorted elimination into arbitrary level

The `motiveLevel` is a fresh level variable that the elaborator solves based on the user's motive type. `_makeRecBindings` change:

```dart
// SINGLE recursor, with motiveLevel determined by usage
TopBinding(
  name: '${dataName}.rec',
  type: _synthRecursorType(dataDecl, motiveLevel: levelFreeVar()),
  term: TRec(dataName, const [], motiveLevel: levelFreeVar()),
  span: span,
)
```

Remove the `.ind` and `.rect` emission entirely.

Update `eq.doxa` call sites: `Eq.rect` → `Eq.rec`. Update `admitsSingletonElim` to gate on level variables (singleton elim into Type is OK at any level, not just Level 0).

---

### Step 3 — Stdlib migration

No user-facing changes needed. All `: Type` annotations remain `: Type`. The elaborator auto-assigns fresh level variables which resolve to `LLevel(0)` (current behavior) — no observable change. Polymorphism is invisible until later phases when `Type` without an explicit level becomes a universal level variable.

Verify all 42 stdlib declarations type-check:
```shell
doxa check lib/stdlib/proofs.doxa
doxa check example/proofs.doxa
```

---

### Step 4 — Eq sort-polymorphic

`Eq[A: Type]` in prelude.doxa — bare `Type` → elaborator auto-assigns `LLevel(0)` (backward compatible). No prelude change needed. The sort-polymorphic `Eq.rec` (Step 2) allows `Eq` to be used with any level variable in the motive.

---

### Step 5 — Tests

1. **Level normalization:** `_normalizeLevel(LMax(LLevel(0), LLevel(0))) == LLevel(0)`
2. **Level subtype:** `_levelGte(LLevel(5), LLevel(3))` → true; `_levelGte(LLevel(2), LLevel(5))` → false
3. **Level equality in conv:** `VType(LLevel(0))` conv `VType(LLevel(0))` → Ok; `VType(LLevel(0))` conv `VType(LLevel(1))` → Mismatch
4. **Recursor collapse:** `data Nat : Type { zero; succ }` produces `Nat.rec` only (not `Nat.ind`, `Nat.rect`)
5. **Eq.rec works:** `Eq.rec` (single recursor) used in `sym`, `trans`, `cong`, `subst` — all type-check
6. **Stdlib regression:** All 42 declarations in `stdlib/proofs.doxa` still type-check
7. **Example regression:** `example/proofs.doxa` (26 declarations) still type-checks

---

### Step 6 — Exit verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All 383 existing tests pass. Recursor bridge is dead code. Level normalization/subtype/equality all unit-tested. `dart format` clean.

---

## Files to modify

| File | Changes | Est. lines |
|------|---------|-----------|
| `doxa/lib/src/term.dart` | `Level` sealed class (4 subclasses). `TType(Level)`. `TRec.motiveSort → motiveLevel: Level?`. `openTerm`/`closeTerm` walk `Level` sub-terms. | ~80 |
| `doxa/lib/src/value.dart` | `VType(Level)`. | ~5 |
| `doxa/lib/src/eval.dart` | `_Sort._TypeN(Level)`. `_asSort`, `_sortToValue`. `_piSort` uses `LImax`. `_Conv` VType uses `_levelEq`. `_Subtype` VType uses `_levelGte`. 30 `VType(0)`/`VType(1)` → constants. `_normalizeLevel`, `_levelGte`, `_levelEq`. `_inferValueType` uses `LSucc`. | ~80 |
| `doxa/lib/src/elab.dart` | `_computePiSort` uses `LImax`. `STypeKind` elaboration: fresh level variables. `_makeRecBindings` collapse to single `T.rec`. 15 `VType(n)` → constants. Level variable substitution walker. | ~60 |
| `doxa/lib/src/check.dart` | Possibly minor (if error types embed int levels). | ~5 |
| `doxa/lib/src/diff.dart` | `_structuralEq` VType: use `_levelEq`. | ~5 |
| `doxa/lib/src/pretty.dart` | Level pretty-printing. | ~10 |
| `doxa/lib/src/quote.dart` | If separate from eval.dart (it's not — quote is in eval.dart). | 0 |
| `lib/stdlib/eq.doxa` | `Eq.rect` → `Eq.rec` (2 sites) | ~2 |
| `lib/stdlib/prelude.doxa` | (No change — bare `Type` = `LLevel(0)`) | 0 |
| `doxa/test/level_test.dart` | New: Level normalization, GTE, equality tests | ~60 |
| `doxa/test/check_test.dart` | Recursor bridge test: verify single `T.rec` | ~15 |
| **Total** | | **~322** |

## Risk assessment

**Medium.** This is the largest kernel change since Phase 11 (inductive types). The level normalization/comparison functions must be bug-for-bug compatible with the existing int-based logic for all concrete levels. All 30 hardcoded level sites must be updated. The recursor bridge collapse may break user code that references `.ind`/`.rect` by name.

**Mitigations:**
1. Level normalization is isolated — unit-test exhaustively with concrete level expressions
2. Use static constants (`_vType0`, `_vType1`) to make the ~30 site changes mechanical
3. Recursor names: emit `.rec` only, add `.ind`/`.rect` as deprecated aliases that forward to `.rec`
4. Run stdlib/proofs.doxa and example/proofs.doxa after each sub-step

## Session estimate

**12-18 sessions** (4-6 per sub-step). Break down:
- Step 0 (Level datatype + normalization): 4-6 sessions
- Step 1 (Elaborator level variables): 3-4 sessions
- Step 2 (Recursor collapse): 2-3 sessions
- Step 3 (Stdlib migration): 1 session
- Step 5 (Tests): 2-3 sessions
- Step 6 (Verification + polish): 1 session
