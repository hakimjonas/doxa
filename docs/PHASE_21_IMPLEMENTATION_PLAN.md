# Phase 21 — Typeclasses + Instance Search

## Part A: Design Note (prior-work study)

### Four reference models

**Agda (Instance Arguments):**
No special "typeclass" keyword — record types ARE typeclasses. `instance` block
declares instances. Instance arguments use `{{arg}}` syntax. Resolution: goal
must target a named type (data/record/postulate); candidates are global instances
+ local bindings + constructor instances; unification-based selection. Overlap
control via `OVERLAPPABLE`/`OVERLAPPING` pragmas. Backtracking via flag.
**The simplest model in the field.** Source: `language/instance-arguments.html`.

**Idris 2 (Interfaces):**
`interface Name a where { ... }` keyword. Implementations via `Name Type where { ... }`.
Named implementations with `[name]` prefix. `using` clause for parent selection.
Determining parameters via `| m` (functional-dependency-like). Default method
definitions. **Cleanest ML-family syntax.** Source: `tutorial/interfaces.html`.

**Coq (Typeclasses):**
Rich system: `Class`, `Instance`, `Existing Instance` keywords. `Typeclasses eauto`
for automated proof search. Priority-based overlap resolution. The most mature
but also the heaviest. Source: `addendum/type-classes.html`.

