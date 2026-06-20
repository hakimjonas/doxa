/// Tests for the Doxa code formatter.
library;

import 'dart:io';

import 'package:doxa/src/parse.dart' show parseProgram;
import 'package:doxa/src/surface.dart';
import 'package:doxa_tooling/src/format.dart' show formatSource, isFormatted;
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

void main() {
  group('canonical formatting', () {
    test('val declaration with type', () {
      final input = 'val x : Nat = zero';
      final expected = 'val x : Nat = zero\n';
      expect(formatSource(input), equals(expected));
    });

    test('val declaration without type', () {
      final input = 'val x = zero';
      final expected = 'val x = zero\n';
      expect(formatSource(input), equals(expected));
    });

    test('type alias', () {
      final input = 'type N = Nat';
      final expected = 'type N = Nat\n';
      expect(formatSource(input), equals(expected));
    });

    test('data declaration', () {
      final input = 'data Bool : Type { true : Bool; false : Bool }';
      final expected =
          'data Bool : Type {\n  true : Bool;\n  false : Bool;\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('data declaration with type params', () {
      final input =
          'data Option[A: Type] : Type { some : A -> Option A; none : Option A }';
      final expected =
          'data Option[A: Type] : Type {\n  some : A -> Option A;\n  none : Option A;\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration single-expression body', () {
      final input = 'fun double(x: Nat) : Nat = plus x x';
      final expected = 'fun double(x: Nat) : Nat = plus x x\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with implicit type params', () {
      final input = 'fun id{A: Type}(x: A) : A = x';
      final expected = 'fun id{A: Type}(x: A) : A = x\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with multiple explicit type params grouped', () {
      final input = 'fun compose[A: Type, B: Type](f: B, g: A) : A = f';
      final expected = 'fun compose[A: Type, B: Type](f: B, g: A) : A = f\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with termination_by annotation', () {
      // termination_by is parsed as part of the return-type expression.
      // The formatter extracts it and emits it in canonical form.
      final input = 'fun gcd(a: Nat, b: Nat) : Nat termination_by a b = a';
      final expected =
          'fun gcd(a: Nat, b: Nat) : Nat termination_by (a, b) = a\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with struct annotation', () {
      final input = 'fun f(a: Nat, b: Nat) : Nat {struct a} = plus a b';
      final expected = 'fun f(a: Nat, b: Nat) : Nat {struct a} = plus a b\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with multiple params', () {
      final input = 'fun add(x: Nat, y: Nat) : Nat = plus x y';
      final expected = 'fun add(x: Nat, y: Nat) : Nat = plus x y\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration block body', () {
      final input = 'fun f(x: Nat) : Nat { val y = x; y }';
      final expected = 'fun f(x: Nat) : Nat {\n  val y = x;\n  y\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('match expression', () {
      final input =
          'fun isZero(x: Nat) : Bool = match x { case zero => true case succ _ => false }';
      final expected =
          'fun isZero(x: Nat) : Bool = match x {\n  case zero => true\n  case succ _ => false\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('non-dependent arrow type', () {
      final input = 'fun f(x: A -> B) : A = x';
      final expected = 'fun f(x: A -> B) : A = x\n';
      expect(formatSource(input), equals(expected));
    });

    test('single data decl', () {
      final input = 'data Nat : Type { zero : Nat; succ : Nat -> Nat }';
      final expected =
          'data Nat : Type {\n  zero : Nat;\n  succ : Nat -> Nat;\n}\n';
      expect(formatSource(input), equals(expected));
    });
  });

  group('import sorting', () {
    test('sorts imports alphabetically', () {
      final input = 'import "z.doxa"\nimport "a.doxa"\nval x = zero';
      final expected = 'import "a.doxa"\n\nimport "z.doxa"\n\nval x = zero\n';
      expect(formatSource(input), equals(expected));
    });

    test('sorts imports by alias secondary', () {
      final input = 'import "b.doxa" as B\nimport "a.doxa" as A';
      final expected = 'import "a.doxa" as A\n\nimport "b.doxa" as B\n';
      expect(formatSource(input), equals(expected));
    });

    test('selective import preserved', () {
      final input = 'import "a.doxa" { foo, bar }';
      final expected = 'import "a.doxa" { foo, bar }\n';
      expect(formatSource(input), equals(expected));
    });
  });

  group('semicolon in output', () {
    test('data constructors separated by | are reformatted to ;', () {
      final input = 'data Bool : Type { true : Bool | false : Bool }';
      final expected =
          'data Bool : Type {\n  true : Bool;\n  false : Bool;\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('semicolons in block expressions', () {
      final input = 'fun f(x: Nat) : Nat { val y = x; y }';
      final expected = 'fun f(x: Nat) : Nat {\n  val y = x;\n  y\n}\n';
      expect(formatSource(input), equals(expected));
    });
  });

  group('idempotency', () {
    test('formatting already formatted output is a no-op', () {
      final input = 'val x : Nat = zero\n';
      expect(formatSource(input), equals(input));
    });

    test('format twice is identity', () {
      final source = 'val   x  :  Nat  =  zero';
      final once = formatSource(source);
      final twice = formatSource(once);
      expect(twice, equals(once));
    });
  });

  group('round-trip', () {
    test('formatted output parses successfully', () {
      final inputs = [
        'val x : Nat = zero',
        'type N = Nat',
        'data Bool : Type { true : Bool; false : Bool }',
        'fun f(x: Nat) : Nat = x',
        'fun f(x: Nat) : Nat { val y = x; y }',
      ];
      for (final input in inputs) {
        final formatted = formatSource(input);
        final result = parseProgram(formatted);
        expect(
          result,
          isA<Success<ParseError, SProgram>>(),
          reason: 'Failed to parse formatted output: "$formatted"',
        );
      }
    });
  });

  group('--check exit codes', () {
    test('formatted file returns true', () {
      final source = 'val x : Nat = zero\n';
      expect(isFormatted(source), isTrue);
    });

    test('unformatted file returns false', () {
      final source = 'val   x  :  Nat  =  zero';
      expect(isFormatted(source), isFalse);
    });
  });

  group('stdlib formatting', () {
    final stdlibDir = Directory('../lib/stdlib');

    test('all stdlib files type-check after formatting', () {
      if (!stdlibDir.existsSync()) return;
      final files =
          stdlibDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.doxa'))
              .where((f) => !f.path.endsWith('prelude.doxa'))
              .toList();
      for (final file in files) {
        final text = file.readAsStringSync();
        final formatted = formatSource(text);
        final result = parseProgram(formatted);
        expect(
          result,
          isA<Success<ParseError, SProgram>>(),
          reason: '${file.path} formatted output does not parse',
        );
      }
    });
  });
}
