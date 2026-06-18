/// End-to-end programs using auto-emitted recursors.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Parse, elaborate, and type-check every declaration through the
/// `elabDecl` + `checkDeclResult` path, so solved metavariables are
/// inlined into the finalized terms before checking. Returns the
/// fully-loaded TopEnv.
TopEnv _run(String src) {
  final r = parseProgram(src);
  final SProgram prog;
  if (r is Success<ParseError, SProgram>) {
    prog = r.value;
  } else if (r is Partial<ParseError, SProgram>) {
    prog = r.value;
  } else {
    fail('parse failed: $r');
  }
  var bindings = const <TopBinding>[];
  var dataDecls = const <DataDecl>[];
  for (final decl in prog.decls) {
    final env = TopEnv(bindings, dataDecls);
    final produced = elabDecl(env, decl);
    final runningData = [...dataDecls, ...produced.dataDecls];
    final finalized = checkDeclResult(TopEnv(bindings, runningData), produced);
    bindings = [...bindings, ...finalized];
    dataDecls = runningData;
  }
  return TopEnv(bindings, dataDecls);
}

/// Look up a binding's value by evaluating its term in a ctx that
/// contains ONLY the bindings declared before it. Necessary because
/// TopBinding.term's de Bruijn indices reference "prior bindings"
/// from its own elaboration scope, evaluating in a ctx that
/// already includes the current binding would offset every index.
/// Each binding is checked in a ctx built from prior bindings, then
/// appended.
Value _valueOf(TopEnv env, String name) {
  for (var i = 0; i < env.bindings.length; i++) {
    final b = env.bindings[i];
    if (b.name != name) continue;
    final priorEnv = TopEnv(env.bindings.sublist(0, i), env.dataDecls);
    final ctx = priorEnv.toCtx();
    return eval(b.term, ctx.env);
  }
  fail('no binding named $name');
}

/// Count the depth of a VConstr(succ) chain wrapping a VConstr(zero).
///
/// Returns the numeric Nat the chain represents, or fails if the
/// shape isn't a strict `succ* zero` canonical.
int _natDepth(Value v) {
  var current = v;
  var depth = 0;
  while (true) {
    expect(
      current,
      isA<VConstr>(),
      reason: 'expected a VConstr at depth $depth',
    );
    final c = current as VConstr;
    expect(c.dataName, 'Nat');
    if (c.ctorName == 'zero') {
      expect(c.args, isEmpty);
      return depth;
    }
    expect(c.ctorName, 'succ');
    expect(c.args, hasLength(1));
    depth++;
    current = c.args.single;
  }
}

void main() {
  group('Nat recursor: plus', () {
    test('plus zero zero = zero', () {
      final env = _run('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val plus : Nat -> Nat -> Nat =
  (m: Nat) => (n: Nat) =>
    Nat.rec
      ((_: Nat) => Nat)
      n
      ((_: Nat) => (rec: Nat) => succ rec)
      m

val result : Nat = plus zero zero
''');
      final result = _valueOf(env, 'result');
      expect(_natDepth(result), 0);
    });

    test('plus zero (succ zero) = succ zero', () {
      final env = _run('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val plus : Nat -> Nat -> Nat =
  (m: Nat) => (n: Nat) =>
    Nat.rec
      ((_: Nat) => Nat)
      n
      ((_: Nat) => (rec: Nat) => succ rec)
      m

val one : Nat = succ zero
val result : Nat = plus zero one
''');
      expect(_natDepth(_valueOf(env, 'result')), 1);
    });

    test('plus (succ zero) (succ zero) = succ (succ zero)', () {
      final env = _run('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val plus : Nat -> Nat -> Nat =
  (m: Nat) => (n: Nat) =>
    Nat.rec
      ((_: Nat) => Nat)
      n
      ((_: Nat) => (rec: Nat) => succ rec)
      m

val one : Nat = succ zero
val two : Nat = succ one
val result : Nat = plus one one
''');
      expect(_natDepth(_valueOf(env, 'result')), 2);
    });

    test('plus two two = four', () {
      final env = _run('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val plus : Nat -> Nat -> Nat =
  (m: Nat) => (n: Nat) =>
    Nat.rec
      ((_: Nat) => Nat)
      n
      ((_: Nat) => (rec: Nat) => succ rec)
      m

val two : Nat = succ (succ zero)
val four : Nat = plus two two
''');
      expect(_natDepth(_valueOf(env, 'four')), 4);
    });

    test('plus three four = seven', () {
      final env = _run('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val plus : Nat -> Nat -> Nat =
  (m: Nat) => (n: Nat) =>
    Nat.rec
      ((_: Nat) => Nat)
      n
      ((_: Nat) => (rec: Nat) => succ rec)
      m

val three : Nat = succ (succ (succ zero))
val four : Nat = succ (succ (succ (succ zero)))
val seven : Nat = plus three four
''');
      expect(_natDepth(_valueOf(env, 'seven')), 7);
    });
  });

  group('Nat recursor: double / mult-by-two', () {
    test('double three = six', () {
      final env = _run('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val double : Nat -> Nat =
  Nat.rec
    ((_: Nat) => Nat)
    zero
    ((_: Nat) => (rec: Nat) => succ (succ rec))

val three : Nat = succ (succ (succ zero))
val six : Nat = double three
''');
      expect(_natDepth(_valueOf(env, 'six')), 6);
    });
  });

  group('List recursor: length', () {
    test('length of a 3-element list is 3', () {
      final env = _run('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

val length : List[Nat] -> Nat =
  List.rec
    Nat
    ((_: List[Nat]) => Nat)
    zero
    ((_: Nat) => (_: List[Nat]) => (rec: Nat) => succ rec)

val xs : List[Nat] =
  cons zero
    (cons (succ zero)
      (cons (succ (succ zero)) nil))

val n : Nat = length xs
''');
      expect(_natDepth(_valueOf(env, 'n')), 3);
    });
  });
}
