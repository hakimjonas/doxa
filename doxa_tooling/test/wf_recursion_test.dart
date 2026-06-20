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
      // Bare Acc[Nat].acc_intro produces arity mismatch, which proves
      // the constructor name resolves correctly.
      const src = '''
import "../lib/stdlib/nat.doxa"
fun rel(a: Nat, b: Nat) : Prop = Eq[Nat] a b
val intro = Acc[Nat].acc_intro rel zero
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
  });
}
