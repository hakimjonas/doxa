/// Rational surface through the CLI: the stdlib consumer fixture
/// elaborates the normalized-pair arithmetic and reduces every `refl`
/// equation, including the `Eqb[Rat]` instance call.
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

void main() {
  test('the rational arithmetic consumer checks through the CLI', () {
    final fixture = File('test/fixtures/rational_arith.doxa');
    final source = SourceFile(
      filename: fixture.path,
      text: fixture.readAsStringSync(),
    );
    final out = _BufferedSink();
    final err = _BufferedSink();
    final code = checkSource(source, out: out, err: err);
    expect(code, 0, reason: err.toString());
    expect(out.toString(), startsWith('OK:'));
  });
}
