/// REPL proof-mode tests.
library;

import 'package:doxa/src/prelude.dart' show loadPrelude;
import 'package:doxa_tooling/src/repl.dart';
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
  group('proof mode basics', () {
    test('step without goal gives error', () {
      final session = _seededSession();
      final (result, _) = session.processInput(':step intro x');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('No proof in progress'));
    });

    test('undo without proof gives error', () {
      final session = _seededSession();
      final (result, _) = session.processInput(':undo');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('No proof in progress'));
    });

    test('qed without proof gives error', () {
      final session = _seededSession();
      final (result, _) = session.processInput(':qed');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('No proof in progress'));
    });

    test('print without proof gives error', () {
      final session = _seededSession();
      final (result, _) = session.processInput(':print');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('No proof in progress'));
    });

    test('abort without proof gives error', () {
      final session = _seededSession();
      final (result, _) = session.processInput(':abort');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('No proof in progress'));
    });

    test('declaration during proof is rejected', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      expect(session.proofState, isNotNull);

      final (result, _) = session.processInput('val x : Type = Type');
      expect(result, isA<ReplError>());
      expect((result as ReplError).message, contains('during a proof'));
    });

    test('qed incomplete gives error', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      final (result, _) = session.processInput(':qed');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('Proof incomplete'));
    });
  });

  group('identity proof', () {
    test('intro A; intro x; exact x; qed', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      expect(session.proofState, isNotNull);

      (_, session) = session.processInput(':step intro A');
      expect(session.proofState, isNotNull);

      (_, session) = session.processInput(':step intro x');
      expect(session.proofState, isNotNull);

      (_, session) = session.processInput(':step exact x');
      expect(session.proofState, isNotNull);

      final (result, nextSession) = session.processInput(':qed');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('id'));
      expect(nextSession.proofState, isNull);

      // :browse should show id
      final (browseResult, _) = nextSession.processInput(':browse');
      expect(browseResult, isA<ReplMeta>());
      expect((browseResult as ReplMeta).text, contains('id'));
    });
  });

  group('undo', () {
    test('undo reverts intro', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      expect(session.proofState, isNotNull);

      // Step intro A.
      (_, session) = session.processInput(':step intro A');
      expect(session.proofState, isNotNull);

      // Step intro x.
      (_, session) = session.processInput(':step intro x');

      // Undo should revert to after-intro-A state.
      final (undoResult, session2) = session.processInput(':undo');
      expect(undoResult, isA<ReplMeta>());
      expect((undoResult as ReplMeta).text, contains('Undone'));

      // Complete the proof from the restored state.
      var s2 = session2;
      (_, s2) = s2.processInput(':step intro y');
      (_, s2) = s2.processInput(':step exact y');
      final (qedResult, _) = s2.processInput(':qed');
      expect(qedResult, isA<ReplMeta>());
      expect((qedResult as ReplMeta).text, contains('id'));
    });

    test('undo empty stack errors', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      final (result, _) = session.processInput(':undo');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('Nothing to undo'));
    });
  });

  group('print mid-proof', () {
    test('print shows partial term with metas', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      (_, session) = session.processInput(':step intro A');
      final (result, _) = session.processInput(':print');
      expect(result, isA<ReplMeta>());
      final text = (result as ReplMeta).text;
      // Should contain lambda with A and a meta.
      expect(text, contains('A'));
    });
  });

  group('abort', () {
    test('abort clears proof state', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      expect(session.proofState, isNotNull);

      (_, session) = session.processInput(':step intro A');
      final (result, nextSession) = session.processInput(':abort');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('aborted'));
      expect(nextSession.proofState, isNull);

      // :qed should now error
      final (qedResult, _) = nextSession.processInput(':qed');
      expect(qedResult, isA<ReplMeta>());
      expect((qedResult as ReplMeta).text, contains('No proof in progress'));
    });
  });

  group('read-only commands during proof', () {
    test(':browse works during proof', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      final (result, _) = session.processInput(':browse');
      expect(result, isA<ReplMeta>());
    });
  });

  group('double goal', () {
    test(':goal while proving is rejected', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        ':goal theorem id : (A: Type) -> A -> A',
      );
      final (result, _) = session.processInput(':goal theorem other : Type');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, contains('Already in proof mode'));
    });
  });

  group('induction', () {
    test('names the argument and hypothesis and advances goal by goal', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
      );
      (_, session) = session.processInput(
        'fun plus(m: Nat, n: Nat): Nat = match m {'
        ' case zero => n case succ k => succ (plus k n) }',
      );
      (_, session) = session.processInput(
        ':goal theorem plus_zero : (n: Nat) -> Eq Nat (plus n zero) n',
      );
      (_, session) = session.processInput(':step intro n');

      final (inductionResult, afterInduction) = session.processInput(
        ':step induction n',
      );
      session = afterInduction;
      expect((inductionResult as ReplMeta).text, contains('Eq Nat zero zero'));

      // `refl` closes the zero arm; the session then shows the succ arm
      // with its argument and induction hypothesis named and typed.
      final (zeroResult, afterZero) = session.processInput(':step refl');
      session = afterZero;
      final zeroText = (zeroResult as ReplMeta).text;
      expect(zeroText, contains('Eq Nat (succ (plus a zero)) (succ a)'));
      expect(zeroText, contains('a : Nat'));
      expect(zeroText, contains('ih : Eq Nat (plus a zero) a'));

      // Undo restores the whole queue: the zero arm is current again and
      // the succ arm is still pending.
      final (undoResult, afterUndo) = session.processInput(':undo');
      session = afterUndo;
      expect((undoResult as ReplMeta).text, contains('Eq Nat zero zero'));
      final (redoZero, afterRedoZero) = session.processInput(':step refl');
      session = afterRedoZero;
      expect(
        (redoZero as ReplMeta).text,
        contains('Eq Nat (succ (plus a zero)) (succ a)'),
      );

      final (rewriteResult, afterRewrite) = session.processInput(
        ':step rewrite ih',
      );
      session = afterRewrite;
      expect(
        (rewriteResult as ReplMeta).text,
        contains('Eq Nat (succ a) (succ a)'),
      );

      final (reflResult, afterRefl) = session.processInput(':step refl');
      session = afterRefl;
      expect((reflResult as ReplMeta).text, contains('Goal solved'));

      final (qedResult, _) = session.processInput(':qed');
      expect((qedResult as ReplMeta).text, contains('plus_zero'));
    });
  });

  group('indexed induction', () {
    test('the refined arm goal names the constructor argument', () {
      var session = _seededSession();
      (_, session) = session.processInput(
        'data PairEqual[A: Type] : A -> A -> Prop {'
        ' mkEq : (z: A) -> PairEqual A z z; }',
      );
      (_, session) = session.processInput(
        ':goal theorem sym : (A: Type) -> (x: A) -> (y: A) ->'
        ' PairEqual A x y -> PairEqual A y x',
      );
      for (final step in [
        ':step intro A',
        ':step intro x',
        ':step intro y',
        ':step intro h',
      ]) {
        (_, session) = session.processInput(step);
      }

      final (result, afterInduction) = session.processInput(
        ':step induction h',
      );
      session = afterInduction;
      final text = (result as ReplMeta).text;
      // The index refinement turns `PairEqual A y x` into
      // `PairEqual A z z` for the mkEq arm.
      expect(text, contains('PairEqual A z z'));
      expect(text, contains('z : A'));

      final (abort, _) = session.processInput(':abort');
      expect((abort as ReplMeta).text, contains('Proof aborted'));
    });
  });
}
