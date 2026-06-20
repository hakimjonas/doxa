# Doxa v1.0.0 Release Notes

Doxa is a dependently typed proof checker. It parses surface syntax in the
ML / Scala 3 family, type-checks it bidirectionally, and normalises terms
via Normalization by Evaluation. The kernel implements the Calculus of
Inductive Constructions with predicative cumulative universes and an
impredicative `Prop` sort with definitional proof irrelevance.

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
| Module | Contents |
|--------|----------|
| `nat.doxa` | `Nat`, `plus`, `mult`, `pow`, `leq` |
| `bool.doxa` | `Bool`, `and`, `or`, `not` |
| `list.doxa` | `List[A]`, `map`, `fold`, `filter`, `length`, `append`, `reverse` |
| `vec.doxa` | `Vec[A] n` (length-indexed), `vlength` |
| `option.doxa` | `Option[A]`, `map`, `getOrElse` |
| `eq.doxa` | `Eq`, `refl`, `sym`, `trans`, `cong`, `subst` |
| `proofs.doxa` | `plus_comm`, `append_assoc`, `map_compose`, `succ_ne_zero`, `true_ne_false`, `vlength_index` |

**Tooling**
- CLI type checker (`doxa check FILE`)
- Interactive REPL (`doxa repl`): `:type`, `:show`, `:nf`
- LSP language server (`doxa lsp`): hover, go-to-definition, completion, diagnostics
- WasmGC browser demo (`doxa_tooling/web/doxa_check.wasm`)
- Structured JSON output for programmatic consumers

**Surface syntax**
- ML-family surface: `fun`, `val`, `data`, `match`, `import`, `theorem`
- Implicit arguments (`{A: Type}`) and explicit type parameters (`[A: Type]`)
- Block expressions with `val` bindings
- Tactics: `by { intro; exact; refl; … }`
- Records with field projection
- Quotient types: `Quot(A, R)`, `mk`, `lift(f, proof)`
- SProp for strict proof irrelevance
- Typeclasses: `typeclass`, `impl`, class-constrained parameters

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
- 19 negative test programs verifying error diagnostics
- 54 positive test programs exercising the full language
- Stack-safety regression tests at depths up to 100,000 binder/β-redex layers
- stdlib files type-checked on every commit
- All 14 tutorial code blocks verified by automated extraction

## What Doxa does not include

These are design non-goals, not omissions:

- Homotopy Type Theory, Cubical Type Theory, univalence
- Full higher-order unification (pattern fragment only)
- Classical axioms (LEM, choice, extensionality) baked into the kernel
- Effects, IO, or mutable state in the object language
- Extraction to functional programming languages
- Universe polymorphism (planned future direction)

## Known limitations

- **Universe polymorphism**: library code is written at concrete levels. A
  general scheme over universe variables is a planned extension.
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
- **Quotient type-inference with `mk`**: defining a `val q : Q = mk x` can
  interfere with the type inference of `Q` in some contexts. Using the
  quotient type in argument position avoids this.

## Installation

Requires Dart SDK 3.7 or later.

```shell
git clone https://github.com/hakimjonas/doxa.git
cd doxa
cd doxa_tooling && dart pub get
dart run doxa check myfile.doxa
```

## Links

- [Language specification](SPEC.md)
- [Tutorial](docs/tutorial.md)
- [SPEC coverage audit](docs/SPEC_COVERAGE.md)
- [Syntax reference](SYNTAX.md)
- [Standard library](lib/stdlib/)
- [Proof examples](example/proofs.doxa)
