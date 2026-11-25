/// Tactic expressions elaborate in the tactic's real context, and
/// `apply` reports its explicit argument holes as goals.
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
''';

const _cong = '''
fun cong{A: Type, B: Type, x: A, y: A}(f: A -> B, p: Eq A x y): Eq B (f x) (f y) =
  Eq.rec
    A
    ((a: A) => (b: A) => (_: Eq A a b) => Eq B (f a) (f b))
    x
    y
    ((z: A) => refl (f z))
    p
''';

void main() {
  group('tactic expressions use the real context', () {
    test('exact infers cong\'s implicits from local binders', () {
      final env = _elabAndCheck('''
$_nat
$_cong
val exact_cong : (n: Nat) -> (m: Nat) -> Eq Nat n m -> Eq Nat (succ n) (succ m) =
  by {
    intro n;
    intro m;
    intro h;
    exact (cong ((j: Nat) => succ j) h)
  }
''');
      expect(_binding(env, 'exact_cong').name, 'exact_cong');
    });

    test('exact elaborates a constructor application after induction', () {
      final env = _elabAndCheck('''
data PairEqual[A: Type] : A -> A -> Prop {
  mkEq : (z: A) -> PairEqual A z z;
}
val exact_mkEq : (A: Type) -> (x: A) -> (y: A) -> PairEqual A x y -> PairEqual A y x =
  by {
    intro A;
    intro x;
    intro y;
    intro h;
    induction h;
    exact (mkEq z)
  }
''');
      expect(_binding(env, 'exact_mkEq').name, 'exact_mkEq');
    });

    test('apply fills holes the goal constrains and reports the rest', () {
      final env = _elabAndCheck('''
$_nat
fun pair_lemma(a: Nat, b: Nat, p: Eq Nat a b): Eq Nat b a =
  Eq.rec
    Nat
    ((x: Nat) => (y: Nat) => (_: Eq Nat x y) => Eq Nat y x)
    a
    b
    ((z: Nat) => refl z)
    p
val apply_forced : (n: Nat) -> (m: Nat) -> Eq Nat n m -> Eq Nat m n =
  by {
    intro n;
    intro m;
    intro h;
    apply pair_lemma;
    exact h
  }
''');
      expect(_binding(env, 'apply_forced').name, 'apply_forced');
    });

    test('apply exposes two explicit arguments as ordered goals', () {
      final env = _elabAndCheck('''
$_nat
fun two_nats(a: Nat, b: Nat): Nat = a
val apply_two : Nat = by {
  apply two_nats;
  exact zero;
  exact (succ zero)
}
''');
      expect(_binding(env, 'apply_two').name, 'apply_two');
    });

    test('a leftover apply goal reports the apply expression span', () {
      const source = '''
$_nat
fun two_nats(a: Nat, b: Nat): Nat = a
val apply_leftover : Nat = by {
  apply two_nats;
  exact zero
}
''';
      final use = source.indexOf('apply two_nats') + 'apply '.length;
      Object? error;
      try {
        _elabAndCheck(source);
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<TacticFailed>());
      expect(
        (error as TacticFailed).span,
        DoxaSpan(use, use + 'two_nats'.length),
      );
    });

    test('a hidden unsolved meta reports the alternative that left it', () {
      const source = '''
$_nat
fun implicit_any{A: Type}(x: Nat): Nat = x
fun two_nats(a: Nat, b: Nat): Nat = a
val alternative : Nat = by {
  apply two_nats;
  exact zero
|
  apply implicit_any;
  exact zero
}
''';
      final use = source.indexOf('apply implicit_any') + 'apply '.length;
      final first = source.indexOf('apply two_nats') + 'apply '.length;
      Object? error;
      try {
        _elabAndCheck(source);
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<TacticFailed>());
      final failed = error as TacticFailed;
      expect(failed.span, DoxaSpan(use, use + 'implicit_any'.length));
      expect(
        failed.span,
        isNot(DoxaSpan(first, first + 'two_nats'.length)),
        reason: 'the span must come from the last alternative, not the first',
      );
    });

    test('apply does not expose implicit arguments as goals', () {
      // `cong` has four implicit parameters and two explicit ones. If the
      // implicits became goals, the first `exact` would target `Type`.
      final env = _elabAndCheck('''
$_nat
$_cong
val apply_cong : (n: Nat) -> (m: Nat) -> Eq Nat n m -> Eq Nat (succ n) (succ m) =
  by {
    intro n;
    intro m;
    intro h;
    apply cong;
    exact ((j: Nat) => succ j);
    exact h
  }
''');
      expect(_binding(env, 'apply_cong').name, 'apply_cong');
    });
  });
}
