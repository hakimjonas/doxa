part of 'eval.dart';

// ===========================================================================
// First-order match / reachability helpers
// ===========================================================================

/// Decide whether constructor [ctor] of inductive [dataDecl] is
/// reachable at a match site whose scrutinee has index values
/// [scrutineeIndices].
///
/// The check is **first-order ctor-head clash only**, the honest
/// For each index position, evaluate the
/// ctor's `resultIndices[i]` under a telescope env containing
/// `paramsV` plus fresh neutrals for the ctor's own arg binders,
/// then compare pairwise with `scrutineeIndices[i]` using
/// [_firstOrderUnifiable]:
///
///   * Two [VConstr] heads with different ctor names → IMPOSSIBLE,
///     so the whole ctor is unreachable. Returns false.
///   * Anything involving a free variable, a stuck computation, or
///     compatible ctor heads → POSSIBLE. Returns true (conservative).
///
/// This rule admits the classic `Vec[A] (succ n)` / `vnil : Vec[A]
/// zero` case (succ vs zero at index position 0 → IMPOSSIBLE) and
/// rejects any case that needs non-trivial unification. A "POSSIBLE
/// but actually unreachable" case can be worked around by adding an
/// explicit unreachable arm with a placeholder body.
bool _ctorReachable(
  DataDecl dataDecl,
  CtorDecl ctor,
  List<Value> paramsV,
  List<Value> scrutineeIndices,
  int level,
) {
  if (ctor.resultIndices.length != scrutineeIndices.length) {
    return true;
  }
  var teleEnv = const ENil() as Env;
  for (var i = paramsV.length - 1; i >= 0; i--) {
    teleEnv = teleEnv.extend(paramsV[i]);
  }
  for (var j = 0; j < ctor.args.length; j++) {
    teleEnv = teleEnv.extend(VNeutral(NVar(level + j)));
  }
  for (var i = 0; i < ctor.resultIndices.length; i++) {
    final ctorIdxV = eval(ctor.resultIndices[i], teleEnv);
    if (!_firstOrderUnifiable(scrutineeIndices[i], ctorIdxV, level)) {
      return false;
    }
  }
  return true;
}

/// First-order ctor-head unification check used by
/// [_ctorReachable]. Returns true iff the two values *might* be
/// equal under some substitution (conservative); false iff they
/// have structurally incompatible ctor heads.
///
/// [outerLevel] is the context level at the match site.  Telescope-
/// fresh neutrals (levels >= [outerLevel]) cannot unify with a
/// constructor because they represent opaque constructor arguments;
/// scrutinee neutrals (levels < [outerLevel]) are rigid variables
/// that *could* be instantiated to the constructor.
bool _firstOrderUnifiable(Value a, Value b, int outerLevel) {
  if (a is VConstr && b is VConstr) {
    if (a.dataName != b.dataName || a.ctorName != b.ctorName) {
      return false;
    }
    if (a.args.length != b.args.length) return false;
    for (var i = 0; i < a.args.length; i++) {
      if (!_firstOrderUnifiable(a.args[i], b.args[i], outerLevel)) return false;
    }
    return true;
  }
  if (a is VConstr && _isTelescopeNeutral(b, outerLevel)) return false;
  if (b is VConstr && _isTelescopeNeutral(a, outerLevel)) return false;
  return true;
}

/// Returns true iff [v] is a VNeutral NVar at a level >= [outerLevel],
/// i.e. a fresh neutral injected into the telescope env for coverage
/// checking.  Such neutrals stand for opaque ctor arguments and
/// cannot be structurally equal to a constructor.
bool _isTelescopeNeutral(Value v, int outerLevel) {
  if (v is VNeutral && v.neutral is NVar) {
    return (v.neutral as NVar).level >= outerLevel;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Recursor type synthesis and ι-reduction helpers
// ---------------------------------------------------------------------------

/// The saturated-spine arity of the recursor for [d].
///
/// Shape: `[params..., motive, indices..., method_0, ..., method_{n-1},
/// scrutinee]`.
int _recursorArity(DataDecl d) =>
    d.params.length + 1 + d.ctors.length + d.indices.length + 1;

// ===========================================================================
// bodyIsNormal fast-path invariant
// ===========================================================================

/// Return the maximum immediate [TBound] index in [t] at this level.
///
/// Used to validate `bodyIsNormal` closures. Only inspects the term
/// structure at the current binder level — does NOT recurse into
/// bodies of TLam/TPi/TMatch/TLet (those have their own binder scopes).
int _maxTBoundIndex(Term t, [int depth = 0]) {
  var maxIdx = 0;
  final work = <(Term, int)>[(t, depth)];
  while (work.isNotEmpty) {
    final (node, d) = work.removeLast();
    switch (node) {
      case TBound(:final index):
        maxIdx = max(maxIdx, index + d);
      case TApp(:final fn, :final arg):
        work.add((fn, d));
        work.add((arg, d));
      case TLam(:final domain):
      case TPi(:final domain):
        work.add((domain, d));
      case TMatch(:final scrutinee, :final motive):
        work.add((scrutinee, d));
        if (motive != null) work.add((motive, d));
      case TLet(:final domain, :final bound):
        work.add((domain, d));
        work.add((bound, d));
      case TType() ||
          TProp() ||
          TSProp() ||
          TFree() ||
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
  return maxIdx;
}
