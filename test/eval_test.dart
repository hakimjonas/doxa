import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

/// Build a Church-Nat-style numeral at the kernel level: the term
///   (A: Type 0) => (s: A -> A) => (z: A) => s(s(...s(z)...))
/// with [n] applications of `s`.
///
/// Per-binder de Bruijn indexing. A domain type is elaborated in the
/// context *outside* its own binder.
///
///   λA: Type 0.       -- domain Type 0 lives in empty ctx
///     λs: (A -> A).   -- domain lives in [A]; inside the domain Pi,
///                        A = TBound(0); under the (inner) Pi binder,
///                        A shifts to TBound(1).
///       λz: A.         -- domain lives in [s, A]; A = TBound(1).
///         body         -- body lives in [z, s, A]:
///                        z = TBound(0), s = TBound(1), A = TBound(2).
Term churchNat(int n) {
  // Body at [z, s, A]: z, s z, s (s z), …
  Term body = const TBound(0);
  for (var i = 0; i < n; i++) {
    body = TApp(const TBound(1), body);
  }
  // λz: A. body, domain A at context [s, A]: A = TBound(1).
  final lamZ = TLam(const TBound(1), body);
  // λs: (A -> A). lamZ, domain at context [A]: A = TBound(0).
  //                       Inside that Pi binder's codomain, A = TBound(1).
  const sType = TPi(TBound(0), TBound(1));
  final lamS = TLam(sType, lamZ);
  // λA: Type 0. lamS
  final lamA = TLam(const TType(0), lamS);
  return lamA;
}

/// The Church-Nat type: (A: Type 0) -> (A -> A) -> A -> A.
///
/// Built outside-in. Non-dependent arrows use a TPi whose codomain does not
/// mention TBound(0); under each such Pi, references to A shift up by one.
Term churchNatType() => const TPi(
  TType(0),
  TPi(TPi(TBound(0), TBound(1)), TPi(TBound(1), TBound(2))),
);

/// Church successor at the kernel level:
///   succ = λn: Nat. λA: Type. λs: (A -> A). λz: A. s (n A s z)
///
/// Binders from outside in: n, A, s, z. Inside the innermost body:
///   z = TBound(0), s = TBound(1), A = TBound(2), n = TBound(3).
Term churchSucc() {
  // Body: s (n A s z)
  const succBody = TApp(
    TBound(1),
    TApp(TApp(TApp(TBound(3), TBound(2)), TBound(1)), TBound(0)),
  );
  // λz: A. succBody, domain A at ctx [s, A, n]: A = TBound(1).
  const succInner = TLam(TBound(1), succBody);
  // λs: (A -> A). succInner
  //   domain at ctx [A, n]: A = TBound(0); inside the Pi, A = TBound(1).
  const succMid = TLam(TPi(TBound(0), TBound(1)), succInner);
  // λA: Type 0. succMid
  const succA = TLam(TType(0), succMid);
  // λn: Nat. succA
  return TLam(churchNatType(), succA);
}

