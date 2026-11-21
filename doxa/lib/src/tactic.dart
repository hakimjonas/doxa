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
import 'env.dart';
import 'eval.dart';
import 'eval.dart' as kernel_eval;
import 'meta.dart';
import 'registry.dart';
import 'term.dart';
import 'value.dart';

// ---------------------------------------------------------------------------
// State and result types
// ---------------------------------------------------------------------------

/// A goal created by a tactic, with everything needed to resume work on
/// it: the meta to solve, the binder context, and the innermost-first
/// binder names that resolve those binders in source expressions.
final class TacticGoal {
  /// The metavariable to solve.
  final int metaId;

  /// The typing context at the goal.
  final Ctx ctx;

  /// Binder names in scope, innermost first, positionally aligned with
  /// the [ctx] chain.
  final List<String> binderNames;

  /// The type to display and check this goal against when it differs
  /// from the meta's declared type. `apply`'s explicit arguments use
  /// this: the meta is closed over the context, the goal is the open
  /// argument type.
  final Value? displayType;

  /// When non-null, this goal's meta is declared with the type
  /// `Π context. displayType`; a solution open in this context is
  /// lifted to a λ-chain before it is committed.
  final Ctx? closedOverCtx;

  /// Creates a goal.
  const TacticGoal(
    this.metaId,
    this.ctx,
    this.binderNames, {
    this.displayType,
    this.closedOverCtx,
  });
}

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

  /// Goals created by earlier steps and not yet solved, in the order
  /// they were created. The current goal is [currentMeta]; these follow
  /// it.
  final List<TacticGoal> pending;

  /// The type to display and check the current goal against when it
  /// differs from the meta's declared type (`apply` explicit arguments).
  final Value? goalTypeOverride;

  /// When non-null, the current goal's meta is declared with the type
  /// `Π ctx. goalType`; a solution open in this context is lifted before
  /// it is committed.
  final Ctx? closedGoalOverCtx;

  /// Creates a tactic state.
  const TacticState(
    this.metas,
    this.ctx,
    this.currentMeta, [
    this.binderNames = const [],
    this.pending = const [],
    this.goalTypeOverride,
    this.closedGoalOverCtx,
  ]);

  /// Copy with a replacement field.
  TacticState copyWith({
    MetaContext? metas,
    Ctx? ctx,
    int? currentMeta,
    List<String>? binderNames,
    List<TacticGoal>? pending,
    Value? goalTypeOverride,
    Ctx? closedGoalOverCtx,
  }) => TacticState(
    metas ?? this.metas,
    ctx ?? this.ctx,
    currentMeta ?? this.currentMeta,
    binderNames ?? this.binderNames,
    pending ?? this.pending,
    goalTypeOverride ?? this.goalTypeOverride,
    closedGoalOverCtx ?? this.closedGoalOverCtx,
  );

  /// The type of the current goal.
  Value get goalType =>
      goalTypeOverride ??
      (metas.lookup(currentMeta).isSolved
          ? (metas.lookup(currentMeta) as TermMetaSolved).typeExpected
          : (metas.lookup(currentMeta) as TermMetaUnsolved).typeExpected);
}

/// Solve [s]'s current goal with [term].
///
/// When the goal's meta is closed over the local context (`apply`'s
/// explicit arguments), the open [term] is lifted to the closed λ-chain
/// the meta was declared with. The kernel treats every solved meta's
/// solution as closed; committing an open term directly makes a later
/// force of that meta evaluate its free indices under an empty env.
void solveCurrentGoal(TacticState s, Term term) {
  final ctx = s.closedGoalOverCtx;
  s.metas.solve(
    s.currentMeta,
    ctx == null ? term : closeTermOverCtx(term, ctx),
  );
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

  /// Every goal this tactic created, in the order they should be worked
  /// on. A single-goal tactic may leave this empty and set [subMeta]
  /// instead; multi-goal tactics (`induction`) fill it so the caller can
  /// queue every arm.
  final List<TacticGoal> subGoals;

  /// Creates a success result.
  const TacticOk(
    this.term,
    this.metas, {
    this.subMeta,
    this.subGoals = const [],
  });
}

