/// `have` and `calc` through the CLI, with the standard library's
/// arithmetic lemmas.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

void main() {
  test('a three-step arithmetic chain and a have fact check', () {
    final fixture = File('test/fixtures/have_calc_proofs.doxa');
    final source = SourceFile(
      filename: fixture.path,
      text: fixture.readAsStringSync(),
    );
    final out = _BufferedSink();
    final err = _BufferedSink();
    final code = checkSource(source, out: out, err: err);
    expect(code, 0, reason: err.toString());
    expect(out.toString(), contains('OK:'));
  });
}

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
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
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
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  Future<void> flush() async {}
}
