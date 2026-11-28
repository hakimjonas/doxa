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

Four infix operators stand for the standard-library operations. Each one is desugared at parse time into an application of the name it expands to, so it denotes an ordinary term: `a + b` and `plus a b` are the same term.

| Operator | Expands to | Associativity |
|---|---|---|
| `*` | `multiply` | left |
| `+` | `plus` | left |
| `<=` | `leq` | none |
| `==` | `equals` | none |

`*` binds tighter than `+`, and both bind tighter than the comparisons, which share one level. Application binds tighter than every operator, and `->` binds looser than every operator. `a + b * c` parses as `plus a (multiply b c)`, and `a * b + c` parses as `plus (multiply a b) c`. A left-associative operator groups to the left, so `a + b + c` is `plus (plus a b) c`.

The comparisons do not associate. Writing `a <= b <= c`, `a == b == c`, or `a <= b == c` is a parse error at the second operator, and the diagnostic names that operator. A parenthesized comparison is an ordinary expression, so `(a <= b) == c` parses.

Each operator expands to one name; there is no type-directed overloading. `+` expands to `plus` and to nothing else, so the algebra classes' `add` is not reachable through `+`. `*` expands to `multiply`, which is also the multiplication method on `Monoid` and `Ring`: at a use site with a `Monoid` or `Ring` dictionary in scope, `x * y` selects that class's `multiply`; otherwise it selects the top-level `Nat` operation when that name is in scope. `==` expands to `equals`, whose implicit `Eqb` dictionary argument is inserted by elaboration when `equals` resolves to the `Eqb` projection, so instance search selects the instance: `x == y` type-checks wherever an `Eqb` instance exists, including `Nat`, `Bool`, and `List Nat`.

The expansion is a plain identifier use resolved in the scope of the use site. A local binding of `plus` shadows the standard library's `plus` for `a + b` exactly as it does for `plus a b`. An operator whose expanded name is not in scope reports an unresolved name whose span is the operator itself.

`calc` endpoints and step proofs use the same expression grammar, so a chain can spell its arithmetic either way: `calc(a + b = b + a := plusComm a b)` parses and checks like `calc(plus a b = plus b a := plusComm a b)`. The `=` between a step's endpoints and the `:=` before its proof are relations, not the `==` operator.

Lambdas use `(x: A) => body` or `{x: A} => body`, and curly binders are implicit. The unannotated `(x) => body` requires an expected Pi type. Pi types use `(x: A) -> B`, `{x: A} -> B`, or `A -> B`; `A -> B -> C` associates to the right, and the non-dependent arrow has an unnamed explicit binder.

`calc` chains equalities as named steps. The form is
`calc(e1 = e2 := p1; ...; en = e(n+1) := pn)`: a parenthesised, non-empty
list of steps separated by `;`, each naming two endpoints and a proof. The
first endpoint is inferred, and its type `A` is the type of every endpoint;
each later endpoint is checked against `A`. Each proof must inhabit
`Eq A lhs rhs`, and a step's left endpoint must be the previous step's right
endpoint up to conversion. The chain elaborates to the transitivity proof
`Eq A e1 e(n+1)`, so a one-step chain is its own proof. The carrier `A` must
be a `Type`, because `Eq` takes its carrier there: a chain over propositions
is rejected as not a type. `calc` is a reserved word and a term, so it stands
where any expression can, including as an application argument and inside
`exact`.

```doxa
import "package:doxa_stdlib/stdlib/proofs.doxa"

val rotate : (a: Nat) -> (b: Nat) ->
    Eq Nat (plus (plus a b) zero) (plus b a) =
  (a: Nat) => (b: Nat) => calc(
    plus (plus a b) zero = plus a (plus b zero) := plusAssoc a b zero;
    plus a (plus b zero) = plus a b := cong ((x: Nat) => plus a x) (plusZero b);
    plus a b = plus b a := plusComm a b
  )
```

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
`auto`, `omega`, `constructor`, and `have`. A block is written
`by { step; ... }`, and `intro` takes an optional binder name. `revert x`
moves a local binder back into the goal. `have name: T = proof` elaborates
`T` and the proof in the current context, adds a binder `name: T` to the
context, and continues on the main goal in the extended context. Without the
proof, `have name: T` makes the fact a subgoal; the fact's goal is closed
before the main goal, and the fact is not in scope in its own type or proof.

