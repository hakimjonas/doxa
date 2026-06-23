/// Runs every `.doxa` file in `test/programs/` through the CLI pipeline:
/// `positive/` must type-check, `negative/` must fail with the expected
/// diagnostic.
///
/// Uses `checkSource` directly (not a subprocess) to capture
/// stdout/stderr into strings for assertion.
library;

import 'dart:async';
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

  // IOSink methods we don't use in tests. Forward to the buffer where
  // sensible; no-op the rest.
  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
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
  final programsDir = Directory('test/programs');

  group('Positive programs (must type-check)', () {
    final dir = Directory('${programsDir.path}/positive');
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.doxa'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      test(_basename(file), () {
        final r = runFile(file);
        expect(
          r.code,
          0,
          reason:
              'expected success but got exit ${r.code}\n'
              'stdout:\n${r.stdout}\nstderr:\n${r.stderr}',
        );
        expect(r.stdout, startsWith('OK:'));
      });
    }
  });

  group('Negative programs (must fail with matching diagnostic)', () {
    /// Each filename maps to an expected substring of the diagnostic.
    const expectations = <String, String>{
      'type_mismatch.doxa': 'error: type mismatch',
      'not_a_function.doxa': 'error: not a function',
      'not_a_type.doxa': 'error: not a type',
      'unresolved_name.doxa': 'error: unresolved name',
      'duplicate_declaration.doxa': 'error: duplicate declaration',
      'parse_error.doxa': 'error: parse error',
      'block_no_result.doxa': 'error: parse error',
      'universe_mismatch.doxa': 'error: type mismatch',
      'positivity_violation.doxa': 'error: positivity violation',
      'ctor_arg_mismatch.doxa': 'error: type mismatch',
      'non_structural_recursion.doxa': 'error: non-structural recursion',
      'prop_elim_into_type.doxa': 'error: Prop elimination into Type',
      'prop_elim_informative_arg.doxa': 'error: Prop elimination into Type',
      'non_exhaustive_match.doxa': 'error: match is not exhaustive',
      'duplicate_case.doxa': 'error: duplicate case in match',
      'auto_refl_mismatch.doxa': 'error: type mismatch',
      'uip_not_statable.doxa': 'error: type mismatch',
      'vec_index_motive_false.doxa': 'error: type mismatch',
    };

    for (final entry in expectations.entries) {
      final file = File('${programsDir.path}/negative/${entry.key}');
      test(entry.key, () {
        expect(file.existsSync(), isTrue, reason: 'missing: ${file.path}');
        final r = runFile(file);
        expect(r.code, 1, reason: 'expected failure exit 1, got ${r.code}');
        expect(
          r.stderr,
          contains(entry.value),
          reason: 'stderr did not contain "${entry.value}":\n${r.stderr}',
        );
      });
    }
  });
}

String _basename(File f) {
  final parts = f.path.split(Platform.pathSeparator);
  return parts.isEmpty ? f.path : parts.last;
}
