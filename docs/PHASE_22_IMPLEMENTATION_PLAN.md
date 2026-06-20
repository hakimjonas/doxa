# Phase 22 — Polish + Release

Final phase. No kernel changes — audit, documentation, tutorial, browser demo,
and release tagging. ~10-15 sessions.

**Writing standard:** The implementer must use the `domain-writing` skill
(shiped with opencode, `~/.config/opencode/skills/domain-writing/SKILL.md`).
All prose — SPEC audit notes, tutorial, release notes — must pass the
Anti-AI-Language Checklist and Precision Checklist in that skill.

---

## Step 1 — SPEC Correctness-Coverage Audit

Walk every clause in `SPEC.md` and verify it maps to at least one test.
Close any coverage gaps found.

### Procedure

1. Read `SPEC.md` section by section.
2. For each specification clause, search the test suite for a corresponding
   test case. Record the mapping in a `docs/SPEC_COVERAGE.md` file:

   | SPEC clause | Test file | Test name | Covers? |
   |-------------|-----------|-----------|---------|
   | §4.3 VType × VType strict equality | `doxa/test/conv_test.dart` | `universe-equality` | Yes |
   | ... | ... | ... | ... |

3. For any clause without a test, write one or note the reason it's untested
   (e.g., `implicitly tested via stdlib/proofs.doxa`, `theorem from POPL 2019
   paper — guaranteed by design`).
4. For any clause that the implementation doesn't actually satisfy, flag it
   as a SPEC bug (the spec is wrong about the implementation) or an
   implementation gap (fix before release).

### Minimum coverage target

- All explicit claims about conversion behavior → direct test
- All explicit claims about sort rules → direct test
- All explicit claims about inductive types → direct test
- All explicit claims about singleton elimination → direct test
- All explicit claims about Pattern unification → direct test
- Metatheoretic claims (soundness, confluence) → notes explaining which tests
  provide what degree of confidence

### Deliverable

`docs/SPEC_COVERAGE.md` — a markdown table enumerating every SPEC clause with
its test coverage status.

---

## Step 2 — Diagnostic Polish

Make error messages precise. Every error kind must have a golden test and
human-readable output with source-span information.

### 2a. Audit all error types

Count all subclasses of `ElabError`, `DoxaCheckError`, and `ConvMismatch`
variants. For each:

| Error type | Golden test? | Span info? | Human-readable? |
|------------|-------------|------------|-----------------|
| `TypeMismatch` | Yes (check_test.dart) | Yes | Yes |
| `UnresolvedName` | Yes | Yes | Yes |
| ... | ... | ... | ... |

### 2b. Tier-2 binder-name propagation

Where error messages currently show placeholder names (de Bruijn-generated
`?a`, `?b`) or `_`, replace with the user-written binder name from source.
The elaborator's `SemInfo` metadata (Phase 3a) already carries source names;
wire it into error formatting.

Goal: an error like `TypeMismatch: expected ?a, got Nat` becomes
`TypeMismatch: expected (x: A) -> B, got Nat`.

### 2c. Negative-program walkthrough

Run every file in `doxa_tooling/test/programs/negative/` (if it exists)
and check that the error message is specific enough to debug the problem
without reading kernel source. If any message is vague ("type mismatch"
without context), add the context.

### Deliverable

Updated `report.dart` error formatting. No changes to error types themselves.

---

## Step 3 — Tutorial (`docs/tutorial.md`)

### Content

A self-contained walkthrough aimed at ML-family programmers. Must be
runnable — every code block is a verified `.doxa` file that type-checks.

### Structure

