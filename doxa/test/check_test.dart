import 'package:doxa/src/check.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parseProg(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  throw StateError('parse failed');
}

/// Church-Nat type: (A: Type 0) -> (A -> A) -> A -> A.
///
/// Duplicated from eval_test to keep these tests self-contained.
Term churchNatType() => const TPi(
  TType(LLevel(0)),
  TPi(TPi(TBound(0), TBound(1)), TPi(TBound(1), TBound(2))),
);

/// churchNat(n) at the kernel level.
Term churchNat(int n) {
  Term body = const TBound(0);
  for (var i = 0; i < n; i++) {
    body = TApp(const TBound(1), body);
  }
  final lamZ = TLam(const TBound(1), body);
  const sType = TPi(TBound(0), TBound(1));
  final lamS = TLam(sType, lamZ);
  final lamA = TLam(const TType(LLevel(0)), lamS);
  return lamA;
}

/// Check that [actual] and [expected] convert at level 0.
void expectConvertible(Value actual, Value expected) {
  final r = conv(0, actual, expected);
  expect(r, isA<ConvOk>(), reason: 'expected $expected, got $actual');
}

void main() {
  group('infer: basic terms', () {
    test('Type n : Type (n+1)', () {
      expect(
        (infer(const CNil(), const TType(LLevel(0))) as VType).level,
        const LLevel(1),
      );
      expect(
        (infer(const CNil(), const TType(LLevel(5))) as VType).level,
        const LLevel(6),
      );
    });

    test('TBound looks up in context', () {
      final ctx = const CNil().extend(const VType(LLevel(7)));
      final t = infer(ctx, const TBound(0));
      expect((t as VType).level, const LLevel(7));
    });

    test('TFree in infer throws UnexpectedFree', () {
      expect(
        () => infer(const CNil(), const TFree('x')),
        throwsA(isA<UnexpectedFree>()),
      );
    });
  });

  group('infer: Pi', () {
    test('(Type 0 -> Type 0) : Type 1', () {
      final t = infer(
        const CNil(),
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
      );
      expect((t as VType).level, const LLevel(1));
    });

    test('(Type 0 -> Type 1) : Type 2 (max rule)', () {
      final t = infer(
        const CNil(),
        const TPi(TType(LLevel(0)), TType(LLevel(1))),
      );
      expect((t as VType).level, const LLevel(2));
    });

    test('(Type 2 -> Type 0) : Type 3', () {
      final t = infer(
        const CNil(),
        const TPi(TType(LLevel(2)), TType(LLevel(0))),
      );
      expect((t as VType).level, const LLevel(3));
    });

    test('dependent (A: Type 0) -> A : Type 1', () {
      // Pi with domain Type 0 (typed Type 1) and codomain A (typed Type 0).
      final t = infer(const CNil(), const TPi(TType(LLevel(0)), TBound(0)));
      expect((t as VType).level, const LLevel(1));
    });

    test('Pi with non-type domain fails (NotAType)', () {
      // Ctx binds x: (Type 0 -> Type 0). Using TBound(0) as a Pi domain
      // means the domain's *type* is a function type, not VType, so the
      // Pi rule must reject it.
      final funcType = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const ENil(),
      );
      final ctx = const CNil().extend(funcType);
      expect(
        () => infer(ctx, const TPi(TBound(0), TType(LLevel(0)))),
        throwsA(isA<NotAType>()),
      );
    });
  });

  group('infer: App', () {
    test('applying non-function throws NotAFunction', () {
      expect(
        () =>
            infer(const CNil(), const TApp(TType(LLevel(0)), TType(LLevel(0)))),
        throwsA(isA<NotAFunction>()),
      );
    });

    test('identity applied to a Type-0 inhabitant infers to Type 0', () {
      // (λA: Type 0. A) applied to a ctx-bound x : Type 0. The application
      // returns x; we ask for its type, which is Type 0.
      final ctx = const CNil().extend(const VType(LLevel(0))); // x: Type 0
      const app = TApp(
        TLam(TType(LLevel(0)), TBound(0)),
        TBound(0), // refers to x in the outer ctx
      );
      final t = infer(ctx, app);
      expect((t as VType).level, const LLevel(0));
    });

    test('applying to wrong-universe arg throws TypeMismatch', () {
      // Domain wants type Type 0, but the arg Type 0 has type Type 1.
      const app = TApp(TLam(TType(LLevel(0)), TBound(0)), TType(LLevel(0)));
      expect(() => infer(const CNil(), app), throwsA(isA<TypeMismatch>()));
    });

    test('applying to right-universe arg succeeds', () {
      // Domain wants Type 1, and the arg Type 0 has type Type 1; result
      // type is Type 1.
      const app = TApp(TLam(TType(LLevel(1)), TBound(0)), TType(LLevel(0)));
      final t = infer(const CNil(), app);
      expect((t as VType).level, const LLevel(1));
    });
  });

  group('infer: Lam (Pi synthesis)', () {
    test('(λA: Type 0. A) infers to (Type 0 -> Type 1)', () {
      // A is bound at Type 0 and the body is A, so infer yields the
      // non-dependent arrow (A: Type 0) -> Type 0.
      final t = infer(const CNil(), const TLam(TType(LLevel(0)), TBound(0)));
      expect(t, isA<VPi>());
      final pi = t as VPi;
      expect((pi.domain as VType).level, const LLevel(0));
      // Poke the codomain closure with an arbitrary value to read it off.
      final codomain = apply(
        VLam(pi.domain, pi.codomain),
        const VType(LLevel(0)),
      );
      expect((codomain as VType).level, const LLevel(0));
    });

    test('identity on values: (λx: Type 0. x) : Type 0 -> Type 0', () {
      const lam = TLam(TType(LLevel(0)), TBound(0));
      final expected = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const ENil(),
      );
      check(const CNil(), lam, expected);
    });
  });

  group('check mode', () {
    test('check TLam against VPi descends under the Pi', () {
      const lam = TLam(TType(LLevel(0)), TBound(0));
      final piType = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const ENil(),
      );
      check(const CNil(), lam, piType);
    });

    test('check TLam against wrong Pi fails (cumulativity downward)', () {
      // Body has type Type 1 but the expected codomain is Type 0; Type 1
      // is not a subtype of Type 0 (only the reverse), so this fails.
      const lam = TLam(TType(LLevel(1)), TBound(0));
      final piType = eval(
        const TPi(TType(LLevel(1)), TType(LLevel(0))),
        const ENil(),
      );
      expect(
        () => check(const CNil(), lam, piType),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('check TLam against non-Pi falls through to infer and conv', () {
      // Checking against a non-Pi infers the lambda's type
      // (Type 0 -> Type 0), which does not convert with Type 0.
      const lam = TLam(TType(LLevel(0)), TBound(0));
      expect(
        () => check(const CNil(), lam, const VType(LLevel(0))),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });

  group('Church-Nat type check', () {
    test('churchNatType() itself checks as a type', () {
      // The outermost Pi has domain Type 0 (n=1) and codomain reducing to
      // Type 0 (m=0), so the whole type lives in Type 1.
      final t = infer(const CNil(), churchNatType());
      expect(t, isA<VType>());
      expect((t as VType).level, const LLevel(1));
    });

    test('churchNat(0) checks against Nat', () {
      final natV = eval(churchNatType(), const ENil());
      check(const CNil(), churchNat(0), natV);
    });

    test('churchNat(3) checks against Nat', () {
      final natV = eval(churchNatType(), const ENil());
      check(const CNil(), churchNat(3), natV);
    });

    test('churchNat(0) does NOT check against (Type 0 -> Type 0)', () {
      final wrong = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const ENil(),
      );
      expect(
        () => check(const CNil(), churchNat(0), wrong),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });

  group('Universe discipline (strict, non-cumulative)', () {
    test('(A: Type 0) -> A has type Type 1 exactly', () {
      final t = infer(const CNil(), const TPi(TType(LLevel(0)), TBound(0)));
      expect((t as VType).level, const LLevel(1));
    });

    test('(A: Type 0) -> A does NOT check against Type 0', () {
      expect(
        () => check(
          const CNil(),
          const TPi(TType(LLevel(0)), TBound(0)),
          const VType(LLevel(0)),
        ),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('(A: Type 0) -> A DOES check against Type 2 (cumulativity)', () {
      // The Pi has type Type 1, and Type 1 <= Type 2, so this checks.
      check(
        const CNil(),
        const TPi(TType(LLevel(0)), TBound(0)),
        const VType(LLevel(2)),
      );
    });

    test('(A: Type 0) -> A does NOT check against Prop', () {
      // Prop and Type are disjoint sorts: cumulativity operates within
      // the Type hierarchy only and does not collapse Type into Prop.
      expect(
        () => check(
          const CNil(),
          const TPi(TType(LLevel(0)), TBound(0)),
          const VProp(),
        ),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('(A: Type 0) -> A DOES check against Type 1 (exact match)', () {
      check(
        const CNil(),
        const TPi(TType(LLevel(0)), TBound(0)),
        const VType(LLevel(1)),
      );
    });
  });

  group('Application in dependent position', () {
    test('id applied at Type 0 yields Type 0 (the type, not value)', () {
      // id = λA: Type 0. λa: A. a  :  (A: Type 0) -> A -> A.
      // Apply id to a ctx value of type Type 0 (you can't apply it at the
      // type level under strict universes: Type 0 has type Type 1).
      // Ctx is x: Type 0, y: x; by de Bruijn x is TBound(1), y is TBound(0).
      const id = TLam(TType(LLevel(0)), TLam(TBound(0), TBound(0)));
      const body = TApp(TApp(id, TBound(1)), TBound(0));
      final ctx = const CNil()
          .extend(const VType(LLevel(0))) // x: Type 0
          .extend(const VNeutral(NVar(0))); // y: x (= TBound(1))
      final t = infer(ctx, body);
      // Expected type is x, which evaluates to the neutral NVar(0).
      expectConvertible(t, const VNeutral(NVar(0)));
    });
  });

  group('Deep structural terms', () {
    test('churchNatType roundtrips through infer (checks as Type 1)', () {
      final natV = eval(churchNatType(), const ENil());
      check(const CNil(), churchNatType(), const VType(LLevel(1)));
      // Does NOT check at Type 0.
      expect(
        () => check(const CNil(), churchNatType(), const VType(LLevel(0))),
        throwsA(isA<TypeMismatch>()),
      );
      expectConvertible(natV, natV);
    });
  });

  group('Stack safety of the checker', () {
    test('infer on 10,000-nested Pi does not blow the stack', () {
      const depth = 10000;
      Term t = const TType(LLevel(0));
      for (var i = 0; i < depth; i++) {
        t = TPi(const TType(LLevel(0)), t);
      }
      final result = infer(const CNil(), t);
      expect((result as VType).level, const LLevel(1));
    });

    test('check on 10,000-nested Pi against Type 1 does not blow stack', () {
      const depth = 10000;
      Term t = const TType(LLevel(0));
      for (var i = 0; i < depth; i++) {
        t = TPi(const TType(LLevel(0)), t);
      }
      check(const CNil(), t, const VType(LLevel(1)));
    });

    test('infer on 10,000-nested Lam does not blow the stack', () {
      const depth = 10000;
      Term t = const TType(LLevel(0));
      for (var i = 0; i < depth; i++) {
        t = TLam(const TType(LLevel(0)), t);
      }
      final result = infer(const CNil(), t);
      expect(result, isA<VPi>());
    });

    test('infer on 100,000-nested Lam completes in under 5 seconds', () {
      // Regression pin: must not be deleted. infer on TLam was once
      // quadratic (10k ~7s, 40k ~70s, 100k effectively non-terminating);
      // the fix landed it in the same 100-300ms band as infer on TPi. The
      // 5s budget is generous; failing means the quadratic is back, likely
      // an open/eval/quote round-trip that lost the bodyIsNormal fast path.
      const depth = 100000;
      Term t = const TType(LLevel(0));
      for (var i = 0; i < depth; i++) {
        t = TLam(const TType(LLevel(0)), t);
      }
      final sw = Stopwatch()..start();
      final result = infer(const CNil(), t);
      sw.stop();
      expect(result, isA<VPi>());
      expect(
        sw.elapsed.inMilliseconds,
        lessThan(5000),
        reason:
            'infer on 100k-deep TLam took ${sw.elapsed.inMilliseconds}ms '
            ', the linear-time invariant is broken; look for an '
            'open/eval/quote round-trip that lost the '
            'Closure.bodyIsNormal fast path.',
      );
    });

    test(
      'quote on 10,000-deep nested VMatch chain does not blow the stack',
      () {
        // Regression pin: must not be deleted. Before driver-native arm
        // iteration, quote(VMatch) re-entered _drive via nested eval/quote
        // calls per arm, so Dart stack grew unbounded with nest depth.
        const depth = 10000;
        // Term-level chain of matches, each a single wildcard arm whose body
        // is the prior match; eval under a neutral scrutinee gives a VMatch
        // chain of the same depth.
        Term body = const TType(LLevel(0));
        for (var i = 0; i < depth; i++) {
          body = TMatch(const TBound(0), null, [
            TMatchCase('', 0, body, const <String?>[]),
          ]);
        }
        final env = const ENil().extend(const VNeutral(NVar(0)));
        final v = eval(body, env);
        final t = quote(1, v);
        expect(t, isA<TMatch>());
      },
    );

    test('recursor ι-reduction on 10,000-deep scrutinee does not blow the '
        'stack', () {
      // Regression pin: must not be deleted. Before driver-native IH
      // collection, each recursive-arg IH was computed via an inlined
      // apply(VRec, subArg) that re-entered _drive, so a D-deep succ-tower
      // scrutinee produced D nested Dart frames (~2k was the breaking point).
      const depth = 10000;
      final env = elabProgram(
        _parseProg('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
'''),
      );
      // Build (succ^depth zero), the Nat.rec application,
      // and evaluate.
      Term succChain = const TConstr('Nat', 'zero', <Term>[]);
      for (var i = 0; i < depth; i++) {
        succChain = TConstr('Nat', 'succ', <Term>[succChain]);
      }
      final recApp = TApp(
        const TApp(
          TApp(
            TApp(
              TRec('Nat'),
              TLam(TData('Nat', <Term>[]), TData('Nat', <Term>[])),
            ),
            TConstr('Nat', 'zero', <Term>[]),
          ),
          TLam(
            TData('Nat', <Term>[]),
            TLam(
              TData('Nat', <Term>[]),
              TConstr('Nat', 'succ', <Term>[TBound(0)]),
            ),
          ),
        ),
        succChain,
      );
      final result = eval(recApp, env.toCtx().env);
      expect(result, isA<VConstr>());
    });
  });
}
