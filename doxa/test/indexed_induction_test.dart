/// `induction` must build each method goal by applying the motive to the
/// constructor's own result indices and value, matching the recursor's
/// method type.
///
/// The recursor's motive abstracts the scrutinee's indices and the
/// scrutinee. Its method type is `arguments -> IHs -> P resultIndices
/// (C args)`, so computing the method and hypothesis goals from the
/// motive is definitionally the recursor's own type. The earlier
/// first-order index refinement agrees with the motive for a variable
/// scrutinee index and for a constructor whose index unifies with the
/// scrutinee's, but leaves the unreachable method of a compound-index
/// induction at the unrefined goal. A completed proof through the
/// tactic therefore checks against the recursor, not merely elaborates.
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
val vlengthIndex : (A: Type) -> (n: Nat) -> (v: Vec A n) -> Eq Nat (vlength v) n =
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
      expect(_binding(env, 'vlengthIndex').name, 'vlengthIndex');
    });

    test('a compound-index induction closes at the constructor indices', () {
      // The scrutinee's index is `succ n`, which cannot unify with
      // `vnil`'s `zero`. Applying the motive makes the vnil method goal
      // `Eq Nat zero zero` (the recursor's `P zero vnil`) instead of the
      // unrefined `Eq Nat zero (succ n)`, and the vcons hypothesis
      // `Eq Nat (vlength rest) n` is at the recursive argument's own
      // index, so `rewrite ih` closes the arm.
      final env = _elabAndCheck('''
$_vec
val vlength_succ : (A: Type) -> (n: Nat) -> (v: Vec A (succ n)) ->
    Eq Nat (vlength v) (succ n) = by {
  intro A;
  intro n;
  intro v;
  induction v;
  refl;
  rewrite ih;
  refl
}
''');
      expect(_binding(env, 'vlength_succ').name, 'vlength_succ');
    });

    test('a wrong compound-index arm still fails', () {
      // The vcons arm needs the hypothesis; `refl` cannot close
      // `Eq Nat (succ (vlength rest)) (succ n)` for an abstract `n`.
      expect(
        () => _elabAndCheck('''
$_vec
val bad_vlength_succ : (A: Type) -> (n: Nat) -> (v: Vec A (succ n)) ->
    Eq Nat (vlength v) (succ n) = by {
  intro A;
  intro n;
  intro v;
  induction v;
  refl;
  refl
}
'''),
        throwsA(isA<TacticFailed>()),
      );
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
