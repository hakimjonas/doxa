# Doxa Consolidated Plan

## Where we are

The kernel (Phases 0–14) is complete and verified:
- CIC with predicative cumulative `Type` hierarchy + impredicative `Prop`
- Inductive types with parametric/indexed families, mutual blocks, auto-derived recursors
- Dependent pattern matching with structural recursion and index refinement
- Propositional equality with proof irrelevance, singleton elimination
- Metavariables + Miller pattern unification + implicit arguments
- 42-declaration stdlib proof roster (`plus_comm`, `map_compose`, `vlength_index`, etc.)
- 766 tests, stack-safe defunctionalized driver, linear-time structural operations

The tooling stack (Phases 0–3c, see `docs/TOOLING_PLAN.md`) is complete:
- Tokenizer + syntax highlighting (rumil_tokens grammar)
- GreenNode concrete syntax tree with position queries
- Structured JSON output with per-declaration type/normal-form display
- Semantic metadata (InfoTree) — per-position type/name/scope queries
- REPL (`doxa repl`) — interactive expression evaluation + declaration accumulation
- LSP server (`doxa lsp`) — diagnostics, hover, go-to-definition, completion
- Package split: `doxa` (kernel), `doxa_tooling` (CLI + WASM + LSP + REPL)

What follows covers benchmarking, kernel hardening, and the language features
that build Doxa from a proof-checker kernel into a practical proof assistant.

This document is the **overview roadmap**. The detailed per-step breakdown
for Phases 15-22 (with prior-work study requirements, risk assessments, and
sub-step exit criteria) lives in the `develop` branch at `PLAN.md`. This
document adds new phases (14.5-14.7, benchmarking) and frames the overall
arc; the `develop` PLAN.md remains authoritative for implementation-level
detail on the phases it covers.

### Cross-cutting invariants

Every phase must preserve:

- **Backward compatibility.** No phase breaks existing checked proofs.
  `example/proofs.doxa` and `lib/stdlib/proofs.doxa` must type-check after
  every phase lands.
- **Test count.** The 766-test suite may grow but never shrinks.
- **Performance.** The checker must stay within its current 6-15ms band
  for the stdlib workload. The benchmarking interlude establishes the
  baseline; each subsequent phase's exit criteria include re-running the
  relevant benchmarks.
- **Analyze + format.** `dart analyze` 0 issues, `dart format` clean, in
  both `doxa/` and `doxa_tooling/`.

### Cross-cutting concern: Educational content

The tutorial (Phase 22 Step 3) is the final deliverable, but educational
material should grow continuously, not wait for the end. Each phase that
adds a user-visible feature (quotients in 14.5, tactics in 20, typeclasses
in 21) should include an educational fragment: an example `.doxa` file in
`docs/tutorial_examples/` that exercises the new feature with comments
explaining it. These accumulate into the final tutorial rather than being
written from scratch at Phase 22.

---

## Benchmarking Interlude (before kernel changes)

Before adding any kernel features or optimizations, measure the kernel
as it exists today. The goal is to know what Doxa *actually* needs, not
what it might hypothetically need. This runs in parallel with Phase 14.5-14.7. The existing kernel paths
(beta-reduction, conversion of existing term forms) are unchanged by
the new features — benchmarking during or after 14.5-14.7 produces
the same measurements for non-quotient code.

## Phase 14.5 — Kernel Hardening

Three kernel-level features that every mature CIC system has and that are
cheap, orthogonal, and hard to retrofit later. All three can be built in
parallel or any order.

### 14.5 — Quotient Types

**What it does.** `Quot(A: Type)(R: A → A → Prop)` — declare two terms equal by
fiat. `Quot.mk(a)` constructs a quotient element. `Quot.lift(f, proof)` lifts
a function that respects the equivalence relation. Conversion:
`lift(mk(a), f, p) ≡ f(a)`.

**Why it matters.** Unlocks real numbers (Cauchy sequences modulo equivalence),
finite sets, modular arithmetic — any construction that needs equivalence
classes. Doxa without quotients is restricted to inductive data. With
quotients it can express the mathematical structures that serious proof
development requires.

**Size.** ~200 lines of kernel code. Four new term forms (`TQuot`, `TQuotMk`,
`TQuotLift`), three new value forms, one new conversion rule. Surface syntax:
`Quot(A, R)`, `mk a`, `lift f p`.

