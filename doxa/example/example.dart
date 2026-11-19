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
val id : (A: Type) -> (a: A) -> Eq A a a = (A: Type) => (a: A) => refl a
''');
  final prog = switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    _ => throw StateError('parse failed'),
  };
  final env = checkProgram(prog);
  print('Checked ${env.bindings.length} bindings');
}
