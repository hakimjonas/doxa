/// Doxa kernel example: load and type-check a simple proof.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';

const prelude = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}
''';

void main() {
  final r = parseProgram('''
$prelude
val x = refl
''');
  final prog = switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    _ => throw StateError('parse failed'),
  };
  final env = elabProgram(prog);
  print('Elaborated ${env.bindings.length} bindings');
}
