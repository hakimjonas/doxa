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
import "../lib/stdlib/nat.doxa"
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
import "../lib/stdlib/nat.doxa"
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
import "../lib/stdlib/nat.doxa"
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
}
