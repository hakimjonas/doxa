/// Kernel match refinement: hypotheses and Pi-returning expected types.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
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
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
data Eq[A: Type]: A -> A -> Prop {
  refl: (x: A) -> Eq A x x;
}
''';

void main() {
  group('kernel match refinement', () {
    test('a local hypothesis is refined with the scrutinee', () {
      final env = checkProgram(
        pp('''
$_prelude
fun f(m: Nat, h: Eq Nat m m): Eq Nat m m = match m returning (Eq Nat m m) {
  case zero => h
  case succ k => h
}
'''),
      );
      expect(env.bindings.map((b) => b.name), contains('f'));
    });

    test('a Pi-returning arm body is refined with the scrutinee', () {
      final env = checkProgram(
        pp('''
$_prelude
fun f(m: Nat): (h: Eq Nat m m) -> Eq Nat m m =
  match m returning ((h: Eq Nat m m) -> Eq Nat m m) {
    case zero => (h: Eq Nat zero zero) => h
    case succ k => (h: Eq Nat (succ k) (succ k)) => h
  }
'''),
      );
      expect(env.bindings.map((b) => b.name), contains('f'));
    });

    test('the fuel skeleton G/hG shape checks', () {
      final env = checkProgram(
        pp('''
$_prelude
fun leq(m: Nat, n: Nat): Bool = match m {
  case zero => true_
  case succ m_ => match n {
    case zero => false_
    case succ n_ => leq m_ n_
  }
}

val gShape: (G1: Nat) -> (hG: Eq Bool (succ zero <= G1) true_) -> Eq Nat zero zero =
  (G1: Nat) => (hG: Eq Bool (succ zero <= G1) true_) =>
    (match G1 returning ((hG2: Eq Bool (succ zero <= G1) true_) -> Eq Nat zero zero) {
      case zero => (hG0: Eq Bool (succ zero <= zero) true_) => refl zero
      case succ G_ => (hG2: Eq Bool (succ zero <= succ G_) true_) => refl zero
    }) hG
'''),
      );
      expect(env.bindings.map((b) => b.name), contains('gShape'));
    });
  });
}
