/// Surface tests for `simp`: parsing, formatting, the REPL step, and one
/// end-to-end CLI check.
library;

import 'dart:io';

import 'package:doxa/src/parse.dart' show parseProgram;
import 'package:doxa/src/prelude.dart' show loadPrelude;
import 'package:doxa/src/surface.dart';
import 'package:doxa_tooling/src/format.dart' show formatSource, isFormatted;
import 'package:doxa_tooling/src/repl.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

ReplSession _seededSession() {
  final prelude = loadPrelude();
  return ReplSession(
    bindings: prelude.bindings,
    dataDecls: prelude.dataDecls,
    namespaceBindings: prelude.namespaceBindings,
  );
}

void main() {
  group('simp surface', () {
    test('parses and formats simp and simp [a, b]', () {
      const bare = 'val f : Type = by { simp }';
      final bareFormatted = formatSource(bare);
      expect(isFormatted(bareFormatted), isTrue);
      expect(bareFormatted, contains('simp'));
      expect(formatSource(bareFormatted), equals(bareFormatted));

      const listed = 'val f : Type = by { simp [h, plus_zero] }';
      final listedFormatted = formatSource(listed);
      expect(isFormatted(listedFormatted), isTrue);
      expect(listedFormatted, contains('simp [h, plus_zero]'));
      expect(formatSource(listedFormatted), equals(listedFormatted));

      final parsed = parseProgram('$_bare\n$_listed');
      expect(parsed, isA<Success<ParseError, SProgram>>());
      final program = (parsed as Success<ParseError, SProgram>).value;
      final allSteps = <STacticStep>[];
      for (final decl in program.decls) {
        if (decl.kind case SValKind(:final body)) {
          if (body.kind case SByKind(:final steps)) {
            allSteps.addAll(steps.first);
          }
        }
      }
      expect(allSteps.whereType<STacticSimp>().length, 2);
      expect(allSteps.whereType<STacticSimp>().first.lemmas, isEmpty);
      expect(allSteps.whereType<STacticSimp>().last.lemmas.length, 2);
    });

    test(
      'REPL :step simp rewrites a context hypothesis and shows the goal',
      () {
        var session = _seededSession();
        (_, session) = session.processInput(
          ':goal theorem t : (A: Type) -> (f: A -> A) -> (g: A -> A) -> '
          '(x: A) -> (y: A) -> Eq A x y -> Eq A (f x) (g x)',
        );
        for (final name in ['A', 'f', 'g', 'x', 'y', 'h']) {
          (_, session) = session.processInput(':step intro $name');
        }
        final (result, _) = session.processInput(':step simp');
        expect(result, isA<ReplMeta>());
        final text = (result as ReplMeta).text;
        expect(text, contains('Simplified.'));
        expect(text, contains('f y'));
        expect(text, contains('g y'));
      },
    );

    test('REPL :step simp [h] accepts a lemma list', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem t : (A: Type) -> (f: A -> A) -> (g: A -> A) -> '
        '(x: A) -> (y: A) -> Eq A x y -> Eq A (f x) (g x)',
      );
      for (final name in ['A', 'f', 'g', 'x', 'y', 'h']) {
        (_, session) = session.processInput(':step intro $name');
      }
      final (result, _) = session.processInput(':step simp [h]');
      expect(result, isA<ReplMeta>());
      final text = (result as ReplMeta).text;
      expect(text, contains('Simplified.'));
      expect(text, contains('f y'));
      expect(text, contains('g y'));
    });

    test('doxa check closes plus n zero = n with simp [plus_zero]', () async {
      final proofs =
          File('../doxa_stdlib/lib/stdlib/proofs.doxa').absolute.path;
      final directory = Directory.systemTemp.createTempSync('doxa-simp-cli-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/simp.doxa')..writeAsStringSync('''
import "$proofs"

val t : (n: Nat) -> Eq Nat (plus n zero) n = by {
  intro n;
  simp [plus_zero]
}
''');
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/doxa.dart',
        'check',
        file.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('OK:'));
    });
  });
}

const _bare = 'val f : Type = by { simp }';
const _listed = 'val f : Type = by { simp [h, plus_zero] }';
