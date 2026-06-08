// Temporary diagnostic: dump synthRecursorType's output for known data decls.

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';

SProgram parseOk(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  throw StateError('parse failed: $r');
}

void dumpFor(String label, String src, String name) {
  final env = elabProgram(parseOk(src));
  final decl = env.lookupData(name)!;
  final t = synthRecursorType(decl);
  // ignore: avoid_print
  print('=== $label ===');
  // ignore: avoid_print
  print(t);
  // ignore: avoid_print
  print('  pretty: ${prettyTerm(t)}');
}

void main() {
  dumpFor(
    'Nat.rec',
    'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
    'Nat',
  );
  dumpFor('List.rec', '''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}
''', 'List');
  dumpFor('Vec.rec', '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''', 'Vec');
}
