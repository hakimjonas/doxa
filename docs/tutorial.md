# Doxa tutorial

Doxa is a dependently typed proof checker. You write functions, data types,
and proofs in a surface syntax modelled on the ML family (Standard ML, OCaml,
Scala 3). Underneath is the Calculus of Inductive Constructions with
predicative universes and an impredicative `Prop` sort. The checker runs
bidirectionally and normalises via Normalization by Evaluation. You can use
it from the command line, as a Dart library, or in the browser via WasmGC.

This tutorial walks through the language feature by feature. Every `doxa`
block is a self-contained program that type-checks. The ambient prelude
declares `Eq` (propositional equality) and `Acc` (accessibility); an example
that needs anything else declares it.

---

## 1. Getting started

Install Dart 3.7 or later. Build and run the checker:

```shell
cd doxa_tooling
dart pub get
dart run bin/doxa.dart check myfile.doxa
```

A successful run prints `OK: N declarations checked`. Errors identify the
source span and, for type mismatches, report the expected and found types.

The REPL provides interactive exploration and step-by-step proof construction:

```shell
dart run bin/doxa.dart repl       # interactive proof mode
dart run bin/doxa.dart lsp        # language server over stdio
dart run bin/doxa.dart fmt myfile.doxa
```

The language server publishes diagnostics and supports hover, go-to-definition,
references, rename, completion, document symbols, signature help, document
formatting, folding ranges, and semantic tokens. The VS Code extension starts
the server configured by `doxa.server.path`; format-on-save remains a VS Code
setting.

---

## 2. Values and functions

A function is written with `fun`, taking explicit arguments and returning a
named type. A `val` gives a name to a term:

```doxa
fun id(x: Type): Type = x

fun compose(f: Type -> Type, g: Type -> Type): Type -> Type =
  (x: Type) => f(g(x))

val zero: (A: Type) -> (A -> A) -> A -> A =
  (A: Type) => (s: A -> A) => (z: A) => z

val succ: ((A: Type) -> (A -> A) -> A -> A) -> (A: Type) -> (A -> A) -> A -> A =
  (n: (A: Type) -> (A -> A) -> A -> A) => (A: Type) => (s: A -> A) => (z: A) =>
    s(n(A)(s)(z))

val one = succ zero
```

The lambda notation `(x: T) => body` is the standard ML-family abstraction.
Function call uses juxtaposition: `f x`. Application associates left:
`f x y` means `(f x) y`. A type annotation on a `val` is optional when the
type can be inferred, but annotating top-level declarations is good
practice.

---

## 3. Data types

An inductive type declares its sort (`Type`, `Prop`, or `SProp`), optional
parameters and indices, and a semicolon-separated list of constructors. The
`Nat` and `Bool` types are examples of simple data:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Bool : Type {
  true_  : Bool;
  false_ : Bool;
}
```

Parameters go in brackets at the declaration site and at use sites. `List[A]`
is a polymorphic list:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

val empty : List[Nat] = nil
val three  : List[Nat] = cons (succ (succ zero)) (cons (succ zero) (cons zero nil))
```

Indices let the type depend on a value. `Vec` is a length-indexed vector:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
```

A length-2 vector of `Bool`s has type `Vec[Bool] (succ (succ zero))`. The
length is part of the type; functions consuming vectors can use it.

---

## 4. Pattern matching

`match` is a kernel primitive. It checks that every constructor is covered
and that each arm body type-checks against the motive:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}
```

Arms are separated by no punctuation; the `case` keyword ends the previous
arm. A wildcard `case _ => ...` catches every remaining constructor.

---

## 5. Dependent types

A Pi type `(x: A) -> B` binds `x` in `B`, so the return type can mention
the argument. The non-dependent arrow `A -> B` is sugar for `(_: A) -> B`
when `_` does not appear in `B`.

For `Nat`, the checker synthesises the dependent eliminators `Nat.ind` and
`Nat.rec`. They let you write induction proofs directly in term form:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}

fun cong{A: Type}{B: Type}{x: A}{y: A}(f: A -> B, p: Eq[A] x y): Eq[B] (f x) (f y) =
  match p { case refl a => refl (f a) }

fun idDep[A: Type](x: A): A = x

fun plusZeroRight(n: Nat): Eq[Nat] (plus n zero) n =
  Nat.ind
    ((k: Nat) => Eq[Nat] (plus k zero) k)
    (refl zero)
    ((m: Nat) => (ih: Eq[Nat] (plus m zero) m) =>
       cong ((k: Nat) => succ k) ih)
    n
