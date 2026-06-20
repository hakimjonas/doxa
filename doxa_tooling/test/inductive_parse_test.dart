/// Parser tests for inductive declarations and type-level application
/// at use sites.
library;

import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

// Re-used helpers, keep local to avoid coupling to parse_test.dart.

T _unwrap<T>(Result<ParseError, T> r) {
  if (r is Success<ParseError, T>) return r.value;
  if (r is Partial<ParseError, T>) return r.value;
  fail('parse failed: $r');
}

/// Strip spans from an SExpr (recursively) for shape-only comparison.
SExprKind _shape(SExpr e) {
  final k = e.kind;
  return switch (k) {
    SIdentKind() || STypeKind() || SPropKind() || SSPropKind() => k,
    SAppKind(:final fn, :final arg) => SAppKind(
      SExpr(_shape(fn), DoxaSpan.synthetic),
      SExpr(_shape(arg), DoxaSpan.synthetic),
    ),
    SLamKind(:final param, :final domain, :final body) => SLamKind(
      param,
      domain == null ? null : SExpr(_shape(domain), DoxaSpan.synthetic),
      SExpr(_shape(body), DoxaSpan.synthetic),
    ),
    SPiKind(:final param, :final domain, :final codomain) => SPiKind(
      param,
      SExpr(_shape(domain), DoxaSpan.synthetic),
      SExpr(_shape(codomain), DoxaSpan.synthetic),
    ),
    SLetKind(:final param, :final domain, :final bound, :final body) =>
      SLetKind(
        param,
        domain == null ? null : SExpr(_shape(domain), DoxaSpan.synthetic),
        SExpr(_shape(bound), DoxaSpan.synthetic),
        SExpr(_shape(body), DoxaSpan.synthetic),
      ),
    SDotKind(:final qualifier, :final name) => SDotKind(
      SExpr(_shape(qualifier), DoxaSpan.synthetic),
      name,
    ),
    SMatchKind(:final scrutinee, :final motive, :final cases) => SMatchKind(
      SExpr(_shape(scrutinee), DoxaSpan.synthetic),
      motive == null ? null : SExpr(_shape(motive), DoxaSpan.synthetic),
      [
        for (final arm in cases)
          switch (arm) {
            SMatchCase(:final ctor, :final binders, :final body) => SMatchCase(
              ctor,
              binders,
              SExpr(_shape(body), DoxaSpan.synthetic),
              DoxaSpan.synthetic,
            ),
            SWildcardCase(:final body) => SWildcardCase(
              SExpr(_shape(body), DoxaSpan.synthetic),
              DoxaSpan.synthetic,
            ),
          },
      ],
    ),
    SQuotKind(:final carrier, :final relation) => SQuotKind(
      SExpr(_shape(carrier), DoxaSpan.synthetic),
      SExpr(_shape(relation), DoxaSpan.synthetic),
    ),
    SQuotMkKind(:final arg) => SQuotMkKind(
      SExpr(_shape(arg), DoxaSpan.synthetic),
    ),
    SQuotLiftKind(:final fn, :final proof) => SQuotLiftKind(
      SExpr(_shape(fn), DoxaSpan.synthetic),
      SExpr(_shape(proof), DoxaSpan.synthetic),
    ),
    SByKind() => k,
    SIntersectionKind() => k,
  };
}

SExpr _id(String name) => SExpr(SIdentKind(name), DoxaSpan.synthetic);

SExpr _app(SExpr fn, SExpr arg) => SExpr(SAppKind(fn, arg), DoxaSpan.synthetic);

SExpr _type(int? level) => SExpr(STypeKind(level), DoxaSpan.synthetic);

SExpr _piAnon(SExpr domain, SExpr codomain) =>
    SExpr(SPiKind(null, domain, codomain), DoxaSpan.synthetic);

SExpr _pi(String name, SExpr domain, SExpr codomain) =>
    SExpr(SPiKind(name, domain, codomain), DoxaSpan.synthetic);

