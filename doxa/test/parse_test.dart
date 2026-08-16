import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Unwrap a parser success, asserting there's no leftover.
T unwrap<T>(Result<ParseError, T> r) {
  if (r is Success<ParseError, T>) return r.value;
  if (r is Partial<ParseError, T>) return r.value;
  fail('parse failed: $r');
}

/// Assert a parse error on [input].
void expectParseError(Result<ParseError, Object?> r) {
  expect(r, isA<Failure<ParseError, Object?>>());
}

/// Strip spans from an SExpr (recursively) for shape-only comparison.
SExprKind shape(SExpr e) {
  final k = e.kind;
  return switch (k) {
    SIdentKind() || STypeKind() || SPropKind() || SSPropKind() => k,
    SAppKind(:final fn, :final arg) => SAppKind(
      SExpr(shape(fn), DoxaSpan.synthetic),
      SExpr(shape(arg), DoxaSpan.synthetic),
    ),
    SLamKind(:final param, :final domain, :final body) => SLamKind(
      param,
      domain == null ? null : SExpr(shape(domain), DoxaSpan.synthetic),
      SExpr(shape(body), DoxaSpan.synthetic),
    ),
    SPiKind(:final param, :final domain, :final codomain) => SPiKind(
      param,
      SExpr(shape(domain), DoxaSpan.synthetic),
      SExpr(shape(codomain), DoxaSpan.synthetic),
    ),
    SLetKind(
      :final param,
      :final domain,
      :final bound,
      :final body,
      :final isRec,
    ) =>
      SLetKind(
        param,
        domain == null ? null : SExpr(shape(domain), DoxaSpan.synthetic),
        SExpr(shape(bound), DoxaSpan.synthetic),
        SExpr(shape(body), DoxaSpan.synthetic),
        isRec: isRec,
      ),
    SDotKind(:final qualifier, :final name) => SDotKind(
      SExpr(shape(qualifier), DoxaSpan.synthetic),
      name,
    ),
    SMatchKind(:final scrutinee, :final motive, :final cases) => SMatchKind(
      SExpr(shape(scrutinee), DoxaSpan.synthetic),
      motive == null ? null : SExpr(shape(motive), DoxaSpan.synthetic),
      [
        for (final arm in cases)
          switch (arm) {
            SMatchCase(:final ctor, :final binders, :final body) => SMatchCase(
              ctor,
              binders,
              SExpr(shape(body), DoxaSpan.synthetic),
              DoxaSpan.synthetic,
            ),
            SWildcardCase(:final body) => SWildcardCase(
              SExpr(shape(body), DoxaSpan.synthetic),
              DoxaSpan.synthetic,
            ),
          },
      ],
    ),
    SQuotKind(:final carrier, :final relation) => SQuotKind(
      SExpr(shape(carrier), DoxaSpan.synthetic),
      SExpr(shape(relation), DoxaSpan.synthetic),
    ),
    SQuotMkKind(:final arg) => SQuotMkKind(
      SExpr(shape(arg), DoxaSpan.synthetic),
    ),
    SQuotLiftKind(:final fn, :final proof) => SQuotLiftKind(
      SExpr(shape(fn), DoxaSpan.synthetic),
      SExpr(shape(proof), DoxaSpan.synthetic),
    ),
    SByKind() => k,
    SIntersectionKind() => k,
  };
}

