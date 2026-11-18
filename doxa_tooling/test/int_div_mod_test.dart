/// Euclidean integer division and modulo. Each row is checked by `refl`,
/// so the definitions must reduce to the expected quotient and remainder.
/// A value `v = n` is `pos n` and `v = -(n + 1)` is `neg n`, so -7 is
/// `neg 6`.
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
val n4: Nat = succ n3
val n5: Nat = succ n4
val n6: Nat = succ n5
val n7: Nat = succ n6
val p0: Int = pos n0
val p1: Int = pos n1
val p2: Int = pos n2
val p3: Int = pos n3
val p4: Int = pos n4
val p5: Int = pos n5
val p6: Int = pos n6
val p7: Int = pos n7
val m2: Int = neg n1
val m3: Int = neg n2
val m4: Int = neg n3
val m5: Int = neg n4
val m6: Int = neg n5
val m7: Int = neg n6
''';

String _src(String body) => '''
import "../doxa_stdlib/lib/stdlib/int.doxa"
$_numerals
$body
''';

void main() {
  final cases = <String, List<(String, String, String, String)>>{
    'positive dividend, positive divisor': [
      ('intDiv p7 p2', 'p3', 'intMod p7 p2', 'p1'),
      ('intDiv p6 p3', 'p2', 'intMod p6 p3', 'p0'),
      ('intDiv p2 p2', 'p1', 'intMod p2 p2', 'p0'),
      ('intDiv p0 p2', 'p0', 'intMod p0 p2', 'p0'),
    ],
    'negative dividend, positive divisor': [
      ('intDiv m7 p2', 'm4', 'intMod m7 p2', 'p1'),
      ('intDiv m6 p2', 'm3', 'intMod m6 p2', 'p0'),
      ('intDiv m5 p2', 'm3', 'intMod m5 p2', 'p1'),
      ('intDiv m6 p3', 'm2', 'intMod m6 p3', 'p0'),
    ],
    'positive dividend, negative divisor': [
      ('intDiv p7 m2', 'm3', 'intMod p7 m2', 'p1'),
      ('intDiv p7 m3', 'm2', 'intMod p7 m3', 'p1'),
      ('intDiv p6 m3', 'm2', 'intMod p6 m3', 'p0'),
      ('intDiv p0 m2', 'p0', 'intMod p0 m2', 'p0'),
    ],
    'negative dividend, negative divisor': [
      ('intDiv m7 m2', 'p4', 'intMod m7 m2', 'p1'),
      ('intDiv m6 m2', 'p3', 'intMod m6 m2', 'p0'),
      ('intDiv m5 m2', 'p3', 'intMod m5 m2', 'p1'),
      ('intDiv m6 m3', 'p2', 'intMod m6 m3', 'p0'),
      ('intDiv m2 m2', 'p1', 'intMod m2 m2', 'p0'),
    ],
    'zero divisor': [
      ('intDiv p5 p0', 'p0', 'intMod p5 p0', 'p5'),
      ('intDiv m5 p0', 'p0', 'intMod m5 p0', 'm5'),
    ],
  };

  cases.forEach((name, rows) {
    test(name, () {
      final buffer = StringBuffer();
      for (final (divExpr, divExpected, modExpr, modExpected) in rows) {
        buffer.writeln(
          'val ${divExpr.replaceAll(' ', '_')}_d: '
          'Eq Int ($divExpr) $divExpected = refl',
        );
        buffer.writeln(
          'val ${modExpr.replaceAll(' ', '_')}_m: '
          'Eq Int ($modExpr) $modExpected = refl',
        );
      }
      final r = runSource(_src(buffer.toString()));
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}
