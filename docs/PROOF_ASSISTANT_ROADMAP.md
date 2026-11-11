# Doxa: roadmap to proof assistant

## Phase 25.5: stabilize

| Task | Effort | Status |
|------|--------|--------|
| Fix formatter `impl` bug | 30 min | **Done**. `_visitImpl` outputs `impl Semigroup[Nat]` with square brackets; `_visitClassMethod` groups parameters as `(x: A, y: B)`. |
| Complete sqrt2 proof | 1 session | **Done**. `case_study.doxa` proves `sqrt2` on `Nat` through `sqrt2_parity`, `even_square_implies_even`, and well-founded induction with `strong_ind` and `nat_wf`. The proof does not use `Int`, `gcd`, or coprimality. |

---

## Phase 26: interactive proof construction

| Task | Effort | Status | Description |
|------|--------|--------|-------------|
| `:goal` REPL command | 1 session | **Done** | Start an interactive proof session. Given `theorem t : P :=`, the REPL opens a goal via the `MetaContext`. `:goal` shows the current subgoal type, context binders, and their types. |
| `:step <tactic>` | bundled | **Done** | Each `:step intro x` runs one tactic against the current goal, updates the `MetaContext`, and shows the new subgoals. When no subgoals remain, the proof term is ready. |
| `:undo` | 30 min | **Done** | Restore the previous `MetaContext` snapshot. The tactic engine supports snapshot/restore via immutable state. |
| `:print` | 15 min | **Done** | Show the proof term constructed so far. |
| `:qed` | 15 min | **Done** | Commit the proof term after checking that all subgoals are solved. |

The command surface is in `doxa_tooling/lib/src/repl.dart` and is covered by `repl_proof_test.dart`. The tutorial documents the commands.

---

## Phase 27: documentation

| Task | Effort | Status | Description |
|------|--------|--------|-------------|
| `docs/proof-guide.md` | 1 session | **Done** | Walks through the sqrt2 proof step-by-step, with goals, tactics, and verifiable blocks. |
| Update `docs/tutorial.md` | 30 min | **Done** | Documents interactive proof mode and the REPL command surface. |

---

## Kernel soundness status

The external audit (`docs/KERNEL_AUDIT_2026-09-22.md`) prioritized three surface soundness gaps. Quotient `mk`/`lift` and `typeclass`/`impl` are now rejected with `QuotientUnsupported` and `TypeclassUnsupported`; every `termination_by` is rejected with `TerminationByUnsupported`. The internal quotient and class registries remain, unreachable from the surface.

Remaining audit items:

- `Nat`/`Int` arithmetic semantics: division by zero, overflow, and remainder sign are not specified and tested.
- General pattern unification and indexed recursors beyond the current first-order refinement.
- The `TType(0)` sentinel used for mutual pre-bindings.

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

| Phase | Sessions | Cumulative | Status |
|-------|----------|------------|--------|
| 25.5 - Case study completion | 1 | 1 | Done |
| 26 - Interactive REPL | 2 | 3 | Done |
| 27 - Documentation | 1.5 | 4.5 | Done |
| 28 - Tactic expansion | 4 | 8.5 | Planned |
| 29 - Tactic automation | 5 | 13.5 | Planned |
| 30 - Gamified book | 6+ | 20+ | Planned |

Phases 25.5 through 27 are complete. Doxa has interactive proof construction and the proof guide. Phases 28 and 29 close the quality-of-life gap with mature systems. Phase 30 is the public launch.