```

`Nat.ind` takes a motive `P : (k: Nat) -> Type`, a base case `P zero`, and
a step case that, given `P m`, produces `P (succ m)`. `List.ind` and
`Vec.ind` follow the corresponding induction principles. The `by { ... }`
tactic in §9 builds the same recursor application from `induction n`,
with one goal per constructor; for an indexed family each goal is the
motive applied to the constructor's own indices and value.

---

## 6. Propositional equality

`Eq` is an ordinary indexed inductive declared in the prelude. When the two
sides are definitionally equal, the elaborator synthesises `refl`
automatically. The standard lemmas follow from Eq's eliminator:

```doxa
fun sym{A: Type}{x: A}{y: A}(p: Eq[A] x y): Eq[A] y x =
  match p { case refl a => refl a }

fun trans{A: Type}{x: A}{y: A}{z: A}(p: Eq[A] x y, q: Eq[A] y z): Eq[A] x z =
  Eq.rec A
    ((a: A) => (b: A) => (_: Eq[A] a b) => Eq[A] b z -> Eq[A] a z)
    x y
    ((c: A) => (h: Eq[A] c z) => h)
    p q

fun cong{A: Type}{B: Type}{x: A}{y: A}(f: A -> B, p: Eq[A] x y): Eq[B] (f x) (f y) =
  match p { case refl a => refl (f a) }
```

`Eq` lives at `Prop`, so two proofs of the same equality are definitionally
equal. The curly-brace parameters `{A: Type}` are implicit; the checker
solves them via pattern unification. Calls like `sym p` do not mention `A`,
`x`, or `y` — they are inferred from the type of `p`.

---

## 7. Implicit arguments

Curly braces introduce an implicit binder. Call sites omit the implicit
argument; the checker solves it:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun idImp{A: Type}(x: A): A = x

val example : Nat = idImp (succ zero)
```

The solver uses Miller-pattern unification to solve omitted arguments from
the surrounding type information.

---

## 8. Modules and imports

A file can import another via an `import` statement at the top level.
Paths are relative to the importing file. Cyclic imports are rejected; an
imported file is elaborated once, and importing it again from the same
pipeline is a no-op.

An import may also name a package with the `package:` scheme:

```doxa
import "package:doxa_stdlib/stdlib/nat.doxa"
```

The resolver finds the nearest `.dart_tool/package_config.json` above the
importing file, looks up the package, and resolves the path under the
package's library root (`lib/`). Declare the package in the project and run
`dart pub get` once:

```yaml
dev_dependencies:
  doxa_stdlib:
    path: ../doxa_stdlib
```

A `package:` import outside a Dart project fails with a configuration error;
the resolver does not fall back to a relative path. The standard library
sources under `doxa_stdlib/lib/stdlib/` can still be imported by relative
path.

---

## 9. Tactics

A tactic block `by { ... }` replaces a proof term with a sequence of
steps. The block follows a `val` or `theorem` declaration using `=`:

```doxa
theorem idProof : (A: Type) -> A -> A = by { intro A; intro x; exact x }

theorem sample : (A: Type) -> A -> A = by { refl | intro A; intro x; exact x }
```

Available commands: `intro name`, `exact expr`, `apply expr`, `refl`,
`rewrite proof`, `induction name`, `cases name`, `revert name`, `trivial`,
`simp [lemmas]`, `auto [depth]`, `omega`, `constructor`, and
`have name: T = proof`. The no-proof form `have name: T` leaves the fact as a
subgoal. `calc(...)` is a term rather than a step: it stands where an
expression can, including inside `exact`.
Alternatives are separated by `|`; the first alternative that closes
every goal wins.

`revert x` is the inverse of `intro`: it moves the innermost local
binder `x` back into the goal, which becomes `(x: T) -> G`. This
generalises the goal over `x` before a later step. Only the innermost
binder can be reverted; a binder with dependent binders inside it fails
with `revert: "x" is not the innermost binder; revert the binders
introduced after it first`.

Steps separated by `;` are applied to one goal each, in order. A block
starts with a single goal. When a step creates several goals
(`induction n` creates one per constructor), the following steps work
through them in constructor order, and a step that closes its goal hands
the next step the next open goal. The block succeeds only when every
goal it created is closed.

An induction proof therefore reads as one step per arm:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ k => succ (plus k n)
}

