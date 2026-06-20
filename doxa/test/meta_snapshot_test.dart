/// Tests for MetaContext snapshot/restore.
library;

import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

void main() {
  group('MetaContext snapshot/restore', () {
    test('snapshot on empty context', () {
      final mc = MetaContext();
      final snap = mc.snapshot();
      expect(snap.entriesLength, 0);
      expect(snap.solved, isEmpty);
    });

    test('snapshot captures unsolved metas', () {
      final mc = MetaContext();
      mc.freshTermMeta(const VType(LLevel(0)), const CNil());
      mc.freshTermMeta(const VType(LLevel(1)), const CNil());
      final snap = mc.snapshot();
      expect(snap.entriesLength, 2);
      expect(snap.solved, isEmpty);
    });

    test('snapshot captures solved metas', () {
      final mc = MetaContext();
      final id = mc.freshTermMeta(const VType(LLevel(0)), const CNil());
      mc.solve(id, const TType(LLevel(0)));
      final snap = mc.snapshot();
      expect(snap.entriesLength, 1);
      expect(snap.solved, {0: const TType(LLevel(0))});
    });

    test('restore truncates new metas added after snapshot', () {
      final mc = MetaContext();
      final id0 = mc.freshTermMeta(const VType(LLevel(0)), const CNil());
      mc.solve(id0, const TType(LLevel(0)));
      final snap = mc.snapshot();
      // Add more metas after snapshot.
      mc.freshTermMeta(const VType(LLevel(1)), const CNil());
      expect(mc.length, 2);
      mc.restore(snap);
      expect(mc.length, 1);
      expect(mc.isSolved(0), isTrue);
      expect(mc.solutionOf(0), const TType(LLevel(0)));
    });

    test('restore re-unsolves metas that were solved after snapshot', () {
      final mc = MetaContext();
      final id = mc.freshTermMeta(const VType(LLevel(0)), const CNil());
      final snap = mc.snapshot();
      // Solve after snapshot.
      mc.solve(id, const TType(LLevel(0)));
      expect(mc.isSolved(0), isTrue);
      mc.restore(snap);
      expect(mc.isSolved(0), isFalse);
    });

    test('restore re-solves metas that were unsolved in snapshot', () {
      final mc = MetaContext();
      final id = mc.freshTermMeta(const VType(LLevel(0)), const CNil());
      mc.solve(id, const TType(LLevel(0)));
      final snap = mc.snapshot();
      // Unsolve it (simulate failed tactic).
      mc.restore(MetaSnapshot(1, {}));
      expect(mc.isSolved(0), isFalse);
      // Now restore back to the solved state.
      mc.restore(snap);
      expect(mc.isSolved(0), isTrue);
      expect(mc.solutionOf(0), const TType(LLevel(0)));
    });

    test('snapshot/restore round-trip preserves mixed solved/unsolved', () {
      final mc = MetaContext();
      // Meta 0: unsolved
      mc.freshTermMeta(const VType(LLevel(0)), const CNil());
      // Meta 1: solved
      final id1 = mc.freshTermMeta(const VType(LLevel(0)), const CNil());
      mc.solve(id1, const TType(LLevel(0)));
      // Meta 2: unsolved
      mc.freshTermMeta(const VType(LLevel(1)), const CNil());

      final snap = mc.snapshot();
      expect(snap.entriesLength, 3);
      expect(snap.solved, {1: const TType(LLevel(0))});

      // Mutate: solve meta 0, unsolve meta 1, add meta 3.
      mc.solve(0, const TType(LLevel(0)));
      mc.restore(MetaSnapshot(3, {0: const TType(LLevel(0))}));
      // Add a new meta.
      mc.freshTermMeta(const VType(LLevel(2)), const CNil());
      expect(mc.length, 4);

      // Restore to original snapshot.
      mc.restore(snap);
      expect(mc.length, 3);
      expect(mc.isSolved(0), isFalse);
      expect(mc.isSolved(1), isTrue);
      expect(mc.solutionOf(1), const TType(LLevel(0)));
      expect(mc.isSolved(2), isFalse);
    });
  });
}
