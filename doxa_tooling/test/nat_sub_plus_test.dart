/// Concrete checks for the Nat order and subtraction helpers added for
/// the Int division shift. Each row closes by `refl`.
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

const _source = '''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"
val sub_plus: Eq Nat (sub (plus (succ (succ zero)) (succ zero)) (succ zero)) (succ (succ zero)) = refl
val leq_self: Eq Bool (leq (succ zero) (plus (succ (succ zero)) (succ zero))) true_ = refl
val lt_leq_row: Eq Bool (leq (succ zero) (succ (succ (succ zero)))) true_ = refl
val plus_sub: Eq Nat (plus (succ (succ (succ zero))) (sub (succ (succ zero)) (succ zero))) (plus (succ (succ zero)) (sub (succ (succ (succ zero))) (succ zero))) = refl
''';

void main() {
  test('the Nat subtraction and order helpers reduce by refl', () {
    final r = runSource(_source);
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });
}
