# Doxa Syntax Reference

**Purpose**: Fast lookup of every surface-syntax form Doxa accepts, plus the decisions behind its notational choices. For the semantics behind each form, see `SPEC.md`.

---

## Aesthetic target

Doxa is **math-voice with developer ergonomics**. It is a proof checker in the CIC tradition, so its notation sits in that tradition (`->` for function types, juxtaposition for application, `data` for inductive declarations). It is also designed to be read by programmers, so it adopts developer-voice choices wherever the semantics allow (`fun` keyword, brace blocks, `[A]` for type parameters at declaration, `match { case p => e }` for pattern matching).

The two targets are in tension only at specific points; each tension is resolved by a principled choice:

- **Application is juxtaposition** (`f a b`), not `f(a, b)`. Doxa is natively curried (CIC requires it), so juxtaposition is the ergonomic default, and partial application `f a` reads uniformly.
- **Dependent function types** use `(x: A) -> B x`, following CIC tradition (Agda, Coq, Lean, Idris). The dependent Pi is Doxa's load-bearing distinction from a non-dependent language.
- **Inductive declarations** use `data T[A: Type] : Indices -> Sort { ctor : Type; ... }` rather than a `type T = A | B` sum form, because Doxa needs parameters, indices, sorts, and a positivity check.

Statement boundaries are keyword-delimited, so the grammar is unambiguous; newlines are treated as ordinary whitespace by the parser.

---

## Declarations

### Value binding

```doxa
val x : T = expr
val y = expr              // type inferred
```

### Type alias

```doxa
type Nat = (A: Type) -> (A -> A) -> A -> A
```

Types and terms share syntax; `type` is a top-level alias declaration for readability.

### Function declaration (sugar)

```doxa
fun id[A: Type](x: A): A = x

fun compose[A: Type, B: Type, C: Type](f: B -> C, g: A -> B): A -> C =
  (x) => f (g x)
```

`fun` desugars to a `val` whose type is a Pi and whose body is nested lambdas. See SPEC §5.2.

Parameters in square brackets (`[A: Type]`) are explicit: the caller passes them. Parameters in curly brackets (`{A: Type}`) are implicit: the caller omits them and the checker solves for them by pattern unification. So `fun map{A: Type}{B: Type}(xs: List[A], f: A -> B): List[B]` is called as `map xs f`, with `A` and `B` recovered from the arguments.

### Mutual function block

```doxa
fun even(n: Nat): Bool = /* ... */
and fun odd(n: Nat): Bool = /* ... */
```

Both names are in scope during each body's elaboration. Recursive calls are admitted when they pass the structural-recursion check (a call must pass a strict sub-term of the designated decreasing argument).

### Inductive type

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
```

- **`[A: Type]` at declaration**: parameter telescope. Optional.
- **`: Indices -> Sort`**: the type of the type. A parametric-only family (`List`) has no indices and just names the sort (`: Type`). An indexed family (`Vec`) has indices written as arrow domains before the sort (`: Nat -> Type`).
- **Constructor declarations**: each is `name : type;`. The type may mention the inductive type being declared, subject to the strict-positivity check.
- **`List[A]`, `Vec[A] n`**: type-level application at use sites. See below.

### Block expressions (local bindings)

```doxa
{ val x : T = expr; val y : T = expr; result }
```

A brace-delimited block of zero or more `val` bindings, each terminated
by `;`, followed by a result expression that is the block's value. The
result is implicit: there is no `in` or `return` keyword, and a block
must end in an expression (a bindings-only block has no value and is
rejected). Bindings scope over the rest of the block. The `;` separator
is always required between block items; newlines are ordinary
whitespace, so a separator-free layout is not used.

A block is an atom: usable wherever an expression is, including as a
function argument when parenthesized (`f ({ val x: T = e; x })`).

The type annotation on a local `val` is optional: when omitted, the
binder's type is inferred from the bound expression, matching a
top-level `val`.

---

## Expressions

### Atoms

```
Type        Type 0     Type 1     ...     // universes
Prop                                      // the Prop sort
x                                         // identifier
List[A]     Vec[A, n]                     // type-level application at use
(expr)                                    // grouping
```

### Application

```doxa
f x y z
```

Pure juxtaposition, left-associative. `f x y z` parses as `((f x) y) z`. Applies identically to:
- functions: `succ zero`, `compose inc double`.
- constructors: `cons 1 nil`, `succ (succ zero)`.
- types: `Vec[A] (succ n)`, where `Vec[A]` is the type-level application and the subsequent `(succ n)` is juxtaposition at the value level.

### Type-level application

```doxa
List[A]
Vec[A, n]
Eq[Nat] three three
```

Square brackets mark type-parameter slots, mirroring the declaration-site `data List[A: Type]`. Multiple type arguments are comma-separated. The bracketed form is an atom; following it with juxtaposed terms is ordinary value-level application.

This is the one point where Doxa surface syntax layers visually on purpose. In `Vec[A] (succ n)`, the reader can tell at a glance which is the type argument (`A`, in brackets) and which is the value index (`succ n`, juxtaposed). That layering is preserved throughout inductive-type use: `Vec[A] zero`, `List[Option[Nat]]`, `Eq[Vec[A] n] xs ys`.

### Lambda

```doxa
(x: A) => body              // with annotation
(x) => body                 // only in check mode (against a Pi)
```

### Dependent Pi

```doxa
(x: A) -> B(x)              // dependent
A -> B                       // non-dependent sugar for (_: A) -> B
```

Right-associative: `A -> B -> C` parses as `A -> (B -> C)`.

### Pattern match

```doxa
match xs {
  case nil => zero
  case cons x rest => succ (length rest)
}
```

Match arms take **no separator**. The `case` keyword is reserved, so it terminates the previous arm's expression unambiguously, and `}` closes the block.

Unlike `data` ctor lists (which use `;` because constructor signatures are type expressions that can run into each other without a terminator: `zero : Nat succ : Nat -> Nat` would parse as applying `Nat` to `succ`), match-arm right-hand sides are ordinary expressions terminated by the next `case` keyword or the closing `}`. The separator carries no grammatical weight here, so we don't add one.

A dependent-motive annotation precedes the opening brace: `match xs returning P { ... }`. The `returning` clause is optional; when omitted, the checker infers the motive from context (a bounded form; see `SPEC.md` §8.5).

---

## Worked example

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

// The element type is implicit; the constructors infer it at use.
fun length{A: Type}(xs: List[A]): Nat = match xs {
  case nil => zero
  case cons _ rest => succ (length rest)
}

val three : Nat = succ (succ (succ zero))
val xs : List[Nat] = cons zero (cons (succ zero) (cons three nil))
val n : Nat = length xs
```

---

## What Doxa does not have (deliberate)

- **No `=>` for function types.** `=>` is reserved for term-level "produces a value" (lambda bodies, match arms). Function types use `->` throughout, consistent with the CIC tradition and with the developer-family `->` convention (Rust, Kotlin, Swift).
- **No `f(a, b)` call syntax.** Juxtaposition only. Parentheses are grouping, not application. See the aesthetic-target note above.
- **No typeclasses yet.** Behavior abstraction is deferred; see SPEC §1.2 and §8.12.
- **No record literals** beyond what ADTs provide. A one-constructor `data` is the record form.
- **No subtyping beyond cumulativity.** `Type n ≤ Type m` when `n ≤ m`; no other implicit coercions.
- **No tuples, arrays, or numeric literals in the core.** The stdlib adds inductive `Option`, `Pair`, `Nat` with numeric-literal elaboration.