theorem plus_zero : (n: Nat) -> Eq Nat (plus n zero) n = by {
  intro n;
  induction n;
  refl;
  rewrite ih;
  refl
}
```

`induction` names each constructor's arguments from the data declaration
(`a`, `a2`, ... where the declaration has no name) and names the
induction hypotheses `ih`, `ih2`, ... in recursive-argument order. The
names are in scope for the following steps, so the `succ` arm above can
`rewrite ih`.

### Simplifying

`simp [lemmas]` normalises the goal by evaluation and rewrites it with
equality lemmas until no rule applies. With no list, every equality-typed
hypothesis in the local context is a rule; a bracketed list adds the named
equalities. A rule may be Pi-typed: its binders are instantiated with
metavariables and its conclusion is matched against subterms of the goal.
The goal closes by `refl` when the two sides become convertible. When a
rewrite applies and the goal remains, `simp` leaves the rewritten goal for
the next step. When nothing applies and `refl` fails, it reports
`simp: no progress`.

The loop is bounded. After 100 rewrites, or when a normalised goal repeats,
`simp` fails with `simp: rewrite limit exceeded` and names the last rule
applied. It never returns a partially rewritten goal as if the proof were
complete.

Every equality hypothesis in context is a rule. Keep one out of the rewrite
set by introducing it after `simp` runs, or by `revert`ing it first. The
following proof uses `plus_zero` and `plus_succ` from the standard library:

```doxa
import "package:doxa_stdlib/stdlib/proofs.doxa"

val plus_nested : (m: Nat) -> (n: Nat) ->
    Eq Nat (plus (plus m (succ n)) zero) (succ (plus m n)) = by {
  intro m;
  intro n;
  simp [plus_zero, plus_succ]
}
```

`plus_zero` removes the outer `zero`, exposing the left side of `plus_succ`,
and the second rewrite makes the sides convertible.

### Case analysis and constructors

`cases x` splits a variable of inductive type into one goal per
constructor, with the constructor's arguments in scope and named as
`induction` names them. Unlike `induction`, no usable hypothesis is
added; a recursive constructor still carries the recursor's hypothesis
binder, which the display shows as `_` and the arm goal does not mention:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ k => succ (plus k n)
}

val two_cases : (n: Nat) -> Eq Nat (plus zero n) n = by {
  intro n;
  cases n;
  refl;
  refl
}
```

`constructor` applies the first constructor whose result type matches the
goal. A nullary constructor closes the goal; any other constructor leaves
one goal per argument, in argument order. An argument type that mentions a
local variable is a goal over that variable, so the proof may name it:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data D: Nat -> Type {
  d0: D zero;
  d1: (n: Nat) -> D n -> D (succ n);
}

val d_succ : (n: Nat) -> D n -> D (succ n) = by {
  intro n;
  intro p;
  constructor;
  exact p
}
```

### Search tactics

`auto [depth]` tries `refl`, then `trivial`, then applications of the
top-level names in scope, recursively to `depth` levels (default 5, accepted
range 0 to 20). The search is bounded, so a larger depth costs more time and
still does not guarantee a proof.

`omega` normalises both sides of an equality and tries the arithmetic
lemmas in scope (`plus_zero`, `plus_succ`, `plus_comm`, and related
lemmas). It is a convenience for goals those lemmas close, not a decision
procedure; when none applies it reports
`omega: could not solve the arithmetic goal`.

For an indexed family the arm's goal comes from the recursor's motive:
each method goal is the motive applied to the constructor's own result
indices and value, which is definitionally the method type the recursor
demands. Symmetry of equality is then one `refl` step:

```doxa
theorem eq_sym : (A: Type) -> (x: A) -> (y: A) -> Eq[A] x y -> Eq[A] y x = by {
  intro A;
  intro x;
  intro y;
  intro h;
  induction h;
  refl
}
```

The `refl` arm's goal is `Eq[A] a a` for the constructor argument `a`,
not the unrefined `Eq[A] y x`.

Building the arm from the motive also covers a scrutinee whose index is a
compound term that does not unify with a constructor's index. With
`v : Vec[A] (succ n)`, induction still produces a `vnil` arm, and its
goal is the recursor's `P zero vnil`, that is `Eq[Nat] zero zero`, not the
unreachable `Eq[Nat] zero (succ n)`:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}

fun vlength{A: Type, n: Nat}(v: Vec[A] n): Nat = match v {
  case vnil => zero
  case vcons _ _ rest => succ (vlength rest)
}

theorem vlength_succ : (A: Type) -> (n: Nat) -> (v: Vec[A] (succ n)) ->
    Eq[Nat] (vlength v) (succ n) = by {
  intro A;
  intro n;
  intro v;
  induction v;
  refl;
  rewrite ih;
  refl
}
```