**Soundness guard.** Singleton-elimination restriction (Phase 12) already
prevents the Lean 3 inconsistency with `Quot` + unrestricted Prop elimination
into Type. No new guard needed — the existing check covers it.

**Prior work.** Lean 4 `Quot` in `Init/Prelude.lean`. Coq `Setoid` + built-in
`Quot` (since 8.17). Agda's `Quotient` via postulate (older) or built-in
`Quot` (newer versions). All three converge on the same kernel shapes.

### 14.6 — Definitional Constructor Injectivity

**What it does.** `VConstr(c, args1) ≡ VConstr(c, args2)` → `args1[i] ≡ args2[i]`
for all `i`. If the same constructor appears on both sides of a conversion
check, the constructor's arguments are compared pointwise. This is already
true for all other value forms (`VPi`, `VLam`, `VData`, `VNeutral`) — the gap
is only `VConstr`.

**Why it matters.** Reduces proof term size for indexed-family reasoning.
Currently the elaborator must synthesize `Eq.rec` chains for every index
refinement step when pattern-matching. With kernel injectivity, the converter
handles it directly — smaller terms, faster checking, less boilerplate in the
elaborator.

**Size.** ~30 lines in `conv.dart` — one new dispatch arm in the `_Conv` step.

**Risk.** None. Constructor injectivity is a conservative extension of CIC.
Lean 4, Coq, and Agda all have it. The existing negative test that verifies
`succ_injective` is provable (not definitional) remains valid — it just
becomes *also* definitional.

### 14.7 — Reducibility Hints

**What it does.** A per-definition flag controlling whether the definition
unfolds during conversion: `transparent` (unfold always, current default),
`opaque` (never unfold). Surface syntax: `opaque val name` or similar.

**Why it matters.** Three things:
1. Fixes the `plus_zero` normalization bug (Phase 19 carry-forward) — a
   recursive function whose return type depends on the scrutinee can enter
   infinite normalization. Marking it opaque during the check of its own
   body prevents this.
2. Postulated axioms (user-asserted, unproven) should never unfold during
   conversion — marking them opaque prevents accidental unfolding.
3. Large derived definitions (auto-generated recursors, stdlib lemmas) can
   be hidden from the type-checker to speed up conversion by preventing
   deep unfolds.

**Size.** ~10 lines. One new field on `TopBindingEntry` (boolean flag), one
check in `conv.dart` before unfolding `TTop` references.

**Risk.** Low. Additive — opaque is a restriction on existing behavior, not
a new reduction rule. Existing proofs that rely on definitional unfolding
continue to work if their definitions remain `transparent`.

**Note.** `VFun` (guarded delta-reduction, Phase 13 Part F-II) already
implements a specialized form of reducibility control for recursive
functions. 14.7 generalizes this to ALL definitions.

---

### Re-benchmark after 14.5-14.7

After all three kernel-hardening phases land, re-run the benchmarking
suite to measure the impact of the new conversion rules and term forms.
Update `docs/BENCHMARKS.md` with a post-14.7 column.

---

## Timeline Estimate

Rough sizing for planning purposes. "Session" = a focused work block
(2-4 hours). Multiply by 2-3 for part-time / interrupted work.

| Phase | Sessions | Rationale |
| 14.5 (quotients) | 8-12 | ✓ Complete |
| 14.6 (injectivity) | 1-2 | ✓ Complete (tests only — kernel code already existed) |
| 14.7 (reducibility) | 1-2 | ✓ Complete |
| 15 (universe polymorphism) | 15-25 | ✓ Complete |
| 16 (SProp) | 4-6 | ✓ Complete |
| 17 (records + η) | 6-10 | ✓ Complete |
| 18 (modules + imports) | 10-15 | ✓ Complete |
| 19 (ergonomic edges) | 5-8 | ✓ Complete |
| 20 (tactics) | 8-12 | ✓ Complete |
| 21 (typeclasses) | 8-12 | ✓ Complete |
| 22 (polish + release) | 10-15 | In progress |

**Pre-v1.0 total:** ~100-140 sessions estimated, ~70-90 actual.

### Post-v1.0|

