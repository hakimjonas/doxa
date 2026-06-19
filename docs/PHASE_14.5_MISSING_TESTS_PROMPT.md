# Phase 14.5 — Missing Test Coverage

Implement the following tests in `doxa/test/quotient_test.dart`. All tests
use kernel-level `Term`/`Value` construction — no parser or elaborator needed.
The goal is to pin the singleton elimination behavior and the architectural
soundness decisions that prevent the Lean 3 `Quot` inconsistency.

## Test 1 — Singleton elimination not triggered for quotients

**What to verify.** `Quot(A, R)` is always `Type`-sorted, regardless of the
carrier's sort. `Quot.lift` into `Type` is a normal (non-singleton) elimination
and must succeed.

```dart
test('Quot.lift into Type with Prop carrier succeeds (quotients are Type-sorted)', () {
  final q = TQuot(TProp(), TPi(TProp(), TPi(TProp(), TProp())));
  final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
  final qType = infer(ctx, q);
  expect(qType, isA<VType>());
  expect((qType as VType).level, equals(0));

  final lift = TQuotLift(
    TQuotMk(TProp()),
    TLam(TProp(), TType(0)),
    TProp(),
  );
  final liftType = infer(ctx, lift);
  expect(liftType, isA<VType>());
});
```

## Test 2 — Lean 3 soundness architecture verification

**What to verify.** In Lean 3, Prop-sorted quotients allowed unrestricted
Prop -> Type elimination. In Doxa, quotients are always Type-sorted regardless
of carrier. The bug path doesn't exist architecturally.

```dart
test('Quot with Prop carrier is Type-sorted, not Prop-sorted (Lean 3 fix is architectural)', () {
  final q = TQuot(TProp(), TPi(TProp(), TPi(TProp(), TProp())));
  final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
  final qType = infer(ctx, q);
  expect(qType, isA<VType>());

  final q2 = TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp())));
  final q2Type = infer(ctx, q2);
  expect(q2Type, isA<VType>());
  expect((q2Type as VType).level, equals(0));
});
```

## Test 3 — Quot.lift with malformed proof rejected

**What to verify.** `Quot.lift` with a proof that doesn't have the correct type
is rejected by the type-checker.

```dart
test('Quot.lift with malformed proof fails inference', () {
  final q = TQuotLift(
    TQuotMk(TType(0)),
    TLam(TType(0), TBound(0)),
    TType(0),                                    // WRONG proof type
  );
  final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
  expect(
    () => infer(ctx, q),
    throwsA(isA<QuotFnNotRespectingRelation>()),  // or TypeMismatch
  );
});
```

## Test 4 — Quotient inside match expression

**What to verify.** A `TMatch` with a quotient in the case body evaluates to
the correct quotient value after ι-reduction. Quotient evaluation doesn't
interfere with match reduction.

```dart
List<DataDecl> _natDataDecls() => [
  DataDecl(
    name: 'Nat',
    params: const Telescope.empty(),
    indices: const Telescope.empty(),
    ctorList: const [
      CtorDecl(name: 'zero', dataName: 'Nat', args: const Telescope.empty(),
        extraArgs: const Telescope.empty(), resultIndices: const <Term>[],
        source: null, span: DoxaSpan.synthetic),
      CtorDecl(name: 'succ', dataName: 'Nat', args: const Telescope.empty(),
        extraArgs: const Telescope.empty(), resultIndices: const <Term>[],
        source: null, span: DoxaSpan.synthetic),
    ],
    sort: TType(0),
    paramsCovariant: const [],
    source: null, span: DoxaSpan.synthetic,
  ),
];

test('TQuot inside TMatch case body evaluates correctly', () {
  final t = TMatch(
    TConstr('Nat', 'zero', const []), null, const [
    TMatchCase('zero', 0,
      TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp()))),
      const [], span: DoxaSpan.synthetic),
  ]);
  final env = ENil.withRegistries(
    dataDecls: _natDataDecls(), topBindings: const {},
  );
  final v = eval(t, env);
  expect(v, isA<VQuot>());
});
```

## Test 5 — Quot.mk inside indexed-family match arm

**What to verify.** `TMatch` on an indexed family (`Vec`) where the case body
contains `TQuotMk`. Index refinement should work correctly.

```dart
List<DataDecl> _vecDataDecls() => [
  DataDecl(
    name: 'Vec',
    params: const Telescope.parseV1([('_', TType(0))]),
    indices: const Telescope.parseV1([('_', TType(0))]),
    ctorList: const [
      CtorDecl(name: 'vnil', dataName: 'Vec',
        args: const Telescope.empty(), extraArgs: const Telescope.empty(),
        resultIndices: const [const TConstr('Nat', 'zero', <Term>[])],
        source: null, span: DoxaSpan.synthetic),
      CtorDecl(name: 'vcons', dataName: 'Vec',
        args: const Telescope.empty(), extraArgs: const Telescope.empty(),
        resultIndices: const [const TConstr('Nat', 'succ', <Term>[])],
        source: null, span: DoxaSpan.synthetic),
    ],
    sort: TType(0),
    paramsCovariant: const [],
    source: null, span: DoxaSpan.synthetic,
  ),
];

test('TQuotMk inside indexed-family match arm evaluates correctly', () {
  final t = TMatch(
    TConstr('Vec', 'vnil', const [TType(0)]), null, const [
    TMatchCase('vnil', 0,
      TQuotMk(TConstr('Nat', 'zero', const [])),
      const [], span: DoxaSpan.synthetic),
  ]);
  final env = ENil.withRegistries(
    dataDecls: _vecDataDecls(), topBindings: const {},
  );
  final v = eval(t, env);
  expect(v, isA<VQuotMk>());
});
```

## Test 6 — Quotient in match round-trips through eval -> quote -> eval

**What to verify.** Quotient structure survives the quote cycle when inside
a match that has already ι-reduced.

```dart
test('quotient in match round-trips through eval -> quote -> eval', () {
  final t = TMatch(
    TConstr('Nat', 'zero', const []), null, const [
    TMatchCase('zero', 0,
      TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp()))),
      const [], span: DoxaSpan.synthetic),
  ]);
  final env = ENil.withRegistries(
    dataDecls: _natDataDecls(), topBindings: const {},
  );
  final v = eval(t, env);
  final quoted = quote(0, v);
  expect(quoted, isA<TQuot>());
  final reEval = eval(quoted, env);
  expect(reEval, isA<VQuot>());
});
```

## What these tests exercise

| Test | Kernel path |
|---|---|
| 1 | `infer(TQuot)` sort computation with Prop carrier, `infer(TQuotLift)` succeeds |
| 2 | `infer(TQuot)` always produces `VType` n, architectural Lean 3 prevention |
| 3 | `infer(TQuotLift)` proof type checking — malformed proof rejected |
| 4 | `eval(TMatch)` ι-reduction with quotient in case body |
| 5 | `eval(TMatch)` on indexed family with quotient in arm, index refinement |
| 6 | `eval → quote → eval` of quotient-inside-match preserved |

## Verification

```shell
cd doxa && dart analyze lib/ test/ && dart test
```

All existing tests pass. The 6 new tests pass. No regressions.