The `vcons` hypothesis is `Eq[Nat] (vlength rest) n`: the motive at the
recursive argument's own index `n`, not at the scrutinee's `succ n`. So
`rewrite ih` leaves `Eq[Nat] (succ n) (succ n)`, which `refl` closes.

The expressions in `exact`, `apply`, and `rewrite` elaborate in the
tactic's local context: local binders carry their real types, and
implicit arguments are inserted as at any other application site. So
`exact (cong f ih)` works with `f` and `ih` introduced earlier.

`apply lemma` creates one goal per *explicit* argument of `lemma`, in
argument order, before any older pending goal. Implicit arguments are
filled by conversion and never become goals. When the goal's type
constrains an explicit argument, that argument is solved during
`apply`; only the remaining ones appear.

### Named steps and chains

`have name: T = proof` adds a local fact. The type and the proof elaborate
in the current context, the fact joins the goal's context under `name`, and
the main goal continues. Omitting the proof leaves the fact as a subgoal;
that subgoal comes first, and the fact is in scope only after it is closed.

```doxa
import "package:doxa_stdlib/stdlib/proofs.doxa"

theorem add_zero_step : (a: Nat) -> Eq Nat (plus a zero) a = by {
  intro a;
  have z : Eq Nat (plus a zero) a;
  exact plus_zero a;
  exact z
}
```

`calc` chains equalities into one proof. Each step names two endpoints and a
proof; the first endpoint's type fixes the carrier, every other endpoint is
checked against it, and consecutive steps must meet. A two-step chain over
the arithmetic lemmas reads as the two rewrites it performs:

```doxa
import "package:doxa_stdlib/stdlib/proofs.doxa"

val assoc_chain : (a: Nat) -> (b: Nat) ->
    Eq Nat (plus (plus a b) zero) (plus a b) =
  (a: Nat) => (b: Nat) => calc(
    plus (plus a b) zero = plus a (plus b zero) := plus_assoc a b zero;
    plus a (plus b zero) = plus a b := cong ((x: Nat) => plus a x) (plus_zero b)
  )
```

The chain elaborates to the transitivity proof `Eq Nat (plus (plus a b) zero)
(plus a b)`, so the example closes the goal without an intermediate `have`. A
single-step chain is its own proof. `calc` is a term, so it also stands inside
`exact` and as an application argument.

---

## 9b. Interactive proof mode

The REPL (`doxa repl`) supports step-by-step proof construction.
Start a proof, apply tactics one at a time, inspect the goal, undo
mistakes, and commit the result.

### Starting a proof

```
> :goal theorem idProof : (A: Type) -> A -> A
Goal:
  (A: Type) -> A -> A
```

### Applying tactics

```
> :step intro A
Introduced A.
Goal:
  ?a -> ?a
Context:
  A : Type

> :step intro x
Introduced x.
Goal:
  ?a
Context:
  x : ?a
  A : Type

> :step exact x
Goal solved. Use :qed to commit.
```

### Induction

`:step induction n` splits the goal into one goal per constructor. For
the `plus_zero` theorem from §9, after `:step intro n`:

```
> :step induction n
Induction applied.
Goal:
  Eq Nat zero zero
Context:
  n : Nat

> :step refl
Goal:
  Eq Nat (succ (plus a zero)) (succ a)
Context:
  ih : Eq Nat (plus a zero) a
  a : Nat
  n : Nat
```

A step that closes an arm moves to the next one, with the constructor's
arguments and induction hypotheses named in the context.

For an indexed scrutinee the arm's goal is the motive applied to the
constructor's result indices, so it is the recursor's method goal. With
`h : Eq A x y`, `:step induction h` shows the `refl` arm's goal as
`Eq A a a` for its constructor argument `a`, not `Eq A y x`. A compound
scrutinee index gives the same treatment: inducting on
`v : Vec A (succ n)` shows the `vnil` arm's goal as `Eq Nat zero zero`.