void main() {
  group('atoms', () {
    test('identifier', () {
      final r = unwrap(parseExpr('foo'));
      expect(r.kind, const SIdentKind('foo'));
      expect(r.span.start, 0);
      expect(r.span.end, 3);
    });

    test('Type without level', () {
      final r = unwrap(parseExpr('Type'));
      expect(r.kind, const STypeKind(null));
    });

    test('Type 3', () {
      final r = unwrap(parseExpr('Type 3'));
      expect(r.kind, const STypeKind(3));
    });

    test('parenthesized identifier', () {
      final r = unwrap(parseExpr('(foo)'));
      expect(r.kind, const SIdentKind('foo'));
    });

    test('reserved word as identifier fails', () {
      expectParseError(parseExpr('val'));
      expectParseError(parseExpr('fun'));
    });

    test('"value" is NOT the keyword "val"', () {
      final r = unwrap(parseExpr('value'));
      expect(r.kind, const SIdentKind('value'));
    });
  });

  group('application (left-associative via pratt)', () {
    test('f x', () {
      final r = unwrap(parseExpr('f x'));
      expect(
        shape(r),
        const SAppKind(
          SExpr(SIdentKind('f'), DoxaSpan.synthetic),
          SExpr(SIdentKind('x'), DoxaSpan.synthetic),
        ),
      );
    });

    test('f x y is left-associative: ((f x) y)', () {
      final r = unwrap(parseExpr('f x y'));
      final s = shape(r);
      // Outer is SApp(SApp(f, x), y)
      expect(s, isA<SAppKind>());
      final outer = s as SAppKind;
      expect(outer.arg.kind, const SIdentKind('y'));
      expect(outer.fn.kind, isA<SAppKind>());
      final inner = outer.fn.kind as SAppKind;
      expect(inner.fn.kind, const SIdentKind('f'));
      expect(inner.arg.kind, const SIdentKind('x'));
    });

    test('application with parenthesized atom', () {
      final r = unwrap(parseExpr('f (g x)'));
      final s = shape(r) as SAppKind;
      expect(s.fn.kind, const SIdentKind('f'));
      expect(s.arg.kind, isA<SAppKind>());
    });

    test('long application chain folds left', () {
      final names = List.generate(20, (i) => 'a$i');
      final r = unwrap(parseExpr(names.join(' ')));
      // Walk the tree leftward collecting idents.
      final collected = <String>[];
      SExprKind k = r.kind;
      while (k is SAppKind) {
        final arg = k.arg.kind;
        if (arg is SIdentKind) collected.add(arg.name);
        k = k.fn.kind;
      }
      if (k is SIdentKind) collected.add(k.name);
      // collected is in right-to-left order of the original list.
      expect(collected.reversed.toList(), names);
    });
  });

  group('arrows and binders', () {
    test('non-dependent arrow A -> B', () {
      final r = unwrap(parseExpr('A -> B'));
      final k = r.kind as SPiKind;
      expect(k.param, isNull);
      expect(k.domain.kind, const SIdentKind('A'));
      expect(k.codomain.kind, const SIdentKind('B'));
    });

    test('right-associative: A -> B -> C', () {
      final r = unwrap(parseExpr('A -> B -> C'));
      final outer = r.kind as SPiKind;
      expect(outer.param, isNull);
      expect(outer.domain.kind, const SIdentKind('A'));
      final inner = outer.codomain.kind as SPiKind;
      expect(inner.param, isNull);
      expect(inner.domain.kind, const SIdentKind('B'));
      expect(inner.codomain.kind, const SIdentKind('C'));
    });

    test('dependent Pi (A: Type) -> A', () {
      final r = unwrap(parseExpr('(A: Type) -> A'));
      final k = r.kind as SPiKind;
      expect(k.param, 'A');
      expect(k.domain.kind, const STypeKind(null));
      expect(k.codomain.kind, const SIdentKind('A'));
    });

    test('lambda (x: Type) => x', () {
      final r = unwrap(parseExpr('(x: Type) => x'));
      final k = r.kind as SLamKind;
      expect(k.param, 'x');
      expect(k.domain?.kind, const STypeKind(null));
      expect(k.body.kind, const SIdentKind('x'));
    });

    test('nested lambda', () {
      final r = unwrap(parseExpr('(A: Type) => (x: A) => x'));
      final outer = r.kind as SLamKind;
      expect(outer.param, 'A');
      final inner = outer.body.kind as SLamKind;
      expect(inner.param, 'x');
    });

    test('unannotated lambda (x) => x', () {
      final r = unwrap(parseExpr('(x) => x'));
      final k = r.kind as SLamKind;
      expect(k.param, 'x');
      expect(k.domain, isNull);
      expect(k.body.kind, const SIdentKind('x'));
    });

    test('parenthesized atom (x) is not a lambda', () {
      // `(x)` not followed by `=>` must backtrack to a parenthesized
      // atom, not parse as a domain-less binder.
      final r = unwrap(parseExpr('(x)'));
      expect(r.kind, const SIdentKind('x'));
    });
  });

  group('declarations', () {
    test('val x = y', () {
      final r = unwrap(parseProgram('val x = y'));
      expect(r.decls, hasLength(1));
      final d = r.decls[0].kind as SValKind;
      expect(d.name, 'x');
      expect(d.type, isNull);
      expect(d.body.kind, const SIdentKind('y'));
    });

    test('val with type annotation', () {
      final r = unwrap(parseProgram('val x: Type = Type'));
      final d = r.decls[0].kind as SValKind;
      expect(d.name, 'x');
      expect(d.type?.kind, const STypeKind(null));
      expect(d.body.kind, const STypeKind(null));
    });

    test('type alias', () {
      final r = unwrap(parseProgram('type T = Type'));
      final d = r.decls[0].kind as STypeAliasKind;
      expect(d.name, 'T');
    });

    test('fun with params', () {
      final r = unwrap(parseProgram('fun id(x: A): A = x'));
      final d = r.decls[0].kind as SFunKind;
      expect(d.name, 'id');
      expect(d.typeParams, isEmpty);
      expect(d.params, hasLength(1));
      expect(d.params[0].$1, 'x');
      expect(d.params[0].$2.kind, const SIdentKind('A'));
      expect(d.returnType.kind, const SIdentKind('A'));
      expect(d.body.kind, const SIdentKind('x'));
    });

    test('fun with type params', () {
      final r = unwrap(parseProgram('fun id[A: Type](x: A): A = x'));
      final d = r.decls[0].kind as SFunKind;
      expect(d.typeParams, hasLength(1));
      expect(d.typeParams[0].name, 'A');
      expect(d.typeParams[0].kind?.kind, const STypeKind(null));
      expect(d.typeParams[0].isImplicit, isFalse);
    });

    test('fun with implicit type params', () {
      final r = unwrap(parseProgram('fun id{A: Type}(x: A): A = x'));
      final d = r.decls[0].kind as SFunKind;
      expect(d.typeParams, hasLength(1));
      expect(d.typeParams[0].name, 'A');
      expect(d.typeParams[0].kind?.kind, const STypeKind(null));
      expect(d.typeParams[0].isImplicit, isTrue);
    });

    test('fun mixing explicit and implicit type params', () {
      final r = unwrap(parseProgram('fun f[A: Type]{B: Type}(x: A): B = x'));
      final d = r.decls[0].kind as SFunKind;
      expect(d.typeParams, hasLength(2));
      expect(d.typeParams[0].name, 'A');
      expect(d.typeParams[0].isImplicit, isFalse);
      expect(d.typeParams[1].name, 'B');
      expect(d.typeParams[1].isImplicit, isTrue);
    });

    test('fun with multiple names in implicit group', () {
      final r = unwrap(parseProgram('fun g{A: Type, B: Type}(x: A): B = x'));
      final d = r.decls[0].kind as SFunKind;
      expect(d.typeParams, hasLength(2));
      expect(d.typeParams[0].name, 'A');
      expect(d.typeParams[0].isImplicit, isTrue);
      expect(d.typeParams[1].name, 'B');
      expect(d.typeParams[1].isImplicit, isTrue);
    });

    test('multiple declarations', () {
      final r = unwrap(parseProgram('val x = y val z = w'));
      expect(r.decls, hasLength(2));
    });

    test('missing declaration body reports one expression expectation', () {
      final result = parseProgram('val value : Type =\n');

      expect(result, isA<Failure<ParseError, SProgram>>());
      final failure = result as Failure<ParseError, SProgram>;
      expect(failure.furthest.offset, 'val value : Type =\n'.length);
      expect(
        failure.errors.whereType<CustomError>().map((error) => error.message),
        contains('expected an expression'),
      );
    });

    test('reads leading imports before a later incomplete declaration', () {
      final imports = parseLeadingImports(
        'import "dependency.doxa"\nval value : Type =\n',
      );

      expect(imports, hasLength(1));
      expect((imports.single.kind as SImportKind).path, 'dependency.doxa');
    });
  });

  group('comments and whitespace', () {
    test('line comment is skipped', () {
      final r = unwrap(parseExpr('// leading\n foo'));
      expect(r.kind, const SIdentKind('foo'));
    });

    test('block comment is skipped', () {
      final r = unwrap(parseExpr('/* block */ foo'));
      expect(r.kind, const SIdentKind('foo'));
    });

    test('nested block comment', () {
      final r = unwrap(parseExpr('/* outer /* inner */ still outer */ foo'));
      expect(r.kind, const SIdentKind('foo'));
    });

    test('mixed whitespace and comments', () {
      final r = unwrap(parseExpr('// first\n  /* block */ foo\n // trailing'));
      expect(r.kind, const SIdentKind('foo'));
    });
  });

  group('spans', () {
    test('simple ident span covers the identifier', () {
      final r = unwrap(parseExpr('hello'));
      expect(r.span, const DoxaSpan(0, 5));
    });

    test('ident span excludes trailing whitespace', () {
      final r = unwrap(parseExpr('hello '));
      expect(r.span, const DoxaSpan(0, 5));
    });

    test('application span covers both subterms', () {
      final r = unwrap(parseExpr('f x'));
      expect(r.span.start, 0);
      expect(r.span.end, 3);
    });

    test('lambda span covers everything from ( to body end', () {
      final r = unwrap(parseExpr('(x: A) => x'));
      expect(r.span.start, 0);
      expect(r.span.end, 11);
    });

    test('binder spans cover identifier tokens', () {
      final lambda = unwrap(parseExpr('(x: A) => x')).kind as SLamKind;
      final pi = unwrap(parseExpr('(x: A) -> x')).kind as SPiKind;
      final fun =
          unwrap(
                parseProgram('fun id[A: Type](value: A) : A = value'),
              ).decls.single.kind
              as SFunKind;

      expect(lambda.paramSpan, const DoxaSpan(1, 2));
      expect(pi.paramSpan, const DoxaSpan(1, 2));
      expect(fun.typeParams.single.span, const DoxaSpan(7, 8));
      expect(fun.paramSpans.single, const DoxaSpan(16, 21));
    });
  });
}
