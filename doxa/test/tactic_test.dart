/// Tests for tactics (`by { ... }` blocks) and theorem declarations.
library;

import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/elab.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

final PreludeData prelude = loadPrelude();

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate [src] starting from the prelude's bindings + dataDecls.
TopEnv _elab(String src) {
  var env = TopEnv(
    prelude.bindings,
    prelude.dataDecls,
    const {},
    prelude.namespaceBindings,
  );
  final prog = _parse(src);
  for (final decl in prog.decls) {
    final produced = elabDecl(env, decl);
    env = TopEnv(
      [...env.bindings, ...produced.bindings],
      [...env.dataDecls, ...produced.dataDecls],
      {...env.classRegistry, ...produced.classRegistry},
      mergeNamespace(env.namespaceBindings, produced.namespaceBindings),
    );
  }
  return env;
}

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

    test('rewrite using an equality', () {
      // Simpler: just rewrite.  The rewrite should leave a subgoal
      // of the same type (since x = x).  Needs prelude for Eq.
      final env = _elab('''
val rewrite_test : (A: Type) -> (x: A) -> (h: Eq A x x) -> Eq A x x =
  (A: Type) => (x: A) => (h: Eq A x x) => by { rewrite h; exact h }
''');
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'rewrite_test'),
        returnsNormally,
      );
    });

    test('rewrite identity test with trivial', () {
      final env = _elab('''
val rewrite_trivial : (A: Type) -> (x: A) -> (h: Eq A x x) -> Eq A x x =
  (A: Type) => (x: A) => (h: Eq A x x) => by { rewrite h | trivial; exact h }
''');
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'rewrite_trivial'),
        returnsNormally,
      );
    });

    test('induction on Eq using refl', () {
      // Prove: (A: Type) -> (x: A) -> (y: A) -> (h: Eq A x y) -> Eq A x y
      // by induction on h, then exact h (refl case).
      final env = _elab('''
val induction_eq : (A: Type) -> (x: A) -> (y: A) -> (h: Eq A x y) -> Eq A x y =
  (A: Type) => (x: A) => (y: A) => (h: Eq A x y) => by { induction h; exact h }
''');
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'induction_eq'),
        returnsNormally,
      );
    });

    test('induction creates subgoals and solves them', () {
      // Simple single-constructor type to avoid multi-subgoal sequencing.
      final env = _elab('''
data Wrap : Prop { wrap : Wrap; }
val induction_wrap : (w: Wrap) -> Wrap = (w: Wrap) => by {
  induction w; exact wrap
}
''');
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'induction_wrap'),
        returnsNormally,
      );
    });
  });
}
