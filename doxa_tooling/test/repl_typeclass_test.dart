/// REPL typeclass state: the class registry survives separate inputs, and
/// a failing declaration returns a [ReplError] with a usable session.
library;

import 'package:doxa_tooling/src/repl.dart';
import 'package:test/test.dart';

/// Feed [input] and require a declaration result, returning the session.
ReplSession _declare(ReplSession session, String input) {
  final (result, next) = session.processInput(input);
  if (result is ReplError) {
    fail('declaration failed: ${result.message}');
  }
  expect(result, isA<ReplDeclResult>());
  return next;
}

void main() {
  group('REPL typeclasses', () {
    test('class, instance, and constrained function accumulate', () {
      var session = ReplSession();
      session = _declare(
        session,
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
      );
      session = _declare(
        session,
        'data Bool : Type { true_ : Bool; false_ : Bool; }',
      );
      session = _declare(
        session,
        'typeclass Eqb[A: Type] { fun eqb(x: A, y: A): Bool; }',
      );
      session = _declare(session, '''
impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = match x {
    case zero => true_
    case succ n => false_
  };
}
''');
      session = _declare(
        session,
        'fun same[A: Eqb](x: A, y: A): Bool = eqb x y',
      );

      final (typeResult, _) = session.processInput(':type same');
      expect(typeResult, isA<ReplMeta>());
      final typeText = (typeResult as ReplMeta).text;
      expect(typeText, contains('Eqb'));
      expect(typeText, contains('Bool'));

      // The registry reached _processDecl: a call with a constrained
      // parameter resolves its dictionary in check mode.
      session = _declare(session, 'val r : Bool = same zero zero');
      final (rType, _) = session.processInput(':type r');
      expect(rType, isA<ReplMeta>());
      expect((rType as ReplMeta).text, 'Bool');
    });

    test('an impl for an unknown class returns a ReplError', () {
      var session = ReplSession();
      session = _declare(
        session,
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
      );
      session = _declare(
        session,
        'data Bool : Type { true_ : Bool; false_ : Bool; }',
      );

      final (result, next) = session.processInput(
        'impl Nope[Nat] { fun eqb(x: Nat, y: Nat): Bool = true_; }',
      );
      expect(result, isA<ReplError>());
      expect((result as ReplError).message, contains('unknown typeclass'));
      expect(identical(next, session), isTrue);

      // The session is still usable.
      final (ok, _) = next.processInput('val x : Nat = zero');
      expect(ok, isA<ReplDeclResult>());
    });

    test('a duplicate instance returns a ReplError', () {
      var session = ReplSession();
      session = _declare(
        session,
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
      );
      session = _declare(
        session,
        'data Bool : Type { true_ : Bool; false_ : Bool; }',
      );
      session = _declare(
        session,
        'typeclass Eqb[A: Type] { fun eqb(x: A, y: A): Bool; }',
      );
      session = _declare(
        session,
        'impl Eqb[Nat] { fun eqb(x: Nat, y: Nat): Bool = true_; }',
      );

      final (result, next) = session.processInput(
        'impl Eqb[Nat] { fun eqb(x: Nat, y: Nat): Bool = false_; }',
      );
      expect(result, isA<ReplError>());
      expect((result as ReplError).message, contains('overlapping instances'));
      expect(identical(next, session), isTrue);

      // The first instance still resolves.
      final (ok, _) = next.processInput('val b : Bool = eqb zero zero');
      expect(ok, isA<ReplDeclResult>());
    });
  });
}