`:step cases x` walks one goal per constructor in constructor order, with
the constructor's arguments named in the context; `:goal` shows the current
arm. A recursive constructor also shows the recursor's hypothesis binder
as `_`, which the arm goal does not mention. `:step constructor` leaves one
goal per argument of the constructor it picked, again in argument order; a
nullary constructor closes the goal immediately, and the next `:step`
targets the first open goal.

### Reverting a binder

`:step revert x` moves the innermost binder back into the goal. The
inverse of `:step intro`, it generalises the goal over `x` before a
later step:

```
> :step intro A
Introduced A.
Goal:
  (x: A) -> Eq A x x
Context:
  A : Type

> :step intro x
Introduced x.
Goal:
  Eq A x x
Context:
  x : A
  A : Type

> :step revert x
Reverted x.
Goal:
  (x: A) -> Eq A x x
Context:
  A : Type
```

Only the innermost binder can be reverted. Reverting a binder that has
dependent binders inside it reports `revert: "x" is not the innermost
binder; revert the binders introduced after it first`.

### Applying a lemma

`:step apply lemma` shows one goal per explicit argument, in argument
order. Closing the first makes the next argument current. Implicit
arguments are filled by conversion and are not shown. With
`two_nats : (a: Nat) -> (b: Nat) -> Nat` in scope:

```
> :step apply two_nats
Goal:
  Nat

> :step exact zero
Goal:
  Nat
```

`rewrite ih` and `exact ih` can refer to the hypothesis by name. `:undo`
restores the whole goal queue, so it also steps back from a later arm to
an earlier one.

### Simplifying

`:step simp` normalises the goal and rewrites with the context's equality
hypotheses. A bracketed list adds lemmas, as in `:step simp [plus_zero]`.
A partial simplification displays the residual goal, so the next step can
finish it:

```
> :step simp [h]
Simplified.
Goal:
  Eq A (f y) (g y)
Context:
  h : Eq A x y
  ...
```

`:step simpl` is kept as an alias for `:step simp` with no list.

### Inspecting and undoing

```
> :print
(A: Type) => (x: A) => x

> :undo
Undone.
Goal:
  ?a
Context:
  x : ?a
  A : Type
```

### Inspecting types and normal forms

`:type` shows the type of an expression, and `:norm` shows its normal form.
Both insert implicit arguments. With `Nat` from §3 and
`id2{A: Type}(x: A): A = x` in scope:

```
> :type id2 zero
Nat

> :norm id2 zero
zero

> :type refl zero
Eq Nat zero zero
```

### Finishing

```
> :step exact x
Goal solved. Use :qed to commit.

> :qed
idProof : (A: Type) -> A -> A
```

### Commands

| Command | Action |
|---------|--------|
| `:goal theorem n : T` | Start an interactive proof |
| `:goal` (in proof)    | Show current goal and context |
| `:step intro [name]`  | Introduce a Pi binder |
| `:step exact e`       | Provide an explicit proof term |
| `:step apply f`       | Apply a lemma, creating subgoals for arguments |
| `:step refl`          | Close `Eq[A] x x` goals |
| `:step rewrite p`     | Rewrite using an equality proof `p` |
| `:step induction v`   | Inductive case split on variable `v` |
| `:step revert v`      | Move the innermost binder `v` back into the goal |
| `:step constructor`   | Apply the first matching constructor; parameterised arguments become goals |
| `:step cases v`       | Case analysis on `v`; no induction hypotheses, hidden `_` recursor binder |
| `:step simp [lemmas]` | Normalise and rewrite with equality hypotheses |
| `:step simpl`         | Alias for `:step simp` |
| `:step trivial`       | Try refl, then context lookup |
| `:step auto [depth]`  | Depth-bounded proof search (default 5, range 0 to 20) |
| `:step omega`         | Bounded arithmetic convenience for `Nat` goals |
| `:step have name: T [= p]` | Add a local fact; without the proof, the fact becomes a subgoal |
| `:undo`               | Revert the last step |
| `:print`              | Show the proof term so far |
| `:abort`              | Abandon the proof |
| `:qed`                | Commit the proof and add it to scope |
| `:browse`             | List all names in scope with types |
| `:search <pattern>`   | Search scope by name or type substring |

---

## 10. Records and field projection

Write a record in product form, with named fields rather than constructor
declarations. The parser desugars the declaration to a single-constructor
inductive named `mk`; field access uses dot notation:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Box[A: Type] : Type {
  value : A;
}

