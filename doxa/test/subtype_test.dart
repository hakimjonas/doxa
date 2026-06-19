/// Cumulativity: `Type n ≤ Type m iff n ≤ m`, Pi variance, and Prop.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

void main() {
  group('Cumulativity at universes', () {
    test('Type 0 checks against Type 1 (upward)', () {
      check(const CNil(), const TType(LLevel(0)), const VType(LLevel(1)));
    });

    test('Type 0 checks against Type 2 (two steps upward)', () {
      check(const CNil(), const TType(LLevel(0)), const VType(LLevel(2)));
    });

    test('Type 1 does NOT check against Type 0 (downward rejected)', () {
      expect(
        () =>
            check(const CNil(), const TType(LLevel(1)), const VType(LLevel(0))),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('Type 2 does NOT check against Type 0', () {
      expect(
        () =>
            check(const CNil(), const TType(LLevel(2)), const VType(LLevel(0))),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });

  group('Pi cumulativity through codomain', () {
    test('Pi Type 0 -> Type 0 has type Type 1 and is subtype of Type 2', () {
      check(
        const CNil(),
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const VType(LLevel(2)),
      );
    });
  });

  group('Cumulativity does not cross Prop', () {
    test('Prop DOES check against Type 1 (Prop : Type 1)', () {
      check(const CNil(), const TProp(), const VType(LLevel(1)));
    });

    test('Prop does NOT check against Type 0', () {
      expect(
        () => check(const CNil(), const TProp(), const VType(LLevel(0))),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('Type 0 does NOT check against Prop', () {
      expect(
        () => check(const CNil(), const TType(LLevel(0)), const VProp()),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('conv Prop vs Type 1 is rejected (not cumulative across sorts)', () {
      final r = conv(0, const VProp(), const VType(LLevel(1)));
      expect(r, isA<ConvMismatch>());
    });
  });

  group('Pi subtype variance', () {
    // Pi variance: got : (A1 -> B1) ≤ expected : (A2 -> B2)  iff
    //   A2 ≤ A1 (contravariant in domain) AND B1 ≤ B2 (covariant in codomain).

    test('covariant codomain: lambda into Type 0 fits codomain Type 2', () {
      // lam : (Type 0 -> Type 0); expected : (Type 0 -> Type 2).
      const lam = TLam(TType(LLevel(0)), TBound(0));
      final broader = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(2))),
        const ENil(),
      );
      check(const CNil(), lam, broader);
    });

    test(
      'contravariant domain: got accepts broader, expected narrower, OK',
      () {
        // got : (Type 2 -> Type 1); expected : (Type 0 -> Type 1).
        // Contravariance needs Type 0 ≤ Type 2, which holds.
        const lam = TLam(TType(LLevel(2)), TType(LLevel(0)));
        final expected = eval(
          const TPi(TType(LLevel(0)), TType(LLevel(1))),
          const ENil(),
        );
        check(const CNil(), lam, expected);
      },
    );

    test('contravariant domain wrong way rejected', () {
      // got : (Type 0 -> Type 1); expected : (Type 2 -> Type 1).
      // Contravariance needs Type 2 ≤ Type 0, which is false, so the
      // lambda-annotation-vs-Pi-domain subtype check must reject.
      const lam = TLam(TType(LLevel(0)), TType(LLevel(0)));
      final expected = eval(
        const TPi(TType(LLevel(2)), TType(LLevel(1))),
        const ENil(),
      );
      expect(
        () => check(const CNil(), lam, expected),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('codomain covariance wrong way rejected', () {
      // got : (Type 0 -> Type 1); expected : (Type 0 -> Type 0).
      // Covariance needs Type 1 ≤ Type 0, which is false.
      const lam = TLam(TType(LLevel(0)), TType(LLevel(0)));
      final expected = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const ENil(),
      );
      expect(
        () => check(const CNil(), lam, expected),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });

  group('Nested Pi check under cumulativity', () {
    test('inner annotation referencing outer binder checks against Pi', () {
      // Checks (A: Type) => (x: A) => x against (A: Type) -> A -> A.
      // Exercises subtype at a non-zero level with a neutral (A) on
      // both sides, which succeeds via the structural-equality fallback.
      check(
        const CNil(),
        const TLam(
          TType(LLevel(0)),
          TLam(TBound(0), TBound(0), name: 'x'),
          name: 'A',
        ),
        eval(
          const TPi(
            TType(LLevel(0)),
            TPi(TBound(0), TBound(1), name: 'x'),
            name: 'A',
          ),
          const ENil(),
        ),
      );
    });

    test('inner annotation differing from outer Pi domain is rejected', () {
      // Checks (A: Type) => (x: Type 0) => x against (A: Type) -> A -> A.
      // The inner annotation Type 0 does not subtype-compare against the
      // Pi's inner domain A (a named neutral is not ≤ Type 0), so it fails.
      expect(
        () => check(
          const CNil(),
          const TLam(
            TType(LLevel(0)),
            TLam(TType(LLevel(0)), TBound(0), name: 'x'),
            name: 'A',
          ),
          eval(
            const TPi(
              TType(LLevel(0)),
              TPi(TBound(0), TBound(1), name: 'x'),
              name: 'A',
            ),
            const ENil(),
          ),
        ),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });

  group('Stack safety of subtype', () {
    test('10,000-nested Pi subtype check does not blow the stack', () {
      // Build (Type 0 -> ... -> Type 0) 10k deep; subtype must descend
      // all levels without host-stack recursion.
      const depth = 10000;
      Term t = const TType(LLevel(0));
      for (var i = 0; i < depth; i++) {
        t = TPi(const TType(LLevel(0)), t);
      }
      check(const CNil(), t, const VType(LLevel(2)));
    });
  });

  group('Equality vs subtype', () {
    test('conv rejects Type 0 ≡ Type 1', () {
      final r = conv(0, const VType(LLevel(0)), const VType(LLevel(1)));
      expect(r, isA<ConvMismatch>());
    });

    test('conv rejects Type 1 ≡ Type 0', () {
      final r = conv(0, const VType(LLevel(1)), const VType(LLevel(0)));
      expect(r, isA<ConvMismatch>());
    });
  });
}
