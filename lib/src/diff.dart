/// Reconstruct the structural path from two outer values to the point
/// at which they diverge.
///
/// `conv` (see `eval.dart`) returns only the innermost diverging pair,
/// which is sufficient to decide equality but leaves the user without
/// context: seeing "Type 0 ≠ Type 1" doesn't tell them *where* in the
/// outer structure the error happened. This module fills that gap.
///
/// The walker takes two top-level values and walks them in parallel:
///
///   * If both are `VPi`, compare domains; if they match, descend into
///     the opened codomain.
///   * If both are `VLam`, descend into the opened body (domains are
///     ignored, matching `conv`'s discipline, SPEC §4.3).
///   * If both are `VNeutral` with equal heads and equal spine lengths,
///     descend into arg pairs left-to-right.
///   * Otherwise, this is the divergence point; return it.
///
/// The result is a [DiffPath], a list of [DiffStep]s describing how to
/// drill in, plus the two diverging sub-values.
///
/// This walker re-uses the evaluator's `apply` to open closures, so its
/// host-stack usage is bounded by value nesting depth (source-bounded),
/// not β-reduction depth (which `apply` handles internally).
library;

import 'eval.dart';
import 'value.dart';

/// One step in a diff path.
sealed class DiffStep {
  /// Base constructor.
  const DiffStep();

  /// A human-readable description of this step.
  String describe();
}

/// Descended into the domain of a Pi.
final class DiffDomain extends DiffStep {
  /// Creates a "into-domain" step.
  const DiffDomain();
  @override
  String describe() => 'domain';
}

/// Descended into the codomain of a Pi (opening the binder).
final class DiffCodomain extends DiffStep {
  /// Creates a "into-codomain" step.
  const DiffCodomain();
  @override
  String describe() => 'codomain';
}

/// Descended into the body of a lambda (opening the binder).
final class DiffLambdaBody extends DiffStep {
  /// Creates a "into-lambda-body" step.
  const DiffLambdaBody();
  @override
  String describe() => 'lambda body';
}

/// Descended into the [index]-th argument of a neutral spine (0-based,
/// outermost-first: the outer `f(a)(b)` has `a` at index 0, `b` at index 1).
final class DiffNeutralArg extends DiffStep {
  /// The 0-based argument position.
  final int index;

  /// Creates a "into-neutral-arg" step.
  const DiffNeutralArg(this.index);
  @override
  String describe() => 'argument ${index + 1}';
}

/// Descended into the [index]-th argument of an inductive type
/// reference (`Vec A n` has `A` at index 0, `n` at index 1).
final class DiffDataArg extends DiffStep {
  /// The 0-based argument position.
  final int index;

  /// Creates a "into-data-arg" step.
  const DiffDataArg(this.index);
  @override
  String describe() => 'data argument ${index + 1}';
}

/// Descended into the [index]-th argument of a constructor
/// (`cons x xs` has `x` at index 0, `xs` at index 1; preceded by
/// data-type parameters, so in `cons` for `List A` the first arg is
/// `A`, then `x`, then `xs`).
final class DiffConstrArg extends DiffStep {
  /// The 0-based argument position.
  final int index;

  /// Creates a "into-constructor-arg" step.
  const DiffConstrArg(this.index);
  @override
  String describe() => 'constructor argument ${index + 1}';
}

/// The reconstructed diff between two values.
final class DiffPath {
  /// The structural path from the outer pair to the diverging pair,
  /// outermost-first.
  final List<DiffStep> steps;

  /// The sub-value on the "got" side at the divergence point.
  final Value got;

  /// The sub-value on the "expected" side at the divergence point.
  final Value expected;

  /// The de-Bruijn level at the divergence point.
  ///
  /// This is how many binders the walker descended past before finding
  /// the mismatch. Callers that quote [got] / [expected] back to a
  /// [Term] must pass this level to `quote()` so the resulting term's
  /// bound references have valid indices.
  final int level;

