# Phase 26 — Interactive Proof Construction

## Guiding principle

The interactive REPL is a step-by-step rendering of a file-based `by { ... }` block.
Every `:step` is one line of a tactic sequence. No new proving power — same kernel,
same tactics, same elaboration. The REPL just splits `by { step1; step2; step3 }`
across user interactions with inspection between steps.

## State machine

```
idle ──:goal theorem t : P :=──▶ proving ──:qed──▶ idle (+ t in scope)
                                      │
                                    :abort──▶ idle
```

In `proving` state only the following are accepted:
- `:step`, `:undo`, `:print`, `:goal` (show), `:abort`, `:qed`
- Read-only meta-commands: `:browse`, `:search`, `:type`, `:norm`
- Declarations and expressions are rejected.

## Files changed

| File | What |
|------|------|
| `doxa/lib/src/meta.dart` | Snapshot/restore API on `MetaContext` |
| `doxa/lib/src/tactic.dart` | Optional `name` parameter on `intro` |
| `doxa/lib/src/elab.dart` | Public `elabExprInScope` for expression elaboration with local binders |
| `doxa_tooling/lib/src/repl.dart` | `_ProofSession`, proof-mode meta-commands |
| `doxa_tooling/bin/doxa.dart` | Banner text |
| `doxa/test/meta_snapshot_test.dart` | Snapshot tests |
| `doxa_tooling/test/repl_proof_test.dart` | Proof-mode tests |

## 1. MetaContext snapshot/restore (`meta.dart`)

The `MetaContext` has append-only entries with solve-once mutation. A snapshot captures
enough state to exactly revert a `:step`.

```dart
/// A point-in-time capture of [MetaContext] state.
///
/// Records the entries-list length and, for each meta that was solved,
/// the solution term. On restore, entries are truncated to the recorded
/// length and each entry's solve state is matched to the snapshot.
final class _MetaSnapshot {
  final int entriesLength;
  final Map<int, Term> solved;  // meta id → solution term
  const _MetaSnapshot(this.entriesLength, this.solved);
}
```

- `MetaContext.snapshot()` — walks `_entries`, records `(length, {id → solution})`.
- `MetaContext.restore(_MetaSnapshot snap)` — truncates `_entries` to
  `snap.entriesLength`, then for each index: if the snapshot says solved,
  re-solve it; if the snapshot says unsolved, revert any solved entry to unsolved.

This preserves the solve-once invariant: restore only ever transitions
`solved → unsolved` or `unsolved → solved` for entries that were created
before the snapshot boundary.

## 2. Intro name parameter (`tactic.dart`)

```dart
TacticResult intro(TacticState s, {String? name})
```

`freshName = name ?? pi.name ?? 'h'`. Existing callers in `elab.dart` pass
no name — behavior unchanged. The REPL passes the user-supplied name from
`:step intro x`.

## 3. Expression elaboration with locals (`elab.dart`)

```dart
/// Elaborate [expr] against [topEnv] with local binder [names] (innermost first).
///
/// Constructs a [_LocalScope] from [names] and delegates to [_elabExpr].
/// The shim-Ctx uses placeholder types for local binders; the resulting term
/// has correct de Bruijn indices. The calling tactic's own [infer] pass uses
/// the real [TacticState.ctx] for type checking.
Term elabExprInScope(
  TopEnv topEnv,
  List<String> localNames,
  SExpr expr, {
  MetaContext? metas,
})
```

The REPL uses this for `:step exact e` and `:step apply f`. Additionally,
it falls back to direct de Bruijn lookup (`TBound(idx)`) for simple identifiers,
mirroring the pattern in `_runExact`.

## 4. Proof session (`repl.dart`)

### `_ProofSession` (mutable, internal)

