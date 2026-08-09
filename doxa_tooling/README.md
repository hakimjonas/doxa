# Doxa

A dependently typed proof checker for the Calculus of Inductive
Constructions, with an ML-family surface syntax. Written in Dart; the
parser is built with [Rumil](https://github.com/hakimjonas/rumil-dart)
parser combinators.

Doxa is a CIC kernel: a predicative universe hierarchy with a single
impredicative `Prop`, inductive types with parametric and indexed
families and auto-derived recursors, dependent pattern matching with
structural recursion, propositional equality with proof irrelevance,
metavariables with Miller pattern unification, and implicit arguments.
Everything is checked bidirectionally over normalization by evaluation.
See [`SPEC.md`](SPEC.md) for the design.

## Quick start

```shell
dart run bin/doxa.dart check example/proofs.doxa
# OK: 26 declarations checked
```

[`example/proofs.doxa`](example/proofs.doxa) is a guided tour: the
naturals and lists, then proofs by computation and by induction. See
[`example/README.md`](example/README.md) for a walkthrough.

## Syntax

Doxa programs are sequences of top-level declarations:

```doxa
// Dependent identity function.
fun id[A: Type](x: A): A = x

// A named type alias.
type Bool = (A: Type) -> A -> A -> A

// A value binding, with an optional type annotation.
val true_: Bool = (A: Type) => (t: A) => (f: A) => t
```

See [`test/programs/positive/`](test/programs/positive/) for more
examples: Church-encoded naturals, Church booleans, the K and S
combinators.

## Diagnostics

When something doesn't type-check, Doxa produces a structured
diagnostic with your original names:

```
error: type mismatch
  at demo.doxa:1:1
  expected: (A: Type) -> A -> A
  actual:   (x: Type) -> (y: Type) -> Type
  first difference at codomain → domain:
    expected:  A
    actual:    Type
```

Names (`A`, `x`, `y`) survive from your source through elaboration,
evaluation, and error rendering.

## Status

The kernel is usable. It type-checks a self-contained standard library
of proofs ([`lib/stdlib/proofs.doxa`](lib/stdlib/proofs.doxa)) end to
end: arithmetic and list lemmas proved by induction and congruence
(`plus_comm`, `append_assoc`, `length_append`, `map_compose`),
refutation lemmas that derive `False` from impossible equalities
(`succ_ne_zero`, `true_ne_false`), and a theorem about an indexed family
whose statement depends on the type-level index (`vlength_index`, that a
vector's length equals the index its type carries).

Implemented and exercised by the test suite:

- Calculus of Inductive Constructions: dependent functions, a
  predicative `Type` hierarchy with cumulativity, impredicative `Prop`.
- Inductive types: parametric + indexed families, mutual `data` blocks,
  nested positivity, auto-derived dependent recursors. Native `Nat` /
  `Bool` / `List` / `Vec` / `RoseTree` type-check and normalize today.
- Dependent pattern matching (`match`) with structural-recursion
  checking and guarded delta-reduction.
- Propositional equality (`Eq`) with definitional proof irrelevance.
- Metavariables, Miller pattern unification, and implicit arguments,
  via a bidirectional elaborator.

The kernel has grown beyond the bare calculus. Built and exercised by
the test suite: `SProp` for strict proof irrelevance, records with
definitional η, a module system with cyclic-import detection, a tactic
engine (`intro`, `exact`, `apply`, `rewrite`, `induction`, `refl`,
`trivial`), typeclasses with instance search, quotient types
(`Quot(A,R)`, `mk`, `lift`), and a WASM browser demo. Universe
polymorphism (level variables, `LMax`, `LSucc`) has kernel-level
infrastructure; surface syntax remains future work. See
[`SPEC.md`](SPEC.md) §1.1a/§1.1b for the built-vs-future split.

## Performance invariants

Two kernel-level invariants, both enforced by the test suite:

- **Stack safety.** No kernel operation consumes host call stack
  proportional to input depth. A single defunctionalized driver
  (`lib/src/eval.dart`) loops over an explicit frame stack; see
  [`SPEC.md`](SPEC.md) §4.5.
- **Linear-time structural operations.** `eval`, `quote`, `conv`,
  `infer`, `check`, and `nf` are O(N) in input size N (β-reduction
  output size is inherently non-linear and excluded). "Stack-safe but
  quadratic" is explicitly rejected.

Verify both end-to-end with the stress harness:

```shell
dart run tool/stack_stress.dart
```

Every workload at 1,000,000 depth should land in the 100-300 ms band.
Pass `--only=lam` (or any substring) to filter, and trailing integers
to override the default depth ladder, e.g.:

```shell
dart run tool/stack_stress.dart --only=infer 10000 100000 1000000
```

Run this before any PR that touches the kernel paths in `eval.dart`.

## Project layout

```
lib/src/
  term.dart      : kernel term ADT (de Bruijn + name hints)
  value.dart     : semantic values for NbE
  env.dart       : cons-list environments
  ctx.dart       : typing contexts
  meta.dart      : metavariable context (Phase 13)
  registry.dart  : inductive-type / top-binding registries
  eval.dart      : the unified driver (eval, apply, quote, conv, infer, check)
  check.dart     : type-check error types (dispatched from eval.dart)
  surface.dart   : surface AST (SExpr / SDecl with spans)
  parse.dart     : Rumil-based parser
  elab.dart      : surface AST → kernel Term (bidirectional elaborator)
  pretty.dart    : kernel Term → surface string
  diff.dart      : parallel value diff for error paths
  report.dart    : diagnostic formatting
  source.dart    : source-file / line-column resolution
lib/stdlib/      : standard library (nat, bool, list, option, vec, eq, proofs)
bin/
  doxa.dart      : CLI: `doxa check FILE`
test/
  programs/     : curated .doxa files (positive and negative)
  *_test.dart   : unit tests
```

## License

MIT. See [`LICENSE`](LICENSE).