  /// Name hints for the binders the walker descended through,
  /// outermost-first. When descending through a Pi or Lam, the walker
  /// records the binder's name hint (or null if none). Callers
  /// pretty-printing sub-values can use these to surface the user's
  /// original names (`A`, `x`) instead of placeholders (`?a`, `?b`).
  final List<String?> binderNames;

  /// Creates a diff path.
  const DiffPath({
    required this.steps,
    required this.got,
    required this.expected,
    required this.level,
    required this.binderNames,
  });

  /// True if the path is empty, the divergence is at the top level.
  bool get isTopLevel => steps.isEmpty;

  /// A human-readable description like `"codomain → argument 2"`.
  String describePath() {
    if (steps.isEmpty) return '(top level)';
    return steps.map((s) => s.describe()).join(' → ');
  }
}

/// Walk [got] and [expected] in parallel to find their divergence.
///
/// This is pure structural comparison; it does not re-run `conv`. The
/// walker is called AFTER `conv` has already reported a mismatch, so
/// we know a divergence exists somewhere; the walker finds the deepest
/// one that is still structurally sensible to describe.
DiffPath diffValues(Value got, Value expected) {
  final steps = <DiffStep>[];
  final binderNames = <String?>[];
  var a = got;
  var b = expected;
  // A "synthetic level" counter for opening closures. Each time we
  // open a VLam or VPi codomain, we increment. Because the caller
  // generally starts at some level (e.g., the ctx depth), we use 0
  // here, the walker doesn't need absolute levels, only fresh ones
  // that don't clash inside the comparison.
  var level = 0;

  DiffPath result(List<DiffStep> s, Value g, Value e) => DiffPath(
    steps: s,
    got: g,
    expected: e,
    level: level,
    binderNames: List.unmodifiable(binderNames),
  );

  while (true) {
    // VPi × VPi: compare domains; if match, descend into codomain.
    if (a is VPi && b is VPi) {
      if (!_structuralEq(a.domain, b.domain)) {
        steps.add(const DiffDomain());
        return result(steps, a.domain, b.domain);
      }
      steps.add(const DiffCodomain());
      // Prefer the expected side's name hint; fall back to got's.
      binderNames.add(b.name ?? a.name);
      final fresh = VNeutral(NVar(level));
      a = apply(VLam(a.domain, a.codomain), fresh);
      b = apply(VLam(b.domain, b.codomain), fresh);
      level += 1;
      continue;
    }

    // VLam × VLam: descend into opened body (domains are NOT compared,
    // matching conv semantics, SPEC §4.3).
    if (a is VLam && b is VLam) {
      steps.add(const DiffLambdaBody());
      binderNames.add(b.name ?? a.name);
      final fresh = VNeutral(NVar(level));
      a = apply(a, fresh);
      b = apply(b, fresh);
      level += 1;
      continue;
    }

    // VData × VData: same inductive name + pointwise arg comparison.
    if (a is VData && b is VData) {
      if (a.name != b.name || a.args.length != b.args.length) {
        return result(steps, a, b);
      }
      for (var i = 0; i < a.args.length; i++) {
        if (!_structuralEq(a.args[i], b.args[i])) {
          steps.add(DiffDataArg(i));
          return result(steps, a.args[i], b.args[i]);
        }
      }
      // All args structurally equal but conv said they differ: fall
      // through with the whole values (diff is deeper than we detect).
      return result(steps, a, b);
    }

    // VConstr × VConstr: same data+ctor name + pointwise arg comparison.
    if (a is VConstr && b is VConstr) {
      if (a.dataName != b.dataName ||
          a.ctorName != b.ctorName ||
          a.args.length != b.args.length) {
        return result(steps, a, b);
      }
      for (var i = 0; i < a.args.length; i++) {
        if (!_structuralEq(a.args[i], b.args[i])) {
          steps.add(DiffConstrArg(i));
          return result(steps, a.args[i], b.args[i]);
        }
      }
      return result(steps, a, b);
    }

    // VNeutral × VNeutral with matching heads and spine lengths.
    if (a is VNeutral && b is VNeutral) {
      final aSpine = _spineOf(a.neutral);
      final bSpine = _spineOf(b.neutral);
      if (aSpine.head == bSpine.head &&
          aSpine.args.length == bSpine.args.length) {
        // Find the first arg pair that diverges.
        for (var i = 0; i < aSpine.args.length; i++) {
          if (!_structuralEq(aSpine.args[i], bSpine.args[i])) {
            steps.add(DiffNeutralArg(i));
            return result(steps, aSpine.args[i], bSpine.args[i]);
          }
        }
        // All args structurally equal, but conv said they differ, so
        // the divergence must be somewhere we don't detect structurally
        // (e.g., one side has a closure that β-reduces differently).
        // Fall through to return the current pair.
        return result(steps, a, b);
      }
      // Heads or spine lengths differ: top-level mismatch at this point.
      return result(steps, a, b);
    }

    // Any other shape combination: this is the divergence.
    return result(steps, a, b);
  }
}

