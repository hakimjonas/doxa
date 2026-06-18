import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Parse + elaborate a single expression in the empty top env.
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
  group('Atoms', () {
    test('Type 0 prints as Type', () {
      expect(prettyTerm(const TType(0)), 'Type');
    });

    test('Type 3 prints as "Type 3"', () {
      expect(prettyTerm(const TType(3)), 'Type 3');
    });

    test('free variable prints its name', () {
      expect(prettyTerm(const TFree('foo')), 'foo');
    });
  });

  group('Binders preserve source names', () {
    test('lambda with source name', () {
      expect(prettyTerm(ee('(x: Type) => x')), '(x: Type) => x');
    });

    test('Pi with source name', () {
      expect(prettyTerm(ee('(A: Type) -> A')), '(A: Type) -> A');
    });

    test('nested lambdas keep distinct names', () {
      expect(
        prettyTerm(ee('(A: Type) => (x: A) => x')),
        '(A: Type) => (x: A) => x',
      );
    });

    test('names survive normalization', () {
      // nf should preserve names through eval+quote.
      final t = ee('(A: Type) => (x: A) => x');
      expect(prettyTerm(nf(t)), '(A: Type) => (x: A) => x');
    });
  });

  group('Non-dependent arrows', () {
    test('simple non-dep arrow uses short syntax', () {
      // Top-level parse produces `A -> B` as SPi(param: null, ...).
      // To avoid UnresolvedName, wrap in binders.
      expect(
        prettyTerm(ee('(A: Type) => (B: Type) => A -> B')),
        '(A: Type) => (B: Type) => A -> B',
      );
    });

    test('arrows are right-associative in output', () {
      expect(
        prettyTerm(ee('(A: Type) => (B: Type) => (C: Type) => A -> B -> C')),
        '(A: Type) => (B: Type) => (C: Type) => A -> B -> C',
      );
    });

    test('dependent Pi where codomain uses binder stays in (x:T) form', () {
      expect(prettyTerm(ee('(A: Type) -> A')), '(A: Type) -> A');
    });
  });

  group('Application precedence', () {
    test('f x y is left-associative', () {
      expect(
        prettyTerm(ee('(f: Type) => (x: Type) => (y: Type) => f x y')),
        '(f: Type) => (x: Type) => (y: Type) => f x y',
      );
    });

    test('f (g x) parenthesizes the inner app', () {
      expect(
        prettyTerm(ee('(f: Type) => (g: Type) => (x: Type) => f (g x)')),
        '(f: Type) => (g: Type) => (x: Type) => f (g x)',
      );
    });
  });

  group('Shadowing', () {
    test('same-name binders become name_1, name_2', () {
      final t = ee('(x: Type) => (x: Type) => x');
      final printed = prettyTerm(t);
      expect(printed, startsWith('(x: Type) => (x_1: Type) => '));
      // The body's TBound(0) refers to the *inner* binder (x_1).
      expect(printed, endsWith('x_1'));
    });
  });

  group('Synthesized names where no hint', () {
    test('TLam with null name gets a fresh synthesized name', () {
      const t = TLam(TType(0), TBound(0));
      final printed = prettyTerm(t);
      // The synthesized name should be something like `_a`.
      expect(printed, matches(r'^\(_[a-z]+\d*: Type\) => _[a-z]+\d*$'));
    });
  });
}
