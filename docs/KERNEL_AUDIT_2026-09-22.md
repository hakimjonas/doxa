# Doxa kernel: external audit

> Historical record (2026-09-22): this is the external audit, kept for
> provenance. Its findings are not current rules. See the resolution status at
> the end and [`KERNEL_INVARIANTS.md`](KERNEL_INVARIANTS.md) for the current
> metavariable rules.

**Status:** audit note (2026-09-22), written by an external reviewer for the next
Doxa work session. It is not a Doxa-authored document. Claims are against the
sources at this revision.

## 1. What Doxa is

A dependently typed proof checker in Dart. The repository is about 50k LOC; the
kernel (`doxa/lib/src/`) is about 24k. The kernel checks a surface language with
dependent functions, inductive types with indices, pattern matching with
motives, implicit arguments, propositional equality, a universe hierarchy
(`Type n`, `Prop`, `SProp`), quotient types, typeclasses, and tactic blocks. The
tooling package provides the CLI, formatter, REPL, LSP, a WASM entry, and editor
extensions. The test suite is about 797 tests, and the checker runs the 42-decl
standard library in about 10 ms AOT.

## 2. What is sound and worth preserving

These are the kernel's load-bearing decisions; a reimplementation should keep
them.

1. **One defunctionalized abstract machine.** Evaluation, quotation, conversion,
   and bidirectional checking share a single driver loop (`_drive`) with an
   explicit step and frame stack (`_Step`, `_Frame`). No semantic function calls
   another, so deeply nested or Church-encoded terms cannot exhaust the host
   stack. This is the single most valuable structural property in the codebase.
2. **Normalization by evaluation with levels in values and indices in terms.**
   Values carry their environments (closures), so beta reduction substitutes
   nothing into syntax. Neutrals (`NVar`, `NApp`, `NStuck`, `NTop`, `NMeta`,
   `NProj`) are first-class values with position-stable de Bruijn levels.
3. **Metavariables and Miller pattern unification inside the conversion loop.**
   The unifier is not a separate pass; it is the flex case of `conv`. This is
   the Lean and elaboration-zoo shape and it is coherent.
4. **Elaboration mirrors the kernel's match refinement.** The elaborator calls
   the kernel's `refineMatchArmExpected`, and the kernel then re-checks the
   elaborated term independently. The layering is honest.
5. **Multi-recursor emission with the singleton-elimination gate.**
   `T.rec` for every inductive, `T.ind` for a Prop motive, `T.rect` only when
   singleton elimination admits. The Prop-elimination restriction is enforced.
6. **The surface is already Fungal-aligned.** `fun`, `val`, `data`, `match`,
   `case`, `typeclass`, `impl`, arrows, brackets, `module`-free imports.

## 3. Soundness gaps (fix or disable before trusting proofs)

These can let an unsound program type-check. They are ordered by severity.

1. **Quotients are not sound and not complete.**
   - `Quot.mk` cannot be checked: `_Infer(TQuotMk)` throws `QuotMkInInferMode`
     and `_Check` has no `TQuotMk` case, so `mk` fails to elaborate.
   - `Quot.lift`'s compatibility proof is never checked. `_InferQuotLiftHaveFnType`
     discards `quotA` and `quotR`, and `_InferQuotLiftAfterProof` yields the
     codomain. `QuotFnNotRespectingRelation` exists in `check.dart` but is never
     thrown (only referenced by the reporter).
   - `VQuotMk` conversion is `identical` only, so two definitionally equal
     carriers are not equal quotients.
   Recommendation: either complete quotients (mk in check mode, the lift proof
   check, and a deliberate equality rule) or reject the surface syntax so it
   cannot accept an unproved elimination.

2. **Multi-parameter `termination_by` silently skips the recursion check.**
   Only a single-parameter `termination_by` is desugared to fuel; otherwise the
   binding is routed through `_elabFunBlock` with `terminationBy != null`, which
   skips `checkStructuralRecursion` and marks the binding opaque. A function
   whose recursion does not structurally decrease can therefore be installed as
   opaque, and its recursion stays stuck rather than being rejected.
   Recommendation: reject multi-parameter `termination_by` until it is
   implemented, or implement the measure check.

3. **Typeclass resolution is a name-matching stub.**
   `_insertImplicits` matches instances by simple name equality, only when the
   domain has exactly one argument; there is no recursive instance search and no
   head unification. When no candidate is found and the arguments are not fully
   concrete it silently allocates a metavariable, so an unsolved constraint can
   surface late or never.
   Recommendation: implement instance search proper, or reject constrained
   implicits you cannot resolve rather than deferring them silently.

## 4. Completeness and fragility (not soundness holes; port carefully)

1. **Pattern unification is deliberately partial.** Only canonical `[0..n-1]`
   spines, common-prefix flex-flex intersection, and a const-approximation
   recovery. Documented as a non-goal, but it bounds what inference can do.
2. **Indexed recursor type synthesis is partial.** Correct for the uniform
   pattern where each constructor's result indices are `TBound` references to
   its arguments; general index expressions are deferred.
