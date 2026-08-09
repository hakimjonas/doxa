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
  }) => TacticState(
    metas ?? this.metas,
    ctx ?? this.ctx,
    currentMeta ?? this.currentMeta,
    binderNames ?? this.binderNames,
  );

  /// The type of the current goal.
  Value get goalType =>
      metas.lookup(currentMeta).isSolved
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
    TacticOk(term: final _, :final metas, :final subMeta) => t2(
      TacticState(metas, s.ctx, subMeta ?? s.currentMeta),
    ),
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
    return TacticFail('intro: goal is not a function type');
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
  return TacticOk(lamTerm, s.metas, subMeta: subMetaId);
}

/// `exact t`: provides an explicit proof term that must have the goal type.
TacticFn Function(Term) exact =
    (term) => (s) {
      final goalType = s.goalType;
      try {
        final inferredType = infer(s.ctx, term);
        if (conv(s.ctx.level, inferredType, goalType, s: s) is ConvOk) {
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
  if (conv(s.ctx.level, x, y, s: s) is! ConvOk) {
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
    if (conv(s.ctx.level, inferred, goalType, s: s) is ConvOk) {
      return TacticOk(reflTerm, s.metas);
    }
  } catch (_) {}
  return TacticFail('refl: type mismatch after constructing refl');
}

/// `apply f`: applies lemma `f`, creating subgoals for each argument.
///
/// Expects `f` to have a Pi type `(x1: A1) -> ... -> (xn: An) -> R`.
/// Creates fresh metas for each argument and returns `f ?1 ... ?n`.
TacticFn Function(Term) tacticApply =
    (f) => (s) {
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
      if (conv(s.ctx.level, resultType, goalType, s: s) is ConvOk) {
        s.metas.solve(s.currentMeta, result);
        return TacticOk(result, s.metas);
      }
      return TacticFail('apply: type mismatch');
    };

/// `rewrite p`: rewrites the goal using equality proof `p`.
///
/// Expects `p : Eq[A] x y`.  Builds the term
/// `Eq.rec A (λ a => G[x:=a]) x y p ?sub` where `G` is the goal type and
/// `?sub` is a fresh subgoal for the rewritten type `G[x:=y]`.
TacticFn Function(Term) rewrite =
    (p) => (s) {
      final pType = infer(s.ctx, p);
      if (pType is! VData || pType.name != 'Eq') {
        return TacticFail('rewrite: proof is not an equality');
      }
      final eqArgs = pType.args;
      if (eqArgs.length != 3) {
        return TacticFail('rewrite: Eq has wrong arity');
      }
      final aType = eqArgs[0]; // A : Type
      final x = eqArgs[1]; // x : A
      final y = eqArgs[2]; // y : A
      final level = s.ctx.level;

      // Goal G = s.goalType (a Value).
      // Build P = λ a => G[x := a].
      //
      // When x is an NVar, use substNVar to replace x with a fresh
      // neutral at the current level.  Quote the result at level+1
      // so that the fresh neutral becomes TBound(0) (the λ binder).
      final Value goalWithFresh;
      final Value motiveBodyV;
      if (x is VNeutral && x.neutral is NVar) {
        final scrutLevel = (x.neutral as NVar).level;
        final freshVar = VNeutral(NVar(level));
        goalWithFresh = substNVar(s.goalType, scrutLevel, freshVar);
        motiveBodyV = goalWithFresh;
      } else {
        // Non-NVar x: quote goal at level+1 and replace x's term by
        // TBound(0) using a syntactic walk.
        final goalTerm = quote(level + 1, s.goalType);
        final xTerm = quote(level + 1, x);
        final motiveBody = _replaceTermInTerm(goalTerm, xTerm, TBound(0));
        final pY = eval(motiveBody, s.ctx.env.extend(y));
        final subMetaId = s.metas.freshTermMeta(pY, s.ctx);
        final motive = TLam(quote(level, aType), motiveBody);
        var proofTerm = TRec('Eq') as Term;
        for (final arg in [
          quote(level, aType),
          motive,
          quote(level, x),
          quote(level, y),
          p,
          TMeta(subMetaId),
        ]) {
          proofTerm = TApp(proofTerm, arg);
        }
        return TacticOk(proofTerm, s.metas, subMeta: subMetaId);
      }

      // Quote the body at level+1 so the fresh neutral → TBound(0).
      final motiveBody = quote(level + 1, motiveBodyV);
      final motive = TLam(quote(level, aType), motiveBody);

      // P y — evaluate G[x:=a] with a ↦ y.
      final pY = eval(motiveBody, s.ctx.env.extend(y));
      final subMetaId = s.metas.freshTermMeta(pY, s.ctx);
      final subMeta = TMeta(subMetaId);

      // Eq.rec A P x y p  :  P x → P y
      var proofTerm = TRec('Eq') as Term;
      for (final arg in [
        quote(level, aType),
        motive,
        quote(level, x),
        quote(level, y),
        p,
        subMeta,
      ]) {
        proofTerm = TApp(proofTerm, arg);
      }
      return TacticOk(proofTerm, s.metas, subMeta: subMetaId);
    };

/// `induction x`: produces subgoals per constructor of `x`'s type.
///
/// Looks up `x` in the context, finds its inductive data type, and
/// builds the recursor application `T.ind (λ a => G) m1 ... mn x`
/// where each `mi` is a method (constructor case) with fresh subgoal
/// metas and induction hypotheses for recursive arguments.
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

TacticFn Function(int) _inductionAt =
    (binderIdx) => (s) {
      final xType = s.ctx.lookupType(binderIdx);
      if (xType is! VData) {
        return TacticFail('induction: variable is not of an inductive type');
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
      final level = s.ctx.level;
      final goalType = s.goalType;

      // Build the motive P = λ a => goalType[x := a].
      final Value xVal = VNeutral(NVar(level - 1 - binderIdx));
      final Value motiveV;
      if (xVal is VNeutral && xVal.neutral is NVar) {
        final scrutLevel = (xVal.neutral as NVar).level;
        final freshVar = VNeutral(NVar(level));
        motiveV = substNVar(goalType, scrutLevel, freshVar);
      } else {
        return TacticFail('induction: cannot build motive');
      }
      final motiveBody = quote(level + 1, motiveV);
      final motive = TLam(quote(level, xType), motiveBody);

      // Build each constructor method and collect fresh meta IDs.
      final methodMetas = <int>[];
      final methodTerms = <Term>[];
      final paramCount = dataDecl.params.length;

      for (final ctor in dataDecl.ctors) {
        // Build the constructor applied to fresh neutrals for its args.
        var teleEnv = const ENil() as Env;
        for (var i = paramCount - 1; i >= 0; i--) {
          teleEnv = teleEnv.extend(dataArgs[i]);
        }
        final ctorArgs = <Value>[];
        final recArgPositions = <int>[];
        for (var j = 0; j < ctor.args.length; j++) {
          final argTypeV = eval(ctor.args[j].type, teleEnv);
          ctorArgs.add(VNeutral(NVar(level + j)));
          teleEnv = teleEnv.extend(VNeutral(NVar(level + j)));
          // Check if this arg is recursive (its type mentions the data).
          if (_typeMentionsData(argTypeV, dataName)) {
            recArgPositions.add(j);
          }
        }

        // P(ctor(args)) = goalType[x := ctor(args)]
        final ctorResultV = VConstr(dataName, ctor.name, ctorArgs);
        final pCtorV = substNVar(
          goalType,
          (xVal.neutral as NVar).level,
          ctorResultV,
        );

        // Method type: (args) -> (IHs) -> P(ctor(args))
        // Build the lambda chain manually, with a fresh subgoal meta
        // at the end for the body.
        final ihTypes = <Value>[];
        var methodBodyCtx = s.ctx;
        for (final j in recArgPositions) {
          final recArgValue = ctorArgs[j];
          final ihType = substNVar(
            goalType,
            (xVal.neutral as NVar).level,
            recArgValue,
          );
          ihTypes.add(ihType);
          methodBodyCtx = methodBodyCtx.extend(ihType);
        }
        final methodBodyMeta = s.metas.freshTermMeta(pCtorV, methodBodyCtx);
        methodMetas.add(methodBodyMeta);

        // Build the lambda: λ IHs... λ args... => TMeta(methodBodyMeta)
        var body = TMeta(methodBodyMeta) as Term;
        for (final ihType in ihTypes.reversed) {
          body = TLam(quote(level, ihType), body);
        }
        for (var j = ctor.args.length - 1; j >= 0; j--) {
          final argTypeV = eval(ctor.args[j].type, teleEnv);
          body = TLam(quote(level, argTypeV), body);
        }
        methodTerms.add(body);
      }

      // Build the full recursor application.
      // T.ind params P method1 ... methodN scrutinee
      var proofTerm = TRec(dataName) as Term;
      // Apply params.
      for (var i = 0; i < paramCount; i++) {
        proofTerm = TApp(proofTerm, quote(level, dataArgs[i]));
      }
      // Apply motive.
      proofTerm = TApp(proofTerm, motive);
      // Apply methods.
      for (final m in methodTerms) {
        proofTerm = TApp(proofTerm, m);
      }
      // Apply scrutinee.
      proofTerm = TApp(proofTerm, TBound(binderIdx));

      // The first subgoal meta becomes the "current" one for the next
      // tactic step.  _runTacticSteps handles the sequencing.
      return TacticOk(proofTerm, s.metas, subMeta: methodMetas.first);
    };

/// True if [v] is or contains a reference to the inductive type [dataName].
/// Used by [induction] to identify recursive constructor arguments.
bool _typeMentionsData(Value v, String dataName) {
  if (v is VData && v.name == dataName) return true;
  // Descend into function types.
  if (v is VPi) return _typeMentionsData(v.domain, dataName);
  // Descend into neutral applications (e.g. List A).
  if (v is VNeutral) {
    var cur = v.neutral;
    while (cur is NApp) cur = cur.fn;
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
    return TacticFail('auto: depth exhausted');
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

    // Build a TTop term for this lemma.
    final lemmaTerm = TTop(name);

    // Try apply on it.
    final applyResult = tacticApply(lemmaTerm)(s);
    if (applyResult is TacticOk) {
      // If no subgoals, we're done.
      if (applyResult.subMeta == null) return applyResult;

      // Otherwise, recursively auto on each subgoal.
      final metas = applyResult.metas;
      final subMetas = <int>[applyResult.subMeta!];
      // Collect all unsolved metas (apply creates one per Pi arg).
      for (var i = 0; i < metas.length; i++) {
        if (!metas.isSolved(i) && i != applyResult.subMeta) {
          subMetas.add(i);
        }
      }

      var allOk = true;
      for (final subMeta in subMetas) {
        final subState = TacticState(metas, s.ctx, subMeta, s.binderNames);
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

  // Normalise the goal and check if sides become identical.
  final goalTerm = quote(level, goalType);
  final nfVal = eval(goalTerm, s.ctx.env);
  final nfTerm = quote(level, nfVal);

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

  return TacticFail('omega: could not solve the arithmetic goal');
}

/// `simpl`: normalise the goal via `nf()` (eval then quote).
///
/// Replaces the goal with its normal form.  If the normal form differs
/// from the original, a new subgoal is created for it; otherwise a
/// `refl`-style proof closes the goal.
TacticResult simpl(TacticState s) {
  final goalType = s.goalType;
  final level = s.ctx.level;
  final origTerm = quote(level, goalType);
  final nfValue = eval(origTerm, s.ctx.env);
  final nfTerm = quote(level, nfValue);
  if (origTerm == nfTerm) {
    // Already in normal form — close via refl if Eq, else fail.
    return refl(s);
  }
  final subMetaId = s.metas.freshTermMeta(eval(nfTerm, s.ctx.env), s.ctx);
  s.metas.solve(s.currentMeta, TMeta(subMetaId));
  return TacticOk(TMeta(subMetaId), s.metas, subMeta: subMetaId);
}

/// `constructor`: apply the first matching constructor of the goal's
/// inductive type.
TacticResult tacticConstructor(TacticState s) {
  final goalType = s.goalType;
  if (goalType is! VData) {
    return TacticFail('constructor: goal is not an inductive type');
  }
  final dataName = goalType.name;
  final dataDecl = s.ctx.lookupData(dataName);
  if (dataDecl == null) {
    return TacticFail('constructor: data type "$dataName" not found');
  }
  final level = s.ctx.level;
  final dataArgs = goalType.args;

  for (final ctor in dataDecl.ctors) {
    // Build fresh metas for each constructor argument.
    var teleEnv = const ENil() as Env;
    final paramCount = dataDecl.params.length;
    for (var i = paramCount - 1; i >= 0; i--) {
      teleEnv = teleEnv.extend(dataArgs[i]);
    }
    final argMetas = <int>[];
    var ctorTerm = TConstr(dataName, ctor.name, <Term>[]) as Term;
    final argTerms = <Term>[];
    for (var j = 0; j < ctor.args.length; j++) {
      final argTypeV = eval(ctor.args[j].type, teleEnv);
      final argMetaId = s.metas.freshTermMeta(argTypeV, s.ctx);
      argMetas.add(argMetaId);
      final argTerm = TMeta(argMetaId);
      argTerms.add(argTerm);
      teleEnv = teleEnv.extend(VNeutral(NVar(level + j)));
    }
    ctorTerm = TConstr(dataName, ctor.name, argTerms);

    // Check if ctor term matches goal type.
    try {
      final ctorType = infer(s.ctx, ctorTerm);
      if (conv(s.ctx.level, ctorType, goalType, s: s) is ConvOk) {
        s.metas.solve(s.currentMeta, ctorTerm);
        // Return the first subgoal meta as current.
        final subMeta = argMetas.isNotEmpty ? argMetas.first : null;
        return TacticOk(ctorTerm, s.metas, subMeta: subMeta);
      }
    } catch (_) {}
  }
  return TacticFail('constructor: no constructor matches the goal');
}

/// `cases x`: destruct variable `x` into one subgoal per constructor.
///
/// Like [induction] but without induction hypotheses.  For each
/// constructor of `x`'s type, creates a subgoal for the goal with `x`
/// replaced by that constructor applied to fresh neutrals.
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
      final xType = s.ctx.lookupType(binderIdx);
      if (xType is! VData) {
        return TacticFail('cases: variable is not of an inductive type');
      }
      final dataName = xType.name;
      final dataArgs = xType.args;
      final dataDecl = s.ctx.lookupData(dataName);
      if (dataDecl == null) {
        return TacticFail('cases: data type "$dataName" not found');
      }
      final level = s.ctx.level;
      final goalType = s.goalType;
      final paramCount = dataDecl.params.length;

      // Build motive: P = λ a => goalType[x := a]
      final xVal = VNeutral(NVar(level - 1 - binderIdx));
      if (xVal.neutral is! NVar) {
        return TacticFail('cases: cannot build motive');
      }
      final scrutLevel = (xVal.neutral as NVar).level;
      final freshVar = VNeutral(NVar(level));
      final motiveV = substNVar(goalType, scrutLevel, freshVar);
      final motiveBody = quote(level + 1, motiveV);
      final motive = TLam(quote(level, xType), motiveBody);

      final methodMetas = <int>[];
      final methodTerms = <Term>[];

      for (final ctor in dataDecl.ctors) {
        var teleEnv = const ENil() as Env;
        for (var i = paramCount - 1; i >= 0; i--) {
          teleEnv = teleEnv.extend(dataArgs[i]);
        }
        final ctorArgs = <Value>[];
        for (var j = 0; j < ctor.args.length; j++) {
          final argTypeV = eval(ctor.args[j].type, teleEnv);
          ctorArgs.add(VNeutral(NVar(level + j)));
          teleEnv = teleEnv.extend(VNeutral(NVar(level + j)));
        }
        final ctorResultV = VConstr(dataName, ctor.name, ctorArgs);
        final pCtorV = substNVar(goalType, scrutLevel, ctorResultV);
        final methodBodyMeta = s.metas.freshTermMeta(pCtorV, s.ctx);
        methodMetas.add(methodBodyMeta);

        var body = TMeta(methodBodyMeta) as Term;
        for (var j = ctor.args.length - 1; j >= 0; j--) {
          final argTypeV = eval(ctor.args[j].type, teleEnv);
          body = TLam(quote(level, argTypeV), body);
        }
        methodTerms.add(body);
      }

      // Build the full recursor application.
      var proofTerm = TRec(dataName) as Term;
      for (var i = 0; i < paramCount; i++) {
        proofTerm = TApp(proofTerm, quote(level, dataArgs[i]));
      }
      proofTerm = TApp(proofTerm, motive);
      for (final m in methodTerms) {
        proofTerm = TApp(proofTerm, m);
      }
      proofTerm = TApp(proofTerm, TBound(binderIdx));

      return TacticOk(
        proofTerm,
        s.metas,
        subMeta: methodMetas.isNotEmpty ? methodMetas.first : null,
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
}) {
  return kernel_eval.conv(
    level,
    a,
    b,
    dataDecls: s.ctx.env.dataDecls,
    topBindings: s.ctx.env.topBindings,
  );
}

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
