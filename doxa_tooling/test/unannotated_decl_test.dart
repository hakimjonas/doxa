/// Unannotated declarations with inserted implicit arguments, through the
/// CLI and the REPL.
///
/// The kernel test `doxa/test/unannotated_val_test.dart` covers the inferred
/// types. This file covers the two user-facing paths: the CLI diagnostic for a
/// type the elaborator cannot determine, and the REPL, whose declaration path
/// used to abort the session.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:doxa_tooling/src/repl.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

/// A minimal standard library for the sources below.
const _prologue = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
typeclass Eqb[A: Type] { fun equals(x: A, y: A): Bool; }
fun equalsNat(x: Nat, y: Nat): Bool = match x {
  case zero => true_
  case succ _ => false_
}
impl Eqb[Nat] {
  fun equals(x: Nat, y: Nat): Bool = equalsNat x y;
}
fun const{A: Type}{B: Type}(x: A, y: B): A = x
''';

({int code, String out, String err}) _check(String source) {
  final out = _BufferedSink();
  final err = _BufferedSink();
  final code = checkSource(
    SourceFile(filename: 'unannotated.doxa', text: source),
    out: out,
    err: err,
  );
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  test('the reproducer checks instead of aborting', () {
    final r = _check('$_prologue\nval q = equals zero zero\n');
    expect(r.code, 0, reason: r.err);
    expect(r.out, startsWith('OK:'));
  });

  test('a declaration with an undetermined type reports a diagnostic', () {
    final r = _check('$_prologue\nval q = const zero\n');
    expect(r.code, 1);
    expect(
      r.err,
      contains('error: cannot infer the type of declaration "q"'),
      reason: r.err,
    );
    expect(r.err, contains('unannotated.doxa:13:9'), reason: r.err);
    expect(
      r.err,
      contains('The body leaves an implicit argument undetermined'),
      reason: r.err,
    );
    expect(r.err, contains('val q: T = ...'), reason: r.err);
  });

  test('the annotated form is unchanged', () {
    final r = _check('$_prologue\nval q: Bool = equals zero zero\n');
    expect(r.code, 0, reason: r.err);
    expect(r.out, startsWith('OK:'));
  });

  group('REPL', () {
    test('an unannotated method application joins the session', () {
      var session = ReplSession();
      for (final decl in [
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
        'data Bool : Type { true_ : Bool; false_ : Bool; }',
        'fun equalsNat(x: Nat, y: Nat): Bool = match x {'
            ' case zero => true_ case succ _ => false_ }',
        'typeclass Eqb[A: Type] { fun equals(x: A, y: A): Bool; }',
        'impl Eqb[Nat] { fun equals(x: Nat, y: Nat): Bool = equalsNat x y; }',
      ]) {
        final (result, next) = session.processInput(decl);
        expect(result, isA<ReplDeclResult>(), reason: '$result');
        session = next;
      }

      final (declResult, after) = session.processInput(
        'val q = equals zero zero',
      );
      expect(declResult, isA<ReplDeclResult>(), reason: '$declResult');
      expect((declResult as ReplDeclResult).type, 'Bool');

      final (typeResult, _) = after.processInput(':type q');
      expect(typeResult, isA<ReplMeta>(), reason: '$typeResult');
      expect((typeResult as ReplMeta).text, 'Bool');
    });

    test('an undetermined type reports instead of aborting the session', () {
      var session = ReplSession();
      for (final decl in [
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
        'fun const{A: Type}{B: Type}(x: A, y: B): A = x',
      ]) {
        final (result, next) = session.processInput(decl);
        expect(result, isA<ReplDeclResult>(), reason: '$result');
        session = next;
      }

      final (result, after) = session.processInput('val q = const zero');
      expect(result, isA<ReplError>(), reason: '$result');
      expect(
        (result as ReplError).message,
        contains('cannot infer the type of declaration "q"'),
      );

      final (nextResult, _) = after.processInput('val r: Nat = zero');
      expect(nextResult, isA<ReplDeclResult>(), reason: '$nextResult');
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
