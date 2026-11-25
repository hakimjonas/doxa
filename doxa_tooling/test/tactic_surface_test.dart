/// Surface tests for `cases`, `constructor`, `auto`, and `omega` in
/// `by` blocks and the REPL.
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
  group('tactic surface', () {
    test('parses and formats cases, constructor, auto, and omega', () {
      const source =
          'val f : Type = by { cases x; constructor; auto; auto 10; omega }';
      final formatted = formatSource(source);
      expect(isFormatted(formatted), isTrue);
      expect(formatted, contains('cases x'));
      expect(formatted, contains('constructor'));
      expect(formatted, contains('auto'));
      expect(formatted, contains('auto 10'));
      expect(formatted, contains('omega'));
      expect(formatSource(formatted), equals(formatted));

      final parsed = parseProgram(source);
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
      expect(allSteps.whereType<STacticCases>().single.name, 'x');
      expect(allSteps.whereType<STacticConstructor>().length, 1);
      expect(allSteps.whereType<STacticAuto>().map((s) => s.depth), [5, 10]);
      expect(allSteps.whereType<STacticOmega>().length, 1);
    });

    test(
      'a by block with cases and constructor checks through the CLI',
      () async {
        final directory = Directory.systemTemp.createTempSync('doxa-tac-cli-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final file = File('${directory.path}/tactics.doxa')
          ..writeAsStringSync('''
data B2 : Type {
  c1 : B2;
  c2 : B2;
}
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
data Wrap : Type {
  wrap : (n: Nat) -> Wrap;
}
val t : (x: B2) -> Eq B2 x x = by {
  intro x;
  cases x;
  refl;
  refl
}
val w : Wrap = by {
  constructor;
  exact zero
}
''');
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/doxa.dart',
          'check',
          file.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('OK:'));
      },
    );

    test('a leftover apply goal carets the apply expression', () async {
      final directory = Directory.systemTemp.createTempSync('doxa-tac-span-');
      addTearDown(() => directory.deleteSync(recursive: true));
      const source = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
fun two_nats(a: Nat, b: Nat): Nat = a
val bad : Nat = by {
  apply two_nats;
  exact zero
}
''';
      final file = File('${directory.path}/leftover.doxa')
        ..writeAsStringSync(source);
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/doxa.dart',
        'check',
        file.path,
      ]);
      expect(result.exitCode, 1);
      final stderrText = result.stderr as String;
      final lines = source.split('\n');
      final applyLine = lines.indexWhere((l) => l.contains('apply two_nats'));
      final applyColumn = lines[applyLine].indexOf('two_nats') + 1;
      final declLine = lines.indexWhere((l) => l.startsWith('val bad'));
      expect(
        stderrText,
        contains('${file.path}:${applyLine + 1}:$applyColumn'),
        reason: stderrText,
      );
      expect(
        stderrText,
        isNot(contains('${file.path}:${declLine + 1}:1')),
        reason: stderrText,
      );
    });

    test('a failed simp step restores the goal for the next step', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
      );
      (_, session) = session.processInput(
        ':goal theorem t : (a: Nat) -> (b: Nat) -> (c: Nat) -> '
        'Eq Nat a b -> Eq Nat b a -> Eq Nat a c',
      );
      for (final name in ['a', 'b', 'c', 'h1', 'h2']) {
        (_, session) = session.processInput(':step intro $name');
      }

      final (failed, afterFailure) = session.processInput(':step simp');
      expect(failed, isA<ReplMeta>());
      expect(
        (failed as ReplMeta).text,
        contains('simp: rewrite limit exceeded'),
      );

      final (goal, afterGoal) = afterFailure.processInput(':goal');
      expect(goal, isA<ReplMeta>());
      expect((goal as ReplMeta).text, contains('Eq Nat a c'));

      final (cases, _) = afterGoal.processInput(':step cases c');
      expect(cases, isA<ReplMeta>());
      expect((cases as ReplMeta).text, contains('Case analysis applied.'));
    });

    test('REPL :step cases walks both arms to :qed', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        'data B2 : Type { c1 : B2; c2 : B2; }',
      );
      (_, session) = session.processInput(
        ':goal theorem t : (x: B2) -> Eq B2 x x',
      );
      (_, session) = session.processInput(':step intro x');
      final (cases, afterCases) = session.processInput(':step cases x');
      expect((cases as ReplMeta).text, contains('Case analysis applied.'));

      final (first, afterFirst) = afterCases.processInput(':step refl');
      expect((first as ReplMeta).text, contains('Eq B2 c2 c2'));

      final (second, afterSecond) = afterFirst.processInput(':step refl');
      expect((second as ReplMeta).text, contains('Goal solved'));

      final (qed, nextSession) = afterSecond.processInput(':qed');
      expect(qed, isA<ReplMeta>());
      expect((qed as ReplMeta).text, contains('t'));
      expect(nextSession.proofState, isNull);
    });
  });
}
