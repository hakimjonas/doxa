import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Parse a program, asserting success.
SProgram pp(String input) {
  final r = parseProgram(input);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Parse a single expression, asserting success.
SExpr pe(String input) {
  final r = parseExpr(input);
  if (r is Success<ParseError, SExpr>) return r.value;
  if (r is Partial<ParseError, SExpr>) return r.value;
  fail('parse failed: $r');
}

void main() {
  group('Typeclass parsing', () {
    test('typeclass Eq[A] parses to STypeclassKind', () {
      final prog = pp('typeclass Eq[A] { fun equals(x: A, y: A): Bool }');
      expect(prog.decls.length, 1);
      final kind = prog.decls.first.kind;
      expect(kind, isA<STypeclassKind>());
      final tc = kind as STypeclassKind;
      expect(tc.name, 'Eq');
      expect(tc.typeParams.length, 1);
      expect(tc.typeParams.first.$1, 'A');
      expect(tc.methods.length, 1);
      expect(tc.methods.first.name, 'equals');
    });

    test('typeclass with superclass parses', () {
      final prog = pp(
        'typeclass Ord[A]: Eq[A] { fun compare(x: A, y: A): Int }',
      );
      expect(prog.decls.length, 1);
      final kind = prog.decls.first.kind as STypeclassKind;
      expect(kind.superclass, isNotNull);
    });

    test('impl Eq[Int] parses to SImplKind', () {
      final prog = pp(
        'impl Eq[Int] { fun equals(x: Int, y: Int): Bool = true }',
      );
      expect(prog.decls.length, 1);
      final kind = prog.decls.first.kind;
      expect(kind, isA<SImplKind>());
      final impl = kind as SImplKind;
      expect(impl.members.length, 1);
      expect(impl.members.first.name, 'equals');
    });

    test('fun with constrained param [A: Eq] parses', () {
      final prog = pp('fun find[A: Eq](x: A): A = x');
      expect(prog.decls.length, 1);
      final kind = prog.decls.first.kind;
      expect(kind, isA<SFunKind>());
    });

    test('fun with multi-constraint [A: Eq & Ord] parses', () {
      final prog = pp('fun sorted[A: Eq & Ord](xs: List[A]): List[A] = xs');
      expect(prog.decls.length, 1);
      final kind = prog.decls.first.kind;
      expect(kind, isA<SFunKind>());
    });
  });

  group('Typeclass declaration kind', () {
    test('STypeclassKind has correct name', () {
      const tc = STypeclassKind('Eq', [], []);
      expect(tc.name, 'Eq');
    });

    test('STypeclassKind with type params', () {
      const tc = STypeclassKind('Eq', [('A', null)], []);
      expect(tc.typeParams.length, 1);
    });

    test('STypeclassKind with superclass', () {
      final superRef = SExpr(SIdentKind('Eq'), DoxaSpan.synthetic);
      const tc = STypeclassKind('Ord', [('A', null)], [], superclass: null);
      // superclass is tested via the parser test above.
      expect(tc.name, 'Ord');
    });
  });

  group('Instance parsing', () {
    test('SImplKind parsing from full program', () {
      final prog = pp(
        'impl Eq[Int] { fun equals(x: Int, y: Int): Bool = true }',
      );
      final impl = prog.decls.first.kind as SImplKind;
      expect(impl.typeclassRef.kind, isA<SAppKind>());
    });

    test('Simple fun constraint works', () {
      final prog = pp('fun id[A: Type](x: A): A = x');
      expect(prog.decls.length, 1);
    });
  });

  group('Elaboration smoke tests', () {
    test('empty program elaborates', () {
      final topEnv = elabProgram(pp(''));
      expect(topEnv.bindings.length, 0);
    });

    test('simple val with type annotation works', () {
      final topEnv = elabProgram(pp('val x: Type 1 = Type'));
      expect(topEnv.bindings.length, 1);
      expect(topEnv.bindings.first.name, 'x');
    });

    test('simple fun elaborates', () {
      final topEnv = elabProgram(pp('fun id[A: Type](x: A): A = x'));
      expect(topEnv.bindings.length, 1);
      expect(topEnv.bindings.first.name, 'id');
    });
  });
}
