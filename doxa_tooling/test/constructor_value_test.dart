/// A constructor is not a first-class function value. A bare constructor
/// in a higher-order position is a partial application, and the checker
/// must report an arity mismatch instead of evaluating a codomain over a
/// non-function constructor value.
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
  group('partial constructor applications', () {
    test('a bare constructor as a higher-order argument is rejected', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
val h: Eq Nat (succ zero) (succ zero) =
  cong_e Nat Nat succ zero zero (refl zero)
''');
      expect(r.code, isNot(0));
      expect(r.stderr, contains('inductive-type arity mismatch'));
      expect(r.stderr, contains('"Nat.succ" expects 1 argument'));
      expect(r.stderr, isNot(contains('RangeError')));
      expect(r.stderr, isNot(contains('Unhandled exception')));
    });

    test('the rejection holds in inference mode', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
val h = cong_e Nat Nat succ zero zero (refl zero)
''');
      expect(r.code, isNot(0));
      expect(r.stderr, contains('inductive-type arity mismatch'));
      expect(r.stderr, contains('"Nat.succ" expects 1 argument'));
    });

    test('a partial constructor against a function type is rejected', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
val f: (n: Nat) -> Lt n (succ n) = lt_succ
''');
      expect(r.code, isNot(0));
      expect(r.stderr, contains('inductive-type arity mismatch'));
      expect(r.stderr, contains('"Lt.lt_succ" expects 1 argument'));
    });

    test(
      'a partial constructor application as a function argument is rejected',
      () {
        final r = runSource('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
data Pair : Type {
  pair : Nat -> Nat -> Pair;
}
val cong2: (f: Nat -> Pair) -> (x: Nat) -> (y: Nat) -> Eq Nat x y -> Eq Pair (f x) (f y) =
  (f: Nat -> Pair) => (x: Nat) => (y: Nat) => (p: Eq Nat x y) => Eq.rec
    Nat
    ((a: Nat) => (b: Nat) => (_: Eq Nat a b) => Eq Pair (f a) (f b))
    x
    y
    ((z: Nat) => refl (f z))
    p
val bad: Eq Pair (pair zero zero) (pair zero zero) =
  cong2 (pair zero) zero zero (refl zero)
''');
        expect(r.code, isNot(0));
        expect(r.stderr, contains('inductive-type arity mismatch'));
        expect(r.stderr, contains('"Pair.pair" expects 2 arguments, got 1'));
        expect(r.stderr, isNot(contains('RangeError')));
      },
    );

    test('a partial function application still checks', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
val p: Nat -> Nat = plus zero
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('an eta-expanded constructor still checks', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
val h: Eq Nat (succ zero) (succ zero) =
  cong_e Nat Nat ((n: Nat) => succ n) zero zero (refl zero)
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('an applied constructor still checks', () {
      final r = runSource('''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
val h: Eq Nat (succ zero) (succ zero) = refl (succ zero)
val r: Eq Nat zero zero = refl zero
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}
