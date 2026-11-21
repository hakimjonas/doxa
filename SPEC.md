# Doxa implementation specification

This document describes behavior implemented by the current Doxa parser,
elaborator, checker, evaluator, and command-line tool. It is the normative
description of the surface syntax and the implemented typing rules.

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

<!-- doxa: fragment -->
```doxa
import "nat.doxa"
import "package:doxa_stdlib/stdlib/nat.doxa"
import "nat.doxa" { Nat, zero } as N
```

This is a syntax fragment, not a standalone program, because the referenced
file must exist.

## Terms and sorts

Doxa uses one expression grammar for terms and types. The implementation uses de Bruijn indices for local binders and named references for top-level definitions. Elaboration resolves source names before type checking.

Newlines are whitespace. Line comments start with `//`; block comments use `/*` and `*/` and may nest. Identifiers start with a letter or `_`, then contain letters, digits, or `_`. A dotted name appends one or more `.name` suffixes to an identifier expression; `Nat.ind` and `N.zero` are accepted where a name is expected.

Application is juxtaposition and associates to the left: `f x y` parses as `(f x) y`. Brackets are a postfix form on an identifier and contain one or more comma-separated expressions; `List[A]` applies `List` to `A`, and a term after a bracket form is ordinary application, so `Vec[A] n` applies the result to `n`.

Lambdas use `(x: A) => body` or `{x: A} => body`, and curly binders are implicit. The unannotated `(x) => body` requires an expected Pi type. Pi types use `(x: A) -> B`, `{x: A} -> B`, or `A -> B`; `A -> B -> C` associates to the right, and the non-dependent arrow has an unnamed explicit binder.

The checker has inference and checking modes. An unannotated lambda requires
an expected function type. Evaluation produces values; quotation reifies values
to terms; conversion compares values. Transparent top-level definitions can
unfold during conversion. An opaque declaration remains opaque to conversion:

```doxa
opaque fun id[A: Type](x: A): A = x
```

`Type`, `Prop`, and `SProp` are sorts. `Type` accepts an optional decimal universe level, such as `Type 0`. That decimal token is a universe level, not a general term literal. `Prop` and `SProp` do not take a level argument. `Prop` is impredicative: a dependent function type whose codomain is in `Prop` is itself in `Prop`.

Universe levels are cumulative during checking: `Type n` checks against `Type m` when `n <= m`. Pi types are covariant in the codomain and contravariant in the domain. Definitional equality remains strict on levels, and cumulativity does not cross sorts: `Prop` does not check against `Type 0`, and `Type 0` does not check against `Prop`.

`SProp` has dedicated parser, term, value, and checking support. The elaborator
requires fields of an SProp-sorted inductive to be SProp-sorted. It also checks
the implemented restriction on elimination from Prop-sorted inductives into
Type-sorted results.

## Declarations

Top-level declarations include `val`, `type`, `fun`, `data`, `theorem`,
`typeclass`, `impl`, and `import`. `theorem name : T := proof` elaborates as a
typed value declaration. The theorem marker may also be `=`.

<!-- doxa: fragment -->
```doxa
val x: T = expr
val x = expr
opaque val x: T = expr
type Name = T
theorem name: T := proof
theorem name: T = proof
```

A type alias, value declaration, and theorem are top-level declarations. The
type on a non-recursive `val` may be omitted, and `opaque` also precedes `fun`.

```doxa
theorem identity : (A: Type) -> (x: A) -> Eq A x x := by {
  intro A; intro x; refl
}
```

The tactic steps implemented by `by` blocks are `intro`, `exact`, `apply`,
`refl`, `rewrite`, `induction`, `cases`, `revert`, `trivial`, `simp`,
`auto`, `omega`, and `constructor`. A block is written `by { step; ... }`, and
`intro` takes an optional binder name. `revert x` moves a local binder back
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

Function declarations accept explicit type parameters in `[...]`, implicit type parameters in `{...}`, and value parameters in `(...)`. An explicit group may state `&`-separated constraints. Value parameters are comma-separated and have type annotations. At a call site, elaboration inserts metavariables for omitted implicit arguments.

```doxa
fun id[A: Type](x: A): A = x
fun idImplicit{A: Type}(x: A): A = x
```

