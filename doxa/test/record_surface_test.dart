/// Surface projections from product-form records.
///
/// The kernel-level projection tests live in `record_test.dart`. These tests
/// drive the parser, elaborator, and checker through `checkProgram`.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

const _prelude = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
data Eq[A : Type] : A -> A -> Prop {
  refl : (x : A) -> Eq A x x;
}
''';

/// Parse a program, asserting success.
SProgram _pp(String input) {
  final r = parseProgram(input);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

TopEnv _check(String body) => checkProgram(_pp('$_prelude\n$body'));

/// Evaluate a named top-level binding in [env].
Value _evalBinding(TopEnv env, String name) {
  final binding = env.bindings.firstWhere((b) => b.name == name);
  return eval(binding.term, env.toCtx().env);
}

String _ctorName(Value value) {
  expect(value, isA<VConstr>());
  return (value as VConstr).ctorName;
}

void main() {
  test('Point with two fields constructs and projects both', () {
    final env = _check('''
data Point : Type { x : Nat; y : Nat; }
val p : Point = Point.mk zero (succ zero)
val first : Nat = p.x
val second : Nat = p.y
''');

    expect(_ctorName(_evalBinding(env, 'first')), 'zero');
    expect(_ctorName(_evalBinding(env, 'second')), 'succ');
  });

  test('a parameterised record projects both fields at Pair Nat', () {
    final env = _check('''
data Pair[A : Type] : Type { fst : A; snd : A; }
val p : Pair Nat = Pair.mk zero (succ zero)
val first : Nat = p.fst
val second : Nat = p.snd
''');

    expect(_ctorName(_evalBinding(env, 'first')), 'zero');
    expect(_ctorName(_evalBinding(env, 'second')), 'succ');
  });

  test('a third field projects', () {
    final env = _check('''
data Triple : Type { a : Nat; b : Nat; c : Nat; }
val t : Triple = Triple.mk zero (succ zero) (succ (succ zero))
val third : Nat = t.c
''');

    final third = _evalBinding(env, 'third');
    expect(_ctorName(third), 'succ');
    final inner = (third as VConstr).args.single;
    expect(_ctorName(inner), 'succ');
    expect(_ctorName((inner as VConstr).args.single), 'zero');
  });

  test('a dependent field type mentions the first projection', () {
    final env = _check('''
data Dep : Type { a : Nat; b : Eq Nat a a; }
fun getB(d : Dep) : Eq Nat d.a d.a = d.b
''');

    // The declaration checks only if `b`'s type is `Eq Nat d.a d.a` with
    // `d.a` as the actual projection, not an unconstrained neutral.
    expect(env.bindings.any((b) => b.name == 'getB'), isTrue);
  });

  test('a nested record projects through', () {
    final env = _check('''
data Point : Type { x : Nat; y : Nat; }
data Segment : Type {
  seg : (start : Point) -> (end : Point) -> Segment;
}
val s : Segment =
  Segment.seg (Point.mk zero zero) (Point.mk zero (succ zero))
val ey : Nat = s.end.y
''');

    expect(_ctorName(_evalBinding(env, 'ey')), 'succ');
  });
}
