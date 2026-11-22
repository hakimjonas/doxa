# Changelog

## Unreleased

Publication status: `doxa` 0.8.4 remains retracted. `doxa_tooling` and
`doxa_stdlib` have never been published. Publishing is on hold until the
project is ready.

**Kernel soundness**

- Rejected `auto` and `omega` in the `by` block of a recursive function.
  Both tactics apply top-level names from the environment, and a recursive
  member is pre-bound during its own check, so either could call the
  function without an expression the recursion check can scan.
- Rejected recursive calls hidden inside `by` blocks. The structural and
  measured recursion checks previously skipped tactic blocks, so a call that
  grew inside a block could pass the check, and a function whose only call
  was in a block crashed during the kernel check. Both checkers now scan the
  block's embedded expressions with the names the tactics introduce and
  report `RecursionInTacticBlock`. A block with no recursive reference is
  still accepted.
- Replaced the gated `termination_by` annotation with a checked
  `decreases (p1, ..., pn)` lexicographic measure. Every recursive call must
  decrease the named tuple under the strict sub-term order. Empty, duplicate,
  unknown, non-recursive, mutual-block, and `{struct}` combinations are
  rejected, and an arithmetic decreasing argument such as `sub m n` is
  rejected because the checker tracks syntactic sub-terms only.
