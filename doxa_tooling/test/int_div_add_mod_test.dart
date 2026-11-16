/// The Euclidean identity `a = b * q + r` for nonnegative dividends.
/// Each row is a bare `refl`, so the arithmetic must reduce to the
/// dividend definitionally. Values use `pos n` for `n` and `neg n` for
/// `-(n + 1)`, so -2 is `neg 1`.
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

const _numerals = '''
val n0: Nat = zero
val n1: Nat = succ n0
val n2: Nat = succ n1
val n3: Nat = succ n2
val n5: Nat = succ (succ (succ (succ (succ n0))))
val n6: Nat = succ n5
val n7: Nat = succ n6
val p0: Int = pos n0
val p2: Int = pos n2
val p3: Int = pos n3
val p5: Int = pos n5
val p6: Int = pos n6
val p7: Int = pos n7
val m1: Int = neg n0
val m2: Int = neg n1
val m3: Int = neg n2
val m5: Int = neg (succ (succ (succ (succ zero))))
val m6: Int = neg n5
val m7: Int = neg n6
''';

String _src(String body) => '''
import "../doxa_stdlib/lib/stdlib/int.doxa"
$_numerals
$body
''';

const _positiveDivisor = [('p7', 'p2'), ('p6', 'p3'), ('p2', 'p2')];

const _negativeDivisor = [('p7', 'm2'), ('p6', 'm3')];

const _zeroCases = [('p0', 'p2'), ('p0', 'm2'), ('p5', 'p0')];

String _row(String a, String b, int index) =>
    'val row$index: Eq Int '
    '(intPlus (intMult $b (intDiv $a $b)) (intMod $a $b)) $a = refl';

String _build(List<(String, String)> rows, {String? use}) {
  final buffer = StringBuffer();
  for (var i = 0; i < rows.length; i++) {
    final (a, b) = rows[i];
    buffer.writeln(_row(a, b, i));
  }
  if (use != null) buffer.writeln(use);
  return _src(buffer.toString());
}

void main() {
  test('the identity holds for positive divisors', () {
    final r = runSource(_build(_positiveDivisor));
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });

  test('the identity holds for negative divisors', () {
    final r = runSource(_build(_negativeDivisor));
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });

  test('the identity holds for zero divisors and zero dividends', () {
    final r = runSource(_build(_zeroCases));
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });

  test('negative dividend, positive divisor', () {
    final r = runSource(
      _build(
        [('m7', 'p2'), ('m6', 'p2'), ('m5', 'p2')],
        use:
            'val use_neg_pos: Eq Int (neg n6) (neg n6) = '
            'intDivMod (neg n6) (pos n2)\n'
            'val z_neg_pos: Nat = zero',
      ),
    );
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });

  test('negative dividend, negative divisor', () {
    final r = runSource(
      _build(
        [('m7', 'm2'), ('m6', 'm2'), ('m5', 'm2')],
        use:
            'val use_neg_neg: Eq Int (neg n6) (neg n6) = '
            'intDivMod (neg n6) (neg n1)\n'
            'val z_neg_neg: Nat = zero',
      ),
    );
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });

  test('zero divisor with a negative dividend', () {
    final r = runSource(
      _build(
        [('m5', 'p0')],
        use:
            'val use_zero: Eq Int (neg n5) (neg n5) = '
            'intDivMod (neg n5) (pos n0)\n'
            'val z_zero: Nat = zero',
      ),
    );
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });
}