`simp` normalises the goal by evaluation and rewrites it with
the equality hypotheses in context; an optional bracketed list adds
equalities, as in `simp [plusZero, plusSucc]`. `cases x` destructs a
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
`decreases (p1, ..., pn)` after a function's result type. The `decreases`
annotation is a checked lexicographic measure (see below). These are
declaration fragments because `T`, `U`, `V`, and `body` require definitions:

<!-- doxa: fragment -->
```doxa
fun f[A]{B: Type}(x: A): B = body
fun f[A: Eqb](x: A): A = body
opaque fun f(x: T): U = body
fun f(x: T): U {struct x} = body
fun f(x: T, y: U): V decreases (x, y) = body
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

A recursive call inside a `by` block is rejected with
`RecursionInTacticBlock`, because the checker does not model the tactic
context and cannot see the arguments the block would supply. The rejection
applies to every call in a block, including one that would otherwise
decrease. In a recursive function the block may also not contain `auto` or
`omega`: both apply top-level names, and a recursive member is pre-bound, so
either tactic can call the function without an expression the checker can
scan. A non-recursive `by` block is allowed, including one that uses `auto`
or `omega`.

Evaluation unfolds a recursive function only when its designated argument is a
constructor, so a recursive call on an unrefined variable stays stuck instead
of unfolding.

### Lexicographic measures

A `fun` may name a lexicographic measure instead of relying on the designated
argument:

```doxa
import "package:doxa_stdlib/stdlib/nat.doxa"

fun ack(m: Nat, n: Nat): Nat decreases (m, n) = match m {
  case zero => succ n
  case succ m_ => match n {
    case zero => ack m_ (succ zero)
    case succ n_ => ack m_ (ack m n_)
  }
}
```

`decreases (p1, ..., pn)` supplies the measure `mu(x) = (x.p1, ..., x.pn)` into
the lexicographic product of the strict sub-term orders on the named value
parameters. Every recursive call must satisfy `mu(call) <lex mu(caller)`. The
checker walks each call left to right: the first position whose argument is not
syntactically the caller's unshadowed parameter `pi` must pass a strict
sub-term of `pi`, and every earlier position must pass that same parameter. A
strict sub-term is a pattern binder from a match on `pi`, a pattern binder of a
match on such a binder (transitively), or a step binder of a data recursor
whose scrutinee is such a sub-term. An unapplied self-reference is rejected.

The measure names value parameters only. A call whose decreasing argument is an
arithmetic term such as `sub m n` is rejected, because the checker tracks
syntactic sub-terms, not arithmetic facts. A measured member may not be a
member of a mutual block, and it may not also carry `{struct name}`. A
recursive call inside a `by` block is rejected for the same reason as in the
structural rule: the checker does not model the tactic context. A measured
member is recursive by construction, so its block may not contain `auto` or
`omega` either.

Evaluation places the guard on the first named parameter: the function unfolds
only when that parameter is a constructor. A function whose first measured
parameter stays neutral therefore stays stuck instead of unfolding.

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

`match` examines an inductive value. A constructor arm introduces one binder per constructor argument; a constructor pattern is a constructor name followed by zero or more binders. `case _ => body` is a wildcard arm. Arms do not need a separator, and `returning` supplies an optional motive. A match used as an application argument must be parenthesized, as in `(match n returning T { ... }) x`.

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
argument must be parenthesized, as in `f ({ val x = y; x })`. When a block
appears where its type is known, the result expression is checked against that
type, so a check-mode form such as `mk` or a match without `returning` can be
the result.

```doxa
val block: Type 2 = { val x: Type 1 = Type; x }
```

Quotient expressions have four surface forms: `Quot(A, R)` for the type
former, `mk value` for the injection, `lift(function, compatibilityProof)`
for the elimination, and `Quot.sound proof` for the soundness proof.

`Quot(A, R)` forms a type when `A` is a type and `R` inhabits
`(x: A) -> (y: A) -> Prop`; the relation is checked, so a non-relation is
rejected at its own span. The quotient's sort is the carrier's sort: `A` at
`Type n` gives `Quot(A, R)` at `Type n`, and a carrier at `Prop` gives
`Type 1`. Quotients are never `Prop`-sorted, which is what keeps
proof-irrelevant elimination out of the construction.

`mk` injects an element. It is a check-mode form: the expected type must be
`Quot(A, R)`, and the argument is checked against `A`. Infer mode has no rule,
because the carrier and the relation come from the expected type; the
`QuotMkInInferMode` diagnostic asks for the annotation.

`lift f h` is the induced map, of type `Quot(A, R) -> B`. It is also a
check-mode form, against a function type whose domain is a quotient. With
`f : A -> B` and `R` the relation, the compatibility proof `h` must inhabit
`(x: A) -> (y: A) -> R x y -> Eq B (f x) (f y)`; a proof of any other type is
reported as `QuotFnNotRespectingRelation`. The result type `B` may not
depend on the quotient element: the elimination returns a type fixed in
advance, and a dependent codomain is rejected with
`QuotLiftNeedsConstantResult`. Infer mode has no rule
(`QuotLiftInInferMode`).

`Quot.sound h` proves `Eq (Quot A R) (mk a) (mk b)` from `h : R a b`. The
equation is propositional: `mk a` and `mk b` are definitionally equal only
when `a` and `b` are. Two injections of related but distinct elements are
equal only through `Quot.sound` and its transports, so a function that does
not respect the relation cannot be used to distinguish them. `Quot.sound`
takes its two elements from the expected equality and is a check-mode form
(`QuotSoundInInferMode`).

The elimination computes: `lift f h (mk a)` reduces to `f a`, without
consulting `h`. Applied to an element that is not a canonical injection the
term stays stuck, with the `lift` itself as the neutral head. Two `lift`s are
definitionally equal when their functions and proofs are, and two `Quot.sound`
proofs are equal by proof irrelevance because the equation is a proposition.

The carrier of a quotient and the result type of a `lift` are at `Type 0` in
this slice, because `Eq`'s carrier parameter is at `Type 0`. There is no
propositional eliminator: `Quot.ind` is not available, so a property of an
arbitrary quotient element cannot yet be proved. `lift` covers the
value-level use, and the slice is complete for building maps out of a
quotient.

```doxa
import "package:doxa_stdlib/stdlib/proofs.doxa"

