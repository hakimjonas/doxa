/// Prop: parsing, `Prop : Type 1`, Pi sort rules, conversion, pretty-printing.
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

void main() {
  group('Prop parses and elaborates', () {
    test('bare Prop', () {
      expect(ee('Prop'), const TProp());
    });

    test('Prop is reserved', () {
      // We can't parse `val Prop = ...` because Prop is reserved.
      expect(
        parseExpr('Prop 0'),
        isA<Failure<ParseError, SExpr>>(),
        skip: false,
        reason: 'Prop does not take a level',
      );
    });
  });

  group('Prop : Type 1', () {
    test('infer Prop yields Type 1', () {
      final t = infer(const CNil(), const TProp());
      expect(t, isA<VType>());
      expect((t as VType).level, const LLevel(1));
    });

    test('check Prop : Type 1 succeeds', () {
      check(const CNil(), const TProp(), const VType(LLevel(1)));
    });

    test('check Prop : Type 0 fails', () {
      expect(
        () => check(const CNil(), const TProp(), const VType(LLevel(0))),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });

  group('Pi sort rules (PTS, CIC with Prop)', () {
    test('(A: Prop) -> A  is in Prop (impredicative)', () {
      final t = infer(const CNil(), const TPi(TProp(), TBound(0)));
      expect(t, isA<VProp>());
    });

    test('(A: Type) -> A  is in Type 1', () {
      // Codomain A has type Type 0; domain has type Type 1 (since
      // Type 0 : Type 1). Pi sort is max(1, 0) = 1.
      final t = infer(const CNil(), const TPi(TType(LLevel(0)), TBound(0)));
      expect(t, isA<VType>());
      expect((t as VType).level, const LLevel(1));
    });

    test('(P: Prop) -> (A: Type) -> A  is in Type 1', () {
      // Outer: domain Prop (type Type 1), codomain itself in Type 1.
      // max(1, 1) = 1.
      const term = TPi(TProp(), TPi(TType(LLevel(0)), TBound(0)));
      final t = infer(const CNil(), term);
      expect(t, isA<VType>());
      expect((t as VType).level, const LLevel(1));
    });

    test(
      '(A: Type) -> (P: Prop) -> P  is in Prop (impredicative codomain)',
      () {
        // The codomain `(P: Prop) -> P` is in Prop. Therefore the
        // outer Pi is also in Prop, regardless of the domain sort.
        const term = TPi(TType(LLevel(0)), TPi(TProp(), TBound(0)));
        final t = infer(const CNil(), term);
        expect(t, isA<VProp>());
      },
    );

    test(
      '(A: Type 2) -> (P: Prop) -> P  is in Prop (even with Type 2 domain)',
      () {
        // Impredicativity is strong: the codomain being in Prop
        // collapses the Pi into Prop no matter how high the domain
        // universe is.
        const term = TPi(TType(LLevel(2)), TPi(TProp(), TBound(0)));
        final t = infer(const CNil(), term);
        expect(t, isA<VProp>());
      },
    );
  });

  group('Prop conversion', () {
    test('Prop ≡ Prop', () {
      final r = conv(0, const VProp(), const VProp());
      expect(r, isA<ConvOk>());
    });

    test('Prop ≢ Type 0', () {
      final r = conv(0, const VProp(), const VType(LLevel(0)));
      expect(r, isA<ConvMismatch>());
    });

    test('Prop ≢ Type 1', () {
      final r = conv(0, const VProp(), const VType(LLevel(1)));
      expect(r, isA<ConvMismatch>());
    });
  });

  group('Prop pretty-prints', () {
    test('bare Prop', () {
      expect(prettyTerm(const TProp()), 'Prop');
    });

    test('inside a Pi', () {
      // We can't easily write (A: Prop) -> A in pure kernel form with
      // a name hint (we'd need elab). Use elab to get it.
      final t = ee('(A: Prop) -> A');
      expect(prettyTerm(t), '(A: Prop) -> A');
    });
  });

  group('Let + Prop interaction', () {
    test('let bound to a Prop-valued expression', () {
      // The let's Prop annotation matches the bound expression's type
      // (impredicative), and the body returns P : Prop.
      final env = elabProgram(
        parseProgramOk('val q: Prop = { val P: Prop = (X: Prop) -> X; P }'),
      );
      final b = env.bindings[0];
      final ctx = env.toCtx();
      check(ctx, b.term, eval(b.type, ctx.env));
    });

    test('let declared Prop; body in Prop', () {
      // Exercises Prop as domain, a let with a Prop annotation, and
      // references to Prop-typed neutrals inside the let body.
      final env = elabProgram(
        parseProgramOk(
          'fun foo(A: Prop, B: Prop): Prop = { val P: Prop = A; B }',
        ),
      );
      final b = env.bindings[0];
      final ctx = env.toCtx();
      check(ctx, b.term, eval(b.type, ctx.env));
    });
  });

  group('Declarations using Prop', () {
    test('val P: Prop = (X: Prop) -> X', () {
      final env = elabProgram(parseProgramOk('val P: Prop = (X: Prop) -> X'));
      expect(env.bindings, hasLength(1));
      // No exception means it type-checked.
    });

    test('Prop can be used as a domain for dependent Pi', () {
      final env = elabProgram(parseProgramOk('fun trivial(P: Prop): Prop = P'));
      expect(env.bindings, hasLength(1));
    });
  });
}

SProgram parseProgramOk(String src) {
  final r = parseProgram(src);
  return switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    _ => fail('parse failed: $r'),
  };
}
