/// `simp` normalises the goal and rewrites with equality lemmas to a
/// fixed point, closing by `refl` when the sides become convertible.
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
val plusZero : (n: Nat) -> Eq Nat (plus n zero) n = by {
  intro n;
  induction n;
  refl;
  rewrite ih;
  refl
}
val plusSucc : (m: Nat) -> (n: Nat) -> Eq Nat (plus m (succ n)) (succ (plus m n)) = by {
  intro m;
  intro n;
  induction m;
  refl;
  rewrite ih;
  refl
}
''';

void main() {
  group('simp', () {
    test('closes a definitional equality by normalisation and refl', () {
      final env = _elabAndCheck('''
$_nat
val t1 : (n: Nat) -> Eq Nat (plus zero n) n = by { intro n; simp }
''');
      expect(_binding(env, 't1').name, 't1');
    });

    test('rewrites a context hypothesis under a constructor', () {
      final env = _elabAndCheck('''
$_nat
val t2 : (a: Nat) -> (b: Nat) -> Eq Nat a b -> Eq Nat (succ a) (succ b) = by {
  intro a;
  intro b;
  intro h;
  simp
}
''');
      expect(_binding(env, 't2').name, 't2');
    });

    test('instantiates a Pi lemma with a compound left side', () {
      // `plusZero` has type `(n: Nat) -> Eq Nat (plus n zero) n`.
      // Matching its left side against the goal's nested occurrence
      // requires solving the binder's meta and rewriting the subterm.
      final env = _elabAndCheck('''
$_nat
$_proofs
val t3 : (n: Nat) -> Eq Nat (plus (plus n zero) zero) n = by {
  intro n;
  simp [plusZero]
}
''');
      expect(_binding(env, 't3').name, 't3');
    });

    test('runs two lemmas in sequence to a fixed point', () {
      // `plusZero` exposes the left side of `plusSucc`.
      final env = _elabAndCheck('''
$_nat
$_proofs
val t4 : (m: Nat) -> (n: Nat) ->
    Eq Nat (plus (plus m (succ n)) zero) (succ (plus m n)) = by {
  intro m;
  intro n;
  simp [plusZero, plusSucc]
}
''');
      expect(_binding(env, 't4').name, 't4');
    });

    test('fails with no progress when nothing applies', () {
      expect(
        () => _elabAndCheck('''
$_nat
val t5 : (n: Nat) -> Eq Nat n (succ n) = by { intro n; simp }
'''),
        throwsA(
          isA<TacticFailed>().having(
            (e) => e.message,
            'message',
            contains('simp: no progress'),
          ),
        ),
      );
    });

    test('guards a rewrite cycle and names the last rule', () {
      final stopwatch = Stopwatch()..start();
      expect(
        () => _elabAndCheck('''
$_nat
val t6 : (a: Nat) -> (b: Nat) -> (c: Nat) -> Eq Nat a b -> Eq Nat b a -> Eq Nat a c = by {
  intro a;
  intro b;
  intro c;
  intro h1;
  intro h2;
  simp
}
'''),
        throwsA(
          isA<TacticFailed>()
              .having(
                (e) => e.message,
                'message',
                contains('simp: rewrite limit exceeded'),
              )
              .having((e) => e.message, 'message', contains('last rule: h2')),
        ),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('leaves a residual goal for a following step', () {
      final env = _elabAndCheck('''
$_nat
$_proofs
val t7 : (m: Nat) -> (n: Nat) ->
    Eq Nat (plus (plus m (succ n)) zero) (succ (plus m n)) = by {
  intro m;
  intro n;
  simp [plusZero];
  rewrite (plusSucc m n);
  refl
}
''');
      expect(_binding(env, 't7').name, 't7');
    });
  });
}
