/// Tests for tactics (`by { ... }` blocks) and theorem declarations.
library;

import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/elab.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

TopEnv _elab(String src) => elabProgram(_parse(src));

void main() {
  group('theorem parsing', () {
    test('theorem with by block parses', () {
      final r = parseProgram('theorem t : Type := by { refl }');
      expect(r, isA<Success<ParseError, SProgram>>());
    });

    test('theorem desugars to SValKind', () {
      final prog = _parse('theorem t : Type := by { refl }');
      expect(prog.decls[0].kind, isA<SValKind>());
      final val = prog.decls[0].kind as SValKind;
      expect(val.name, 't');
      expect(val.type, isNotNull);
    });

    test('theorem with = works (no :=)', () {
      final r = parseProgram('theorem t : Type = Type');
      expect(r, isA<Success<ParseError, SProgram>>());
    });

    test('theorem with := works', () {
      final r = parseProgram('theorem t : Type := Type');
      expect(r, isA<Success<ParseError, SProgram>>());
    });
  });

  group('by block parsing', () {
    test('by { refl } parses', () {
      final r = parseProgram('val x : Type = by { refl }');
      expect(r, isA<Success<ParseError, SProgram>>());
    });

    test('by { intro x; exact x } parses', () {
      final r = parseProgram('val x : Type = by { intro x; exact x }');
      expect(r, isA<Success<ParseError, SProgram>>());
    });

    test('by { refl | trivial } parses (alternatives)', () {
      final r = parseProgram('val x : Type = by { refl | trivial }');
      expect(r, isA<Success<ParseError, SProgram>>());
    });
  });

  group('tactic elaboration', () {
    test('intro and exact prove (A: Type) -> A -> A', () {
      final prog = _parse('''
val id : (A: Type) -> A -> A = by { intro A; intro x; exact x }
''');
      final env = elabProgram(prog);
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'id'),
        returnsNormally,
      );
    });

    test('by block in infer mode fails', () {
      expect(() => _elab('val x = by { refl }'), throwsA(isA<TacticFailed>()));
    });
  });
}