void main() {
  group('type-level application at use sites', () {
    test('List[A] parses as App(List, A)', () {
      final r = _unwrap(parseExpr('List[A]'));
      expect(_shape(r), equals(_shape(_app(_id('List'), _id('A')))));
    });

    test('Map[K, V] parses as App(App(Map, K), V)', () {
      final r = _unwrap(parseExpr('Map[K, V]'));
      expect(
        _shape(r),
        equals(_shape(_app(_app(_id('Map'), _id('K')), _id('V')))),
      );
    });

    test('Vec[A] n: bracket app then juxtaposed value arg', () {
      final r = _unwrap(parseExpr('Vec[A] n'));
      expect(
        _shape(r),
        equals(_shape(_app(_app(_id('Vec'), _id('A')), _id('n')))),
      );
    });

    test('Vec[A] (succ n): bracket app then parenthesized juxtaposition', () {
      final r = _unwrap(parseExpr('Vec[A] (succ n)'));
      expect(
        _shape(r),
        equals(
          _shape(_app(_app(_id('Vec'), _id('A')), _app(_id('succ'), _id('n')))),
        ),
      );
    });

    test('List[Option[Nat]] nests correctly', () {
      final r = _unwrap(parseExpr('List[Option[Nat]]'));
      expect(
        _shape(r),
        equals(_shape(_app(_id('List'), _app(_id('Option'), _id('Nat'))))),
      );
    });

    test('bare identifier still parses (no type args)', () {
      final r = _unwrap(parseExpr('Nat'));
      expect(r.kind, const SIdentKind('Nat'));
    });

    test('Type keyword does not accept type args (not identifier)', () {
      // `Type` takes a level, not bracket args, so it is not an
      // identifier atom: `]` cannot follow it and the parse fails.
      final r = parseExpr('Type[A]');
      expect(r, isA<Failure<ParseError, SExpr>>());
    });
  });

  group('data declaration: non-parametric', () {
    test('data Nat with zero and succ', () {
      const src = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''';
      final prog = _unwrap(parseProgram(src));
      expect(prog.decls, hasLength(1));
      final decl = prog.decls.first;
      final kind = decl.kind;
      expect(kind, isA<SDataKind>());
      final data = kind as SDataKind;
      expect(data.name, 'Nat');
      expect(data.typeParams, isEmpty);
      expect(_shape(data.signature), _shape(_type(null)));
      expect(data.ctors, hasLength(2));
      expect(data.ctors[0].name, 'zero');
      expect(_shape(data.ctors[0].type), _shape(_id('Nat')));
      expect(data.ctors[1].name, 'succ');
      expect(
        _shape(data.ctors[1].type),
        _shape(_piAnon(_id('Nat'), _id('Nat'))),
      );
    });

    test('trailing semicolon after last ctor is accepted', () {
      const src = '''
data Bool : Type {
  true_ : Bool;
  false_ : Bool;
}
''';
      final prog = _unwrap(parseProgram(src));
      final data = prog.decls.first.kind as SDataKind;
      expect(data.ctors, hasLength(2));
      expect(data.ctors.map((c) => c.name), ['true_', 'false_']);
    });

    test('missing semicolon after last ctor also accepted', () {
      const src = '''
data Bool : Type {
  true_ : Bool;
  false_ : Bool
}
''';
      final prog = _unwrap(parseProgram(src));
      final data = prog.decls.first.kind as SDataKind;
      expect(data.ctors, hasLength(2));
    });
  });

  group('data declaration: parametric', () {
    test('data List[A: Type]', () {
      const src = '''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}
''';
      final prog = _unwrap(parseProgram(src));
      final data = prog.decls.first.kind as SDataKind;
      expect(data.name, 'List');
      expect(data.typeParams, hasLength(1));
      expect(data.typeParams.first.$1, 'A');
      expect(_shape(data.typeParams.first.$2!), _shape(_type(null)));
      expect(_shape(data.signature), _shape(_type(null)));
      expect(data.ctors, hasLength(2));

      // nil : List[A]
      expect(data.ctors[0].name, 'nil');
      expect(_shape(data.ctors[0].type), _shape(_app(_id('List'), _id('A'))));

      // cons : A -> List[A] -> List[A]
      expect(data.ctors[1].name, 'cons');
      expect(
        _shape(data.ctors[1].type),
        _shape(
          _piAnon(
            _id('A'),
            _piAnon(_app(_id('List'), _id('A')), _app(_id('List'), _id('A'))),
          ),
        ),
      );
    });
  });

  group('data declaration: indexed family', () {
    test('data Vec[A: Type] : Nat -> Type', () {
      const src = '''
data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''';
      final prog = _unwrap(parseProgram(src));
      final data = prog.decls.first.kind as SDataKind;
      expect(data.name, 'Vec');
      expect(data.typeParams, hasLength(1));
      expect(data.typeParams.first.$1, 'A');

      // signature is `Nat -> Type`, a Pi chain with codomain Type.
      expect(_shape(data.signature), _shape(_piAnon(_id('Nat'), _type(null))));

      expect(data.ctors, hasLength(2));

      // vnil : Vec[A] zero
      expect(data.ctors[0].name, 'vnil');
      expect(
        _shape(data.ctors[0].type),
        _shape(_app(_app(_id('Vec'), _id('A')), _id('zero'))),
      );

      // vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n)
      expect(data.ctors[1].name, 'vcons');
      expect(
        _shape(data.ctors[1].type),
        _shape(
          _pi(
            'n',
            _id('Nat'),
            _piAnon(
              _id('A'),
              _piAnon(
                _app(_app(_id('Vec'), _id('A')), _id('n')),
                _app(_app(_id('Vec'), _id('A')), _app(_id('succ'), _id('n'))),
              ),
            ),
          ),
        ),
      );
    });
  });

  group('data declaration: edge cases', () {
    test('data with explicit Type 1', () {
      const src = '''
data Big : Type 1 {
  it : Big;
}
''';
      final prog = _unwrap(parseProgram(src));
      final data = prog.decls.first.kind as SDataKind;
      expect(_shape(data.signature), _shape(_type(1)));
    });

    test('data with Prop sort', () {
      const src = '''
data P : Prop {
  it : P;
}
''';
      final prog = _unwrap(parseProgram(src));
      final data = prog.decls.first.kind as SDataKind;
      expect(data.signature.kind, isA<SPropKind>());
    });

    test('data with empty ctor list', () {
      // Parser accepts; elaborator is expected to reject later.
      const src = 'data Void : Type { }';
      final prog = _unwrap(parseProgram(src));
      final data = prog.decls.first.kind as SDataKind;
      expect(data.ctors, isEmpty);
    });

    test('data followed by another declaration', () {
      const src = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val example : Nat = zero
''';
      final prog = _unwrap(parseProgram(src));
      expect(prog.decls, hasLength(2));
      expect(prog.decls[0].kind, isA<SDataKind>());
      expect(prog.decls[1].kind, isA<SValKind>());
    });

    test('data span covers from `data` to closing `}`', () {
      const src = 'data Unit : Type { it : Unit; }';
      final prog = _unwrap(parseProgram(src));
      final decl = prog.decls.first;
      expect(decl.span.start, 0);
      expect(decl.span.end, src.length);
    });
  });

  group('data declaration: does not accept malformed', () {
    test('missing colon after data name', () {
      final r = parseProgram('data Nat { zero : Nat; }');
      expect(r, isA<Failure<ParseError, SProgram>>());
    });

    test('missing braces', () {
      final r = parseProgram('data Nat : Type');
      expect(r, isA<Failure<ParseError, SProgram>>());
    });

    test('ctor without type annotation', () {
      final r = parseProgram('data Nat : Type { zero ; succ : Nat -> Nat; }');
      expect(r, isA<Failure<ParseError, SProgram>>());
    });
  });
}