| Phase | Sessions | Rationale |
| 23 (namespace modules) | 6-8 | Gate for safe stdlib expansion |
| 24 (well-founded recursion) | 4-6 | Trigger fired (tactics exist); desugar to Acc.rec |
| 25 (stdlib expansion) | ongoing | Grows as features are used |
| **Post-v1.0 total:** | 16-22 | For structured phases 23-24 |

---

## Phase 15 — Universe Polymorphism

**Goal.** Lift the sort hierarchy from sort-monomorphic (`Type n` with
concrete level integers) to universe-polymorphic, so library code is
written once over any level.

**Prior work.** Coq's `kernel/univ.ml` (algebraic universes with constraint
graph). Lean 4's `library/level.h` (simpler per-declaration level variables).
Read both; pick one in a design note.

### Deliverables

1. `Level` datatype replacing `int` in `VType`/`TType`.
2. Level substitution, level-variable unification.
3. Sort comparison in `conv`/`subtype` handles level variables.
4. Sort-polymorphic `Eq.rec` — `Eq` takes a sort argument. UIP becomes
   statable (still not derivable via motive restriction).
5. Multi-recursor bridge (`T.rec` + `T.ind` + `T.rect`) retires — single
   sort-polymorphic `T.rec`.
6. Stdlib lemmas rewrite to universe-polymorphic style.

**Exit.** Sort-polymorphic `Eq.rec` works. `Eq[SomeProp] p q` typechecks.
Multi-recursor bridge is dead code. Stdlib compiles with polymorphic lemmas.

---

## Phase 16 — SProp + Strict Proof Irrelevance

**Goal.** A second propositional sort `SProp` with strict (definitional) proof
irrelevance — two proofs of the same `SProp`-sorted proposition are
definitionally equal, not just propositionally.

**Prior work.** Gilbert, Cockx, Sozeau & Tabareau, "Definitional
Proof-Irrelevance without K" (POPL 2019). Lean 4's SProp handling
in `src/Init/Prelude.lean`.

**Size.** New sort `SProp` alongside `Prop`/`Type n`. One additional
conversion short-circuit (same pattern as Phase 12's `_isPropSorted`).

**Exit.** SProp inductives exist, strict irrelevance fires during conversion,
Phase 12's Prop-irrelevance is unchanged.

---

## Phase 17 — Records with Definitional η

**Goal.** Record types as kernel primitives with definitional η:
`{ x := r.x, y := r.y } ≡ r`.

**Prior work.** Lean 4's `structure` + primitive projections. Coq's
`Set Primitive Projections`.

**Size.** New term/value forms: `TRecord`, `VRecord`, `TProj`, `VProj`.
One new conversion rule for η.

**Exit.** Records with η work. Anonymous construction `{ x = ..., y = ... }`.
Field projection `r.x`. Stdlib pairs/sigma types migrate from single-ctor
inductives where η matters.

---

## Phase 18 — Modules + Imports

**Goal.** Multi-file programs with qualified names and imports. The currently
monolithic stdlib reorganises into per-module files.

**Prior work.** Lean 4's `import` model (simpler than Coq's `Module`/`Require`).

**Deliverables.**
1. Qualified names: `Nat.plus` resolves to `plus` in module `Nat`.
2. `import` declaration — load and make visible another module's names.
3. `TTop` names become potentially qualified; conflict detection.
4. Stdlib reorganised: `lib/stdlib/nat.doxa`, `list.doxa`, etc. as separate
   modules. Prelude becomes auto-imported by the CLI.

**Exit.** Multi-file stdlib with imports. Existing single-file programs work
unchanged.

---

## Phase 19 — Ergonomic Edges

**Goal.** Close ergonomic gaps that aren't critical path but accumulate as
user friction.

### Items

1. **Local `let rec`** inside expressions. Reuses Phase 11's structural
   recursion check.
2. **Per-member `{struct <name>}` annotation** for non-first decreasing
   arguments in mutual blocks.
3. **`plus_zero` match normalization bug** (carried forward from Phase 12
   interlude). May be fixed by Phase 14.7's reducibility hints — revisit
   after that lands.
4. Other elaborator polish surfaced during Phases 15–18.

**Exit.** Phase 11/12 carry-forwards closed.

---

## Phase 20 — Tactics

**Goal.** A minimal tactic engine and library. Users write `theorem ... :=
by { tactics }` and Doxa produces the proof term.

