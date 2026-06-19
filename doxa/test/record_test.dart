/// Primitive projections and definitional η for record types.
///
/// Tests are written at the kernel term level to isolate the
/// projection/η machinery from parser limitations.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/registry.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

DataDecl _pairDecl() => DataDecl(
      name: 'Pair',
      params: const [
        TelescopeEntry('A', TType(LLevel(0)), DoxaSpan.synthetic),
        TelescopeEntry('B', TType(LLevel(0)), DoxaSpan.synthetic),
      ],
      indices: const [],
      sort: TType(LLevel(0)),
      ctors: [
        CtorDecl(
          dataName: 'Pair',
          name: 'mk',
          args: const [
            TelescopeEntry('fst', TBound(1), DoxaSpan.synthetic),
            TelescopeEntry('snd', TBound(0), DoxaSpan.synthetic),
          ],
          resultIndices: const [],
          source: SCtorDecl(
            'mk',
            SExpr(SIdentKind('dummy'), DoxaSpan.synthetic),
            DoxaSpan.synthetic,
          ),
          span: DoxaSpan.synthetic,
        ),
      ],
      paramsCovariant: const [true, true],
      source: SDataKind(
        'Pair',
        const [],
        const SExpr(SIdentKind('dummy'), DoxaSpan.synthetic),
        const [],
      ),
      span: DoxaSpan.synthetic,
    );

void main() {
  group('Projection from VConstr', () {
    test('TProj projects "fst" from VConstr(Pair, mk)', () {
      const a = VConstr('Nat', 'zero', []);
      const b = VConstr('Nat', 'succ', [VConstr('Nat', 'zero', [])]);
      const pair = VConstr('Pair', 'mk', [
        VType(LLevel(0)),
        VType(LLevel(0)),
        a,
        b,
      ]);
      final env = ENil.withData([_pairDecl()]).extend(pair);
      final t = TProj(TBound(0), 'fst');
      final v = eval(t, env);
      expect(v, a);
    });

    test('TProj projects "snd" from VConstr(Pair, mk)', () {
      const a = VConstr('Nat', 'zero', []);
      const b = VConstr('Nat', 'succ', [VConstr('Nat', 'zero', [])]);
      const pair = VConstr('Pair', 'mk', [
        VType(LLevel(0)),
        VType(LLevel(0)),
        a,
        b,
      ]);
      final env = ENil.withData([_pairDecl()]).extend(pair);
      final t = TProj(TBound(0), 'snd');
      final v = eval(t, env);
      expect(v, b);
    });
  });

  group('Projection from stuck neutral', () {
    test('TProj(VNeutral(NVar(0)), "fst") stays NProj', () {
      final env = ENil.withData([_pairDecl()])
          .extend(const VNeutral(NVar(0)));
      final t = TProj(TBound(0), 'fst');
      final v = eval(t, env);
      expect(v, isA<VNeutral>());
      final n = (v as VNeutral).neutral;
      expect(n, isA<NProj>());
      expect((n as NProj).fieldName, 'fst');
    });
  });

  group('Quote round-trip', () {
    test('NProj quotes to TProj', () {
      final t = quote(1, const VNeutral(NProj(VNeutral(NVar(0)), 'fst')));
      expect(t, const TProj(TBound(0), 'fst'));
    });
  });

  group('Record η', () {
    test('η: VConstr(mk, [proj(p, fst), proj(p, snd)]) conv VNeutral(p)', () {
      // The η rule: when one side is VConstr and the other is not,
      // compare fields pointwise using NProj.
      const p = VNeutral(NVar(0));
      final etaExpanded = VConstr('Pair', 'mk', [
        const VType(LLevel(0)),
        const VType(LLevel(0)),
        VNeutral(NProj(p, 'fst')),
        VNeutral(NProj(p, 'snd')),
      ]);
      // conv(etaExpanded, p): left is VConstr, right is VNeutral (not VConstr).
      // η rule projects fields from right: NProj(p, "fst"), NProj(p, "snd").
      // These match the VConstr's fields, so ConvOk.
      final result =
          conv(0, etaExpanded, p, dataDecls: [_pairDecl()]);
      expect(result, isA<ConvOk>());
    });
  });

  group('NProj conv', () {
    test('same NProj is convertible', () {
      const p = VNeutral(NVar(0));
      const p1 = VNeutral(NProj(p, 'fst'));
      const p2 = VNeutral(NProj(p, 'fst'));
      expect(conv(0, p1, p2), isA<ConvOk>());
    });

    test('different field names mismatch', () {
      const p = VNeutral(NVar(0));
      const p1 = VNeutral(NProj(p, 'fst'));
      const p2 = VNeutral(NProj(p, 'snd'));
      expect(conv(0, p1, p2), isA<ConvMismatch>());
    });
  });
}
