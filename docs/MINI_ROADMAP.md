# Mini Roadmap — Post-Rebase Audit Fixes

> Generated 2026-08-09. Ordered by priority.

## 1. Fix hanging kernel test (critical)

**Test:** `check_test.dart` — "infer on 10,000-nested Lam does not blow the stack"
**Symptom:** Runs 2+ minutes; expected <1s. Companion 100,000-nested test (<5s expected) likely also broken.
**Likely cause:** `bodyIsNormal` fast path bypassed after `_codomainHasBinders` guard (commit `5b72b7d`) or `_QPiCod` depth-mismatch fixes (`c049891`, `a580114`).
**Impact:** Blocks `dart test` suite. Checker may be O(n²) instead of O(n).

## 2. Wire rewrite + induction to REPL proof mode (high)

**File:** `doxa_tooling/lib/src/repl.dart`
**Problem:** `:step rewrite` and `:step induction` return "not yet implemented in this version" (2 occurrences). Tactic implementations exist in `tactic.dart`.
**Estimate:** 30 min (Phase 27.5 Task 2).

## 3. Replace tactic conv with kernel _Conv (high)

**File:** `doxa/lib/src/tactic.dart` (`_driveConvert`)
**Problem:** Uses naive structural term equality (`quote + term equality`) instead of the kernel's full `_Conv` with WHNF normalization, eta, and proof irrelevance. `refl` and `trivial` tactics miss definitional equalities.
**Estimate:** 1 session (Phase 27.5 Task 3).

## 4. Cleanup stale comments (low)

**File:** `lib/stdlib/case_study.doxa` lines 126-143
**Problem:** "--- Remaining lemmas (to be completed)" header and commented-out stubs — all four lemmas are actually implemented.
**Estimate:** 5 minutes.

## 5. Missing tactics (medium)

- `cases` — destruct inductive hypothesis into subgoals (Phase 27.5 Task 4)
- `constructor` — build first constructor of goal (Phase 27.5 Task 5)
- `simpl` — normalize goal via `nf()` (Phase 27.5 Task 6)

## 6. Missing Prop connectives (medium)

- `∃`, `∧`, `∨`, `¬` as Prop-sorted inductives (Phase 27.5 Task 7)

## 7. Verify Acc.rec status (medium)

- Commits `79af70e` and `f6e4fc9` claim fixes but need verification
- sqrt2 proof uses `strong_ind` via `Nat.ind`, not `Acc.rec`
