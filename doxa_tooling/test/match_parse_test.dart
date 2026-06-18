/// Parser tests for `match`: parse shape of arms, motive, and scrutinee.
library;

import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SExpr _parse(String src) {
  final r = parseExpr(src);
  if (r is Success<ParseError, SExpr>) return r.value;
  if (r is Partial<ParseError, SExpr>) return r.value;
  fail('parse failed: $r');
}

void _expectParseFailure(String src) {
  final r = parseExpr(src);
  expect(
    r,
    isA<Failure<ParseError, SExpr>>(),
    reason: 'should have failed: $src',
  );
}

SMatchKind _asMatch(SExpr e) {
  final k = e.kind;
  if (k is! SMatchKind) fail('not SMatchKind: ${k.runtimeType}');
  return k;
}

void main() {
  group('basic shape', () {
    test('single wildcard arm parses', () {
      final m = _asMatch(_parse('match x { case _ => x }'));
      expect(m.scrutinee.kind, const SIdentKind('x'));
      expect(m.motive, isNull);
      expect(m.cases, hasLength(1));
      expect(m.cases.single, isA<SWildcardCase>());
      final w = m.cases.single as SWildcardCase;
      expect(w.body.kind, const SIdentKind('x'));
    });

    test('single ctor arm with zero binders', () {
      final m = _asMatch(_parse('match n { case zero => z }'));
      expect(m.cases, hasLength(1));
      final c = m.cases.single as SMatchCase;
      expect(c.ctor, 'zero');
      expect(c.binders, isEmpty);
      expect(c.body.kind, const SIdentKind('z'));
    });

    test('ctor with one binder', () {
      final m = _asMatch(_parse('match n { case succ p => p }'));
      final c = m.cases.single as SMatchCase;
      expect(c.ctor, 'succ');
      expect(c.binders, ['p']);
      expect(c.body.kind, const SIdentKind('p'));
    });

    test('ctor with multiple binders', () {
      final m = _asMatch(_parse('match xs { case cons x rest => rest }'));
      final c = m.cases.single as SMatchCase;
      expect(c.ctor, 'cons');
      expect(c.binders, ['x', 'rest']);
    });

    test('underscore binder preserved literally', () {
      final m = _asMatch(_parse('match xs { case cons _ rest => rest }'));
      final c = m.cases.single as SMatchCase;
      expect(c.binders, ['_', 'rest']);
    });

    test('two arms: no separator between them', () {
      final m = _asMatch(_parse('match n { case zero => z case succ p => p }'));
      expect(m.cases, hasLength(2));
      final zero = m.cases[0] as SMatchCase;
      final succ = m.cases[1] as SMatchCase;
      expect(zero.ctor, 'zero');
      expect(succ.ctor, 'succ');
      expect(succ.binders, ['p']);
    });

    test('three arms with mixed wildcard', () {
      final m = _asMatch(
        _parse('match x { case a => a case b => b case _ => c }'),
      );
      expect(m.cases, hasLength(3));
      expect(m.cases[0], isA<SMatchCase>());
      expect(m.cases[1], isA<SMatchCase>());
      expect(m.cases[2], isA<SWildcardCase>());
    });

    test('empty match parses (coverage check is elaboration-time)', () {
      final m = _asMatch(_parse('match x { }'));
      expect(m.cases, isEmpty);
    });
  });

  group('returning motive', () {
    test('explicit motive attaches', () {
      final m = _asMatch(_parse('match n returning P { case zero => tt }'));
      expect(m.motive, isNotNull);
      expect(m.motive!.kind, const SIdentKind('P'));
    });

    test('motive can be a compound expression', () {
      final m = _asMatch(
        _parse('match v returning (n: Nat) -> Type { case _ => Nat }'),
      );
      expect(m.motive, isNotNull);
      expect(m.motive!.kind, isA<SPiKind>());
    });

    test('motive absent → null', () {
      final m = _asMatch(_parse('match x { case _ => x }'));
      expect(m.motive, isNull);
    });
  });

  group('body expressions terminate at case / brace', () {
    test('application in body, terminated by next case', () {
      final m = _asMatch(
        _parse('match n { case zero => f x y case succ p => p }'),
      );
      final zero = m.cases[0] as SMatchCase;
      // `f x y` left-folds to App(App(f, x), y); must include all three.
      expect(zero.body.kind, isA<SAppKind>());
    });

    test('lambda in body, terminated by next case', () {
      final m = _asMatch(
        _parse('match v { case nil => (x: A) => x case cons _ _ => y }'),
      );
      expect((m.cases[0] as SMatchCase).body.kind, isA<SLamKind>());
    });

    test('nested match in a case body', () {
      final m = _asMatch(
        _parse(
          'match outer { case cons x rest => match rest { case nil => x case cons y _ => y } }',
        ),
      );
      final outer = m.cases.single as SMatchCase;
      expect(outer.body.kind, isA<SMatchKind>());
      final inner = outer.body.kind as SMatchKind;
      expect(inner.cases, hasLength(2));
    });
  });

  group('parenthesized and dotted scrutinees', () {
    test('parenthesized scrutinee', () {
      final m = _asMatch(_parse('match (f x) { case _ => y }'));
      expect(m.scrutinee.kind, isA<SAppKind>());
    });

    test('dotted qualifier scrutinee', () {
      final m = _asMatch(_parse('match Foo.bar { case _ => y }'));
      expect(m.scrutinee.kind, isA<SDotKind>());
    });
  });

  group('span discipline', () {
    test("match span covers 'match' through closing brace", () {
      const src = 'match x { case _ => y }';
      final e = _parse(src);
      expect(e.span.start, 0);
      expect(e.span.end, src.length);
    });

    test('each case span covers its own arm', () {
      const src = 'match n { case zero => z case succ p => p }';
      final m = _asMatch(_parse(src));
      final zero = m.cases[0] as SMatchCase;
      final succ = m.cases[1] as SMatchCase;
      expect(zero.span.start, src.indexOf('case zero'));
      expect(succ.span.start, src.indexOf('case succ'));
      expect(zero.span.start, lessThan(succ.span.start));
    });
  });

  group('reserved words', () {
    test("'match' cannot be used as an identifier", () {
      _expectParseFailure('match');
    });

    test("'case' cannot be used as an identifier", () {
      _expectParseFailure('case');
    });

    test("'returning' cannot be used as an identifier", () {
      _expectParseFailure('returning');
    });
  });

  group('malformed match → parse error', () {
    test('missing arrow after pattern', () {
      _expectParseFailure('match n { case zero z }');
    });

    test('unmatched brace', () {
      _expectParseFailure('match n { case zero => z');
    });

    test('missing body after arrow', () {
      _expectParseFailure('match n { case zero => }');
    });
  });
}
