# Changelog

## 1.0.0

Initial release of the Doxa proof checker.

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
