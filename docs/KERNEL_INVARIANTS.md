# Kernel meta-solution invariants

Status: 2026-11-19. This note records the metavariable rules the kernel
enforces, the entry points that apply them, and the gap that remains. It
is the companion to `KERNEL_AUDIT_2026-09-22.md`.

## Solve sites validate their candidates

Every unification solve site checks the candidate against the meta's
recorded `typeExpected` before committing:

| Site | Check |
|---|---|
| `_tryUnify` (`eval.dart`) | scope check, then `checkMetaSolution` |
| `_tryFlexFlexIntersect` (`eval.dart`) | scope check on both candidates, then `checkMetaSolution` on both |
| `_tryConstApproxAtSameMeta` (`eval.dart`) | scope check, then `checkMetaSolution` |

A failed check does not commit. `_tryUnify` throws the diagnostic from the
application that triggered the solve. The flex-flex and const-approximation
sites return `null`, so the caller falls back to the conversion mismatch
path and both metas stay unsolved.

`MetaContext.solve` is the trusted inner API. The tactic engine calls it
directly to commit terms that are open in the goal context; the
elaborator's implicit insertion goes through the unifier, which validates
its candidates. `MetaContext.solve` itself does not re-check. Every
declaration that goes through `checkDeclResult` audits each solved entry
against its expected type in its declaration-site context, so a bad direct
solve is reported at the declaration boundary rather than silently inlined.

## Scope discipline

`_solutionWellScopedUnderCtx` permits a solution that has free de Bruijn
indices pointing into the meta's `localCtx`. Such a solution is open at its
declaration site, not closed over its own λ-chain.

`_forceMetaHead` evaluates a solved entry under `installMetaContext(entry.localCtx,
metas).env`, with the caller's top-binding registry merged in when supplied.
It previously evaluated under an empty env, which threw on any escaped index;
the declaration-site evaluation makes an open solution force correctly.

`inlineSolvedMetas` classifies each stored solution by
`solutionHasFreeIndices`:

- **Open**: the solution has a free `TBound` pointing into
  `entry.localCtx`; its root lives at `entry.localCtx.level`. At a use
  site whose ambient level is `d >= localCtx.level`, the free indices are
  shifted by `d - localCtx.level`; below that the meta is left un-inlined.
- **Closed**: no free indices; its own λ-chain binds the local context or
  the unification spine, so its root lives at ambient 0 and it is
  self-contained.

`_solutionAdmissibleAtDepth` expresses exactly this rule: a closed
solution is always admissible, an open one only at
`ambientLevel >= localCtx.level`.

`_validateSolvedMeta` inlines nested solutions at the solution root's
ambient (`localCtx.level` for an open solution, 0 for a closed one) and
checks the solution under the declaration-site context.

### Producer convention

The tactic engine already stores both shapes consistently:

- **Open over `localCtx`**: `exact`, `refl`, `trivial`, `rewrite`'s
  subgoal, `induction`/`cases` arm goals, `simp`'s direct solves, and
  `intro`'s lambda body. Their free indices refer to the goal context.
- **Closed over `localCtx`**: `apply`'s explicit arguments,
  `constructor`'s argument metas, and `revert`'s reverted goal. They store
  `closeTermOverCtx`'s λ-chain, which rebinds the context and leaves no
  free indices.

`solutionHasFreeIndices` distinguishes the two structurally, so no
producer needs a marker and none had to change. The earlier shift attempt
failed because it treated every solution as open and walked the closed
`revert` chain at `localCtx.level`, counting its context binders twice.

### Two-level rule

The inliner tracks the ambient context level at the position, not the
number of binders entered since the walk root. Entering a binder raises
the ambient by one. Substituting a closed solution resets nothing (it is
self-contained); substituting an open solution sets its root ambient to
its own `localCtx.level`. The shift of `d - localCtx.level` applies once,
to the open solution's own escaped indices.

`_validateSolvedMeta`, the two unifier solve-site inlines, and
`_finalizeDeclBindings` pass the root ambient for the term they hand to
`inlineSolvedMetas`, so the audit and the inliner use the same rule.

## Where solutions are evaluated and inlined

- `_forceMetaHead`: declaration-site env, current `MetaContext` installed.
- `_tryUnify`, `_tryFlexFlexIntersect`: `inlineSolvedMetas` with
  `outerDepth: 0` (their solutions are closed λ-chains over the unification
  spine), then `checkMetaSolution` under the declaration context.
- `_validateSolvedMeta`: `inlineSolvedMetas` with
  `outerDepth: solutionHasFreeIndices(entry.solution) ? entry.localCtx.level
  : 0`, checked under `installMetaContext(entry.localCtx, metas)`.
- `_finalizeDeclBindings`: `inlineSolvedMetas` over each stored binding with
  the default root ambient 0 (the binding term is at the top-level scope).

## Public entry points

| Entry point | What it runs |
|---|---|
| `checkDeclResult` | kernel-checks the produced bodies and audits every solved meta |
| `checkProgram` | elaborates each declaration, then runs `checkDeclResult` against the running environment; the library entry point for a checked program |
| `elabProgram` | elaborates only; no body check, no meta audit |
| `elabDecl` | elaborates one declaration only; no body check, no meta audit |

The tooling pipelines keep their own loops because they need import
resolution and poisoned-name tracking; they call `checkDeclResult`
themselves. `doxa/example/example.dart` uses `checkProgram`.

## Limits

- Pattern unification remains partial (deliberate; see the audit).
- `auto` and `omega` are bounded conveniences.
- A direct `MetaContext.solve` is trusted; only `checkDeclResult`'s audit
  catches an ill-typed direct solution.
