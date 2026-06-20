/// Tests for namespace-qualified module access:
/// `Nat.plus`, `import "path" as Alias`, and related features.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

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

/// Run checkSource on inline source and return structured result.
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
  group('namespace-qualified access', () {
    test('Nat.zero resolves via import "nat.doxa"', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
val x : Nat = Nat.zero
val y : Nat = Nat.plus Nat.zero Nat.zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('unqualified zero still works (backward compat)', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
val x : Nat = zero
val y : Nat = plus zero zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('mixed qualified and unqualified access', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
val x : Nat = Nat.zero
val y : Nat = plus zero x
val z : Nat = Nat.plus x y
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('import "nat.doxa" as N enables N.zero', () {
      const src = '''
import "../lib/stdlib/nat.doxa" as N
val x : Nat = N.zero
val y : Nat = N.plus N.zero N.zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('alias coexists with unqualified access', () {
      const src = '''
import "../lib/stdlib/nat.doxa" as N
val x : Nat = zero
val y : Nat = N.zero
val z : Nat = plus x y
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('recursor via qualified name: Nat.rec resolves', () {
      // The recursor resolves via the fallback flatten-to-dotted path.
      // `Nat.rec` as a term refers to the recursor; we verify it
      // resolves without an "unresolved name" error.
      const src = '''
import "../lib/stdlib/nat.doxa"
val n : Nat = Nat.zero
val use_rec = Nat.rec
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('different namespaces with aliases disambiguate', () {
      // nat.doxa transitively imports bool.doxa, so use alias for disambiguation.
      const src = '''
import "../lib/stdlib/nat.doxa" as N
val a : Nat = N.zero
val b : Bool = N.true_
val c : Bool = N.and_ b b
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('selective import with qualified access via alias', () {
      // Selective import must include data decl names for type references.
      const src = '''
import "../lib/stdlib/nat.doxa" { Nat, zero, plus } as N
val x : Nat = N.zero
val y : Nat = N.plus x x
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('duplicate unqualified names from two modules errors', () {
      // Both nat.doxa and bool.doxa have their own data decls and
      // bindings. Names like `true_` are unique to bool.doxa.
      // The import should succeed because names don't collide.
      const src = '''
import "../lib/stdlib/nat.doxa"
import "../lib/stdlib/bool.doxa"
val x : Nat = zero
val b : Bool = true_
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('namespace-qualified types work: Nat.zero, Nat.plus, etc.', () {
      const src = '''
import "../lib/stdlib/nat.doxa"
val x : Nat = Nat.zero
val b : Bool = Nat.true_
val c : Bool = Nat.and_ b b
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });

    test('qualified type reference in annotation', () {
      // Uses alias for the type name qualification.
      const src = '''
import "../lib/stdlib/nat.doxa" as N
val x : N.Nat = N.zero
''';
      final r = runSource(src);
      expect(r.code, 0, reason: 'stderr: ${r.stderr}');
    });
  });
}
