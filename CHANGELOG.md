# Changelog

## 0.8.0

First preview release — feature-complete kernel, competitive tooling, one verified case study.

### Kernel
- Calculus of Inductive Constructions: dependent functions, predicative cumulative `Type` hierarchy, impredicative `Prop`, `SProp`
- Inductive types with parametric/indexed families, mutual `data` blocks, strict positivity
- Dependent pattern matching with coverage/exhaustiveness checking
- Propositional equality with proof irrelevance, `refl` synthesis
- Metavariables + Miller pattern unification + implicit arguments
- Records with field projection and definitional η
- Quotient types, universe polymorphism infrastructure
- Structural recursion with `termination_by` for well-founded functions
- Stack-safe defunctionalized evaluator, O(N) operations
- Hardening guards: step-count limit, `bodyIsNormal` invariant, `_validateTerm` at meta-solve, `_buildFullEnv` stub check

### Standard library (157 declarations)
- `nat.doxa`: Nat, plus, mult, pow, sub, lt, leq, mod, div, gcd, lcm, coprime, divides, prime, `fix_by_fuel`
- `proofs.doxa`: plus_comm, plus_assoc, mult_comm, mult_assoc, plus_zero, `strong_ind`
- `case_study.doxa`: Full `sqrt2` irrationality proof (127 declarations)
- `Prop/prop.doxa`: And, Or, Not, Exists
- `Lt` well-founded relation on Nat

### Tooling
- CLI: `doxa check [--json] [--watch]`, `doxa fmt [--check]`, `doxa lsp`, `doxa repl`
- REPL: 12 tactics (intro, exact, apply, refl, trivial, rewrite, induction, constructor, cases, simpl, auto, omega) with proof mode (`:goal`, `:step`, `:undo`, `:print`, `:qed`)
- REPL: `import` support, `:browse`, `:search` (name + type matching)
- LSP: diagnostics, hover, go-to-definition, completion (with types + frequency ranking), references, rename, semantic tokens, document symbols, signature help, code lens, document formatting
- Formatter: robust pretty-printer, fast AOT compilation
- Error messages: unsolved metas rendered as `_` instead of internal IDs

### IDE support
- VS Code extension in `vscode/` — syntax highlighting, bracket matching, LSP integration
- JetBrains (IntelliJ, CLion, etc.) via LSP4IJ — config in `contrib/jetbrains/`

### Browser
- WASM playground: expandable per-declaration display with types and normal forms

## 1.0.0 (unreleased — was placeholder)

Replaced by 0.8.0 above. 1.0.0 will ship when the proof roster includes
at least two non-trivial case-study theorems and the full tooling stack
is user-tested.

- Calculus of Inductive Constructions: dependent functions, a predicative
  cumulative `Type` hierarchy, impredicative `Prop`.
- Inductive types with parametric and indexed families, mutual `data`
  blocks, strict (and nested) positivity, and auto-derived dependent
  recursors.
- Dependent pattern matching (`match`) with structural-recursion checking
  and guarded delta-reduction.
- Propositional equality (`Eq`) with definitional proof irrelevance and
  `refl` synthesis.
- Metavariables, Miller pattern unification, and implicit arguments, via a
  bidirectional elaborator.
- Block-expression local bindings (`{ val x: T = e; ... result }`) with
  `val rec` for recursive local definitions.
- Normalization by evaluation on a single stack-safe defunctionalized
  driver; structural kernel operations are linear-time, enforced by a
  stress harness.
- Structured diagnostics that cite source spans and the user's binder
  names.
- `SProp` sort with strict proof irrelevance; SProp-inductive families.
- Records with field projection and definitional η.
- Module system with `import` declarations and cyclic-import detection.
- Tactic engine: `intro`, `exact`, `apply`, `refl`, `induction`, `rewrite`,
  `trivial`, with alternative blocks (`|`).
- Typeclasses: `typeclass` declarations, `impl` instance blocks, and
  implicit-argument instance search.
- Quotient types: `Quot(A, R)`, `mk` injection, `lift(f, proof)` with
  ι-reduction.
- Universe polymorphism infrastructure: level variables, `LMax`, `LSucc`.
  Surface syntax and elaboration are future work.
- CLI type checker (`doxa check`), REPL (`doxa repl`), LSP language server.
- WasmGC browser demo via dart2wasm.
- Structured JSON output for programmatic consumers.
- A self-contained standard library whose proof roster (`plus_comm`,
  `append_assoc`, `length_append`, `map_compose`, `succ_ne_zero`,
  `true_ne_false`, `vlength_index`) type-checks end to end.
- Written tutorial (`docs/tutorial.md`) with 14 verified code blocks.
- SPEC coverage audit (`docs/SPEC_COVERAGE.md`) mapping every specification
  clause to its test.

## 0.1.0

Initial public preview of the Doxa kernel (Phases 0–13).

- Calculus of Inductive Constructions: dependent functions, a predicative
  cumulative `Type` hierarchy, impredicative `Prop`.
- Inductive types with parametric and indexed families, mutual `data`
  blocks, strict (and nested) positivity, and auto-derived dependent
  recursors.
- Dependent pattern matching (`match`) with structural-recursion checking
  and guarded delta-reduction.
- Propositional equality (`Eq`) with definitional proof irrelevance and
  `refl` synthesis.
- Metavariables, Miller pattern unification, and implicit arguments, via a
  bidirectional elaborator.
- Block-expression local bindings (`{ val x: T = e; ... result }`).
- Normalization by evaluation on a single stack-safe defunctionalized
  driver; structural kernel operations are linear-time, enforced by a
  stress harness.
- Structured diagnostics that cite source spans and the user's binder
  names.
- A self-contained standard library whose proof roster (`plus_comm`,
  `append_assoc`, `length_append`, `map_compose`, …) type-checks
  end to end.