/// The state after [result] solved [prev]'s current goal.
///
/// The next goal is the first unsolved one among the tactic's
/// [TacticOk.subGoals] and [prev]'s [TacticState.pending] queue, in that
/// order. Returns null when every goal is solved.
///
/// Callers solve [prev]'s current meta with [TacticOk.term] first (when
/// [TacticOk.subMeta] is non-null); this function only selects.
TacticState? nextGoalAfter(TacticState prev, TacticOk result) {
  final created =
      result.subGoals.isNotEmpty
          ? result.subGoals
          : (result.subMeta != null && !result.metas.isSolved(result.subMeta!)
              ? [TacticGoal(result.subMeta!, prev.ctx, prev.binderNames)]
              : const <TacticGoal>[]);
  final queue = <TacticGoal>[...created, ...prev.pending];
  final index = queue.indexWhere((g) => !result.metas.isSolved(g.metaId));
  if (index < 0) return null;
  final picked = queue[index];
  final rest = <TacticGoal>[
    for (var i = index + 1; i < queue.length; i++)
      if (!result.metas.isSolved(queue[i].metaId)) queue[i],
  ];
  return TacticState(
    result.metas,
    picked.ctx,
    picked.metaId,
    picked.binderNames,
    rest,
    picked.displayType,
    picked.closedOverCtx,
  );
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

/// Sequence combinator: run [t1], then [t2] on the next goal.
///
/// `t1` solves the current goal; if it created subgoals, `t2` runs on
/// the first one, then on the next queued goal after that. When `t1`
/// leaves no goal, `t2` is a no-op and the result of `t1` is returned.
TacticFn seq(TacticFn t1, TacticFn t2) => (s) {
  final r1 = t1(s);
  return switch (r1) {
    TacticOk(:final term, :final subMeta) => () {
      if (subMeta != null) solveCurrentGoal(s, term);
      final next = nextGoalAfter(s, r1);
      if (next == null) return r1;
      return t2(next);
    }(),
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
TacticResult intro(TacticState s, {String? name}) {
  final goalType = s.goalType;
  if (goalType is! VPi) {
    return const TacticFail('intro: goal is not a function type');
  }
  final pi = goalType;
  final freshName = name ?? pi.name ?? 'h';
  // Extend context with the binder of type dom.
  final newCtx = s.ctx.extend(pi.domain);
  // Track the binder name for later resolution in exact/apply.
  // ignore: unused_local_variable
  final newNames = [freshName, ...s.binderNames];
  // Evaluate the codomain under the extended context to get the subgoal type.
  final codArg = VNeutral(NVar(newCtx.level - 1));
  final codVal = eval(pi.codomain.body, pi.codomain.env.extend(codArg));
  // Create a subgoal for the codomain.
  final subMetaId = s.metas.freshTermMeta(codVal, newCtx);
  // Return TLam wrapping the subgoal meta.
  final bodyTerm = TMeta(subMetaId);
  final lamTerm = TLam(
    quote(s.ctx.level, pi.domain),
    bodyTerm,
    name: freshName,
  );
  return TacticOk(
    lamTerm,
    s.metas,
    subMeta: subMetaId,
    subGoals: [
      TacticGoal(subMetaId, newCtx, [freshName, ...s.binderNames]),
    ],
  );
}

/// `revert x`: moves the local binder `x` back into the goal.
///
/// The inverse of `intro`: the goal becomes `(x: T) -> G`, where `T` is
/// the binder's type in the outer scope and `G` is the goal with `x` as
/// the bound variable. The current goal meta is solved with the new
/// goal's meta applied to the binder, so the proof eventually reduces to
/// the new goal's proof applied to the same value.
///
/// Only the innermost binder is supported. A binder with dependent
/// binders inside it cannot be removed without also rewinding them, and
/// silently dropping them would leave their types out of scope.
TacticFn Function(String) revert =
    (varName) => (s) {
      int? binderIdx;
      for (var i = 0; i < s.binderNames.length; i++) {
        if (s.binderNames[i] == varName) {
          binderIdx = i;
          break;
        }
      }
      if (binderIdx == null) {
        return TacticFail('revert: variable "$varName" not in scope');
      }
      return _revertAt(binderIdx, varName)(s);
    };

TacticFn Function(int, String) _revertAt =
    (binderIdx, varName) => (s) {
      if (s.closedGoalOverCtx != null) {
        return const TacticFail('revert: cannot revert an apply argument goal');
      }
      if (binderIdx != 0) {
        return TacticFail(
          'revert: "$varName" is not the innermost binder; revert the '
          'binders introduced after it first',
        );
      }
      final ctx = s.ctx;
      if (ctx is! CCons) {
        return TacticFail('revert: there is no binder "$varName" to revert');
      }
      final outerCtx = ctx.rest;
      final level = s.ctx.level;
      // `ctx.type` is the binder's type in the outer scope (it does not
      // mention the binder). The goal is a value at the full level; under
      // the new Pi binder the same indices denote the same binders, so it
      // quotes unchanged at `level`.
      final goal = s.goalType;
      final openGoal = eval(
        TPi(quote(level - 1, ctx.type), quote(level, goal), name: varName),
        outerCtx.env,
      );
      // The new goal lives in the outer context, but its proof solves the
      // old goal under the reverted binder. A bare meta would store a
      // solution relative to the outer depth and be inlined under the
      // extra binder without a shift. Close the meta over the outer
      // context (the `apply` argument shape), display the open Pi, and
      // apply the closed meta to the outer binders at the use site.
      final closedType = closeValueOverCtx(openGoal, outerCtx);
      final newMeta = s.metas.freshTermMeta(closedType, outerCtx);
      var appliedMeta = TMeta(newMeta) as Term;
      for (var k = outerCtx.level - 1; k >= 0; k--) {
        appliedMeta = TApp(appliedMeta, TBound(k + 1));
      }
      // The old goal is `openGoal x` for the binder x (TBound 0 in the
      // current context).
      final applied = TApp(appliedMeta, const TBound(0));
      return TacticOk(
        applied,
        s.metas,
        subMeta: newMeta,
        subGoals: [
          TacticGoal(
            newMeta,
            outerCtx,
            s.binderNames.sublist(1),
            displayType: openGoal,
            closedOverCtx: outerCtx,
          ),
        ],
      );
    };

/// `have name : T = proof` and `have name : T`: adds a local fact.
///
/// [type] is the fact's declared type, already elaborated in the current
/// context; [proof] is its proof, or null to leave the fact as a subgoal.
///
/// The solution is the same shape `intro` builds: a λ that binds the fact,
/// applied to the proof, so the current goal is solved by the fact's term
/// and the main goal continues in the extended context. Without a proof the
/// application argument is a fresh meta, and the fact's goal comes before
/// the main goal.
TacticResult haveFact(TacticState s, String name, Term type, {Term? proof}) {
  final typeValue = eval(type, s.ctx.env);
  final level = s.ctx.level;
  final typeTerm = quote(level, typeValue);
  final newCtx = s.ctx.extend(typeValue);
  final newNames = [name, ...s.binderNames];

  // The main goal's type does not mention the fact: the outer binder
  // levels are unchanged by the extension and the fresh binder sits at
  // the new level, outside the goal's indices.
  final mainMetaId = s.metas.freshTermMeta(s.goalType, newCtx);
  final mainGoal = TacticGoal(mainMetaId, newCtx, newNames);

  final Term factTerm;
  final factGoal = <TacticGoal>[];
  if (proof != null) {
    factTerm = proof;
  } else {
    final factMetaId = s.metas.freshTermMeta(typeValue, s.ctx);
    factTerm = TMeta(factMetaId);
    factGoal.add(TacticGoal(factMetaId, s.ctx, s.binderNames));
  }

  final solution = TApp(
    TLam(typeTerm, TMeta(mainMetaId), name: name),
    factTerm,
  );
  solveCurrentGoal(s, solution);
  return TacticOk(solution, s.metas, subGoals: [...factGoal, mainGoal]);
}

/// `exact t`: provides an explicit proof term that must have the goal type.
TacticFn Function(Term) exact =
    (term) => (s) {
      final goalType = s.goalType;
      try {
        final inferredType = infer(s.ctx, term);
        if (conv(s.ctx.level, inferredType, goalType, s: s) is ConvOk) {
          solveCurrentGoal(s, term);
          return TacticOk(term, s.metas);
        }
      } catch (_) {}
      return const TacticFail('exact: type mismatch');
    };

/// `refl`: closes `Eq[A] x x` goals using the `refl` constructor.
///
/// Expects the goal type to be `Eq[A] x x` and produces `refl[A] x`.
TacticResult refl(TacticState s) {
  final goalType = s.goalType;
  // Goal must be VData("Eq", [A, x, y]) where x == y.
  if (goalType is! VData) {
    return const TacticFail('refl: goal is not an equality type');
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
  if (conv(s.ctx.level, x, y, s: s) is! ConvOk) {
    return const TacticFail(
      'refl: the two sides of the equality are not definitionally equal',
    );
  }
  // Build TConstr("Eq", "refl", [A_term, x_term]).
  final aTerm = quote(s.ctx.level, args[0]);
  final xTerm = quote(s.ctx.level, x);
  final reflTerm = TConstr('Eq', 'refl', [aTerm, xTerm]);
  try {
    final inferred = infer(s.ctx, reflTerm);
    if (conv(s.ctx.level, inferred, goalType, s: s) is ConvOk) {
      // Leaf tactic: solve the goal itself, matching `exact` and `apply`.
      solveCurrentGoal(s, reflTerm);
      return TacticOk(reflTerm, s.metas);
    }
  } catch (_) {}
  return const TacticFail('refl: type mismatch after constructing refl');
}

/// `apply f`: applies lemma `f`, creating subgoals for its explicit
/// arguments.
///
/// Expects `f` to have a Pi type `(x1: A1) -> ... -> (xn: An) -> R`.
/// Every binder gets a fresh meta. Implicit binders are filled by
/// conversion when the conclusion is checked against the goal and never
/// become user goals. Each explicit binder's meta is reported in
/// [TacticOk.subGoals] in argument order, so the following steps solve
/// `apply`'s arguments left to right before any older pending goal.
TacticFn Function(Term) tacticApply =
    (f) => (s) {
      final fType = infer(s.ctx, f);
      final args = <Term>[];
      final explicitGoals = <TacticGoal>[];
      var currentType = fType;
      while (currentType is VPi) {
        final pi = currentType;
        if (pi.icit == Icit.implicit) {
          // Implicit arguments are filled by conversion against the
          // goal. Close the meta over the local context (the same shape
          // `_insertImplicits` uses) so a solution may reference the
          // local binders, and apply the meta to them.
          final closedType = closeValueOverCtx(pi.domain, s.ctx);
          final metaId = s.metas.freshTermMeta(closedType, s.ctx);
          var metaTerm = TMeta(metaId) as Term;
          for (var k = s.ctx.level - 1; k >= 0; k--) {
            metaTerm = TApp(metaTerm, TBound(k));
          }
          args.add(metaTerm);
          final metaValue = eval(metaTerm, s.ctx.env);
          currentType = eval(
            pi.codomain.body,
            pi.codomain.env.extend(metaValue),
          );
        } else {
          // Explicit arguments become user goals, in argument order.
          // The kernel requires every solved meta to be closed, so the
          // meta is declared with the type closed over the local context
          // and applied to it. The user sees the open argument type and
          // their proof is lifted to the closed λ-chain on solve.
          final closedType = closeValueOverCtx(pi.domain, s.ctx);
          final metaId = s.metas.freshTermMeta(closedType, s.ctx);
          var metaTerm = TMeta(metaId) as Term;
          for (var k = s.ctx.level - 1; k >= 0; k--) {
            metaTerm = TApp(metaTerm, TBound(k));
          }
          args.add(metaTerm);
          explicitGoals.add(
            TacticGoal(
              metaId,
              s.ctx,
              s.binderNames,
              displayType: pi.domain,
              closedOverCtx: s.ctx,
            ),
          );
          final metaValue = eval(metaTerm, s.ctx.env);
          currentType = eval(
            pi.codomain.body,
            pi.codomain.env.extend(metaValue),
          );
        }
      }
      var result = f;
      for (final arg in args) {
        result = TApp(result, arg);
      }
      final goalType = s.goalType;
      final resultType = infer(s.ctx, result);
      final matches = conv(s.ctx.level, resultType, goalType, s: s) is ConvOk;
      // With explicit holes the conclusion can only be checked once the
      // user's proofs fill them; the kernel re-checks the final term.
      // Without holes, a mismatched lemma is rejected here as before.
      if (!matches && explicitGoals.isEmpty) {
        return const TacticFail('apply: type mismatch');
      }
      solveCurrentGoal(s, result);
      return TacticOk(result, s.metas, subGoals: explicitGoals);
    };

/// `rewrite p`: rewrites the goal using equality proof `p`.
///
/// Expects `p : Eq[A] x y`. Replaces `x` with `y` throughout the goal
/// type `G`, leaving a subgoal for `G[x:=y]`.
///
/// Doxa's `Eq` recursor abstracts both indices and the proof:
/// `Eq.rec A P c d base e : P c d e`, and its method is a function
/// `(z: A) -> P z z (refl z)`. A motive that only substitutes into one
/// index cannot express a one-point rewrite (the base would then have to
/// hold at every `z`), and a one-argument motive is rejected outright.
/// Rewriting is transport: with the symmetric proof `sym p : Eq[A] y x`
/// and the motive `P a b e := G[x:=a] -> G[x:=b]`, the identity method
/// proves `P z z (refl z)` for every `z`, and
///
///   Eq.rec A P y x (λ z h. h) (sym p) : G[x:=y] -> G
///
/// turns a proof of the rewritten goal into a proof of the goal.
TacticFn Function(Term) rewrite =
    (p) => (s) {
      final pType = infer(s.ctx, p);
      if (pType is! VData || pType.name != 'Eq') {
        return const TacticFail('rewrite: proof is not an equality');
      }
      final eqArgs = pType.args;
      if (eqArgs.length != 3) {
        return const TacticFail('rewrite: Eq has wrong arity');
      }
      final transport = _rewriteTransport(
        s,
        aType: eqArgs[0],
        x: eqArgs[1],
        y: eqArgs[2],
        proof: p,
        goalType: s.goalType,
      );
      return TacticOk(
        TApp(transport.recursor, TMeta(transport.subMeta)),
        s.metas,
        subMeta: transport.subMeta,
        subGoals: [TacticGoal(transport.subMeta, s.ctx, s.binderNames)],
      );
    };

/// Build the transport proof `G[x:=y] -> G` for one rewrite step.
///
/// [x] is the occurrence being replaced (the equation's left endpoint for
/// `rewrite`, the matched subterm for `simp`) and [y] its replacement.
/// [proof] must inhabit `Eq A x y` up to conversion. Returns the recursor
/// application and the fresh subgoal meta for `G[x:=y]`; the caller applies
/// the recursor to a proof of that subgoal.
({Term recursor, int subMeta}) _rewriteTransport(
  TacticState s, {
  required Value aType,
  required Value x,
  required Value y,
  required Term proof,
  required Value goalType,
}) {
  final level = s.ctx.level;
  final xLevel =
      x is VNeutral && x.neutral is NVar ? (x.neutral as NVar).level : null;

  // G[x := v] as a Term quoted at [quoteLevel], where the
  // replacement `v` is the binder at de Bruijn index [boundIndex]
  // of that scope. For an NVar `x`, substitute a neutral at the
  // matching absolute level; otherwise replace the quoted subterm.
  Term goalAt(int quoteLevel, int boundIndex) {
    if (xLevel != null) {
      return quote(
        quoteLevel,
        substNVar(
          goalType,
          xLevel,
          VNeutral(NVar(quoteLevel - 1 - boundIndex)),
        ),
      );
    }
    final goalTerm = quote(quoteLevel, goalType);
    final xTerm = quote(quoteLevel, x);
    return _replaceTermInTerm(goalTerm, xTerm, TBound(boundIndex));
  }

  final aVar = VNeutral(NVar(level));
  final bVar = VNeutral(NVar(level + 1));
  final eqAB = VData('Eq', [aType, aVar, bVar]);

  // sym p : Eq[A] y x. The method of Eq.rec for `refl` is
  // `(z: A) -> P z z (refl z)`, so here it is the function
  // `λ z. refl A z`.
  final symMotive = TLam(
    quote(level, aType),
    TLam(
      quote(level + 1, aType),
      TLam(
        quote(level + 2, eqAB),
        quote(level + 3, VData('Eq', [aType, bVar, aVar])),
      ),
    ),
  );
  final symMethod = TLam(
    quote(level, aType),
    TConstr('Eq', 'refl', [quote(level + 1, aType), const TBound(0)]),
  );
  var symProof = const TRec('Eq') as Term;
  for (final arg in [
    quote(level, aType),
    symMotive,
    quote(level, x),
    quote(level, y),
    symMethod,
    proof,
  ]) {
    symProof = TApp(symProof, arg);
  }

  // Main motive P a b e := G[x:=a] -> G[x:=b], under binders
  // a (level), b (level+1), e (level+2). The Pi body is quoted at
  // level+3; its codomain sits one binder deeper, so its quoted
  // references are one index larger.
  final motive = TLam(
    quote(level, aType),
    TLam(
      quote(level + 1, aType),
      TLam(
        quote(level + 2, eqAB),
        TPi(goalAt(level + 3, 2), goalAt(level + 4, 2)),
      ),
    ),
  );

  // Method `λ (z: A) (h: G[x:=z]). h`, whose type is
  // `P z z (refl z) = G[x:=z] -> G[x:=z]`.
  final method = TLam(
    quote(level, aType),
    TLam(goalAt(level + 1, 0), const TBound(0)),
  );

  // Base instantiated at the equation's left endpoint, y: the
  // subgoal is G[x:=y].
  final reflY = VConstr('Eq', 'refl', [aType, y]);
  final subgoalTerm = goalAt(level + 3, 1);
  final subgoalType = eval(
    subgoalTerm,
    s.ctx.env.extend(y).extend(y).extend(reflY),
  );
  final subMetaId = s.metas.freshTermMeta(subgoalType, s.ctx);

  // Eq.rec A P y x (λ z h. h) (sym p) : G[x:=y] -> G.
  final motiveSort = _motiveSortFor(s.ctx, goalType);
  var recursor = TRec('Eq', motiveSort: motiveSort) as Term;
  for (final arg in [
    quote(level, aType),
    motive,
    quote(level, y),
    quote(level, x),
    method,
    symProof,
  ]) {
    recursor = TApp(recursor, arg);
  }
  return (recursor: recursor, subMeta: subMetaId);
}

/// `induction x`: produces subgoals per constructor of `x`'s type.
///
/// Looks up `x` in the context, finds its inductive data type, and
/// builds the recursor application `T.ind (λ a => G) m1 ... mn x`
/// where each `mi` is a method (constructor case) with fresh subgoal
/// metas and induction hypotheses for recursive arguments. Every method
/// subgoal is returned in [TacticOk.subGoals], in constructor order, so
/// a sequencing driver can work through the arms.
TacticFn Function(String) induction =
    (varName) => (s) {
      // Look up the variable using binderNames (populated by
      // _runTacticSteps for binders introduced by intro).
      int? binderIdx;
      for (var i = 0; i < s.binderNames.length; i++) {
        if (s.binderNames[i] == varName) {
          binderIdx = i;
          break;
        }
      }
      if (binderIdx == null) {
        return TacticFail('induction: variable "$varName" not in scope');
      }
      return _inductionAt(binderIdx)(s);
    };

/// Like [induction] but takes a de Bruijn index instead of a name.
/// Exposed for [_runInduction] in elab.dart which has access to the
/// elaborator's name scope.
TacticFn Function(int) inductionAt = _inductionAt;

/// The motive shared by induction and `cases`.
///
/// [term] is `λ (indices) (scrutinee). goal`, and [value] is its
/// evaluation. Applying [value] to a constructor's result indices and
/// constructor instance is the recursor's method goal for that
/// constructor.
final class _ScrutineeMotive {
  /// Number of data parameters.
  final int paramCount;

  /// Number of result indices.
  final int indexCount;

  /// The scrutinee type's parameters, in declaration order.
  final List<Value> paramsV;

  /// The scrutinee type's index values.
  final List<Value> indicesV;

  /// The motive term and its evaluation.
  final Term term;
  final Value value;

  /// Registries for evaluating constructor telescopes.
  final Env registries;

  const _ScrutineeMotive({
    required this.paramCount,
    required this.indexCount,
    required this.paramsV,
    required this.indicesV,
    required this.term,
    required this.value,
    required this.registries,
  });
}

/// Build `λ (i_0: I_0) ... (i_k-1: I_k-1) (a: T params i). G`.
///
/// The motive abstracts the scrutinee and each result index, which is the
/// shape every indexed recursor demands. A zero-index family gets the
/// one-binder motive `λ (a: T params). G`.
_ScrutineeMotive _buildScrutineeMotive(
  TacticState s,
  DataDecl dataDecl,
  List<Value> dataArgs,
  Value goalType,
  int scrutLevel,
) {
  final level = s.ctx.level;
  final paramCount = dataDecl.params.length;
  final indexCount = dataDecl.indices.length;
  final paramsV = dataArgs.sublist(0, paramCount);
  final indicesV = dataArgs.sublist(paramCount);
  final registries = ENil.withRegistries(
    dataDecls: s.ctx.env.dataDecls,
    topBindings: s.ctx.env.topBindings,
  );

  // Motive P = λ (i_0: I_0) ... (i_k-1: I_k-1) (a: T params i). G,
  // abstracting the scrutinee and the scrutinee's indices. The
  // recursor's motive type is `(indices) -> T params indices ->
  // Sort`, so index binder t sits at level+t and the scrutinee
  // binder at level+indexCount.
  final indexDomains = <Term>[];
  Env indexEnv = registries;
  for (var i = 0; i < paramCount; i++) {
    indexEnv = indexEnv.extend(paramsV[i]);
  }
  for (var t = 0; t < indexCount; t++) {
    final indexTypeV = eval(dataDecl.indices[t].type, indexEnv);
    indexDomains.add(quote(level + t, indexTypeV));
    indexEnv = indexEnv.extend(VNeutral(NVar(level + t)));
  }
  final scrutBinderLevel = level + indexCount;
  final scrutTypeV = VData(dataDecl.name, [
    ...paramsV,
    for (var t = 0; t < indexCount; t++) VNeutral(NVar(level + t)),
  ]);
  // The motive body is the goal with the scrutinee and each index
  // value replaced by its binder. The body sits under all
  // index binders plus the scrutinee binder, hence quoted at
  // scrutBinderLevel+1.
  Value motiveGoal = substNVar(
    goalType,
    scrutLevel,
    VNeutral(NVar(scrutBinderLevel)),
  );
  for (var t = 0; t < indexCount; t++) {
    motiveGoal = _abstractIndexValue(
      ctx: s.ctx,
      goal: motiveGoal,
      index: indicesV[t],
      binder: VNeutral(NVar(level + t)),
      quoteLevel: scrutBinderLevel + 1,
    );
  }
  final motiveBody = quote(scrutBinderLevel + 1, motiveGoal);
  var motive = TLam(quote(scrutBinderLevel, scrutTypeV), motiveBody);
  for (var t = indexCount - 1; t >= 0; t--) {
    motive = TLam(indexDomains[t], motive);
  }
  return _ScrutineeMotive(
    paramCount: paramCount,
    indexCount: indexCount,
    paramsV: paramsV,
    indicesV: indicesV,
    term: motive,
    value: eval(motive, s.ctx.env),
    registries: registries,
  );
}

TacticFn Function(int) _inductionAt =
    (binderIdx) => (s) {
      final level = s.ctx.level;
      // Normalize the goal and the scrutinee type: earlier elaboration
      // leaves solved metavariables in both (implicit arguments of the
      // functions they mention). The index refinement walks values
      // structurally, so a solved `NMeta` where it expects an `NVar`
      // would silently skip the refinement.
      Value normalize(Value v) => eval(
        inlineSolvedMetas(quote(level, v), s.metas, outerDepth: level),
        s.ctx.env,
      );
      final xType = normalize(s.ctx.lookupType(binderIdx));
      if (xType is! VData) {
        return const TacticFail(
          'induction: variable is not of an inductive type',
        );
      }
      final dataName = xType.name;
      final dataArgs = xType.args;
      final dataDecl = s.ctx.lookupData(dataName);
      if (dataDecl == null) {
        return TacticFail('induction: data type "$dataName" not found');
      }
      if (dataDecl.ctors.isEmpty) {
        return TacticFail('induction: $dataName has no constructors');
      }
      final goalType = normalize(s.goalType);

      final Value xVal = VNeutral(NVar(level - 1 - binderIdx));
      if (xVal is! VNeutral || xVal.neutral is! NVar) {
        return const TacticFail('induction: cannot build motive');
      }
      final scrutLevel = (xVal.neutral as NVar).level;

      final motiveInfo = _buildScrutineeMotive(
        s,
        dataDecl,
        dataArgs,
        goalType,
        scrutLevel,
      );
      final paramCount = motiveInfo.paramCount;
      final indexCount = motiveInfo.indexCount;
      final paramsV = motiveInfo.paramsV;
      final indicesV = motiveInfo.indicesV;
      final registries = motiveInfo.registries;
      // The recursor's method type is `arguments -> IHs -> P resultIndices
      // (C args)`. Evaluate the motive once and apply it directly: that
      // is definitionally the method type, including for a constructor
      // whose result indices do not unify with the scrutinee's (the
      // unreachable `vnil` in an induction on `Vec A (succ n)`).
      final motive = motiveInfo.term;
      final motiveV = motiveInfo.value;

      // Build each constructor method and collect its subgoal.
      final methodGoals = <TacticGoal>[];
      final methodTerms = <Term>[];

      for (final ctor in dataDecl.ctors) {
        // Constructor-argument types are closed under the data's params
        // (outermost) and the preceding constructor arguments. Mirror
        // the kernel's arm-telescope construction: extend params in
        // declaration order, then one neutral per argument. The neutral
        // for argument j sits at level `level + j`, the level it
        // occupies inside the method's lambda chain.
        Env teleEnv = registries;
        for (var i = 0; i < paramCount; i++) {
          teleEnv = teleEnv.extend(paramsV[i]);
        }
        final argTypes = <Value>[];
        final ctorArgs = <Value>[];
        for (var j = 0; j < ctor.args.length; j++) {
          argTypes.add(eval(ctor.args[j].type, teleEnv));
          final neutral = VNeutral(NVar(level + j));
          ctorArgs.add(neutral);
          teleEnv = teleEnv.extend(neutral);
        }

        // Names for the method binders. Declared constructor-argument
        // names are used when present; otherwise a stable positional
        // name. Induction hypotheses are named ih, ih2, ...
        final argNames = <String>[
          for (var j = 0; j < ctor.args.length; j++) _ctorArgName(ctor, j),
        ];
        final recArgPositions = <int>[
          for (var j = 0; j < ctor.args.length; j++)
            if (_typeMentionsData(argTypes[j], dataName)) j,
        ];
        final ihNames = <String>[
          for (var i = 0; i < recArgPositions.length; i++) _ihName(i),
        ];

        // The arm telescope: the outer context plus the ctor arguments
        // (without the IHs).
        var armCtx = s.ctx;
        for (final t in argTypes) {
          armCtx = armCtx.extend(t);
        }

        // P(resultIndices) (C args): the recursor's method goal. Applying
        // the motive gives the goal at the constructor's own indices, so
        // an unreachable constructor's method is `P zero vnil` (for Vec)
        // rather than the unrefined `Eq Nat zero (succ n)`.
        final ctorResultIndicesV = <Value>[
          for (final t in ctor.resultIndices) eval(t, teleEnv),
        ];
        final ctorInstanceV = VConstr(dataName, ctor.name, [
          ...paramsV,
          ...ctorArgs,
        ]);
        final pCtorV = _applyMotive(motiveV, [
          ...ctorResultIndicesV,
          ctorInstanceV,
        ]);

        // The induction hypotheses sit after all argument binders in the
        // method's type. Each is the motive at the recursive argument's
        // own indices and the argument itself.
        final ihTypes = <Value>[
          for (final j in recArgPositions)
            _applyMotive(motiveV, [
              ..._subIndices(argTypes[j], dataName, paramCount),
              ctorArgs[j],
            ]),
        ];

        var methodCtx = armCtx;
        for (final t in ihTypes) {
          methodCtx = methodCtx.extend(t);
        }
        final methodBodyMeta = s.metas.freshTermMeta(pCtorV, methodCtx);
        methodGoals.add(
          TacticGoal(methodBodyMeta, methodCtx, [
            for (var i = ihTypes.length - 1; i >= 0; i--) ihNames[i],
            for (var j = argTypes.length - 1; j >= 0; j--) argNames[j],
            ...s.binderNames,
          ]),
        );

        // Build the lambda chain: arguments outermost, hypotheses
        // innermost, matching the recursor's synthesized method type.
        //
        // A binder's domain lives in the scope outside that binder, so
        // argument j is quoted at level+j (it may reference the params,
        // the outer context, and arguments 0..j-1) and hypothesis i at
        // level+args.length+i.
        var body = TMeta(methodBodyMeta) as Term;
        for (var i = ihTypes.length - 1; i >= 0; i--) {
          body = TLam(
            quote(level + argTypes.length + i, ihTypes[i]),
            body,
            name: ihNames[i],
          );
        }
        for (var j = argTypes.length - 1; j >= 0; j--) {
          body = TLam(quote(level + j, argTypes[j]), body, name: argNames[j]);
        }
        methodTerms.add(body);
      }

      // Build the full recursor application. The synthesized recursor
      // takes params, the motive, the methods, the scrutinee's indices,
      // then the scrutinee:
      //   T.ind params P methods indices scrutinee
      //
      // Pick the recursor whose motive targets the goal's sort: a
      // Prop-sorted goal uses `T.ind`, a Type goal the large-elimination
      // variant. The default recursor's motive is the data's declared
      // sort, and Prop does not cumulate into Type, so a Prop goal
      // checked against a Type-sorted motive is rejected.
      final motiveSort = _motiveSortFor(s.ctx, goalType);
      var proofTerm = TRec(dataName, motiveSort: motiveSort) as Term;
      // Apply params.
      for (var i = 0; i < paramCount; i++) {
        proofTerm = TApp(proofTerm, quote(level, paramsV[i]));
      }
      // Apply motive.
      proofTerm = TApp(proofTerm, motive);
      // Apply the scrutinee's indices, then the methods, then the
      // scrutinee. `synthRecursorType` wraps the indices outside the
      // methods (see Eq.rec: `(P) -> (c) -> (d) -> method -> (e)`), so
      // indexed recursors take their indices before the method arms.
      for (var t = 0; t < indexCount; t++) {
        proofTerm = TApp(proofTerm, quote(level, indicesV[t]));
      }
      for (final m in methodTerms) {
        proofTerm = TApp(proofTerm, m);
      }
      proofTerm = TApp(proofTerm, TBound(binderIdx));

      // The first subgoal becomes the "current" one for the next tactic
      // step; the rest are queued by the sequencing driver.
      return TacticOk(
        proofTerm,
        s.metas,
        subMeta: methodGoals.first.metaId,
        subGoals: methodGoals,
      );
    };

/// The name for constructor argument [j]'s binder: the declared name
/// when the data declaration has one, a stable positional name (a, a2,
/// a3, ...) otherwise.
String _ctorArgName(CtorDecl ctor, int j) {
  final declared = ctor.args[j].name;
  if (declared != null && declared != '_') return declared;
  return j == 0 ? 'a' : 'a${j + 1}';
}

/// The name for the [i]-th induction hypothesis: `ih`, `ih2`, ...
String _ihName(int i) => i == 0 ? 'ih' : 'ih${i + 1}';

/// Replace every occurrence of [index] in [goal] with [binder].
///
/// A variable index uses [substNVar], which is capture-avoiding. A
/// compound index (e.g. `succ n`) is quoted and replaced syntactically,
/// the same first-order discipline the rewrite motive uses. The kernel
/// check rejects an abstraction that is wrong under the goal's binders.
Value _abstractIndexValue({
  required Ctx ctx,
  required Value goal,
  required Value index,
  required Value binder,
  required int quoteLevel,
}) {
  if (index is VNeutral && index.neutral is NVar) {
    return substNVar(goal, (index.neutral as NVar).level, binder);
  }
  final goalT = quote(quoteLevel, goal);
  final indexT = quote(quoteLevel, index);
  final binderT = quote(quoteLevel, binder);
  final replaced = _replaceTermInTerm(goalT, indexT, binderT);
  // Evaluate under an env supplying the binders in scope at
  // [quoteLevel]: the outer context plus the new index/scrutinee
  // binders (identity neutrals).
  var env = ctx.env;
  for (var lvl = ctx.level; lvl < quoteLevel; lvl++) {
    env = env.extend(VNeutral(NVar(lvl)));
  }
  return eval(replaced, env);
}

/// Apply [motive] to [args] left to right.
Value _applyMotive(Value motive, List<Value> args) {
  var result = motive;
  for (final arg in args) {
    result = apply(result, arg);
  }
  return result;
}

/// The index values of the data value [type] (params dropped), or an
/// empty list when [type] is not the target inductive applied to
/// arguments (e.g. a function-typed recursive argument).
List<Value> _subIndices(Value type, String dataName, int paramCount) {
  if (type is! VData || type.name != dataName) return const <Value>[];
  if (type.args.length < paramCount) return const <Value>[];
  return type.args.sublist(paramCount);
}

/// The motive-sort override for the recursor that matches [goalType]'s
/// sort: Prop goals use `T.ind`, SProp goals `T.indS`, Type goals the
/// large-elimination variant. The recursor's motive has the goal's sort,
/// and Prop does not cumulate into Type, so the default (the data's own
/// declared sort) is wrong whenever the goal's sort differs.
Term? _motiveSortFor(Ctx ctx, Value goalType) {
  final Value sort;
  try {
    sort = infer(ctx, quote(ctx.level, goalType));
  } catch (_) {
    return null;
  }
  if (sort is VProp) return const TProp();
  if (sort is VSProp) return const TSProp();
  if (sort is VType) return TType(sort.level);
  return null;
}

/// True if [v] is or contains a reference to the inductive type [dataName].
/// Used by [induction] to identify recursive constructor arguments.
bool _typeMentionsData(Value v, String dataName) {
  if (v is VData && v.name == dataName) return true;
  // Descend into function types.
  if (v is VPi) return _typeMentionsData(v.domain, dataName);
  // Descend into neutral applications (e.g. List A).
  if (v is VNeutral) {
    var cur = v.neutral;
    while (cur is NApp) {
      cur = cur.fn;
    }
    if (cur is NVar || cur is NTop) {
      // Check if this could be the target data type through args.
    }
    return false;
  }
  return false;
}

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
      if (conv(s.ctx.level, c.type, s.goalType, s: s) is ConvOk) {
        final term = TBound(idx);
        try {
          final inferred = infer(s.ctx, term);
          if (conv(s.ctx.level, inferred, s.goalType, s: s) is ConvOk) {
            // Leaf tactic: solve the goal itself, matching `exact`.
            solveCurrentGoal(s, term);
            return TacticOk(term, s.metas);
          }
        } catch (_) {}
      }
    } catch (_) {}
    currentCtx = c.rest;
    idx++;
  }
  return const TacticFail('trivial: no trivial proof found');
}

/// `auto [depth]`: depth-bounded proof search.
///
/// Tries `refl`, then `trivial`, then `apply` on every top-level name
/// in scope, recursively up to [depth] levels.  Returns the first
/// solution found or fails.
TacticResult Function(TacticState) auto({int depth = 5}) => (s) {
  // Try refl/trivial first (depth 0 pass).
  final reflResult = refl(s);
  if (reflResult is TacticOk) return reflResult;
  final trivialResult = trivial(s);
  if (trivialResult is TacticOk) return trivialResult;

  if (depth <= 0) {
    return const TacticFail('auto: depth exhausted');
  }

  // Collect lemma names from the context's env topBindings.
  final topBindings = s.ctx.env.topBindings;
  final lemmaNames = topBindings.keys.toList();
  // Also try data type constructors.
  for (final dd in s.ctx.env.dataDecls) {
    for (final c in dd.ctors) {
      if (!lemmaNames.contains(c.name)) lemmaNames.add(c.name);
    }
  }

  for (final name in lemmaNames) {
    // Look up the term for this name.
    final entry = topBindings[name];
    if (entry == null) continue;

    // `tacticApply` solves the current goal before this search knows
    // whether its explicit arguments are provable. Keep a snapshot and
    // restore it when this lemma does not finish, so the next candidate
    // starts from the same unsolved goal.
    final snapshot = s.metas.snapshot();
    try {
      // Build a TTop term for this lemma.
      final lemmaTerm = TTop(name);

      // Try apply on it.
      final applyResult = tacticApply(lemmaTerm)(s);
      if (applyResult is TacticOk) {
        // With no explicit arguments the conclusion already matched; the
        // current goal is solved and `tacticApply` committed the term.
        if (applyResult.subGoals.isEmpty) return applyResult;

        // Otherwise every explicit argument is a goal for the recursive
        // search. An unsolved argument means this application is not a
        // proof.
        final metas = applyResult.metas;
        var allOk = true;
        for (final goal in applyResult.subGoals) {
          if (metas.isSolved(goal.metaId)) continue;
          final subState = TacticState(
            metas,
            goal.ctx,
            goal.metaId,
            goal.binderNames,
            const [],
            goal.displayType,
            goal.closedOverCtx,
          );
          final subResult = auto(depth: depth - 1)(subState);
          if (subResult is! TacticOk) {
            allOk = false;
            break;
          }
        }
        if (allOk) {
          return TacticOk(applyResult.term, metas);
        }
      }
    } catch (_) {
      // A candidate the kernel rejects is not a proof; restore and try
      // the next name.
    }
    s.metas.restore(snapshot);
  }

  return TacticFail('auto: no proof found at depth $depth');
};

/// `omega`: solve simple arithmetic goals on `Nat`.
///
/// Normalises both sides of an `Eq Nat lhs rhs` goal via `nf()` and
/// returns `refl` if they become syntactically identical.  Handles
/// common patterns: `plus_comm`, `plus_assoc`, `plus_zero`,
/// `mult_zero`, etc. by trying known lemmas from the environment.
TacticResult omega(TacticState s) {
  final goalType = s.goalType;
  final level = s.ctx.level;

  // If the goal is Eq Nat a b, normalise and compare a, b.
  if (goalType is VData && goalType.name == 'Eq' && goalType.args.length == 3) {
    final lhs = goalType.args[1];
    final rhs = goalType.args[2];
    final lhsNorm = quote(level, eval(quote(level, lhs), s.ctx.env));
    final rhsNorm = quote(level, eval(quote(level, rhs), s.ctx.env));
    if (lhsNorm == rhsNorm) {
      // Normalise to identity — use refl.
      return refl(s);
    }
  }

  // Try known lemmas for common arithmetic patterns.
  final topBindings = s.ctx.env.topBindings;
  final lemmaCandidates = [
    'plus_comm',
    'plus_assoc',
    'plus_zero',
    'plus_succ',
    'mult_comm',
    'mult_zero',
    'mult_one',
    'mult_assoc',
    'mult_plus',
    'mult_2',
    'mult_4_eq',
    'mult_succ_right',
    'mult_2_inj',
  ];

  for (final name in lemmaCandidates) {
    if (!topBindings.containsKey(name)) continue;
    final result = tacticApply(TTop(name))(s);
    if (result is TacticOk) return result;
  }

  return const TacticFail('omega: could not solve the arithmetic goal');
}

/// `simpl`: normalise the goal, then run `simp` with no extra lemmas.
///
/// Kept as the REPL's historical `:step simpl` entry point.
TacticResult simpl(TacticState s) => simp(const <Term>[])(s);

/// Rewrite budget for one `simp` invocation.
const int _simpRewriteBudget = 100;

/// One equality the resolver may rewrite with.
final class _SimpRuleSource {
  /// Name used in diagnostics.
  final String name;

  /// The source's type, before Pi instantiation.
  final Value type;

  /// The source's proof term, before Pi instantiation.
  final Term proof;

  const _SimpRuleSource(this.name, this.type, this.proof);
}

/// `simp [lemmas]`: normalise the goal and rewrite with equality lemmas
/// to a fixed point, closing by `refl` when the sides become convertible.
///
/// With no list, the equality-typed hypotheses in the local context are
/// the rewrite set. A list adds elaborated expressions. There is no
/// global lemma search and no attribute syntax.
///
/// A rule may have a Pi type. Every binder is instantiated with a fresh
/// meta closed over the local context, as [tacticApply] does, and the
/// instantiated type must reduce to `Eq A l r`. Matching traverses the
/// goal type's subterms outermost first and uses the kernel's conversion
/// checker as the matching relation; a successful match leaves the rule's
/// metas solved.
///
/// Each rewrite replaces every occurrence of the matched subterm with the
/// rule's right endpoint through the same transport construction
/// [rewrite] uses. The goal is normalised before matching and after each
/// rewrite. The loop stops on a repeated normalised goal or after
/// [_simpRewriteBudget] rewrites and reports a diagnostic rather than
/// returning a partial result.
///
/// Outcomes: the goal closes when `refl` applies; a rewrite or
/// normalisation with the goal still open leaves the rewritten goal as
/// the current subgoal; no rewrite and no `refl` fails with
/// `simp: no progress` when nothing changed.
TacticFn Function(List<Term>) simp =
    (lemmas) => (s) {
      final metas = s.metas;
      final ctx = s.ctx;
      final level = ctx.level;
      final initialMeta = s.currentMeta;

      final sources = <_SimpRuleSource>[];
      var binder = ctx;
      var index = 0;
      while (binder is CCons) {
        final name =
            index < s.binderNames.length ? s.binderNames[index] : 'h$index';
        sources.add(_SimpRuleSource(name, binder.type, TBound(index)));
        binder = binder.rest;
        index++;
      }
      for (var i = 0; i < lemmas.length; i++) {
        final term = lemmas[i];
        final Value type;
        try {
          type = infer(ctx, term);
        } catch (_) {
          return const TacticFail('simp: could not infer a lemma type');
        }
        final name = switch (term) {
          TTop(:final name) => name,
          TBound(:final index) when index < s.binderNames.length =>
            s.binderNames[index],
          _ => 'lemma${i + 1}',
        };
        sources.add(_SimpRuleSource(name, type, term));
      }

      TacticState stateFor(int meta) => TacticState(
        metas,
        ctx,
        meta,
        s.binderNames,
        const [],
        meta == initialMeta ? s.goalTypeOverride : null,
        meta == initialMeta ? s.closedGoalOverCtx : null,
      );

      var tail = initialMeta;
      var first = true;
      var rewrites = 0;
      String? lastRule;
      final visited = <String>{};
      Term Function(Term) initialFromTail = (t) => t;

      void advance(int newMeta, Term Function(Term) stepForward) {
        final previous = initialFromTail;
        initialFromTail = (t) => previous(stepForward(t));
        if (!first) {
          metas.solve(tail, stepForward(TMeta(newMeta)));
        } else {
          first = false;
        }
        tail = newMeta;
      }

      TacticFail limitExceeded({required bool cycle}) {
        final suffix = lastRule == null ? '' : '; last rule: $lastRule';
        final count = cycle ? rewrites : _simpRewriteBudget;
        return TacticFail(
          'simp: rewrite limit exceeded after $count steps'
          '${cycle ? ' (cycle detected)' : ''}$suffix',
        );
      }

      while (true) {
        final state = stateFor(tail);
        final goalType = state.goalType;
        final original = quote(level, goalType);
        final normalValue = eval(original, ctx.env);
        final normal = quote(level, normalValue);
        if (normal != original) {
          final next = metas.freshTermMeta(normalValue, ctx);
          advance(next, (t) => t);
          continue;
        }

        if (!visited.add(normal.toString())) {
          return limitExceeded(cycle: true);
        }

        final reflTerm = _simpRefl(state);
        if (reflTerm != null) {
          if (tail == initialMeta) {
            // Leave the initial meta for the caller, which owns the
            // convention of solving the current goal with the result.
            return TacticOk(reflTerm, metas, subMeta: tail);
          }
          metas.solve(tail, reflTerm);
          return TacticOk(initialFromTail(reflTerm), metas, subMeta: tail);
        }

        final match = _findSimpMatch(state, sources, goalType);
        if (match == null) {
          if (tail == initialMeta) {
            return const TacticFail('simp: no progress');
          }
          return TacticOk(initialFromTail(TMeta(tail)), metas, subMeta: tail);
        }
        if (rewrites >= _simpRewriteBudget) {
          return limitExceeded(cycle: false);
        }
        final transport = _rewriteTransport(
          state,
          aType: match.aType,
          x: match.x,
          y: match.y,
          proof: match.proof,
          goalType: goalType,
        );
        advance(transport.subMeta, (t) => TApp(transport.recursor, t));
        lastRule = match.ruleName;
        rewrites++;
      }
    };

/// Find one rule and one goal subterm that the kernel accepts as equal.
///
/// Candidates are visited outermost first. Each rule instantiation takes a
/// [MetaContext] snapshot; a failed match restores it, so a rule that
/// cannot be solved leaves no metas behind.
({String ruleName, Value aType, Value x, Value y, Term proof})? _findSimpMatch(
  TacticState state,
  List<_SimpRuleSource> sources,
  Value goalType,
) {
  final level = state.ctx.level;
  for (final candidate in _valueSubterms(goalType, level)) {
    for (final source in sources) {
      final snapshot = state.metas.snapshot();
      try {
        final rule = _instantiateSimpRule(state, source);
        if (rule == null) {
          state.metas.restore(snapshot);
          continue;
        }
        final matched = conv(level, rule.lhs, candidate, s: state) is ConvOk;
        if (matched && rule.metaIds.every(state.metas.isSolved)) {
          final rhsTerm = inlineSolvedMetas(
            quote(level, rule.rhs),
            state.metas,
            outerDepth: level,
          );
          final rhs = eval(rhsTerm, state.ctx.env);
          if (_simpRewriteChanges(goalType, candidate, rhs, level)) {
            return (
              ruleName: source.name,
              aType: rule.aType,
              x: candidate,
              y: rhs,
              proof: rule.proof,
            );
          }
        }
      } catch (_) {
        // A rule whose type or unifier state the kernel cannot handle is
        // not a match; leave the metas as they were and keep searching.
      }
      state.metas.restore(snapshot);
    }
  }
  return null;
}

/// Instantiate [source]'s Pi binders with fresh metas and require the
/// result to be an `Eq` type. Returns `null` without restoring metas; the
/// caller owns the snapshot.
({Value aType, Value lhs, Value rhs, Term proof, List<int> metaIds})?
_instantiateSimpRule(TacticState s, _SimpRuleSource source) {
  var type = source.type;
  var proof = source.proof;
  final metaIds = <int>[];
  while (type is VPi) {
    final pi = type;
    final closedType = closeValueOverCtx(pi.domain, s.ctx);
    final metaId = s.metas.freshTermMeta(closedType, s.ctx);
    metaIds.add(metaId);
    var metaTerm = TMeta(metaId) as Term;
    for (var k = s.ctx.level - 1; k >= 0; k--) {
      metaTerm = TApp(metaTerm, TBound(k));
    }
    proof = TApp(proof, metaTerm);
    final metaValue = eval(metaTerm, s.ctx.env);
    type = eval(pi.codomain.body, pi.codomain.env.extend(metaValue));
  }
  if (type is! VData || type.name != 'Eq' || type.args.length != 3) {
    return null;
  }
  return (
    aType: type.args[0],
    lhs: type.args[1],
    rhs: type.args[2],
    proof: proof,
    metaIds: metaIds,
  );
}

/// Whether replacing [x] with [y] changes [goalType] syntactically.
///
/// A rule whose endpoints normalise to the matched subterm cannot make
/// progress; treating the match as a failure keeps the fixed-point loop
/// from cycling on a no-op rewrite.
bool _simpRewriteChanges(Value goalType, Value x, Value y, int level) {
  final original = quote(level, goalType);
  if (x is VNeutral && x.neutral is NVar) {
    final xLevel = (x.neutral as NVar).level;
    return quote(level, substNVar(goalType, xLevel, y)) != original;
  }
  return _replaceTermInTerm(original, quote(level, x), quote(level, y)) !=
      original;
}

/// Build the `refl` term when the goal is an equality with convertible
/// sides, without solving the goal.
Term? _simpRefl(TacticState s) {
  final goalType = s.goalType;
  if (goalType is! VData || goalType.name != 'Eq') return null;
  final args = goalType.args;
  if (args.length != 3) return null;
  final level = s.ctx.level;
  final reflTerm = TConstr('Eq', 'refl', [
    quote(level, args[0]),
    quote(level, args[1]),
  ]);
  try {
    if (conv(level, args[1], args[2], s: s) is! ConvOk) return null;
    final inferred = infer(s.ctx, reflTerm);
    if (conv(level, inferred, goalType, s: s) is ConvOk) return reflTerm;
  } catch (_) {}
  return null;
}

/// Enumerate [value]'s subterms, outermost first.
///
/// Covers data and constructor applications, neutral spines, Pi domains
/// and codomains, and lambda domains and bodies. Bodies under a binder are
/// opened with a fresh neutral at the current level so nested applications
/// stay visible.
List<Value> _valueSubterms(Value value, int level) {
  final out = <Value>[];
  void visit(Value v, int lvl) {
    out.add(v);
    switch (v) {
      case VType() || VUnknown() || VProp() || VSProp():
        break;
      case VLam(:final domain, :final closure):
        visit(domain, lvl);
        visit(
          eval(closure.body, closure.env.extend(VNeutral(NVar(lvl)))),
          lvl + 1,
        );
      case VPi(:final domain, :final codomain):
        visit(domain, lvl);
        visit(
          eval(codomain.body, codomain.env.extend(VNeutral(NVar(lvl)))),
          lvl + 1,
        );
      case VNeutral(:final neutral):
        for (final sub in _neutralSubvalues(neutral)) {
          visit(sub, lvl);
        }
      case VData(:final args):
        for (final arg in args) {
          visit(arg, lvl);
        }
      case VConstr(:final args):
        for (final arg in args) {
          visit(arg, lvl);
        }
      case VRec(:final spine):
        for (final arg in spine) {
          visit(arg, lvl);
        }
      case VFun(:final spine):
        for (final arg in spine) {
          visit(arg, lvl);
        }
      case VMatch(:final scrutinee, :final motive):
        visit(scrutinee, lvl);
        if (motive != null) visit(motive, lvl);
      case VQuot(:final carrier, :final relation):
        visit(carrier, lvl);
        visit(relation, lvl);
      case VQuotMk(:final arg):
        visit(arg, lvl);
      case VQuotLift(:final quot, :final fn, :final proof):
        visit(quot, lvl);
        visit(fn, lvl);
        visit(proof, lvl);
      case VDelayed(:final closure, :final arg):
        visit(arg, lvl);
        visit(eval(closure.body, closure.env.extend(arg)), lvl);
    }
  }

  visit(value, level);
  return out;
}

/// The argument subvalues of a neutral spine.
List<Value> _neutralSubvalues(Neutral neutral) {
  final out = <Value>[];
  void walk(Neutral n) {
    switch (n) {
      case NVar() || NTop() || NMeta():
        break;
      case NApp(:final fn, :final arg):
        walk(fn);
        out.add(arg);
      case NStuck(:final value):
        out.add(value);
      case NProj(:final expr):
        out.add(expr);
    }
  }

  walk(neutral);
  return out;
}

/// `constructor`: apply the first matching constructor of the goal's
/// inductive type, leaving each explicit argument as a subgoal.
TacticResult tacticConstructor(TacticState s) {
  final goalType = s.goalType;
  if (goalType is! VData) {
    return const TacticFail('constructor: goal is not an inductive type');
  }
  final dataName = goalType.name;
  final dataDecl = s.ctx.lookupData(dataName);
  if (dataDecl == null) {
    return TacticFail('constructor: data type "$dataName" not found');
  }
  final dataArgs = goalType.args;
  final paramCount = dataDecl.params.length;
  final level = s.ctx.level;
  final paramTerms = <Term>[
    for (var i = 0; i < paramCount; i++) quote(level, dataArgs[i]),
  ];
  final registries = ENil.withRegistries(
    dataDecls: s.ctx.env.dataDecls,
    topBindings: s.ctx.env.topBindings,
  );

  for (final ctor in dataDecl.ctors) {
    // Constructor-argument types are closed under the data's params in
    // declaration order, then the preceding constructor arguments. Each
    // argument meta is closed over the tactic context and applied to its
    // spine, the shape `tacticApply` gives an explicit argument, so a
    // solution open in the context is lifted when the user supplies it.
    Env teleEnv = registries;
    for (var i = 0; i < paramCount; i++) {
      teleEnv = teleEnv.extend(dataArgs[i]);
    }
    final argMetas = <int>[];
    final argTerms = <Term>[];
    final argTypes = <Value>[];
    for (var j = 0; j < ctor.args.length; j++) {
      final argTypeV = eval(ctor.args[j].type, teleEnv);
      argTypes.add(argTypeV);
      final closedType = closeValueOverCtx(argTypeV, s.ctx);
      final metaId = s.metas.freshTermMeta(closedType, s.ctx);
      argMetas.add(metaId);
      var metaTerm = TMeta(metaId) as Term;
      for (var k = s.ctx.level - 1; k >= 0; k--) {
        metaTerm = TApp(metaTerm, TBound(k));
      }
      argTerms.add(metaTerm);
      teleEnv = teleEnv.extend(eval(metaTerm, s.ctx.env));
    }
    // A constructor term carries the data parameters first, then the
    // constructor's own arguments; the kernel's constructor signature
    // and the recursor's instance both use that order.
    final ctorTerm = TConstr(dataName, ctor.name, [...paramTerms, ...argTerms]);

    // Check if ctor term matches goal type.
    try {
      final ctorType = infer(s.ctx, ctorTerm);
      if (conv(s.ctx.level, ctorType, goalType, s: s) is ConvOk) {
        if (argMetas.isEmpty) {
          // A nullary constructor is a leaf proof; no subgoals remain.
          solveCurrentGoal(s, ctorTerm);
          return TacticOk(ctorTerm, s.metas);
        }
        // Leave the current goal to the caller, which commits [ctorTerm]
        // first and then works through the argument goals in order.
        final subGoals = <TacticGoal>[
          for (var j = 0; j < argMetas.length; j++)
            TacticGoal(
              argMetas[j],
              s.ctx,
              s.binderNames,
              displayType: argTypes[j],
              closedOverCtx: s.ctx,
            ),
        ];
        return TacticOk(
          ctorTerm,
          s.metas,
          subMeta: argMetas.first,
          subGoals: subGoals,
        );
      }
    } catch (_) {}
  }
  return const TacticFail('constructor: no constructor matches the goal');
}

/// `cases x`: destruct variable `x` into one subgoal per constructor.
///
/// Like [induction] but without induction hypotheses. For each
/// constructor of `x`'s type, creates a subgoal for the goal with `x`
/// replaced by that constructor applied to fresh neutrals. Every arm is
/// reported in [TacticOk.subGoals], with the constructor arguments in the
/// arm's context and named as [induction] names them.
TacticFn Function(String) tacticCases =
    (varName) => (s) {
      int? binderIdx;
      for (var i = 0; i < s.binderNames.length; i++) {
        if (s.binderNames[i] == varName) {
          binderIdx = i;
          break;
        }
      }
      if (binderIdx == null) {
        return TacticFail('cases: variable "$varName" not in scope');
      }
      final level = s.ctx.level;
      Value normalize(Value v) => eval(
        inlineSolvedMetas(quote(level, v), s.metas, outerDepth: level),
        s.ctx.env,
      );
      final xType = normalize(s.ctx.lookupType(binderIdx));
      if (xType is! VData) {
        return const TacticFail('cases: variable is not of an inductive type');
      }
      final dataName = xType.name;
      final dataArgs = xType.args;
      final dataDecl = s.ctx.lookupData(dataName);
      if (dataDecl == null) {
        return TacticFail('cases: data type "$dataName" not found');
      }
      final goalType = normalize(s.goalType);

      final xVal = VNeutral(NVar(level - 1 - binderIdx));
      if (xVal.neutral is! NVar) {
        return const TacticFail('cases: cannot build motive');
      }
      final scrutLevel = (xVal.neutral as NVar).level;

      // The recursor demands the indexed motive, the same construction
      // induction uses: `λ (indices) (a: T params indices). G`.
      final motiveInfo = _buildScrutineeMotive(
        s,
        dataDecl,
        dataArgs,
        goalType,
        scrutLevel,
      );
      final paramCount = motiveInfo.paramCount;
      final indexCount = motiveInfo.indexCount;
      final paramsV = motiveInfo.paramsV;
      final indicesV = motiveInfo.indicesV;
      final registries = motiveInfo.registries;
      final motive = motiveInfo.term;
      final motiveV = motiveInfo.value;

      final methodMetas = <int>[];
      final methodTerms = <Term>[];
      final methodGoals = <TacticGoal>[];

      for (final ctor in dataDecl.ctors) {
        // Constructor-argument types are closed under the data's params
        // (outermost) and the preceding constructor arguments. Extend
        // params in declaration order and each argument after it, the
        // same telescope [induction] builds.
        Env teleEnv = registries;
        for (var i = 0; i < paramCount; i++) {
          teleEnv = teleEnv.extend(paramsV[i]);
        }
        final argTypes = <Value>[];
        final ctorArgs = <Value>[];
        for (var j = 0; j < ctor.args.length; j++) {
          final argTypeV = eval(ctor.args[j].type, teleEnv);
          argTypes.add(argTypeV);
          final neutral = VNeutral(NVar(level + j));
          ctorArgs.add(neutral);
          teleEnv = teleEnv.extend(neutral);
        }
        // P(resultIndices) (C args): the recursor's method goal at the
        // constructor's own indices and instance, the same computation
        // induction's method goals use.
        final ctorResultIndicesV = <Value>[
          for (final t in ctor.resultIndices) eval(t, teleEnv),
        ];
        final ctorInstanceV = VConstr(dataName, ctor.name, [
          ...paramsV,
          ...ctorArgs,
        ]);
        final pCtorV = _applyMotive(motiveV, [
          ...ctorResultIndicesV,
          ctorInstanceV,
        ]);

        // The recursor's method for a recursive constructor still demands
        // an induction hypothesis. `cases` does not hand it to the user;
        // it is bound under an unusable `_` name so the arm goal, which
        // does not mention it, is the only thing the next step sees.
        final recArgPositions = <int>[
          for (var j = 0; j < ctor.args.length; j++)
            if (_typeMentionsData(argTypes[j], dataName)) j,
        ];
        final ihTypes = <Value>[
          for (final j in recArgPositions)
            _applyMotive(motiveV, [
              ..._subIndices(argTypes[j], dataName, paramCount),
              ctorArgs[j],
            ]),
        ];

        // The arm's context carries the constructor arguments, so their
        // neutrals are in scope when the user solves the arm. Binder
        // names are innermost-first, matching every other tactic goal.
        var armCtx = s.ctx;
        for (final t in argTypes) {
          armCtx = armCtx.extend(t);
        }
        var methodCtx = armCtx;
        for (final t in ihTypes) {
          methodCtx = methodCtx.extend(t);
        }
        final methodBodyMeta = s.metas.freshTermMeta(pCtorV, methodCtx);
        methodMetas.add(methodBodyMeta);

        final argNames = <String>[
          for (var j = 0; j < ctor.args.length; j++) _ctorArgName(ctor, j),
        ];
        methodGoals.add(
          TacticGoal(methodBodyMeta, methodCtx, [
            for (var i = ihTypes.length - 1; i >= 0; i--) '_',
            for (var j = argNames.length - 1; j >= 0; j--) argNames[j],
            ...s.binderNames,
          ]),
        );

        // The method's lambda chain: arguments outermost, hypotheses
        // innermost, the discipline [induction] uses.
        var body = TMeta(methodBodyMeta) as Term;
        for (var i = ihTypes.length - 1; i >= 0; i--) {
          body = TLam(
            quote(level + argTypes.length + i, ihTypes[i]),
            body,
            name: '_',
          );
        }
        for (var j = argTypes.length - 1; j >= 0; j--) {
          body = TLam(quote(level + j, argTypes[j]), body, name: argNames[j]);
        }
        methodTerms.add(body);
      }

      // Build the full recursor application. Pick the eliminator whose
      // motive targets the goal's sort, the way induction does: a
      // Prop-sorted goal needs `T.ind`, not the Type default.
      final motiveSort = _motiveSortFor(s.ctx, goalType);
      var proofTerm = TRec(dataName, motiveSort: motiveSort) as Term;
      for (var i = 0; i < paramCount; i++) {
        proofTerm = TApp(proofTerm, quote(level, dataArgs[i]));
      }
      proofTerm = TApp(proofTerm, motive);
      for (var t = 0; t < indexCount; t++) {
        proofTerm = TApp(proofTerm, quote(level, indicesV[t]));
      }
      for (final m in methodTerms) {
        proofTerm = TApp(proofTerm, m);
      }
      proofTerm = TApp(proofTerm, TBound(binderIdx));

      return TacticOk(
        proofTerm,
        s.metas,
        subMeta: methodMetas.isNotEmpty ? methodMetas.first : null,
        subGoals: methodGoals,
      );
    };

// ---------------------------------------------------------------------------
// Conversion check — delegates to kernel
// ---------------------------------------------------------------------------

/// Check convertibility of two values at [level], using the kernel's
/// full conversion checker (WHNF normalisation, eta, proof irrelevance).
///
/// Extracts [dataDecls] and [topBindings] from [s] so the kernel can
/// look up top-level definitions and inductive types.
kernel_eval.ConvResult conv(
  int level,
  Value a,
  Value b, {
  required TacticState s,
}) => kernel_eval.conv(
  level,
  a,
  b,
  dataDecls: s.ctx.env.dataDecls,
  // Thread the meta context: a term elaborated in the tactic's real
  // context carries solved implicit arguments, and conversion must
  // force them (and may solve new ones) exactly as the elaborator's
  // conv does.
  metas: s.metas,
  topBindings: s.ctx.env.topBindings,
);

/// Walk [t] and replace every occurrence of the term [from] with [to].
/// Uses structural equality (Term.==).  This is a simple syntactic
/// replacement; it does NOT perform capture-avoiding substitution.
/// Reliable only when [from] is a closed term (no TBound references).
Term _replaceTermInTerm(Term t, Term from, Term to) {
  if (t == from) return to;
  switch (t) {
    case TApp(:final fn, :final arg):
      final newFn = _replaceTermInTerm(fn, from, to);
      final newArg = _replaceTermInTerm(arg, from, to);
      if (identical(newFn, fn) && identical(newArg, arg)) return t;
      return TApp(newFn, newArg);
    case TLam(:final domain, :final body):
      final newDom = _replaceTermInTerm(domain, from, to);
      final newBody = _replaceTermInTerm(body, from, to);
      if (identical(newDom, domain) && identical(newBody, body)) return t;
      return TLam(newDom, newBody);
    case TPi(:final domain, :final codomain):
      final newDom = _replaceTermInTerm(domain, from, to);
      final newCod = _replaceTermInTerm(codomain, from, to);
      if (identical(newDom, domain) && identical(newCod, codomain)) return t;
      return TPi(newDom, newCod);
    case TLet(:final domain, :final bound, :final body, :final name):
      return TLet(
        _replaceTermInTerm(domain, from, to),
        _replaceTermInTerm(bound, from, to),
        _replaceTermInTerm(body, from, to),
        name: name,
      );
    case TData(:final name, :final args):
      final newArgs = <Term>[];
      var changed = false;
      for (final a in args) {
        final na = _replaceTermInTerm(a, from, to);
        newArgs.add(na);
        if (!identical(na, a)) changed = true;
      }
      return changed ? TData(name, newArgs) : t;
    case TConstr(:final dataName, :final ctorName, :final args):
      final newArgs = <Term>[];
      var changed = false;
      for (final a in args) {
        final na = _replaceTermInTerm(a, from, to);
        newArgs.add(na);
        if (!identical(na, a)) changed = true;
      }
      return changed ? TConstr(dataName, ctorName, newArgs) : t;
    case TMatch(:final scrutinee, :final motive, :final cases):
      return TMatch(
        _replaceTermInTerm(scrutinee, from, to),
        motive == null ? null : _replaceTermInTerm(motive, from, to),
        [
          for (final c in cases)
            TMatchCase(
              c.ctorName,
              c.nBinders,
              _replaceTermInTerm(c.body, from, to),
              c.binderNames,
              span: c.span,
            ),
        ],
      );
    case TQuot(:final carrier, :final relation):
      return TQuot(
        _replaceTermInTerm(carrier, from, to),
        _replaceTermInTerm(relation, from, to),
      );
    case TQuotMk(:final arg):
      return TQuotMk(_replaceTermInTerm(arg, from, to));
    case TQuotLift(:final quot, :final fn, :final proof):
      return TQuotLift(
        _replaceTermInTerm(quot, from, to),
        _replaceTermInTerm(fn, from, to),
        _replaceTermInTerm(proof, from, to),
      );
    case TProj(:final expr, :final fieldName):
      return TProj(_replaceTermInTerm(expr, from, to), fieldName);
    default:
      return t;
  }
}

/// Validate [term] against [ctx] at construction time.
///
/// Checks that the term contains no [TFree] (unresolved names) and
/// no [TBound] indices exceeding the context depth.  Throws
/// [StateError] on violation.  Called as an assertion before
/// meta-solving in the REPL proof loop.
void validateTerm(Term term, Ctx ctx) {
  _validateTerm(term, ctx, 0);
}

void _validateTerm(Term t, Ctx ctx, int depth) {
  switch (t) {
    case TFree(:final name):
      throw StateError('validateTerm: unresolved TFree($name)');
    case TUnknown():
      // The internal unknown marker never belongs in a term handed to
      // the meta-solver: it names the absence of a type.
      throw StateError('validateTerm: internal TUnknown');
    case TBound(:final index):
      final maxIdx = ctx.level + depth - 1;
      if (index > maxIdx) {
        throw StateError(
          'validateTerm: TBound($index) exceeds max depth $maxIdx '
          '(ctx level ${ctx.level}, nest depth $depth)',
        );
      }
    case TApp(:final fn, :final arg):
      _validateTerm(fn, ctx, depth);
      _validateTerm(arg, ctx, depth);
    case TLam(:final domain, :final body):
      _validateTerm(domain, ctx, depth);
      _validateTerm(body, ctx, depth + 1);
    case TPi(:final domain, :final codomain):
      _validateTerm(domain, ctx, depth);
      _validateTerm(codomain, ctx, depth + 1);
    case TMatch(:final scrutinee, :final motive, :final cases):
      _validateTerm(scrutinee, ctx, depth);
      if (motive != null) _validateTerm(motive, ctx, depth);
      for (final c in cases) {
        _validateTerm(c.body, ctx, depth + c.nBinders);
      }
    case TLet(:final domain, :final bound, :final body):
      _validateTerm(domain, ctx, depth);
      _validateTerm(bound, ctx, depth);
      _validateTerm(body, ctx, depth + 1);
    case TType() ||
        TProp() ||
        TSProp() ||
        TTop() ||
        TMeta() ||
        TConstr() ||
        TData() ||
        TQuot() ||
        TQuotMk() ||
        TQuotLift() ||
        TProj() ||
        TRec():
      break;
  }
}
