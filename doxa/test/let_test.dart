/// Block-expression local bindings: parse, elaborate, eval, infer, pretty.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
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
  group('Block parsing', () {
    test('block with one annotated binding parses to SLetKind', () {
      final r = parseExpr('{ val x: Type = Type; x }');
      expect(r, isA<Success<ParseError, SExpr>>());
      final v = (r as Success<ParseError, SExpr>).value.kind;
      expect(v, isA<SLetKind>());
      final k = v as SLetKind;
      expect(k.param, 'x');
      expect(k.domain?.kind, const STypeKind(null));
    });

    test('block with unannotated binding parses (rejected at elab)', () {
      final r = parseExpr('{ val x = Type; x }');
      expect(r, isA<Success<ParseError, SExpr>>());
      final v = (r as Success<ParseError, SExpr>).value.kind;
      expect(v, isA<SLetKind>());
      expect((v as SLetKind).domain, isNull);
    });

    test('block with no bindings is just its result expression', () {
      final r = parseExpr('{ Type }');
      expect(r, isA<Success<ParseError, SExpr>>());
      final v = (r as Success<ParseError, SExpr>).value.kind;
      expect(v, isA<STypeKind>());
    });

    test('a block must end in a result expression', () {
      expect(
        parseExpr('{ val x: Type = Type }'),
        isA<Failure<ParseError, SExpr>>(),
      );
    });

    test('val is reserved: cannot be a bare identifier', () {
      expect(parseExpr('val'), isA<Failure<ParseError, SExpr>>());
    });

    test('let is no longer reserved: usable as an identifier', () {
      final r = parseExpr('let');
      expect(r, isA<Success<ParseError, SExpr>>());
      final v = (r as Success<ParseError, SExpr>).value.kind;
      expect(v, isA<SIdentKind>());
      expect((v as SIdentKind).name, 'let');
    });
  });

  group('Block elaboration (de Bruijn)', () {
    test('body references bound name via TBound(0)', () {
      final t = ee('{ val x: Type = Type; x }');
      expect(t, const TLet(TType(LLevel(0)), TType(LLevel(0)), TBound(0), name: 'x'));
    });

    test('two bindings: result refers to outer via TBound(1)', () {
      final t = ee('{ val x: Type = Type; val y: Type = Type; x }');
      // Under inner's binder, x = TBound(1), y = TBound(0).
      expect(
        t,
        const TLet(
          TType(LLevel(0)),
          TType(LLevel(0)),
          TLet(TType(LLevel(0)), TType(LLevel(0)), TBound(1), name: 'y'),
          name: 'x',
        ),
      );
    });

    test('elab infers an unannotated binding from the bound expr', () {
      // Binder type inferred from the bound expr: `Type : Type 1`, so the
      // TLet's domain term is `TType(LLevel(1))`.
      final t = ee('{ val x = Type; x }');
      expect(t, const TLet(TType(LLevel(1)), TType(LLevel(0)), TBound(0), name: 'x'));
    });
  });

  group('Block evaluation', () {
    test('bound value is inlined into env; no block value remains', () {
      final t = ee('{ val x: Type = Type 5; x }');
      final v = eval(t, const ENil());
      expect(v, isA<VType>());
      expect((v as VType).level, const LLevel(5));
    });

    test('shared value across body uses', () {
      final t = ee('{ val x: Type = Type 3; x -> x }');
      final nf_ = nf(t);
      // Normalizes to TPi(Type 3, Type 3): binding gone, both x resolved.
      expect(nf_, isA<TPi>());
      final pi = nf_ as TPi;
      expect(pi.domain, const TType(LLevel(3)));
      expect(pi.codomain, const TType(LLevel(3)));
    });
  });

  group('Block type inference', () {
    test('infer type of block body under extended ctx', () {
      final t = ee('{ val x: Type = Type; x }');
      expect(t, isA<TLet>());
      final env = elabProgram(
        parseProgramOk('val x: Type 1 = { val x: Type = Type; x }'),
      );
      expect(env.bindings, hasLength(1));
    });

    test('block checked against expected type (success)', () {
      final program = parseProgramOk('val y: Type = { val x: Type = Type; x }');
      final env = elabProgram(program);
      expect(env.bindings, hasLength(1));
    });

    test('block with ill-typed bound expression fails at check time', () {
      // `Type : Type 1` is NOT <= `Type 0` (the annotation); the bound
      // is checked against the domain at type-check time, not elab time.
      final program = parseProgramOk(
        'val y: Type 1 = { val x: Type = Type; x }',
      );
      final env = elabProgram(program);
      final b = env.bindings[0];
      final ctx = env.toCtx();
      expect(
        () => check(ctx, b.term, eval(b.type, ctx.env)),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('block with matching types succeeds (Type 1 annotation)', () {
      final program = parseProgramOk(
        'val y: Type 2 = { val x: Type 1 = Type; x }',
      );
      final env = elabProgram(program);
      final b = env.bindings[0];
      final ctx = env.toCtx();
      // No throw = success.
      check(ctx, b.term, eval(b.type, ctx.env));
    });
  });

  group('Stack safety of blocks', () {
    test('10,000-deep nested binding normalizes without blowing stack', () {
      // Built kernel-first as nested TLet (the desugared block form).
      // Verifies _EvalLetBody frames are tail-style.
      const depth = 10000;
      Term inner = const TBound(0);
      for (var i = 0; i < depth; i++) {
        inner = TLet(const TType(LLevel(0)), const TType(LLevel(0)), inner);
      }
      final v = eval(inner, const ENil());
      expect(v, isA<VType>());
      expect((v as VType).level, const LLevel(0));
    });
  });

  group('Block + cumulativity', () {
    test('block body type uses cumulativity upward', () {
      final env = elabProgram(
        parseProgramOk('val y: Type 2 = { val x: Type 1 = Type; Type }'),
      );
      final b = env.bindings[0];
      final ctx = env.toCtx();
      check(ctx, b.term, eval(b.type, ctx.env));
    });

    test('block body type rejected when target is too narrow', () {
      // The body is checked against the declared type during elaboration,
      // so the mismatch is raised at elab time.
      expect(
        () => elabProgram(
          parseProgramOk('val y: Type 0 = { val x: Type 1 = Type; Type }'),
        ),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });

  group('Block pretty-printing', () {
    test('simple binding round-trips as a block', () {
      final t = ee('{ val x: Type = Type; x }');
      expect(prettyTerm(t), '{ val x: Type = Type; x }');
    });
  });
}
