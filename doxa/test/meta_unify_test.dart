/// Pattern unification, exercised in isolation via the public `conv` API.
library;

import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

void main() {
  group('Pattern unification: flex-rigid', () {
    test('bare unapplied meta unifies with a concrete value', () {
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(1)), const CNil());
      final r = conv(
        0,
        eval(TMeta(id), const ENil()),
        const VType(LLevel(0)),
        metas: metas,
      );
      expect(r, isA<ConvOk>());
      expect(metas.isSolved(id), isTrue);
      expect(metas.solutionOf(id), const TType(LLevel(0)));
    });

    test('meta applied to bound var unifies: builds a λ solution', () {
      // ?0 x0 ≡ x0 at level 1, expecting ?0 := λ(x0: Type). x0.
      //
      // Mechanics: the meta's declared type must be a Pi-chain whose
      // arity matches the application spine; the unifier reads domains
      // from it to build well-typed lambda solutions. Here the single
      // outer binder is `x0 : Type 0`, so the meta's declared type is
      // `Π(Type 0). Type 0`, giving solution `λ(Type 0). TBound(0)`.
      final metas = MetaContext();
      final metaType = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const ENil(),
      );
      final id = metas.freshTermMeta(metaType, const CNil());
      // Build value `?0 x0` at level 1.
      const x0 = VNeutral(NVar(0));
      final metaApplied = apply(eval(TMeta(id), const ENil()), x0);
      // The rigid side is `x0` itself.
      final r = conv(1, metaApplied, x0, metas: metas);
      expect(r, isA<ConvOk>());
      expect(metas.isSolved(id), isTrue);
      // Solution's domain is Type 0 (from the meta's declared Pi).
      expect(metas.solutionOf(id), const TLam(TType(LLevel(0)), TBound(0)));
    });

    test('occurs check rejects ?0 ≡ f ?0 (self-referential solution)', () {
      // Build the rigid side as a stuck neutral `x0 ?0` whose argument
      // mentions ?0 itself, so solving ?0 would reference itself.
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(1)), const CNil());
      final metaV = eval(TMeta(id), const ENil());
      final rigid = VNeutral(NApp(const NVar(0), metaV));
      final r = conv(1, metaV, rigid, metas: metas);
      // Occurs check rejects, falling through to mismatch.
      expect(r, isA<ConvMismatch>());
      expect(metas.isSolved(id), isFalse);
    });

    test('non-distinct-var spine fails the pattern restriction', () {
      // ?0 x0 x0 ≡ Type 0: x0 appears twice, so the spine is not a
      // valid pattern and the unifier declines.
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(1)), const CNil());
      final base = eval(TMeta(id), const ENil());
      final applied = apply(
        apply(base, const VNeutral(NVar(0))),
        const VNeutral(NVar(0)),
      );
      final r = conv(1, applied, const VType(LLevel(0)), metas: metas);
      expect(r, isA<ConvMismatch>());
      expect(metas.isSolved(id), isFalse);
    });

    test('scope check rejects solution referencing out-of-scope var', () {
      // ?0 x0 ≡ x1 at level 2 where only x0 is in the meta's spine:
      // x1 is not among the pattern vars, so the scope check declines.
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(0)), const CNil());
      final base = eval(TMeta(id), const ENil());
      final applied = apply(base, const VNeutral(NVar(0)));
      final r = conv(2, applied, const VNeutral(NVar(1)), metas: metas);
      expect(r, isA<ConvMismatch>());
      expect(metas.isSolved(id), isFalse);
    });
  });

  group('Pattern unification: flex-flex', () {
    test('same meta, equal spines: admits without solving', () {
      // ?0 x0 ≡ ?0 x0: admitted by structural equality, meta stays
      // unsolved (no most-general solution is computed).
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(0)), const CNil());
      final base = eval(TMeta(id), const ENil());
      final applied = apply(base, const VNeutral(NVar(0)));
      final r = conv(1, applied, applied, metas: metas);
      expect(r, isA<ConvOk>());
      expect(metas.isSolved(id), isFalse);
    });

    test('same meta, different spine lengths: mismatch', () {
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(0)), const CNil());
      final base = eval(TMeta(id), const ENil());
      final a = apply(base, const VNeutral(NVar(0)));
      final b = base;
      final r = conv(1, a, b, metas: metas);
      expect(r, isA<ConvMismatch>());
    });

    test('same meta, diverging spines: const-approximation fires', () {
      // `?0 x0 x1 ≡ ?0 x0 x2` with x1 ≠ x2 would fail a pointwise
      // spine compare. The same-meta flex-flex const-approximation
      // instead solves `?0 := λ_.λ_. ?aux`, a constant function that
      // discards the spine, so both sides reduce to the same `?aux`
      // and succeed. The unifier detects spine divergence via a
      // pointer-identity pre-guard and tries const-approx before
      // pointwise compare.
      final metas = MetaContext();
      // Meta's declared type: Π(A: Type). Π(B: Type). Type, a
      // 2-Pi-layer chain long enough to supply both λ-chain
      // domains in the const-approx solution.
      final metaType = eval(
        const TPi(TType(LLevel(0)), TPi(TType(LLevel(0)), TType(LLevel(0)))),
        const ENil(),
      );
      final id = metas.freshTermMeta(metaType, const CNil());
      final base = eval(TMeta(id), const ENil());
      // ?0 x0 x1 vs ?0 x0 x2 at level 3.
      final v1 = apply(
        apply(base, const VNeutral(NVar(0))),
        const VNeutral(NVar(1)),
      );
      final v2 = apply(
        apply(base, const VNeutral(NVar(0))),
        const VNeutral(NVar(2)),
      );
      final r = conv(3, v1, v2, metas: metas);
      expect(r, isA<ConvOk>());
      expect(metas.isSolved(id), isTrue);
      // Solution shape: λ(Type 0). λ(Type 0). TMeta(aux) where
      // `aux` is the fresh meta inheriting the original's
      // (empty) localCtx.
      final sol = metas.solutionOf(id);
      expect(sol, isA<TLam>());
      final outer = sol as TLam;
      expect(outer.domain, const TType(LLevel(0)));
      expect(outer.body, isA<TLam>());
      final inner = outer.body as TLam;
      expect(inner.domain, const TType(LLevel(0)));
      expect(inner.body, isA<TMeta>());
    });

    test('same meta, equal spines (pointer-identity), fast path, no solve', () {
      // When spine args are pointer-identical, the divergence
      // pre-guard skips const-approx (pointwise is trivially ok) and
      // the meta stays unsolved. Regression pin: preserves the
      // "same meta, equal spines" fast path so an applied meta is not
      // needlessly solved here.
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(0)), const CNil());
      final base = eval(TMeta(id), const ENil());
      const shared = VNeutral(NVar(0));
      final applied = apply(base, shared);
      final r = conv(1, applied, applied, metas: metas);
      expect(r, isA<ConvOk>());
      expect(metas.isSolved(id), isFalse);
    });

    test('different metas: defer (return mismatch without solving)', () {
      // ?0 ≡ ?1 has no principled solution without intersection metas,
      // so the unifier defers: mismatch, neither meta solved.
      final metas = MetaContext();
      final id0 = metas.freshTermMeta(const VType(LLevel(0)), const CNil());
      final id1 = metas.freshTermMeta(const VType(LLevel(0)), const CNil());
      final v0 = eval(TMeta(id0), const ENil());
      final v1 = eval(TMeta(id1), const ENil());
      final r = conv(0, v0, v1, metas: metas);
      expect(r, isA<ConvMismatch>());
      expect(metas.isSolved(id0), isFalse);
      expect(metas.isSolved(id1), isFalse);
    });
  });

  group('Conv without meta-context (metas=null) treats NMeta opaquely', () {
    test('?0 ≡ Type 0 without metas yields mismatch', () {
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(1)), const CNil());
      final r = conv(
        0,
        eval(TMeta(id), const ENil()),
        const VType(LLevel(0)),
        // No meta-context passed, so no solving.
      );
      expect(r, isA<ConvMismatch>());
      expect(metas.isSolved(id), isFalse);
    });

    test('?0 ≡ ?0 without metas still admits (structural)', () {
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(0)), const CNil());
      final v = eval(TMeta(id), const ENil());
      final r = conv(0, v, v);
      expect(r, isA<ConvOk>());
    });
  });

  group('Map-shape reproducer', () {
    // Reproduces a `map{A}{B}(xs, f)` failure that surfaced as
    // `expected: List ?b, actual: List (?1 ?a ?b ?c ?d ?e ?f)`.
    // This group isolates the conv-API-level behaviour to see whether
    // the unifier itself is declining or the failure is in the elab
    // scaffolding.

    test('meta applied to 6-var spine solves against spine member', () {
      // Conv site at level 6 (binders A B xs f x rest at levels 0..5).
      // The elaborator's inserted-meta spine applies the binders in
      // order, evaluating to [NVar(0), NVar(1), …, NVar(5)]
      // (leftmost-applied first). Rhs = NVar(1) (the B binder).
      //
      // Mechanics: the meta's declared type is a closed Pi-chain
      // `Π(T₀). Π(T₁). … Π(T₅). Type 0`. For this isolated test all
      // binder types are Type 0; what matters is that the Pi-chain
      // arity matches the spine arity and the unifier reads
      // per-position domains from it. Expected solution
      // `λ. λ. λ. λ. λ. λ. TBound(4)`: the second λ from the outside
      // binds NVar(1), which sits at de-Bruijn index `n-1-1 = 4`
      // inside the 6-λ chain.
      final metas = MetaContext();
      Term metaTypeTerm = const TType(LLevel(0));
      for (var i = 0; i < 6; i++) {
        metaTypeTerm = TPi(const TType(LLevel(0)), metaTypeTerm);
      }
      final metaType = eval(metaTypeTerm, const ENil());
      final id = metas.freshTermMeta(metaType, const CNil());
      final base = eval(TMeta(id), const ENil());
      final spine = <Value>[];
      Value metaApplied = base;
      for (var k = 0; k <= 5; k++) {
        spine.add(VNeutral(NVar(k)));
        metaApplied = apply(metaApplied, VNeutral(NVar(k)));
      }
      const target = VNeutral(NVar(1));
      final r = conv(6, metaApplied, target, metas: metas);
      expect(r, isA<ConvOk>(), reason: 'pattern unif should solve');
      expect(metas.isSolved(id), isTrue);

      // Verify the solution is semantically correct: applying it to
      // the same spine should reproduce the rhs.
      final solutionTerm = metas.solutionOf(id);
      final solutionValue = eval(solutionTerm, const ENil());
      var reapplied = solutionValue;
      for (final s in spine) {
        reapplied = apply(reapplied, s);
      }
      final reapplyConv = conv(6, reapplied, target, metas: metas);
      expect(
        reapplyConv,
        isA<ConvOk>(),
        reason: 'solution applied to spine should equal rhs (semantic check)',
      );
    });

    test('meta spine under VData wrapper', () {
      // Same as above but wrapped: VData("List", [?0 spine]) vs
      // VData("List", [NVar(1)]). Conv descends into the data arg,
      // using the canonical spine order (NVar(0), …, NVar(5)) and an
      // arity-6 declared Pi-chain. After solve, applying the solution
      // to the spine reproduces NVar(1).
      final metas = MetaContext();
      Term metaTypeTerm = const TType(LLevel(0));
      for (var i = 0; i < 6; i++) {
        metaTypeTerm = TPi(const TType(LLevel(0)), metaTypeTerm);
      }
      final metaType = eval(metaTypeTerm, const ENil());
      final id = metas.freshTermMeta(metaType, const CNil());
      final base = eval(TMeta(id), const ENil());
      final spine = <Value>[];
      Value metaApplied = base;
      for (var k = 0; k <= 5; k++) {
        spine.add(VNeutral(NVar(k)));
        metaApplied = apply(metaApplied, VNeutral(NVar(k)));
      }
      final listMeta = VData('List', [metaApplied]);
      const listB = VData('List', [VNeutral(NVar(1))]);
      final r = conv(6, listMeta, listB, metas: metas);
      expect(r, isA<ConvOk>());
      expect(metas.isSolved(id), isTrue);

      // Semantic check.
      final solutionValue = eval(metas.solutionOf(id), const ENil());
      var reapplied = solutionValue;
      for (final s in spine) {
        reapplied = apply(reapplied, s);
      }
      final reapplyConv = conv(
        6,
        reapplied,
        const VNeutral(NVar(1)),
        metas: metas,
      );
      expect(reapplyConv, isA<ConvOk>());
    });
  });

  group('Solved meta unfolds during subsequent conv', () {
    test('after solving ?0 := Type 0, ?0 ≡ Type 0 via unfolding', () {
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(1)), const CNil());
      // Pre-solve, then conv should admit by unfolding the meta side:
      // eval(TMeta) yields VNeutral(NMeta(0)), and conv unfolds it via
      // the solved-meta branch.
      metas.solve(id, const TType(LLevel(0)));
      final r = conv(
        0,
        eval(TMeta(id), const ENil()),
        const VType(LLevel(0)),
        metas: metas,
      );
      expect(r, isA<ConvOk>());
    });
  });
}
