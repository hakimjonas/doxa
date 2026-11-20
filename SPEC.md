# Doxa implementation specification

This document describes behavior implemented by the current Doxa parser,
elaborator, checker, evaluator, and command-line tool. `SYNTAX.md` is the
surface-syntax reference.

## Pipeline

`doxa check FILE` loads the ambient prelude, resolves imports, parses the
program, elaborates declarations, and checks the elaborated terms. The prelude
declares `Eq` and `Acc`.

Imports use quoted paths. A path is either relative to the importing file or a
`package:` URI of the form `package:<name>/<path>`. A `package:` import is
resolved through the nearest `.dart_tool/package_config.json` above the
importing file: `<name>` must name a package in that configuration, and
`<path>` is resolved under that package's library root (`lib/` unless the
configuration records another `packageUri`). A missing configuration, an
undeclared package, or a malformed specifier is a resolution error; the
resolver never falls back to a relative path. The parser accepts an
unqualified import, a selective import, an alias, or both:

```doxa
import "nat.doxa"
import "package:doxa_stdlib/stdlib/nat.doxa"
import "nat.doxa" { Nat, zero } as N
```

This is a syntax fragment, not a standalone program, because the referenced
file must exist. Dotted names such as `Nat.ind` and `N.zero` are accepted where
a name is expected.

## Terms and sorts

Doxa uses one expression grammar for terms and types. The implementation uses de Bruijn indices for local binders and named references for top-level definitions. Elaboration resolves source names before type checking.

The checker has inference and checking modes. An unannotated lambda requires
an expected function type. Evaluation produces values; quotation reifies values
to terms; conversion compares values. Transparent top-level definitions can
unfold during conversion. An opaque declaration remains opaque to conversion:

```doxa
opaque fun id[A: Type](x: A): A = x
```

`Type`, `Prop`, and `SProp` are sorts. `Type` accepts an optional decimal universe level, such as `Type 0`. That decimal token is a universe level, not a general term literal. `Prop` and `SProp` do not take a level argument.

`SProp` has dedicated parser, term, value, and checking support. The elaborator
requires fields of an SProp-sorted inductive to be SProp-sorted. It also checks
the implemented restriction on elimination from Prop-sorted inductives into
Type-sorted results.

## Declarations

Top-level declarations include `val`, `type`, `fun`, `data`, `theorem`,
`typeclass`, `impl`, and `import`. `theorem name : T := proof` elaborates as a
typed value declaration. The theorem marker may also be `=`.

```doxa
theorem identity : (A: Type) -> (x: A) -> Eq A x x := by {
  intro A; intro x; refl
}
```

The tactic steps implemented by `by` blocks are `intro`, `exact`, `apply`,
`refl`, `rewrite`, `induction`, `cases`, `revert`, `trivial`, `simp`,
`auto`, `omega`, and `constructor`. `revert x` moves a local binder back
into the goal. `simp` normalises the goal by evaluation and rewrites it with
the equality hypotheses in context; an optional bracketed list adds
equalities, as in `simp [plus_zero, plus_succ]`. `cases x` destructs a
variable into one subgoal per constructor, without induction hypotheses.
`constructor` applies the first constructor whose result type matches the
goal, leaving its arguments as subgoals. `auto` searches depth-bounded for
`refl`, `trivial`, and applications of names in scope; `auto 10` raises the
depth. `omega` normalises both sides of an equality and tries the arithmetic
lemmas in scope; it is not a decision procedure. Semicolons sequence steps;
`|` separates alternatives.

Function declarations accept explicit type parameters in `[...]`, implicit type parameters in `{...}`, and value parameters in `(...)`. At a call site, elaboration inserts metavariables for omitted implicit arguments.

```doxa
fun id{A: Type}(x: A): A = x
```

The parser also accepts `{struct name}` and `termination_by (name, ...)` after a function's result type. These are declaration fragments because `T`, `U`, `V`, and `body` require definitions:

```doxa
fun f(x: T): U {struct x} = body
fun f(x: T, y: U): V termination_by (x, y) = body
```

Mutual declarations join members with `and fun` or `and data`. The members of a mutual block are in scope in the block's bodies.

## Inductive types and matching

`data` declares an inductive type and its constructors. Its signature ends in `Type`, `Prop`, or `SProp`; preceding arrow domains are indices. Constructor types use ordinary Doxa syntax. Constructor entries may be separated with `;` or `|`, and a trailing separator is accepted.

```doxa
data Nat: Type {
  zero: Nat | succ: Nat -> Nat;
}
```

The elaborator checks constructor result shapes and positivity. It records data
declarations and constructors for checking, matching, projections, and derived
eliminator bindings.

Product-form data declarations contain fields whose result types do not refer to the data name. The parser desugars such a declaration to a single `mk` constructor:

```doxa
data Point[A: Type]: Type {
  x: A;
  y: A;
}
```

Projection uses dotted syntax such as `p.x`. There is no `record` keyword.

