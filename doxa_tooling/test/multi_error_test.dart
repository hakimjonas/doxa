/// Multi-error reporting: verifies that `checkSource` collects ALL errors
/// in a single pass rather than stopping at the first one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;
import 'package:doxa_tooling/src/web_check.dart' show checkSourceString;

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
  Future<dynamic> addStream(Stream<List<int>> stream) async {}
  @override
  Future<dynamic> close() async {}
  @override
  Future<dynamic> get done => Future.value();
  @override
  Future<dynamic> flush() async {}
}

void main() {
  group('Multi-error reporting', () {
    test('3 independent type errors all reported', () {
      const src = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val a : Bool = zero
val b : Bool = succ
val c : Bool = true_
''';
      final source = SourceFile(filename: 'test.doxa', text: src);
      final outBuf = _BufferedSink();
      final errBuf = _BufferedSink();
      final code = checkSource(source, out: outBuf, err: errBuf);

      expect(code, 1);
      final stderr = errBuf.toString();
      // Should contain 2 errors (a and b fail; c succeeds).
      expect(stderr, contains('error: type mismatch'));
      // Count the error occurrences.
      expect(
        stderr.split('error: type mismatch').length - 1,
        greaterThanOrEqualTo(2),
      );
      // Each error should have a source context.
      expect(stderr, contains('expected Bool, found Nat'));
    });

    test(
      'subsequent decls referencing a failed one are gracefully skipped',
      () {
        // `broken` fails type-checking and is NOT added to scope.
        // `also_broken` references `broken`, which is an unresolved name.
        const src = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val broken : Bool = zero
val also_broken : Bool = broken
''';
        final source = SourceFile(filename: 'test.doxa', text: src);
        final outBuf = _BufferedSink();
        final errBuf = _BufferedSink();
        final code = checkSource(source, out: outBuf, err: errBuf);

        expect(code, 1);
        final stderr = errBuf.toString();
        // First error: type mismatch (zero : Nat, expected Bool)
        expect(stderr, contains('error: type mismatch'));
        expect(stderr, contains('"broken"'));
        // Second error: unresolved name (broken was never added to scope)
        expect(stderr, contains('error: unresolved name'));
        expect(stderr, contains('also_broken'));
        // The annotation about the failed dependency appears.
        expect(stderr, contains('"broken" failed earlier'));
      },
    );

    test('3 errors reported via checkSourceString (web path)', () {
      const src = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val a : Bool = zero
val b : Bool = succ
val c : Bool = true_
''';
      final result = checkSourceString(src);
      // Should contain 2 error: type mismatch lines.
      expect(result, contains('error: type mismatch'));
      expect(result.split('error: type mismatch').length - 1, 2);
      expect(result, contains('val a'));
      expect(result, contains('val b'));
    });

    test('single error still works as before', () {
      const src = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val x : Bool = zero
''';
      final source = SourceFile(filename: 'test.doxa', text: src);
      final outBuf = _BufferedSink();
      final errBuf = _BufferedSink();
      final code = checkSource(source, out: outBuf, err: errBuf);

      expect(code, 1);
      final stderr = errBuf.toString();
      expect(stderr, contains('error: type mismatch'));
      expect(stderr, contains('expected Bool, found Nat'));
    });
  });
}
