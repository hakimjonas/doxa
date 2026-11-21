# Release notes and 1.0 plan

> Status: this document is the v1.0.0 plan, not the 0.8.4 release. The
> release record is `CHANGELOG.md`.

Doxa is a dependently typed proof checker. It parses surface syntax in the
ML / Scala 3 family, type-checks it bidirectionally, and normalises terms
via Normalization by Evaluation. The kernel implements the Calculus of
Inductive Constructions with predicative cumulative universes and an
impredicative `Prop` sort with definitional proof irrelevance.

## Current status

Doxa is experimental and has no release. `doxa` 0.8.4 was published to pub.dev
on 2026-11-12 and retracted the same day. `doxa_tooling` and `doxa_stdlib` have
never been published. Publishing is on hold until the project is ready.
[`README.md`](../README.md) is the release-status reference and
[`SPEC.md`](../SPEC.md) is the normative language description. The bar a
release must meet is [`RELEASEWORTHY.md`](RELEASEWORTHY.md).

## Feature list

**Core calculus**
- CIC kernel with predicative cumulative `Type 0 : Type 1 : Type 2 : ...` and impredicative `Prop`
- Bidirectional type inference and checking
- Normalization by Evaluation with α, β, η, and ι equivalence
- Defunctionalized interpreter — every kernel path is stack-safe and O(N) in term size
- Locally nameless variable representation with source-name hints for diagnostics

**Inductive types**
- Data declarations with parameters and indices
- Mutual `data` and mutual `fun` blocks
- Strict-positivity check with nested-positivity support
- Auto-synthesised dependent eliminators (`T.ind`, `T.rec`) for every inductive
- Singleton-elimination for Prop-sorted inductives with 1 non-informative constructor

**Pattern matching**
- Primitive `match` with coverage and exhaustiveness checking
- Index-refinement for indexed families (unreachable-arm omission)
- Wildcard arms with constructor-at-a-time coverage
- Dependent motive inference (indexed arms only; non-indexed via eliminators)

**Metavariables and unification**
- Miller's pattern unification (decidable fragment)
- Implicit arguments with `{A: Type}` syntax
- Occurs-check and scope-check on all solutions
- First-class metavariable infrastructure (tactic-ready)

**Propositional equality**
- `Eq` as an ordinary indexed inductive (not a kernel primitive)
- Auto-`refl` synthesis when sides are definitionally equal
- `sym`, `trans`, `cong`, `subst` derived from `Eq.rec`
- K-free, intensional equality (UIP not even statable)

**Standard library**

The standard library is the separate `doxa_stdlib` package.
[`doxa_stdlib/README.md`](../doxa_stdlib/README.md) lists its modules, layout,
and `package:` usage.

**Tooling**
- CLI (`doxa`): `check`, `repl`, `lsp`, and `fmt`
- Interactive REPL (`doxa repl`): `:type`, `:norm`, `:browse`, `:search`,
  `:goal`, `:step`, `:undo`, `:print`, `:qed`, and `:abort`
- LSP language server (`doxa lsp`): hover, go-to-definition, completion, diagnostics
- WasmGC browser demo (`doxa_tooling/web/doxa_check.wasm`)
- Structured JSON output for programmatic consumers

