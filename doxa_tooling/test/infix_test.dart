/// The four infix operators through the tooling surfaces: the CLI check, the
/// REPL's `:type` and `:norm`, and the syntax-highlighting tokenizer.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:doxa_tooling/src/repl.dart';
import 'package:doxa_tooling/src/tokenize.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

void main() {
  test('a CLI program using all four operators type-checks', () {
    final fixture = File('test/fixtures/infix_operators.doxa');
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

  group('REPL', () {
    ReplSession newSession() {
      var session = ReplSession();
      for (final decl in [
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
        'data Bool : Type { true_ : Bool; false_ : Bool; }',
        'fun plus(m: Nat, n: Nat): Nat = match m {'
            ' case zero => n case succ m_ => succ (plus m_ n) }',
        'fun mult(m: Nat, n: Nat): Nat = match m {'
            ' case zero => zero case succ m_ => plus n (mult m_ n) }',
        'fun leq(m: Nat, n: Nat): Bool = match m {'
            ' case zero => true_'
            ' case succ m_ => match n {'
            ' case zero => false_ case succ n_ => leq m_ n_ } }',
        'fun eqbNat(x: Nat, y: Nat): Bool = match x {'
            ' case zero => match y {'
            ' case zero => true_ case succ _ => false_ }'
            ' case succ n => match y {'
            ' case zero => false_ case succ m => eqbNat n m } }',
        'typeclass Eqb[A: Type] { fun eqb(x: A, y: A): Bool; }',
        'impl Eqb[Nat] { fun eqb(x: Nat, y: Nat): Bool = eqbNat x y; }',
      ]) {
        final (result, next) = session.processInput(decl);
        expect(result, isA<ReplDeclResult>(), reason: '$result');
        session = next;
      }
      return session;
    }

    String meta(ReplSession session, String command) {
      final (result, _) = session.processInput(command);
      expect(result, isA<ReplMeta>(), reason: '$result');
      return (result as ReplMeta).text;
    }

    test(':type accepts the arithmetic operators', () {
      final session = newSession();
      expect(meta(session, ':type zero + succ zero'), 'Nat');
      expect(meta(session, ':type zero * succ zero'), 'Nat');
      expect(meta(session, ':type zero + zero * zero'), 'Nat');
    });

    test(':type accepts the comparisons', () {
      final session = newSession();
      expect(meta(session, ':type zero <= succ zero'), 'Bool');
      expect(meta(session, ':type zero == succ zero'), 'Bool');
    });

    test(':norm reduces an addition', () {
      final session = newSession();
      expect(meta(session, ':norm zero + succ zero'), 'succ zero');
      expect(meta(session, ':norm zero * succ zero'), 'zero');
    });

    test(':norm reduces a comparison', () {
      final session = newSession();
      expect(meta(session, ':norm zero <= succ zero'), 'true_');
      expect(meta(session, ':norm succ zero == zero'), 'false_');
    });
  });

  group('tokenizer', () {
    test('classifies the four operators as operators', () {
      final tokens =
          tokenizeDoxaSpans(
            'val p = a <= b == c + d * e',
          ).where((s) => s.token is Operator).map((s) => s.token.text).toList();
      expect(tokens, ['<=', '==', '+', '*']);
    });

    test('does not split -> or => into a comparison', () {
      final tokens =
          tokenizeDoxaSpans(
            'val f = (x: Nat) => x\nval t = Nat -> Nat',
          ).where((s) => s.token is Operator).map((s) => s.token.text).toList();
      expect(tokens, ['=>', '->']);
    });
  });
}

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
