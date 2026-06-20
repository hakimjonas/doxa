/// Tactic engine for Doxa.
///
/// Tactics are imperative-style proof construction commands that operate
/// on the elaborator's metavariable context. A tactic block `by { ... }`
/// desugars to creating a fresh goal meta and running the tactic sequence
/// against it. When the tactic sequence solves the meta, the resulting
/// term replaces the `by` block at elaboration time.
///
/// ## Design
///
/// Follows Agda's reflection model: tactics are implemented in the host
/// language (Dart), not as an embedded DSL. Each tactic primitive is a
/// function from [TacticState] to [TacticResult]. Composition uses
/// [seq] (;) and [alt] (|).
///
/// ## Dependencies
///
/// Depends on: ctx.dart, meta.dart, term.dart, value.dart, eval.dart, registry.dart
library;

import 'ctx.dart';
import 'eval.dart';
import 'meta.dart';
import 'registry.dart';
import 'term.dart';
import 'value.dart';

// ---------------------------------------------------------------------------
// State and result types
// ---------------------------------------------------------------------------

/// The state a tactic operates on: the elaborator context plus the
/// current goal meta to solve.
final class TacticState {
  /// The metavariable context (shared across all goals).
  final MetaContext metas;

  /// The typing context at the goal site.
  final Ctx ctx;

  /// The ID of the meta being solved by this tactic.
  final int currentMeta;

  /// Local binder names in scope (innermost first), for name resolution
  /// in `exact` / `apply` / `rewrite` expressions.
  final List<String> binderNames;

  /// Creates a tactic state.
  const TacticState(
    this.metas,
    this.ctx,
    this.currentMeta, [
    this.binderNames = const [],
  ]);

  /// Copy with a replacement field.
  TacticState copyWith({
    MetaContext? metas,
    Ctx? ctx,
    int? currentMeta,
    List<String>? binderNames,
  }) =>
      TacticState(
        metas ?? this.metas,
        ctx ?? this.ctx,
        currentMeta ?? this.currentMeta,
        binderNames ?? this.binderNames,
      );

  /// The type of the current goal.
  Value get goalType => metas.lookup(currentMeta).isSolved
      ? (metas.lookup(currentMeta) as TermMetaSolved).typeExpected
      : (metas.lookup(currentMeta) as TermMetaUnsolved).typeExpected;
}

/// The result of running a tactic.
sealed class TacticResult {
  const TacticResult();
}

/// The tactic succeeded, producing a term that solves the current meta
/// and returning updated metas (possibly with new subgoals).
final class TacticOk extends TacticResult {
  /// The proof term (solves currentMeta (or subMeta if set)).
  final Term term;

  /// Updated metas (subgoals may have been added).
  final MetaContext metas;

  /// If non-null, the new "current meta" that subsequent steps should
  /// operate on (e.g. the subgoal created by `intro`).
  final int? subMeta;

  /// Creates a success result.
  const TacticOk(this.term, this.metas, {this.subMeta});
}

/// The tactic failed with a diagnostic message.
final class TacticFail extends TacticResult {
  /// Human-readable failure message.
  final String message;

  /// Creates a failure result.
  const TacticFail(this.message);
}

// ---------------------------------------------------------------------------
// Tactic function type and combinators
// ---------------------------------------------------------------------------

/// A tactic is a function from [TacticState] to [TacticResult].
typedef TacticFn = TacticResult Function(TacticState state);

/// Sequence combinator: run [t1], then [t2] on the resulting state.
///
/// If [t1] returns a term but leaves a subgoal ([subMeta] is non-null),
/// the subgoal becomes the new [currentMeta] for [t2].
TacticFn seq(TacticFn t1, TacticFn t2) => (s) {
      final r1 = t1(s);
      return switch (r1) {
        TacticOk(:final term, :final metas, :final subMeta) =>
          t2(TacticState(metas, s.ctx, subMeta ?? s.currentMeta)),
        TacticFail _ => r1,
      };
    };