val boxed : Box[Nat] = Box.mk (succ zero)
val unboxed : Nat = boxed.value
```

Every field projects. With two fields, both `p.x` and `p.y` check:

```doxa
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Point : Type { x : Nat; y : Nat; }
val p : Point = Point.mk zero (succ zero)
val first : Nat = p.x
val second : Nat = p.y
```

A module declares at most one product-form record: every product-form
declaration desugars to `mk`, and a second `mk` is a duplicate declaration.
Declare additional records with named constructor arguments, as in
`data Segment: Type { seg: (start: Point) -> (end: Point) -> Segment; }`;
`Segment.seg` projects through `start` and `end`.

Record types support definitional eta: a record converts to the constructor
applied to its projections. Field projection via dot notation is available
for a non-indexed data type with one constructor.

---

## 11. Typeclasses

A `typeclass` declaration produces a dictionary type and one projection per
method. A class may declare more than one method; each method becomes a
projection and a dictionary field. An `impl` declaration produces a dictionary
value for a head type, optionally applied to the instance's own type
parameters. Resolution happens during elaboration: a constrained parameter
becomes an implicit dictionary parameter, and a method call inserts the
dictionary it needs.

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Bool : Type {
  true_ : Bool;
  false_ : Bool;
}

typeclass Eqb[A: Type] {
  fun eqb(x: A, y: A): Bool;
}

impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = match x {
    case zero => true_
    case succ n => false_
  };
}

impl Eqb[Bool] {
  fun eqb(x: Bool, y: Bool): Bool = match x {
    case true_ => y
    case false_ => false_
  };
}

fun same[A: Eqb](x: A, y: A): Bool = eqb x y

val natSame : Bool = same Nat zero zero
val boolSame : Bool = same Bool true_ true_
```

`typeclass Eqb[A: Type]` produces the dictionary type `Eqb[A]`, a
single-constructor inductive with one field per method, and the projection
`eqb`. `impl Eqb[Nat]` registers one instance for the head `Nat`. A second
instance for the same class and head is rejected with
`OverlappingInstances`.

`[A: Eqb]` is an explicit type parameter with a constraint. The dictionary
is an implicit argument placed after the value parameters, so the class
parameter is solved from them first. The call `same Nat zero zero` supplies
`Nat` and resolves `Eqb[Nat]` by search. Inside `same`, `eqb x y` uses the
dictionary parameter directly, so no search runs there.

### Parameterised instances

An instance can target a type constructor applied to its own parameters. A
parameter group between `impl` and the class reference declares those
parameters, using the same bracket and constraint syntax as `fun`. The block
repeats the class and the `Nat` instance so it is self-contained.

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Bool : Type {
  true_ : Bool;
  false_ : Bool;
}

typeclass Eqb[A: Type] {
  fun eqb(x: A, y: A): Bool;
}

impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = match x {
    case zero => true_
    case succ n => false_
  };
}

data List[A: Type] : Type {
  nil : List A;
  cons : A -> List A -> List A;
}

fun andb(a: Bool, b: Bool): Bool = match a {
  case true_ => b
  case false_ => false_
}

fun eqbList[A: Eqb](xs: List A, ys: List A): Bool {struct xs} = match xs {
  case nil => match ys {
    case nil => true_
    case cons _ _ => false_
  }
  case cons h t => match ys {
    case nil => false_
    case cons h2 t2 => andb (eqb h h2) (eqbList A t t2)
  }
}

impl[A: Eqb] Eqb[List A] {
  fun eqb(x: List A, y: List A): Bool = eqbList A x y;
}

val listSame : Bool = eqb (cons zero nil) (cons zero nil)
```

`impl[A: Eqb] Eqb[List A]` elaborates to a binding
`(A: Type) -> (inst: Eqb A) -> Eqb (List A)` with explicit binders. The
method body runs with `A` and `inst` in scope. The call `eqbList A x y`
passes `inst` as the helper's `Eqb A` dictionary, so `eqb h h2` in the helper
compares elements through `inst`.

An instance method body does not see the instance being defined, so the
recursive comparison is a top-level `fun`; the structural-recursion check
applies to `eqbList`, whose tail call `eqbList A t t2` passes a strict
sub-term. The checker counts the explicit type argument before comparing the
designated value position.

The standard library ships the class and instances for `Nat`, `Bool`, and
`List`. Importing the domain package brings them into scope:

```doxa
import "package:doxa_stdlib/stdlib/Eqb/package.doxa"

