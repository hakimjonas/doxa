# Changelog

## 0.1.0

Initial public preview of the Doxa kernel.

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