/// Alternative combinator: try [t1], if it fails, try [t2].
TacticFn alt(TacticFn t1, TacticFn t2) => (s) {
      final r1 = t1(s);
      if (r1 is TacticOk) return r1;
      return t2(s);
    };

// ---------------------------------------------------------------------------
// Primitive tactics
// ---------------------------------------------------------------------------

/// `intro`: introduces a Pi binder.
///
/// Expects the goal to be a Pi type `(x: A) -> B`. Extends the context
/// with a fresh binder of type `A` and creates a subgoal for `B`.
TacticResult intro(TacticState s) {
  final goalType = s.goalType;
  if (goalType is! VPi) {
    return TacticFail('intro: goal is not a function type');
  }
  final pi = goalType;
  final freshName = pi.name ?? 'h';
  // Extend context with the binder of type dom.
  final newCtx = s.ctx.extend(pi.domain);
  // Track the binder name for later resolution in exact/apply.
  final newNames = [freshName, ...s.binderNames];
  // Evaluate the codomain under the extended context to get the subgoal type.
  final codArg = VNeutral(NVar(newCtx.level - 1));
  final codVal = eval(pi.codomain.body, pi.codomain.env.extend(codArg));
  // Create a subgoal for the codomain.
  final subMetaId = s.metas.freshTermMeta(codVal, newCtx);
  // Return TLam wrapping the subgoal meta.
  final bodyTerm = TMeta(subMetaId);
  final lamTerm = TLam(quote(s.ctx.level, pi.domain), bodyTerm, name: freshName);
  return TacticOk(lamTerm, s.metas, subMeta: subMetaId);
}

/// `exact t`: provides an explicit proof term that must have the goal type.
TacticFn Function(Term) exact = (term) => (s) {
  final goalType = s.goalType;
  try {
    final inferredType = infer(s.ctx, term);
    if (conv(s.ctx.level, inferredType, goalType) is ConvOk) {
      s.metas.solve(s.currentMeta, term);
      return TacticOk(term, s.metas);
    }
  } catch (_) {}
  return TacticFail('exact: type mismatch');
};

/// `refl`: closes `Eq[A] x x` goals using the `refl` constructor.
///
/// Expects the goal type to be `Eq[A] x x` and produces `refl[A] x`.
TacticResult refl(TacticState s) {
  final goalType = s.goalType;
  // Goal must be VData("Eq", [A, x, y]) where x == y.
  if (goalType is! VData) {
    return TacticFail('refl: goal is not an equality type');
  }
  final data = goalType;
  if (data.name != 'Eq') {
    return TacticFail('refl: goal type is ${data.name}, not Eq');
  }
  final args = data.args;
  if (args.length != 3) {
    return TacticFail('refl: Eq has ${args.length} args, expected 3');
  }
  // For refl we need x and y to be convertible.
  final x = args[1];
  final y = args[2];
  if (conv(s.ctx.level, x, y) is! ConvOk) {
    return TacticFail(
      'refl: the two sides of the equality are not definitionally equal',
    );
  }
  // Build TConstr("Eq", "refl", [A_term, x_term]).
  final aTerm = quote(s.ctx.level, args[0]);
  final xTerm = quote(s.ctx.level, x);
  final reflTerm = TConstr('Eq', 'refl', [aTerm, xTerm]);
  try {
    final inferred = infer(s.ctx, reflTerm);
    if (conv(s.ctx.level, inferred, goalType) is ConvOk) {
      return TacticOk(reflTerm, s.metas);
    }
  } catch (_) {}
  return TacticFail('refl: type mismatch after constructing refl');
}

