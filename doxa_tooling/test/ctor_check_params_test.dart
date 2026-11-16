/// Constructor applications in check mode: data parameters must be
/// solved from the expected type before the explicit arguments are
/// checked, so an argument type that mentions a value parameter sees
/// the solved parameter.
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
  group('constructor parameters from the expected type', () {
    test('Box3 solves a value parameter used in an argument type', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
data Box3[A: Type, R: A -> A -> Prop]: Type {
  box3: (x: A) -> ((y: A) -> R y x -> Box3 A R) -> Box3 A R;
}
val apply_box:
  (R: Nat -> Nat -> Prop) ->
  (f: (y: Nat) -> R y zero -> Box3 Nat R) ->
  Box3 Nat R =
  (R: Nat -> Nat -> Prop) =>
  (f: (y: Nat) -> R y zero -> Box3 Nat R) =>
  box3 zero f
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('nullary constructors with value parameters still check', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
data Triv: Prop {
  triv: Triv;
}
data Box[A: Type, x: A]: Type {
  box: Box A x;
}
data Box2[A: Type, R: A -> A -> Prop]: Type {
  box2: Box2 A R;
}
val b1: Box Nat zero = box
val b2: Box2 Nat ((a: Nat) => (b: Nat) => Triv) = box2
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a wrong constructor argument reports a type mismatch', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
data Triv: Prop {
  triv: Triv;
}
data Bool: Type {
  true_: Bool;
  false_: Bool;
}
data Box3[A: Type, R: A -> A -> Prop]: Type {
  box3: (x: A) -> ((y: A) -> R y x -> Box3 A R) -> Box3 A R;
}
val bad: Box3 Nat ((a: Nat) => (b: Nat) => Triv) = box3 zero true_
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('error: type mismatch'));
      expect(r.stderr, contains('true_'));
    });
  });

  group('match arm parameter telescopes', () {
    test('two-parameter D gives the arm binder the second parameter', () {
      const src = '''
data B1: Type {
  b1: B1;
}
data B2: Type {
  b2: B2;
}
data D[A: Type, B: Type]: Type {
  mkD: (x: B) -> D A B;
}
fun f(d: D B1 B2): B2 = match d {
  case mkD x => x
}
val t: B2 = f (mkD b2)
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('three-parameter D3 gives the arm binder the third parameter', () {
      const src = '''
data A1: Type {
  a1: A1;
}
data B1: Type {
  b1: B1;
}
data C1: Type {
  c1: C1;
}
data D3[A: Type, B: Type, C: Type]: Type {
  mk3: (x: C) -> D3 A B C;
}
fun f3(d: D3 A1 B1 C1): C1 = match d {
  case mk3 x => x
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('reachability reads a constructor result index from the '
        'second parameter', () {
      // mkB's result index is `m`, the second parameter. The arm is
      // omitted; the kernel must report it as reachable.
      const src = '''
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}
data D[n: Nat, m: Nat]: Nat -> Type {
  mkA: D n m n;
  mkB: D n m m;
}
fun f(d: D zero (succ zero) (succ zero)): Nat = match d {
  case mkA => zero
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('not exhaustive'));
      expect(r.stderr, contains('mkB'));
    });

    test('parameterized AccP, nat_wfP, and strong_ind_implP check', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
data AccP[A: Type, R: A -> A -> Prop]: A -> Prop {
  acc_introP: (x: A) ->
    ((y: A) -> R y x -> AccP A R y) -> AccP A R x;
}
fun ltP(a: Nat, b: Nat): Prop = Lt a b
fun nat_wfP(n: Nat): AccP Nat ltP n = match n {
  case zero => acc_introP zero
    ((y: Nat) => (h: Lt y zero) => False.rec
      ((_: False) => AccP Nat ltP y)
      (Lt.rec
        ((a: Nat) => (b: Nat) => (_: Lt a b) => Eq Nat b zero -> False)
        y
        zero
        ((n_: Nat) => (eq: Eq Nat (succ n_) zero) => succ_ne_zero n_ eq)
        ((n_: Nat) => (m: Nat) => (k: Nat) => (_: Lt n_ m) => (_: Lt m k) =>
          (_: Eq Nat m zero -> False) => (ih2: Eq Nat k zero -> False) =>
          (eq: Eq Nat k zero) => ih2 eq)
        h
        (refl zero)))
  case succ k => acc_introP (succ k)
    ((y: Nat) => (h: Lt y (succ k)) => nat_wfP_help k y h)
} and nat_wfP_help(k: Nat, y: Nat, h: Lt y (succ k)):
    AccP Nat ltP y {struct h} = match h {
  case lt_succ y_ => nat_wfP y_
  case lt_trans y_ m _ p1 p2 => match nat_wfP_help k m p2 {
    case acc_introP _ f => f y_ p1
  }
}
fun strong_ind_implP(
  n: Nat,
  P: Nat -> Prop,
  step: (n: Nat) -> ((k: Nat) -> Lt k n -> P k) -> P n
): P n =
  AccP.rec Nat ltP
    ((m: Nat) => (v: AccP Nat ltP m) => P m)
    n
    ((x: Nat) =>
      (f: (y: Nat) -> ltP y x -> AccP Nat ltP y) =>
      (ih: (y: Nat) -> (h: ltP y x) -> P y) =>
      step x ih)
    (nat_wfP n)
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}
