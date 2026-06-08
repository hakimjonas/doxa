/// Metavariable infrastructure round-trip.
library;

import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

void main() {
  group('TMeta term', () {
    test('equality by id', () {
      expect(const TMeta(0), const TMeta(0));
      expect(const TMeta(0), isNot(const TMeta(1)));
    });

    test('hashCode distinguishes ids', () {
      expect(const TMeta(0).hashCode, isNot(const TMeta(1).hashCode));
    });

    test('toString', () {
      expect(const TMeta(3).toString(), 'TMeta(3)');
    });

    test('pretty renders as ?id', () {
      expect(prettyTerm(const TMeta(0)), '?0');
      expect(prettyTerm(const TMeta(42)), '?42');
    });

    test('pretty renders TApp(TMeta, x) as ?0 x', () {
      const t = TApp(TMeta(0), TType(0));
      expect(prettyTerm(t), '?0 Type');
    });
  });

  group('NMeta neutral', () {
    test('equality by structural reference', () {
      const a = NMeta(7);
      const b = NMeta(7);
      expect(
        identical(a, b) || a == b,
        isTrue,
        reason: 'const ctors should intern or compare equal',
      );
    });
  });

  group('eval(TMeta) yields VNeutral(NMeta)', () {
    test('empty env, unsolved', () {
      final v = eval(const TMeta(0), const ENil());
      expect(v, isA<VNeutral>());
      final neu = (v as VNeutral).neutral;
      expect(neu, isA<NMeta>());
      expect((neu as NMeta).id, 0);
    });

    test('applied to an arg: spine extends', () {
      final v = eval(const TApp(TMeta(3), TType(5)), const ENil());
      expect(v, isA<VNeutral>());
      final neu = (v as VNeutral).neutral;
      expect(neu, isA<NApp>());
      final app = neu as NApp;
      expect(app.fn, isA<NMeta>());
      expect((app.fn as NMeta).id, 3);
      expect(app.arg, isA<VType>());
    });
  });

  group('quote(VNeutral(NMeta)) round-trips to TMeta', () {
    test('bare meta', () {
      const v = VNeutral(NMeta(2));
      final t = quote(0, v);
      expect(t, const TMeta(2));
    });

    test('with spine', () {
      const v = VNeutral(NApp(NMeta(1), VType(0)));
      final t = quote(0, v);
      expect(t, const TApp(TMeta(1), TType(0)));
    });

    test('term → value → term round trip', () {
      const t = TApp(TApp(TMeta(0), TType(0)), TType(1));
      final v = eval(t, const ENil());
      final back = quote(0, v);
      expect(back, t);
    });
  });

  group('MetaContext', () {
    test('fresh allocates consecutive ids', () {
      final ctx = MetaContext();
      final id0 = ctx.freshTermMeta(const VType(0), const CNil());
      final id1 = ctx.freshTermMeta(const VType(1), const CNil());
      expect(id0, 0);
      expect(id1, 1);
      expect(ctx.length, 2);
    });

    test('lookup returns TermMetaUnsolved for fresh', () {
      final ctx = MetaContext();
      final id = ctx.freshTermMeta(const VType(0), const CNil());
      final entry = ctx.lookup(id);
      expect(entry, isA<TermMetaUnsolved>());
      expect((entry as TermMetaUnsolved).typeExpected, const VType(0));
    });

    test('solve mutates to TermMetaSolved', () {
      final ctx = MetaContext();
      final id = ctx.freshTermMeta(const VType(0), const CNil());
      ctx.solve(id, const TType(0));
      final entry = ctx.lookup(id);
      expect(entry, isA<TermMetaSolved>());
      expect((entry as TermMetaSolved).solution, const TType(0));
      expect(ctx.isSolved(id), isTrue);
      expect(ctx.solutionOf(id), const TType(0));
    });

    test('solve-twice throws (solve-once invariant)', () {
      final ctx = MetaContext();
      final id = ctx.freshTermMeta(const VType(0), const CNil());
      ctx.solve(id, const TType(0));
      expect(() => ctx.solve(id, const TType(1)), throwsStateError);
    });

    test('lookup out-of-range throws', () {
      final ctx = MetaContext();
      expect(() => ctx.lookup(0), throwsStateError);
    });

    test('solutionOf on unsolved throws', () {
      final ctx = MetaContext();
      final id = ctx.freshTermMeta(const VType(0), const CNil());
      expect(() => ctx.solutionOf(id), throwsStateError);
    });
  });

  group('infer(TMeta) with Ctx.metas', () {
    test('unsolved meta returns declared typeExpected', () {
      final metas = MetaContext();
      final ctx = CNil.withRegistries(
        dataDecls: const [],
        topBindings: const {},
        metas: metas,
      );
      const expected = VType(0);
      final id = metas.freshTermMeta(expected, ctx);
      final inferred = infer(ctx, TMeta(id));
      // Identity-compare since there is no custom == on VType.
      expect(identical(inferred, expected), isTrue);
    });

    test('solved meta returns the declared expected type', () {
      // A solved meta returns its pre-solve declared type, not a
      // re-inference of the solution term: solutions can contain quoted
      // stuck forms that only typecheck in a specific check context, so
      // re-inferring them standalone would fail. Meta type is stored
      // separately from the solution for this reason.
      final metas = MetaContext();
      final ctx = CNil.withRegistries(
        dataDecls: const [],
        topBindings: const {},
        metas: metas,
      );
      const expected = VType(1);
      final id = metas.freshTermMeta(expected, ctx);
      // Well-typed solve: TType(0) has type VType(1) = expected.
      metas.solve(id, const TType(0));
      final inferred = infer(ctx, TMeta(id));
      expect(identical(inferred, expected), isTrue);
    });

    test('infer(TMeta) without metas on ctx throws', () {
      expect(() => infer(const CNil(), const TMeta(0)), throwsStateError);
    });
  });

  group('TMeta in walkers (open/close no-op)', () {
    test('openTerm is identity on TMeta', () {
      expect(openTerm(const TMeta(3), 'x'), const TMeta(3));
    });

    test('closeTerm is identity on TMeta', () {
      expect(closeTerm(const TMeta(3), 'x'), const TMeta(3));
    });

    test('close then open round-trip preserves TMeta', () {
      const t = TApp(TMeta(0), TFree('x'));
      final closed = closeTerm(t, 'x');
      expect(closed, const TApp(TMeta(0), TBound(0)));
      final reopened = openTerm(closed, 'x');
      expect(reopened, t);
    });
  });
}
