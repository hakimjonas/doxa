/// Tests for the Doxa code formatter.
library;

import 'dart:io';

import 'package:doxa/src/parse.dart' show parseProgram;
import 'package:doxa/src/surface.dart';
import 'package:doxa_tooling/src/format.dart' show formatSource, isFormatted;
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

void main() {
  group('formatSource line width', () {
    test('rejects unusably narrow widths', () {
      expect(
        () => formatSource('val x: Type = Type', lineWidth: 19),
        throwsArgumentError,
      );
    });
  });

  group('canonical formatting', () {
    test('val declaration with type', () {
      const input = 'val x : Nat = zero';
      const expected = 'val x: Nat = zero\n';
      expect(formatSource(input), equals(expected));
    });

    test('val declaration without type', () {
      const input = 'val x = zero';
      const expected = 'val x = zero\n';
      expect(formatSource(input), equals(expected));
    });

    test('type alias', () {
      const input = 'type N = Nat';
      const expected = 'type N = Nat\n';
      expect(formatSource(input), equals(expected));
    });

    test('data declaration', () {
      const input = 'data Bool : Type { true : Bool; false : Bool }';
      const expected = 'data Bool: Type {\n  true: Bool;\n  false: Bool;\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('data declaration with type params', () {
      const input =
          'data Option[A: Type] : Type { some : A -> Option A; none : Option A }';
      const expected =
          'data Option[A: Type]: Type {\n  some: A -> Option A;\n  none: Option A;\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration single-expression body', () {
      const input = 'fun double(x: Nat) : Nat = plus x x';
      const expected = 'fun double(x: Nat): Nat = plus x x\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with implicit type params', () {
      const input = 'fun id{A: Type}(x: A) : A = x';
      const expected = 'fun id{A: Type}(x: A): A = x\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with multiple explicit type params grouped', () {
      const input = 'fun compose[A: Type, B: Type](f: B, g: A) : A = f';
      const expected = 'fun compose[A: Type, B: Type](f: B, g: A): A = f\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with termination_by annotation', () {
      // termination_by is parsed as part of the return-type expression.
      // The formatter extracts it and emits it in canonical form.
      const input = 'fun gcd(a: Nat, b: Nat) : Nat termination_by a b = a';
      const expected = 'fun gcd(a: Nat, b: Nat): Nat termination_by a b = a\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with struct annotation', () {
      const input = 'fun f(a: Nat, b: Nat) : Nat {struct a} = plus a b';
      const expected = 'fun f(a: Nat, b: Nat): Nat {struct a} = plus a b\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration with multiple params', () {
      const input = 'fun add(x: Nat, y: Nat) : Nat = plus x y';
      const expected = 'fun add(x: Nat, y: Nat): Nat = plus x y\n';
      expect(formatSource(input), equals(expected));
    });

    test('fun declaration block body', () {
      const input = 'fun f(x: Nat) : Nat { val y = x; y }';
      const expected = 'fun f(x: Nat): Nat {\n  val y = x;\n  y\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('match expression', () {
      const input =
          'fun isZero(x: Nat) : Bool = match x { case zero => true case succ _ => false }';
      const expected =
          'fun isZero(x: Nat): Bool = match x {\n  case zero => true\n  case succ _ => false\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('non-dependent arrow type', () {
      const input = 'fun f(x: A -> B) : A = x';
      const expected = 'fun f(x: A -> B): A = x\n';
      expect(formatSource(input), equals(expected));
    });

    test('single data decl', () {
      const input = 'data Nat : Type { zero : Nat; succ : Nat -> Nat }';
      const expected =
          'data Nat: Type {\n  zero: Nat;\n  succ: Nat -> Nat;\n}\n';
      expect(formatSource(input), equals(expected));
    });
  });

  group('imports', () {
    test('preserves import order', () {
      const input = 'import "z.doxa"\nimport "a.doxa"\nval x = zero';
      const expected = 'import "z.doxa"\n\nimport "a.doxa"\n\nval x = zero\n';
      expect(formatSource(input), equals(expected));
    });

    test('selective import preserved', () {
      const input = 'import "a.doxa" { foo, bar }';
      const expected = 'import "a.doxa" { foo, bar }\n';
      expect(formatSource(input), equals(expected));
    });
  });

  group('semicolon in output', () {
    test('data constructors separated by | are reformatted to ;', () {
      const input = 'data Bool : Type { true : Bool | false : Bool }';
      const expected = 'data Bool: Type {\n  true: Bool;\n  false: Bool;\n}\n';
      expect(formatSource(input), equals(expected));
    });

    test('semicolons in block expressions', () {
      const input = 'fun f(x: Nat) : Nat { val y = x; y }';
      const expected = 'fun f(x: Nat): Nat {\n  val y = x;\n  y\n}\n';
      expect(formatSource(input), equals(expected));
    });
  });

  group('idempotency', () {
    test('formatting already formatted output is a no-op', () {
      const input = 'val x: Nat = zero\n';
      expect(formatSource(input), equals(input));
    });

    test('format twice is identity', () {
      const source = 'val   x:  Nat  =  zero';
      final once = formatSource(source);
      final twice = formatSource(once);
      expect(twice, equals(once));
    });

    test('preserves comment-looking text inside import paths', () {
      const source = 'import "https://example.doxa"\nval x = zero';
      final formatted = formatSource(source);
      expect(
        formatted,
        equals('import "https://example.doxa"\n\nval x = zero\n'),
      );
      expect(formatSource(formatted), equals(formatted));
    });

    test('preserves nested block comments', () {
      const source = '/* outer /* inner */ retained */\nval x = zero';
      final formatted = formatSource(source);
      expect(formatted, contains('/* outer /* inner */ retained */'));
      expect(formatSource(formatted), equals(formatted));
    });

    test('keeps comments local to data entries', () {
      const source = '''
data Bool : Type {
  // true branch
  true : Bool;
  /* false branch */
  false : Bool;
}
''';
      const expected = '''
data Bool: Type {
  // true branch
  true: Bool;
  /* false branch */
  false: Bool;
}
''';
      expect(formatSource(source), equals(expected));
    });

    test('keeps declaration comments outside data bodies', () {
      const source = '''
data A : Type { a : A; }
// Documentation for B.
data B : Type { b : B; }
''';
      const expected = '''
data A: Type {
  a: A;
}
// Documentation for B.

data B: Type {
  b: B;
}
''';
      final formatted = formatSource(source);
      expect(formatted, equals(expected));
      expect(formatted, isNot(contains(RegExp(r'[ \t]+\n'))));
    });

    test('keeps comments local to match cases', () {
      const source = '''
val choose = match b {
  // chosen when true
  case true => left
  // chosen when false
  case false => right
}
''';
      const expected = '''
val choose = match b {
  // chosen when true
  case true => left
  // chosen when false
  case false => right
}
''';
      expect(formatSource(source), equals(expected));
    });

    test('keeps comments local to block bindings', () {
      const source = '''
fun f(x: Nat): Nat {
  // retained before the first binding
  val y = x;
  // retained before the second binding
  val z = y;
  z
}
''';
      const expected = '''
fun f(x: Nat): Nat {
  // retained before the first binding
  val y = x;
  // retained before the second binding
  val z = y;
  z
}
''';
      expect(formatSource(source), equals(expected));
    });

    test('moves trailing comments to their own line', () {
      const source =
          'fun f(x: Nat): Nat = match x { case zero => zero }// tail\n'
          'val x = zero';
      expect(formatSource(source), contains('}\n// tail\n\nval x = zero\n'));
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

    test('preserves syntax requiring application parentheses', () {
      const input = 'val id = ((x: Nat) => x) zero';
      const expected = 'val id = ((x: Nat) => x) zero\n';
      final formatted = formatSource(input);
      expect(formatted, equals(expected));
      _expectParses(formatted);
    });

    test('preserves match arguments', () {
      const input = 'val x = f (match n { case zero => a })';
      final formatted = formatSource(input);
      expect(formatted, contains('(match n {'));
      _expectParses(formatted);
    });

    test('uses the accepted quotient syntax', () {
      const input = 'val q = mk x\nval liftQ = lift(f, p)';
      final formatted = formatSource(input);
      expect(formatted, contains('val q = mk x'));
      expect(formatted, contains('val liftQ = lift(f, p)'));
      _expectParses(formatted);
    });

    test('retains theorem types for by blocks', () {
      const input = 'theorem p: Prop := by { trivial }';
      final formatted = formatSource(input);
      expect(formatted, contains('theorem p: Prop := by {'));
      _expectParses(formatted);
    });

    test('prints termination_by in its accepted application form', () {
      const input = 'fun gcd(a: Nat, b: Nat): Nat termination_by a b = a';
      final formatted = formatSource(input);
      expect(
        formatted,
        equals('fun gcd(a: Nat, b: Nat): Nat termination_by a b = a\n'),
      );
      _expectParses(formatted);
    });

    test('prints opaque once for a mutual function block', () {
      const input = 'opaque fun f(x: Nat): Nat = x and g(x: Nat): Nat = x';
      final formatted = formatSource(input);
      expect(formatted, contains('and g(x: Nat): Nat = x'));
      expect(formatted, isNot(contains('and opaque g')));
      _expectParses(formatted);
    });

    test('preserves all implementation type arguments', () {
      const input = 'impl C[A, B] {}';
      final formatted = formatSource(input);
      expect(formatted, contains('impl C[A, B] {'));
      _expectParses(formatted);
    });

    test('keeps parentheses around low-precedence Pi domains', () {
      const input = 'val f: ((x: A) => x) -> B = f';
      const expected = 'val f: ((x: A) => x) -> B = f\n';
      final formatted = formatSource(input);
      expect(formatted, equals(expected));
      final type = _singleVal(formatted).type!.kind as SPiKind;
      expect(type.domain.kind, isA<SLamKind>());
    });

    test('keeps match and quotient Pi domains parenthesized', () {
      const input = '''
val matchType: Type = (match x { case c => A }) -> B
val quotientType: Type = (mk x) -> B
''';
      final formatted = formatSource(input);
      expect(formatted, contains('(match x {'));
      expect(formatted, contains('(mk x) -> B'));
      _expectParses(formatted);
    });

    test('preserves product-form data syntax', () {
      const input = 'data Pair[A: Type] : Type { fst : A; snd : A; }';
      const expected = '''
data Pair[A: Type]: Type {
  fst: A;
  snd: A;
}
''';
      final formatted = formatSource(input);
      expect(formatted, equals(expected));
      final data = _singleData(formatted);
      expect(data.productFields, isNotNull);
      expect(data.ctors.single.name, equals('mk'));
    });

    test('soft-wraps long application right-hand sides', () {
      const input =
          'val result: Type = functionName firstArgument secondArgument';
      const expected = '''
val result: Type =
  functionName
    firstArgument
    secondArgument
''';
      final formatted = formatSource(input, lineWidth: 20);
      expect(formatted, equals(expected));
      expect(formatSource(formatted, lineWidth: 20), equals(formatted));
    });

    test('preserves implicit method return types', () {
      const input = 'typeclass C { fun f: {x: Nat} -> Nat; }';
      final formatted = formatSource(input);
      expect(formatted, contains('fun f(): {x: Nat} -> Nat;'));
      _expectParses(formatted);
    });
  });

  group('--check exit codes', () {
    test('formatted file returns true', () {
      const source = 'val x: Nat = zero\n';
      expect(isFormatted(source), isTrue);
    });

    test('unformatted file returns false', () {
      const source = 'val   x  :  Nat  =  zero';
      expect(isFormatted(source), isFalse);
    });

    test('parse errors are not considered formatted', () {
      expect(() => isFormatted('val x = )'), throwsFormatException);
    });
  });

  group('stdlib formatting', () {
    final stdlibDir = Directory('../lib/stdlib');

    test('all stdlib files parse after formatting', () {
      if (!stdlibDir.existsSync()) return;
      final files =
          stdlibDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.doxa'))
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

void _expectParses(String source) {
  expect(parseProgram(source), isA<Success<ParseError, SProgram>>());
}

SValKind _singleVal(String source) =>
    (parseProgram(source) as Success<ParseError, SProgram>)
            .value
            .decls
            .single
            .kind
        as SValKind;

SDataKind _singleData(String source) =>
    (parseProgram(source) as Success<ParseError, SProgram>)
            .value
            .decls
            .single
            .kind
        as SDataKind;
