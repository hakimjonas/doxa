/// Edge-case tests for `Nat` division and modulo. The conventions under
/// test are specified in `docs/arithmetic.md`: floor division for a
/// positive divisor, `div m zero = zero`, and `mod m zero = m`.
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

/// Shared preamble: imports `nat.doxa` and binds the numerals used by the
/// edge cases. Doxa has no decimal term literals, so each numeral is a
/// `succ` chain.
const _preamble = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
val one: Nat = succ zero
val two: Nat = succ (succ zero)
val four: Nat = succ (succ (succ (succ zero)))
val five: Nat = succ (succ (succ (succ (succ zero))))
''';

void main() {
  group('Nat division and modulo edge cases', () {
    test('positive divisor: div and mod compute by refl', () {
      final r = runSource('''
$_preamble
val div_5_2: Eq Nat (div five two) two = refl two
val mod_5_2: Eq Nat (mod five two) one = refl one
val div_4_2: Eq Nat (div four two) two = refl two
val mod_4_2: Eq Nat (mod four two) zero = refl zero
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('zero divisor: div m zero = zero and mod m zero = m', () {
      final r = runSource('''
$_preamble
val div_5_0: Eq Nat (div five zero) zero = refl zero
val mod_5_0: Eq Nat (mod five zero) five = refl five
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('zero dividend: div 0 n = 0 and mod 0 n = 0', () {
      final r = runSource('''
$_preamble
val div_0_2: Eq Nat (div zero two) zero = refl zero
val mod_0_2: Eq Nat (mod zero two) zero = refl zero
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('dividend smaller than divisor: div 1 2 = 0 and mod 1 2 = 1', () {
      final r = runSource('''
$_preamble
val div_1_2: Eq Nat (div one two) zero = refl zero
val mod_1_2: Eq Nat (mod one two) one = refl one
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}