**Prior work.** Lean 4's tactic framework (`Lean/Elab/Tactic/*`). The
meta-context (Phase 13) is already the observable protocol that tactics
manipulate.

### Tactics (initial set)

| Tactic | What it does |
|---|---|
| `intro` | Introduces a Pi binder |
| `exact term` | Provides an explicit proof |
| `apply f` | Applies a lemma, producing subgoals for its arguments |
| `refl` | Closes `Eq A x x` by auto-`refl` |
| `rewrite p` | Rewrites with an equation |
| `induction x` | Produces subgoals per constructor of `x`'s type |
| `trivial` | Tries `refl` + trivially-true lookups |

### Surface

- `theorem name : T := by { intro n; induction n; refl; rewrite ih }` syntax.
- Tactics compose via `;` (sequence) and `<|>` (alternative).
- Meta-context snapshot/restore for tactic backtracking.

**Exit.** User writes `plus_comm` via `induction m; refl; rewrite ih` and
gets a valid proof term.

---

## Phase 21 — Typeclasses + Instance Search

**Goal.** Typeclass-style polymorphism with instance search, built on
Phase 13's pattern unifier.

**Prior work.** Lean 4's `Meta/TypeClass.lean`. Agda's `instance` arguments.

**Deliverables.**
1. Instance arguments: `{{C: Monoid A}}` in signatures.
2. Instance resolution: consults per-class instance table, unifies candidate.
3. Stdlib uses: `deriving Eq`-decidability, `Functor`/`Monad`/`Monoid`
   instances.

**Exit.** Polymorphic lemmas with class constraints work. Stdlib uses
instances where it helps.

---

## Phase 22 — Final Polish + Release

**Goal.** Ship Doxa.

### Steps

1. **SPEC-wide correctness-coverage audit.** Walk every SPEC clause, verify
   each maps to at least one test. Close gaps.
2. **Diagnostic polish.** Every error kind has a golden test. Tier-2
   binder-name propagation (user names in error messages instead of
   placeholders). Manual walkthrough of all negative-program diagnostics.
3. **Tutorial.** `docs/tutorial.md` — ML-family-programmer-aimed, runnable
    example code, covering declarations → inductives → match → Eq → tactics.
    Every code block is a verified `.doxa` file. Educational fragments from
    earlier phases (quotient examples from 14.5, record examples from 17,
    tactic examples from 20) are woven in — the tutorial is assembled from
    accumulated material, not written from scratch.
4. **Browser demo.** Refresh arda-web with WASM compiled from `doxa_tooling`.
   Expandable declaration view, structured error display, share-link support.
5. **Release.** Release notes. Tag `v1.0.0`. Update documentation.

**Exit.** Reader clones the repo, reads the tutorial, writes a proof using
tactics, gets helpful diagnostics on mistakes, and shares a browser link.

---

## Deferred Decisions

These are questions we mean to answer later, once more data exists. They are
not commitment gaps — they are explicitly deferred to the benchmarking
interlude or to a later phase's design note.

### Well-Founded Recursion

Structural recursion (Phase 11) covers most functions, but genuinely
well-founded functions (Ackermann, Euclidean algorithm, quicksort partition)
need a termination metric. Lean 4 has `termination_by`; Coq has
`well_founded_induction`.

**Deferred to:** after Phase 20 (tactics). The tactic engine will generate
proof terms with explicit accessibility proofs; the elaborator can synthesize
them from termination metrics once tactics exist. Not a kernel change until
a `TWFix` term form is needed for reduction — the elaborator can desugar to
`Acc.rec` without kernel changes.

