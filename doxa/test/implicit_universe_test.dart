/// Implicit-argument solutions must inhabit the closed expected type.
///
/// The elaborator gives an inserted implicit meta the closed type
/// `Π ctx. T`. Pattern unification can otherwise solve it with a closed
/// λ-chain whose body sits one universe above `T`
/// (`?A value := Type 0` against `?A : (value: Type 0) -> Type 0`).
/// The unifier now checks the candidate against that type before
/// committing it, so the program is rejected during elaboration, at the
/// argument that triggered the solve. `elabProgram` does not run the
/// declaration audit, so these tests exercise the source fix alone.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate [src] (no `checkDeclResult` audit) and return the rejection.
TypeMismatch _rejectDuringElaboration(String src) {
  try {
    elabProgram(_parse(src));
  } on TypeMismatch catch (e) {
    return e;
  }
  fail('expected elaboration to reject the program');
}

Level _levelOf(Value v) {
  if (v is VType) return v.level;
  fail('expected a universe value, got $v');
}

const _identity = '''
fun identity{A: Type}(value: A): A = value
''';

void main() {
  group('implicit-universe solutions', () {
    test('the indirect form is rejected during elaboration', () {
      // `identity value` with `value : Type 0` forces `A := Type 0`,
      // whose type is `Type 1`, not the closed codomain `Type 0`.
      final error = _rejectDuringElaboration(
        '$_identity'
        'fun applyIdentity(value: Type): Type = identity value\n',
      );
      expect(_levelOf(error.got), const LLevel(1));
      expect(_levelOf(error.expected), const LLevel(0));
    });

    test('the direct form keeps the same rejection', () {
      final error = _rejectDuringElaboration(
        'val direct: (value: Type) -> Type = (value: Type) => Type\n',
      );
      expect(_levelOf(error.got), const LLevel(1));
      expect(_levelOf(error.expected), const LLevel(0));
    });
  });
}
