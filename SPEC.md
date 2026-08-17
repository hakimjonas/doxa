# Doxa implementation specification

This document describes behavior implemented by the current Doxa parser,
elaborator, checker, evaluator, and command-line tool. `SYNTAX.md` is the
surface-syntax reference.

## Pipeline

`doxa check FILE` loads the ambient prelude, resolves imports, parses the
program, elaborates declarations, and checks the elaborated terms. The prelude
declares `Eq` and `Acc`.

Imports use quoted paths relative to the importing file. The parser accepts an
unqualified import, a selective import, an alias, or both:

```doxa
import "nat.doxa"
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
`refl`, `rewrite`, `induction`, and `trivial`. Semicolons sequence steps; `|`
separates alternatives.

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

Typeclasses and implementations are declarations. A class contains `fun`
method signatures, optionally with default bodies. An implementation names an
applied class and provides `fun` members.

```doxa
typeclass Semigroup[A: Type] {
  fun combine(x: A, y: A): A;
}

impl Semigroup[Nat] {
  fun combine(x: Nat, y: Nat): Nat = plus x y;
}
```

This is a syntax fragment because `Nat` and `plus` require declarations. An
explicit type-parameter group may state constraints such as `[A: Eq & Ord]`.
The elaborator records classes and implementations for constrained-argument
resolution.

## Scope

This document makes no performance, metatheoretic, or compatibility claim not
represented by the current implementation or its checked examples. The sources
under `doxa/lib/src/` are authoritative for details omitted here.