**Decision trigger.** When the stdlib needs a function that can't be written
with structural recursion (e.g., `gcd` via Euclid's algorithm), revisit.

### Native Numerics (Primitive `Nat` / `Int`)

Inductive `Nat` works for current proofs. The question is whether
large-constant computation (primality proofs, large-array indexing) needs
faster reduction.

**Deferred to:** after the benchmarking interlude. If inductive `Nat` on
depth-10000 Church numerals shows unacceptable time, measure the evaluator
path and decide between:
- **Evaluator optimization (Coq-style):** Compile `Nat.rec` into a fast loop
  without changing the term language. Same semantics, faster reduction.
- **Kernel primitive (Lean-style):** New term forms with native reduction
  rules. Changes the term language and conversion.

**Decision trigger.** When the benchmarking data shows inductive `Nat`
reduction as a measurable bottleneck.

### Stdlib Expansion

Phase 14's stdlib is 324 lines — a proof-of-concept. A real stdlib needs
integers (`Int` via Nat pairs), rationals (`Rat` via Int × Nat), finite
sets (needs quotients from 14.5), algebraic structures with typeclasses
(Phase 21), and decidability instances.

**Deferred to:** continuous development. The stdlib is not a phased
deliverable — it grows as features land. Each new phase enables new library
modules. Tracked outside the phase plan.

### Coinductive Types

Coq and Agda have them for infinite structures and productivity-based
reasoning. Lean 4 does not. Adding them to Doxa requires a productivity
checker (dual to the termination checker, Phase 11) — a substantial new
kernel pass.

**Deferred to:** post-Phase 22. No use case within Doxa's proof-checker
scope. Revisit if a concrete application emerges.

---

## Dependency Graph

```
14 (kernel complete)
 │
 ├─ Benchmarking ── (measures kernel, runs alongside 14.5-14.7)
 │   │               results inform implementation decisions
 │   └──────────────────────────────────────────────┐
 │                                                   │
 ├─ 14.5 (quotients) ──┐                            │
 ├─ 14.6 (injectivity)─┤  all three in parallel     │
 └─ 14.7 (reducibility)┘  or any order              │
        │                                            │
        ├── Re-benchmark (measure post-14.7 kernel) ─┘
        │
        ├─ 15 (universe polymorphism)
        │   └─ 16 (SProp)
        │       └─ 17 (records + η)
        │           └─ 18 (modules + imports)
        │               └─ 19 (ergonomic edges)
        │                   └─ 20 (tactics)
        │                       └─ 21 (typeclasses)
        │                           └─ 22 (audit + polish + release)
        │
        └─ Deferred decisions → promoted to post-v1.0 (below)

Post-v1.0
        │
        ├─ 23 (namespace modules)
        │   └─ 25 (stdlib expansion)
        │
        └─ 24 (well-founded recursion) — independent of 23
            └─ 25 (stdlib expansion)

Deferred (still pending):
        └─ Native numerics (bottleneck not yet observed)
        └─ Coinductive types (no use case)
```

Phases 14.5–14.7 are independent of each other. Phases 15–22 are linear.
Post-v1.0: Phase 23 gates safe stdlib expansion; Phase 24 is independent
but benefits from namespace qualification.
alongside 14.5–14.7 — the existing kernel code paths are unchanged by
the new features. A re-benchmark after 14.7 measures the delta.
Each subsequent phase re-runs relevant benchmarks as part of its exit
criteria.

---

## Non-Goals (reconfirmed)

- **Mutable state, effects, IO** in the object language. Doxa is total
  and pure.
- **Homotopy Type Theory, Cubical Type Theory, univalence.** Different
  kernel, different project.
- **Full higher-order unification.** Pattern fragment only (Miller 1991,
  Kovács elaboration-zoo).
- **Classical axioms in the kernel.** Users may postulate; the kernel
  stays axiom-free so constructivity is preserved.
- **Extraction to other languages.** If extraction is ever wanted, it
  lives in a separate project.

---

## Post-v1.0 Roadmap

After Phase 22 (Polish + Release), Doxa ships v1.0.0 with all 22 pre-release
phases complete. The post-v1.0 roadmap addresses capability gaps that emerged
now that the full feature set is in place, and ergonomic gaps that became
visible as the stdlib grew.

### Phase 23 — Namespace-Qualified Modules

**Goal.** `Nat.plus` resolves to `plus` in module `Nat` without polluting
the flat namespace. Selective imports keep the current ergonomics;
qualified names remove collision risk.

**Why first.** Phase 18 (imports) uses a flat namespace: every imported
name is visible unqualified. As the stdlib expands, name collisions become
inevitable (`plus` in `Nat` and `Int`). Namespace qualification is the gate
for safe stdlib expansion.

**Deliverables.**
1. `TTop` gains an optional namespace prefix.
2. `import "nat.doxa"` makes names available unqualified (current behaviour)
   AND qualified as `Nat.<name>`.
3. `import "nat.doxa" as N` creates the alias `N.<name>`.
4. Duplicate unqualified names error; qualified names never collide.
5. Kernel resolution in `_Eval(TTop)`/`_Infer(TTop)` checks both qualified
   and unqualified name registries.

**Size.** ~60 lines across 4 files. No new kernel term forms — the namespace
prefix is a resolution key, not a structure.

**Session estimate.** 6-8.

### Phase 24 — Well-Founded Recursion

**Goal.** Write functions that terminate by a well-founded measure
(Euclid's algorithm, Ackermann) with a `termination_by` annotation.
Desugars to `Acc.rec` — no kernel changes.

**Why now.** The plan deferred this to "after Phase 20 (tactics)." Tactics
(Phase 20) can synthesize `Acc.rec` proof terms. The elaborator just needs
a desugaring pass. Structural recursion (Phase 11) already provides the
termination checker infrastructure.

**Deliverables.**
1. `termination_by (m, n)` annotation on `fun` declarations.
2. Elaborator desugars to `Acc.rec` with accessibility proofs.
3. Minimal `Acc` inductive in the prelude.

**Size.** ~40 lines across 3 files.

**Session estimate.** 4-6.

### Phase 25 — Stdlib Expansion (ongoing)

**Goal.** Build a proof library that demonstrates Doxa's full feature set.

**Modules to add:**

| Module | Contents |
|--------|----------|
| `Int` | `data Int = Pos Nat \| Neg Nat` with arithmetic |
| `Rat` | `data Rat = MkRat Int (pos: Nat)` with field operations |
| `Sigma` | Dependent pair with primitive projections |
| `Semigroup`/`Monoid`/`Group` | Algebraic hierarchy via typeclasses |
| `DecEq` | Decidable equality typeclass + instances |

**Plus:** more lemmas (`mult_comm`, `mult_assoc`, `plus_assoc`, `distrib`,
`gcd_spec`), more induction examples, and decidability proofs.

**Not included.** Real numbers, topology, category theory — these are for
the community to build on top of the kernel.

### Dependency

```
Phase 23 (namespaces)
  │
  ├─ Phase 24 (well-founded recursion) — independent, benefits from namespaces
  │
  └─ Phase 25 (stdlib) — needs namespaces for safe expansion
```

**Total post-v1.0 estimate:** 16-22 sessions for the structured phases (23-24),
plus ongoing stdlib development.

---

## Deferred Decisions (re-evaluated post-Phase 21)

The original deferred decisions were made when Doxa was at Phase 14. With the
full feature set now in place (Phases 15-21 complete), several have been
re-evaluated:

- **Well-founded recursion**: Decision trigger fired (tactics now exist).
  Promoted to Phase 24 on the post-v1.0 roadmap.

- **Native numerics**: Inductive `Nat` remains adequate for the current
  stdlib. Benchmarking data (Phase 17) shows Church depth 5000 at 1.5s AOT
  — not a bottleneck. Stays deferred; resurfaces if expanded stdlib does
  primality or large-array proofs.

- **Stdlib expansion**: No longer deferred — all enabling features have
  landed (typeclasses Phase 21, quotients 14.5, SProp 16, projections 17,
  opacity 14.7). Promoted to Phase 25 on the post-v1.0 roadmap.

- **Coinductive types**: Still no use case. Lean 4 does not have them
  either. Stays deferred.

## References

- Coquand & Huet 1990: "The Calculus of Constructions"
- Paulin-Mohring 1993: "Inductive Definitions in the system Coq"
- Cockx & Abel 2018: "Eliminating Dependent Pattern Matching without K"
- Gilbert et al. 2019: "Definitional Proof-Irrelevance without K"
- Sozeau & Tabareau 2014: "Universe Polymorphism in Coq"
- Miller 1991: "A Logic Programming Language with Lambda-Abstraction"
- Kovács: "elaboration-zoo" — bidirectional elaboration with implicits
- Lean 4: `Lean/Server/README.md`, `Lean/Elab/Tactic/*`, `Init/Prelude.lean`
- rust-analyzer: "Three Architectures for a Responsive IDE" (matklad 2020)
- rumil-dart: `hakimjonas/rumil-dart` — parser combinators with
  GreenNode/RedTree, incremental reparse, Pratt precedence
- LSP Specification: `microsoft.github.io/language-server-protocol`
