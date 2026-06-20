# Doxa — Roadmap to Proof Assistant

## Phase 25.5 — Stabilize

| Task | Effort | Status |
|------|--------|--------|
| Fix formatter `impl` bug | 30 min | **Done** — `_visitImpl` outputs `impl Semigroup[Nat]` with square brackets; `_visitClassMethod` groups params in single parens `(x: A, y: B)` |
| Complete sqrt2 proof | 1 session | **Not done** — `case_study.doxa` defines `even`, `twice`, `square`, and base-case parity facts (0-3) but does not prove the key lemma or the final contradiction |

**Case-study remaining work:**
- Lemma: if `even n = false_` then `even (square n) = false_` (odd squared is odd). Proved by induction on `n` using `even`'s alternating structure.
- Lemma: if `even (square n) = true_` then `even n = true_` (contrapositive). Follows from the above.
- Lemma: if `mult n n = mult 2 (mult k k)` and `even n = false_`, then `False`. Uses `even_sq_false`.
- Main theorem skeleton: assume `Rational` representation `(a, b)` with `gcd a b = 1` and `mult a a = mult 2 (mult b b)`. Derive contradiction via parity. Note: this requires `Int` and `gcd` which are out of scope for the current stdlib.

**Recommendation:** The sqrt2 proof in full generality needs `Int` (for subtraction when reasoning about coprimality) and `gcd` (or at least a divisibility relation on `Nat`). The Doxa stdlib has `Int` but no `gcd`. Two options:
- **Option A:** Prove sqrt2 directly on `Nat` without coprimality: show that `∀ a b, a² ≠ 2·b²` by induction on `a`. This avoids `Int`, `gcd`, and rationals entirely. The proof is: if `a² = 2·b²`, then `a` is even, so `a = 2k`, so `4k² = 2b²` → `2k² = b²`, so `b` is even, so `a = 2a'` and `b = 2b'`, then descending induction on `a` yields contradiction.
- **Option B:** Add `gcd` to the stdlib and do the full proof with coprimality.

Option A is self-contained and fits in ~60 lines. Option B is more traditional but requires an additional stdlib module.

---

## Phase 26 — Interactive proof construction

| Task | Effort | Description |
|------|--------|-------------|
| `:goal` REPL command | 1 session | Start interactive proof session. Given `theorem t : P :=`, the REPL opens a goal via the `MetaContext`. `:goal` shows the current subgoal type, context binders, and their types. |
| `:step <tactic>` | (bundled) | Each `:step intro x` runs one tactic against the current goal, updates the `MetaContext`, and shows the new subgoals. When no subgoals remain, the proof term is ready. |
| `:undo` | 30 min | Restore the previous `MetaContext` snapshot. The tactic engine already supports snapshot/restore via immutable state. |
| `:print` | 15 min | Show the proof term constructed so far. Useful for debugging before `:qed`. |
| `:qed` | 15 min | Commit the proof term. Checks all subgoals solved, adds the binding to the REPL session. |

**Architecture:** The `:goal`/`:step` loop uses the existing `TacticState` and `MetaContext`. The REPL session holds a snapshot chain for `:undo`. No kernel changes.

---

## Phase 27 — Documentation

| Task | Effort | Description |
|------|--------|-------------|
| `docs/proof-guide.md` | 1 session | Walk through the sqrt2 proof step-by-step. Each step: strategic explanation → show current goal → apply tactic → show new subgoals. Every block verifiable. |
| Update `docs/tutorial.md` | 30 min | Add section on interactive proof mode. Reference the proof guide. Update installation to mention `doxa lsp` + VS Code extension. |

---

## Phase 28 — Tactic expansion

| Task | Effort | Description |
|------|--------|-------------|
| `apply` with hole-filling | 1-2 sessions | Current `apply f` requires exact match of conclusion to goal. Expansion: if `f : A → B → C` and goal is `C`, create two fresh subgoal metas for `A` and `B`. Return `f ?a ?b` as partial proof term with `?a`, `?b` as new goals. The `MetaContext` already supports this pattern. |
| `:search <pattern>` | 1 session | Search scope (bindings + dataDecls + imported modules) for lemmas whose conclusion type structurally contains `<pattern>`. Uses `:browse` infrastructure. |
| `simp` tactic | 1 session | Normalize the goal via `nf`/`conv`. Reduces `plus zero n` to `n`, `refl`-applied terms, etc. Single-pass rewrite against a built-in set of simplification lemmas. |

---

## Phase 29 — Tactic automation

| Task | Effort | Description |
|------|--------|-------------|
| `auto` tactic | 2-3 sessions | Depth-bounded search: try `refl`, `trivial`, then `apply` on every lemma in scope. Configurable depth limit and recursion guard. Returns solved proof term or failure. |
| `omega`-style arithmetic | 2-3 sessions | Decision procedure for Presburger arithmetic on `Nat` and `Int`. Normalizes to canonical form, then syntactically compares. Closes goals like `plus_comm`, `plus_assoc` automatically. |

---

## Phase 30 — Gamified book (browser)

| Task | Effort | Description |
|------|--------|-------------|
| `book/` directory | Ongoing | Single-page web application embedding `doxa_check.wasm` into an interactive textbook. |
| Chapter structure | — | Types, functions, data, pattern matching, equality, induction, tactics. Each: read → see example → solve exercise → check in-browser → unlock next. |
| Check-on-type | — | Live editor on every page. Inline WASM checker runs client-side. Correct solutions unlock the next chapter. |
| Gamification | — | Achievements (first proof, first induction, first contradiction). Progress persistence via `localStorage`. Optional leaderboard. |
| Technical | — | Static HTML/CSS/JS. No backend. WASM binary (329KB) already built. State in `localStorage`. |

---

## Session estimates

| Phase | Sessions | Cumulative |
|-------|----------|------------|
| 25.5 — Case study completion | 1 | 1 |
| 26 — Interactive REPL | 2 | 3 |
| 27 — Documentation | 1.5 | 4.5 |
| 28 — Tactic expansion | 4 | 8.5 |
| 29 — Tactic automation | 5 | 13.5 |
| 30 — Gamified book | 6+ | 20+ |

After Phase 27, Doxa is a credible proof assistant with interactive proof construction and proper documentation. Phases 28-29 close the quality-of-life gap with mature systems. Phase 30 is the public launch.