`match` examines an inductive value. A constructor arm introduces one binder per constructor argument. `case _ => body` is a wildcard arm. Arms do not need a separator, and `returning` supplies an optional motive.

```doxa
data Nat: Type { zero: Nat; succ: Nat -> Nat; }

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}
```

The elaborator checks duplicate arms and coverage. The checker performs
additional motive and reachability checks for indexed-family matches.

## Local bindings and quotients

A block expression has zero or more local `val` bindings, each followed by
`;`, and a final result expression. A local binding can use `val rec`.

```doxa
{ val x: Type 1 = Type; x }
```

This is an expression fragment; the checked form appears in `SYNTAX.md` with a surrounding value declaration and expected type.

Quotient expressions have these surface forms:

```doxa
Quot(A, R)
mk value
lift(function, compatibilityProof)
```

These quotient forms are expression fragments. `mk` is accepted in check mode
against an expected quotient type. `lift` is completed by a surrounding
application that supplies a quotient argument. The elaborator emits dedicated
quotient terms, and the checker verifies their formation and elimination rules.

## Typeclasses

A `typeclass` declaration produces a dictionary type and one projection per
method. The dictionary type is an ordinary inductive with a single
constructor and one field per method.

```doxa
typeclass Eqb[A: Type] {
  fun eqb(x: A, y: A): Bool;
}
```

elaborates to

```doxa
data Eqb[A: Type] : Type {
  mk_Eqb: (eqb: (x: A) -> (y: A) -> Bool) -> Eqb A;
}
```

together with the projection
`eqb : {A: Type} -> (x: A) -> (y: A) -> {inst: Eqb A} -> Bool`. A projection
binds the class parameters implicitly, then the method's explicit arguments,
then the dictionary as an implicit binder after them; its body applies the
dictionary field to the explicit arguments.

An `impl` supplies the dictionary value for one type and registers it in the
class's instance table.

```doxa
impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = ...;
}
```

`Nat` requires a declaration, so this is a fragment.

A constrained type parameter keeps the icity of its group. Constraints are
accepted on explicit `[...]` parameters; the parser does not accept them in
`{...}` groups. Its dictionary is an implicit argument placed after the
explicit value parameters, so the class parameter is solved from them first.

```doxa
fun same[A: Eqb](x: A, y: A): Bool = eqb x y
```

A call supplies the type argument explicitly, as with any `[...]` parameter,
and the dictionary is filled by instance search: `same Nat zero zero` supplies
`Nat` and resolves `Eqb[Nat]`.

A call-site dictionary is filled by matching the head type constructor of the
required class argument against the registered instances, then matching the
argument types against the selected instance's parameters positionally. Each
constraint the instance declares is discharged recursively at the matched
type, with the depth bound decremented. Search is depth-bounded at 8. A
parameter that is itself class-constrained in the local context supplies its
dictionary without a search. A failed search is an error that names the class
and the target type; a failed inner constraint names the inner class and
inner type. The elaborator does not defer the dictionary through an unsolved
metavariable.

An `impl` may declare its own type parameters between `impl` and the class
reference, using the same group syntax as `fun`. A parameter group is
required when the target applies a type constructor to the instance's
parameters.

```doxa
impl[A: Eqb] Eqb[List A] {
  fun eqb(x: List A, y: List A): Bool = ...;
}
```

The target after the class name is either a bare type constructor or a
concrete head applied to distinct parameters from the group. A bare variable
target, a closed argument, a repeated parameter, and a parameter that does
not appear in the target are rejected with `UnsupportedInstanceTarget` and a
reason. The instance elaborates to a binding with explicit binders,
`(A: Type) -> (inst: Eqb A) -> Eqb (List A)`, whose body builds the
dictionary. Method bodies elaborate with the parameters and their
dictionaries in scope. An instance method body does not see the instance
being defined; recursion is expressed through a top-level `fun`, which is
subject to the structural-recursion rule.

Search selects the single instance registered at the goal's head, matches the
goal's arguments against the instance's target parameters positionally, and
discharges each constraint at the matched type. The result applies the
instance binding to the matched arguments and the resolved dictionaries in
binder order. A failed inner discharge reports `NoInstanceFound` for the
inner class and type. A chain longer than the depth bound reports
`InstanceSearchDepthExceeded`.

At most one instance exists per class and head, so a second parameterised
instance for the same head is rejected with `OverlappingInstances`.

Class method names are top-level projection names and share the global
namespace; two classes cannot declare the same method name.

This version does not implement superclasses, local instances, default method
bodies, or classes with more than one parameter. A superclass is rejected with
`SuperclassUnsupported`, a default method body with `TypeclassUnsupported`, a
missing or unknown method with `MissingInstanceMethod` or
`UnknownInstanceMethod`, an unknown class with `UnknownTypeclass`, and a
wrong class-argument count with `TypeclassArityMismatch`.

## Scope

This document makes no performance, metatheoretic, or compatibility claim not
represented by the current implementation or its checked examples. The sources
under `doxa/lib/src/` are authoritative for details omitted here.
