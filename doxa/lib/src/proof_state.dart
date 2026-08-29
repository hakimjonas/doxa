/// Proof-state snapshots for `by { ... }` tactic blocks.
///
/// While a document is checked, each `by` block produces one immutable
/// snapshot recording the open goals at the moment elaboration of the
/// block finished: for every unsolved goal meta, the binder context in
/// scope (names paired with pretty-printed types) and the expected
/// goal type. The LSP server forwards these snapshots to editors as a
/// `doxa/proofState` notification; the REPL can reuse the same data.
///
/// Snapshots are plain data. Kernel values are quoted and rendered at
/// capture time so no live `Value` / `Ctx` escapes the elaborator.
/// Unsolved metas inside types render as `_` via the pretty printer,
/// matching the established report format.
library;

import 'ctx.dart';
import 'eval.dart' show quote;
import 'meta.dart';
import 'pretty.dart';
import 'surface.dart';

/// One context binder of a proof goal: its display name and the
/// pretty-printed type.
final class ProofGoalBinder {
  /// The binder name as written in the source (or as `intro` named it).
  final String name;

  /// The pretty-printed type of the binder.
  final String type;

  /// Creates a context binder entry.
  const ProofGoalBinder({required this.name, required this.type});

  @override
  String toString() => '$name : $type';
}

/// One open goal: the binder context in scope and the expected type of
/// the goal.
final class ProofGoal {
  /// The binders in scope at the goal, innermost first.
  final List<ProofGoalBinder> context;

  /// The pretty-printed expected type of the goal.
  final String target;

  /// Creates a goal entry.
  const ProofGoal({required this.context, required this.target});

  @override
  String toString() {
    final sb = StringBuffer();
    for (final binder in context) {
      sb.writeln('  $binder');
    }
    sb.write('  |- $target');
    return sb.toString();
  }
}

/// An immutable snapshot of one `by { ... }` block after elaboration.
final class ProofStateBlock {
  /// The source span of the whole `by { ... }` expression.
  final DoxaSpan span;

  /// True when the block's tactic proof closed every goal it created.
  final bool solved;

  /// The open goals, one per unsolved goal meta. Empty when [solved].
  final List<ProofGoal> goals;

  /// Creates a proof-state snapshot.
  const ProofStateBlock({
    required this.span,
    required this.solved,
    required this.goals,
  });

  @override
  String toString() => 'ProofStateBlock($span, solved: $solved, goals: $goals)';
}

/// Capture an immutable proof-state snapshot for one `by` block.
///
/// Scans the meta context over the block's goal metas: [rootMetaId]
/// (the goal the block was checked against) plus the range
/// `[rangeStart, metas.length)` allocated by the tactic attempt. Each
/// unsolved meta contributes one [ProofGoal]. [binderNames] is the
/// elaborator's local scope at block exit, innermost first, aligned
/// with the context chain the metas were created in.
ProofStateBlock captureProofStateBlock({
  required MetaContext metas,
  required DoxaSpan span,
  required int rootMetaId,
  required int rangeStart,
  required List<String> binderNames,
}) {
  final goals = <ProofGoal>[];
  final rootEntry = metas.lookup(rootMetaId);
  if (rootEntry is TermMetaUnsolved) {
    goals.add(_goalFromMeta(rootEntry, binderNames));
  }
  for (var id = rangeStart; id < metas.length; id++) {
    final entry = metas.lookup(id);
    if (entry is TermMetaUnsolved) {
      goals.add(_goalFromMeta(entry, binderNames));
    }
  }
  return ProofStateBlock(span: span, solved: goals.isEmpty, goals: goals);
}

ProofGoal _goalFromMeta(TermMetaUnsolved entry, List<String> binderNames) {
  final ctx = entry.localCtx;
  final level = ctx.level;
  // Names paired with the meta's context chain, innermost first. The
  // scope at block exit may be deeper than the meta's own context (the
  // meta was created before later binders); the meta's context is a
  // prefix of the chain, so its names are the outermost [level] names.
  final namesInScope =
      binderNames.length >= level
          ? binderNames.sublist(binderNames.length - level)
          : binderNames;
  final outerNames = namesInScope.reversed.toList();
  final context = <ProofGoalBinder>[];
  var c = ctx;
  var i = 0;
  while (c is CCons && i < namesInScope.length) {
    final typeStr = prettyTerm(
      quote(c.level, c.type),
      outerDepth: c.level,
      outerNames: outerNames,
    );
    context.add(ProofGoalBinder(name: namesInScope[i], type: typeStr));
    c = c.rest;
    i++;
  }
  final target = prettyTerm(
    quote(level, entry.typeExpected),
    outerDepth: level,
    outerNames: outerNames,
  );
  return ProofGoal(context: context, target: target);
}