The parser also accepts mixed and implicit-first groups, `{struct name}`, and
`termination_by (name, ...)` after a function's result type. These are
declaration fragments because `T`, `U`, `V`, and `body` require definitions:

<!-- doxa: fragment -->
```doxa
fun f[A]{B: Type}(x: A): B = body
fun f[A: Eqb](x: A): A = body
opaque fun f(x: T): U = body
fun f(x: T): U {struct x} = body
fun f(x: T, y: U): V termination_by (x, y) = body
```

Mutual declarations join members with `and fun` or `and data`. The members of a mutual block are in scope in the block's bodies.

### Structural recursion

A recursive `fun` must be structurally recursive. Its designated argument is
the first explicit value parameter, or the parameter named in a `{struct name}`
annotation on the declaration. Every call to the function, including a call to
a sibling in a `fun ... and ...` block, must pass a strict sub-term of the
caller's designated argument in the callee's designated position. A strict
sub-term is a pattern binder introduced by matching on the designated
argument, or a pattern binder of a match on such a binder. An unapplied
reference to a recursive function is rejected, because the eventual call
cannot be checked.

A call that supplies explicit type arguments passes them before its value
arguments. The check counts those type arguments when it locates the
designated value position. Implicit type parameters are supplied by
elaboration, not by the call, and do not shift the position.

Evaluation unfolds a recursive function only when its designated argument is a
constructor, so a recursive call on an unrefined variable stays stuck instead
of unfolding.

## Inductive types and matching

`data` declares an inductive type and its constructors. Its signature ends in `Type`, `Prop`, or `SProp`; preceding arrow domains are indices. Constructor types use ordinary Doxa syntax. Constructor entries may be separated with `;` or `|`, and a trailing separator is accepted.

```doxa
data Nat: Type {
  zero: Nat | succ: Nat -> Nat;
}

data Vec[A: Type]: Nat -> Type {
  vnil: Vec[A] zero |
  vcons: (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
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

Construct values with the qualified constructor name, as in `Point.mk x y`. The unqualified `mk` is reserved for quotient construction and is rejected for a product-form declaration. Every field projects with dotted syntax:

```doxa
import "package:doxa_stdlib/stdlib/nat.doxa"

data Point: Type {
  x: Nat;
  y: Nat;
}

val p: Point = Point.mk zero (succ zero)
val first: Nat = p.x
val second: Nat = p.y
```

There is no `record` keyword.

A module declares at most one product-form record: every product-form declaration desugars to a constructor named `mk`, and a second `mk` in the same module is rejected as a duplicate declaration. Declare additional records with named constructor arguments, as in `data Segment: Type { seg: (start: Point) -> (end: Point) -> Segment; }`. The qualified constructor `Segment.seg` projects through `start` and `end`.

`match` examines an inductive value. A constructor arm introduces one binder per constructor argument; a constructor pattern is a constructor name followed by zero or more binders. `case _ => body` is a wildcard arm. Arms do not need a separator, and `returning` supplies an optional motive.

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
`;`, and a final result expression. A local binding can use `val rec`. The type
on a non-recursive local `val` may be omitted. A block used as an application
argument must be parenthesized, as in `f ({ val x = y; x })`.

```doxa
val block: Type 2 = { val x: Type 1 = Type; x }
```

Quotient expressions have these surface forms:

<!-- doxa: fragment -->
```doxa
Quot(A, R)
mk value
lift(function, compatibilityProof)
```

These quotient forms are expression fragments. `Quot(A, R)` forms a type.
`mk` and `lift` are rejected at the surface with `QuotientUnsupported`, and the
kernel API rejects the `TQuotMk` and `TQuotLift` terms with
`QuotientTermUnsupported`, because the lift compatibility proof is not checked.
No quotient elimination is available. The forms above are listed for the
planned completion and do not check.

## Typeclasses

A `typeclass` declaration produces a dictionary type and one projection per
method. The dictionary type is an ordinary inductive with a single
constructor and one field for the superclass dictionary when a superclass is
declared, followed by one field per method. A class may declare more than one
type parameter; the dictionary carries all of them and each projection binds
them implicitly.

```doxa
import "package:doxa_stdlib/stdlib/bool.doxa"