val natSame : Bool = eqb zero zero
val listSame : Bool = eqb (cons zero nil) (cons zero nil)
```

Search for a goal `C T` takes the head of `T`, selects the instance
registered at that head, and matches the arguments of `T` against the
instance's target parameters positionally. Each constraint is discharged at
the matched type with the depth counter decremented. At `List (List Nat)`,
search uses the List instance twice and reaches the `Eqb Nat` instance.

A failed inner discharge names the inner class and type. With no `Eqb Bool`,
`eqb` at `List Bool` reports `NoInstanceFound` for `Eqb` at `Bool`, not for
`List Bool`.

### Superclasses

A class can embed a parent dictionary. `typeclass Ord[A]: Eqb[A]` adds the
`Eqb[A]` dictionary as the first field of every `Ord` dictionary. An instance
of `Ord` resolves the parent at registration. A constraint `[A: Ord]` supplies
an `Ord` dictionary, and a call that needs `Eqb A` projects the parent from
it.

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Bool : Type {
  true_ : Bool;
  false_ : Bool;
}

typeclass Eqb[A: Type] {
  fun eqb(x: A, y: A): Bool;
}

typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}

fun eqbNat(x: Nat, y: Nat): Bool = match x {
  case zero => match y {
    case zero => true_
    case succ _ => false_
  }
  case succ n => match y {
    case zero => false_
    case succ m => eqbNat n m
  }
}

impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = eqbNat x y;
}

impl Ord[Nat] {
  fun cmp(x: Nat, y: Nat): Bool = eqbNat x y;
}

fun eqViaOrd[A: Ord](x: A, y: A): Bool = eqb x y

val throughParent : Bool = eqViaOrd Nat zero zero
```

The parent's methods stay the parent's projections. `Ord` adds only `cmp`.
Search prefers a direct instance; when none matches, it searches a direct
subclass and projects the embedded parent dictionary. Two subclasses
providing the same parent report `OverlappingInstances`.

### Two type parameters

A class may take more than one type parameter. The dictionary carries both,
and the projection binds both implicitly.

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Bool : Type {
  true_ : Bool;
  false_ : Bool;
}

typeclass Pair[A: Type, B: Type] {
  fun fst(x: A, y: B): A;
  fun snd(x: A, y: B): B;
}

impl Pair[Nat, Bool] {
  fun fst(x: Nat, y: Bool): Nat = x;
  fun snd(x: Nat, y: Bool): Bool = y;
}

val first : Nat = fst zero true_
val second : Bool = snd zero true_
```

Search matches both class arguments positionally. A mismatch at either
position is not an instance, so a `Pair[Nat, Nat]` goal does not select the
`Pair[Nat, Bool]` instance. A generic instance can leave each class argument
as a bare parameter, as in `impl[G: Type, X: Type] Pair[G, X]`.

This slice has these limits:

- A superclass reference must apply the parent class to distinct class type
  parameters, with each class parameter appearing once. A repeated or missing
  parameter is rejected with `TypeclassUnsupported`.
- Local dictionaries are ordinary `val` bindings of the dictionary type, not
  a separate instance declaration. The binding supplies the dictionary to a
  call in its scope when the call is checked against a known result type.
- Coherence is global: one instance per class and tuple of target heads.
- Method names share the global namespace, because each method becomes a
  top-level projection. Two classes cannot declare the same method name; the
  second declaration is rejected with `DuplicateDeclaration`.
- Method default bodies are not implemented. Every instance supplies every
  method, and a missing method is rejected with `MissingInstanceMethod`.
- For a single-parameter class, a target is a bare type constructor or a type
  constructor applied to distinct instance parameters. For a multi-parameter
  class, each target position is one of those two forms and the positions may
  mix; a bare instance parameter is the wildcard form. A bare variable target
  for a single-parameter class, such as `impl[A: Eqb] Eqb[A]`, is rejected
  with `UnsupportedInstanceTarget` because search cannot make progress.
- Closed applied target arguments are rejected. `impl Eqb[List Nat]` reports
  `UnsupportedInstanceTarget`; a parameterised instance covers the same
  ground.
- Target arguments must be distinct. `impl[A: Eqb] Eqb[Pair A A]` is rejected
  because matching would need consistency checking.
- Search prefers a direct instance, then derives a parent from a direct
  subclass. A goal with more than one matching instance is reported as
  `OverlappingInstances`; search is depth-bounded at 8. A miss is reported
  with `NoInstanceFound`, naming the class and type. A chain past the bound is
  reported with `InstanceSearchDepthExceeded`.

### The algebra library

The standard library ships monoids and commutative monoids.
`AddCommMonoid` and `CommMonoid` embed their monoid as a superclass
dictionary, so an `AddCommMonoid` dictionary also supplies `AddMonoid`.
`sum` folds a list with `add` and `azero`, and `sumViaComm` takes the
commutative constraint:

```doxa
import "package:doxa_stdlib/stdlib/algebra.doxa"

