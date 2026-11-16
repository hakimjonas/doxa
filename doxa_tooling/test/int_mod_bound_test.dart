/// The Euclidean bound: `0 <= intMod a b` and `intMod a b < |b|` for
/// `b != 0`. The rows are concrete `refl` checks; the theorem
/// applications carry the nonzero divisor hypothesis explicitly and are
/// followed by another declaration, so `_shimState` re-evaluates them.
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
val n6: Nat = succ (succ (succ (succ (succ (succ n0)))))
val p0: Int = pos n0
val p2: Int = pos n2
val p7: Int = pos (succ n6)
val m2: Int = neg n1
val m7: Int = neg n6
''';

String _src(String body) => '''
import "../lib/stdlib/int.doxa"
$_numerals
$body
''';

/// The (a, b) pairs: 7/2, -7/2, 7/-2, -7/-2.
const _pairs = [('p7', 'p2'), ('m7', 'p2'), ('p7', 'm2'), ('m7', 'm2')];

void main() {
  test('intMod is nonnegative on the concrete sign matrix', () {
    final buffer = StringBuffer();
    for (var i = 0; i < _pairs.length; i++) {
      final (a, b) = _pairs[i];
      buffer.writeln(
        'val low$i: Eq Bool (intLeq (pos zero) (intMod $a $b)) true_ = refl',
      );
    }
    final r = runSource(_src(buffer.toString()));
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });

  test('intMod is below the divisor magnitude on the sign matrix', () {
    final buffer = StringBuffer();
    for (var i = 0; i < _pairs.length; i++) {
      final (a, b) = _pairs[i];
      buffer.writeln(
        'val up$i: Eq Bool '
        '(intLeq (intPlus (intMod $a $b) (pos (succ zero))) (pos (intAbs $b))) '
        'true_ = refl',
      );
    }
    final r = runSource(_src(buffer.toString()));
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });

  test('the bound theorems apply with explicit nonzero hypotheses', () {
    const body = '''
val use_nonneg_pos: (h: Eq Int p2 (pos zero) -> False) ->
  Eq Bool (intLeq (pos zero) (intMod p7 p2)) true_ =
  (h: Eq Int p2 (pos zero) -> False) => intMod_nonneg p7 p2 h
val z_nonneg_pos: Nat = zero
val use_lt_pos: (h: Eq Int p2 (pos zero) -> False) ->
  Eq Bool (intLeq (intPlus (intMod p7 p2) (pos (succ zero))) (pos (intAbs p2))) true_ =
  (h: Eq Int p2 (pos zero) -> False) => intMod_lt p7 p2 h
val z_lt_pos: Nat = zero
val use_nonneg_neg: (h: Eq Int m2 (pos zero) -> False) ->
  Eq Bool (intLeq (pos zero) (intMod p7 m2)) true_ =
  (h: Eq Int m2 (pos zero) -> False) => intMod_nonneg p7 m2 h
val z_nonneg_neg: Nat = zero
val use_lt_neg: (h: Eq Int m2 (pos zero) -> False) ->
  Eq Bool (intLeq (intPlus (intMod p7 m2) (pos (succ zero))) (pos (intAbs m2))) true_ =
  (h: Eq Int m2 (pos zero) -> False) => intMod_lt p7 m2 h
val z_lt_neg: Nat = zero
''';
    final r = runSource(_src(body));
    expect(r.code, 0, reason: 'stderr: ${r.stderr}');
  });
}
