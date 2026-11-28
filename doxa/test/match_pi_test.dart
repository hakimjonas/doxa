/// Pi-returning match shapes.
///
/// A match whose `returning` type is a Pi can be a function; using it as an
/// application argument requires parentheses. A successor branch may bind
/// the function's arguments after the scrutinee is refined, and a nested
/// match in that branch returns the goal type.
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

void main() {
  group('Pi-returning matches', () {
    test('a branch binds its arguments after the scrutinee is refined', () {
      // The outer match returns `(n1) -> Bool -> Bool -> ...`; the successor
      // branch binds `n1`, then the two inequality arguments. The nested
      // match returns the goal equation.
      final env = checkProgram(
        pp('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
data Eq[A: Type]: A -> A -> Prop {
  refl: (x: A) -> Eq A x x;
}

val k: (m: Nat) -> (n1: Nat) -> Bool -> Bool -> Eq Nat n1 n1 =
  (m: Nat) => match m returning ((n1: Nat) -> Bool -> Bool -> Eq Nat n1 n1) {
    case zero => (n1: Nat) => (hF: Bool) => (hG: Bool) => refl n1
    case succ m_ => (n1: Nat) => (hF: Bool) => (hG: Bool) => match n1 returning (Eq Nat n1 n1) {
      case zero => refl zero
      case succ d => refl (succ d)
    }
  }
'''),
      );
      expect(env.bindings.map((b) => b.name), contains('k'));
    });

    test('a match returning a Pi is a function when parenthesized', () {
      final env = checkProgram(
        pp('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Eq[A: Type]: A -> A -> Prop {
  refl: (x: A) -> Eq A x x;
}

val k: Nat = (match zero returning (Nat -> Nat) {
  case zero => (x: Nat) => x
  case succ m_ => (x: Nat) => x
}) zero
'''),
      );
      expect(env.bindings.map((b) => b.name), contains('k'));
    });

    test('a bare match cannot be an application argument', () {
      // The grammar requires parentheses around a match used as an argument,
      // the same rule as a block argument.
      final r = parseProgram('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val k: Nat = match zero returning (Nat -> Nat) {
  case zero => (x: Nat) => x
  case succ m_ => (x: Nat) => x
} zero
''');
      expect(r, isA<Failure<ParseError, SProgram>>());
    });
  });
}