data Pair: Type {
  pair: (a: Nat) -> (b: Nat) -> Pair;
}

fun sum(p: Pair): Nat = plus p.a p.b

fun sameSum(x: Pair, y: Pair): Prop = Eq Nat (sum x) (sum y)

val soundAt : (x: Pair) -> (y: Pair) -> sameSum x y ->
    Eq (Quot(Pair, sameSum)) (mk x) (mk y) =
  (x: Pair) => (y: Pair) => (h: sameSum x y) => Quot.sound h

val sumQ : Quot(Pair, sameSum) -> Nat =
  lift(sum, (x: Pair) => (y: Pair) => (h: sameSum x y) => h)

val computes : (p: Pair) -> Eq Nat (sumQ (mk p)) (sum p) =
  (p: Pair) => refl (sum p)
```

## Typeclasses

A `typeclass` declaration produces a dictionary type and one projection per
method. A projection is identified by its class and method, `Class.method`.
The dictionary type is an ordinary inductive with a single constructor and one
field for the superclass dictionary when a superclass is declared, followed by
one field per method. A class may declare more than one type parameter; the
dictionary carries all of them and each projection binds them implicitly.

```doxa
import "package:doxa_stdlib/stdlib/bool.doxa"

typeclass Eqb[A: Type] {
  fun equals(x: A, y: A): Bool;
}
```

elaborates to

```doxa
import "package:doxa_stdlib/stdlib/bool.doxa"