typeclass Eqb[A: Type] {
  fun eqb(x: A, y: A): Bool;
}
```

elaborates to

```doxa
import "package:doxa_stdlib/stdlib/bool.doxa"

data Eqb[A: Type] : Type {
  mk_Eqb: (eqb: (x: A) -> (y: A) -> Bool) -> Eqb A;
}
```

together with the projection
`eqb : {A: Type} -> (x: A) -> (y: A) -> {inst: Eqb A} -> Bool`. A projection
binds the class parameters implicitly, then the method's explicit arguments,
then the dictionary as an implicit binder after them; its body applies the
dictionary field to the explicit arguments.

### Superclasses

A class may name one superclass after its parameters. The superclass
reference is a class application over the class's own type parameters.

<!-- doxa: fragment -->
```doxa
typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}
```

elaborates the dictionary with the parent dictionary as its first field:

<!-- doxa: fragment -->
```doxa
data Ord[A: Type] : Type {
  mk_Ord: (_super: Eqb A) -> (cmp: (x: A) -> (y: A) -> Bool) -> Ord A;
}
```

The parent's methods remain the parent's projections; `Ord` adds only `cmp`.
The superclass reference must apply the parent class to distinct class type
parameters, with every class parameter appearing once. A parent class with
more than one parameter follows the same rule.

An `impl` of a subclass resolves the parent dictionary by instance search at
registration, with the instance's own parameters and their dictionaries in
scope. A missing parent is `NoInstanceFound` naming the parent class and its
target type. The parent instance must be in scope when the subclass instance
is elaborated. A parent instance declared later is not visible at
registration.

Search for a class prefers a direct instance. When none matches, it considers
direct subclasses whose superclass is the requested class, builds the
subclass goal from the parent goal, searches for the subclass dictionary, and
projects the embedded parent dictionary. The recursion covers longer chains.
Two subclass dictionaries providing the same parent report
`OverlappingInstances`.

### Multiple type parameters

A class with two parameters carries both in its dictionary. Its projections
bind both implicitly.

<!-- doxa: fragment -->
```doxa
typeclass Pair[A: Type, B: Type] {
  fun fst(x: A, y: B): A;
}
```

elaborates to `mk_Pair: (fst: (x: A) -> (y: B) -> A) -> Pair A B` and the
projection `fst : {A: Type} -> {B: Type} -> (x: A) -> (y: B) -> {inst: Pair A B} -> A`.

An instance applies the class to one target per parameter. Each target
position is either a bare type constructor, as in
`impl Convert[Nat, Bool]`, or a type constructor applied to distinct
instance parameters, as in `impl[G: Type, X: Type] Pair[G, X]`. A target may
mix the two forms, as in `impl[A: Type] Pair[A, Nat]`. A type constructor
applied to a closed argument, such as `List Nat`, is rejected with
`UnsupportedInstanceTarget`. A bare instance parameter is the wildcard form
and matches any goal argument at that position; for a single-parameter class
a bare variable target remains rejected.

<!-- doxa: fragment -->
```doxa
impl[G: Type, X: Type] Pair[G, X] {
  fun fst(x: G, y: X): G = x;
}
```

<!-- doxa: fragment -->
```doxa
impl Convert[Nat, Bool] {
  fun conv(x: Nat, y: Bool): Bool = y;
}
```

Search matches the goal's class arguments positionally against the instance's
targets. A head or argument-count mismatch at any position is not an instance.
A repeated parameter and a parameter that does not appear in the target are
rejected with `UnsupportedInstanceTarget` and a reason.

At most one instance exists per class and tuple of target heads, so a second
instance with the same tuple is rejected with `OverlappingInstances`. A goal
that matches more than one registered instance (for example, a wildcard
instance and a concrete instance at the same argument types) is reported as
`OverlappingInstances`, naming both bindings; the diagnostic points at the
class declaration. Search does not prefer the more specific instance.

### Local dictionaries

A local dictionary is an ordinary `val` binding of the dictionary type. The
class constructor `mk_<Class>` builds the value, and instance search consults
in-scope local binders before the registered instances. The binding supplies
the dictionary to a call in its scope when that call is checked against a
known result type; the example annotates the intermediate result.

<!-- doxa: fragment -->
```doxa
fun useEqb[A: Eqb](x: A, y: A): Bool = eqb x y

