# What releaseworthy means

This document defines whether Doxa deserves a release. It is the bar the
owner uses, and it governs how agents report progress. A green packaging
checklist does not satisfy it.

## The bar

Doxa is releaseworthy when the artifact is capable, useful, and correct
enough for the label. The bar is a property of the artifact. It is not a
property of its packaging.

### Correct enough

The kernel is trustworthy. The declaration-boundary audit is closed,
solutions are validated at the solve site, the implemented semantics are
specified in [`SPEC.md`](../SPEC.md), and the implemented surface has no known
unsoundness. A gated surface is rejected with a named diagnostic; it is never
accepted unchecked.

### Capable

A person can author a nontrivial development without the surface fighting
them. This covers the tactic set, induction, typeclasses, recursion, quotients
where the domain needs them, and the ergonomics that keep larger proofs
readable.

### Useful

The library supports real developments: algebraic structures, number systems,
and data structures. It is a base others can extend. A set of monomorphic
examples does not qualify.

### Usable by someone else

A stranger can install the tool, read the docs, and use the editor. The manual
editor pass and the LSP pass have been done.

## What it is not

Distribution readiness is a separate property. It covers the license, the
pana score, package metadata, the version number, trusted publishers, and the
mechanics of packaging. Each is necessary to publish. None is evidence that
the artifact deserves publishing. A pana score does not establish the bar,
and a version number is not permission to release.

## The failure mode

The failure mode is calling a version ready because the packaging is green.
The record has two instances. `doxa` 0.8.4 was published to pub.dev on
2026-11-12 and retracted the same day. The 2026-11-21 readiness pass measured
distribution (pana, metadata, and packaging) and was called release readiness
while the substance tracks were still open. A packaging checklist answers a
different question from the one this document sets.

## The order

1. Substance: correct, capable, and useful.
2. External usability: installation, documentation, and the editor and LSP
   passes.
3. Distribution: license, pana, metadata, versioning, publishers, and
   packaging.
4. Publication: the owner's decision after the hold is lifted.

Work on a later item does not move an earlier one. Distribution work can
proceed in parallel, but it is not evidence that an earlier item is done.

## The rule for agents

- Do not bump `VERSION`, tag, publish, or describe the project as
  release-ready until the owner says the bar is met.
- Distribution work may proceed. It is not evidence for the bar, and it must
  not be cited in an argument for a release.
- When a track finishes, report against correct, capable, and useful. A green
  packaging checklist is not a status report against this document.

The publishing hold in [`AGENTS.md`](../AGENTS.md) stands.

## Current position (2026-11-21)

### Correct

The declaration-boundary audit is closed. The remaining limits concern
completeness. Solved metavariables are validated at the solve site, and the
implemented rules are specified in [`SPEC.md`](../SPEC.md).
Quotient construction, elimination, and soundness are checked; a lexicographic
`decreases` measure is checked over named value parameters. The completeness limits are general
pattern unification and indexed recursors beyond the current first-order
refinement.

### Capable

Fourteen tactic steps are available: `intro`, `exact`, `apply`, `refl`,
`rewrite`, `induction`, `cases`, `revert`, `trivial`, `simp`, `auto`, `omega`,
`constructor`, and `have`. `calc` chains compose equalities as named steps.
Four infix operators, `*`, `+`, `<=`, and `==`, spell `mult`, `plus`, `leq`,
and `eqb`; the operators are monomorphic to those functions, so the algebra
monoids' `add` and `mul` are not reachable through them.
Typeclasses cover single-parameter classes, instance search, explicit type
arguments, parameterised instances, superclasses with the derived parent
dictionary, local dictionaries, and multi-parameter classes. Default method
bodies are the remaining typeclass gap. Quotients have `mk`, `lift`, and
`Quot.sound` over a checked relation, without a propositional eliminator;
`decreases` checks a lexicographic measure over named value parameters, and an
arithmetic decreasing argument such as `sub m n` is rejected.

### Useful

The standard library covers arithmetic, `Nat`, `Bool`, `List`, `Vec`,
`Option`, `Sigma`, `Int`, equality, the `sqrt2` case study, and the algebra
monoids and the additive group, with `Nat` and `List` monoid instances plus
`AddMonoid[Int]` and `AddGroup[Int]`. The hierarchy stops there: there is no
ring class, no commutative group class, and `AddGroup` has only the `Int`
instance. A `Ring` class cannot sit beside `Monoid` because `Monoid` already
declares `mul`, `mone`, `mul_assoc`, `mul_one_left`, and `mul_one_right` as
global projections. `rational.doxa` is a first cut with a constructor and no
operations or lemmas. Others can instantiate the classes and extend the
library.

### Next

Proof ergonomics: notation for the naming surface. Then the remaining gated
surface, a checked termination measure, and `Quot.ind` for a propositional
eliminator. Then the rest of the algebraic hierarchy, which needs a
class-method namespace that lets a ring class state multiplication fields
that `Monoid` already declares.

### Distribution

Parked. The hold stands.

## Related records

- [`AGENTS.md`](../AGENTS.md) records the publishing hold and the agent rules.
- [`README.md`](../README.md) records the public status.
- [`docs/RELEASE_NOTES.md`](RELEASE_NOTES.md) records the release plan and
  known limitations.
- [`docs/PROOF_ASSISTANT_ROADMAP.md`](PROOF_ASSISTANT_ROADMAP.md) records the
  phase status.
- [`docs/KERNEL_AUDIT_2026-09-22.md`](KERNEL_AUDIT_2026-09-22.md) records the
  kernel audit.
