/// Exercises `checkSourceString`, the pure pipeline driver behind the
/// WasmGC browser entry, natively (no browser/Node runtime needed).
library;

import 'package:doxa/src/web_check.dart';
import 'package:test/test.dart';

void main() {
  group('checkSourceString (WasmGC entry core)', () {
    test('valid proof type-checks -> OK', () {
      const src = '''
data Bool : Type {
  true_  : Bool;
  false_ : Bool;
}

data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun if_[A: Type](b: Bool, t: A, f: A): A =
  Bool.rec ((_: Bool) => A) t f b

val y : Nat = if_ Nat true_ (succ zero) zero
''';
      final result = checkSourceString(src);
      expect(result, startsWith('OK:'));
      expect(result, contains('declarations checked'));
    });

    test('type mismatch -> error with expected/actual', () {
      const src = '''
data Bool : Type {
  true_  : Bool;
  false_ : Bool;
}

data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val oops : Bool = zero
''';
      final result = checkSourceString(src);
      expect(result, contains('error: type mismatch'));
      expect(result, contains('expected:'));
      expect(result, contains('actual:'));
    });
  });
}
