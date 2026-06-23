/// `fun` mutual / recursive declarations: parse, elab, structural-recursion check.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram pp(String src) {
  final r = parseProgram(src);
  return switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    _ => fail('parse failed: $r'),
  };
}

void main() {
  group('Parsing mutual blocks', () {
    test('single fun parses to SFunKind (not wrapped)', () {
      final p = pp('fun f(x: Type): Type = x');
      expect(p.decls, hasLength(1));
      expect(p.decls[0].kind, isA<SFunKind>());
    });

    test('fun + and parses to SFunBlockKind', () {
      final p = pp('''
        fun f(x: Type): Type = x
        and g(y: Type): Type = y
      ''');
      expect(p.decls, hasLength(1));
      expect(p.decls[0].kind, isA<SFunBlockKind>());
      final k = p.decls[0].kind as SFunBlockKind;
      expect(k.members.map((m) => m.fun.name).toList(), ['f', 'g']);
    });

    test('three-fun block', () {
      final p = pp('''
        fun f(x: Type): Type = x
        and g(x: Type): Type = x
        and h(x: Type): Type = x
      ''');
      expect(p.decls, hasLength(1));
      final k = p.decls[0].kind as SFunBlockKind;
      expect(k.members.map((m) => m.fun.name).toList(), ['f', 'g', 'h']);
    });

    test('`and` is reserved: cannot be an identifier', () {
      expect(parseExpr('and'), isA<Failure<ParseError, SExpr>>());
    });
  });

  group('Non-recursive mutual blocks elaborate', () {
    test('two funs that don\'t reference each other elaborate', () {
      final env = elabProgram(
        pp('''
        fun f(x: Type): Type = x
        and g(y: Type): Type = y
      '''),
      );
      expect(env.bindings, hasLength(2));
      expect(env.bindings[0].name, 'f');
      expect(env.bindings[1].name, 'g');
    });

    test('three-fun block elaborates when non-recursive', () {
      final env = elabProgram(
        pp('''
        fun f(x: Type): Type = x
        and g(x: Type): Type = x
        and h(x: Type): Type = x
      '''),
      );
      expect(env.bindings, hasLength(3));
    });
  });

  group('Non-structural recursion rejected', () {
    test('self-reference passing designated arg itself fails', () {
      // `fun f(x: Type): Type = f x`, `x` is the designated arg,
      // not a strict sub-term of itself.
      expect(
        () => elabProgram(
          pp('fun f(x: Type): Type = f x and g(x: Type): Type = x'),
        ),
        throwsA(
          isA<NonStructuralRecursion>().having(
            (e) => e.calleeName,
            'calleeName',
            'f',
          ),
        ),
      );
    });

    test(
      'mutual non-decrease accepted (no cycle: g calls non-recursive f)',
      () {
        final env = elabProgram(
          pp('''
        fun f(x: Type): Type = x
        and g(x: Type): Type = f x
      '''),
        );
        expect(env.bindings, hasLength(2));
        expect(env.bindings[0].name, 'f');
        expect(env.bindings[1].name, 'g');
      },
    );

    test('mutual reference through the return type fails at sig elab', () {
      expect(
        () => elabProgram(
          pp('''
          fun f(A: Type): Type = A
          and g(A: Type): f A = A
        '''),
        ),
        throwsA(isA<UnresolvedName>()),
      );
    });

    test('ref through a non-dep arrow codomain accepted (no cycle)', () {
      final env = elabProgram(
        pp('''
        fun f(A: Type): Type = A
        and g(A: Type): Type = A -> f A
      '''),
      );
      expect(env.bindings, hasLength(2));
      expect(env.bindings[0].name, 'f');
      expect(env.bindings[1].name, 'g');
    });

    test('ref inside a let body accepted (no cycle)', () {
      final env = elabProgram(
        pp('''
        fun f(A: Type): Type = A
        and g(A: Type): Type = { val x: Type = A; f x }
      '''),
      );
      expect(env.bindings, hasLength(2));
      expect(env.bindings[0].name, 'f');
      expect(env.bindings[1].name, 'g');
    });
  });

  group('Shadowing suppresses the structural check', () {
    test('shadowing through a let binder hides the block member', () {
      final env = elabProgram(
        pp('''
        fun f(A: Type): Type = A
        and g(A: Type): Type = { val f: Type = A; f }
      '''),
      );
      expect(env.bindings, hasLength(2));
    });

    test('shadowing: a param named like a block member is NOT flagged', () {
      final env = elabProgram(
        pp('''
        fun f(x: Type): Type = x
        and g(f: Type): Type = f
      '''),
      );
      expect(env.bindings, hasLength(2));
    });
  });

  group('Duplicate name detection', () {
    test('duplicates within a block are detected', () {
      expect(
        () => elabProgram(
          pp('''
          fun f(x: Type): Type = x
          and f(y: Type): Type = y
        '''),
        ),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });

    test('block member clashing with earlier top-level decl is detected', () {
      expect(
        () => elabProgram(
          pp('''
          val f: Type 1 = Type
          fun f(x: Type): Type = x
          and g(x: Type): Type = x
        '''),
        ),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });
  });
}
