/// Surface parity for `cases`, `constructor`, `auto`, and `omega` in
/// `by` blocks.
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

const _nat = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ k => succ (plus k n)
}
''';

const _proofs = '''
val plus_zero : (n: Nat) -> Eq Nat (plus n zero) n = by {
  intro n;
  induction n;
  refl;
  rewrite ih;
  refl
}
''';

Matcher _failsWith(String text) => throwsA(
  isA<TacticFailed>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  group('cases', () {
    test('walks both arms of Nat', () {
      final env = _elabAndCheck('''
$_nat
val two_cases : (n: Nat) -> Eq Nat (plus zero n) n = by {
  intro n;
  cases n;
  refl;
  refl
}
''');
      expect(_binding(env, 'two_cases').name, 'two_cases');
    });

    test('names the constructor argument in the arm context', () {
      final env = _elabAndCheck('''
$_nat
$_proofs
val named_arm : (n: Nat) -> Eq Nat (plus n zero) n = by {
  intro n;
  cases n;
  refl;
  rewrite (plus_zero a);
  refl
}
''');
      expect(_binding(env, 'named_arm').name, 'named_arm');
    });

    test('rejects an unknown variable', () {
      expect(
        () => _elabAndCheck('''
$_nat
val bad : (n: Nat) -> Eq Nat n n = by { intro n; cases z }
'''),
        _failsWith('cases: variable "z" not in scope'),
      );
    });

    test('rejects a non-inductive variable', () {
      expect(
        () => _elabAndCheck('''
val bad : (A: Type) -> A = by { intro A; cases A }
'''),
        _failsWith('cases: variable is not of an inductive type'),
      );
    });
  });

  group('constructor', () {
    test('leaves one reachable goal per argument', () {
      final env = _elabAndCheck('''
$_nat
data Pair2 : Type {
  pair2 : (a: Nat) -> (b: Nat) -> Pair2;
}
val pair : Pair2 = by { constructor; exact zero; exact zero }
''');
      expect(_binding(env, 'pair').name, 'pair');
    });

    test('closes an argument whose type mentions a local variable', () {
      final env = _elabAndCheck('''
$_nat
data D: Nat -> Type {
  d0: D zero;
  d1: (n: Nat) -> D n -> D (succ n);
}
val d_succ : (n: Nat) -> D n -> D (succ n) = by {
  intro n;
  intro p;
  constructor;
  exact p
}
''');
      expect(_binding(env, 'd_succ').name, 'd_succ');
    });

    test('rejects a non-inductive goal', () {
      expect(
        () => _elabAndCheck('''
val bad : (A: Type) -> A -> A = by { constructor }
'''),
        _failsWith('constructor: goal is not an inductive type'),
      );
    });
  });

  group('auto', () {
    test('closes a goal from a hypothesis', () {
      final env = _elabAndCheck('''
val identity : (A: Type) -> A -> A = by { intro A; intro x; auto }
''');
      expect(_binding(env, 'identity').name, 'identity');
    });

    test('reports its diagnostic and stays bounded', () {
      final stopwatch = Stopwatch()..start();
      expect(
        () => _elabAndCheck('''
val bad : (A: Type) -> A = by { intro A; auto }
'''),
        _failsWith('auto: no proof found at depth 5'),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('rejects a depth outside 0 to 20', () {
      expect(
        () => _elabAndCheck('''
val bad : (A: Type) -> A -> A = by { intro A; intro x; auto 21 }
'''),
        _failsWith('auto: depth must be between 0 and 20'),
      );
    });
  });

  group('omega', () {
    test('closes with plus_zero in scope', () {
      final env = _elabAndCheck('''
$_nat
$_proofs
val plus_zero_again : (n: Nat) -> Eq Nat (plus n zero) n = by {
  intro n;
  omega
}
''');
      expect(_binding(env, 'plus_zero_again').name, 'plus_zero_again');
    });

    test('reports its diagnostic when no lemma applies', () {
      expect(
        () => _elabAndCheck('''
$_nat
val bad : (n: Nat) -> Eq Nat n (succ n) = by { intro n; omega }
'''),
        _failsWith('omega: could not solve the arithmetic goal'),
      );
    });
  });
}