- Replaced the `TType(0)` sentinel with an explicit unknown marker (#7).
- Resolved top-level bindings during inductive index evaluation (#8).
- Completed the match, induction, and tactic soundness pass (#10).
- Recorded the meta-solution audit and inlining discipline (#13).
- Counted explicit type arguments when locating the structural-recursion
  position (#16).
- Unannotated declarations whose bodies insert implicit arguments, such as a
  typeclass dictionary or an implicit type argument, now infer their type and
  are checked instead of aborting with an internal error. An inferred type
  that still depends on an undetermined metavariable is reported as
  `cannot infer the type of declaration` with the annotation that fixes it.

**Quotients**

- Completed the first quotient slice: `Quot(A, R)` checks that the relation
  inhabits `(x: A) -> (y: A) -> Prop`, `mk` and `lift` are check-mode rules,
  `lift`'s compatibility proof is checked, and the primitive `Quot.sound`
  provides the propositional equality of two injections. `lift` computes by
  ι-reduction, and `VQuotMk` conversion compares its arguments. Carriers and
  lift results are at `Type 0`, and there is no `Quot.ind`.

**Proof authoring and tactics**

- Added `simp`, `cases`, `constructor`, `auto`, and `omega` (#12).
- Added `have` steps and `calc` equality chains to the proof surface.

**Language surface**

- Added the infix operators `*`, `+`, `<=`, and `==` for `mult`, `plus`,
  `leq`, and `eqb`. `*` binds tighter than `+`, both bind tighter than the
  comparisons, arithmetic associates left, comparisons do not associate, and
  each operator expands to exactly one top-level function. The formatter
  prints the operators and parenthesizes only where precedence requires.

**Standard library and package imports**

- Packaged the standard library as `doxa_stdlib` and resolved `package:`
  imports through the project configuration (#11).
- Added `Eqb` instances for `Nat`, `Bool`, and `List` (#17).

**Typeclasses**

- Implemented typeclass declarations, instances, and instance search,
  replacing the 0.8.4 rejection (#14).
- Added parameterised instances, recursive dictionary discharge, and the
  self-recursion soundness fix (#15).

**Records and projections**

- Made every field of a product-form record project and lifted the one-method
  class limit through the same field-type fix (#19).

**Documentation and tooling**

- Folded the syntax reference into `SPEC.md` and added a test that checks
  `doxa` fences in the SPEC and README (#18).
- Refreshed the tutorial and guide examples and extended the doc-block test
  to the tutorial, proof guide, and arithmetic document (#20).
- Solved implicit arguments in the REPL `:type` and `:norm` paths, so
  expressions such as `id2 zero` and `refl zero` elaborate and show their
  types.
- Kept LSP hover, definition, references, rename, and completion available on
  the checked prefix of a document with a type error.
- Kept imported files navigable when a document's declaration fails: the
  failure carries the resolved imports cache, so hover and definition reach
  the imported source instead of dropping it.

## 0.8.4 (2026-11-12)

Publication status: `doxa` 0.8.4 was published to pub.dev on 2026-11-12 and
retracted the same day. `doxa_tooling` 0.8.4 was never published. The 0.8.4
JetBrains plugin was published from the pre-fix build and remains on the
marketplace; it predates the `prime`, `gcd`, and `coprime` fixes.

- Added `docs/arithmetic.md`, which specifies the `Nat` operations, the
  zero-divisor conventions (`div m zero = zero`, `mod m zero = m`), the
  fuel-based `mod_acc`/`div_acc` bound, arbitrary precision, and the proposed
  `Int` division conventions.
- Proved `sub_zero`, `mod_acc_zero`, `mod_zero`, and `div_zero` in
  `lib/stdlib/proofs.doxa`.
- Fixed `prime` to start the divisor scan at `n - 2`, so candidates run from
  `n - 1` down to `2`; composites now return `false_`.
- Fixed `gcd` to use `m + n` fuel. The previous `m` bound made `gcd 2 3`
  return `2`, which also corrupted `lcm` and `coprime` for `m < n`.
- Changed `coprime` to require the gcd to be both at most one and nonzero.
  `coprime zero zero` is now `false_`.
- Added `doxa_tooling/test/nat_div_mod_test.dart` and
  `doxa_tooling/test/nat_prime_test.dart`, which check the division, modulo,
  prime, coprime, gcd, and lcm edge cases by `refl`.
- Corrected the v1.0.0 release notes. Quotient `mk`/`lift`, typeclass/impl,
  and `termination_by` are recorded as gated rather than shipped, and the
  universe-polymorphism statements now distinguish concrete levels from
  polymorphism.

- Synthesized well-formed recursor types for constructors whose recursive
  argument is a dependent Pi chain. Earlier chain binders are preserved and
  outer references are rebased into the method context.
- Closed the induction hypothesis for function-typed recursive arguments
  over the constructor telescope and in the data parameter order, so
  `Acc.rec`, `D4.rec`, and `D5.rec` reduce through their methods.
- Solved constructor data parameters from the expected type in check mode
  before checking explicit arguments. An argument type that mentions a
  value parameter no longer sees an unsolved meta.
- Built match-arm telescopes in data parameter order at all three sites,
  which also restores indexed coverage detection for a missed reachable
  constructor.
- Parameterized `Acc` by its relation (`data Acc[A: Type, R: A -> A -> Prop]`)
  and redefined `strong_ind_impl` as `Acc.rec` over `nat_wf` / `nat_wf_help`,
  now in `proofs.doxa`. `lib/stdlib` no longer uses `termination_by`.
- Kept the ambient prelude mirror in sync with `lib/stdlib/prelude.doxa`
  and added a structural sync test for the `Eq` and `Acc` declarations.
- Rejected `typeclass` and `impl` declarations with `TypeclassUnsupported`.
  The resolver does not thread class dictionaries, search instances
  recursively, or project methods. The parser, formatter, AST, and internal
  class registry remain for a future implementation; the stdlib typeclass
  demo and `Typeclass` package are removed.
- Rejected the quotient surface operations `mk` and `lift` with
  `QuotientUnsupported`. `Quot(A, R)` still forms a type; the construction
  and elimination are unavailable until the kernel checks the lift
  compatibility proof. The internal `TQuot`/`VQuot` primitives remain for
  kernel tests and are not user-reachable.
- Rejected every `termination_by` annotation with
  `TerminationByUnsupported`. The measure was never checked, and the
  single-parameter fuel desugaring could accept non-terminating recursion.
  The fuel path, its self-call rewriter, and `TerminationByParamNotFound`
  are removed. Use structural recursion, or `Acc.rec` with `nat_wf`.
- Fixed leaf tactics leaving the goal unsolved: a `by { ... }` block ending
  in `refl` or `trivial` failed with "tactic block: no alternative succeeded"
  even when the produced proof term checked, because `refl` and `trivial`
  returned the term without solving the current goal meta (unlike `exact`
  and `apply`, which solve it themselves). Both now solve the current goal,
  matching the leaf-tactic convention.
- Synced `doxa_tooling`'s `rumil`/`rumil_tokens` constraints to `^0.11.0` to
  match the kernel, unblocking `dart pub global activate` from the path.
- `doxa_tooling` depends on `doxa ^0.8.4`. The local path override moved to
  the gitignored `pubspec_overrides.yaml`, which CI and the release binary
  build generate before `dart pub get`; the published pubspec has no override.

## 0.8.3 (2026-08-30)

- Fixed the Zed extension's language-server launch. Zed resolves extension
  server commands relative to the extension work directory, so the previous
  bare `doxa` command failed to start ("No such file or directory" in
  `Zed.log`). The extension now asks the worktree for the absolute path of
  `doxa` and falls back to `~/.local/bin/doxa` and `~/.pub-cache/bin/doxa`.
- Added a `doxa/proofState` server notification. After every document check
  the language server reports one entry per `by { ... }` block: the span,
  whether the block proved its goal, and the open goals with their binder
  context and expected type. Positions are UTF-16.
- Added kernel support for proof-state snapshots: `elabDecl` accepts a
  `proofStateSink`, and each `by` block records an immutable
  `ProofStateBlock` (new export `package:doxa/doxa.dart`) as its
  elaboration finishes, on success and on failure.
- The VS Code extension shows the open goals for the block under the cursor
  in a webview panel (`Doxa: Show Proof State`).
- Declared the JetBrains support policy: the plugin is developed and tested
  against IntelliJ IDEA Community Edition and other IDEs built on IntelliJ
  Platform 2025.1; commercial IDEs work as-is but are untested.
- Added a Zed extension (`editors/zed/`): tree-sitter grammar pinned by
  revision, highlighting, bracket, indentation, and outline queries, and
  the Doxa language server started from PATH.
- Added `tool/grammar/`: the Doxa surface grammar as a declarative
  `rumil_grammars` IR plus `generate.sh`, which lowers it to
  `grammar.json`, regenerates the tree-sitter parser in the
  tree-sitter-doxa repository, runs the corpus tests, and syncs the
  query files. The parser in `doxa/lib/src/parse.dart` remains
  authoritative.
- The release workflow builds native binaries on five runners (linux-x64,
  linux-arm64, macos-arm64, macos-x64, windows-x64) and attaches them, with a
  `checksums.txt` file, to the GitHub release.

## 0.8.2

- Fixed duplicate-declaration diagnostics when an imported path is resolved
  more than once.
- Reported the release version from the language server.
- Moved the VS Code and JetBrains extensions into `editors/` in this
  repository.
- Added a configurable language-server path and scoped file watching to the VS
  Code extension.

## 0.8.0

- Published the first preview release of the kernel, command-line tooling,
  standard library, VS Code extension, and JetBrains plugin.
- Added checked standard-library proofs and the `sqrt2` natural-number descent
  case study.