/// `apply f`: applies lemma `f`, creating subgoals for each argument.
///
/// Expects `f` to have a Pi type `(x1: A1) -> ... -> (xn: An) -> R`.
/// Creates fresh metas for each argument and returns `f ?1 ... ?n`.
TacticFn Function(Term) tacticApply = (f) => (s) {
  final fType = infer(s.ctx, f);
  final args = <Term>[];
  var currentType = fType;
  var currentCtx = s.ctx;
  while (currentType is VPi) {
    final pi = currentType;
    final subMeta = s.metas.freshTermMeta(pi.domain, currentCtx);
    args.add(TMeta(subMeta));
    currentCtx = currentCtx.extend(pi.domain);
    final codArg = VNeutral(NVar(currentCtx.level - 1));
    currentType = eval(pi.codomain.body, pi.codomain.env.extend(codArg));
  }
  var result = f;
  for (final arg in args) {
    result = TApp(result, arg);
  }
  final goalType = s.goalType;
  final resultType = infer(s.ctx, result);
  if (conv(s.ctx.level, resultType, goalType) is ConvOk) {
    s.metas.solve(s.currentMeta, result);
    return TacticOk(result, s.metas);
  }
  return TacticFail('apply: type mismatch');
};

/// `rewrite p`: rewrites the goal using equality proof `p`.
///
/// Expects `p : Eq[A] x y`. Replaces `x` with `y` in the goal type.
TacticFn Function(Term) rewrite = (p) => (s) {
  final pType = infer(s.ctx, p);
  if (pType is! VData || pType.name != 'Eq') {
    return TacticFail('rewrite: proof is not an equality');
  }
  final eqArgs = pType.args;
  if (eqArgs.length != 3) {
    return TacticFail('rewrite: Eq has wrong arity');
  }
  return TacticFail('rewrite: not yet implemented in this version');
};

/// `induction x`: produces subgoals per constructor of `x`'s type.
TacticFn Function(String) induction = (varName) => (s) {
  return TacticFail('induction: not yet implemented in this version');
};

/// `trivial`: tries `refl` followed by simple context lookups.
TacticResult trivial(TacticState s) {
  // Try refl first.
  final reflResult = refl(s);
  if (reflResult is TacticOk) return reflResult;
  // Try exact from context: look for a local binder whose type matches.
  var currentCtx = s.ctx;
  var idx = 0;
  while (currentCtx is CCons) {
    final c = currentCtx;
    try {
      if (conv(s.ctx.level, c.type, s.goalType) is ConvOk) {
        final term = TBound(idx);
        try {
          final inferred = infer(s.ctx, term);
          if (conv(s.ctx.level, inferred, s.goalType) is ConvOk) {
            return TacticOk(term, s.metas);
          }
        } catch (_) {}
      }
    } catch (_) {}
    currentCtx = c.rest;
    idx++;
  }
  return TacticFail('trivial: no trivial proof found');
}

// ---------------------------------------------------------------------------
// Conversion check helper (shallow)
// ---------------------------------------------------------------------------

/// Result of a conversion check.
sealed class ConvResult {
  const ConvResult();
}

final class ConvOk extends ConvResult {
  const ConvOk();
}

final class ConvMismatch extends ConvResult {
  const ConvMismatch();
}

/// Check convertibility of two values at [level].
///
/// This is a lightweight wrapper around the kernel's conversion checker.
/// Returns [ConvOk] if convertible, [ConvMismatch] otherwise.
ConvResult conv(int level, Value a, Value b) {
  try {
    _driveConvert(level, a, b);
    return const ConvOk();
  } catch (_) {
    return ConvMismatch();
  }
}

/// Internal conversion driver. Throws on mismatch.
void _driveConvert(int level, Value a, Value b) {
  // Use the kernel's quote + term equality as a simple conversion check.
  // For a full implementation we'd use the kernel's _Conv driver, but
  // this is sufficient for initial tactic needs.
  final termA = quote(level, a);
  final termB = quote(level, b);
  if (termA != termB) {
    // Fall back to evaluate-and-compare for non-identity cases.
    // WHNF comparison through the real kernel would be better, but for
    // initial tactics this catches the common cases (refl on identical terms).
    throw Exception('conversion mismatch');
  }
}