**Fungal (Doxa's target syntax):**
```fungal
typeclass Eq[A] { fun equals(x: A, y: A): Boolean }
typeclass Ord[A]: Eq[A] { fun compare(x: A, y: A): Int }
impl Eq[Int] { fun equals(x, y) { x == y } }
fun find[A: Eq](list: List[A], target: A): Option[A] { ... }
fun sortedSet[A: Ord & Hash](items: List[A]): Set[A] { ... }
```
Source: `SYNTAX.md` lines 805-901.

### Decision: Idris 2-style elaboration with Agda-style resolution

**Why this hybrid:**

1. **Idris 2's interface model** maps cleanly to Doxa's kernel: a typeclass is a
   record whose fields are methods, and an `impl` is a top-level instance of that
   record. This can desugar to Doxa's existing `data` + primitive projections
   (from Phase 17) with no new kernel types needed.

2. **Agda's resolution algorithm** is the simplest in the field: candidate instances
   are unified against the goal type using the existing pattern unifier. Doxa
   already has `_insertImplicits` (elab.dart) which creates metas for implicit args
   and solves them via pattern unification. Instance search hooks into this same
   mechanism — instead of allocating a plain meta, the elaborator consults the
   instance table to find a matching candidate.

3. **No new kernel types.** A typeclass is `data Eq[A] { mk : (equals: A -> A -> Bool) -> Eq[A] }`
   desugared from the `typeclass` keyword. An `impl` is a `val Eq[Int] = mk(intEquals)`.
   Instance search is purely an elaborator feature.

4. **Fungal-compatible syntax.** `typeclass`, `impl`, `A: Eq` constraint annotations,
   `&` for multiple constraints — all match Fungal's SYNTAX.md.

### How instance search works

When the elaborator encounters `fun find[A: Eq](...)`, it:
1. Parses `A: Eq` as a constrained type parameter — `A` has kind `Type` and
   constraint `Eq`.
2. Inserts an implicit instance argument: the function type becomes
   `Pi(A: Type) → Pi({{inst: Eq[A]}}) → (list: List[A]) → ...`.
3. At call sites, `_insertImplicits` creates a meta for `Eq[Int]`, then
   consults the per-class instance table for `Eq`. The candidates are unified
   against `Eq[Int]` using pattern unification.
4. If exactly one candidate unifies, the meta is solved. If none, error. If
   multiple and one is strictly more specific, the more specific wins. If
   multiple with equal specificity, error (overlap).

This allows the elaborate to express "find me an instance of Eq for Int" and
have it resolved automatically, without explicit instance passing.

---

## Part B: Implementation Plan (~250 lines, 8-12 sessions)

### Step 0 — Surface syntax + parser (~50 lines)

#### 0a. `STypeclassKind` and `SImplKind` (surface.dart)

```dart
/// A typeclass declaration: `typeclass Eq[A] { fun equals(x: A, y: A): Bool }`.
final class STypeclassKind extends SDeclKind {
  @override final String name;
  final List<(String, SExpr?)> typeParams;   // [A: Type] etc.
  final SExpr? superclass;                    // e.g. Eq[A]
  final List<SClassMethod> methods;

  const STypeclassKind(this.name, this.typeParams, this.methods, {this.superclass});
}

/// A single method in a typeclass: `fun equals(x: A, y: A): Bool`.
final class SClassMethod {
  final String name;
  final SExpr? type;     // method body is defined in impl
  final SExpr? defaultBody;  // optional default implementation
  const SClassMethod(this.name, this.type, {this.defaultBody});
}

/// An instance: `impl Eq[Int] { fun equals(x, y) { x == y } }`.
final class SImplKind extends SDeclKind {
  @override final String name;  // optional, synthetic if absent
  final SExpr typeclassRef;     // e.g. Eq[Int]
  final List<SFunKind> members;

  const SImplKind(this.typeclassRef, this.members, {this.name = ''});
}
```

#### 0b. Parser (parse.dart)

```
typeclassDecl ::= 'typeclass' ident typeParams (':' expr)? '{' (method ';')* '}'
method ::= 'fun' ident valueParams (':' retType)? ('=' expr)?
implDecl ::= 'impl' expr '{' (funDecl ';')* '}'
```

Add `typeclass`, `impl` to reserved words. Add constraint syntax `[A: Eq & Ord]`
to `_funTypeParamGroup` — when the kind annotation after `:` is not a sort
keyword (Type/Prop/SProp), treat it as a constraint.

```dart
final Parser<ParseError, List<SFunTypeParam>> _funTypeParamGroup(
  String open, String close, bool isImplicit,
) => _sym(open).skipThen(
  _ident.flatMap<SFunTypeParam>(
    (name) => _sym(':').skipThen(
      _expr.sepBy(_sym('&')).map((cs) => cs.length == 1 ? cs.first : null)
    ).optional.map((kind) {
      // If kind is a bare sort keyword, it's a kind annotation.
      // Otherwise, it's a constraint (or list of constraints with &).
      return SFunTypeParam(name, kind, isImplicit: isImplicit);
    }),
  ).sepBy(_sym(',')),
).thenSkip(_sym(close));
```

#### 0c. `&` intersection parser

Add `_sym('&')` as a type-level combinator for constraint intersection.
Produces `SIntersectionKind(cs)`.

### Step 1 — Elaborator: typeclass → record desugaring (~40 lines)

#### 1a. `_elabTypeclass` (elab.dart)

In `_elabDecl`:

```dart
case STypeclassKind(:final name, :final typeParams, :final methods, :final superclass):
  return _elabTypeclass(topEnv, name, typeParams, methods, superclass, decl.span);
```

`_elabTypeclass` desugars the typeclass to a `data` declaration:

```
typeclass Eq[A] { fun equals(x: A, y: A): Bool }
```
↓ desugars to:
```
data Eq[A] : Type {
  mk : (equals: (x: A) -> (y: A) -> Bool) -> Eq[A];
}
```

For superclasses:
```
typeclass Ord[A]: Eq[A] { fun compare(x: A, y: A): Int }
```
↓ desugars to:
```
data Ord[A] : Type {
  mk : (eqInst: Eq[A]) -> (compare: (x: A) -> (y: A) -> Int) -> Ord[A];
}
```

The superclass becomes the first field of the record. Field access `ord.eqInst`
retrieves the superclass instance.

The type params + methods are elaborated into a `DataDecl` with a single
constructor `mk`. The method types become the constructor's argument types.
The generated `DataDecl` is registered in `topEnv.dataDecls` so that
primitive projections (Phase 17) work on class fields.

Additionally, for each method, synthesize a convenience function:
```
fun equals[A](eqInst: Eq[A], x: A, y: A): Bool = eqInst.equals x y
```
This allows `Eq.equals(a, b)` syntax.

#### 1b. Instance table registration

After desugaring, the typeclass name is registered in a new per-`TopEnv` field:

```dart
// In TopEnv (elab.dart):
final class TopEnv {
  final List<TopBinding> bindings;
  final List<DataDecl> dataDecls;
  final Map<String, ClassInfo> classRegistry;  // NEW: class name → info

  const TopEnv(this.bindings, this.dataDecls, {
    this.classRegistry = const {},
  });
}

final class ClassInfo {
  final String className;
  final List<String> typeParams;
  final List<(String, Term)> methods;  // method name → type
  final String? superclassName;
}
```

### Step 2 — Instance elaboration (~40 lines)

#### 2a. `_elabImpl` (elab.dart)

```
impl Eq[Int] {
  fun equals(x: Int, y: Int): Bool { x == y }
}
```
↓ desugars to:
```
val _impl_Eq_Int : Eq[Int] = mk(intEquals)
```
where `intEquals` is the elaborated lambda body.

The elaborator resolves `Eq[Int]` against the class registry, looks up the
`mk` constructor's expected field types, checks each method body against its
declared type, and constructs the `mk(...)` application.

#### 2b. Instance table population

After elaboration + checking, the instance is registered in `classRegistry`:

```dart
// In classRegistry, under "Eq":
classRegistry["Eq"]!.instances.add(InstanceInfo(
  targetType: "Int",
  binding: topBindingForImpl,
));
```

### Step 3 — Instance search during elaboration (~50 lines)

#### 3a. Constrained type params

When a `fun` declares `[A: Eq]`, the elaborator:
1. Normal type param `A` with inferred kind `Type`.
2. Constraint `Eq` is recorded on the param.
3. An implicit instance argument is inserted: the function's Pi type gains
   an implicit `{{inst: Eq[A]}}` parameter BEFORE the explicit value params.

```dart
// In _elabFun / _buildFunBody:
for (final param in typeParams) {
  if (param.constraints != null) {
    for (final c in param.constraints!) {
      // Insert implicit instance argument for this constraint
      instanceArgs.add((c, param.name));
    }
  }
}
```

#### 3b. Instance resolution at call sites

In `_insertImplicits` (elab.dart line 2063), when encountering an implicit
Pi whose domain type is a class type (identified via `classRegistry`):

```dart
while (curV is VPi && curV.icit == Icit.implicit) {
  if (curV.domain is VData && classRegistry.containsKey((curV.domain as VData).name)) {
    // This is a class-constrained implicit — resolve via instance search
    final className = (curV.domain as VData).name;
    final classInfo = classRegistry[className]!;
    final candidates = classInfo.instances
        .where((i) => _unifiesWith(curV.domain, i.targetType))
        .toList();
    if (candidates.length == 1) {
      // Solve the meta directly with the instance
      final instanceTerm = TTop(candidates.first.binding.name);
      metas.solve(metaId, instanceTerm);
    } else if (candidates.isEmpty) {
      throw NoInstanceFound(className, curV.domain, span);
    } else {
      throw OverlappingInstances(className, candidates, span);
    }
  } else {
    // Regular implicit — allocate a meta as before
    final metaId = metas.freshTermMeta(closedType, state.ctx);
    // ...
  }
}
```

#### 3c. Multi-constraint `&`

`[A: Eq & Ord]` creates TWO implicit instance args: `{{inst1: Eq[A]}}` and
`{{inst2: Ord[A]}}`. When resolving `Ord[A]`, the `Ord` instance provides
access to `Eq[A]` via its superclass field (the first constructor arg).

### Step 4 — Stdlib instances (~20 lines)

Add minimal stdlib instances to demonstrate the system:

```
// In eq.doxa or a new instance file:
impl Eq[Nat] {
  fun equals(x: Nat, y: Nat): Bool = Nat.eqb x y
}

impl Eq[Bool] {
  fun equals(x: Bool, y: Bool): Bool = Bool.eqb x y
}
```

### Step 5 — Tests (~60 lines)

Create `doxa/test/typeclass_test.dart`:

| # | Test | Expected |
|---|------|----------|
| 1 | `typeclass Eq[A] { ... }` parses | STypeclassKind |
| 2 | `impl Eq[Int] { ... }` parses | SImplKind |
| 3 | `fun find[A: Eq](...)` — constrained param | Type param with constraint |
| 4 | Instance resolution at call site | `find(5)` resolves `Eq[Int]` |
| 5 | Superclass: `Ord[A]: Eq[A]` | Superclass field emitted |
| 6 | Missing instance → error | NoInstanceFound |
| 7 | Overlapping instances → error | OverlappingInstances |
| 8 | Multi-constraint `[A: Eq & Show]` | Both constraints resolved |
| 9 | `Eq.equals(a, b)` convenience function works | Method call resolves |
| 10 | `typeclass` desugars to single-ctor `data` | DataDecl with 1 ctor |

---

### Step 6 — Exit verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All 872 existing tests pass. New typeclass tests pass.
`dart format --set-exit-if-changed` clean.

---

## Files to modify

| File | Changes | Est. lines |
|------|---------|-----------|
| `doxa/lib/src/surface.dart` | `STypeclassKind`, `SImplKind`, `SClassMethod`, `SIntersectionKind` | +30 |
| `doxa/lib/src/parse.dart` | `typeclass`/`impl` keywords, `&` combinator, constraint syntax in `_funTypeParamGroup` | +35 |
| `doxa/lib/src/elab.dart` | `_elabTypeclass`, `_elabImpl`, `ClassInfo`, `InstanceInfo`, `classRegistry` on `TopEnv`, instance resolution in `_insertImplicits`, `NoInstanceFound`/`OverlappingInstances` errors | +80 |
| `doxa/lib/src/env.dart` | Possibly minor — thread `classRegistry` through `TopBindingEntry` | +5 |
| `doxa/lib/src/report.dart` | New error formatting | +10 |
| `doxa_tooling/lib/src/web_check.dart` | New error kind mappings | +3 |
| `doxa_tooling/lib/src/syntax.dart` | `kwTypeclass`, `kwImpl` tokens | +3 |
| `doxa/test/typeclass_test.dart` | **New file** — 10 tests | +60 |
| `lib/stdlib/eq.doxa` | Add `impl Eq[Nat]`, `impl Eq[Bool]` | +10 |
| **Total** | | **~236** |

## Risk assessment

**Risk: Medium.** Instance search modifies the elaborator's implicit-argument
resolution path, which is a hot code path. The desugaring of typeclasses to
single-ctor data declarations reuses Phase 17's projection infrastructure,
so kernel correctness is inherited. The main risk is the instance resolution
algorithm producing wrong results (choosing wrong instance) or missing valid
instances due to unification limitations.

**Mitigations:**
- Instance search is gated on `classRegistry` membership — if no registry
  entry exists, the code path is identical to current behavior.
- The initial implementation supports only non-overlapping instances
  (exactly one candidate must unify). Overlap resolution with priorities
  can be added later.
- All typeclass machinery desugars to existing kernel constructs
  (`data` + projections) — if the desugaring is correct, the kernel
  guarantees type safety.

## Session estimate

**8-12 sessions.** Break down:
- Step 0 (surface + parser): 2-3 sessions
- Step 1 (typeclass → record desugaring): 2-3 sessions
- Step 2 (instance elaboration): 1-2 sessions
- Step 3 (instance search): 2-3 sessions
- Steps 4-5 (stdlib + tests): 1 session
