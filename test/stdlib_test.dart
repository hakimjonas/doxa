/// Runs the CLI check on every `lib/stdlib/*.doxa` file; each must type-check.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

void main() {
  final stdlibDir = Directory('lib/stdlib');

  group('stdlib type-checks', () {
    // Discover all .doxa files in lib/stdlib/. If the directory is
    // missing (e.g. running from a package that doesn't include the
    // stdlib), skip gracefully.
    if (!stdlibDir.existsSync()) {
      test('lib/stdlib/ directory exists', () {
        fail('expected lib/stdlib/ to exist');
      });
      return;
    }

    final files =
        stdlibDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.doxa'))
            // prelude.doxa is ambient-loaded by the CLI; checking it
            // explicitly would re-introduce Eq as a duplicate declaration.
            // The prelude's correctness is tested indirectly: every other
            // stdlib file references Eq (via `refl`, etc.) and depends on
            // the prelude being loaded.
            .where((f) => !f.path.endsWith('prelude.doxa'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      test(file.uri.pathSegments.last, () {
        final text = file.readAsStringSync();
        final source = SourceFile(filename: file.path, text: text);
        final outBuf = _BufferedSink();
        final errBuf = _BufferedSink();
        final code = checkSource(source, out: outBuf, err: errBuf);
        expect(
          code,
          0,
          reason:
              'expected exit code 0 for ${file.path}\n'
              'stdout: ${outBuf.toString()}\n'
              'stderr: ${errBuf.toString()}',
        );
        expect(outBuf.toString(), startsWith('OK:'));
      });
    }
  });
}

/// An IOSink that accumulates into a StringBuffer. Copy of the same
/// helper in programs_test.dart to avoid cross-test dependencies.
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
