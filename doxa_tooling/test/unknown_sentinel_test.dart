/// Stage 0 reproducer for the `TType(0)` / `VType(0)` sentinel.
///
/// The expression shim (`_elabExpr`) elaborates tactic expressions with
/// no binder types. Before the unknown marker, it pushed `VType(0)` as
/// every local binder's type. The typed `Type 0` then stood in for the
/// real type during implicit-argument insertion and conversion: an
/// implicit type metavariable got solved to `Type 0` (a guessed type),
/// and the application was rejected deep inside the tactic with no
/// mention of the actual problem.
///
/// With the explicit marker the same program is still rejected, because
/// the shim genuinely does not know the local binder's type, but the
/// diagnostic now names the unknown instead of fabricating a type. The
/// direct (non-tactic) body has real binder types and still checks,
/// which is the control that isolates the shim.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

/// Run [checkSource] on [text] and return exit code, stdout, stderr.
({int code, String stdout, String stderr}) check(String text) {
  final source = SourceFile(filename: 'probe.doxa', text: text);
  final out = _BufferedSink();
  final err = _BufferedSink();
  final code = checkSource(source, out: out, err: err);
  return (code: code, stdout: out.toString(), stderr: err.toString());
}

void main() {
  group('Stage 0 reproducer: shim-local type reaches implicit insertion', () {
    test('tactic application of a local implicit-polymorphic binder', () {
      // `f` is a local binder; the shim knows only its name, so it
      // cannot insert the implicit argument `f`'s real type requires.
      // The term is still built as written and rejected by the
      // tactic's own check; `exact` reports that check as an opaque
      // tactic failure. The unknown marker does not change this
      // outcome, it only stops the fabricated `Type 0` from standing
      // in for the missing type.
      final r = check('''
val test : ({A: Type} -> A -> A) -> (B: Type) -> B -> B
  = (f: {A: Type} -> A -> A) => (B: Type) => (b: B) => by { exact f b }
''');
      expect(r.code, 1, reason: 'stderr:\n${r.stderr}');
      expect(r.stderr, contains('tactic failed'));
    });

    test('tactic application of a top-level implicit function to a local', () {
      // `id` has a real type; the argument `x` is a shim local. The
      // dummy Type-0 type used to be offered to the implicit
      // metavariable as a solution.
      final r = check('''
fun id{A: Type}(a: A): A = a
val test : (A: Type) -> A -> A
  = (A: Type) => (x: A) => by { exact id x }
''');
      expect(r.code, 1, reason: 'stderr:\n${r.stderr}');
      expect(r.stderr, contains('found Unknown'));
    });

    test('mutual-block member body with a tactic application', () {
      final r = check('''
fun id{A: Type}(a: A): A = a
fun test[A](x: A): A = by { exact id x }
and other[A](x: A): A = x
''');
      expect(r.code, 1, reason: 'stderr:\n${r.stderr}');
      expect(r.stderr, contains('found Unknown'));
    });

    test('control: the direct body elaborates with real binder types', () {
      final r = check('''
fun id{A: Type}(a: A): A = a
val test : (A: Type) -> A -> A
  = (A: Type) => (x: A) => id x
''');
      expect(r.code, 0, reason: 'stderr:\n${r.stderr}');
      expect(r.stdout, startsWith('OK:'));
    });

    test('explicit arguments in a tactic application still elaborate', () {
      // No implicit insertion is needed, so the unknown head type is
      // harmless: the term is built as written and the tactic's real
      // check accepts it.
      final r = check('''
val test : ({A: Type} -> A -> A) -> (B: Type) -> B -> B
  = (f: {A: Type} -> A -> A) => (B: Type) => (b: B) => by { exact f B b }
''');
      expect(r.code, 0, reason: 'stderr:\n${r.stderr}');
      expect(r.stdout, startsWith('OK:'));
    });
  });

  group('Pre-binding discrimination is by flag, not by term shape', () {
    test('type X = Type followed by a mutual block elaborates', () {
      // Under the old rule a binding was a pre-binding when its term
      // was `TType(0)` and its type a Pi. `type X = Type` has term
      // `TType(0)` but is not a pre-binding; the flag keeps them
      // apart.
      final r = check('''
type X = Type
fun f[A](x: A): A = x
and g[A](x: A): A = f[A] x
''');
      expect(r.code, 0, reason: 'stderr:\n${r.stderr}');
      expect(r.stdout, startsWith('OK:'));
    });

    test('the Type alias value folds inside a mutual-block body', () {
      // `X` is `Type`, so `X` as a *type* is `Type 0`, and a member
      // whose body is the data type `Bool` (also `Type 0`) must check
      // against it. This only works when the alias is not stubbed:
      // a stub would leave `X` as an opaque neutral and reject
      // `Bool` against it. It therefore pins the flag-based
      // discrimination: the alias's term is `TType(0)`, yet the flag
      // says it is not a pre-binding.
      final r = check('''
data Bool: Type {
  true_: Bool;
  false_: Bool;
}
type X = Type
fun pick(u: Bool): X = Bool
and pick2(u: Bool): X = pick u
''');
      expect(r.code, 0, reason: 'stderr:\n${r.stderr}');
      expect(r.stdout, startsWith('OK:'));
    });

    test('a mutual block with a dependent sibling reference elaborates', () {
      final r = check('''
fun apply[A](f: A -> A, x: A): A = f x
and twice[A](f: A -> A, x: A): A = apply[A] f (apply[A] f x)
''');
      expect(r.code, 0, reason: 'stderr:\n${r.stderr}');
      expect(r.stdout, startsWith('OK:'));
    });
  });
}

/// Minimal [IOSink] that accumulates into a [StringBuffer].
class _BufferedSink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  @override
  void write(Object? obj) => _buffer.write(obj);

  @override
  void writeln([Object? obj = '']) => _buffer.writeln(obj);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

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
