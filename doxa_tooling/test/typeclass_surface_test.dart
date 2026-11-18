/// Typeclass and impl declarations are rejected until resolution and
/// method projection are implemented. The parser and formatter still
/// handle the syntax.
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
  group('typeclass surface', () {
    test('typeclass declaration is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
typeclass Default[A: Type] {
  fun default(): A;
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(
        r.stderr,
        contains('typeclass declarations and instances are not supported'),
      );
      expect(
        r.stderr,
        contains('The `typeclass` and `impl` surface is rejected'),
      );
    });

    test('impl declaration is rejected', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
impl Default[Nat] {
  fun default(): Nat = zero;
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(
        r.stderr,
        contains('typeclass declarations and instances are not supported'),
      );
    });
  });
}
