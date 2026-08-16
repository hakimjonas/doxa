# Doxa syntax reference

This reference lists forms accepted by the current parser. Newlines are whitespace. Line comments start with `//`; block comments use `/*` and `*/` and may nest.

Unless a block appears under Checked examples, it is a syntax fragment.
Fragments use metavariables such as `A`, `T`, `body`, and `value`, or require an
expected type or an importable file, so they cannot be checked as standalone
programs.

## Names and sorts

Identifiers start with a letter or `_`, then contain letters, digits, or `_`.
Dotted names append one or more `.name` suffixes to an identifier expression.

```doxa
Type
Type 0
Prop
SProp
Nat.ind
```

The decimal after `Type` is a universe level. Decimal numerals are not general
term literals. `Prop` and `SProp` do not accept levels.

## Expressions

### Application

```doxa
f x y
List[A]
Vec[A] n
```

Application is juxtaposition and associates to the left. `f x y` parses as
`(f x) y`. Brackets are a postfix form on an identifier and contain one or more
comma-separated expressions. A term after a bracket form is ordinary
application.

### Functions

```doxa
(x: A) => body
(x) => body
{x: A} => body

(x: A) -> B
{x: A} -> B
A -> B
```

`(x) => body` needs an expected Pi type. Curly forms introduce implicit
binders. `A -> B -> C` associates to the right. The non-dependent arrow has an
unnamed explicit binder.

### Blocks

```doxa
{ val x: Type 1 = Type; x }
{ val rec loop(x: T): U = body; result }
```

Each local binding needs a semicolon and the block needs a final expression.
The type on a non-recursive local `val` may be omitted. A block used as an
application argument must be parenthesized: `f ({ val x = y; x })`.

### Pattern matching

```doxa
match xs {
  case nil => zero
  case cons x rest => succ (length rest)
  case _ => zero
}

match xs returning P {
  case nil => zero
  case cons x rest => succ (length rest)
}
```

Arms have no separator. A constructor pattern has a constructor name and zero
or more binders. `_` is a wildcard arm only in `case _ => body`.

### Quotients

```doxa
Quot(A, R)
mk value
lift(function, compatibilityProof)
```

`mk` requires an expected quotient type. `lift` is completed by a surrounding
application that supplies a quotient argument.

### Tactic blocks

```doxa
by { intro x; exact x }
by { refl | trivial }
```

The parser accepts `intro [name]`, `exact expr`, `apply expr`, `refl`,
`rewrite expr`, `induction name`, and `trivial`. `;` sequences steps and `|`
separates alternatives.

## Declarations

### Values, aliases, and theorems

```doxa
val x: T = expr
val x = expr
opaque val x: T = expr
type Name = T
theorem name: T := proof
theorem name: T = proof
```

`opaque` also precedes `fun`. A type alias, value declaration, and theorem are
top-level declarations.

### Functions

```doxa
fun id[A: Type](x: A): A = x
fun idImplicit{A: Type}(x: A): A = x
fun f[A]{B: Type}(x: A): B = body
fun f[A: Eq & Ord](x: A): A = body
opaque fun f(x: T): U = body
fun f(x: T): U {struct x} = body
fun f(x: T, y: U): V termination_by (x, y) = body
```

`[...]` introduces explicit type parameters and `{...}` introduces implicit
type parameters. An explicit group may state `&`-separated constraints. Value
parameters are comma-separated and have type annotations.

Mutual functions use `and fun`:

```doxa
fun f(x: T): U = body
and fun g(x: T): U = body
```

### Inductive declarations

```doxa
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}

data Vec[A: Type]: Nat -> Type {
  vnil: Vec[A] zero |
  vcons: (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
```

The signature after `:` gives the indices, if any, followed by the target
sort. Constructor entries use either `;` or `|`, and a trailing separator is
accepted. Mutual data declarations use `and data`.

Product-form declarations have fields and no `record` keyword:

```doxa
data Point[A: Type]: Type {
  x: A;
  y: A;
}
```

Field access has the form `point.x`.

### Imports

```doxa
import "nat.doxa"
import "nat.doxa" { Nat, zero }
import "nat.doxa" as N
import "nat.doxa" { Nat, zero } as N
```

### Typeclasses and implementations

```doxa
typeclass Semigroup[A: Type] {
  fun combine(x: A, y: A): A;
}

typeclass Ord[A: Type]: Eq[A] {
  fun compare(x: A, y: A): Int;
}

impl Semigroup[Nat] {
  fun combine(x: Nat, y: Nat): Nat = plus x y;
}
```

Method separators are optional semicolons. A superclass follows the parameter
list after `:`.

## Checked examples

The following complete programs were checked with
`doxa_tooling/build/doxa check` during this documentation update.

```doxa
opaque fun id[A: Type](x: A): A = x
```

```doxa
fun id[A: Type](x: A): A = x
fun idImplicit{A: Type}(x: A): A = x
```

```doxa
theorem identity : (A: Type) -> (x: A) -> Eq A x x := by {
  intro A; intro x; refl
}
```

```doxa
val block: Type 2 = { val x: Type 1 = Type; x }
```

```doxa
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}

data Vec[A: Type]: Nat -> Type {
  vnil: Vec[A] zero |
  vcons: (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
```

```doxa
data Point[A: Type]: Type {
  x: A;
  y: A;
}
```

The checked standard library also contains imports, structural annotations,
`termination_by`, matching, and typeclass implementations. Quotient syntax is
covered by the parser and checker tests; its forms remain fragments here because
their well-typed use requires surrounding context.
