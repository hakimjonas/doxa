import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

/// quote(VMatch) scope-faithfulness.
///
/// A stuck `VMatch` is a closure `(env, cases)`: its arm bodies are
/// Terms whose free indices are interpreted against `env` (extended by
/// the pattern binders). When such a value is quoted at level `L`, an
/// arm body's outer reference (an index that resolves through `env` to
/// some `NVar(ℓ)`) must be reindexed so that, at quote level L with the
/// arm's `n` binders open (effective depth L+n), it denotes the SAME
/// absolute binder NVar(ℓ): i.e. it must quote to `TBound(L+n-1-ℓ)`.

/// A stuck `VMatch` whose single `cons` arm body is `TApp(TBound(headIdx),
/// TBound(1))`, structurally `(outer) h`, mirroring map's `f h`. The
/// scrutinee is a neutral var so the match stays stuck.
VMatch stuckMatch({
  required Env env,
  required int scrutLevel,
  required int headIdx,
}) => VMatch(VNeutral(NVar(scrutLevel)), null, [
  VMatchCase('cons', 2, TApp(TBound(headIdx), const TBound(1)), const [
    null,
    null,
  ]),
], env);

/// The cons arm body's head element `TApp(headTerm, _)` from a quoted
/// TMatch.
Term consHead(Term quoted) {
  final m = quoted as TMatch;
  final arm = m.cases.firstWhere((c) => c.ctorName == 'cons');
  return (arm.body as TApp).fn;
}

/// Build env `[#0=NVar(levels[0]), #1=…, …]` (index 0 = first element).
Env envOf(List<Value> entries) {
  var env = const ENil() as Env;
  for (final v in entries.reversed) {
    env = env.extend(v);
  }
  return env;
}

