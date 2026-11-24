/// Tests for Phase 24: Well-founded recursion with `Acc` and
/// `decreases` annotation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

class _BufferedSink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  @override
  void write(Object? obj) {
    _buffer.write(obj);
  }

  @override
  void writeln([Object? obj = '']) {
    _buffer.writeln(obj);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String sep = '']) {
    _buffer.writeAll(objects, sep);
  }

  @override
  void writeCharCode(int charCode) {
    _buffer.writeCharCode(charCode);
  }

  @override
  String toString() => _buffer.toString();
  @override
  Encoding encoding = utf8;
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? st]) {}
  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {}
  @override
  Future<dynamic> close() async {}
  @override
  Future<dynamic> get done => Future.value();
  @override
  Future<dynamic> flush() async {}
}

({int code, String stdout, String stderr}) runSource(
  String src, {
  String filename = 'test.doxa',
}) {
  final source = SourceFile(filename: filename, text: src);
  final outBuf = _BufferedSink();
  final errBuf = _BufferedSink();
  final code = checkSource(source, out: outBuf, err: errBuf);
  return (code: code, stdout: outBuf.toString(), stderr: errBuf.toString());
}

void main() {
  group('well-founded recursion (Acc)', () {
    test('Acc type exists in prelude', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun rel(a: Nat, b: Nat) : Prop = Eq[Nat] a b
val accProp : Prop = Acc[Nat] rel zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('accIntro resolves (arity mismatch means name found)', () {
      // The parameterized `accIntro` takes `x` and the accessibility
      // function. Supplying one explicit argument produces an arity
      // mismatch, which proves the constructor name resolves.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
val intro = Acc[Nat].accIntro zero
''';
      final r = runSource(src);
      expect(r.stderr, contains('arity mismatch'));
    });

    test('Acc.rec recursor exists', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
val rec = Acc[Nat].rec
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('decreases on a non-recursive fun is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun identity(x : Nat) : Nat decreases (x) = x
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('decreases on a non-recursive function'));
    });

    test('decreases with an unknown parameter is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(x : Nat) : Nat decreases (y) = f x
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('decreases names an invalid measure'));
      expect(r.stderr, contains('`y` is not a value parameter of `f`'));
    });

    test('decreases on a non-recursive helper is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun helper(m : Nat, n : Nat) : Nat decreases (m) = plus m (plus m n)
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('decreases on a non-recursive function'));
    });

    test('decreases with {struct} is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(x : Nat) : Nat {struct x} decreases (x) = x
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('decreases cannot be combined with {struct}'));
    });

    test('structural recursion still works', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun my_plus(a : Nat, b : Nat) : Nat = match a {
  case zero => b
  case succ a_ => succ (my_plus a_ b)
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('decreases on a fun with no value parameters is rejected', () {
      const src = 'fun f{A : Type} : Type decreases (x) = A';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('decreases names an invalid measure'));
      expect(r.stderr, contains('`f` has no value parameters'));
    });

    test('decreases with a duplicate parameter is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(x : Nat) : Nat decreases (x, x) = f x
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('decreases names an invalid measure'));
      expect(r.stderr, contains('`x` appears more than once'));
    });

    test('decreases with an empty measure is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n : Nat) : Nat decreases () = f n
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('decreases names an invalid measure'));
      expect(r.stderr, contains('the measure is empty'));
    });

    test('the bare spelling is a parse error', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(a: Nat, b: Nat): Nat decreases a b = f a b
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('error: parse error'));
      expect(r.stderr, contains('Unexpected "a"'));
      expect(r.stderr, contains('expected: "("'));
    });

    test('a malformed measure is a parse error', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(m: Nat, n: Nat): Nat decreases (sub m n) n = f m n
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('error: parse error'));
      expect(r.stderr, contains('Unexpected "m"'));
      expect(r.stderr, contains('expected: ")"'));
    });

    test('decreases is a reserved word', () {
      const src = 'val decreases = 0';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('unexpected reserved word "decreases"'));
    });

    test('decreases soundness reproducer is rejected', () {
      // A call that grows the measured argument must not be accepted.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun bad(n: Nat): Eq Nat zero (succ zero) decreases (n) = bad (succ n)
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(
        r.stderr,
        contains('recursive call does not decrease the termination measure'),
      );
      expect(r.stderr, contains('strict sub-term of `n`'));
    });

    test('multi-parameter decreases with no descent is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(a: Nat, b: Nat): Nat decreases (a, b) = f a b
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(
        r.stderr,
        contains('recursive call does not decrease the termination measure'),
      );
      expect(r.stderr, contains('no position decreases'));
    });

    test('a call that swaps the measured parameters is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(a: Nat, b: Nat): Nat decreases (a) = f b a
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('strict sub-term of `a`'));
      expect(r.stderr, contains('passes `b`'));
    });

    test('a call in the return type is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Eq Nat (f n) (f n) decreases (n) = refl (f n)
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('no position decreases'));
    });

    test('an unapplied self-reference is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Nat decreases (n) = plus f n
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('referenced without its arguments'));
    });

    test('a self-call through a lambda is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Nat decreases (n) = ((x: Nat) => f (succ x)) n
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('strict sub-term of `n`'));
      expect(r.stderr, contains('compound term'));
    });

    test('a call on an arithmetic term is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(m: Nat, n: Nat): Nat decreases (m, n) = f (sub m n) n
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('strict sub-term of `m`'));
      expect(r.stderr, contains('compound term'));
    });

    test('mutual-block member with decreases is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Nat decreases (n) = g n
and g(n: Nat): Nat = f n
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(
        r.stderr,
        contains('decreases is not available in a mutual block'),
      );
    });

    test('Ackermann checks and computes under a lexicographic measure', () {
      // `ack m_ (ack m n_)` keeps the first position and decreases the
      // second in the inner call; `ack m_ (succ zero)` decreases the
      // first. `refl` forces the guard to unfold both descents.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun ack(m: Nat, n: Nat): Nat decreases (m, n) = match m {
  case zero => succ n
  case succ m_ => match n {
    case zero => ack m_ (succ zero)
    case succ n_ => ack m_ (ack m n_)
  }
}
val two: Nat = succ (succ zero)
val seven: Nat = succ (succ (succ (succ (succ (succ (succ zero))))))
val ack22: Eq Nat (ack two two) seven = refl seven
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a measure may start at a parameter after the first', () {
      // Measure (b, a): the succ branch holds b and decreases a, the
      // zero branch holds a and decreases b.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun holdB(a: Nat, b: Nat): Nat decreases (b, a) = match a {
  case zero => match b {
    case zero => zero
    case succ b_ => holdB a b_
  }
  case succ a_ => holdB a_ b
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a Nat.ind step binder is a strict sub-term', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun stepLoop(n: Nat): Eq Nat zero zero decreases (n) = Nat.ind
  ((k: Nat) => Eq Nat zero zero)
  (refl zero)
  ((k: Nat) => (ih: Eq Nat zero zero) => stepLoop k)
  n
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a single-parameter measure checks', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun down(n: Nat): Nat decreases (n) = match n {
  case zero => zero
  case succ n_ => down n_
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('strongInd computes through natWf and Acc.rec', () {
      // `observed_iota` forces `strongInd P step zero` through
      // `natWf zero` and Acc.rec to `step zero ... = refl zero`.
      const src = '''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
fun P(n: Nat): Prop = Eq Nat n n
fun step(n: Nat, ih: (k: Nat) -> Lt k n -> P k): P n = refl n
val observed: Nat = Eq.rect Nat
  ((a: Nat) => (b: Nat) => (_: Eq Nat a b) => Nat)
  zero zero ((z: Nat) => zero)
  (strongInd P step zero)
val observed_iota: Eq Nat observed zero = refl zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });

  group('dependent Pi constructor arguments', () {
    test('D6.rec, D7.rec, and Acc.rec Nat type-check', () {
      // A later Pi domain may reference an earlier Pi binder. The
      // recursor type must stay closed in both the Pi-chain domains and
      // the base type's indices.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
data D6[A: Type]: Type {
  mk6: ((y: A) -> Eq A y y -> D6 A) -> D6 A;
}
data D7[A: Type, B: Type]: Type {
  mk7: ((x: A) -> (y: B) -> Eq A x x -> Eq B y y -> D7 A B) -> D7 A B;
}
val r6 = D6.rec Nat
val r7 = D7.rec Nat Nat
val racc = Acc.rec Nat
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a fully applied Acc.rec with a Prop motive type-checks', () {
      // The IH is function-shaped over the same Pi chain as accIntro's
      // recursive argument.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun rel(a: Nat, b: Nat): Prop = Eq Nat a b
val acc_eq: (n: Nat) -> Acc Nat rel n -> Eq Nat n n =
  (n: Nat) => (h: Acc Nat rel n) => Acc.rec Nat rel
    ((x: Nat) => (v: Acc Nat rel x) => Eq Nat x x)
    n
    ((x: Nat) =>
      (f: (y: Nat) -> rel y x -> Acc Nat rel y) =>
      (ih: (y: Nat) -> (r: rel y x) -> Eq Nat y y) =>
        refl x)
    h
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('D4.rec, D5.rec, and Acc.rect reduce through iota', () {
      // Each `refl zero` forces the eliminator to reduce to the method
      // result. The recursive arguments are function-typed, so the IH
      // must be a lambda closed over the constructor telescope.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
data D4[A: Type]: Type {
  mk4: (x: A) -> ((y: A) -> D4 A) -> D4 A;
}
val d4_iota: (f: (y: Nat) -> D4 Nat) ->
  Eq Nat (D4.rec Nat ((v: D4 Nat) => Nat)
    ((x: Nat) => (f: (y: Nat) -> D4 Nat) =>
      (ih: (y: Nat) -> Nat) => zero)
    (mk4 zero f)) zero =
  (f: (y: Nat) -> D4 Nat) => refl zero
data D5[A: Type]: Type {
  mk5: (x: A) -> ((y: A) -> Eq A y x -> D5 A) -> D5 A;
}
val d5_iota: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) ->
  Eq Nat (D5.rec Nat ((v: D5 Nat) => Nat)
    ((x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
      (ih: (y: Nat) -> (e: Eq Nat y x) -> Nat) => zero)
    (mk5 x f)) zero =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) => refl zero
fun rel(a: Nat, b: Nat): Prop = Eq Nat a b
val acc_rect_true: (n: Nat) -> Acc Nat rel n -> Nat =
  (n: Nat) => (h: Acc Nat rel n) => Acc.rect Nat rel
    ((x: Nat) => (v: Acc Nat rel x) => Nat)
    n
    ((x: Nat) =>
      (f: (y: Nat) -> rel y x -> Acc Nat rel y) =>
      (ih: (y: Nat) -> (r: rel y x) -> Nat) => zero)
    h
val acc_rect_iota:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) ->
  Eq Nat (acc_rect_true n (accIntro n f)) zero =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => refl zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('the Prop-motive Acc.rec observer reduces', () {
      // `observe_iota` needs `observe n f` to reduce to zero, which
      // requires the Acc.rec IH to be the closed lambda
      // `(y) -> (r) -> Eq Nat y y`.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun rel(a: Nat, b: Nat): Prop = Eq Nat a b
val acc_true: (n: Nat) -> Acc Nat rel n -> Eq Nat n n =
  (n: Nat) => (h: Acc Nat rel n) => Acc.rec Nat rel
    ((x: Nat) => (v: Acc Nat rel x) => Eq Nat x x)
    n
    ((x: Nat) =>
      (f: (y: Nat) -> rel y x -> Acc Nat rel y) =>
      (ih: (y: Nat) -> (r: rel y x) -> Eq Nat y y) => refl x)
    h
val observe:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) -> Nat =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => Eq.rect Nat
    ((a: Nat) => (b: Nat) => (_: Eq Nat a b) => Nat)
    n n ((z: Nat) => zero)
    (acc_true n (accIntro n f))
val observe_iota:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) ->
  Eq Nat (observe n f) zero =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => refl zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('D4.rec applies the function-typed IH', () {
      // The step applies the IH to `x`, so the identity of the IH is
      // observable: `ih x` must be `D4.rec ... (f x)`.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
data D4[A: Type]: Type {
  mk4: (x: A) -> ((y: A) -> D4 A) -> D4 A;
}
val step: (x: Nat) -> (f: (y: Nat) -> D4 Nat) -> ((y: Nat) -> Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> D4 Nat) => (ih: (y: Nat) -> Nat) => succ (ih x)
val d4_use: (x: Nat) -> (f: (y: Nat) -> D4 Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> D4 Nat) =>
    D4.rec Nat ((_: D4 Nat) => Nat) step (mk4 x f)
val d4_expected: (x: Nat) -> (f: (y: Nat) -> D4 Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> D4 Nat) =>
    succ (D4.rec Nat ((_: D4 Nat) => Nat) step (f x))
val d4_use_iota: (x: Nat) -> (f: (y: Nat) -> D4 Nat) ->
  Eq Nat (d4_use x f) (d4_expected x f) =
  (x: Nat) => (f: (y: Nat) -> D4 Nat) => refl (d4_expected x f)
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('D5.rec applies the dependent function-typed IH', () {
      // The IH is applied at `x` with `refl x`, so the dependent
      // domain and the recursive-call body must both line up.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
data D5[A: Type]: Type {
  mk5: (x: A) -> ((y: A) -> Eq A y x -> D5 A) -> D5 A;
}
val step5: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) ->
    ((y: Nat) -> (e: Eq Nat y x) -> Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
  (ih: (y: Nat) -> (e: Eq Nat y x) -> Nat) => succ (ih x (refl x))
val d5_use: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
    D5.rec Nat ((_: D5 Nat) => Nat) step5 (mk5 x f)
val d5_expected: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
    succ (D5.rec Nat ((_: D5 Nat) => Nat) step5 (f x (refl x)))
val d5_use_iota: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) ->
  Eq Nat (d5_use x f) (d5_expected x f) =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
    refl (d5_expected x f)
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('Acc.rect applies the function-typed IH', () {
      // The step applies the IH at the constructor's own index and
      // proof. Acc is Prop-sorted, so the Type-valued motive uses
      // `Acc.rect`.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun rel(a: Nat, b: Nat): Prop = Eq Nat a b
val acc_motive:
  (x: Nat) -> (v: Acc Nat rel x) -> Type =
  (x: Nat) => (v: Acc Nat rel x) => (r: rel x x) -> Nat
val acc_step:
  (x: Nat) ->
  (f: (y: Nat) -> rel y x -> Acc Nat rel y) ->
  (ih: (y: Nat) -> (r: rel y x) -> (r2: rel y y) -> Nat) ->
  (r: rel x x) -> Nat =
  (x: Nat) =>
  (f: (y: Nat) -> rel y x -> Acc Nat rel y) =>
  (ih: (y: Nat) -> (r: rel y x) -> (r2: rel y y) -> Nat) =>
  (r: rel x x) => ih x r r
val acc_ih: (n: Nat) -> (h: Acc Nat rel n) -> (r: rel n n) -> Nat =
  (n: Nat) => (h: Acc Nat rel n) =>
    Acc.rect Nat rel acc_motive n acc_step h
val acc_expected:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) ->
  (r: rel n n) -> Nat =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => (r: rel n n) =>
    Acc.rect Nat rel acc_motive n acc_step (f n r) r
val acc_ih_iota:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) ->
  (r: rel n n) ->
  Eq Nat (acc_ih n (accIntro n f) r) (acc_expected n f r) =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => (r: rel n n) =>
    refl (acc_expected n f r)
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('Tree.rec selects the nodeT method and preserves the spine', () {
      // Two constructors put nodeT at method index 1. The IH-use
      // comparison checks that the iota step keeps the full head spine
      // and returns the recursive call on `f x`.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
data Tree[A: Type]: Type {
  leafT: Tree A;
  nodeT: (x: A) -> ((y: A) -> Tree A) -> Tree A;
}
val tree_count: (t: Tree Nat) -> Nat =
  (t: Tree Nat) => Tree.rec Nat ((_: Tree Nat) => Nat)
    zero
    ((x: Nat) => (f: (y: Nat) -> Tree Nat) =>
      (ih: (y: Nat) -> Nat) => succ (ih x))
    t
val tree_use: (x: Nat) -> (f: (y: Nat) -> Tree Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Tree Nat) => tree_count (nodeT x f)
val tree_expected: (x: Nat) -> (f: (y: Nat) -> Tree Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Tree Nat) => succ (tree_count (f x))
val tree_iota: (x: Nat) -> (f: (y: Nat) -> Tree Nat) ->
  Eq Nat (tree_use x f) (tree_expected x f) =
  (x: Nat) => (f: (y: Nat) -> Tree Nat) => refl (tree_expected x f)
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
  group('tactic-block recursion', () {
    const msg = 'a recursive call inside a `by` block is not checked';

    test('a measured bypass inside a by block is rejected', () {
      // The ordinary call `f n_` decreases the measure; the growing call
      // inside the block was previously invisible to the checker.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Nat decreases (n) = match n {
  case zero => zero
  case succ n_ => plus (f n_) (by { exact f (succ n) })
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains(msg));
      expect(r.stderr, contains('The `by` block in "f"'));
    });

    test('a structural mixed call inside a by block is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun g(n: Nat): Nat = match n {
  case zero => zero
  case succ n_ => plus (g n_) (by { exact g (succ n) })
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains(msg));
    });

    test('a body that only recurses inside a by block is rejected', () {
      // Previously this crashed with an unbound TTop during the kernel
      // check because the function was not recognised as recursive.
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun bad3(n: Nat): Nat = by { exact bad3 (succ n) }
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains(msg));
      expect(r.stderr, isNot(contains('Bad state')));
    });

    test('a non-recursive by block still checks', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun idp(n: Nat): Eq Nat n n = by { exact refl n }
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a harmless by block in a recursive function still checks', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun h(n: Nat): Nat = match n {
  case zero => zero
  case succ n_ => plus (h n_) (by { exact zero })
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a call inside a have proof is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Nat decreases (n) = match n {
  case zero => zero
  case succ n_ => plus (f n_) (by { have q : Nat = f (succ n); exact zero })
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains(msg));
    });

    test('a call inside a nested by block is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Nat decreases (n) = by { exact (by { exact f (succ n) }) }
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains(msg));
    });

    test('calls inside apply, rewrite, simp, and cases are rejected', () {
      const sources = [
        'fun f(n: Nat): Nat decreases (n) = by { apply f }',
        'fun f(n: Nat): Nat decreases (n) = by { rewrite f (succ n); exact zero }',
        'fun f(n: Nat): Nat decreases (n) = by { simp [f (succ n)] }',
        'fun f(n: Nat): Nat decreases (n) = by { cases n; exact f (succ n) }',
      ];
      for (final body in sources) {
        final r = runSource('''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
$body
''');
        expect(r.code, 1, reason: body);
        expect(r.stderr, contains(msg), reason: body);
      }
    });
    test('auto in a recursive block is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Nat = match n {
  case zero => by { auto }
  case succ n_ => f n_
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains(msg));
      expect(r.stderr, contains('contains `auto` or `omega`'));
    });

    test('omega in a recursive block is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Eq Nat zero zero = match n {
  case zero => by { omega }
  case succ n_ => f n_
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains(msg));
    });

    test('auto in a mutually recursive block is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun f(n: Nat): Nat = by { auto }
and g(n: Nat): Nat = f n
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains(msg));
    });

    test('a non-recursive by { auto } proof still checks', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
fun idp(n: Nat): Eq Nat n n = by { auto }
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a non-recursive by { omega } proof still checks', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
fun pz(n: Nat): Eq Nat (plus n zero) n = by { omega }

val plus_zero_again : (n: Nat) -> Eq Nat (plus n zero) n =
  by { intro n; omega }
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}
