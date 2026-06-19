/// SProp: strict proof irrelevance — parsing, sort rules, conversion,
/// data declarations, type inference, pretty-printing.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

Term ee(String src) {
  final r = parseExpr(src);
  final expr = switch (r) {
    Success<ParseError, SExpr>(:final value) => value,
    Partial<ParseError, SExpr>(:final value) => value,
    _ => fail('parse failed: $r'),
  };
  return elabExpr(TopEnv.empty, expr);
}

SProgram parseProgramOk(String src) {
  final r = parseProgram(src);
  return switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    _ => fail('parse failed: $r'),
  };
}

void main() {
  // Test 9: TSProp() parsed and elaborated
  group('SProp parses and elaborates', () {
    test('bare SProp', () {
      expect(ee('SProp'), const TSProp());
    });

    test('SProp is reserved', () {
      // SProp should not parse as an identifier
      expect(
        parseExpr('SProp 0'),
        isA<Failure<ParseError, SExpr>>(),
        skip: false,
        reason: 'SProp does not take a level',
      );
    });
  });

  // SProp : Type 1
  group('SProp : Type 1', () {
    test('infer SProp yields Type 1', () {
      final t = infer(const CNil(), const TSProp());
      expect(t, isA<VType>());
      expect((t as VType).level, const LLevel(1));
    });

    test('check SProp : Type 1 succeeds', () {
      check(const CNil(), const TSProp(), const VType(LLevel(1)));
    });

    test('check SProp : Type 0 fails', () {
      expect(
        () => check(const CNil(), const TSProp(), const VType(LLevel(0))),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });

  // Test 1: VSProp() conv VSProp() -> ConvOk (strict irrelevance)
  // Test 2: VSProp() conv VProp() -> ConvMismatch (distinct sorts)
  // Test 3: VType(0) conv VSProp() -> ConvMismatch
  group('SProp conversion', () {
    test('SProp ≡ SProp (strict irrelevance)', () {
      final r = conv(0, const VSProp(), const VSProp());
      expect(r, isA<ConvOk>());
    });

    test('SProp ≢ Prop (distinct sorts)', () {
      expect(conv(0, const VSProp(), const VProp()), isA<ConvMismatch>());
      expect(conv(0, const VProp(), const VSProp()), isA<ConvMismatch>());
    });

    test('SProp ≢ Type 0 (distinct sorts)', () {
      expect(
        conv(0, const VSProp(), const VType(LLevel(0))),
        isA<ConvMismatch>(),
      );
      expect(
        conv(0, const VType(LLevel(0)), const VSProp()),
        isA<ConvMismatch>(),
      );
    });

    test('SProp ≢ Type 1', () {
      expect(
        conv(0, const VSProp(), const VType(LLevel(1))),
        isA<ConvMismatch>(),
      );
    });
  });

  // Test 7/8: Pi sort rules
  group('Pi sort rules (SProp)', () {
    test('(x: Type 0) -> SProp is in SProp (impredicative)', () {
      // SProp is impredicative: codomain in SProp means Pi is in SProp
      // regardless of domain sort.
      const term = TPi(TType(LLevel(0)), TSProp());
      final t = infer(const CNil(), term);
      expect(t, isA<VSProp>());
    });

    test('(x: SProp) -> SProp is in SProp (impredicative)', () {
      // Codomain SProp → Pi is in SProp regardless of domain
      const term = TPi(TSProp(), TSProp());
      final t = infer(const CNil(), term);
      expect(t, isA<VSProp>());
    });
  });

  // Test 4: SProp data with distinct constructors — conversion
  group('SProp data declarations', () {
    test('SProp data: two distinct proofs are convertible '
        '(strict irrelevance via mismatch fallback)', () {
      final env = elabProgram(
        parseProgramOk('''
          data UnitS : SProp { unitS : UnitS; otherS : UnitS }
        '''),
      );
      final ctx = env.toCtx();
      // unitS conv otherS should succeed (both are SProp-sorted)
      final unitS = eval(const TConstr('UnitS', 'unitS', []), ctx.env);
      final otherS = eval(const TConstr('UnitS', 'otherS', []), ctx.env);
      final r = conv(ctx.level, unitS, otherS, dataDecls: ctx.env.dataDecls);
      expect(r, isA<ConvOk>());
    });

    test('SProp data: .rec exists', () {
      final env = elabProgram(
        parseProgramOk('''
        data UnitS : SProp { unitS : UnitS }
      '''),
      );
      expect(env.bindings.any((b) => b.name == 'UnitS.rec'), true);
    });

    // Test 6: No .ind or .rect for SProp data
    test('SProp data: no .ind or .rect emitted', () {
      final env = elabProgram(
        parseProgramOk('''
        data UnitS : SProp { unitS : UnitS }
      '''),
      );
      expect(env.bindings.any((b) => b.name == 'UnitS.ind'), false);
      expect(env.bindings.any((b) => b.name == 'UnitS.rect'), false);
    });
  });

  // Test 9 (via surface): parsing and elaboration integration
  group('SProp in Pi surface syntax', () {
    test('(A: SProp) -> A elaborates', () {
      final t = ee('(A: SProp) -> A');
      // Should elaborate as TPi(TSProp(), TBound(0))
      expect(t, isA<TPi>());
      final pi = t as TPi;
      expect(pi.domain, const TSProp());
    });

    test('infer (A: SProp) -> A yields SProp (impredicative)', () {
      final t = infer(const CNil(), const TPi(TSProp(), TBound(0)));
      expect(t, isA<VSProp>());
    });
  });

  // Test 5: SProp data — ctor field must be SProp-sorted
  group('SProp data field restrictions', () {
    test('SProp data with Type-sorted field is rejected', () {
      // If we have SProp data with a field of type Type (not SProp),
      // the elaborator should catch it.
      //
      // Note: Doxa's current elaborator validates ctor-field sorts
      // only when TSProp is the data sort. This test verifies the
      // rejection path.
      expect(
        () => elabProgram(
          parseProgramOk('''
          data Bad : SProp { bad : (A: Type) -> Bad }
        '''),
        ),
        throwsA(isA<ElabError>()),
      );
    });
  });

  // Regression: all existing Prop tests are unaffected
  group('Regression: Prop still works', () {
    test('Prop parses and elaborates', () {
      expect(ee('Prop'), const TProp());
    });

    test('Prop : Type 1', () {
      final t = infer(const CNil(), const TProp());
      expect(t, isA<VType>());
      expect((t as VType).level, const LLevel(1));
    });

    test('Prop ≡ Prop', () {
      expect(conv(0, const VProp(), const VProp()), isA<ConvOk>());
    });

    test('Prop ≢ Type 0', () {
      expect(
        conv(0, const VProp(), const VType(LLevel(0))),
        isA<ConvMismatch>(),
      );
    });
  });

  group('SProp pretty-prints', () {
    test('bare SProp', () {
      expect(prettyTerm(const TSProp()), 'SProp');
    });

    test('inside a Pi', () {
      final t = ee('(A: SProp) -> A');
      expect(prettyTerm(t), '(A: SProp) -> A');
    });
  });
}
