/// Tests for the `import "path"` declaration feature.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

/// Run [checkSource] against [file] and return its exit code, stdout,
/// and stderr.
({int code, String stdout, String stderr}) runFile(File file) {
  final text = file.readAsStringSync();
  final source = SourceFile(filename: file.path, text: text);
  final outBuf = _BufferedSink();
  final errBuf = _BufferedSink();
  final code = checkSource(source, out: outBuf, err: errBuf);
  return (code: code, stdout: outBuf.toString(), stderr: errBuf.toString());
}

/// Run checkSourceString on inline source.
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
  final stdlibDir = Directory('../lib/stdlib');

  group('import', () {
    test('import "stdlib/nat.doxa" makes Nat, plus, etc. available', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
val x : Nat = zero
val y : Nat = plus zero zero
''';
      final r = runSource(src, filename: 'import_test.doxa');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('import multiple stdlib files works', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
import "../lib/stdlib/list.doxa"
val xs : List[Nat] = nil
val n : Nat = length xs
''';
      final r = runSource(src, filename: 'import_test.doxa');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('importing a file twice is idempotent', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
import "../lib/stdlib/nat.doxa"
val x : Nat = zero
''';
      final r = runSource(src, filename: 'import_test.doxa');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('import of non-existent file raises ImportFileNotFound', () {
      const src = 'import "nonexistent.doxa"';
      final r = runSource(src, filename: 'import_test.doxa');
      expect(r.code, 1);
      expect(r.stderr, contains('import file not found'));
    });

    test('self-import raises CyclicImport', () {
      // Create a temp file that imports itself.
      final tmpDir = Directory.systemTemp.createTempSync('doxa_import_test_');
      try {
        final file = File('${tmpDir.path}/self_import.doxa')
          ..writeAsStringSync('import "self_import.doxa"\nval x : Nat = zero');
        final r = runFile(file);
        expect(r.code, 1);
        expect(r.stderr, contains('cyclic import'));
      } finally {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('import paths resolve relative to importing file', () {
      // The stdlib dirs exist; test that path resolution works.
      final src = 'import "../lib/stdlib/nat.doxa"';
      final r = runSource(src, filename: 'import_test.doxa');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('transitive import works (list imports nat which imports bool)', () {
      const src = '''
import "../lib/stdlib/list.doxa"
val xs : List[Nat] = nil
''';
      final r = runSource(src, filename: 'import_test.doxa');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('stdlib nat.doxa type-checks via CLI', () {
      if (!stdlibDir.existsSync()) {
        fail('expected lib/stdlib/ to exist');
      }
      final file = File('${stdlibDir.path}/nat.doxa');
      if (!file.existsSync()) {
        fail('expected lib/stdlib/nat.doxa to exist');
      }
      final r = runFile(file);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('stdlib list.doxa type-checks via CLI', () {
      if (!stdlibDir.existsSync()) {
        fail('expected lib/stdlib/ to exist');
      }
      final file = File('${stdlibDir.path}/list.doxa');
      final r = runFile(file);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('stdlib proofs.doxa type-checks via CLI', () {
      if (!stdlibDir.existsSync()) {
        fail('expected lib/stdlib/ to exist');
      }
      final file = File('${stdlibDir.path}/proofs.doxa');
      final r = runFile(file);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('stdlib vec.doxa type-checks via CLI', () {
      if (!stdlibDir.existsSync()) {
        fail('expected lib/stdlib/ to exist');
      }
      final file = File('${stdlibDir.path}/vec.doxa');
      final r = runFile(file);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}

/// An IOSink that accumulates into a StringBuffer.
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