```
metas: MetaContext
undoStack: List<_ProofSnapshot>
rootGoalMetaId: int
currentGoalMeta: int
ctx: Ctx
binderNames: List<String>          // innermost first
topEnv: TopEnv                     // snapshot at :goal time
theoremName: String
theoremType: Term                  // quoted, for TopBinding
```

### `_ProofSnapshot`

```
metaSnapshot: _MetaSnapshot    // from MetaContext.snapshot()
currentGoalMeta: int
ctx: Ctx                       // pointer into immutable Ctx list
binderNames: List<String>
```

`Ctx` and `List<String>` are immutable, so snapshot stores references.
Only `MetaContext` needs explicit snapshot/restore.

### `ReplSession`

Gains a `final _ProofSession? _proofState` field.

- On `:goal` — returns a new `ReplSession` (non-const) with `_proofState` set.
- On proof commands — mutates `_proofState` in-place, returns `this`.
- On `:qed` — returns a new `ReplSession` with the theorem binding added and
  `_proofState = null`.
- On `:abort` — clears `_proofState`, returns `this`.

Bindings and dataDecls never change during proof mode, so the
ReplSession-immutability contract is preserved at the user-observable level.

### Command handlers

#### `:goal theorem t : P :=`

1. Parse `theorem t : P :=` via `parseDecl`.
2. Elaborate the type `P` against the current TopEnv via `elabExpr`.
3. Use `topEnv.toCtx()` as the base Ctx.
4. Create a fresh `MetaContext` and a goal meta for the elaborated type.
5. Store `rootGoalMetaId = currentGoalMeta = goalMetaId`.
6. Display the goal type and context (empty initially).
7. Return new `ReplSession` with `_proofState` set.

Before entering proof mode, snapshot the current `TopEnv` so the proof
sees a fixed scope. Reject `:goal` while already in proof mode.

#### `:goal` (no args, in proof mode)

Display the current unsolved goal. For each binder in `ctx` (innermost first),
quote its type at the appropriate level and pretty-print. Show:

```
Goal:
  A -> A
Context:
  x : A
  A : Type
```

If the goal is already solved and no subgoals remain, indicate "Proof complete."

#### `:step intro [name]`

1. Take a `_ProofSnapshot` of current state.
2. Call `intro(tstate, name: name)`.
3. On `TacticFail` — report error, discard snapshot, stay in proof mode.
4. On `TacticOk(term, metas, subMeta:)`:
   - `metas.solve(currentGoalMeta, term)`
   - Push snapshot to `undoStack`.
   - Set `currentGoalMeta = subMeta`.
   - Update `ctx` and `binderNames` to reflect the new binder.
   - Display introduced binder name, new goal type, and updated context.

If no subgoal remains (proof complete), display "Goal solved. Use :qed to commit."

#### `:step exact e`

1. Parse `e` with `parseExpr`.
2. Elaborate via `elabExprInScope`; fall back to `TBound(idx)` for simple identifiers.
3. Take a `_ProofSnapshot`.
4. Call `exact(term)(tstate)`.
5. On success: push snapshot, display "Goal solved…".
6. On failure: report error, discard snapshot.

#### `:step apply f`

