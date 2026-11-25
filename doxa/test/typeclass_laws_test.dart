/// Class law fields that reference operation projections.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Parse a program, asserting success.
SProgram pp(String input) {
  final r = parseProgram(input);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

const _prelude = '''
data Eq[A: Type]: A -> A -> Prop {
  refl: (x: A) -> Eq A x x;
}

data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}
''';

/// The Nat lemmas the additive instance needs, inlined because
/// `checkProgram` does not process imports.
const _natLemmas = '''
fun cong{A: Type, B: Type, x: A, y: A}(f: A -> B, p: Eq A x y): Eq B (f x) (f y) =
  Eq.rec
    A
    ((a: A) => (b: A) => (_: Eq A a b) => Eq B (f a) (f b))
    x
    y
    ((z: A) => refl (f z))
    p

val plusZero: (n: Nat) -> Eq Nat (plus n zero) n =
  Nat.ind
    ((k: Nat) => Eq Nat (plus k zero) k)
    (refl zero)
    ((m: Nat) => (ih: Eq Nat (plus m zero) m) => cong ((k: Nat) => succ k) ih)

val plusAssoc: (m: Nat) -> (n: Nat) -> (p: Nat) -> Eq Nat (plus (plus m n) p) (plus m (plus n p)) =
  (m: Nat) => Nat.ind
    ((k: Nat) => (n: Nat) -> (p: Nat) -> Eq Nat (plus (plus k n) p) (plus k (plus n p)))
    ((n: Nat) => (p: Nat) => refl (plus n p))
    ((k: Nat) => (ih: (n: Nat) -> (p: Nat) -> Eq Nat (plus (plus k n) p) (plus k (plus n p))) => (n: Nat) => (p: Nat) => cong ((x: Nat) => succ x) (ih n p))
    m
''';

Value _evalBinding(TopEnv env, String name) {
  final binding = env.bindings.firstWhere((b) => b.name == name);
  return eval(binding.term, env.toCtx().env);
}

String _ctorName(Value value) {
  expect(value, isA<VConstr>());
  return (value as VConstr).ctorName;
}

void main() {
  group('law projections', () {
    test('a law field names an operation declared earlier', () {
      final env = checkProgram(
        pp('''
$_prelude

typeclass Op[A: Type] {
  fun op(x: A): A;
  fun law1(x: A): Eq A (op x) (op x);
  fun law2(x: A): Eq A (op (op x)) (op x);
}

impl Op[Nat] {
  fun op(x: Nat): Nat = x;
  fun law1(x: Nat): Eq Nat (op x) (op x) = refl x;
  fun law2(x: Nat): Eq Nat (op (op x)) (op x) = refl x;
}

val l1 : Eq Nat (op zero) zero = law1 zero
val l2 : Eq Nat (op (op zero)) zero = law2 zero
'''),
      );

      expect(env.bindings.where((b) => b.name == 'Op.law1'), hasLength(1));
      expect(env.bindings.where((b) => b.name == 'Op.law2'), hasLength(1));
      expect(_ctorName(_evalBinding(env, 'l1')), 'refl');
      expect(_ctorName(_evalBinding(env, 'l2')), 'refl');
    });

    test('a law that references a later method is rejected', () {
      expect(
        () => checkProgram(
          pp('''
$_prelude

typeclass Bad[A: Type] {
  fun law(x: A): Eq A (op x) (op x);
  fun op(x: A): A;
}
'''),
        ),
        throwsA(isA<UnresolvedName>().having((e) => e.name, 'name', 'op')),
      );
    });
  });

  group('additive laws', () {
    const addMonoidClass = '''
typeclass AddMonoid[A: Type] {
  fun add(x: A, y: A): A;
  fun addZero: A;
  fun addAssoc(x: A, y: A, z: A): Eq A (add (add x y) z) (add x (add y z));
  fun addZeroLeft(x: A): Eq A (add addZero x) x;
  fun addZeroRight(x: A): Eq A (add x addZero) x;
}
''';

    test('an instance supplies the Nat laws', () {
      final env = checkProgram(
        pp('''
$_prelude
$_natLemmas
$addMonoidClass

impl AddMonoid[Nat] {
  fun add(x: Nat, y: Nat): Nat = plus x y;
  fun addZero: Nat = zero;
  fun addAssoc(x: Nat, y: Nat, z: Nat): Eq Nat (plus (plus x y) z) (plus x (plus y z)) =
    plusAssoc x y z;
  fun addZeroLeft(x: Nat): Eq Nat (plus zero x) x = refl x;
  fun addZeroRight(x: Nat): Eq Nat (plus x zero) x = plusZero x;
}

val assoc : Eq Nat zero zero = addAssoc zero zero zero
val left : Eq Nat zero zero = addZeroLeft zero
val right : Eq Nat zero zero = addZeroRight zero
'''),
      );

      expect(_ctorName(_evalBinding(env, 'assoc')), 'refl');
      expect(_ctorName(_evalBinding(env, 'left')), 'refl');
      expect(_ctorName(_evalBinding(env, 'right')), 'refl');
    });

    test('a commutative subclass resolves its parent', () {
      final env = checkProgram(
        pp('''
$_prelude

data Unit : Type { unit : Unit; }

fun unit_eq(x: Unit): Eq Unit unit x =
  Unit.ind ((u: Unit) => Eq Unit unit u) (refl unit) x

$addMonoidClass

typeclass AddCommMonoid[A: Type]: AddMonoid[A] {
  fun addComm(x: A, y: A): Eq A (add x y) (add y x);
}

impl AddMonoid[Unit] {
  fun add(x: Unit, y: Unit): Unit = unit;
  fun addZero: Unit = unit;
  fun addAssoc(x: Unit, y: Unit, z: Unit): Eq Unit unit unit = refl unit;
  fun addZeroLeft(x: Unit): Eq Unit unit x = unit_eq x;
  fun addZeroRight(x: Unit): Eq Unit unit x = unit_eq x;
}

impl AddCommMonoid[Unit] {
  fun addComm(x: Unit, y: Unit): Eq Unit unit unit = refl unit;
}

fun useComm[A: AddCommMonoid](x: A): A = add x x
val r : Unit = useComm Unit unit
'''),
      );
      expect(_ctorName(_evalBinding(env, 'r')), 'unit');
    });
  });
}
