# Phase 14.6 — Constructor Injectivity (Tests) & Benchmarking Interlude

## Overview

Phase 14.6 (definitional constructor injectivity) is a two-part undertaking:
1. **Test coverage** — the kernel code already exists, but dedicated injectivity
   tests were never written. Add them.
2. **Benchmarking interlude** — run the existing `tool/benchmark.dart` harness,
   produce `docs/BENCHMARKS.md` with AOT numbers for every workload.

**What's already done.** The `VConstr × VConstr` pointwise argument comparison
has been in `doxa/lib/src/eval.dart` since the initial kernel commit (line
1903–1917). When two `VConstr` values share the same `dataName`, `ctorName`,
and argument count, the converter compares arguments pointwise — this IS
definitional constructor injectivity. The `diff.dart` has matching handling
(lines 218–232). No new kernel code is needed.

**Why this phase still exists.** The plan documents (CONSOLIDATED_PLAN.md and
DETAILED_PLAN.md) list injectivity as ~30 lines of work, reflecting the plan
author's belief that the VConstr case was missing. It wasn't — but the
specific injectivity tests the plan calls for were never written. The
benchmarking interlude captures the performance baseline for future phases.

**Constraints.** All existing tests (currently 373 in `doxa/`) must continue
to pass. `dart analyze` 0 issues, `dart format` clean in `doxa/`. No kernel
code changes unless the existing VConstr comparison proves buggy under
testing.

---

## Step 1 — Add Injectivity Tests

Add 5 tests to `doxa/test/conv_test.dart` in a new `group('Constructor Injectivity')`.

### Test 1: Same constructor, same stuck argument → conv Ok

```
Positive: VConstr("Nat", "succ", [VNeutral(NVar(0))])
conv with VConstr("Nat", "succ", [VNeutral(NVar(0))]) → ConvOk
```

Build two VConstr values with the same neutral argument. The converter
should walk into the args, compare the two identical neutrals pointwise,
and return Ok. This is the simplest injectivity case.

### Test 2: Different constructors → conv Mismatch

```
Negative: VConstr("Nat", "zero", [])
conv with VConstr("Nat", "succ", []) → ConvMismatch
```

Different constructor names on the same data type must not convert. This
is the soundness guard — injectivity only applies to the SAME constructor.
Uses `_mismatchOrIrrelevance` internally, which handles Prop irrelevance
correctly.

### Test 3: Same constructor, differing arguments → conv Mismatch

```
Negative: VConstr("Nat", "succ", [VNeutral(NVar(0))])
conv with VConstr("Nat", "succ", [VNeutral(NVar(1))]) → ConvMismatch
```

Same ctor, same arity, but the pointwise arg comparison fails because
`NVar(0) ≠ NVar(1)`. The converter should propagate the arg-level mismatch
as a ConvMismatch.

### Test 4: Type-sorted data — irrelevance does NOT fire on different ctors

Build a real Type-sorted Nat via elaboration:
```dart
final env = elabProgram(_parse('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
'''));
// zero and succ_zero are different values → mismatch
```

Verifies that `_mismatchOrIrrelevance` correctly returns `ConvMismatch`
for Type-sorted constructors (not Prop-sorted). Guards against
over-admission of irrelevance.

### Test 5: Regression — `succ_injective` provable via `Nat.rec` still compiles

Extend the existing `example/proofs.doxa` check or add a quick elab+check
test that verifies a `succ_injective` propositional proof type-checks.
The proof is:

```
val succ_injective : (a b: Nat) -> Eq[Nat] (succ a) (succ b) -> Eq[Nat] a b
  = (a b: Nat) (h: Eq[Nat] (succ a) (succ b)) =>
    Nat.rec (Eq[Nat] a a) (refl[Nat] a) ((x: Nat) => ...)
```

This confirms that *propositional* injectivity via induction still works
alongside the new *definitional* injectivity. They are complementary, not
mutually exclusive.

### Test implementation notes

- Hand-build `VConstr` values directly for Tests 1–3 (no elaboration needed).
- For Test 4, use `elabProgram` + `eval(elabExpr(...))` as the existing
  conv_test.dart tests do.
- For Test 5, use `elabProgram`, then `checkDeclResult` against the full
  declaration sequence — match the pattern in `check_test.dart` or
  `elab_test.dart`.
- Follow the existing conv_test.dart conventions: `expect(result, isA<ConvOk>())`
  or `isA<ConvMismatch>()`, optionally checking `.got` / `.expected` on mismatch.

---

## Step 2 — Benchmarking Interlude

Run the existing `tool/benchmark.dart` harness and produce
`docs/BENCHMARKS.md` with a performance baseline.

### Run the harness

```shell
# AOT (authoritative numbers)
dart compile exe tool/benchmark.dart -o tool/benchmark_aot
./tool/benchmark_aot --repeat=5 --warmup=3 --output=table

# Church depth ladder (scaling behaviour)
./tool/benchmark_aot --only=church --depth=100,500,1000,5000 --repeat=3 --warmup=2
```

### Write `docs/BENCHMARKS.md`

The document should contain:

1. **Environment.** CPU model, Dart SDK version, AOT compilation command.
2. **Real workloads table.** All `stdlib/*` and `example/*` files, with
   columns: workload name, source size, parse time (µs), elab+check time (µs),
   total time (ms).
3. **Church depth table.** Depth vs total time, showing the linear O(N)
   characteristic of the evaluator.
4. **Key takeaways.** Stdlib throughput, parse-to-check ratio, scaling
   behaviour at depth 5000.
5. **Phase column.** Marker row for "14.5 (quotients)" — the baseline column
   that future phases (14.7, 15, …) will be compared against in the same
   table. Subsequent phases add new columns to the same markdown table.

### Template

```markdown
# Doxa Benchmarks

Environment: Ryzen 9950X3D, Dart 3.x, AOT (`dart compile exe`).

## Real Workloads (AOT, best-of-5, 3 warmup)

| Workload | Source | Parse (us) | Elab+Check (us) | Total (ms) |
|----------|--------|------------|------------------|------------|
| stdlib/proofs | 11.5 KB | ... | ... | ... |
| example/proofs | 4.8 KB | ... | ... | ... |

## Church Depth Scaling (AOT, best-of-3, 2 warmup)

| Depth | Total (ms) |
|-------|------------|
| 100   | ... |
| 500   | ... |
| 1000  | ... |
| 5000  | ... |

## Phase History

| Phase | Description | stdlib/proofs (ms) | Delta |
|-------|-------------|---------------------|-------|
| 14.5  | Quotient types | ... | baseline |
| 14.6  | Injectivity tests | ... | (no kernel change) |
```

---

## Verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All 373 existing `doxa/` tests pass. New injectivity tests pass (5 new tests).
`dart format --set-exit-if-changed` clean in both packages.
AOT benchmark table is populated in `docs/BENCHMARKS.md`.

No new kernel code is introduced — this is purely test + documentation work.

---

## Files to modify

| File | What changes |
|------|-------------|
| `doxa/test/conv_test.dart` | Add `group('Constructor Injectivity')` with 5 tests |
| `docs/BENCHMARKS.md` | **New file** — benchmark results in markdown format |