val two : Nat = sum Nat (cons (succ zero) (cons (succ zero) nil))
val two_eq : Eq Nat two (succ (succ zero)) = refl two
val viaComm : Nat = sumViaComm Nat (cons (succ zero) (cons (succ zero) nil))
val viaComm_eq : Eq Nat viaComm (succ (succ zero)) = refl viaComm
```

Both folds reduce the two-element list to `succ (succ zero)`, so `refl`
proves both equations. The explicit `Nat` supplies the class parameter, and
the dictionary comes from the `AddMonoid Nat` and `AddCommMonoid Nat`
instances by search. `sumViaComm` reaches `AddMonoid` through the
`AddCommMonoid` dictionary's parent field.

A class that is not passed as a constraint can still be used as an ordinary
record type. A user-defined record is an explicit dictionary:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Default[A: Type] : Type {
  default : A;
}

val natDefault : Default[Nat] = Default.mk zero
```

---

## 12. Quotient types

The type former `Quot(A, R)` remains available:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val R : Nat -> Nat -> Prop = (x: Nat) => (y: Nat) => Eq[Nat] x y
val Q : Type = Quot(Nat, R)
```

The surface operations `mk` and `lift` are rejected with
`QuotientUnsupported`. The elaborator does not check the proof that a
lifted function respects `R`, so the surface does not offer the
elimination rule. Use a data type, or encode the quotient with a
setoid-style relation and transport lemmas, until the lift proof is
checked.

---

## 13. SProp and proof irrelevance

`SProp` is a strict-Proposition sort. All values in `SProp` are
definitionally equal:

```doxa
data STrue : SProp {
  strue : STrue;
}

val p : STrue = strue
val q : STrue = strue
// p == q definitionally.
```

SProp-inductive fields must themselves be SProp-sorted. This prevents
information smuggling through the proof-irrelevant channel.

---

## 14. Strict positivity and structural recursion

Every constructor must use its own inductive type strictly positively.
Self-references may appear on the right of arrows but not on the left:

```doxa
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

data Tree : Type {
  leaf : Tree;
  node : List[Tree] -> Tree;
}
```

A constructor like `bad : (Tree -> Tree) -> Tree` would be rejected because
`Tree` appears in a negative position (left of an arrow).

Every recursive function must pass a strict sub-term of a designated
decreasing argument. The check runs at elaboration time. For mutual
recursion, every member of a `fun ... and ...` block must decrease on the
same argument across all mutual calls.

---

## 15. Propositional-level reasoning

Proofs that derive a contradiction from an impossible equality use the
empty type `False` (zero constructors):

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data False : Prop { }

fun isZero(n: Nat): Prop = match n {
  case zero => Eq[Nat] zero zero
  case succ k => False
}

val succNeZero : (n: Nat) -> Eq[Nat] (succ n) zero -> False =
  (n: Nat) => (p: Eq[Nat] (succ n) zero) =>
    Eq.rec Nat
      ((a: Nat) => (b: Nat) => (_: Eq[Nat] a b) => isZero b -> isZero a)
      (succ n) zero
      ((z: Nat) => (h: isZero z) => h)
      p (refl zero)
```

Together with `cong`, `sym`, and `trans`, the J eliminator `Eq.rec` gives
the standard Martin-Löf identity type. Because `Eq` is K-free, uniqueness
of identity proofs is not derivable, and it is not even statable since
`Eq[A] x y` lives at `Prop` while `Eq` requires a `Type`-sorted carrier.

---

## 16. Next steps

- The [language specification](../SPEC.md) gives the full formal semantics.
- The [standard library sources](../doxa_stdlib/lib/stdlib/) contain `Nat`, `List`,
  `Vec`, `Bool`, `Option`, and the `Eq` lemmas.
- The [proof example](../example/proofs.doxa) proves `plus_zero_left`,
  `plus_zero_right`, `length_append`, `succ_ne_zero`, and `vlength_index`.
- The [interactive proof mode](#9b-interactive-proof-mode) lets you
  construct proofs step by step in the REPL.
