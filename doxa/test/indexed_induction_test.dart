/// `induction` must refine the goal's indices per constructor, the same
/// first-order refinement the match arms use.
///
/// The recursor's motive abstracts the scrutinee's indices and the
/// scrutinee, and each method's expected type is the goal at the
/// constructor's result indices. A completed proof through the tactic
/// therefore checks against the recursor, not merely elaborates.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate and kernel-check [src] the way the CLI does.
TopEnv _elabAndCheck(String src) {
  final prelude = loadPrelude();
  var env = TopEnv(
    prelude.bindings,
    prelude.dataDecls,
    const {},
    prelude.namespaceBindings,
  );
  for (final decl in _parse(src).decls) {
    final produced = elabDecl(env, decl);
    final checked = checkDeclResult(
      TopEnv(
        env.bindings,
        [...env.dataDecls, ...produced.dataDecls],
        env.classRegistry,
        env.namespaceBindings,
      ),
      produced,
    );
    env = TopEnv(
      [...env.bindings, ...checked],
      [...env.dataDecls, ...produced.dataDecls],
      {...env.classRegistry, ...produced.classRegistry},
      mergeNamespace(env.namespaceBindings, produced.namespaceBindings),
    );
  }
  return env;
}

TopBinding _binding(TopEnv env, String name) =>
    env.bindings.firstWhere((b) => b.name == name);

const _vec = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
data Vec[A: Type]: Nat -> Type {
  vnil: Vec A zero;
  vcons: (n: Nat) -> A -> Vec A n -> Vec A (succ n);
}
fun vlength{A: Type, n: Nat}(v: Vec A n): Nat = match v {
  case vnil => zero
  case vcons _ _ rest => succ (vlength rest)
}
''';

void main() {
  group('indexed-family induction', () {
    test('eq_sym completes through the tactic', () {
      final env = _elabAndCheck('''
val eq_sym : (A: Type) -> (x: A) -> (y: A) -> Eq A x y -> Eq A y x = by {
  intro A;
  intro x;
  intro y;
  intro h;
  induction h;
  refl
}
''');
      expect(_binding(env, 'eq_sym').name, 'eq_sym');
    });

    test('a Vec induction uses the refined length index and the IH', () {
      // Without index refinement the vcons arm's goal stays
      // `Eq Nat (vlength v) n` and neither `refl` nor `rewrite ih` fits.
      final env = _elabAndCheck('''
$_vec
val vlength_index : (A: Type) -> (n: Nat) -> (v: Vec A n) -> Eq Nat (vlength v) n =
  by {
    intro A;
    intro n;
    intro v;
    induction v;
    refl;
    rewrite ih;
    refl
  }
''');
      expect(_binding(env, 'vlength_index').name, 'vlength_index');
    });

    test('a wrong indexed arm still fails', () {
      // The refl arm's goal is refined to `Eq A a a`; the outer
      // hypothesis `h : Eq A x y` no longer fits it.
      expect(
        () => _elabAndCheck('''
val bad : (A: Type) -> (x: A) -> (y: A) -> (h: Eq A x y) -> Eq A x y =
  (A: Type) => (x: A) => (y: A) => (h: Eq A x y) => by {
    induction h;
    exact h
  }
'''),
        throwsA(isA<TacticFailed>()),
      );
    });
  });
}
