# Doxa tutorial

Doxa is a dependently typed proof checker. You write functions, data types,
and proofs in a surface syntax modelled on the ML family (Standard ML, OCaml,
Scala 3). Underneath is the Calculus of Inductive Constructions with
predicative universes and an impredicative `Prop` sort. The checker runs
bidirectionally and normalises via Normalization by Evaluation. You can use
it from the command line, as a Dart library, or in the browser via WasmGC.

This tutorial walks through the language feature by feature. Every code
block is a self-contained Doxa program that type-checks. The only ambient
name is `Eq` (propositional equality), declared in the prelude.

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

An inductive type declares its sort (`Type` or `Prop`), optional parameters
and indices, and a semicolon-separated list of constructors. The `Nat`
and `Bool` types are examples of simple data:

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
`induction name`, `revert name`, `rewrite proof`, `simp [lemmas]`, `trivial`.
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
arguments are filled by conversion and are not shown.

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
| `:step constructor`   | Apply the first matching constructor |
| `:step cases v`       | Case analysis on variable `v` (no IHs) |
| `:step simp [lemmas]` | Normalise and rewrite with equality hypotheses |
| `:step simpl`         | Alias for `:step simp` |
| `:step trivial`       | Try refl, then context lookup |
| `:step auto [depth]`  | Depth-bounded proof search (default depth 5) |
| `:step omega`         | Arithmetic solver for `Nat` goals |
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

Record types support definitional eta: a record converts to the constructor
applied to its projections. Field projection via dot notation is available
for a non-indexed data type with one constructor.

---

## 11. Typeclasses

The `typeclass` and `impl` declarations are rejected with
`TypeclassUnsupported`:

```doxa
typeclass Default[A: Type] {
  fun default(): A;
}

impl Default[Nat] {
  fun default(): Nat = zero;
}
```

The parser and formatter accept this syntax, but the elaborator stops
before adding either declaration to scope. The resolver does not thread
class dictionaries, search instances recursively, or project methods.

Use a record type with explicit dictionary arguments, or a plain data
type:

```doxa
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