**Surface syntax**
- ML-family surface: `fun`, `val`, `data`, `match`, `import`, `theorem`
- Implicit arguments (`{A: Type}`) and explicit type parameters (`[A: Type]`)
- Typeclasses: single-parameter classes, superclasses with the derived parent
  dictionary, multi-parameter classes, local dictionaries, parameterised
  instances with linear targets, constrained parameters with trailing
  dictionary arguments, and depth-bounded instance search. The standard
  library provides `Eqb` instances for `Nat`, `Bool`, and `List`, and the
  algebra classes `AddMonoid`, `AddCommMonoid`, `Monoid`, and `CommMonoid`
  with `Nat` and `List` instances plus `sum` and `sumViaComm`. Default method
  bodies are not supported; see [`SPEC.md`](../SPEC.md#typeclasses).
- Block expressions with `val` bindings
- Tactics: `by { ... }` with `intro`, `exact`, `apply`, `refl`, `rewrite`,
  `induction`, `cases`, `revert`, `trivial`, `simp`, `auto`, `omega`, and
  `constructor`
- Records with field projection
- Quotient type formation: `Quot(A, R)`
- SProp for strict proof irrelevance

**Platform**
- Dart 3.7+, sealed-class ADTs throughout
- dart2wasm compilation: runs in the browser at native speed
- Native AOT for CLI use
- Single-repo: `doxa/` (kernel) + `doxa_tooling/` (CLI, REPL, LSP, web)
- Parser built on Rumil combinator library

**Testing**
- Test suite covering parsing, elaboration, type checking, conversion, evaluation,
  metas/unification, inductive types, pattern matching, structural recursion,
  quotient types, SProp, records, let-blocks, subtypes/cumulativity,
  Prop elimination, and tactic infrastructure
- 20 negative test programs verifying error diagnostics
- 58 positive test programs exercising the full language
- Stack-safety regression tests at depths up to 10,000 binder/β-redex layers
- stdlib files type-checked on every commit
- Documentation `doxa` blocks are checked by
  `doxa_tooling/test/doc_blocks_test.dart`; the current run checks 45 blocks
  and skips 20 marked fragments

## Gated until implemented

The parser and formatter accept these surfaces, but the elaborator rejects
them with a dedicated error. They are not shipped features:

| Surface | Current status | Error |
|---|---|---|
| Quotient construction `mk` and elimination `lift(f, proof)` | `Quot(A, R)` formation is available. The surface is gated, and the kernel API rejects the `TQuotMk` / `TQuotLift` terms directly, because the lift compatibility proof is not checked | `QuotientUnsupported` (surface), `QuotientTermUnsupported` (kernel API) |
| `termination_by` | Every annotation is rejected; the measure was never checked | `TerminationByUnsupported` |

## 1.0.0 scope

Two surfaces in this plan are gated rather than implemented: kernel checking
for the quotient lift proof and a checked termination measure. The 1.0.0
scope must either complete them or ship them gated with the diagnostics
above. Typeclass declarations, instances, and instance search are partially
implemented; the supported subset is described in the feature list and the
known limitations below. That decision is open.

## What Doxa does not include

These are design non-goals, not omissions:

- Homotopy Type Theory, Cubical Type Theory, univalence
- Full higher-order unification (pattern fragment only)
- Classical axioms (LEM, choice, extensionality) baked into the kernel
- Effects, IO, or mutable state in the object language
- Extraction to functional programming languages
- Universe polymorphism over level variables (concrete `Type n` levels and
  cumulativity are supported)

## Known limitations

- **Universe polymorphism**: the kernel has a hierarchy of concrete levels
  (`Type 0 : Type 1 : ...`) with cumulativity, and conversion is strict on
  levels. It has no quantification over universe variables. Library code is
  written at concrete levels. `docs/SPEC_COVERAGE.md` lists the level tests
  under a "Universe polymorphism" heading; those tests exercise concrete
  levels, not polymorphism.
- **Mutual-data header independence**: a data declaration's header cannot
  reference a sibling in the same mutual block unless that sibling is
  elaborated first. Meta-variables would resolve this.
- **Cross-recursor ι-reductions**: mutual `data` blocks produce
  per-member recursors; cross-recursor calls are not wired as ι-reductions.
  `match` + structural recursion across mutual `fun` blocks covers the use
  case.
- **Non-indexed dependent-motive inference**: `match` infers the motive for
  indexed families but not for simple types like `Nat` in dependent
  positions. The eliminators `T.ind` and `T.rec` work unconditionally.
- **Quotient construction and elimination**: `mk` and `lift(f, proof)` are
  rejected with `QuotientUnsupported`. `Quot(A, R)` formation is available.
  The kernel does not check the lift compatibility proof, so the elimination
  rule is not offered. The kernel API rejects the `TQuotMk` and `TQuotLift`
  terms directly (`QuotientTermUnsupported`), so a consumer that builds
  kernel terms cannot bypass the surface gate; quotation and evaluation still
  handle the terms for the 1.0 completion.
- **Typeclass instance targets**: an instance may target a type constructor
  applied to distinct instance parameters (`impl[A: Eqb] Eqb[List A]`).
  Closed target arguments such as `impl Eqb[List Nat]` are rejected with
  `UnsupportedInstanceTarget`, as are repeated parameters and bare variable
  targets. Coherence is one instance per class and head.
- **Typeclass method names**: each method becomes a top-level projection, so
  method names share the global namespace and two classes cannot declare the
  same name.
- **Typeclass scope**: a method with a default body is rejected with
  `TypeclassUnsupported`, so every instance supplies every method. An
  instance method body does not see the instance being defined; recursion is
  expressed through a top-level `fun`, which is subject to the
  structural-recursion rule.

## Installation

Requires Dart SDK 3.7 or later.

```shell
git clone https://github.com/hakimjonas/doxa.git
cd doxa
cd doxa_tooling && dart pub get
dart run doxa check myfile.doxa
```

## Links

- [Language specification](../SPEC.md)
- [Tutorial](tutorial.md)
- [SPEC coverage audit](SPEC_COVERAGE.md)
- [Standard library](../doxa_stdlib/README.md)
- [Proof examples](../example/proofs.doxa)