void main() {
  group('Env.lookup', () {
    test('empty lookup throws', () {
      expect(() => const ENil().lookup(0), throwsRangeError);
    });

    test('index 0 returns head', () {
      final env = const ENil().extend(const VType(0));
      expect(env.lookup(0), isA<VType>());
    });

    test('index 1 returns second-from-top', () {
      final env = const ENil().extend(const VType(0)).extend(const VType(1));
      expect((env.lookup(0) as VType).level, 1);
      expect((env.lookup(1) as VType).level, 0);
    });

    test('extension does not mutate the tail', () {
      final base = const ENil().extend(const VType(0));
      final extended = base.extend(const VType(5));
      // base.lookup(0) should still be VType(0), not VType(5).
      expect((base.lookup(0) as VType).level, 0);
      expect((extended.lookup(0) as VType).level, 5);
      expect((extended.lookup(1) as VType).level, 0);
    });
  });

  group('eval: basic terms', () {
    test('TType evaluates to VType of same level', () {
      final v = eval(const TType(2), const ENil());
      expect(v, isA<VType>());
      expect((v as VType).level, 2);
    });

    test('TBound looks up in env', () {
      final env = const ENil().extend(const VType(7));
      final v = eval(const TBound(0), env);
      expect((v as VType).level, 7);
    });

    test('TFree in eval throws (kernel invariant)', () {
      expect(() => eval(const TFree('x'), const ENil()), throwsStateError);
    });

    test('TLam becomes VLam with captured env', () {
      // λ(A: Type 0). TBound(0), identity on TType.
      const term = TLam(TType(0), TBound(0));
      final v = eval(term, const ENil());
      expect(v, isA<VLam>());
    });

    test('TPi becomes VPi with evaluated domain', () {
      // (A: Type 0) -> A
      const term = TPi(TType(0), TBound(0));
      final v = eval(term, const ENil());
      expect(v, isA<VPi>());
      expect((v as VPi).domain, isA<VType>());
    });
  });

  group('eval: β-reduction', () {
    test('(λx. x) y reduces to y (y = TType 5)', () {
      // (λA. A) applied to (TType 5).
      const lam = TLam(TType(0), TBound(0));
      const app = TApp(lam, TType(5));
      final v = eval(app, const ENil());
      expect((v as VType).level, 5);
    });

    test('(λx. λy. x) a b reduces to a', () {
      // const-like: (λA. λB. A) applied to TType 3, then TType 7.
      // Inside: outermost binder is x, second is y.
      // Body: TBound(1) (the outer x).
      const inner = TLam(TType(0), TBound(1));
      const lam = TLam(TType(0), TLam(TType(0), TBound(1)));
      const app1 = TApp(lam, TType(3));
      const app2 = TApp(app1, TType(7));
      final v = eval(app2, const ENil());
      expect((v as VType).level, 3);
      // Sanity-check the single-arg intermediate stays a VLam.
      final v1 = eval(app1, const ENil());
      expect(v1, isA<VLam>());
      expect(inner, isNotNull);
    });

    test('under-applied lambda stays VLam', () {
      // (λx. x) with no argument: just eval the lambda.
      const lam = TLam(TType(0), TBound(0));
      final v = eval(lam, const ENil());
      expect(v, isA<VLam>());
    });

    test('applying a free variable yields a neutral', () {
      // We can't directly write TFree in terms (throws), so to test
      // neutral application we construct a VNeutral-headed value and
      // apply it.
      const head = VNeutral(NVar(0));
      const arg = VType(3);
      final v = apply(head, arg);
      expect(v, isA<VNeutral>());
      expect((v as VNeutral).neutral, isA<NApp>());
      final napp = v.neutral as NApp;
      expect(napp.fn, const NVar(0));
      expect((napp.arg as VType).level, 3);
    });
  });

  group('quote', () {
    test('VType round-trips', () {
      expect(quote(0, const VType(0)), const TType(0));
      expect(quote(0, const VType(5)), const TType(5));
    });

    test('neutral variable quotes to TBound relative to level', () {
      // At depth 3, NVar(0) is the outermost binder -> index 2.
      expect(quote(3, const VNeutral(NVar(0))), const TBound(2));
      // NVar(2) is the innermost binder at depth 3 -> index 0.
      expect(quote(3, const VNeutral(NVar(2))), const TBound(0));
    });

    test('identity λ round-trips via nf', () {
      // (λA: Type 0. A)
      const term = TLam(TType(0), TBound(0));
      final normalized = nf(term);
      expect(normalized, term);
    });

    test('Pi round-trips via nf', () {
      // (A: Type 0) -> A
      const term = TPi(TType(0), TBound(0));
      final normalized = nf(term);
      expect(normalized, term);
    });

    test('neutral application quotes with spine intact', () {
      // Build NApp(NVar(0), VType(3)) at level 2 -> TApp(TBound(1), TType(3)).
      const v = VNeutral(NApp(NVar(0), VType(3)));
      final t = quote(2, v);
      expect(t, const TApp(TBound(1), TType(3)));
    });
  });

  group('Church-Nat arithmetic', () {
    test('churchNatType() itself round-trips through nf', () {
      // The Nat type is a four-deep nested Pi; verifying it round-trips
      // exercises domain-then-codomain quoting at each level and catches
      // any per-level index arithmetic errors in nested Pi handling.
      final nat = churchNatType();
      expect(nf(nat), nat);
    });

    test('churchNat(0) normalizes to its canonical form', () {
      final zero = churchNat(0);
      expect(nf(zero), zero);
    });

    test('churchNat(3) normalizes to its canonical form', () {
      final three = churchNat(3);
      expect(nf(three), three);
    });

    test('succ(zero) reduces to one', () {
      final succ = churchSucc();
      final one = TApp(succ, churchNat(0));
      expect(nf(one), churchNat(1));
    });

    test('succ applied three times to zero reduces to three', () {
      // This exercises real β-reduction chains, unlike nf(churchNat(3))
      // which only tests idempotence on a term already in normal form.
      final succ = churchSucc();
      final three = TApp(succ, TApp(succ, TApp(succ, churchNat(0))));
      expect(nf(three), churchNat(3));
    });

    test('succ applied ten times reduces to ten', () {
      // Deeper β-chain, still well under any stack limit but confirms
      // that iterated application of a non-trivial function composes.
      final succ = churchSucc();
      Term term = churchNat(0);
      for (var i = 0; i < 10; i++) {
        term = TApp(succ, term);
      }
      expect(nf(term), churchNat(10));
    });
  });

  group('Neutral spines', () {
    test('two-deep neutral spine quotes with argument order preserved', () {
      // NApp(NApp(NVar(0), VType(1)), VType(2)) at level 1 should produce
      // TApp(TApp(TBound(0), TType(1)), TType(2)), the outer app is
      // outermost in the Term, with the leftmost-applied argument first.
      const v = VNeutral(NApp(NApp(NVar(0), VType(1)), VType(2)));
      final t = quote(1, v);
      expect(t, const TApp(TApp(TBound(0), TType(1)), TType(2)));
    });

    test('three-deep neutral spine preserves argument order', () {
      const v = VNeutral(
        NApp(NApp(NApp(NVar(0), VType(1)), VType(2)), VType(3)),
      );
      final t = quote(1, v);
      expect(
        t,
        const TApp(TApp(TApp(TBound(0), TType(1)), TType(2)), TType(3)),
      );
    });
  });

  group('stack safety', () {
    test('10,000-deep TApp chain does not blow the Dart stack', () {
      // Build a left-nested application: ((f a) a) a ... a
      // evaluated against a free function `f` in env position 0.
      // We use a single-arg function: evaluating in an env where index 0
      // is a neutral, each `f a` produces NApp(NApp(...NApp(f, a), a), a).
      const depth = 10000;
      // Start with TBound(0) as the function (which will look up a neutral).
      Term term = const TBound(0);
      for (var i = 0; i < depth; i++) {
        // Apply to TType(0) each step.
        term = TApp(term, const TType(0));
      }
      // Env has one neutral at index 0, NVar(0).
      final env = const ENil().extend(const VNeutral(NVar(0)));
      // This must not throw StackOverflowError.
      final v = eval(term, env);
      expect(v, isA<VNeutral>());
    });

    test('10,000-deep β-reduction does not blow the Dart stack', () {
      // Construct: apply a function that returns its argument, 10,000 times,
      // by layering (λx. x) applications.
      // ((λx. x) ((λx. x) ((λx. x) ... TType(0))))
      const depth = 10000;
      const idLam = TLam(TType(0), TBound(0));
      Term term = const TType(0);
      for (var i = 0; i < depth; i++) {
        term = TApp(idLam, term);
      }
      final v = eval(term, const ENil());
      expect((v as VType).level, 0);
    });

    test('10,000 nested lambdas evaluate without blowing the stack', () {
      // λ. λ. λ. ... TType(0), 10,000 deep.
      const depth = 10000;
      Term term = const TType(0);
      for (var i = 0; i < depth; i++) {
        term = TLam(const TType(0), term);
      }
      final v = eval(term, const ENil());
      expect(v, isA<VLam>());
    });

    test('quoting a 10,000-deep nested VLam structure is stack-safe', () {
      // Build the lambda, evaluate, then quote, all three must be stack-safe.
      const depth = 10000;
      Term term = const TType(0);
      for (var i = 0; i < depth; i++) {
        term = TLam(const TType(0), term);
      }
      final v = eval(term, const ENil());
      final t = quote(0, v);
      // Round-trips to the original.
      expect(t, term);
    });

    test('nf of deeply nested lambda is stack-safe (unified loop test)', () {
      // This is the specific regression test for the unified-driver fix:
      // under the old architecture, quote's _applyClosure called back into
      // eval, costing one Dart frame per binder descent. If that path were
      // still live, a deep-enough nested lambda would blow the stack during
      // the quote phase of nf(), even though eval on its own handled the
      // same depth fine. We run nf() end-to-end to exercise the full path.
      const depth = 10000;
      Term term = const TType(0);
      for (var i = 0; i < depth; i++) {
        term = TLam(const TType(0), term);
      }
      expect(nf(term), term);
    });

    test('Pi codomain quote is stack-safe for deeply nested Pi', () {
      // Same regression shape but for Pi: every Pi codomain opened during
      // quote previously went through _applyClosure -> eval.
      const depth = 10000;
      Term term = const TType(0);
      for (var i = 0; i < depth; i++) {
        term = TPi(const TType(0), term);
      }
      expect(nf(term), term);
    });
  });
}