void main() {
  group('quote(VMatch) scope-faithfulness', () {
    test('trivial-identity env, level == depth: head reindexes correctly', () {
      // Identity depth-4 env: [NVar3, NVar2, NVar1, NVar0].
      final env = envOf([
        const VNeutral(NVar(3)),
        const VNeutral(NVar(2)),
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      // headIdx=2 -> env slot (2-2)=0 -> NVar(3). At level 4, 2 binders
      // open (depth 6), NVar(3) is index 6-1-3 = TBound(2).
      final v = stuckMatch(env: env, scrutLevel: 5, headIdx: 2);
      expect(consHead(quote(4, v)), const TBound(2));
    });

    test('trivial-identity env, level > depth: head reindexes correctly', () {
      // SAME identity depth-4 env, but quoted at level 7 (the value got
      // embedded in a deeper context). headIdx=2 -> NVar(3). At level 7,
      // 2 binders open (depth 9), NVar(3) is index 9-1-3 = TBound(5).
      final env = envOf([
        const VNeutral(NVar(3)),
        const VNeutral(NVar(2)),
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      final v = stuckMatch(env: env, scrutLevel: 8, headIdx: 2);
      expect(
        consHead(quote(7, v)),
        const TBound(5),
        reason:
            'trivial-identity branch already handles level>depth '
            'via its `shift = level - env.depth`',
      );
    });

    test('non-trivial env, level == depth: head reindexes correctly', () {
      // Non-trivial depth-4 env (slot1 = a nested stuck match), but
      // level == depth (the append_nil shape).
      final inner = stuckMatch(
        env: envOf([const VNeutral(NVar(0))]),
        scrutLevel: 0,
        headIdx: 2,
      );
      final env = envOf([
        const VNeutral(NVar(3)),
        inner,
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      // headIdx=2 -> env slot 0 -> NVar(3). level 4, depth 6: TBound(2).
      final v = stuckMatch(env: env, scrutLevel: 5, headIdx: 2);
      expect(consHead(quote(4, v)), const TBound(2));
    });

    test('non-trivial env, level > depth: THE map_compose bug', () {
      // map_compose env1: depth-4 [#0=NVar4 (=g), #1=VMatch, #2=NVar2,
      // #3=NVar1], quoted at level 7.
      final inner = stuckMatch(
        env: envOf([const VNeutral(NVar(0))]),
        scrutLevel: 0,
        headIdx: 2,
      );
      final env = envOf([
        const VNeutral(NVar(4)), // #0 = g
        inner, // #1
        const VNeutral(NVar(2)), // #2
        const VNeutral(NVar(1)), // #3
      ]);
      // headIdx=2 -> env slot 0 -> NVar(4)=g. At level 7, 2 binders open
      // (depth 9), NVar(4) is index 9-1-4 = TBound(4).
      final v = stuckMatch(env: env, scrutLevel: 6, headIdx: 2);
      expect(
        consHead(quote(7, v)),
        const TBound(4),
        reason:
            'outer ref to NVar(4)=g must quote to TBound(4); the '
            'bug under-shifts it (TBound(2) -> denotes NVar(6), a '
            'deeper wrong binder).',
      );
    });

    // ORACLE (no hand-computed index): the trivial-identity branch is
    // known-correct. For a head that resolves to the SAME absolute
    // NVar(ℓ), a non-trivial env must quote to the SAME index a trivial
    // env does. This removes any reliance on my index arithmetic.
    test('non-trivial must agree with trivial for the same NVar (L==d)', () {
      // Trivial depth-4 identity env; headIdx=2 -> slot0 -> NVar(3).
      final triv = envOf([
        const VNeutral(NVar(3)),
        const VNeutral(NVar(2)),
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      final trivHead = consHead(
        quote(4, stuckMatch(env: triv, scrutLevel: 5, headIdx: 2)),
      );
      // Non-trivial depth-4 env whose slot0 ALSO holds NVar(3).
      final inner = stuckMatch(
        env: envOf([const VNeutral(NVar(0))]),
        scrutLevel: 0,
        headIdx: 2,
      );
      final nontriv = envOf([
        const VNeutral(NVar(3)), // #0 = same NVar(3)
        inner, // #1 makes it non-trivial
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      final ntHead = consHead(
        quote(4, stuckMatch(env: nontriv, scrutLevel: 5, headIdx: 2)),
      );
      expect(
        ntHead,
        trivHead,
        reason:
            'same head NVar must quote identically regardless of '
            'whether the env is trivial-identity',
      );
    });

    test('non-trivial must agree with trivial for the same NVar (L>d)', () {
      // Trivial depth-4 env quoted at 7; headIdx=2 -> NVar(3).
      final triv = envOf([
        const VNeutral(NVar(3)),
        const VNeutral(NVar(2)),
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      final trivHead = consHead(
        quote(7, stuckMatch(env: triv, scrutLevel: 8, headIdx: 2)),
      );
      final inner = stuckMatch(
        env: envOf([const VNeutral(NVar(0))]),
        scrutLevel: 0,
        headIdx: 2,
      );
      final nontriv = envOf([
        const VNeutral(NVar(3)), // #0 = same NVar(3)
        inner, // #1
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      final ntHead = consHead(
        quote(7, stuckMatch(env: nontriv, scrutLevel: 8, headIdx: 2)),
      );
      expect(
        ntHead,
        trivHead,
        reason:
            'level>depth: non-trivial env must still agree with '
            'trivial for the same head NVar',
      );
    });
  });

  // The TWO-REGIME interaction: an arm body that mixes a main-walk outer
  // reference AND a meta-spine `TApp*(TMeta, σ)`. This is the gap between
  // the meta-free harness above (which a blanket +nBinders main-walk
  // shift satisfies) and a body where that shift corrupts the meta-spine
  // arg through the quote roundtrip.
  group('quote(VMatch) two-regime (meta-spine + main-walk)', () {
    // Arm body: cons head element = TApp*(TMeta(0), [outerRef]) applied
    // to h. The head element is a meta-spine whose single arg is an
    // OUTER reference, the shape where a head element sits beside
    // meta-spine type args in the cons constructor.
    VMatch metaSpineMatch({
      required Env env,
      required int scrutLevel,
      required int spineArgIdx,
    }) => VMatch(VNeutral(NVar(scrutLevel)), null, [
      VMatchCase(
        'cons',
        2,
        // TApp(TApp(TMeta(0), TBound(spineArgIdx)), TBound(1))
        TApp(TApp(const TMeta(0), TBound(spineArgIdx)), const TBound(1)),
        const [null, null],
      ),
    ], env);

    // The meta-spine arg term from a quoted TMatch cons arm:
    // arm.body = TApp(TApp(TMeta, ARG), h) -> ARG.
    Term spineArg(Term quoted) {
      final m = quoted as TMatch;
      final arm = m.cases.firstWhere((c) => c.ctorName == 'cons');
      final inner = (arm.body as TApp).fn as TApp; // TApp(TMeta, ARG)
      return inner.arg;
    }

    // A MetaContext with meta 0 SOLVED, so quoteWithMetas takes the
    // meta-spine-aware path (`metas != null`) inside
    // quote(VMatch)/_substArmBody, the path the conv site exercises.
    MetaContext metasSolved0() {
      final m = MetaContext();
      final id = m.freshTermMeta(const VType(LLevel(0)), const CNil() as Ctx);
      expect(id, 0);
      m.solve(0, const TType(LLevel(0)));
      return m;
    }

    test('meta-spine arg: non-trivial must agree with trivial (L>d)', () {
      final metas = metasSolved0();
      // Trivial depth-4 env; spineArgIdx=2 -> env slot0 -> NVar(3).
      final triv = envOf([
        const VNeutral(NVar(3)),
        const VNeutral(NVar(2)),
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      final trivArg = spineArg(
        quoteWithMetas(
          7,
          metaSpineMatch(env: triv, scrutLevel: 8, spineArgIdx: 2),
          metas,
        ),
      );
      // Non-trivial depth-4 env (slot1 = nested stuck match), slot0 same.
      final inner = stuckMatch(
        env: envOf([const VNeutral(NVar(0))]),
        scrutLevel: 0,
        headIdx: 2,
      );
      final nontriv = envOf([
        const VNeutral(NVar(3)),
        inner,
        const VNeutral(NVar(1)),
        const VNeutral(NVar(0)),
      ]);
      final ntArg = spineArg(
        quoteWithMetas(
          7,
          metaSpineMatch(env: nontriv, scrutLevel: 8, spineArgIdx: 2),
          metas,
        ),
      );
      expect(
        ntArg,
        trivArg,
        reason:
            'meta-spine arg must reindex identically for trivial '
            'and non-trivial envs; the fix must NOT corrupt the E.1 '
            'spine regime while shifting the main-walk regime',
      );
    });
  });
}
