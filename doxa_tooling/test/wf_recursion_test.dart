/// Tests for Phase 24: Well-founded recursion with `Acc` and
/// `termination_by` annotation.
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
import "../lib/stdlib/nat.doxa"
fun rel(a: Nat, b: Nat) : Prop = Eq[Nat] a b
val accProp : Prop = Acc[Nat] rel zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('acc_intro resolves (arity mismatch means name found)', () {
      // The parameterized `acc_intro` takes `x` and the accessibility
      // function. Supplying one explicit argument produces an arity
      // mismatch, which proves the constructor name resolves.
      const src = '''
import "../lib/stdlib/nat.doxa"
val intro = Acc[Nat].acc_intro zero
''';
      final r = runSource(src);
      expect(r.stderr, contains('arity mismatch'));
    });

    test('Acc.rec recursor exists', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
val rec = Acc[Nat].rec
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('termination_by parsed on simple fun', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
fun identity(x : Nat) : Nat termination_by (x) = x
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('invalid termination_by parameter -> error', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
fun f(x : Nat) : Nat termination_by (y) = x
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('termination_by'));
    });

    test('termination_by with {struct}', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
fun f(x : Nat) : Nat {struct x} termination_by (x) = x
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('structural recursion still works', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
fun my_plus(a : Nat, b : Nat) : Nat = match a {
  case zero => b
  case succ a_ => succ (my_plus a_ b)
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('termination_by fun is non-recursive', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
fun helper(m : Nat, n : Nat) : Nat termination_by (m) = plus m (plus m n)
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('termination_by on fun with no value params errors', () {
      const src = 'fun f(A : Type) : Type termination_by (x) = A';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('termination_by'));
    });

    test('strong_ind computes through nat_wf and Acc.rec', () {
      // `observed_iota` forces `strong_ind P step zero` through
      // `nat_wf zero` and Acc.rec to `step zero ... = refl zero`.
      const src = '''
import "../lib/stdlib/proofs.doxa"
fun P(n: Nat): Prop = Eq Nat n n
fun step(n: Nat, ih: (k: Nat) -> Lt k n -> P k): P n = refl n
val observed: Nat = Eq.rect Nat
  ((a: Nat) => (b: Nat) => (_: Eq Nat a b) => Nat)
  zero zero ((z: Nat) => zero)
  (strong_ind P step zero)
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
import "../lib/stdlib/nat.doxa"
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
      // The IH is function-shaped over the same Pi chain as acc_intro's
      // recursive argument.
      const src = '''
import "../lib/stdlib/nat.doxa"
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
import "../lib/stdlib/nat.doxa"
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
  Eq Nat (acc_rect_true n (acc_intro n f)) zero =
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
import "../lib/stdlib/nat.doxa"
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
    (acc_true n (acc_intro n f))
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
import "../lib/stdlib/nat.doxa"
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
import "../lib/stdlib/nat.doxa"
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
import "../lib/stdlib/nat.doxa"
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
  Eq Nat (acc_ih n (acc_intro n f) r) (acc_expected n f r) =
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
import "../lib/stdlib/nat.doxa"
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
}