```
1. What Doxa is (2 paragraphs)
2. Getting Started (installation, first check)
3. Values and Functions (val, fun, lambdas, application)
4. Data Types (data, constructors, pattern matching)
5. Dependent Types (Pi, indices, Vec example)
6. Propositional Equality (Eq, refl, sym, trans, cong)
7. Induction (Nat.ind, List.ind, plus_zero)
8. Implicit Arguments ([A: Type] vs {A: Type})
9. Standard Library (Nat, List, Vec, Bool)
10. Modules and Imports
11. Tactics (by { intro; induction; refl })
12. Typeclasses (typeclass Eq[A], impl Eq[Int])
13. Quotient Types
14. SProp and Proof Irrelevance
15. Primitive Projections (record field access)
16. Next Steps (links to SPEC, stdlib source, Fungal)
```

### Assembly

Educational fragments from earlier phases (quotient examples from 14.5,
record examples from 17, tactic examples from 20, typeclass examples from 21)
are woven in rather than written from scratch.

### Verification

Every code block must be extracted, saved as a temporary `.doxa` file, and
checked with `doxa check`. This can be automated with a small shell script
or Dart test that extracts fenced code blocks and runs the checker on each.

### Deliverable

`docs/tutorial.md` — ~2,000-3,000 words, 15+ runnable code examples.

---

## Step 4 — Browser Demo

Refresh the existing `arda-web` WASM demo with the latest kernel.

### What to do

1. Compile Doxa to WASM: `dart compile wasm doxa_tooling/web/doxa_check.dart`
2. Deploy alongside the existing arda-web frontend (or a minimal HTML page)
3. Verify the demo accepts Doxa source, type-checks it, and displays the
   output (structured JSON from Phase 2, `CheckOutput`/`CheckSuccess`/`CheckFailure`)
4. Add an expandable declaration view (show type and normal form per decl)
5. Add structured error display (highlight the offending span)

### Deliverable

Working browser demo at a shareable URL. The demo should let a reader type
(or paste) any example from the tutorial and see it type-check.

---

## Step 5 — Release

### 5a. Release notes

Write `docs/RELEASE_NOTES.md` covering:
- What Doxa is
- Feature list (every phase from 0 through 21)
- What it ships with (stdlib, examples, tooling)
- What it does NOT include (explicit non-goals)
- How to install and run
- Known limitations
- Link to tutorial and SPEC

### 5b. Version tagging

```shell
git tag v1.0.0 -m "Doxa v1.0.0: CIC proof checker"
git push origin v1.0.0
```

### 5c. Final verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All 885 tests pass. `dart format --set-exit-if-changed` clean.
`docs/SPEC_COVERAGE.md` complete. `docs/tutorial.md` complete.
Browser demo live.

---

## Files

| Step | File | Action |
|------|------|--------|
| 1 | `docs/SPEC_COVERAGE.md` | **New** — audit table |
| 2 | `doxa/lib/src/report.dart` | Polish error formatting |
| 2 | `doxa/test/` | Possibly new golden-error tests |
| 3 | `docs/tutorial.md` | **New** — 2-3K word tutorial |
| 3 | `doxa_tooling/test/tutorial_test.dart` | Possibly new — verify tutorial code blocks |
| 4 | `doxa_tooling/web/` | WASM compilation + deployment |
| 5 | `docs/RELEASE_NOTES.md` | **New** — release notes |
| 5 | `.git/refs/tags/v1.0.0` | Tag |

## Session estimate

**10-15 sessions.** Break down:
- Step 1 (SPEC audit): 3-4 sessions
- Step 2 (diagnostic polish): 2-3 sessions
- Step 3 (tutorial): 3-4 sessions
- Step 4 (browser demo): 1-2 sessions
- Step 5 (release): 1-2 sessions

## Risk assessment

**Risk: Low.** No kernel changes. All work is documentation, testing, and
deployment. The SPEC audit may find gaps that require kernel fixes — if so,
those become mini-phases before release.

## Writing standard

The implementer must load the `domain-writing` skill before writing any prose
for this phase. The skill lives at `~/.config/opencode/skills/domain-writing/`.
All text must pass:
- Anti-AI-Language Checklist (no "delve", "robust", "landscape", etc.)
- Precision Checklist (no bare hedges, no unqualified quantifiers)
- Domain conventions for CS/math proof-writing
