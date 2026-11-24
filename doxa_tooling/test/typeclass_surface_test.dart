/// Typeclass surface through the CLI: a class and an instance elaborate,
/// and unsupported forms report their named diagnostics.
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
    test('typeclass declaration is accepted', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
typeclass Default[A: Type] {
  fun default(): A;
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('impl declaration is accepted for a declared class', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
typeclass Default[A: Type] {
  fun default(): A;
}
impl Default[Nat] {
  fun default(): Nat = zero;
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a superclass is accepted', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
typeclass Default[A: Type] {
  fun default(): A;
}
typeclass WithDefault[A: Type]: Default[A] {
  fun withDefault(): A;
}
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a class law that uses an operation projection checks', () {
      // The fixture consumes the stdlib algebra module, so checking it
      // elaborates the module's law fields through the import.
      final fixture = File('test/fixtures/class_laws_algebra.doxa');
      final r = runSource(fixture.readAsStringSync(), filename: fixture.path);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('a ring checks the square and the qualified projections', () {
      // The fixture imports the ring, so the module's `square_one` refl and
      // the fixture's `square_two` refl are both checked, together with
      // `Ring.mul` and the inherited `Ring.add`.
      final fixture = File('test/fixtures/ring_int.doxa');
      final r = runSource(fixture.readAsStringSync(), filename: fixture.path);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
      expect(r.stdout, contains('OK'));
    });

    test('a block val dictionary supplies a class projection', () {
      // SPEC's local dictionary: an ordinary `val` binding of the
      // dictionary type, followed by a call that needs the dictionary.
      const src = '''
import "../doxa_stdlib/lib/stdlib/algebra.doxa"
fun g(x: Nat): Nat = {
  val d : AddMonoid Nat = _impl_AddMonoid_Nat;
  add x x
}
val r : Eq Nat (g (succ zero)) (succ (succ zero)) = refl (succ (succ zero))
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('an ambiguous bare method name reports the diagnostic', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/algebra.doxa"
val bad: Nat = mul (succ zero) (succ zero)
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('ambiguous class method'));
      expect(r.stderr, contains('Monoid.mul'));
      expect(r.stderr, contains('Ring.mul'));
    });

    test('an unknown class reports the named diagnostic', () {
      const src = '''
import "../doxa_stdlib/lib/stdlib/nat.doxa"
impl Default[Nat] {
  fun default(): Nat = zero;
}
''';
      final r = runSource(src);
      expect(r.code, 1);
      expect(r.stderr, contains('unknown typeclass'));
      expect(r.stderr, contains('"Default"'));
    });
  });
}