// ---------------------------------------------------------------------------
// Structural equality on Values (shallow, used by the walker to decide
// whether to descend).
// ---------------------------------------------------------------------------

/// Cheap structural equality. Returns true only when two values are
/// identical up to shape; used by the walker to decide whether to
/// descend past a sub-term.
///
/// This is NOT α/β/η equivalence, for that, use `conv`. Structural
/// equality is strictly stronger (i.e., structurally equal implies
/// conv-equal, but not vice versa). A `false` here just means "keep
/// walking / this is where they diverge"; a `true` means "these
/// sub-values are identical, no need to descend here."
bool _structuralEq(Value a, Value b) {
  if (identical(a, b)) return true;
  return switch ((a, b)) {
    (VType(level: final la), VType(level: final lb)) => la == lb,
    (VProp(), VProp()) => true,
    (
      VPi(domain: final da, codomain: final ca),
      VPi(domain: final db, codomain: final cb),
    ) =>
      _structuralEq(da, db) &&
          identical(ca, cb), // closures compared by reference only
    (
      VLam(domain: final da, closure: final ca),
      VLam(domain: final db, closure: final cb),
    ) =>
      _structuralEq(da, db) && identical(ca, cb),
    (VNeutral(neutral: final na), VNeutral(neutral: final nb)) => _neutralEq(
      na,
      nb,
    ),
    (
      VData(name: final na, args: final aa),
      VData(name: final nb, args: final ab),
    ) =>
      na == nb && _listEq(aa, ab),
    (
      VConstr(dataName: final dna, ctorName: final cna, args: final aa),
      VConstr(dataName: final dnb, ctorName: final cnb, args: final ab),
    ) =>
      dna == dnb && cna == cnb && _listEq(aa, ab),
    _ => false,
  };
}

bool _listEq(List<Value> a, List<Value> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_structuralEq(a[i], b[i])) return false;
  }
  return true;
}

bool _neutralEq(Neutral a, Neutral b) {
  if (identical(a, b)) return true;
  return switch ((a, b)) {
    (NVar(level: final la), NVar(level: final lb)) => la == lb,
    (NApp(fn: final fa, arg: final aa), NApp(fn: final fb, arg: final ab)) =>
      _neutralEq(fa, fb) && _structuralEq(aa, ab),
    _ => false,
  };
}

// ---------------------------------------------------------------------------
// Neutral spine flattening.
// ---------------------------------------------------------------------------

class _Spine {
  final NVar head;
  final List<Value> args;
  const _Spine(this.head, this.args);
}

/// Flatten a neutral into `(head-variable, [arg1, arg2, ...])` where
/// args are in leftmost-first order (the order the user would read
/// them in `f a b c`).
_Spine _spineOf(Neutral n) {
  final args = <Value>[];
  var cur = n;
  while (cur is NApp) {
    args.add(cur.arg);
    cur = cur.fn;
  }
  // cur is now NVar. Reverse args to get leftmost-first order.
  return _Spine(cur as NVar, args.reversed.toList());
}
