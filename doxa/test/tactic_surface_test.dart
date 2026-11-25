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
val plusZero : (n: Nat) -> Eq Nat (plus n zero) n = by {
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
  rewrite (plusZero a);
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

    test('closes a parameterized nullary equality constructor', () {
      final env = _elabAndCheck('''
val eq_refl : (A: Type) -> (x: A) -> Eq A x x = by {
  intro A;
  intro x;
  constructor
}
''');
      expect(_binding(env, 'eq_refl').name, 'eq_refl');
    });

    test('closes nullary constructors of parameterized types', () {
      final env = _elabAndCheck('''
$_nat
$_list
$_option
val list0 : List Nat = by { constructor }
val option0 : Option Nat = by { constructor }
''');
      expect(_binding(env, 'list0').name, 'list0');
      expect(_binding(env, 'option0').name, 'option0');
    });

    test('closes a parameterized indexed nullary constructor', () {
      final env = _elabAndCheck('''
$_nat
$_vec
val vnil0 : Vec Nat zero = by { constructor }
''');
      expect(_binding(env, 'vnil0').name, 'vnil0');
    });

    test('solves the index and leaves the value arguments on vcons', () {
      // The goal index `succ n` determines the index argument, so only
      // the head and tail are goals.
      final env = _elabAndCheck('''
$_nat
$_vec
val vcons1 : (n: Nat) -> (x: Nat) -> (xs: Vec Nat n) -> Vec Nat (succ n) = by {
  intro n;
  intro x;
  intro xs;
  constructor;
  exact x;
  exact xs
}
''');
      expect(_binding(env, 'vcons1').name, 'vcons1');
    });

    test('rejects a goal with no matching constructor', () {
      expect(
        () => _elabAndCheck('''
$_nat
data D: Nat -> Type {
  d0: D zero;
}
val bad : D (succ zero) = by { constructor }
'''),
        _failsWith('constructor: no constructor matches the goal'),
      );
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
    test('closes with plusZero in scope', () {
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

  group('indexed cases', () {
    test('cases on Vec Nat m reaches both arms with a constant goal', () {
      final env = _elabAndCheck('''
$_nat
$_vec
val vec_const : (m: Nat) -> Vec Nat m -> Nat = by {
  intro m;
  intro v;
  cases v;
  constructor;
  constructor
}
''');
      expect(_binding(env, 'vec_const').name, 'vec_const');
    });

    test('cases on VecN (succ n) uses the indices of each arm', () {
      // P zero only accepts p0; P (succ k) only accepts p1 applied to k.
      // The declaration checking therefore pins each arm's goal to the
      // motive at that constructor's result indices.
      final env = _elabAndCheck('''
$_nat
$_vecN
$_parity
val vecn_parity : (n: Nat) -> VecN (succ n) -> P (succ n) = by {
  intro n;
  intro v;
  cases v;
  constructor;
  constructor;
  exact k
}
''');
      expect(_binding(env, 'vecn_parity').name, 'vecn_parity');
    });

    test('cases covers a two-index family', () {
      final env = _elabAndCheck('''
$_nat
$_lt
val lt_const : (a: Nat) -> (b: Nat) -> Lt a b -> Nat = by {
  intro a;
  intro b;
  intro h;
  cases h;
  constructor;
  constructor
}
''');
      expect(_binding(env, 'lt_const').name, 'lt_const');
    });

    test('a wrong indexed arm term fails with a diagnostic', () {
      expect(
        () => _elabAndCheck('''
$_nat
$_vecN
$_parity
val bad : (n: Nat) -> VecN (succ n) -> P (succ n) = by {
  intro n;
  intro v;
  cases v;
  exact Type;
  constructor;
  exact k
}
'''),
        _failsWith('exact: type mismatch'),
      );
    });
  });
}

const _vec = '''
data Vec[A: Type]: Nat -> Type {
  vnil: Vec A zero;
  vcons: (k: Nat) -> A -> Vec A k -> Vec A (succ k);
}
''';

const _list = '''
data List[A: Type]: Type {
  nil: List A;
  cons: A -> List A -> List A;
}
''';

const _option = '''
data Option[A: Type]: Type {
  none: Option A;
  some: A -> Option A;
}
''';

const _vecN = '''
data VecN: Nat -> Type {
  vnil: VecN zero;
  vcons: (k: Nat) -> Nat -> VecN k -> VecN (succ k);
}
''';

const _parity = '''
data P: Nat -> Type {
  p0: P zero;
  p1: (k: Nat) -> P (succ k);
}
''';

const _lt = '''
data Lt: Nat -> Nat -> Prop {
  ltSucc: (n: Nat) -> Lt n (succ n);
  ltTrans: (n: Nat) -> (m: Nat) -> (k: Nat) -> Lt n m -> Lt m k -> Lt n k;
}
''';
