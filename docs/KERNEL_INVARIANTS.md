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

`inlineSolvedMetas` substitutes a solved meta at the use-site walker depth.
`_solutionAdmissibleAtDepth` is a hook for delayed records and returns
true for every solved entry today, so a solved entry is inlined at any
depth; the open gap below is the consequence.

`_validateSolvedMeta` inlines nested solutions at the default outer depth
(0) and then checks the solution under the declaration-site context, so the
audit and the inliner interpret the term with the same no-shift rule.

### Open gap: deeper inlining of an open solution

If an open solution (one with free indices into `localCtx`) is inlined under
binders added after the meta was declared, its indices are short by the
number of added binders. The intended fix is to shift the escaped indices by
`useDepth - localCtx.level`.

That shift was implemented and reverted. It breaks the tactic engine's
nested solutions: `revert`, two indexed-induction proofs, and a `simp`
residual all store inner-metas whose terms are already positioned for the
enclosing λ-chain rather than for the meta's recorded `localCtx` (for
example, `refl [TBound(1), TBound(0)]` at `localCtx.level == 2` nested under
a meta at level 1). Shifting those terms by the ambient difference produces
an ill-typed proof, and the audit rejects it with `expected VNeutral, got
VType`.

Closing the gap needs one of:

- close every tactic solution over its goal context at solve time, so all
  stored solutions are closed λ-chains (this changes the tactic solver,
  which this change deliberately leaves alone), or
- a provenance-aware inliner that distinguishes an outer solution's own
  free indices from indices inside an inlined nested solution.

Until then a direct `MetaContext.solve` with an open term is safe to force
at its declaration depth and to inline at that same depth, which is what the
tactic engine does. Using such a term under additional binders is the
remaining risk.

## Where solutions are evaluated and inlined

- `_forceMetaHead`: declaration-site env, current `MetaContext` installed.
- `_tryUnify`, `_tryFlexFlexIntersect`: `inlineSolvedMetas` with
  `outerDepth: 0`, then `checkMetaSolution` under the declaration context.
- `_validateSolvedMeta`: `inlineSolvedMetas(entry.solution, metas)` with the
  default depth, checked under `installMetaContext(entry.localCtx, metas)`.
- `_finalizeDeclBindings`: `inlineSolvedMetas` over each stored binding at
  the top-level depth.

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

- The deeper-inlining gap above.
- Pattern unification remains partial (deliberate; see the audit).
- `auto` and `omega` are bounded conveniences.
- A direct `MetaContext.solve` is trusted; only `checkDeclResult`'s audit
  catches an ill-typed direct solution.