Same pattern. Uses `tacticApply(term)(tstate)`. For Phase 26 this only
handles exact-conclusion matches (no subgoal generation — that's Phase 28).

#### `:step refl`

Snapshot, call `refl(tstate)`, same success/failure pattern.

#### `:step trivial`

Snapshot, call `trivial(tstate)`, same pattern.

#### `:step rewrite p` / `:step induction x`

Report "not yet implemented" (matching the file-based behavior).

#### `:undo`

1. Pop `_ProofSnapshot` from `undoStack`.
2. `metas.restore(snapshot.metaSnapshot)`.
3. Restore `currentGoalMeta`, `ctx`, `binderNames` from snapshot.
4. Display the restored goal via `:goal` (show) logic.

Error if undo stack is empty.

#### `:print`

1. Start from `rootGoalMetaId`.
2. Walk the solution chain via `inlineSolvedMetas(metas)`.
3. Unsolved metas rendered as `?id` in the output.
4. Pretty-print the resulting term.

No proof in progress → error.

#### `:qed`

1. Walk from `rootGoalMetaId`; collect all unsolved metas.
2. If any unsolved metas remain → error "Proof incomplete: N subgoal(s) remain."
3. `inlineSolvedMetas` to get the final proof term.
4. `infer(ctx, finalTerm)` and `conv(level, inferred, theoremTypeValue)`.
5. On type mismatch → error with diagnostic.
6. Create `TopBinding(name: theoremName, type: theoremType, term: finalTerm, …)`.
7. Return new `ReplSession` with binding added and `_proofState = null`.
8. Display the theorem signature (name + type).

#### `:abort`

1. Clear `_proofState` to null.
2. Return `this` (session unchanged).
3. Display "Proof aborted."

### Edge-case errors

| Condition | Message |
|-----------|---------|
| `:step` without `:goal` | "No proof in progress. Use :goal to start." |
| `:goal` while proving | "Already in proof mode. Use :qed, :abort, or :undo." |
| `:undo` with empty stack | "Nothing to undo." |
| `:qed` unsolved metas | "Proof incomplete: N subgoal(s) remain." |
| `:qed` type mismatch | "QED failed: {error}" |
| `:print` without proof | "No proof in progress." |
| Declaration during proof | "Cannot add declarations during a proof." |

## 5. Help text

Update `:help` output and the REPL banner to list new commands.

## 6. Tests

### `doxa/test/meta_snapshot_test.dart`

- Snapshot/restore round-trip: create metas, solve some, snapshot, mutate, restore.
- Undo after `intro`: snapshot before intro, simulate intro, verify restore gives
  pre-intro state.

### `doxa_tooling/test/repl_proof_test.dart`

- **identity**: `:goal theorem id : (A: Type) -> A -> A :=` →
  `:step intro A` → `:step intro x` → `:step exact x` → `:qed` →
  `:browse` shows `id`.
- **refl**: seed a data decl for `Bool`/`Eq`, `:goal theorem t : Eq Bool true_ true_ :=` →
  `:step refl` → `:qed`.
- **step without goal**: `:step intro x` → error.
- **undo**: `:goal` → `:step intro A` → `:undo` → goal reverts to original.
- **undo empty stack**: `:undo` immediately after `:goal` → error.
- **print mid-proof**: `:goal` → `:step intro A` → `:print` shows `λ A : Type. ?1`.
- **qed incomplete**: `:goal` → `:qed` (no steps taken) → error.
- **abort**: `:goal` → `:step intro A` → `:abort` → proof cleared, `:qed` errors.
- **read-only during proof**: `:browse`, `:search`, `:type`, `:norm` all work in proof mode.
- **declaration during proof**: `val x : Bool = true_` → rejected with message.

## 7. Out of scope (by principled deferral)

- `apply` with subgoal generation — Phase 28.
- `rewrite` implementation — Phase 28.
- `induction` implementation — Phase 28.
- Subgoal focusing — not needed until `apply` generates multiple subgoals.
- Expression elaboration with real `Ctx` types — placeholder-shim is correct
  for Phase 26 scope; upgrade when complex implicit resolution is needed.

## 8. Invariants to preserve

1. A proof constructed interactively via `:step` and ended with `:qed` produces
   the same `TopBinding` as the equivalent `val t : P = by { … }` in a file.
2. `:undo` exactly reverses the last successful `:step` — metas, Ctx, binderNames
   all match the pre-step state.
3. `:abort` leaves zero trace — no metas, no bindings, no state.
4. `ReplSession` bindings and dataDecls are unchanged by any proof command
   except `:qed`, which appends exactly one binding.
5. Failed `:step` does not mutate any state (snapshot is discarded before
   the tactic runs, and on failure nothing is pushed to the undo stack).
