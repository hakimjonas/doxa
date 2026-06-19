# Phase 19.5 — Quote Faithfulness + Parser Gaps

Two small fixes closing documented limitations. ~35 lines, 1 session.

---

## Item 1 — VMatch Quote Scope-Faithfulness (~30 lines)

### Background

5 skipped tests in `doxa_tooling/test/vmatch_roundtrip_test.dart` document a known gap:
when quoting a `VMatch` at `level > env.depth`, the arm-body substitution path
applies a blanket `+nBinders` de Bruijn index shift. This corrupts meta-spine args
because the meta-spine index regime and the main-walk index regime need independent
shifts.

The bug manifests in `map_compose` and similar proofs where a stuck match is threaded
through `cong` / `trans` — the meta-spine args get shifted incorrectly, producing
wrong quoted terms.

### What needs to change

**File:** `doxa/lib/src/eval.dart` — the `_QMatchArmAfterEval` and `_QMatchArmAfterQuote`
frames (lines ~1120-1150).

The fix: when computing the quote level shift for arm bodies, track two separate
offsets:
1. **Main-walk offset:** `level + nBinders - env.depth` — the standard shift for
   de Bruijn indices that walk through the VMatch's captured environment.
2. **Meta-spine offset:** `level - metaEnv.depth` — the shift for indices that resolve
   through the meta-context's spine, which is at the call-site depth, not the
   VMatch's captured depth.

Currently the code uses `level + nBinders` uniformly. The fix separates the two:

```dart
// In _QMatchArmAfterEval or the arm-body substitution logic:
final mainDepth = level + nBinders;  // arm binder depth
final metaDepth = level;             // meta-spine is at the call-site
// Apply mainDepth shift to free indices resolving through env
// Apply metaDepth shift to free indices resolving through meta spine
```

The exact implementation depends on how the current substitution walker is structured.
The test file at lines 86-95 has precise assertions for the correct behavior.

### Tests to un-skip

Remove `skip:` from 5 tests in `doxa_tooling/test/vmatch_roundtrip_test.dart`:
- Lines 114, 141, 183, 218 (`openGap`)
- Line 313 (`openGap2`)

After the fix, these tests should pass. The test harness already has the correct
expected values — it's just that the quoting logic didn't produce them.

---

## Item 2 — Zero-Parameter `fun` Parser Fix (~5 lines)

### Background

The `_valueParams` parser (parse.dart:834-843) claims to support `()` in its doc
comment but doesn't implement it. The parser requires at least one `(name: Type)`
between the parens, making zero-parameter `fun` definitions unparseable.

This blocks a test in `doxa_tooling/test/structural_recursion_walker_test.dart:264`
that needs a zero-param fun in a mutual block (a type parameter references a sibling).

### Fix

**File:** `doxa/lib/src/parse.dart`, lines 834-843.

Make the content between parens optional:

```dart
/// Value parameters: `( name ':' expr (',' name ':' expr)* )` or `()`.
final Parser<ParseError, List<(String, SExpr)>> _valueParams = _sym('(')
    .skipThen(
      _ident
          .flatMap<(String, SExpr)>(
            (name) => _sym(':').skipThen(_expr).map((t) => (name, t)),
          )
          .sepBy(_sym(','))
          .optional
          .map((r) => r ?? []),
    )
    .thenSkip(_sym(')'));
```

The `.optional.map((r) => r ?? [])` makes the entire parameter list optional:
- `()` → `[]` (empty list, valid)
- `(x: Nat)` → `[(x, Nat)]` (existing behavior unchanged)
- `(x: Nat, y: Bool)` → `[(x, Nat), (y, Bool)]` (existing behavior unchanged)

### Tests to un-skip / add

Un-skip the test in `doxa_tooling/test/structural_recursion_walker_test.dart:264`.

Optionally add a parse test verifying that `fun f(): Nat = zero` parses correctly.

---

## Verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

After fix:
- All 418 doxa tests pass (unchanged — kernel unaffected by parser fix)
- All 438 doxa_tooling tests pass (5 previously skipped now pass)
- No new regressions

---

## Files to modify

| Item | File | Changes | Est. lines |
|------|------|---------|-----------|
| 1 | `doxa/lib/src/eval.dart` | Separate main-walk vs meta-spine index regimes in VMatch quoting | ~25 |
| 1 | `doxa_tooling/test/vmatch_roundtrip_test.dart` | Remove `skip:` from 5 tests | ~5 |
| 2 | `doxa/lib/src/parse.dart` | Make `_valueParams` content optional | +3 |
| 2 | `doxa_tooling/test/structural_recursion_walker_test.dart` | Remove `skip:` from 1 test | ~2 |
| **Total** | | | **~35** |

## Risk assessment

**Risk: Low.** Item 2 is a trivial parser relaxation — can only make more things parse,
never fewer. Item 1 is scoped to the VMatch quoting path, which has specific test
assertions to guard against regression. The existing behavior for `level == env.depth`
(the common case) is already correct and will not be affected.
