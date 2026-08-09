# Doxa Tutorial

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
dart run doxa check myfile.doxa
```

A successful run prints `OK: N declarations checked`. Errors print a source
span, the inferred type, the expected type, and the innermost point where
conversion failed.

The REPL provides interactive exploration and step-by-step proof construction:

```shell
dart run doxa repl       # interactive proof mode
dart run doxa lsp        # language server for VS Code / Vim / Emacs
doxa fmt myfile.doxa     # format to canonical style
```

The LSP provides diagnostics, hover, go-to-definition, completion (with types
and frequency ranking), document symbols, signature help, code lens (inline
declaration types), and format-on-save.

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

Constructor names are globally unique. Parameters go in brackets at the
declaration site and at use sites. `List[A]` is a polymorphic list:

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

The dependent eliminators `T.ind` and `T.rec` are auto-synthesised for
every `data` declaration. They let you write induction proofs directly:

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
a step case that given `P m` produces `P (succ m)`. The same pattern works
for `List.ind`, `Vec.ind`, and every other inductive type.

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
    ((c: A) => (h: Eq[A] c z) => h)
    x y p q

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

The solver uses Miller's pattern unification fragment. When it cannot find
a unique solution, it emits an error asking for an explicit argument. Doxa
never silently guesses.

---

## 8. Modules and imports

A file can import another via an `import` statement at the top level.
Paths are relative to the importing file. Cyclic imports are rejected; an
imported file is elaborated once, and importing it again from the same
pipeline is a no-op. The standard library files under `lib/stdlib/` are
imported this way.

---

## 9. Tactics

A tactic block `by { ... }` replaces a proof term with a sequence of
steps. The block follows a `val` or `theorem` declaration using `=`:

```doxa
theorem idProof : (A: Type) -> A -> A = by { intro A; intro x; exact x }

theorem sample : (A: Type) -> A -> A = by { refl | intro A; intro x; exact x }
```

Available commands: `intro name`, `exact expr`, `apply expr`, `refl`,
`induction name`, `trivial`. Alternatives are separated by `|`; the first
successful alternative wins.

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
  A -> A
Context:
  A : Type

> :step intro x
Introduced x.
Goal:
  A
Context:
  x : A
  A : Type

> :step exact x
Goal solved. Use :qed to commit.
```

### Inspecting and undoing

```
> :print
(lambda) (A: Type) => (lambda) (x: A) => x

> :undo
Undone.
Goal:
  A
Context:
  x : A
  A : Type
```

### Finishing

```
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
| `:step constructor`   | Apply the first matching constructor |
| `:step cases v`       | Case analysis on variable `v` (no IHs) |
| `:step simpl`         | Normalise the goal |
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

Records are a single-constructor inductive with named fields. The `mk`
constructor is synthesised; field access uses dot notation:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Bool : Type {
  true_  : Bool;
  false_ : Bool;
}

data Pair[A: Type, B: Type]: Type {
  pair : A -> B -> Pair[A] B;
}

val p : Pair[Nat] Bool = pair (succ zero) true_
```

Record types support definitional η: a pair converts to the pair of its
projections. Field projection via dot notation is available when a data
type has a single constructor.

---

## 11. Typeclasses (experimental)

Typeclasses are an emerging feature. A `typeclass` declares a class with
named methods; `impl` provides instances:

```
// Syntax (in progress):
//   typeclass Eq[A] { fun equals(x: A, y: A): Type; }
//   impl Eq[Nat] { fun equals(x: Nat, y: Nat): Type = Type; }
```

Functions can constrain type parameters with class requirements using
`[A: ClassName]`. The checker searches registered instances when an
implicit argument has a class constraint. Overlapping instances are
rejected.

---

## 12. Quotient types

`Quot(A, R)` declares the quotient of a carrier type `A` by a relation
`R : A -> A -> Prop`. Elements are injected with `mk` and functions are
lifted with `lift(f, proof)`:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val R : Nat -> Nat -> Prop = (x: Nat) => (y: Nat) => Eq[Nat] x y
val Q : Type = Quot(Nat, R)
```

A `lift(f, proof)` requires a proof that `f` respects `R`. The ι-rule
reduces `lift(f, p)(mk a)` to `f(a)`.

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
      ((z: Nat) => (h: isZero z) => h)
      (succ n) zero p (refl zero)
```

Together with `cong`, `sym`, and `trans`, the J eliminator `Eq.rec` gives
the standard Martin-Löf identity type. Because `Eq` is K-free, uniqueness
of identity proofs is not derivable, and it is not even statable since
`Eq[A] x y` lives at `Prop` while `Eq` requires a `Type`-sorted carrier.

---

## 16. Next steps

- The [language specification](../SPEC.md) gives the full formal semantics.
- The [standard library sources](../lib/stdlib/) contain `Nat`, `List`,
  `Vec`, `Bool`, `Option`, and the `Eq` lemmas.
- The [proof examples](../example/proofs.doxa) include `plus_comm`,
  `append_assoc`, `map_compose`, `succ_ne_zero`, `true_ne_false`, and a
  theorem about indexed vectors.
- The [SPEC coverage document](SPEC_COVERAGE.md) enumerates every clause of
  the specification and its corresponding test.
- The [proof guide](proof-guide.md) walks through a complete proof that
  sqrt(2) is irrational, using induction on natural numbers.
- The [interactive proof mode](#9b-interactive-proof-mode) lets you
  construct proofs step by step in the REPL.