3. **Singleton-elimination determinism is first-order.** `_collectHeadBounds`
   counts any reachable `TBound`, not only head positions.
4. **`TType(0)` is used as a sentinel** for mutual pre-bindings, and `_shimState`
   uses `VType(0)` placeholder binder types that are explicitly documented as
   able to lie to implicit insertion. This is fragile coupling between
   elaboration and evaluation; a reimplementation should carry real types or an
   explicit `Unknown` marker instead.
5. **`VMatch` conversion and `_substArmBody`** are the highest-risk code in the
   kernel: a three-tier match-to-match comparison and env-relative substitution
   with a separate metavariable-spine regime. Expect any port to be wrong here
   first.
6. **A global `maxSteps` guard** and many `StateError`s make invariant
   violations abort the checker rather than report a diagnostic.
7. **Dead and vestigial code**: `_appViaRule` (parser) and `_buildMethodLambda`
   and `_buildMethodPiType` (elab) are retained but unused.

## 5. Tooling

The parser is rumil-based and its live `_app` path uses `pratt`; the older
`rule` path is retained as a benchmark. The formatter, REPL, LSP, WASM entry,
and editor extensions are complete for the current feature set. The known
friction for a port is the span and `Icit` plumbing and the tactic surface, not
the grammar shape.

## 6. Where Fungal features could take it beyond the current kernel

This is an argument for a Fungal reimplementation only if and when it is
wanted; it is not a recommendation to port now.

1. **The driver is an explicit control stack already.** Fungal's effect and CPS
   machinery is a natural host for `_drive`; the machine could be written as an
   effectful interpreter whose continuation is the frame stack.
2. **GADT terms.** Doxa models `Term` and `Value` as Dart sealed hierarchies;
   Fungal GADTs could index the value representation by its sort, removing the
   `TType`/`TProp`/`TSProp` dispatch duplication and the sentinel coupling.
3. **Typeclasses.** The kernel's typeclass resolution is the weakest part; a
   Fungal reimplementation would inherit Fungal's own instance search.
4. **Reference counting.** Values and terms are acyclic and share closures;
   Fungal's borrow-first RC and in-place reuse fit the lifetime pattern, though
   quote and conv create transient spines.
5. **One language.** A Fungal kernel removes the Dart host and the package
   split, and makes the checker part of the same self-hosting story as the
   Fungal compiler.

## 7. Prioritized next steps

1. Fix or disable quotients (soundness, section 3.1).
2. Reject multi-parameter `termination_by` (soundness, section 3.2).
3. Implement or reject typeclass constraints (soundness, section 3.3).
4. Specify and test the arithmetic semantics of `Nat`/`Int` (division by zero,
   overflow, remainder sign). A proof assistant's integer theory is a
   specification that callers rely on; leaving `div`/`mod` unsigned is the same
   class of gap as the three above.
5. Complete pattern unification and indexed recursors when a proof needs them.
6. Replace the `TType(0)` sentinel with an explicit unknown marker.

## 8. What to keep unchanged

The abstract machine, the level/index split, the in-conversion unifier, the
elaborator-mirrors-kernel discipline, and the multi-recursor scheme. These are
correct and hard-won; a port that loses any of them loses the kernel's main
advantages.

## Resolution status (2026-11-19)

The three soundness gaps in section 3 are closed:

1. **Quotients.** Closed in two steps. The surface first rejected `mk` and
   `lift` (`QuotientUnsupported`) and the kernel rejected `TQuotMk` and
   `TQuotLift` in both modes. The quotient completion (2026-11-22) then
   implemented the finding's first recommendation: `mk` and `lift` are
   check-mode rules, the compatibility proof is checked
   (`QuotFnNotRespectingRelation` is now reachable), and the equality rule is
   the primitive `Quot.sound`, propositional rather than definitional.
   `VQuotMk` conversion compares its arguments structurally. The carrier and a
   lift's result type are `Type 0`, and there is no `Quot.ind`. Covered by
   `doxa/test/quotient_test.dart`, `doxa_tooling/test/quotient_surface_test.dart`,
   and the `doxa_tooling/test/fixtures/quotient_pair.doxa` acceptance module.
2. **Multi-parameter `termination_by`.** Every `termination_by` is
   rejected before the recursion check can be skipped
   (`TerminationByUnsupported`). Covered by
   `doxa_tooling/test/wf_recursion_test.dart`, including the
   multi-parameter and mutual-block cases.
3. **Typeclasses.** `typeclass` and `impl` declarations are rejected
   before registration (`TypeclassUnsupported`), so no class-constrained
   implicit can resolve silently. Covered by
   `doxa/test/typeclass_test.dart`.

Meta-solution handling is summarised in
[`KERNEL_INVARIANTS.md`](KERNEL_INVARIANTS.md): solve-site validation and
declaration-site evaluation are closed; the deeper-inlining gap and its
design constraint are recorded there, along with the checked
`checkProgram` entry point.
