/// Quotient construction, elimination, and soundness through the CLI.
///
/// `Quot(A, R)` forms a type, `mk` and `lift` have check-mode rules, and
/// `Quot.sound` relates two injections propositionally. Each negative case
/// names the diagnostic it produces.
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

/// The shared prelude of the cases below: `Nat`, a two-field pair, and an
/// equal-sum relation, all from the standard library's `Nat` arithmetic.
const _pairPrelude = '''
import "../doxa_stdlib/lib/stdlib/proofs.doxa"

data Pair: Type {
  pair: (a: Nat) -> (b: Nat) -> Pair;
}

fun sum(p: Pair): Nat = plus p.a p.b

fun sameSum(x: Pair, y: Pair): Prop = Eq Nat (sum x) (sum y)
''';

void main() {
  test('the acceptance module checks through the CLI', () {
    final fixture = File('test/fixtures/quotient_pair.doxa');
    final source = SourceFile(
      filename: fixture.path,
      text: fixture.readAsStringSync(),
    );
    final out = _BufferedSink();
    final err = _BufferedSink();
    final code = checkSource(source, out: out, err: err);
    expect(code, 0, reason: err.toString());
    expect(out.toString(), startsWith('OK:'));
  });

  group('quotient surface', () {
    test('Quot(A, R) still forms a type', () {
      final r = runSource('''
$_pairPrelude
val q: Type = Quot(Pair, sameSum)
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('mk checks against the expected quotient type', () {
      final r = runSource('''
$_pairPrelude
val q: Quot(Pair, sameSum) = mk (pair zero zero)
val unq: (p: Pair) -> Quot(Pair, sameSum) = (p: Pair) => mk p
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('lift checks and computes', () {
      final r = runSource('''
$_pairPrelude
val sumQ: Quot(Pair, sameSum) -> Nat =
  lift(sum, (x: Pair) => (y: Pair) => (h: sameSum x y) => h)

val computes: (p: Pair) -> Eq Nat (sumQ (mk p)) (sum p) =
  (p: Pair) => refl (sum p)
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('Quot.sound relates two injections propositionally', () {
      final r = runSource('''
$_pairPrelude
val soundAt: (x: Pair) -> (y: Pair) -> sameSum x y ->
    Eq (Quot(Pair, sameSum)) (mk x) (mk y) =
  (x: Pair) => (y: Pair) => (h: sameSum x y) => Quot.sound h

val sumQ: Quot(Pair, sameSum) -> Nat =
  lift(sum, (x: Pair) => (y: Pair) => (h: sameSum x y) => h)

val respected: (x: Pair) -> (y: Pair) -> sameSum x y ->
    Eq Nat (sumQ (mk x)) (sumQ (mk y)) =
  (x: Pair) => (y: Pair) => (h: sameSum x y) => h

val transported: (x: Pair) -> (y: Pair) -> sameSum x y ->
    Eq (Quot(Pair, sameSum)) (mk x) (mk y) =
  (x: Pair) => (y: Pair) => (h: sameSum x y) =>
    cong ((q: Quot(Pair, sameSum)) => q) (soundAt x y h)
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a lift composes with Quot.sound through cong', () {
      final r = runSource('''
$_pairPrelude
val soundAt: (x: Pair) -> (y: Pair) -> sameSum x y ->
    Eq (Quot(Pair, sameSum)) (mk x) (mk y) =
  (x: Pair) => (y: Pair) => (h: sameSum x y) => Quot.sound h

val sumQ: Quot(Pair, sameSum) -> Nat =
  lift(sum, (x: Pair) => (y: Pair) => (h: sameSum x y) => h)

val respected: (x: Pair) -> (y: Pair) -> sameSum x y ->
    Eq Nat (sumQ (mk x)) (sumQ (mk y)) =
  (x: Pair) => (y: Pair) => (h: sameSum x y) => cong sumQ (soundAt x y h)

val respectWrapped: (x: Pair) -> (y: Pair) -> sameSum x y ->
    Eq Nat (sumQ (mk x)) (sumQ (mk y)) =
  (x: Pair) => (y: Pair) => (h: sameSum x y) =>
    cong ((q: Quot(Pair, sameSum)) => sumQ q) (soundAt x y h)
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('cong through a lift solves the indices from the proof argument', () {
      final r = runSource('''
$_pairPrelude
val sumQ: Quot(Pair, sameSum) -> Nat =
  lift(sum, (x: Pair) => (y: Pair) => (h: sameSum x y) => h)

val a: Pair = pair zero zero
val e0: Eq (Quot(Pair, sameSum)) (mk a) (mk a) =
  Quot.sound (refl (sum a))

val congruent: Eq Nat (sumQ (mk a)) (sumQ (mk a)) = cong sumQ e0
''');
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a lift whose result type reads the quotient element is rejected', () {
      final r = runSource('''
$_pairPrelude
val dep: (q: Quot(Pair, sameSum)) -> Eq (Quot(Pair, sameSum)) q q =
  lift((p: Pair) => mk p,
       (x: Pair) => (y: Pair) => (h: sameSum x y) => Quot.sound h)
''');
      expect(r.code, 1);
      expect(
        r.stderr,
        contains('quotient elimination needs a constant result type'),
      );
    });

    test('a relation that is not a relation is rejected on its span', () {
      final r = runSource('''
$_pairPrelude
val bad: Type = Quot(Pair, Type)
''');
      expect(r.code, 1);
      expect(r.stderr, contains('error: type mismatch'));
      expect(r.stderr, contains('expected Pair -> Pair -> Prop, found Type 1'));
    });

    test('mk without an expected type names the form', () {
      final r = runSource('''
$_pairPrelude
val q = mk (pair zero zero)
''');
      expect(r.code, 1);
      expect(r.stderr, contains('`mk` needs an expected type here'));
      expect(r.stderr, contains('val q: Quot(A, R) = mk a'));
    });

    test('lift without an expected type names the form', () {
      final r = runSource('''
$_pairPrelude
val sumQ = lift(sum, (x: Pair) => (y: Pair) => (h: sameSum x y) => h)
''');
      expect(r.code, 1);
      expect(r.stderr, contains('`lift` needs an expected type here'));
    });

    test('lift(f, h) q is not available: the lift itself needs a type', () {
      final r = runSource('''
$_pairPrelude
val applied: Nat =
  lift(sum, (x: Pair) => (y: Pair) => (h: sameSum x y) => h) (mk (pair zero zero))
''');
      expect(r.code, 1);
      expect(r.stderr, contains('`lift` needs an expected type here'));
    });

    test('a lift that ignores the relation is rejected', () {
      final r = runSource('''
$_pairPrelude
fun zeroAll(p: Pair): Nat = zero

val sumQ: Quot(Pair, sameSum) -> Nat =
  lift(zeroAll, (x: Pair) => (y: Pair) => (h: sameSum x y) => h)
''');
      expect(r.code, 1);
      expect(
        r.stderr,
        contains('error: quotient lift function does not respect the relation'),
      );
      expect(r.stderr, contains('expected compatibility proof type'));
    });

    test('Quot.sound against a type that is not an equality is rejected', () {
      final r = runSource('''
$_pairPrelude
val bad: (x: Pair) -> (y: Pair) -> Nat =
  (x: Pair) => (y: Pair) => Quot.sound (refl zero)
''');
      expect(r.code, 1);
      expect(
        r.stderr,
        contains('quotient soundness needs an equality of injections'),
      );
    });

    test('Quot.sound with a witness of the wrong relation is rejected', () {
      final r = runSource('''
$_pairPrelude
val bad: (x: Pair) -> (y: Pair) -> Eq Nat (sum x) (sum y) ->
    Eq (Quot(Pair, sameSum)) (mk x) (mk y) =
  (x: Pair) => (y: Pair) => (h: Eq Nat (sum x) (sum y)) =>
    Quot.sound (refl zero)
''');
      expect(r.code, 1);
      expect(r.stderr, contains('error: type mismatch'));
    });
  });
}