data Eqb[A: Type] : Type {
  mkEqb: (equals: (x: A) -> (y: A) -> Bool) -> Eqb A;
}
```

together with the projection
`Eqb.equals : {A: Type} -> (x: A) -> (y: A) -> {inst: Eqb A} -> Bool`. A
projection binds the class parameters implicitly, then the method's explicit
arguments, then the dictionary as an implicit binder after them; its body
applies the dictionary field to the explicit arguments.

### Projection names

The projection's name is `Class.method`, and the dictionary field keeps the
bare method name. A dictionary value therefore still projects with `d.multiply`.
`Class.method` is usable in a term and in a type and applies like any function.
A method inherited from a parent resolves through the class that declares it:
`Ring.add` names the `AddMonoid.add` projection.

A bare method name resolves when it selects one projection:

- Inside a class declaration, the class's own law fields resolve a bare
  method against the current class first, then its parents.
- A local dictionary, or a constrained parameter, whose class declares the
  method selects that class. The class may reach the declaring class through
  the superclass chain.
- Otherwise a top-level binding of that name selects the top-level function,
  even when exactly one class declares the method. A unique declaring class
  never overrides an explicit top-level function.
- Otherwise a unique declaring class selects the projection.
- When more than one class declares the name and neither a local dictionary nor
  a top-level binding selects one, elaboration reports `AmbiguousClassMethod`
  and names the `Class.method` forms.

`Ring`'s `multiplyAssoc` therefore reads `Ring.multiply`, and `Ring`'s
`multiplyAdd` reads `Ring.multiply` and the inherited `AddMonoid.add`.

```doxa
import "package:doxa_stdlib/stdlib/algebra.doxa"

val product : Nat = Monoid.multiply (succ zero) (succ zero)
val product_eq : Eq Nat product (succ zero) = refl product
val integerProduct : Int = Ring.multiply (pos (succ zero)) (pos (succ zero))
val integerProduct_eq : Eq Int integerProduct (pos (succ zero)) =
  refl integerProduct

fun add(x: Nat, y: Nat): Nat = plus x y

val topLevel : Nat = add (succ zero) (succ zero)
val qualified : Nat = Monoid.multiply (succ zero) (succ zero)

fun twice[A: AddMonoid](x: A): A = add x x
fun selfMultiply[A: Ring](x: A): A = multiply x x
fun starMultiply[A: Ring](x: A): A = x * x
```

### Superclasses

A class may name one superclass after its parameters. The superclass
reference is a class application over the class's own type parameters.

<!-- doxa: fragment -->
```doxa
typeclass Ord[A: Type]: Eqb[A] {
  fun compare(x: A, y: A): Bool;
}
```

elaborates the dictionary with the parent dictionary as its first field:

<!-- doxa: fragment -->
```doxa
data Ord[A: Type] : Type {
  mkOrd: (_super: Eqb A) -> (compare: (x: A) -> (y: A) -> Bool) -> Ord A;
}
```

The parent's methods remain the parent's projections, named `Eqb.equals`; `Ord`
adds only `Ord.compare`. The superclass reference must apply the parent class to
distinct class type parameters, with every class parameter appearing once. A
parent class with more than one parameter follows the same rule.

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

elaborates to `mkPair: (fst: (x: A) -> (y: B) -> A) -> Pair A B` and the
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
class constructor `mk<Class>` builds the value, and instance search consults
in-scope local binders before the registered instances. The binding supplies
the dictionary to any call in its scope, including the block's tail
expression. A local dictionary or constrained parameter of a class also
selects that class's projection for a bare method name.

<!-- doxa: fragment -->
```doxa
fun useEqb[A: Eqb](x: A, y: A): Bool = equals x y

fun localEq(x: Nat, y: Nat): Bool = {
  val d : Eqb Nat = mkEqb equalsNat;
  useEqb Nat x y
}
```

A local dictionary of a subclass also supplies its parent through the derived
search.

An `impl` supplies the dictionary value for one type and registers it in the
class's instance table.

<!-- doxa: fragment -->
```doxa
impl Eqb[Nat] {
  fun equals(x: Nat, y: Nat): Bool = ...;
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

fun same[A: Eqb](x: A, y: A): Bool = equals x y
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
  fun equals(x: List A, y: List A): Bool = ...;
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

Class method projections share the top-level namespace under their
`Class.method` names, so two classes may declare the same field name. The
dictionary constructor keeps the bare field names, and an `impl` matches its
methods to those field names. A bare method reference follows the resolution
rules under Projection names.

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