fun localEq(x: Nat, y: Nat): Bool = {
  val d : Eqb Nat = mk_Eqb eqbNat;
  val r : Bool = useEqb Nat x y;
  r
}
```

A local dictionary of a subclass also supplies its parent through the derived
search.

An `impl` supplies the dictionary value for one type and registers it in the
class's instance table.

<!-- doxa: fragment -->
```doxa
impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = ...;
}
```

The body elides the comparison, and `Nat` and `Bool` require declarations, so
this is a fragment.

A constrained type parameter keeps the icity of its group. Constraints are
accepted on explicit `[...]` parameters; the parser does not accept them in
`{...}` groups. Its dictionary is an implicit argument placed after the
explicit value parameters, so the class parameter is solved from them first.

```doxa
import "package:doxa_stdlib/stdlib/eqb.doxa"

fun same[A: Eqb](x: A, y: A): Bool = eqb x y
```

A call supplies the type argument explicitly, as with any `[...]` parameter,
and the dictionary is filled by instance search: `same Nat zero zero` supplies
`Nat` and resolves `Eqb[Nat]`.

A call-site dictionary is filled by matching the goal's class arguments
against the registered instances positionally, then matching each argument's
type parameters. Each constraint the instance declares is discharged
recursively at the matched type, with the depth bound decremented. A direct
instance is preferred; when none matches, the derived superclass search runs.
Search is depth-bounded at 8. A parameter that is itself class-constrained in
the local context supplies its dictionary without a search. A failed search
is an error that names the class and the target type; a failed inner
constraint names the inner class and inner type. The elaborator does not
defer the dictionary through an unsolved metavariable.

An `impl` may declare its own type parameters between `impl` and the class
reference, using the same group syntax as `fun`. A parameter group is
required when the target applies a type constructor to the instance's
parameters.

<!-- doxa: fragment -->
```doxa
impl [A: Eqb] Eqb[List A] {
  fun eqb(x: List A, y: List A): Bool = ...;
}
```

The body and `List` are elided, so this is a fragment.

For a single-parameter class, the target after the class name is either a
bare type constructor or a concrete head applied to distinct parameters from
the group. A bare variable target, a closed applied argument, a repeated
parameter, and a parameter that does not appear in the target are rejected
with `UnsupportedInstanceTarget` and a reason. The instance elaborates to a
binding with explicit binders,
`(A: Type) -> (inst: Eqb A) -> Eqb (List A)`, whose body builds the
dictionary. Method bodies elaborate with the parameters and their
dictionaries in scope. An instance method body does not see the instance
being defined; recursion is expressed through a top-level `fun`, which is
subject to the structural-recursion rule.

Search matches the registered instances at the goal's tuple of target heads,
matches the goal's arguments against the instance's target parameters
positionally, and discharges each constraint at the matched type. If more
than one direct instance matches, the search reports `OverlappingInstances`.
When no direct instance matches, the derived search described under
Superclasses runs. The result applies the instance binding to the matched
arguments and the resolved dictionaries in binder order. A failed inner
discharge reports `NoInstanceFound` for the inner class and type. A chain
longer than the depth bound reports `InstanceSearchDepthExceeded`.

Class method names are top-level projection names and share the global
namespace; two classes cannot declare the same method name.

This version does not implement default method bodies. A class method with a
body is rejected with `TypeclassUnsupported`. A missing or unknown method is
`MissingInstanceMethod` or `UnknownInstanceMethod`, an unknown class is
`UnknownTypeclass`, and a wrong class-argument count is
`TypeclassArityMismatch`.

## Documentation blocks

Every `doxa` fenced block in this document is a complete program checked by
`doxa_tooling/test/doc_blocks_test.dart`, unless the line before the fence is
`<!-- doxa: fragment -->`. A fragment uses metavariables such as `A`, `T`,
`body`, or `value`, needs an expected type, or needs surrounding context, so it
cannot be checked as a standalone program.

## Scope

This document makes no performance, metatheoretic, or compatibility claim not
represented by the current implementation or its checked examples. The sources
under `doxa/lib/src/` are authoritative for details omitted here.
