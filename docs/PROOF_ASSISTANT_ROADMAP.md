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

The external audit (`docs/KERNEL_AUDIT_2026-09-22.md`) prioritized three
surface soundness gaps. Quotients are complete for the first slice: `mk`,
`lift`, and `Quot.sound` are checked, with the relation checked at formation
and no propositional eliminator. `decreases` checks a lexicographic measure
over named value parameters. Typeclasses were implemented after the audit
(#14, #15, #19); the remaining limits are in Phase 29.5.

Remaining audit items:

- General pattern unification and indexed recursors beyond the current
  first-order refinement.

The arithmetic semantics are specified in `docs/arithmetic.md` and tested, and
#7 replaced the `TType(0)` sentinel with an explicit unknown marker.

---

## Phase 28 — Tactic expansion

| Task | Effort | Status | Description |
|------|--------|--------|-------------|
| `apply` with hole-filling | 1-2 sessions | **Done** | `apply f` creates one goal per explicit argument, in argument order; implicit arguments are filled by conversion and do not become goals. |
| `:search <pattern>` | 1 session | **Done** | Search scope (bindings + dataDecls + imported modules) for lemmas whose conclusion type structurally contains `<pattern>`. Uses `:browse` infrastructure. |
| `simp` tactic | 1 session | **Done** | Normalises the goal and rewrites with equality hypotheses. Explicit lemmas only; no attributes; no rewriting under a goal-type lambda. |

---

## Phase 29 — Tactic automation

| Task | Effort | Status | Description |
|------|--------|--------|-------------|
| `auto` tactic | 2-3 sessions | **Done** | Depth-bounded search: tries `refl`, `trivial`, then `apply` on lemmas in scope. Depth 0 to 20; default 5. |
| `omega`-style arithmetic | 2-3 sessions | **Done** | Normalises both sides and tries the arithmetic lemmas in scope. Lemma matching, not a decision procedure. |

---

## Phase 29.5 — Typeclasses

| Task | Status |
|------|--------|
| Declarations, instances, and instance search | **Done** |
| Parameterised instances and recursive dictionary discharge | **Done** |
| Multi-method classes | **Done** |
| Superclasses | **Done** |
| Local instances | **Done** |
| Class-qualified projections and bare-name resolution | **Done** |
| `Ring` and the `Ring[Int]` instance | **Done** |
| camelCase naming pass | Open |
| Default method bodies | Open |
| Multi-parameter classes | **Done** |

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
| 28 - Tactic expansion | 4 | 8.5 | Done |
| 29 - Tactic automation | 5 | 13.5 | Done |
| 29.5 - Typeclasses | 3 | 16.5 | Done, with the open items above |
| Documentation and doc-block gate | 1 | 17.5 | Done |
| 30 - Gamified book | 6+ | 23.5+ | Planned |

Phases 25.5 through 29.5 are complete, as is the documentation and doc-block
pass. Phase 30 is the public launch. The known gaps below remain.

## Known gaps

- A module declares at most one product-form record; every product-form
  declaration desugars to `mk`.
- Constructor names share a global namespace, so records cannot each declare
  `mk`.
- Quotients have no propositional eliminator (`Quot.ind`), and their carrier
  and lift result types are at `Type 0` because `Eq`'s carrier is.
- `decreases (p1, ..., pn)` checks a lexicographic measure over named value
  parameters. Arithmetic measures such as `sub m n`, mutual blocks, and
  general measure expressions are not supported.
