/// Defunctionalized interpreter: evaluation, quoting, conversion, and
/// bidirectional type checking, all sharing one driver loop.
///
/// Implements the semantics described in `SPEC.md` §4 and §3.3 without
/// using the host call stack for semantic recursion. See SPEC §4.5 for
/// the rationale: Church-encoded programs in pure CoC routinely produce
/// β-reduction chains and nested-binder structures that exceed any
/// fixed-size call stack, and a [StackOverflowError] would violate SPEC
/// §6's error-reporting contract. The checker (which consumes the same
/// terms a parser produces, including Church-encoded terms) is held to
/// the same invariant.
///
/// Architecture: **one driver loop** ([_drive]) dispatches over a sealed
/// [_Step] (evaluate a term, apply two values, quote a value, conv two
/// values, check/infer a term, yield a value/term/conv-result) and an
/// explicit control stack of [_Frame]s. Eval, apply, quote, conv, check,
/// and infer all share the same driver and the same stack.
///
/// Invariant: **no function in this file calls itself transitively, and
/// no function in this file calls any other semantic function.** The only
/// Dart calls are [_drive]'s single entry from each public API and the
/// pattern-match dispatch inside [_drive]'s `while (true)` loop. Therefore
/// the host call stack is bounded by a small constant, independent of
/// β-reduction depth, binder nesting, neutral-spine length, conversion
/// mismatch depth, OR source term depth.
///
/// Public entry points:
///
///   * [eval]: evaluate a [Term] in an [Env] to a [Value]
///   * [apply]: apply one [Value] to another
///   * [quote]: reify a [Value] back to a [Term] at a given context depth
///   * [nf]: normal form: a single driver run that evaluates and then
///     quotes, with no intermediate Dart frame between the two phases
///   * [conv]: definitional equality of two [Value]s at a given depth,
///     returning a [ConvResult] that carries the first-found mismatch on
///     failure (SPEC §4.3, strict on universe levels in v1)
///   * [infer]: bidirectional type inference: produce the type [Value]
///     of a term under a [Ctx], throwing [DoxaCheckError] on failure
///   * [check]: bidirectional type checking against an expected type,
///     throwing [DoxaCheckError] on mismatch
///
/// Invariants upheld by callers:
///
///   * [eval] is only called on de-Bruijn-only terms. [TFree] reaching
///     evaluation throws [StateError]: indicates an elaborator bug, not
///     a user error.
///   * [apply] is only called on a function-shaped head ([VLam] or
///     [VNeutral]). A non-function head throws [StateError]: indicates
///     a type-checker bug, not a user error.
///   * [quote] uses de Bruijn *levels* (counted from the root). The
///     `level` argument counts how many binders already surround the
///     value being quoted.
///   * [conv] does **not** compare [VLam] domain annotations. The domain
///     is only present for [quote]'s reconstruction; the type of a lambda
///     comes from its enclosing Pi via bidirectional checking, not from
///     the annotation (SPEC §4.3).
///   * [infer] / [check] receive kernel terms with no [TFree] (the
///     elaborator closes free names before handing off). A [TFree]
///     reaching either throws [UnexpectedFree].
library;

import 'check.dart';
import 'ctx.dart';
import 'env.dart';
import 'meta.dart';
import 'registry.dart';
import 'term.dart';
import 'value.dart';

// -------------------------------------------------------------------------
// Level constants (universe polymorphism).
// -------------------------------------------------------------------------
const _l0 = LLevel(0);
const _l1 = LLevel(1);
const _vType0 = VType(_l0);
const _vType1 = VType(_l1);

// ===========================================================================
// Conversion result.
// ===========================================================================

/// The outcome of a definitional-equality check.
sealed class ConvResult {
  /// Base constructor.
  const ConvResult();

  /// True if the two values converted.
  bool get isOk => this is ConvOk;
}

/// Values converted successfully.
final class ConvOk extends ConvResult {
  /// The singleton success result.
  const ConvOk();
}

/// Values failed to convert. [got] and [expected] are the innermost
/// two sub-values at which the comparison first diverged. "Innermost"
/// because the driver delivers the deepest mismatch upward through any
/// outer conv frames unchanged, outer frames do not wrap or re-describe
/// the mismatch, so what the caller sees is the actual diverging pair.
///
/// A higher layer produces human-readable diagnostics by [quote]-ing
/// both values at the originating depth.
final class ConvMismatch extends ConvResult {
  /// The value that was produced / inferred.
  final Value got;

  /// The value that was expected.
  final Value expected;

  /// Creates a conversion mismatch.
  const ConvMismatch(this.got, this.expected);
}

/// The canonical success value, reused to avoid per-call allocation.
const ConvOk _ok = ConvOk();

// ===========================================================================
// Steps: what the driver is currently doing.
// ===========================================================================

/// A single step of the machine.
sealed class _Step {
  const _Step();
}

/// Evaluate [term] in [env]; yields a [Value].
final class _Eval extends _Step {
  final Term term;
  final Env env;
  const _Eval(this.term, this.env);
}

/// Apply [fn] to [arg]; yields a [Value].
final class _Apply extends _Step {
  final Value fn;
  final Value arg;
  const _Apply(this.fn, this.arg);
}

/// Quote [value] at [level]; yields a [Term].
final class _Quote extends _Step {
  final Value value;
  final int level;
  const _Quote(this.value, this.level);
}

/// Deliver [value] to the pending frame (or return it if the stack is empty).
final class _YieldV extends _Step {
  final Value value;
  const _YieldV(this.value);
}

/// Deliver [term] to the pending frame (or return it if the stack is empty).
final class _YieldT extends _Step {
  final Term term;
  const _YieldT(this.term);
}

/// Compare [a] and [b] for definitional equality at context depth [level];
/// yields a [ConvResult].
final class _Conv extends _Step {
  final Value a;
  final Value b;
  final int level;
  const _Conv(this.a, this.b, this.level);
}

/// Check that [got] is a subtype of [expected] at context depth [level];
/// yields a [ConvResult] (reusing the same result type because the
/// diagnostic shape is identical).
///
/// Subtype differs from [_Conv] only at universes (`Type n ≤ Type m`
/// iff `n ≤ m`) and recurses through Pi contravariantly in the domain
/// and covariantly in the codomain. Everywhere else it is strict
/// equality (via [_Conv]), CIC's `≤` is a small relaxation of `≡`,
/// not a general subtyping relation.
///
/// Used at the Conv rule in the checker and at application
/// argument-against-domain checks (SPEC §8.3).
final class _Subtype extends _Step {
  final Value got;
  final Value expected;
  final int level;
  const _Subtype(this.got, this.expected, this.level);
}

/// Deliver [result] to the pending frame (or return it if the stack is
/// empty).
final class _YieldC extends _Step {
  final ConvResult result;
  const _YieldC(this.result);
}

/// Infer the type of [term] under [ctx]; yields a [Value] (the inferred
/// type) on the [_YieldV] channel. Throws a [DoxaCheckError] on failure.
final class _Infer extends _Step {
  final Ctx ctx;
  final Term term;
  const _Infer(this.ctx, this.term);
}

/// Check that [term] has type [expected] under [ctx]; on success yields
/// the [expected] value on the [_YieldV] channel (a sentinel, callers
/// that don't care about the result value can discard it). Throws a
/// [DoxaCheckError] on mismatch.
final class _Check extends _Step {
  final Ctx ctx;
  final Term term;
  final Value expected;
  const _Check(this.ctx, this.term, this.expected);
}

// ===========================================================================
// Frames: what to do when a value or term is delivered.
// ===========================================================================

/// A continuation on the control stack.
sealed class _Frame {
  const _Frame();
}

// --- Value-consuming frames (fired when current step is [_YieldV]) ---

/// After the function position of a [TApp] is evaluated, evaluate the
/// argument in [env] and then apply.
final class _EvalArg extends _Frame {
  final Term arg;
  final Env env;
  const _EvalArg(this.arg, this.env);
}

/// After the argument of a [TApp] is evaluated, apply [fn] to it.
final class _ApplyFn extends _Frame {
  final Value fn;
  const _ApplyFn(this.fn);
}

/// After a function value is produced (e.g. by forcing a [VDelayed]),
/// apply it to the already-known [arg]. This is the mirror of
/// [_ApplyFn]: there the function is known and the arg is being
/// computed; here the arg is known and the function is being computed.
/// Used by [VDelayed] re-application so the forced head is applied to
/// the pending argument in the correct order (`forced arg`, not
/// `arg forced`).
final class _ApplyArg extends _Frame {
  final Value arg;
  const _ApplyArg(this.arg);
}

/// After a [TLam]'s domain is evaluated, wrap with [env] and [body]
/// into a [VLam].
final class _BuildLam extends _Frame {
  final Env env;
  final Term body;
  final String? nameHint;
  final Icit icit;
  const _BuildLam(this.env, this.body, this.nameHint, this.icit);
}

/// After a [TPi]'s domain is evaluated, wrap with [env] and [codomain]
/// into a [VPi].
final class _BuildPi extends _Frame {
  final Env env;
  final Term codomain;
  final String? nameHint;
  final Icit icit;
  const _BuildPi(this.env, this.codomain, this.nameHint, this.icit);
}

/// After a [TLet]'s bound expression is evaluated, extend [env] with
/// the value and evaluate [body] under the extended env. Does NOT
/// produce a VLet, eval inlines the let entirely.
final class _EvalLetBody extends _Frame {
  final Env env;
  final Term body;
  final bool isRec;
  final String? name;
  final int? decreasingArg;
  final int? arity;
  const _EvalLetBody(
    this.env,
    this.body, {
    this.isRec = false,
    this.name,
    this.decreasingArg,
    this.arity,
  });
}

/// Fires after a [TMatch]'s scrutinee is evaluated. `value` is the
/// scrutineeV. Schedules motive evaluation (if any) followed by
/// [_MatchDispatch]. If [motive] is null, goes straight to dispatch
/// with a null motiveV.
final class _MatchAfterScrutinee extends _Frame {
  final Term? motive;
  final List<TMatchCase> cases;
  final Env env;
  const _MatchAfterScrutinee(this.motive, this.cases, this.env);
}

/// Fires after the motive is evaluated (stuck scrutinee with explicit
/// motive path only). `value` is the motiveV; the handler builds the
/// stuck [VMatch]. For the canonical-scrutinee and null-motive paths,
/// [_MatchAfterScrutinee] handles the dispatch directly without
/// allocating this frame.
final class _MatchDispatch extends _Frame {
  final Value scrutineeV;
  final List<TMatchCase> cases;
  final Env env;
  const _MatchDispatch(this.scrutineeV, this.cases, this.env);
}

/// Progressively build a [VData] by evaluating its args left-to-right.
///
/// Index-based accumulator: [collected] is mutated in place as each
/// arg's value is delivered, and [nextIndex] advances along [args]
/// (the original, shared arg list). Yields the final [VData] when
/// `nextIndex == args.length` after the append. O(N) total, matching
/// the VNeutral spine pattern in conv.
final class _BuildData extends _Frame {
  final String name;
  final List<Value> collected;
  final List<Term> args;
  final int nextIndex;
  final Env env;
  const _BuildData(
    this.name,
    this.collected,
    this.args,
    this.nextIndex,
    this.env,
  );
}

/// Progressively quote a [VData]'s args. T-consuming: when the current
/// arg's Term is delivered, append to [collected] in place and advance
/// `nextIndex` along the original [args] list.
final class _QDataArg extends _Frame {
  final String name;
  final List<Term> collected;
  final List<Value> args;
  final int nextIndex;
  final int level;
  const _QDataArg(
    this.name,
    this.collected,
    this.args,
    this.nextIndex,
    this.level,
  );
}

/// Progressively quote a [VConstr]'s args (mirror of [_QDataArg]).
final class _QConstrArg extends _Frame {
  final String dataName;
  final String ctorName;
  final List<Term> collected;
  final List<Value> args;
  final int nextIndex;
  final int level;
  const _QConstrArg(
    this.dataName,
    this.ctorName,
    this.collected,
    this.args,
    this.nextIndex,
    this.level,
  );
}

/// After the current delivered value `f` is yielded, apply it to
/// [args]`[nextIndex]` and continue (via another _ApplyChain if more
/// args remain, or yield directly when done).
///
/// Used by ι-reduction to drive a sequence of applications of the
/// selected method to the ctor's non-param args (interleaved with
/// recursive-call values). Each step runs through the driver, so
/// subsequent ι-reductions on returned VRec values unfold naturally.
final class _ApplyChain extends _Frame {
  /// The full argument list to apply, left-to-right.
  final List<Value> args;

  /// The index of the next arg to apply (guaranteed in range when
  /// this frame is pushed).
  final int nextIndex;

  const _ApplyChain(this.args, this.nextIndex);
}

/// Progressively build a [VConstr] by evaluating its args
/// left-to-right. Same index-based pattern as [_BuildData].
final class _BuildConstr extends _Frame {
  final String dataName;
  final String ctorName;
  final List<Value> collected;
  final List<Term> args;
  final int nextIndex;
  final Env env;
  const _BuildConstr(
    this.dataName,
    this.ctorName,
    this.collected,
    this.args,
    this.nextIndex,
    this.env,
  );
}

/// After a [TQuot]'s carrier is evaluated, evaluate the relation and
/// produce [VQuot].
final class _EvalQuot extends _Frame {
  final Term relation;
  final Env env;
  final Value? carrier;
  const _EvalQuot(this.relation, this.env, [this.carrier]);
}

/// After a [TQuotMk]'s arg is evaluated, produce [VQuotMk].
final class _EvalQuotMk extends _Frame {
  const _EvalQuotMk();
}

/// After a [TQuotLift]'s arguments are evaluated, produce [VQuotLift],
/// or ι-reduce when the quot is [VQuotMk].
final class _EvalQuotLift extends _Frame {
  final Term fnTerm;
  final Term proofTerm;
  final Env env;
  final Value? quot;
  final Value? fn;
  const _EvalQuotLift(
    this.fnTerm,
    this.proofTerm,
    this.env, [
    this.quot,
    this.fn,
  ]);
}

/// Eval a [TProj] expression: evaluate the expr, then project the field.
final class _EvalProj extends _Frame {
  final String fieldName;
  const _EvalProj(this.fieldName);
}

/// After inferring the type of a [TProj]'s qualifier, look up the
/// field's declared type from the record's constructor.
final class _InferProjFieldType extends _Frame {
  final String fieldName;
  const _InferProjFieldType(this.fieldName);
}

/// Cross-mode frame. When a value is delivered, transition to quote mode
/// at the captured [level]. Used to bridge from eval back to quote when
/// a closure has just been opened for quote's benefit.
final class _QuoteAt extends _Frame {
  final int level;
  const _QuoteAt(this.level);
}

/// Cross-mode. When a value is delivered, stash it as the "got" side,
/// schedule applying [rightV] to the same [applied] argument to get the
/// "expected" side, and then conv at [level]. Produces:
///
///   [_ConvPairLeft] → pop → _Apply(rightV, applied) → [_ConvPairRight] → pop
///   → _Conv(stashedLeft, deliveredRight, level)
final class _ConvPairLeft extends _Frame {
  final Value rightV;
  final Value applied;
  final int level;

  /// True means "after pairing, do subtype"; false means conv.
  final bool asSubtype;
  const _ConvPairLeft(
    this.rightV,
    this.applied,
    this.level, {
    this.asSubtype = false,
  });
}

/// Sister frame of [_ConvPairLeft]: when the second value arrives, pair it
/// with [stashedLeft] and kick off a _Conv.
final class _ConvPairRight extends _Frame {
  final Value stashedLeft;
  final int level;

  /// True means "finish with subtype"; false means conv.
  final bool asSubtype;
  const _ConvPairRight(this.stashedLeft, this.level, {this.asSubtype = false});
}

// --- Conv-sequencing frames (fired when current step is [_YieldC]) ---

/// Sequential AND: if the conv just delivered is Ok, run a second _Conv
/// [then]; otherwise propagate the mismatch unchanged.
///
/// Used for Pi-Pi comparison (first compare domains, then compare opened
/// codomains) and for neutral spine comparison.
final class _ConvThen extends _Frame {
  final _Conv then;
  const _ConvThen(this.then);
}

/// Sequential AND with cross-mode bridge: if the conv just delivered is
/// Ok, apply both [leftV] and [rightV] to a fresh neutral at [level] and
/// compare the resulting bodies at [level]+1. Otherwise propagate the
/// mismatch unchanged.
///
/// Used for:
///   * Pi-Pi codomain descent (conv: both sides leftV/rightV wrap the
///     original Pi's codomain closure; [asSubtype] false).
///   * Pi-Pi subtype codomain descent ([asSubtype] true, the final
///     comparison is [_Subtype] covariantly).
///   * VLam-VLam body descent.
final class _ConvThenOpen extends _Frame {
  final Value leftV;
  final Value rightV;
  final int level;

  /// True means "after opening, compare bodies with _Subtype (covariant)";
  /// false means "with _Conv (strict)."
  final bool asSubtype;
  const _ConvThenOpen(
    this.leftV,
    this.rightV,
    this.level, {
    this.asSubtype = false,
  });
}

// --- Check/infer frames (value-consuming unless noted) ---

/// After inferring the domain's type of a [TPi]: require VType, stash
/// its level [n], and schedule evaluation of the domain so we can
/// extend the context for the codomain.
final class _InferPiHaveDomType extends _Frame {
  final Ctx ctx;
  final Term dom;
  final Term cod;
  const _InferPiHaveDomType(this.ctx, this.dom, this.cod);
}

/// After evaluating the domain of a [TPi]: extend the context with the
/// domain value and schedule inferring the codomain. The stashed [n] is
/// the domain's universe level.
final class _InferPiHaveDomV extends _Frame {
  final Ctx ctx;
  final Term cod;

  /// Domain sort (Prop or Type n).
  final _Sort domSort;
  const _InferPiHaveDomV(this.ctx, this.cod, this.domSort);
}

/// After inferring the codomain's type of a [TPi]: require VType, combine
/// with stashed [n] into VType(max n m) and yield.
final class _InferPiHaveCodType extends _Frame {
  /// Stashed domain sort (from the prior dom-type check).
  final _Sort domSort;
  const _InferPiHaveCodType(this.domSort);
}

/// After inferring the function type of a [TApp]: require VPi, schedule
/// checking the argument against the domain, and remember the codomain
/// closure plus the evaluation env for the argument.
final class _InferAppHaveFnType extends _Frame {
  final Ctx ctx;
  final Term arg;
  const _InferAppHaveFnType(this.ctx, this.arg);
}

/// After checking the argument of a [TApp] succeeded: schedule evaluating
/// the argument in [env], carrying [cod] so we can apply it to the value.
final class _InferAppHaveCheck extends _Frame {
  final Closure cod;
  final Term arg;
  final Env env;
  const _InferAppHaveCheck(this.cod, this.arg, this.env);
}

/// After evaluating the argument of a [TApp]: evaluate the codomain
/// closure's body in its env extended with the argument value. The
/// resulting value yields as the App's inferred type.
final class _InferAppHaveArgV extends _Frame {
  final Closure cod;
  const _InferAppHaveArgV(this.cod);
}

/// After inferring the domain annotation's type on a [TLam]: require
/// VType, schedule evaluating the annotation to form the extended
/// context for inferring the body.
final class _InferLamHaveDomType extends _Frame {
  final Ctx ctx;
  final Term dom;
  final Term body;
  final String? nameHint;
  const _InferLamHaveDomType(this.ctx, this.dom, this.body, this.nameHint);
}

/// After evaluating the domain annotation of a [TLam]: extend the ctx
/// and schedule inferring the body. The body's level is ctx.level+1.
final class _InferLamHaveDomV extends _Frame {
  final Ctx ctx;
  final Term body;
  final String? nameHint;
  const _InferLamHaveDomV(this.ctx, this.body, this.nameHint);
}

/// After inferring the body type of a [TLam]: schedule quoting the body
/// type at [bodyLevel] so we can build a Pi with the body-as-closure.
/// The outer [env] and evaluated domain [domV] will be captured by the
/// Pi's closure.
final class _InferLamHaveBodyType extends _Frame {
  final Env env;
  final Value domV;
  final int bodyLevel;
  final String? nameHint;
  const _InferLamHaveBodyType(
    this.env,
    this.domV,
    this.bodyLevel,
    this.nameHint,
  );
}

/// T-consuming frame. After quoting the body type of a [TLam]: build
/// and yield VPi(domV, Closure(env, bodyTerm)).
final class _InferLamHaveBodyTerm extends _Frame {
  final Env env;
  final Value domV;
  final String? nameHint;
  const _InferLamHaveBodyTerm(this.env, this.domV, this.nameHint);
}

// --- let inference frames ---

/// After inferring the domain's type on a TLet: require VType/VProp,
/// then evaluate the domain to a value.
final class _InferLetHaveDomType extends _Frame {
  final Ctx ctx;
  final Term domain;
  final Term bound;
  final Term body;
  final String? nameHint;
  const _InferLetHaveDomType(
    this.ctx,
    this.domain,
    this.bound,
    this.body,
    this.nameHint,
  );
}

/// After evaluating the domain of a TLet: check the bound expression
/// against it, then evaluate the bound expression to a value.
final class _InferLetHaveDomV extends _Frame {
  final Ctx ctx;
  final Term bound;
  final Term body;
  final String? nameHint;
  const _InferLetHaveDomV(this.ctx, this.bound, this.body, this.nameHint);
}

/// After `check(ctx, bound, domainV)` succeeds: evaluate the bound
/// expression to a value so we can bind it in the ctx.
final class _InferLetHaveCheck extends _Frame {
  final Ctx ctx;
  final Term bound;
  final Term body;
  final Value domainV;
  final String? nameHint;
  const _InferLetHaveCheck(
    this.ctx,
    this.bound,
    this.body,
    this.domainV,
    this.nameHint,
  );
}

/// After evaluating the bound expression of a TLet: extend the ctx
/// with (domainV, boundV) and infer the body's type.
final class _InferLetHaveBoundV extends _Frame {
  final Ctx ctx;
  final Term body;
  final Value domainV;
  const _InferLetHaveBoundV(this.ctx, this.body, this.domainV);
}

// --- infer(TData) / infer(TConstr) sequencing ---

/// After a TData or TConstr's arg[nextIndex] has passed `_Check`, evaluate
/// it in the caller's ctx.env so the resulting value can extend the
/// telescope environment for checking arg[nextIndex + 1].
///
/// Holds everything needed to continue processing: the data decl (and
/// optional ctor decl if this is a TConstr inference), the argument
/// list, the index of the arg just checked, the running telescope env
/// (built from the outer scope plus all previously-evaluated args), and
/// the combined telescope types of the head being applied.
final class _InferIndAfterCheck extends _Frame {
  /// The inductive type being inferred.
  final DataDecl dataDecl;

  /// The constructor being inferred (null when inferring a TData head).
  final CtorDecl? ctorDecl;

  /// The caller's ctx, for evaluating args in the outer env and
  /// scheduling further checks under ctx-extending frames.
  final Ctx ctx;

  /// The full argument list (all of them; not sublist-copied).
  final List<Term> args;

  /// The index of the argument that was just checked.
  final int index;

  /// The telescope env: outer ENil extended by each previously-evaluated
  /// arg. At index=0's _InferIndAfterCheck fire, this is ENil; at index=k's
  /// fire, it has values for args[0..k-1]. `Env` because telescope types
  /// are elaborated under the telescope binders (not the caller's).
  final Env teleEnv;

  const _InferIndAfterCheck({
    required this.dataDecl,
    required this.ctorDecl,
    required this.ctx,
    required this.args,
    required this.index,
    required this.teleEnv,
  });
}

/// After `_InferIndAfterCheck` scheduled `_Eval(args[index], ctx.env)`
/// and the value is produced, extend the telescope env with it and
/// either schedule the next arg's check or produce the final result.
final class _InferIndAfterEval extends _Frame {
  final DataDecl dataDecl;
  final CtorDecl? ctorDecl;
  final Ctx ctx;
  final List<Term> args;
  final int index;
  final Env teleEnv;

  const _InferIndAfterEval({
    required this.dataDecl,
    required this.ctorDecl,
    required this.ctx,
    required this.args,
    required this.index,
    required this.teleEnv,
  });
}

/// After inferring the annotation's type on a TLam being check-ed against
/// a VPi: require the annotation type to be a sort, then schedule
/// evaluating the annotation term so we can compare it contravariantly
/// against the Pi's domain (see [_CheckLamAnnotV]).
final class _CheckLamAnnotDone extends _Frame {
  final Ctx ctx;
  final Term annotTerm;
  final Term body;
  final Value piDom;
  final Closure piCod;
  final Value expected;
  const _CheckLamAnnotDone(
    this.ctx,
    this.annotTerm,
    this.body,
    this.piDom,
    this.piCod,
    this.expected,
  );
}

/// After evaluating the TLam's annotation to a value: subtype-check that
/// the Pi's domain is ≤ the annotation (contravariant). On success,
/// descend into the body.
///
/// This is the cumulativity-aware check that v1 (strict conv) skipped.
/// Without it, a lambda with annotation `Type 0` would incorrectly
/// check against `(Type 2 -> ...)`, the caller would pass a Type-2
/// value, but the body assumes the bound variable has type Type 0.
final class _CheckLamAnnotV extends _Frame {
  final Ctx ctx;
  final Term body;
  final Value piDom;
  final Closure piCod;
  final Value expected;
  const _CheckLamAnnotV(
    this.ctx,
    this.body,
    this.piDom,
    this.piCod,
    this.expected,
  );
}

/// C-consuming frame: after the subtype(piDom, annotV) check, if OK,
/// descend into the lambda's body. Otherwise propagate the mismatch
/// as a TypeMismatch error.
final class _CheckLamAnnotSubtype extends _Frame {
  final Ctx ctx;
  final Term body;
  final Value piDom;
  final Closure piCod;
  final Value annotV;
  final Value expected;
  const _CheckLamAnnotSubtype(
    this.ctx,
    this.body,
    this.piDom,
    this.piCod,
    this.annotV,
    this.expected,
  );
}

/// After opening the Pi's codomain via apply: descend into the body with
/// the extended ctx, checking it against the opened codomain. On success
/// yield the original [expected] (check-success sentinel).
final class _CheckLamOpenedCod extends _Frame {
  final Ctx bodyCtx;
  final Term body;
  final Value expected;
  const _CheckLamOpenedCod(this.bodyCtx, this.body, this.expected);
}

/// After an inferred type has been produced during the fallback of
/// [_Check]: schedule a [_Conv] against the expected type. Stash [got]
/// to include in a potential mismatch error.
final class _CheckFallbackGotType extends _Frame {
  final int level;
  final Value expected;
  const _CheckFallbackGotType(this.level, this.expected);
}

/// C-consuming frame. After the conv check in [_Check]'s fallback: if
/// Ok, yield [expected]; otherwise throw [TypeMismatch] with [got] and
/// [expected] and the inner conv mismatch.
///
/// [level] is the Ctx level at which the fallback ran; threaded into
/// the TypeMismatch so the renderer can seed its outer-binder scope
/// correctly (SPEC §6.2 tier 1, prevents `?-N` negative-index
/// placeholders in rendered errors).
final class _CheckFallbackConvResult extends _Frame {
  final Value got;
  final Value expected;
  final int level;
  const _CheckFallbackConvResult(this.got, this.expected, this.level);
}

/// Replace the delivered value with [expected] and yield.
///
/// When a nested `_Check` finishes, its success yield is its own
/// `expected`. But the outer caller of the current `_Check` wants the
/// outer `expected` as the check-success sentinel. This frame forces
/// the substitution.
final class _CheckSuccessYield extends _Frame {
  final Value expected;
  const _CheckSuccessYield(this.expected);
}

// --- match check frames ---

/// After evaluating an explicit motive in infer mode, re-dispatch as
/// a check of the match against the motive value. `value` on entry is
/// the motiveV; the check's success yields that same motiveV which
/// is what the caller's infer chain expects.
final class _InferMatchAfterMotive extends _Frame {
  final Ctx ctx;
  final TMatch matchTerm;
  const _InferMatchAfterMotive(this.ctx, this.matchTerm);
}

/// After inferring the scrutinee's type (yielded as `value`), dispatch
/// to arm-by-arm checking.
final class _CheckMatchScrutineeType extends _Frame {
  final Ctx ctx;
  final TMatch matchTerm;
  final Value expected;
  const _CheckMatchScrutineeType({
    required this.ctx,
    required this.matchTerm,
    required this.expected,
  });
}

/// Fires after a match arm has been checked. Advance to the next arm
/// or succeed. `value` is the check-success sentinel from the arm.
final class _CheckMatchArm extends _Frame {
  final Ctx ctx;
  final TMatch matchTerm;
  final DataDecl dataDecl;

  /// The evaluated param values from the scrutinee's inferred type.
  final List<Value> paramsV;

  /// The evaluated index values from the scrutinee's inferred type
  /// (threaded so the next-arm step can apply first-order refinement
  /// against the ctor's resultIndices).
  final List<Value> indicesV;

  /// The index of the arm we just checked.
  final int armIndex;
  final Value expected;
  const _CheckMatchArm({
    required this.ctx,
    required this.matchTerm,
    required this.dataDecl,
    required this.paramsV,
    required this.indicesV,
    required this.armIndex,
    required this.expected,
  });
}

// --- Quotient inference frames ---

/// After inferring a [TQuot]'s carrier type, check it's a sort and eval the carrier.
final class _InferQuotHaveCarrierType extends _Frame {
  final Ctx ctx;
  final Term carrier;
  final Term relation;
  const _InferQuotHaveCarrierType(this.ctx, this.carrier, this.relation);
}

/// After evaluating a [TQuot]'s carrier, quote it and check the relation.
final class _InferQuotHaveCarrierV extends _Frame {
  final Ctx ctx;
  final Term relation;
  final _Sort carrierSort;
  const _InferQuotHaveCarrierV(this.ctx, this.relation, this.carrierSort);
}

/// After quoting the carrier (term arrived in _YieldT), build expected rel type and check.
final class _InferQuotAfterCarrierQuote extends _Frame {
  final Ctx ctx;
  final Term relation;
  final _Sort carrierSort;
  const _InferQuotAfterCarrierQuote(this.ctx, this.relation, this.carrierSort);
}

/// After checking relation, yield the result sort.
final class _InferQuotAfterRelationCheck extends _Frame {
  final _Sort carrierSort;
  const _InferQuotAfterRelationCheck(this.carrierSort);
}

/// After inferring [TQuotLift]'s quot type, check it's a VQuot.
final class _InferQuotLiftHaveQuotType extends _Frame {
  final Ctx ctx;
  final Term fn;
  const _InferQuotLiftHaveQuotType(this.ctx, this.fn);
}

/// After inferring [TQuotLift]'s fn type, check it's VPi and open codomain.
final class _InferQuotLiftHaveFnType extends _Frame {
  final Ctx ctx;
  final Value quotA;
  final Value quotR;
  const _InferQuotLiftHaveFnType(this.ctx, this.quotA, this.quotR);
}

/// After checking proof, yield the opened codomain value.
final class _InferQuotLiftAfterProof extends _Frame {
  const _InferQuotLiftAfterProof();
}

// --- Term-consuming frames (fired when current step is [_YieldT]) ---

/// After a Pi's domain is quoted, open the codomain closure (by evaluating
/// the body in env extended with a fresh neutral at [level]) and quote the
/// result at [level]+1. The newly-quoted domain is carried into [_QPiBuild]
/// on the stack before eval is invoked.
final class _QPiCod extends _Frame {
  final Closure codomain;
  final int level;
  final String? nameHint;
  final Icit icit;
  const _QPiCod(this.codomain, this.level, this.nameHint, this.icit);
}

/// After a Pi's codomain has been quoted, combine with the saved [domain]
/// into a [TPi].
final class _QPiBuild extends _Frame {
  final Term domain;
  final String? nameHint;
  final Icit icit;
  const _QPiBuild(this.domain, this.nameHint, this.icit);
}

/// Fast-path build for quoting a Pi whose codomain closure was marked
/// `bodyIsNormal` and level-aligned. Skip the open/eval/quote round-trip
/// on the codomain and reuse [codomainTerm] directly after the domain
/// has been quoted.
final class _QPiBuildNormal extends _Frame {
  final Term codomainTerm;
  final String? nameHint;
  final Icit icit;
  const _QPiBuildNormal(this.codomainTerm, this.nameHint, this.icit);
}

/// After quoting a [VMatch]'s scrutinee, schedule motive quoting;
/// `value` on entry = scrutineeT. If [motiveV] is null, skip motive
/// quoting and emit a `TMatch` with null motive directly.
final class _QMatchAfterScrutinee extends _Frame {
  final Value? motiveV;
  final List<TMatchCase> caseTerms;
  final int level;
  const _QMatchAfterScrutinee(this.motiveV, this.caseTerms, this.level);
}

/// After quoting a [VMatch]'s motive, assemble the final `TMatch`.
/// `value` on entry = motiveT; the scrutineeT is carried via the
/// [scrutineeT] field.
final class _QMatchBuild extends _Frame {
  final Term scrutineeT;
  final List<TMatchCase> caseTerms;
  const _QMatchBuild(this.scrutineeT, this.caseTerms);
}

/// After a [VQuot]'s carrier is quoted, quote the relation.
final class _QQuotRelation extends _Frame {
  final Value relation;
  final int level;
  const _QQuotRelation(this.relation, this.level);
}

/// After a [VQuot]'s relation is quoted, combine into a [TQuot].
final class _QQuotBuild extends _Frame {
  final Term carrier;
  const _QQuotBuild(this.carrier);
}

/// After a [VQuotMk]'s arg is quoted, produce [TQuotMk].
final class _QQuotMk extends _Frame {
  const _QQuotMk();
}

/// After a [VQuotLift]'s quot is quoted, quote the fn.
final class _QQuotLiftFn extends _Frame {
  final Value fn;
  final Value proof;
  final int level;
  const _QQuotLiftFn(this.fn, this.proof, this.level);
}

/// After a [VQuotLift]'s fn is quoted, quote the proof.
final class _QQuotLiftProof extends _Frame {
  final Term quot;
  final Value proof;
  final int level;
  const _QQuotLiftProof(this.quot, this.proof, this.level);
}

/// After a [VQuotLift]'s proof is quoted, produce [TQuotLift].
final class _QQuotLiftBuild extends _Frame {
  final Term quot;
  final Term fn;
  const _QQuotLiftBuild(this.quot, this.fn);
}

/// Stack-safe recursor ι-reduction. A naive ι-reduction for `VRec ...
/// canonical-scrutinee` would compute recursive IHs eagerly via inlined
/// `apply(VRec(head), subArg)` calls. Each subArg could itself reduce to
/// another VConstr whose ι-reduction fires more inlined applies, one
/// Dart frame per structural level. Deep succ-towers or list-fold
/// scrutinees would blow the stack at ~2k depth.
///
/// Driver-native redesign: split ι-reduction into two stages.
///
/// Stage 1: IH computation. Walk `ctorDecl.args`; for each
/// recursive-occurrence arg, schedule `_Apply(VRec(head), subArg)`
/// as a driver step, then accumulate the result into the `ihs` list
/// via [_RecCollectIH]. Non-recursive args go directly into
/// [methodArgs].
///
/// Stage 2: method application. Once all IHs are in hand, drive
/// the sequential application of `method` to
/// `[methodArgs..., ihs...]` via the existing [_ApplyChain] frame
/// (bounded by method arity).
final class _RecCollectIH extends _Frame {
  final Value method;
  final DataDecl dataDecl;
  final CtorDecl ctorDecl;
  final List<Value> headSpine;
  final List<Value> scrutArgs;
  final int paramCount;
  final int subArgIndex;
  final List<Value> methodArgs;
  final List<Value> ihs;
  const _RecCollectIH({
    required this.method,
    required this.dataDecl,
    required this.ctorDecl,
    required this.headSpine,
    required this.scrutArgs,
    required this.paramCount,
    required this.subArgIndex,
    required this.methodArgs,
    required this.ihs,
  });
}

/// Stack-safe VMatch-arm body evaluation.
///
/// `value` on entry is the evaluated body of arm [armIndex]. Schedule
/// quoting the body at the arm's extended depth (level + nBinders);
/// after that yields a Term, [_QMatchArmAfterQuote] accumulates it
/// into [builtArms] and advances to the next arm (or finishes).
///
/// Arm iteration is driver-native (through frames) rather than a Dart
/// for-loop so host-stack depth stays constant: an arm body may itself
/// be a VMatch over a recursive top-level reference, and a Dart-loop
/// quote would recurse once per nested-match layer.
final class _QMatchArmAfterEval extends _Frame {
  final Value sv;
  final Value? mv;
  final List<VMatchCase> cases;
  final Env env;
  final int level;
  final List<TMatchCase> builtArms;
  final int armIndex;
  const _QMatchArmAfterEval({
    required this.sv,
    required this.mv,
    required this.cases,
    required this.env,
    required this.level,
    required this.builtArms,
    required this.armIndex,
  });
}

/// `value` on entry is the quoted body Term
/// for arm [armIndex]. Accumulate into [builtArms], advance to arm
/// [armIndex] + 1 (or finish by quoting scrutinee + motive).
final class _QMatchArmAfterQuote extends _Frame {
  final Value sv;
  final Value? mv;
  final List<VMatchCase> cases;
  final Env env;
  final int level;
  final List<TMatchCase> builtArms;
  final int armIndex;
  const _QMatchArmAfterQuote({
    required this.sv,
    required this.mv,
    required this.cases,
    required this.env,
    required this.level,
    required this.builtArms,
    required this.armIndex,
  });
}

/// Like [_QPiCod], but for a [VLam]'s body.
final class _QLamBody extends _Frame {
  final Closure body;
  final int level;
  final String? nameHint;
  final Icit icit;
  const _QLamBody(this.body, this.level, this.nameHint, this.icit);
}

/// Like [_QPiBuild], but for a [VLam].
final class _QLamBuild extends _Frame {
  final Term domain;
  final String? nameHint;
  final Icit icit;
  const _QLamBuild(this.domain, this.nameHint, this.icit);
}

/// After the head of a neutral spine is quoted (or an outer app term is
/// produced), quote the next argument [arg] at [level].
final class _QAppArg extends _Frame {
  final Value arg;
  final int level;
  const _QAppArg(this.arg, this.level);
}

/// After an argument term has been produced, combine with saved [fn]
/// into a [TApp].
final class _QAppBuild extends _Frame {
  final Term fn;
  const _QAppBuild(this.fn);
}

// ===========================================================================
// Public API.
// ===========================================================================

/// Evaluate [term] in [env] to a [Value].
Value eval(Term term, Env env) =>
    _drive(_Eval(term, env), <_Frame>[], env.dataDecls) as Value;

/// Force a [VDelayed] β-redex by running one β-step: eval the
/// closure body in the closure's captured env extended with the
/// deferred arg. The result may still contain further `VDelayed`
/// nodes at deeper positions, callers force on demand.
///
/// Lazy-motive forcing, in the manner of weak-head normalisation:
/// `_Conv` forces at the head before structural compare; `_Apply`
/// forces before extending the spine; `_Quote` forces to reify.
Value _forceDelayed(VDelayed v) =>
    _drive(
          _Eval(v.closure.body, v.closure.env.extend(v.arg)),
          <_Frame>[],
          v.closure.env.dataDecls,
        )
        as Value;

/// True iff [term] mentions any `TMeta(_)`. Used as the heuristic
/// discriminator for lazy β: a [VLam] whose body contains
/// unsolved-ish metavariables should stay stuck as [VDelayed] when
/// applied to a non-variable value, because β would substitute the
/// arg into meta spines and can degrade pattern-fragment shape.
///
/// A VLam whose body has no metas (e.g. the user's `plus`, `append`,
/// or `cong`'s `f`) β-reduces normally, the discriminator doesn't
/// affect ordinary evaluation.
///
/// Iterative walk via an explicit stack to stay within SPEC §4.5's
/// no-Dart-recursion-per-syntax-layer invariant (a 10k-deep TPi
/// stack-safety test exercises this walker with depth 10000).
bool _termContainsMeta(Term t) {
  final stack = <Term>[t];
  while (stack.isNotEmpty) {
    final cur = stack.removeLast();
    switch (cur) {
      case TMeta():
        return true;
      case TType():
      case TProp():
      case TSProp():
      case TBound():
      case TFree():
      case TTop():
      case TRec():
        break;
      case TApp(:final fn, :final arg):
        stack.add(fn);
        stack.add(arg);
      case TLam(:final domain, :final body):
        stack.add(domain);
        stack.add(body);
      case TPi(:final domain, :final codomain):
        stack.add(domain);
        stack.add(codomain);
      case TLet(:final domain, :final bound, :final body):
        stack.add(domain);
        stack.add(bound);
        stack.add(body);
      case TData(:final args):
        stack.addAll(args);
      case TConstr(:final args):
        stack.addAll(args);
      case TMatch(:final scrutinee, :final motive, :final cases):
        stack.add(scrutinee);
        if (motive != null) stack.add(motive);
        for (final c in cases) {
          stack.add(c.body);
        }
      case TQuot(:final carrier, :final relation):
        stack.add(carrier);
        stack.add(relation);
      case TQuotMk(:final arg):
        stack.add(arg);
      case TQuotLift(:final quot, :final fn, :final proof):
        stack.add(quot);
        stack.add(fn);
        stack.add(proof);
      case TProj(:final expr):
        stack.add(expr);
    }
  }
  return false;
}

/// If [t] is `TApp*(TMeta(id), a1, …, an)`,
/// return `(id, [a1, …, an])` with args in leftmost-first order.
/// Otherwise return null.
///
/// Used by shift-at-crossing walkers to detect a `TMeta σ` subterm
/// whose spine must be re-anchored to the meta's declaration-site
/// scope.
(int, List<Term>)? _termHeadTMetaAndSpine(Term t) {
  final args = <Term>[];
  var cur = t;
  while (cur is TApp) {
    args.add(cur.arg);
    cur = cur.fn;
  }
  if (cur is! TMeta) return null;
  return (cur.id, args.reversed.toList());
}

/// Apply [fn] to [arg]. β-reduces if [fn] is a [VLam], extends the spine
/// if [fn] is a [VNeutral]. A non-function head is a kernel invariant
/// violation (ill-typed term reached evaluation).
Value apply(Value fn, Value arg) =>
    _drive(_Apply(fn, arg), <_Frame>[], null) as Value;

/// Reify [value] to a [Term] at context depth [level].
Term quote(int level, Value value) =>
    _drive(_Quote(value, level), <_Frame>[], null) as Term;

/// Reify [value] at [level] with a [metas] context threaded into the
/// driver, so `quote(VMatch)`'s arm-body substitution takes the
/// meta-spine-aware path. Exposed for the scope-faithfulness harness
/// (`test/vmatch_roundtrip_test.dart`), which must exercise the
/// `metas != null` branch in isolation.
Term quoteWithMetas(int level, Value value, MetaContext metas) =>
    _drive(_Quote(value, level), <_Frame>[], null, metas: metas) as Term;

/// Compute the normal form of [term] in the empty environment.
///
/// Single-loop: the driver evaluates then quotes without any intermediate
/// Dart frame. The pre-loaded [_QuoteAt] frame transitions from the final
/// evaluation value into quote mode at level 0.
Term nf(Term term) {
  final stack = <_Frame>[const _QuoteAt(0)];
  return _drive(_Eval(term, const ENil()), stack, null) as Term;
}

/// Definitional equality of [a] and [b] at context depth [level].
///
/// Implements SPEC §4.3: α, β, and η, strict on universe levels. Does not
/// compare [VLam] domain annotations. Returns [ConvOk] on success or a
/// [ConvMismatch] pointing at the innermost diverging pair.
///
/// [dataDecls], when supplied, enables SPEC §8.2 definitional proof
/// irrelevance: at conv-mismatch sites, the driver consults the
/// registry to check whether both values have Prop-sorted types;
/// if so, the conversion is admitted. Omitting the registry (the
/// default for low-level callers and most tests) keeps conv purely
/// structural.
///
/// [metas], when supplied, enables pattern unification:
/// a `VNeutral(NMeta(id) spine)` on either side triggers a Miller-
/// pattern solve attempt (occurs check + scope check + commit).
/// Omitting the meta-context keeps conv meta-agnostic (metas are
/// treated as opaque neutrals, distinct from one another).
ConvResult conv(
  int level,
  Value a,
  Value b, {
  List<DataDecl>? dataDecls,
  MetaContext? metas,
  Map<String, TopBindingEntry>? topBindings,
}) =>
    _drive(
          _Conv(a, b, level),
          <_Frame>[],
          dataDecls,
          metas: metas,
          topBindings: topBindings,
        )
        as ConvResult;

/// Cumulativity-aware comparison: succeeds when [got] is a *subtype* of
/// [expected] at depth [level] (`Type n ≤ Type m` for `n ≤ m`, Pi
/// codomain covariant / domain contravariant; identical to [conv]
/// everywhere else). This is the relation check mode uses: an inferred
/// type need only be a subtype of the expected type, not strictly equal.
ConvResult subtype(
  int level,
  Value got,
  Value expected, {
  List<DataDecl>? dataDecls,
  MetaContext? metas,
  Map<String, TopBindingEntry>? topBindings,
}) =>
    _drive(
          _Subtype(got, expected, level),
          <_Frame>[],
          dataDecls,
          metas: metas,
          topBindings: topBindings,
        )
        as ConvResult;

/// Infer the type of [term] in [ctx]. Throws [DoxaCheckError] on failure.
Value infer(Ctx ctx, Term term) =>
    _drive(
          _Infer(ctx, term),
          <_Frame>[],
          ctx.dataDecls,
          metas: ctx.metas,
          topBindings: ctx.env.topBindings,
        )
        as Value;

/// Check that [term] has type [expected] in [ctx]. Returns [expected] on
/// success (a sentinel; callers that don't need the result discard it). Throws
/// [DoxaCheckError] on mismatch.
Value check(Ctx ctx, Term term, Value expected) =>
    _drive(
          _Check(ctx, term, expected),
          <_Frame>[],
          ctx.dataDecls,
          metas: ctx.metas,
          topBindings: ctx.env.topBindings,
        )
        as Value;

// ===========================================================================
// Driver.
// ===========================================================================

/// The single dispatch loop. Returns either a [Value] or a [Term]
/// depending on which kind of yield matches the empty stack.
///
/// All semantic recursion in the kernel flows through this loop: [_Eval],
/// [_Apply], and [_Quote] steps push frames and transform into further
/// steps; yields pop frames and transform accordingly. The Dart call stack
/// never grows beyond the constant depth of this one function.
Object _drive(
  _Step start,
  List<_Frame> stack,
  List<DataDecl>? dataDecls, {
  MetaContext? metas,
  Map<String, TopBindingEntry>? topBindings,
}) {
  var step = start;
  while (true) {
    switch (step) {
      // -----------------------------------------------------------------
      // _Eval: evaluate a term in an environment.
      // -----------------------------------------------------------------
      case _Eval(:final term, :final env):
        switch (term) {
          case TType(:final level):
            step = _YieldV(VType(level));

          case TProp():
            step = const _YieldV(VProp());

          case TSProp():
            step = const _YieldV(VSProp());

          case TBound(:final index):
            step = _YieldV(env.lookup(index));

          case TFree(:final name):
            throw StateError(
              'eval reached TFree($name): kernel invariant violated '
              '(open term in evaluator).',
            );

          case TApp(:final fn, :final arg):
            // Schedule "evaluate arg then apply" and continue by
            // evaluating the function.
            stack.add(_EvalArg(arg, env));
            step = _Eval(fn, env);

          case TLam(:final domain, :final body, :final name, :final icit):
            // Schedule VLam construction and evaluate the domain.
            stack.add(_BuildLam(env, body, name, icit));
            step = _Eval(domain, env);

          case TPi(:final domain, :final codomain, :final name, :final icit):
            stack.add(_BuildPi(env, codomain, name, icit));
            step = _Eval(domain, env);

          case TLet(
            bound: final boundTerm,
            body: final bodyTerm,
            :final isRec,
            :final name,
            recDecreasingArg: final decreasingArg,
            recArity: final arity,
          ):
            // Eval the bound expression; the resulting value gets
            // extended into the env when `_EvalLetBody` fires, and the
            // body is evaluated under the new env. Domain and name
            // hint are not needed at eval time, they're for the
            // checker (domain) and diagnostics (name).
            stack.add(
              _EvalLetBody(
                env,
                bodyTerm,
                isRec: isRec,
                name: name,
                decreasingArg: decreasingArg,
                arity: arity,
              ),
            );
            step = _Eval(boundTerm, env);

          case TData(name: final n, args: final dataArgs):
            if (dataArgs.isEmpty) {
              step = _YieldV(VData(n, const <Value>[]));
            } else {
              // Seed an index-based accumulator; the frame's handler
              // mutates `collected` in place and advances `nextIndex`.
              stack.add(_BuildData(n, <Value>[], dataArgs, 1, env));
              step = _Eval(dataArgs[0], env);
            }

          case TConstr(
            dataName: final dn,
            ctorName: final cn,
            args: final ctorArgs,
          ):
            if (ctorArgs.isEmpty) {
              step = _YieldV(VConstr(dn, cn, const <Value>[]));
            } else {
              stack.add(_BuildConstr(dn, cn, <Value>[], ctorArgs, 1, env));
              step = _Eval(ctorArgs[0], env);
            }

          case TRec(:final dataName):
            // Look up the DataDecl via the env's registry. TRec only
            // appears as the RHS of mechanically-generated recursor
            // bindings (see _elabData in elab.dart), so a missing
            // registration is a kernel invariant violation rather than
            // a user error.
            final decl = env.lookupData(dataName);
            if (decl == null) {
              throw StateError(
                'eval reached TRec($dataName) with no matching DataDecl '
                'in env.dataDecls. Kernel invariant violation: TRec is '
                'only emitted by _elabData for a registered data type.',
              );
            }
            step = _YieldV(VRec(decl, const <Value>[]));

          case TTop(:final name):
            // Prefer the _drive-level threaded topBindings over the
            // closure-captured env map. Stored
            // VLam closures (built during `TopEnv.toCtx`'s incremental
            // build) carry an env with only the topBindings in scope
            // at build time. When such a closure is later applied
            // inside a real conv/check/infer driven with a fuller
            // topBindings map, resolving TTop via the _drive param
            // finds the complete registry. Env.topBindings remains a
            // safe fallback for drive invocations that omit the map.
            final entry =
                (topBindings != null ? topBindings[name] : null) ??
                env.lookupTop(name);
            if (entry == null) {
              throw StateError(
                'eval reached TTop($name) with no matching entry in '
                'env.topBindings. Kernel invariant violation: the '
                'elaborator only emits TTop for registered top-level '
                'names.',
              );
            }
            // An opaque binding never unfolds: yield a neutral keyed
            // on the name. Checked before the VFun guard so opaque
            // recursive funs also stay stuck.
            if (entry.isOpaque) {
              step = _YieldV(VNeutral(NTop(name)));
              break;
            }
            // A structurally-recursive `fun` yields a guarded VFun
            // (empty spine) instead of its raw VLam, so
            // it stays stuck until its decreasing argument is canonical
            // (CIC fix-reduction). Stubs (VNeutral(NTop)) during a
            // group's own check keep their stub value, guarding only
            // applies once the real VLam is installed.
            final dec = entry.recDecreasingArg;
            if (dec != null && entry.value is! VNeutral) {
              step = _YieldV(
                VFun(name, entry.value, dec, entry.recArity!, const <Value>[]),
              );
            } else {
              step = _YieldV(entry.value);
            }

          case TMeta(:final id):
            // Yield a stuck metavariable neutral. Unfolding
            // of solved metas happens in the elaborator / unifier
            // layer via an explicit `force` walk (matches Kovács's
            // elaboration-zoo pattern). Keeping eval meta-agnostic
            // preserves the driver's separation: eval is purely
            // structural; meta-context manipulation sits above it.
            step = _YieldV(VNeutral(NMeta(id)));

          case TMatch(:final scrutinee, :final motive, :final cases):
            // Evaluate scrutinee first; then the motive (needed both
            // for stuck-match convertibility and for future type-
            // driven reductions); then dispatch.
            stack.add(_MatchAfterScrutinee(motive, cases, env));
            step = _Eval(scrutinee, env);

          case TQuot(:final carrier, :final relation):
            stack.add(_EvalQuot(relation, env));
            step = _Eval(carrier, env);

          case TQuotMk(:final arg):
            stack.add(const _EvalQuotMk());
            step = _Eval(arg, env);

          case TQuotLift(:final quot, :final fn, :final proof):
            stack.add(_EvalQuotLift(fn, proof, env));
            step = _Eval(quot, env);

          case TProj(:final expr, :final fieldName):
            stack.add(_EvalProj(fieldName));
            step = _Eval(expr, env);
        }

      // -----------------------------------------------------------------
      // _Conv: compare two values for definitional equality.
      //
      // Follows SPEC §4.3. VLam domain annotations are NOT compared.
      // η is eager on both sides: whenever one side is VLam and the other
      // is not, we apply both to a fresh neutral and compare the bodies
      // for neutrals this just extends the spine, for VLam this β-reduces.
      // -----------------------------------------------------------------
      case _Conv(:final a, :final b, :final level):
        // Force solved metas at the head before any structural
        // dispatch. If the meta-context is populated and
        // a side is a meta-headed neutral whose meta is already
        // solved, unfold it (apply the solution to the spine) and
        // restart conv. Matches Kovács's `force` pattern, keeps
        // structural cases below unaware of meta machinery.
        if (metas != null) {
          final forcedA = _forceMetaHead(a, metas, topBindings);
          final forcedB = _forceMetaHead(b, metas, topBindings);
          if (!identical(forcedA, a) || !identical(forcedB, b)) {
            step = _Conv(forcedA, forcedB, level);
            break;
          }
        }
        // Lazy-motive: if both sides are VDelayed sharing
        // the SAME closure identity, compare arg pointwise without
        // forcing. This is the structural path that preserves
        // pattern-fragment meta spines inside the closure body
        // the whole reason VDelayed exists.
        //
        // If only one side is VDelayed, force it and retry (the
        // other side may be an eager-β form that equals the
        // delayed-β result). If both are VDelayed with different
        // closures, force both, they represent distinct β-redex
        // shapes whose meanings only coincide post-reduction.
        if (a is VDelayed && b is VDelayed && identical(a.closure, b.closure)) {
          step = _Conv(a.arg, b.arg, level);
          break;
        }
        if (a is VDelayed) {
          final forcedA = _forceDelayed(a);
          step = _Conv(forcedA, b, level);
          break;
        }
        if (b is VDelayed) {
          final forcedB = _forceDelayed(b);
          step = _Conv(a, forcedB, level);
          break;
        }
        // Guarded recursive funs (VFun). A stuck VFun represents
        // `name` applied to a spine whose decreasing
        // argument is not yet canonical (so it cannot ι-reduce). Two
        // such funs are definitionally equal iff they are the SAME
        // function applied to pointwise-convertible spines, exactly
        // VRec's discipline. They never need forcing: a VFun whose
        // decreasing arg is canonical already unfolded at `apply`
        // time, so any VFun reaching conv is genuinely stuck. A VFun
        // vs a non-VFun is a head mismatch (the proof, not conv,
        // bridges propositional-but-not-definitional equalities).
        if (a is VFun && b is VFun) {
          if (a.name != b.name || a.spine.length != b.spine.length) {
            step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
            break;
          }
          if (a.spine.isEmpty) {
            step = const _YieldC(_ok);
            break;
          }
          // Compare spines pointwise: schedule the tail comparisons,
          // then start on the head. (_ConvThen chains the rest.)
          final pending = <_Frame>[];
          for (var i = 1; i < a.spine.length; i++) {
            pending.add(_ConvThen(_Conv(a.spine[i], b.spine[i], level)));
          }
          for (final f in pending.reversed) {
            stack.add(f);
          }
          step = _Conv(a.spine[0], b.spine[0], level);
          break;
        }
        // VFun vs non-VFun is NOT special-cased here: it falls through
        // to the structural switch's `default`, which first tries
        // flex-rigid pattern unification (so a meta can solve to the
        // VFun, e.g. `?x := plus m zero` in `cong … ih`) and only then
        // reports a mismatch. Hard-mismatching here would block that
        // unification and break every proof that passes a stuck
        // recursive application as a `cong`/`trans` argument.
        // Strict proof irrelevance: any two SProp values are
        // definitionally equal regardless of their internal structure.
        // This fires before the structural switch, so SProp-to-SProp
        // comparison never descends into inner terms.
        if (a is VSProp && b is VSProp) {
          step = const _YieldC(_ok);
          break;
        }
        // Record η: if one side is a VConstr from a record type and
        // the other side is not a VConstr, η-expand by projecting all
        // fields from both sides and comparing pointwise.
        if (a is VConstr && b is! VConstr) {
          final dDecl = _lookupData(a.dataName, dataDecls);
          if (dDecl != null && _isRecordData(dDecl)) {
            final ctor = dDecl.ctors.first;
            final paramCount = dDecl.params.length;
            final pending = <_Frame>[];
            for (var i = 0; i < ctor.args.length; i++) {
              pending.add(
                _ConvThen(
                  _Conv(
                    a.args[paramCount + i],
                    VNeutral(NProj(b, ctor.args[i].name ?? '')),
                    level,
                  ),
                ),
              );
            }
            for (final f in pending.reversed) {
              stack.add(f);
            }
            step = const _YieldC(_ok);
            break;
          }
        }
        if (b is VConstr && a is! VConstr) {
          final dDecl = _lookupData(b.dataName, dataDecls);
          if (dDecl != null && _isRecordData(dDecl)) {
            final ctor = dDecl.ctors.first;
            final paramCount = dDecl.params.length;
            final pending = <_Frame>[];
            for (var i = 0; i < ctor.args.length; i++) {
              pending.add(
                _ConvThen(
                  _Conv(
                    VNeutral(NProj(a, ctor.args[i].name ?? '')),
                    b.args[paramCount + i],
                    level,
                  ),
                ),
              );
            }
            for (final f in pending.reversed) {
              stack.add(f);
            }
            step = const _YieldC(_ok);
            break;
          }
        }
        switch ((a, b)) {
          // VType × VType: strict on levels.
          case (VType(level: final la), VType(level: final lb)):
            step = _YieldC(
              _levelEq(la, lb) ? _ok : _mismatchOrIrrelevance(a, b, dataDecls),
            );

          // Prop × Prop: α-convertible.
          case (VProp(), VProp()):
            step = const _YieldC(_ok);

          // SProp × SProp: strict irrelevance.
          case (VSProp(), VSProp()):
            step = const _YieldC(_ok);

          // VType × VProp/VProp × VType: distinct sorts, strict
          // equality rejects them (no cumulativity across sort
          // identity; see SPEC §8.2, Prop and Type are separate, not a
          // subtype chain).
          case (VType(), VProp()):
          case (VProp(), VType()):
            step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));

          // VSProp × {VType, VProp}: distinct sorts.
          case (VSProp(), VType()):
          case (VType(), VSProp()):
          case (VSProp(), VProp()):
          case (VProp(), VSProp()):
            step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));

          // VPi × VPi: domains first, then opened codomains at level+1.
          case (
            VPi(domain: final d1, codomain: final c1),
            VPi(domain: final d2, codomain: final c2),
          ):
            // Compare domains; if OK, open both codomains at level+1 and
            // compare those. We wrap each Pi's codomain closure as a VLam
            // because _Apply expects a function-shaped head (VLam or
            // VNeutral); the "domain" field of the VLam wrapper is unused
            // by _Apply, only the closure is consulted.
            stack.add(_ConvThenOpen(VLam(d1, c1), VLam(d2, c2), level));
            step = _Conv(d1, d2, level);

          // VLam × VLam: apply both to a fresh neutral at level, compare
          // bodies at level+1. Both sides β-reduce.
          //
          // VLam × VNeutral (and symmetric): η rule. Apply both to a
          // fresh neutral; the VLam side β-reduces, the VNeutral side
          // just extends its spine. If they agree after that, η holds.
          //
          // VLam × {VType, VPi}: structural mismatch, a function value
          // can never convert with a non-function value. This has to be
          // checked explicitly because _Apply on a non-function throws.
          // η: either side is a VLam. The other side must be
          // something that can be applied, another VLam, a VNeutral,
          // a stuck VRec, or a stuck VMatch. In every case, apply
          // both sides to a fresh neutral and compare the results.
          // The comparison reduces β on the VLam side and extends
          // the spine on the stuck side; if the two shapes
          // coincidentally match (e.g. `(x: T) => stuckThing x` vs
          // `stuckThing`), η lets them convert.
          //
          // Non-applicable values on the other side, VType, VProp,
          // VPi, VData, VConstr, are a structural mismatch and fail
          // the `(VLam(), _)` / `(_, VLam())` fallthrough below.
          case (VLam(), VLam()):
          case (VLam(), VNeutral()):
          case (VNeutral(), VLam()):
          case (VLam(), VRec()):
          case (VRec(), VLam()):
          case (VLam(), VMatch()):
          case (VMatch(), VLam()):
            final fresh = VNeutral(NVar(level));
            stack.add(_ConvPairLeft(b, fresh, level + 1));
            step = _Apply(a, fresh);

          case (VLam(), _):
          case (_, VLam()):
            step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));

          // VNeutral × VNeutral: compare heads and spines.
          case (VNeutral(neutral: final n1), VNeutral(neutral: final n2)):
            // Walk both spines outward collecting args. If lengths or
            // heads differ, immediate mismatch. Otherwise schedule a
            // chain of _ConvThen frames for the args, then dispatch on
            // the head shapes (NVar × NVar or NStuck × NStuck).
            final args1 = <Value>[];
            final args2 = <Value>[];
            var h1 = n1;
            var h2 = n2;
            while (h1 is NApp) {
              args1.add(h1.arg);
              h1 = h1.fn;
            }
            while (h2 is NApp) {
              args2.add(h2.arg);
              h2 = h2.fn;
            }
            // Pattern unification: if exactly one head is a
            // meta (and the meta-context is populated), try to solve
            // the flex-rigid case against the other neutral. Both-
            // metas (flex-flex) falls to the block right after.
            if (metas != null && (h1 is NMeta) != (h2 is NMeta)) {
              final r = _tryUnify(a, b, level, metas);
              if (r != null) {
                step = _YieldC(r);
                break;
              }
              step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
              break;
            }
            // Flex-flex: both heads metas. Solved metas are
            // handled by the force-at-top step; here both metas are
            // unsolved.
            //
            //   * Same meta id → pointwise spine compare.
            //   * Different meta ids → Miller / Abel-Pientka
            //     intersection (see `_tryFlexFlexIntersect` for
            //     details and the rationale for why this is in the
            //     pattern fragment and not higher-order unification).
            if (metas != null && h1 is NMeta && h2 is NMeta) {
              if (h1.id == h2.id) {
                if (args1.length != args2.length) {
                  step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
                  break;
                }
                // Const-approximation.
                // When `?m σ ≡ ?m τ` with `σ ≠ τ`, the same-meta
                // flex-flex case (as Lean handles it) solves
                // `?m := λ_…λ_. ?aux`, a constant function discarding
                // the spine, with `?aux` inheriting the meta's original
                // localCtx. Applying the solution makes both `?m σ` and
                // `?m τ` reduce to the same `?aux`, succeeding where
                // pointwise compare would have failed.
                //
                // Ordering: in Lean, pointwise compare runs first
                // and const-approx is the recovery path. Doxa's
                // `_drive` loop can't observe pointwise failure
                // and then retry; instead we use a cheap
                // divergence check, if all spine args are
                // pointer-identical, pointwise comparison is a no-op:
                // (emit `_ok`); otherwise the spines diverge and
                // we attempt const-approx before scheduling
                // pointwise. On const-approx success the solve
                // commits; on decline we still schedule pointwise
                // (preserves old behaviour for cases where a
                // proper pointwise conv would have matched via
                // deeper semantic equality).
                //
                // Unconditional (as in Lean's constant-approximation
                // mode): some proofs hit spines exceeding the meta's
                // declared scope-prefix (e.g. a motive implicit at
                // level 1 applied to 2 args), which a gated form
                // cannot close.
                var allIdentical = true;
                for (var i = 0; i < args1.length; i++) {
                  if (!identical(args1[i], args2[i])) {
                    allIdentical = false;
                    break;
                  }
                }
                if (!allIdentical) {
                  final approxResult = _tryConstApproxAtSameMeta(
                    h1.id,
                    args1,
                    metas,
                  );
                  if (approxResult != null) {
                    step = _YieldC(approxResult);
                    break;
                  }
                }
                for (var i = 0; i < args1.length; i++) {
                  stack.add(_ConvThen(_Conv(args1[i], args2[i], level)));
                }
                step = const _YieldC(_ok);
                break;
              }
              final r = _tryFlexFlexIntersect(
                h1.id,
                args1,
                h2.id,
                args2,
                level,
                metas,
              );
              if (r != null) {
                step = _YieldC(r);
                break;
              }
              step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
              break;
            }
            if (args1.length != args2.length) {
              step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
            } else {
              // Compare heads. Valid head shapes:
              //   * NVar (local free variable at level)
              //   * NStuck (stuck Value, e.g. VMatch)
              //   * NTop (top-level-binding stub during its own check)
              //   * NMeta (unsolved metavariable, caught above as
              //     flex-flex if both sides are metas; here only if
              //     exactly one is, in which case the outer
              //     `(VNeutral, _)` flex-rigid arm would have caught
              //     it already if metas != null. This path is taken
              //     when metas == null, treat NMeta like NTop:
              //     same-id + same-spine-length → ok, else mismatch.)
              // Mismatched shapes are ConvMismatch.
              switch ((h1, h2)) {
                case (NVar(level: final l1), NVar(level: final l2)):
                  if (l1 != l2) {
                    step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
                  } else {
                    // Schedule arg pair comparisons. args1/args2 are
                    // in outermost-first order (last-applied first);
                    // we want to compare leftmost-first, i.e., the
                    // last element of the list first. Push frames in
                    // reverse so they pop in the right order.
                    for (var i = 0; i < args1.length; i++) {
                      stack.add(_ConvThen(_Conv(args1[i], args2[i], level)));
                    }
                    step = const _YieldC(_ok);
                  }
                case (NStuck(value: final v1), NStuck(value: final v2)):
                  // Compare the wrapped stuck values first; then
                  // arg pairs. If the heads diverge the spine's args
                  // are irrelevant.
                  for (var i = 0; i < args1.length; i++) {
                    stack.add(_ConvThen(_Conv(args1[i], args2[i], level)));
                  }
                  step = _Conv(v1, v2, level);
                case (NTop(name: final tn1), NTop(name: final tn2)):
                  // Two top-level stubs converge iff they name the
                  // same top binding, and their spines match pointwise.
                  if (tn1 != tn2) {
                    step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
                  } else {
                    for (var i = 0; i < args1.length; i++) {
                      stack.add(_ConvThen(_Conv(args1[i], args2[i], level)));
                    }
                    step = const _YieldC(_ok);
                  }
                case (NMeta(id: final mn1), NMeta(id: final mn2)):
                  // metas == null path only. Treat as opaque: same
                  // id + equal spines → ok; else mismatch.
                  if (mn1 != mn2) {
                    step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
                  } else {
                    for (var i = 0; i < args1.length; i++) {
                      stack.add(_ConvThen(_Conv(args1[i], args2[i], level)));
                    }
                    step = const _YieldC(_ok);
                  }
                case (
                  NProj(expr: final e1, fieldName: final f1),
                  NProj(expr: final e2, fieldName: final f2),
                ):
                  if (f1 != f2) {
                    step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
                  } else {
                    for (var i = 0; i < args1.length; i++) {
                      stack.add(_ConvThen(_Conv(args1[i], args2[i], level)));
                    }
                    step = _Conv(e1, e2, level);
                  }
                case (NApp(), _):
                case (_, NApp()):
                  // Loop above walked past all NApps; reaching one
                  // here would mean the invariant was violated.
                  throw StateError('neutral spine head is NApp, unreachable');
                default:
                  // Any other head-shape mismatch: NVar × NStuck,
                  // NVar × NTop, NStuck × NTop, etc.
                  step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
              }
            }

          // VData × VData: same inductive name + pointwise-convertible
          // args.
          case (
            VData(name: final n1, args: final a1),
            VData(name: final n2, args: final a2),
          ):
            if (n1 != n2 || a1.length != a2.length) {
              step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
            } else if (a1.isEmpty) {
              step = const _YieldC(_ok);
            } else {
              // Push arg-pair conv frames in reverse so they pop in
              // forward order, same pattern as the VNeutral spine.
              for (var i = a1.length - 1; i >= 1; i--) {
                stack.add(_ConvThen(_Conv(a1[i], a2[i], level)));
              }
              step = _Conv(a1[0], a2[0], level);
            }

          // VConstr × VConstr: same data+ctor name + pointwise args.
          case (
            VConstr(dataName: final dn1, ctorName: final cn1, args: final a1),
            VConstr(dataName: final dn2, ctorName: final cn2, args: final a2),
          ):
            if (dn1 != dn2 || cn1 != cn2 || a1.length != a2.length) {
              step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
            } else if (a1.isEmpty) {
              step = const _YieldC(_ok);
            } else {
              for (var i = a1.length - 1; i >= 1; i--) {
                stack.add(_ConvThen(_Conv(a1[i], a2[i], level)));
              }
              step = _Conv(a1[0], a2[0], level);
            }

          // VRec × VRec: same data decl (by identity, recursor bindings
          // are registered once per data type) + pointwise-convertible
          // spine. Two stuck recursors compare equal iff they're applied
          // to convertible spines of the same length.
          case (
            VRec(dataDecl: final d1, spine: final s1),
            VRec(dataDecl: final d2, spine: final s2),
          ):
            if (!identical(d1, d2) || s1.length != s2.length) {
              step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
            } else if (s1.isEmpty) {
              step = const _YieldC(_ok);
            } else {
              for (var i = s1.length - 1; i >= 1; i--) {
                stack.add(_ConvThen(_Conv(s1[i], s2[i], level)));
              }
              step = _Conv(s1[0], s2[0], level);
            }

          // VMatch × VMatch: stuck matches compare by scrutinee +
          // motive + structural case-by-case equality. The case
          // comparison is syntactic on the body Term (alpha-equivalent
          // via de Bruijn): since two stuck matches from identical
          // elaboration runs share the exact same case bodies, this
          // suffices in the common case. More aggressive case-body
          // conversion
          // (evaluating each body under fresh neutrals and comparing
          // at higher level) could be added later if real programs
          // surface the need.
          case (
            VMatch(
              scrutinee: final sv1,
              motive: final mv1,
              cases: final c1,
              env: final env1,
            ),
            VMatch(
              scrutinee: final sv2,
              motive: final mv2,
              cases: final c2,
              env: final env2,
            ),
          ):
            if (c1.length != c2.length) {
              step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
            } else {
              // Structural case comparison. For each arm pair we
              // require matching ctor name + binder count, then
              // compare arm body Terms through a layered check:
              //
              //   1. Term.== on the bodies after `inlineSolvedMetas`.
              //      Covers identical elaboration paths (the deep-
              //      nested-VMatch stack-stress case lands here) plus
              //      the case where both sides carry the same
              //      solved-meta references, after inlining, both
              //      sides substitute the same solution terms.
              //
              //   2. Env-relative normalization through
              //      `_substArmBody` at the outer conv level. Two
              //      VMatches of the same source match with
              //      diverged envs (one β-reduced, one still
              //      parameterized by a lambda at a different
              //      depth) resolve each free TBound through their
              //      env into the same outer scope, Term.== on the
              //      normalized forms then matches.
              //
              //   3. Semantic fallback: evaluate each arm body
              //      under a fresh-NVar extension of its forced env
              //      and drop into the public `conv`. This lets
              //      flex-rigid pattern unification and flex-flex
              //      intersection fire on meta-headed sub-positions
              //      that tiers 1 and 2 can only compare
              //      syntactically. Handles proofs where `append xs
              //      (nil A)`-shape compositions produce VMatches
              //      whose arm bodies are structurally distinct but
              //      semantically equivalent up to pattern-fragment
              //      unification.
              //
              // Stack safety. Tier 1 is O(source term size) per
              // arm with no eval, satisfying the deep-nested-VMatch
              // stack-safety requirement (identical arm bodies from
              // the same
              // source TMatch remain identical `Term`s by
              // elaborator discipline). Tiers 2 and 3 only fire
              // when tier 1 fails; their eval + nested conv calls
              // run as fresh `_drive` loops, which never grow the
              // Dart stack beyond the driver's constant depth.
              //
              // Meta-headed entries in the captured envs are
              // handled uniformly: `_forceEnvMetas` unfolds solved
              // metas at env-entry heads; unsolved ones propagate
              // as `VNeutral(NMeta)` values that `_substArmBody`
              // quotes into faithful `TMeta … TApp` chains in the
              // normalized term, and that the tier-3 nested conv
              // can then try to solve via pattern unification.
              final forcedEnv1 =
                  metas == null ? env1 : _forceEnvMetas(env1, metas);
              final forcedEnv2 =
                  metas == null ? env2 : _forceEnvMetas(env2, metas);
              var casesOk = true;
              for (var i = 0; i < c1.length; i++) {
                final x = c1[i];
                final y = c2[i];
                if (x.ctorName != y.ctorName || x.nBinders != y.nBinders) {
                  casesOk = false;
                  break;
                }
                // Tier 1 fast path: identical body terms are always
                // equal (regardless of env), after inlining solved
                // BARE metas via the shared meta-context, so two
                // bodies that differ only by "meta not yet unfolded
                // on one side but solved identically in both
                // contexts" still catch the fast path without
                // paying for `_substArmBody`.
                //
                // Use `inlineSolvedBareMetas`, NOT
                // `inlineSolvedMetas`. The tier-1 inline at a
                // VMatch arm-body crossing must PRESERVE
                // `TApp*(TMeta, σ)` subterms intact so
                // `_substArmBody`'s `walkSpineArg` can
                // interpret σ's TBound indices scope-correctly
                // against the captured env. Eager flattening of
                // `TApp*(TMeta, σ)` into `TApp*(solution, σ)`
                // displaces σ's indices to emission scope but the
                // enclosing term continues to cross scope
                // boundaries in nested VMatch walks, the
                // solution body's λ-binders get β-applied to σ
                // args that no longer reference the right outer
                // NVars.
                final xBody =
                    metas == null
                        ? x.body
                        : inlineSolvedBareMetas(x.body, metas);
                final yBody =
                    metas == null
                        ? y.body
                        : inlineSolvedBareMetas(y.body, metas);
                if (xBody == yBody) continue;

                // Tier 2 & 3 both need env-relative substitution:
                // each side's captured forced env is the only
                // source of truth for the arm body's free-index
                // resolution. `_substArmBody` walks the term,
                // replacing each free outer-scope TBound with the
                // quoted form of its env entry. Meta-headed env
                // entries quote to faithful `TMeta … TApp` chains,
                // not garbage, so this is safe regardless of
                // whether the env carries unsolved metas.
                final nx = _substArmBody(
                  xBody,
                  env: forcedEnv1,
                  level: level,
                  nBinders: x.nBinders,
                  metas: metas,
                );
                final ny = _substArmBody(
                  yBody,
                  env: forcedEnv2,
                  level: level,
                  nBinders: y.nBinders,
                  metas: metas,
                );
                // Tier 2: Term.== on the normalized forms.
                if (nx == ny) continue;

                // Tier 3: evaluate each arm body under its own
                // captured forced env (extended with fresh NVars
                // for the arm-local binders), then drop into
                // public conv so flex-flex intersection and
                // flex-rigid pattern unification can fire at
                // meta-headed sub-positions.
                //
                // Each side eval'ing under its OWN captured env
                // preserves the VMatch-captured outer-scope
                // references at the levels they were originally
                // captured, meta applications inside arm bodies
                // carry TBound spines indexed relative to the
                // allocation-time scope, and re-interpreting them
                // under the CAPTURED env produces the correct
                // binder-level references. A shared-env variant
                // that substituted outer TBounds first (via
                // `_substArmBody`) mis-interprets meta-app spines
                // whose indices were already bound to specific
                // arm-frame interpretations.
                //
                // Prefer the outer conv's threaded topBindings
                // over whatever snapshot the captured env carries,
                // a VMatch built during an incremental
                // `TopEnv.toCtx` walk retains the pre-binding
                // registry; the outer conv sees the complete one
                // (TTop eval routes through the same threaded map).
                //
                // Tier-3 env reconciliation:
                //
                // `_substArmBody` produced `nx`/`ny` terms where
                // outer-scope TBounds are in LEVEL-relative
                // coordinates (the formula uses `level + depth`
                // as the quote scope) and arm-local TBounds
                // 0..nBinders-1 are preserved. To eval these
                // consistently across both sides we use a
                // common env: outer slots resolve via identity
                // on `level` (so TBound(level-1-k) → NVar(k)),
                // and arm-local slots extend with fresh NVars
                // at the outer conv level.
                //
                // Both sides must use `nx`/`ny` (already env-
                // substituted) under this shared identity env, NOT
                // their raw captured envs: each side can reach the
                // stuck VMatch by a different reduction path (motive
                // β-substitution vs direct user expression), so two
                // same-depth captured envs may hold different entries
                // and resolve the same TBound to different NVars.
                // Shift nx/ny's outer-scope TBounds past the arm
                // binders so the mixed-scope term becomes uniformly
                // at armLevel-scope. After the shift, `eval` under a
                // plain identity env of depth armLevel resolves
                // every free TBound correctly: arm-local 0..nBinders-1
                // map to fresh NVars at [level, level+nBinders), and
                // outer TBounds [nBinders + level - 1 .. nBinders]
                // map to NVar(0) .. NVar(level-1).
                final armLevel = level + x.nBinders;
                final nxShifted = _shiftTBoundPastThreshold(
                  nx,
                  threshold: x.nBinders,
                  shiftBy: x.nBinders,
                );
                final nyShifted = _shiftTBoundPastThreshold(
                  ny,
                  threshold: y.nBinders,
                  shiftBy: y.nBinders,
                );
                final armIdentityEnv = _armIdentityEnv(
                  level: level,
                  nBinders: x.nBinders,
                  topBindings: topBindings,
                  dataDecls: dataDecls,
                );
                final v1 = eval(nxShifted, armIdentityEnv);
                final v2 = eval(nyShifted, armIdentityEnv);
                final armConv = conv(
                  armLevel,
                  v1,
                  v2,
                  dataDecls: dataDecls,
                  metas: metas,
                  topBindings: topBindings,
                );
                if (armConv is! ConvOk) {
                  casesOk = false;
                  break;
                }
              }
              if (!casesOk) {
                step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
              } else {
                // Motives: null matches null (both implicit from
                // check context); explicit × explicit must convert;
                // null × explicit is a mismatch (one claimed a
                // specific return-type family, the other deferred).
                if (mv1 == null && mv2 == null) {
                  step = _Conv(sv1, sv2, level);
                } else if (mv1 == null || mv2 == null) {
                  step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
                } else {
                  stack.add(_ConvThen(_Conv(mv1, mv2, level)));
                  step = _Conv(sv1, sv2, level);
                }
              }
            }

          // VQuot × VQuot: compare carriers, then relations.
          case (
            VQuot(carrier: final c1, relation: final r1),
            VQuot(carrier: final c2, relation: final r2),
          ):
            stack.add(_ConvThen(_Conv(r1, r2, level)));
            step = _Conv(c1, c2, level);

          // VQuotMk × VQuotMk: identity only (no pointwise equality).
          case (VQuotMk(arg: final a1), VQuotMk(arg: final a2)):
            step = _YieldC(identical(a1, a2) ? _ok : ConvMismatch(a, b));

          // VQuotLift × VQuotLift: compare pointwise.
          case (
            VQuotLift(quot: final q1, fn: final f1, proof: final p1),
            VQuotLift(quot: final q2, fn: final f2, proof: final p2),
          ):
            stack.add(_ConvThen(_Conv(f1, f2, level)));
            stack.add(_ConvThen(_Conv(p1, p2, level)));
            step = _Conv(q1, q2, level);

          // Any other shape combination: try flex-rigid
          // pattern unification first (if one side is a meta-headed
          // neutral and the other is rigid), then fall back to the
          // mismatch/irrelevance path.
          default:
            if (metas != null) {
              final r = _tryUnify(a, b, level, metas);
              if (r != null) {
                step = _YieldC(r);
                break;
              }
            }
            step = _YieldC(_mismatchOrIrrelevance(a, b, dataDecls));
        }

      // -----------------------------------------------------------------
      // _Subtype: cumulativity-aware comparison.
      //
      // Subtype differs from conv only at universes and Pi; everywhere
      // else it delegates to conv. See SPEC §8.3.
      // -----------------------------------------------------------------
      case _Subtype(:final got, :final expected, :final level):
        switch ((got, expected)) {
          // Type n ≤ Type m  iff  n ≤ m.
          case (VType(level: final lg), VType(level: final le)):
            step = _YieldC(
              _levelGte(le, lg) ? _ok : ConvMismatch(got, expected),
            );

          // Prop ≤ Prop.
          case (VProp(), VProp()):
            step = const _YieldC(_ok);

          // SProp ≤ SProp.
          case (VSProp(), VSProp()):
            step = const _YieldC(_ok);

          // SProp ≤ Prop (SProp eliminates into Prop).
          case (VSProp(), VProp()):
            step = const _YieldC(_ok);

          // Pi ≤ Pi: contravariant domain, covariant codomain.
          case (
            VPi(domain: final dg, codomain: final cg),
            VPi(domain: final de, codomain: final ce),
          ):
            // Contravariant: subtype(expected's domain, got's domain).
            // On success, open both and subtype covariantly via
            // _ConvThenOpen's asSubtype path.
            stack.add(
              _ConvThenOpen(VLam(dg, cg), VLam(de, ce), level, asSubtype: true),
            );
            step = _Subtype(de, dg, level);

          // Everything else: fall back to strict equality.
          default:
            step = _Conv(got, expected, level);
        }

      // -----------------------------------------------------------------
      // _Infer: bidirectional type inference.
      // -----------------------------------------------------------------
      case _Infer(:final ctx, :final term):
        switch (term) {
          case TType(:final level):
            step = _YieldV(VType(_normalizeLevel(LSucc(level))));

          case TProp():
            // Prop : Type 1 (SPEC §8.2).
            step = const _YieldV(_vType1);

          case TSProp():
            // SProp : Type 1 (same cumulativity as Prop).
            step = const _YieldV(_vType1);

          case TBound(:final index):
            step = _YieldV(ctx.lookupType(index));

          case TFree(:final name):
            throw UnexpectedFree(name);

          case TPi(:final domain, :final codomain):
            stack.add(_InferPiHaveDomType(ctx, domain, codomain));
            step = _Infer(ctx, domain);

          case TApp(:final fn, :final arg):
            stack.add(_InferAppHaveFnType(ctx, arg));
            step = _Infer(ctx, fn);

          case TLam(:final domain, :final body, :final name):
            stack.add(_InferLamHaveDomType(ctx, domain, body, name));
            step = _Infer(ctx, domain);

          case TLet(:final domain, :final bound, :final body, :final name):
            stack.add(_InferLetHaveDomType(ctx, domain, bound, body, name));
            step = _Infer(ctx, domain);

          case TData(:final name, :final args):
            // Look up the inductive declaration in the ctx's registry
            // (populated by TopEnv.toCtx()).
            final decl = ctx.lookupData(name);
            if (decl == null) throw UnknownDataOrCtor(name);
            final expected = decl.params.length + decl.indices.length;
            if (args.length != expected) {
              throw InductiveArityMismatch(
                dataName: name,
                gotArity: args.length,
                expectedArity: expected,
              );
            }
            if (args.isEmpty) {
              // Nullary data type: its type is just the target sort,
              // evaluated under the empty telescope env (the sort can't
              // depend on parameters or indices since there are none).
              step = _Eval(decl.sort, const ENil());
            } else {
              // Schedule check of args[0] against the first telescope
              // entry's type, then the AfterCheck frame drives the rest.
              final firstExpected = eval(
                _indexTelescope(decl, null, 0).type,
                const ENil(),
              );
              stack.add(
                _InferIndAfterCheck(
                  dataDecl: decl,
                  ctorDecl: null,
                  ctx: ctx,
                  args: args,
                  index: 0,
                  teleEnv: const ENil(),
                ),
              );
              step = _Check(ctx, args[0], firstExpected);
            }

          case TConstr(:final dataName, :final ctorName, :final args):
            final dataDecl = ctx.lookupData(dataName);
            if (dataDecl == null) throw UnknownDataOrCtor(dataName);
            final ctorDecl = ctx.lookupCtor(dataName, ctorName);
            if (ctorDecl == null) {
              throw UnknownDataOrCtor(dataName, ctorName);
            }
            final expected = dataDecl.params.length + ctorDecl.args.length;
            if (args.length != expected) {
              throw InductiveArityMismatch(
                dataName: dataName,
                ctorName: ctorName,
                gotArity: args.length,
                expectedArity: expected,
              );
            }
            if (args.isEmpty) {
              // Nullary constructor. Result is
              // VData(dataName, <evaluated resultIndices under empty env>).
              final resultIndexVals = <Value>[
                for (final t in ctorDecl.resultIndices) eval(t, const ENil()),
              ];
              step = _YieldV(VData(dataName, resultIndexVals));
            } else {
              final firstExpected = eval(
                _indexTelescope(dataDecl, ctorDecl, 0).type,
                const ENil(),
              );
              stack.add(
                _InferIndAfterCheck(
                  dataDecl: dataDecl,
                  ctorDecl: ctorDecl,
                  ctx: ctx,
                  args: args,
                  index: 0,
                  teleEnv: const ENil(),
                ),
              );
              step = _Check(ctx, args[0], firstExpected);
            }

          case TRec(:final dataName, :final motiveSort):
            // The recursor's type is mechanically derived from the
            // DataDecl. Look up the decl and synthesize its type term;
            // evaluate that term under the ctx's env to return its
            // VPi-chain value. motiveSort, when non-null, selects the
            // large-elim variant (T.rect) instead of the default T.rec.
            final decl = ctx.lookupData(dataName);
            if (decl == null) throw UnknownDataOrCtor(dataName);
            step = _Eval(
              synthRecursorType(decl, motiveSort: motiveSort),
              ctx.env,
            );

          case TTop(:final name):
            // Mirror the _Eval TTop dispatch, prefer the
            // _drive-level threaded topBindings over the
            // ctx env's map. See the matching comment in _Eval above.
            final entry =
                (topBindings != null ? topBindings[name] : null) ??
                ctx.env.lookupTop(name);
            if (entry == null) {
              throw StateError(
                'infer reached TTop($name) with no matching entry in '
                'env.topBindings. Kernel invariant violation: the '
                'elaborator only emits TTop for registered top-level '
                'names.',
              );
            }
            step = _YieldV(entry.type);

          case TMeta(:final id):
            // Look up the meta's declared expected type in
            // the context's meta-context. The elaborator always
            // creates a TermMetaUnsolved with a concrete expected
            // type; reaching infer without that invariant means a
            // metavariable escaped without being registered.
            final metas = ctx.metas;
            if (metas == null) {
              throw StateError(
                'infer reached TMeta($id) with no MetaContext on ctx. '
                'Kernel invariant: metas require Ctx.metas != null.',
              );
            }
            final entry = metas.lookup(id);
            switch (entry) {
              case TermMetaUnsolved(:final typeExpected):
                step = _YieldV(typeExpected);
              case TermMetaSolved(:final typeExpected):
                // Return the PRE-SOLVE expected type, not
                // a re-inference of the solution term. Pattern-unif
                // solutions can contain quoted stuck forms (e.g.
                // `TMatch(null motive)`) that are well-typed only
                // in a specific check context, not standalone
                // infer. Lean/Coq/Agda store meta type separately
                // from solution for this reason.
                step = _YieldV(typeExpected);
            }

          case TMatch(:final motive):
            // Infer mode.
            //
            // With an explicit `returning P` clause, the match's
            // inferred type is P, and the arm bodies must actually
            // check against P for the inference to be sound. So we
            // re-dispatch as a check against motiveV: that runs the
            // full arm-checking machinery and then yields motiveV as
            // the success value (which is what infer mode wants).
            //
            // Without a motive clause, inference is not possible:
            // the user must either add `returning` or place the
            // match in a check-mode position (where the expected type
            // supplies the motive, and metavariables/index refinement
            // recover indexed-family motives).
            if (motive == null) {
              throw const MatchMotiveRequired();
            }
            stack.add(_InferMatchAfterMotive(ctx, term));
            step = _Eval(motive, ctx.env);

          case TQuot(:final carrier, :final relation):
            stack.add(_InferQuotHaveCarrierType(ctx, carrier, relation));
            step = _Infer(ctx, carrier);
            break;

          case TQuotMk():
            throw const QuotMkInInferMode();

          case TQuotLift(:final quot, :final fn):
            stack.add(_InferQuotLiftHaveQuotType(ctx, fn));
            step = _Infer(ctx, quot);
            break;

          case TProj(:final expr, :final fieldName):
            // Infer the type of expr, then extract the field's type
            // from the record's constructor.
            stack.add(_InferProjFieldType(fieldName));
            step = _Infer(ctx, expr);
        }

      // -----------------------------------------------------------------
      // _Check: bidirectional type checking against an expected type.
      //
      // Specializes on (TLam, VPi) to descend under the binder without
      // first inferring a Pi. Falls through to infer+conv otherwise.
      // -----------------------------------------------------------------
      case _Check(:final ctx, :final term, :final expected):
        // Auto-refl. When the user writes bare
        // `refl` (no arguments) and the expected type's head is
        // Eq[A] x y with conv(A, x, y) success, synthesize
        // `TConstr("Eq", "refl", [A, x])` and re-check. The
        // elaborator resolved `refl` by name to `TConstr("Eq", "refl", [])`
        // which would otherwise fail arity. We rescue in check mode
        // where the expected type supplies A and x.
        //
        // Keyed on the literal name `"Eq"`, as Lean's elaborator
        // recognises equality by a hardcoded name. No kernel flag;
        // the prelude-declared `Eq` is recognized by name only.
        //
        // When conv(A, x, y) fails, fall through to structural check:
        // the user wrote refl for two values that aren't def. equal,
        // which the subsequent check-against-Eq will flag as a real
        // TypeMismatch.
        if (term is TConstr &&
            term.dataName == 'Eq' &&
            term.ctorName == 'refl' &&
            term.args.isEmpty &&
            expected is VData &&
            expected.name == 'Eq' &&
            expected.args.length == 3) {
          final a = expected.args[0];
          final x = expected.args[1];
          final y = expected.args[2];
          final convResult = conv(
            ctx.level,
            x,
            y,
            dataDecls: ctx.dataDecls,
            metas: ctx.metas,
            topBindings: ctx.env.topBindings,
          );
          if (convResult is ConvOk) {
            // Rewrite the term with the A, x args filled in. Re-check.
            final aTerm = quote(ctx.level, a);
            final xTerm = quote(ctx.level, x);
            step = _Check(ctx, TConstr('Eq', 'refl', [aTerm, xTerm]), expected);
            break;
          }
          // conv failed: the two sides of the expected Eq aren't
          // def. equal. Raise a TypeMismatch directly against the
          // two Eq arguments (x vs y) so the user sees the actual
          // divergence, not a misleading arity error.
          throw TypeMismatch(
            x,
            y,
            convResult as ConvMismatch,
            level: ctx.level,
          );
        }
        if (term is TMatch) {
          // Check a match by inferring the scrutinee's type, then
          // checking each arm's body against `expected` under the
          // arm's binder-extended ctx. Motive inference is bounded to
          // the constant-motive case here, the motive placeholder
          // emitted by the elaborator (TType(0)) is treated as "use
          // `expected` as the constant motive". Explicit motives raise
          // a boundary error.
          stack.add(
            _CheckMatchScrutineeType(
              ctx: ctx,
              matchTerm: term,
              expected: expected,
            ),
          );
          step = _Infer(ctx, term.scrutinee);
        } else if (term is TLam && expected is VPi) {
          // Under cumulativity, the annotation on the lambda must
          // be contravariantly compared against the Pi's domain:
          // piDom ≤ annotation. A looser annotation is OK (the body
          // over-promises what it can consume); a tighter one is NOT
          // (the caller could pass values the body can't handle).
          //
          // Flow:
          //   1. Infer annotation's type (must be a sort).
          //   2. Evaluate annotation to get its value.
          //   3. Subtype-check piDom ≤ annotV.
          //   4. Extend ctx with piDom (NOT annotV, the body sees
          //      the caller's narrower view).
          //   5. Open Pi's codomain at fresh neutral.
          //   6. Check body against opened codomain.
          stack.add(
            _CheckLamAnnotDone(
              ctx,
              term.domain,
              term.body,
              expected.domain,
              expected.codomain,
              expected,
            ),
          );
          step = _Infer(ctx, term.domain);
        } else {
          // Fallback: infer the term's type, then subtype against
          // expected (cumulativity-aware, see _CheckFallbackGotType).
          stack.add(_CheckFallbackGotType(ctx.level, expected));
          step = _Infer(ctx, term);
        }

      // -----------------------------------------------------------------
      // _Apply: apply a function value to an argument value.
      // -----------------------------------------------------------------
      case _Apply(:final fn, :final arg):
        switch (fn) {
          case VLam(:final closure):
            // Lazy-motive: delay β when body has metas AND
            // the arg is a VConstr (ctor instance like `cons A h t`),
            // the pattern where eager β substitutes a non-variable
            // into the body's meta application spines and degrades
            // Miller pattern-fragment shape. VNeutral args (plain
            // variables, meta-headed neutrals) and non-VConstr canon-
            // icals are safe to β normally. Bodies without metas β
            // as before, the discriminator is AND: both meta-
            // containing body AND ctor-shaped arg.
            if (arg is VConstr && _termContainsMeta(closure.body)) {
              step = _YieldV(VDelayed(closure, arg));
            } else {
              step = _Eval(closure.body, closure.env.extend(arg));
            }

          case VFun(
            :final name,
            :final lam,
            :final decreasingArg,
            :final arity,
            :final spine,
          ):
            // Guarded fix-reduction. Accumulate the
            // arg onto the spine. Unfold (apply the underlying lambda to
            // the whole spine) ONLY when the spine is saturated AND the
            // decreasing-argument position holds a canonical VConstr
            // mirroring VRec's ι-reduction guard. Otherwise stay a stuck
            // VFun, which quotes to `TTop(name)` applied to the spine
            // (depth-portable; never frozen as an expanded match).
            final newSpine = [...spine, arg];
            final decArgFilled = newSpine.length > decreasingArg;
            final canUnfold =
                newSpine.length >= arity &&
                decArgFilled &&
                newSpine[decreasingArg] is VConstr;
            if (canUnfold) {
              // Unfold: apply the raw lambda to the accumulated spine.
              // Schedule the applications left-to-right via the apply
              // frame chain (driver-native, no host recursion).
              var v = lam;
              // Apply all but the last via a fold; the loop is bounded
              // by spine length (small), and each `apply` re-enters the
              // driver as its own bounded loop.
              for (final a in newSpine) {
                v = apply(v, a);
              }
              step = _YieldV(v);
            } else {
              step = _YieldV(VFun(name, lam, decreasingArg, arity, newSpine));
            }

          case VNeutral(:final neutral):
            // Stuck application: extend the spine.
            step = _YieldV(VNeutral(NApp(neutral, arg)));

          case VRec(:final dataDecl, :final spine):
            // Extend the recursor's spine. If the spine is now saturated
            // and the scrutinee position holds a canonical VConstr,
            // ι-reduction fires: dispatch to the method for that ctor,
            // applied to the ctor's non-param args (with a recursive
            // call inserted after each recursive-sub-data arg).
            //
            // Otherwise the recursor stays stuck (VRec with extended
            // spine). Users may then apply further args or embed the
            // stuck recursor in larger terms.
            final newSpine = [...spine, arg];
            final arity = _recursorArity(dataDecl);
            if (newSpine.length < arity) {
              step = _YieldV(VRec(dataDecl, newSpine));
              break;
            }
            // Saturated. Check the scrutinee.
            final scrut = arg;
            if (scrut is! VConstr || scrut.dataName != dataDecl.name) {
              // Either not a canonical ctor, or a ctor of a different
              // data type (kernel invariant violation, type checker
              // should have rejected this). Stay stuck.
              step = _YieldV(VRec(dataDecl, newSpine));
              break;
            }
            // Find the ctor's index to pick the corresponding method.
            var ctorIndex = -1;
            for (var i = 0; i < dataDecl.ctors.length; i++) {
              if (dataDecl.ctors[i].name == scrut.ctorName) {
                ctorIndex = i;
                break;
              }
            }
            if (ctorIndex < 0) {
              throw StateError(
                'ι-reduction: VConstr(${dataDecl.name}.${scrut.ctorName}) '
                'does not match any ctor of ${dataDecl.name}. Kernel '
                'invariant violation.',
              );
            }
            final ctorDecl = dataDecl.ctors[ctorIndex];
            // Spine layout: [params..., motive, indices..., method_0, ...,
            // method_{n-1}, scrutinee]
            final paramCount = dataDecl.params.length;
            final indexCount = dataDecl.indices.length;
            final method = newSpine[paramCount + 1 + indexCount + ctorIndex];
            // Build the argument list for the method by walking the
            // ctor's args telescope. Ordering per CIC convention: all
            // ctor-args first, then all IHs (one per recursive
            // ctor-arg) after.
            //
            // IHs are computed via DRIVER-NATIVE sub-ι-reduction: an
            // inline `apply(VRec(head), subArg)` call would re-enter
            // the driver, so a D-deep succ-tower scrutinee would
            // produce D nested Dart frames (breaking stack safety).
            //
            // Scheme: collect methodArgs and ihs in a bounded Dart
            // loop (safe, bounded by ctorDecl.args.length), but for
            // each recursive arg schedule a driver step via a
            // _RecCollectIH frame. The ihs list accumulates as the
            // driver yields each IH value.
            final headSpineLen =
                paramCount + 1 + indexCount + dataDecl.ctors.length;
            final headSpine = newSpine.sublist(0, headSpineLen);

            // Fast path: no recursive args in this ctor. No IH
            // computation needed; directly apply method to
            // non-param ctor args.
            var hasRecursive = false;
            for (var j = 0; j < ctorDecl.args.length; j++) {
              if (_isRecursiveOccurrence(
                dataDecl.name,
                ctorDecl.args[j].type,
              )) {
                hasRecursive = true;
                break;
              }
            }

            if (!hasRecursive) {
              final methodArgs = <Value>[
                for (var j = 0; j < ctorDecl.args.length; j++)
                  scrut.args[paramCount + j],
              ];
              if (methodArgs.isEmpty) {
                step = _YieldV(method);
              } else if (methodArgs.length == 1) {
                step = _Apply(method, methodArgs[0]);
              } else {
                stack.add(_ApplyChain(methodArgs, 1));
                step = _Apply(method, methodArgs[0]);
              }
              break;
            }

            // Recursive-args path: start with methodArgs =
            // [scrut.args[paramCount..]]. Walk the ctor's args via
            // _RecCollectIH frames, computing one IH per recursive
            // position in the driver loop.
            final methodArgs = <Value>[
              for (var j = 0; j < ctorDecl.args.length; j++)
                scrut.args[paramCount + j],
            ];
            final ihs = <Value>[];
            // Find the first recursive arg to start the IH walk.
            var firstRecJ = -1;
            for (var j = 0; j < ctorDecl.args.length; j++) {
              if (_isRecursiveOccurrence(
                dataDecl.name,
                ctorDecl.args[j].type,
              )) {
                firstRecJ = j;
                break;
              }
            }
            // Push a frame to resume after this first IH's _Apply
            // yields. Subsequent recursive args queue through the
            // same frame's advance logic.
            stack.add(
              _RecCollectIH(
                method: method,
                dataDecl: dataDecl,
                ctorDecl: ctorDecl,
                headSpine: headSpine,
                scrutArgs: scrut.args,
                paramCount: paramCount,
                subArgIndex: firstRecJ,
                methodArgs: methodArgs,
                ihs: ihs,
              ),
            );
            step = _Apply(
              VRec(dataDecl, headSpine),
              scrut.args[paramCount + firstRecJ],
            );

          case VMatch():
            // A stuck match applied to an argument becomes a neutral
            // application with the match as the stuck head. If the
            // match later reduces (because its scrutinee becomes
            // canonical in an outer context, e.g. if nested inside
            // another match that later dispatches), the neutral
            // spine will be rebuilt by conv/quote walkers.
            step = _YieldV(VNeutral(NApp(NStuck(fn), arg)));

          case VQuotLift(quot: VQuotMk(:final arg), :final fn):
            // ι-reduction: lift(mk(a), f, proof) → f(a), then apply
            // the current arg to the result.
            stack.add(_ApplyArg(arg));
            step = _Apply(fn, arg);

          case VQuotLift():
            // Stuck VQuotLift applied to an arg becomes a neutral.
            // The quot is not VQuotMk, so the lift stays stuck.
            step = _YieldV(VNeutral(NApp(NStuck(fn), arg)));

          case VDelayed(:final closure, arg: final dArg):
            // Lazy-motive: force the delayed β-redex (the
            // head is a VLam-shaped closure waiting on dArg), then
            // apply the NEW arg to the forced result. Two-step
            // rewrite rather than one: `_ApplyArg(arg)` records the
            // new-arg to re-apply once forcing yields a value. We use
            // `_ApplyArg` (apply forced-head to stored arg), NOT
            // `_ApplyFn` (which would apply the stored arg AS A
            // FUNCTION to the forced head, backwards). The two-binder
            // motive path `(P i) c` exercises this: `P i` is the
            // VDelayed head, `c` the pending arg.
            stack.add(_ApplyArg(arg));
            step = _Eval(closure.body, closure.env.extend(dArg));

          case VType():
          case VProp():
          case VSProp():
          case VPi():
          case VData():
          case VConstr():
          case VQuot():
          case VQuotMk():
            throw StateError(
              'apply: attempted to apply a non-function value '
              '(${fn.runtimeType}). Kernel invariant violated.',
            );
        }

      // -----------------------------------------------------------------
      // _Quote: reify a value to a term at a given context depth.
      // -----------------------------------------------------------------
      case _Quote(:final value, :final level):
        switch (value) {
          case VType(level: final l):
            step = _YieldT(TType(l));

          case VProp():
            step = const _YieldT(TProp());

          case VSProp():
            step = const _YieldT(TSProp());

          case VPi(:final domain, :final codomain, :final name, :final icit):
            // Fast path: the codomain closure was built by
            // _InferLamHaveBodyTerm with a body already in normal
            // form under env.extend(fresh). That's precisely the
            // shape the open/eval/quote round-trip would produce,
            // so reuse the body directly. Requires level alignment:
            // the closure expects a fresh neutral at level
            // `codomain.env.depth`, which must equal the current
            // `level` for the body's indices to remain valid.
            if (codomain.bodyIsNormal && codomain.env.depth == level) {
              stack.add(_QPiBuildNormal(codomain.body, name, icit));
              step = _Quote(domain, level);
            } else {
              // Schedule "after domain is quoted, open and quote codomain".
              stack.add(_QPiCod(codomain, level, name, icit));
              step = _Quote(domain, level);
            }

          case VLam(:final domain, :final closure, :final name, :final icit):
            stack.add(_QLamBody(closure, level, name, icit));
            step = _Quote(domain, level);

          case VNeutral(:final neutral):
            // Walk the neutral spine outward, pushing _QAppArg frames so
            // that args are quoted leftmost-first when the frames fire.
            // This walk uses a local while-loop, not recursion, depth
            // here is spine length, not binder depth.
            var n = neutral;
            while (n is NApp) {
              stack.add(_QAppArg(n.arg, level));
              n = n.fn;
            }
            switch (n) {
              case NVar(level: final nvarLevel):
                // Convert level to de Bruijn index relative to the
                // current depth.
                step = _YieldT(TBound(level - nvarLevel - 1));
              case NStuck(:final value):
                // Descend into the wrapped stuck value; its quote form
                // is the head of the app spine we just pushed.
                step = _Quote(value, level);
              case NTop(:final name):
                // A top-level stub quotes back to TTop(name), a
                // kernel term the elaborator round-trips cleanly.
                step = _YieldT(TTop(name));
              case NMeta(:final id):
                // Unsolved metavariable. Quote to TMeta(id);
                // any spine applied to it was already pushed as
                // _QAppArg frames in the loop above, so the final
                // term is TApp(...TApp(TMeta(id), arg1)...argN).
                step = _YieldT(TMeta(id));
              case NProj(:final expr, :final fieldName):
                step = _YieldT(TProj(quote(level, expr), fieldName));
              case NApp():
                // Loop invariant: we walked past all NApps above.
                throw StateError(
                  'neutral spine walk ended at an NApp, unreachable',
                );
            }

          case VData(name: final n, args: final vargs):
            if (vargs.isEmpty) {
              step = _YieldT(TData(n, const <Term>[]));
            } else {
              stack.add(_QDataArg(n, <Term>[], vargs, 1, level));
              step = _Quote(vargs[0], level);
            }

          case VConstr(
            dataName: final dn,
            ctorName: final cn,
            args: final vargs,
          ):
            if (vargs.isEmpty) {
              step = _YieldT(TConstr(dn, cn, const <Term>[]));
            } else {
              stack.add(_QConstrArg(dn, cn, <Term>[], vargs, 1, level));
              step = _Quote(vargs[0], level);
            }

          case VRec(:final dataDecl, :final spine):
            // Quote as TRec(dataName) applied to each spine entry via
            // a left-folded TApp chain. Uses _QAppArg / _QAppBuild
            // frames (the same pattern VNeutral uses for its spine).
            // Walk the spine outermost-first: push _QAppArg frames for
            // each entry in REVERSE so they pop in forward order,
            // producing `App(App(...App(TRec(name), s0), s1), ..., sn)`.
            for (var i = spine.length - 1; i >= 0; i--) {
              stack.add(_QAppArg(spine[i], level));
            }
            step = _YieldT(TRec(dataDecl.name));

          case VFun(:final name, :final spine):
            // A stuck guarded fun quotes to
            // `TTop(name)` applied to its accumulated spine, exactly
            // the shape it was built from, so the round-trip re-evals
            // to the same VFun at ANY depth (depth-portable; this is
            // what guarding is for: no frozen-match arm bodies).
            for (var i = spine.length - 1; i >= 0; i--) {
              stack.add(_QAppArg(spine[i], level));
            }
            step = _YieldT(TTop(name));

          case VMatch(
            scrutinee: final sv,
            motive: final mv,
            :final cases,
            :final env,
          ):
            // Quote arm bodies via substitution, each free TBound in
            // the body reindexed to reflect its outer-scope binder
            // position.
            //
            // Two regimes, by the shape of the VMatch's captured env:
            //   * "Trivial identity" env (every env.lookup(i) =
            //     NVar(env.depth - 1 - i), i.e. fresh neutrals numbered
            //     by position): a uniform shift suffices. This is the
            //     deep-nested-VMatch stack-stress shape
            //     verbatim-with-shift is O(1) per layer, stack-safe.
            //   * Non-trivial envs (e.g. β-reduced stuck matches where
            //     the env captured outer NVars) need full substitution
            //     via a structural walk; `_substArmBody` handles those.
            //
            // Two failure modes this avoids: eval'ing bodies under fresh
            // neutrals can unfold TTop refs into new stuck VMatches and
            // recurse forever (OOM); preserving bodies verbatim without
            // reindexing leaves arm TBounds indexed against the VMatch's
            // env rather than the outer scope (semantically wrong when
            // the substituted expected is later eval'd).
            final shift = level - env.depth;
            final Term Function(VMatchCase) quoteArm;
            if (_envIsTrivialIdentity(env)) {
              quoteArm =
                  (c) =>
                      shift == 0
                          ? c.body
                          : _shiftTBoundPastThreshold(
                            c.body,
                            threshold: c.nBinders,
                            shiftBy: shift,
                          );
            } else {
              quoteArm =
                  (c) => _substArmBody(
                    c.body,
                    env: env,
                    level: level,
                    nBinders: c.nBinders,
                    metas: metas,
                  );
            }
            final quotedArms = <TMatchCase>[
              for (final c in cases)
                TMatchCase(
                  c.ctorName,
                  c.nBinders,
                  quoteArm(c),
                  c.binderNames,
                  span: c.span,
                ),
            ];
            stack.add(_QMatchAfterScrutinee(mv, quotedArms, level));
            step = _Quote(sv, level);

          case VDelayed(:final closure, :final arg):
            // Quote forces VDelayed: eval the closure body under
            // the extended env, then quote the resulting value.
            // VDelayed is an elaboration-time stuck shape; when
            // reified for diagnostics or meta-solution storage,
            // the β-reduction is completed. (Conv avoids quote
            // it handles VDelayed structurally at the Value level.)
            stack.add(_QuoteAt(level));
            step = _Eval(closure.body, closure.env.extend(arg));

          case VQuot(:final carrier, :final relation):
            stack.add(_QQuotRelation(relation, level));
            step = _Quote(carrier, level);

          case VQuotMk(:final arg):
            stack.add(const _QQuotMk());
            step = _Quote(arg, level);

          case VQuotLift(:final quot, :final fn, :final proof):
            stack.add(_QQuotLiftFn(fn, proof, level));
            step = _Quote(quot, level);
        }

      // -----------------------------------------------------------------
      // _YieldV: a value has been produced; dispatch on the top frame.
      // -----------------------------------------------------------------
      case _YieldV(:final value):
        if (stack.isEmpty) {
          return value;
        }
        final frame = stack.removeLast();
        switch (frame) {
          case _EvalArg(:final arg, :final env):
            stack.add(_ApplyFn(value));
            step = _Eval(arg, env);

          case _ApplyFn(:final fn):
            step = _Apply(fn, value);

          case _ApplyArg(:final arg):
            step = _Apply(value, arg);

          case _BuildLam(:final env, :final body, :final nameHint, :final icit):
            step = _YieldV(
              VLam(value, Closure(env, body), name: nameHint, icit: icit),
            );

          case _BuildPi(
            :final env,
            :final codomain,
            :final nameHint,
            :final icit,
          ):
            step = _YieldV(
              VPi(value, Closure(env, codomain), name: nameHint, icit: icit),
            );

          case _EvalLetBody(
            :final env,
            :final body,
            :final isRec,
            :final name,
            :final decreasingArg,
            :final arity,
          ):
            // `value` is the evaluated bound expression. Extend env
            // and evaluate the body; no VLet is produced.
            if (isRec) {
              final vfun = VFun(
                name as String,
                value,
                decreasingArg!,
                arity!,
                const <Value>[],
              );
              step = _Eval(body, env.extend(vfun));
            } else {
              step = _Eval(body, env.extend(value));
            }

          case _MatchAfterScrutinee(:final motive, :final cases, :final env):
            // `value` is the scrutineeV. Three cases:
            //  1. Canonical VConstr → dispatch immediately (skip motive
            //     eval; motive is not consumed by ι-reduction).
            //  2. Stuck + null source motive → build VMatch with null
            //     motive directly.
            //  3. Stuck + explicit source motive → evaluate motive,
            //     then build VMatch with the resulting motiveV.
            if (value is VConstr) {
              final paramCount = _dataParamCount(env, value.dataName);
              TMatchCase? matched;
              for (final arm in cases) {
                if (!arm.isWildcard && arm.ctorName == value.ctorName) {
                  matched = arm;
                  break;
                }
              }
              if (matched == null) {
                for (final arm in cases) {
                  if (arm.isWildcard) {
                    matched = arm;
                    break;
                  }
                }
              }
              if (matched == null) {
                // Coverage check at elaboration should prevent this.
                throw StateError(
                  'match: no arm for VConstr(${value.dataName}.'
                  '${value.ctorName}) and no wildcard present. '
                  'Elaborator coverage check violated.',
                );
              }
              // Extend env with the ctor's non-param args, innermost-
              // first. For `cons x xs` with paramCount=1,
              // value.args = [A, x, xs]; we want env.extend(x).extend(xs),
              // so `xs` is TBound(0) and `x` is TBound(1).
              var armEnv = env;
              final argsUsed = matched.nBinders;
              for (var i = 0; i < argsUsed; i++) {
                armEnv = armEnv.extend(value.args[paramCount + i]);
              }
              step = _Eval(matched.body, armEnv);
            } else if (motive == null) {
              // Stuck + null motive. Build VMatch with null motiveV.
              step = _YieldV(
                VMatch(value, null, [
                  for (final a in cases)
                    VMatchCase(
                      a.ctorName,
                      a.nBinders,
                      a.body,
                      a.binderNames,
                      span: a.span,
                    ),
                ], env),
              );
            } else {
              // Stuck + explicit motive. Evaluate motive, then build
              // VMatch via _MatchDispatch.
              stack.add(_MatchDispatch(value, cases, env));
              step = _Eval(motive, env);
            }

          case _MatchDispatch(:final scrutineeV, :final cases, :final env):
            // Only reached for stuck scrutinees with explicit motives.
            // `value` is the motiveV. Build the stuck VMatch.
            step = _YieldV(
              VMatch(scrutineeV, value, [
                for (final a in cases)
                  VMatchCase(
                    a.ctorName,
                    a.nBinders,
                    a.body,
                    a.binderNames,
                    span: a.span,
                  ),
              ], env),
            );

          case _BuildData(
            :final name,
            :final collected,
            :final args,
            :final nextIndex,
            :final env,
          ):
            collected.add(value);
            if (nextIndex == args.length) {
              step = _YieldV(VData(name, collected));
            } else {
              stack.add(_BuildData(name, collected, args, nextIndex + 1, env));
              step = _Eval(args[nextIndex], env);
            }

          case _BuildConstr(
            :final dataName,
            :final ctorName,
            :final collected,
            :final args,
            :final nextIndex,
            :final env,
          ):
            collected.add(value);
            if (nextIndex == args.length) {
              step = _YieldV(VConstr(dataName, ctorName, collected));
            } else {
              stack.add(
                _BuildConstr(
                  dataName,
                  ctorName,
                  collected,
                  args,
                  nextIndex + 1,
                  env,
                ),
              );
              step = _Eval(args[nextIndex], env);
            }

          case _EvalQuot(:final relation, :final env, :final carrier):
            if (carrier == null) {
              // First yield: value is the evaluated carrier.
              // Re-push with carrier stored, then eval relation.
              stack.add(_EvalQuot(relation, env, value));
              step = _Eval(relation, env);
            } else {
              // Second yield: value is the evaluated relation.
              step = _YieldV(VQuot(carrier, value));
            }

          case _EvalQuotMk():
            step = _YieldV(VQuotMk(value));

          case _EvalProj(:final fieldName):
            if (value is VConstr) {
              step = _YieldV(_projectField(value, fieldName, dataDecls));
            } else {
              step = _YieldV(VNeutral(NProj(value, fieldName)));
            }

          case _EvalQuotLift(
            :final fnTerm,
            :final proofTerm,
            :final env,
            :final quot,
            :final fn,
          ):
            if (quot == null) {
              // First yield: value is the evaluated quot.
              if (value is VQuotMk) {
                // ι-reduce: lift(mk(a), f, proof) → f(a)
                // Eval fn then apply to value.arg
                stack.add(_EvalQuotLift(fnTerm, proofTerm, env, value, null));
                step = _Eval(fnTerm, env);
              } else {
                // Stuck: continue accumulating
                stack.add(_EvalQuotLift(fnTerm, proofTerm, env, value, null));
                step = _Eval(fnTerm, env);
              }
            } else if (fn == null) {
              // Second yield: value is the evaluated fn.
              final q = quot;
              if (q is VQuotMk) {
                // ι-reduce: apply fn to quot.arg
                step = _Apply(value, q.arg);
              } else {
                // Store fn, eval proof
                stack.add(_EvalQuotLift(fnTerm, proofTerm, env, quot, value));
                step = _Eval(proofTerm, env);
              }
            } else {
              // Third yield: value is the evaluated proof. Produce VQuotLift.
              step = _YieldV(VQuotLift(quot, fn, value));
            }

          case _QuoteAt(:final level):
            step = _Quote(value, level);

          case _ConvPairLeft(
            :final rightV,
            :final applied,
            :final level,
            :final asSubtype,
          ):
            // The left side has been applied; stash the result and
            // schedule applying the right side to the same fresh neutral.
            stack.add(_ConvPairRight(value, level, asSubtype: asSubtype));
            step = _Apply(rightV, applied);

          case _ConvPairRight(
            :final stashedLeft,
            :final level,
            :final asSubtype,
          ):
            // Both sides have been applied. Compare the opened bodies
            // at the deeper level, via either subtype or strict conv
            // depending on how this pair was set up.
            step =
                asSubtype
                    ? _Subtype(stashedLeft, value, level)
                    : _Conv(stashedLeft, value, level);

          // --- infer(TPi) sequencing ---
          //
          // PTS sort rules (SPEC §8.2):
          //   dom : Prop,   cod : Prop   => Pi : Prop
          //   dom : Type n, cod : Prop   => Pi : Prop   (impredicative Prop)
          //   dom : Prop,   cod : Type m => Pi : Type m
          //   dom : Type n, cod : Type m => Pi : Type (max n m)
          //
          // So the rule is: if codomain is Prop, Pi is Prop; otherwise
          // Pi's level is the max of domain-level (0 for Prop) and
          // codomain-level.

          case _InferPiHaveDomType(:final ctx, :final dom, :final cod):
            // `value` is the domain's type. It must be a sort (Prop or
            // VType n).
            final domSort = _asSort(value);
            if (domSort == null) throw NotAType(value);
            stack.add(_InferPiHaveDomV(ctx, cod, domSort));
            step = _Eval(dom, ctx.env);

          case _InferPiHaveDomV(:final ctx, :final cod, :final domSort):
            // `value` is the evaluated domain. Extend the ctx and infer
            // the codomain, carrying the stashed domain sort forward.
            // Quick path for sort-literal codomains: avoid losing
            // the specific sort through type inference (Prop/SProp
            // both infer as VType(1)).
            if (cod is TSProp) {
              step = _YieldV(_piSort(domSort, _sPropSort));
              break;
            }
            if (cod is TProp) {
              step = _YieldV(_piSort(domSort, _propSort));
              break;
            }
            stack.add(_InferPiHaveCodType(domSort));
            step = _Infer(ctx.extend(value), cod);

          case _InferPiHaveCodType(:final domSort):
            // `value` is the codomain's type, Prop or Type m.
            final codSort = _asSort(value);
            if (codSort == null) throw NotAType(value);
            step = _YieldV(_piSort(domSort, codSort));

          // --- infer(TApp) sequencing ---

          case _InferAppHaveFnType(:final ctx, :final arg):
            // `value` is the function's type. It must be a VPi.
            if (value is! VPi) throw NotAFunction(value);
            stack.add(_InferAppHaveCheck(value.codomain, arg, ctx.env));
            step = _Check(ctx, arg, value.domain);

          case _InferAppHaveCheck(:final cod, :final arg, :final env):
            // `value` is the check-success sentinel (= the domain
            // expected); discard and schedule evaluating the argument.
            stack.add(_InferAppHaveArgV(cod));
            step = _Eval(arg, env);

          case _InferAppHaveArgV(:final cod):
            // `value` is the evaluated argument. Evaluate the codomain
            // body in the closure's env extended with the arg.
            step = _Eval(cod.body, cod.env.extend(value));

          case _InferProjFieldType(:final fieldName):
            // `value` is the inferred type of the record expression.
            // It must be VData(name, params) for a record type.
            if (value is VData) {
              final dDecl = _lookupData(value.name, dataDecls);
              if (dDecl != null && _isRecordData(dDecl)) {
                final ctor = dDecl.ctors.first;
                var fieldIndex = -1;
                for (var i = 0; i < ctor.args.length; i++) {
                  if (ctor.args[i].name == fieldName) {
                    fieldIndex = i;
                    break;
                  }
                }
                if (fieldIndex >= 0) {
                  final fieldTypeTerm = ctor.args[fieldIndex].type;
                  // Build env: preceding args as placeholders, then params
                  // + preceding fields. Fields after fieldIndex are NOT
                  // pushed so de Bruijn indices in the field type resolve
                  // correctly against (params + preceding fields only).
                  Env env = const ENil();
                  for (var j = 0; j < fieldIndex; j++) {
                    env = env.extend(VNeutral(NVar(1000 + j)));
                  }
                  for (
                    var j = dDecl.params.length + fieldIndex - 1;
                    j >= 0;
                    j--
                  ) {
                    env = env.extend(value.args[j]);
                  }
                  step = _YieldV(eval(fieldTypeTerm, env));
                  break;
                }
              }
            }
            throw StateError(
              'infer TProj: expected record type with field $fieldName, '
              'got ${value.runtimeType}',
            );

          // --- infer(TLam) sequencing ---

          case _InferLamHaveDomType(
            :final ctx,
            :final dom,
            :final body,
            :final nameHint,
          ):
            // The domain annotation must be a sort (Prop or Type n).
            if (_asSort(value) == null) throw NotAType(value);
            stack.add(_InferLamHaveDomV(ctx, body, nameHint));
            step = _Eval(dom, ctx.env);

          case _InferLamHaveDomV(:final ctx, :final body, :final nameHint):
            // `value` is the evaluated domain. Save ctx.env and this
            // domV for building the VPi later. Infer the body under
            // the extended ctx; the body's level is ctx.level+1.
            stack.add(
              _InferLamHaveBodyType(ctx.env, value, ctx.level + 1, nameHint),
            );
            step = _Infer(ctx.extend(value), body);

          case _InferLamHaveBodyType(
            :final env,
            :final domV,
            :final bodyLevel,
            :final nameHint,
          ):
            // `value` is the body's type. Quote it at bodyLevel to get
            // a term suitable for placing in a closure over `env`.
            stack.add(_InferLamHaveBodyTerm(env, domV, nameHint));
            step = _Quote(value, bodyLevel);

          // --- infer(TLet) sequencing ---

          case _InferLetHaveDomType(
            :final ctx,
            :final domain,
            :final bound,
            :final body,
            :final nameHint,
          ):
            // `value` is the domain's type. Require sort.
            if (_asSort(value) == null) throw NotAType(value);
            stack.add(_InferLetHaveDomV(ctx, bound, body, nameHint));
            step = _Eval(domain, ctx.env);

          case _InferLetHaveDomV(
            :final ctx,
            :final bound,
            :final body,
            :final nameHint,
          ):
            // `value` is the evaluated domain. Check that the bound
            // expression has this type.
            stack.add(_InferLetHaveCheck(ctx, bound, body, value, nameHint));
            step = _Check(ctx, bound, value);

          case _InferLetHaveCheck(
            :final ctx,
            :final bound,
            :final body,
            :final domainV,
          ):
            // `value` is the check-success sentinel (= domainV). Eval
            // the bound expression to get its value for the ctx.
            stack.add(_InferLetHaveBoundV(ctx, body, domainV));
            step = _Eval(bound, ctx.env);

          case _InferLetHaveBoundV(:final ctx, :final body, :final domainV):
            // `value` is the evaluated bound expression. Extend the
            // ctx with (domainV, boundV) and infer the body.
            step = _Infer(ctx.extendWith(domainV, value), body);

          // --- ι-reduction apply-chain sequencing ---

          case _ApplyChain(:final args, :final nextIndex):
            // `value` is the just-applied function. Apply it to the
            // next argument; if more remain, push another chain frame
            // for subsequent steps.
            if (nextIndex + 1 < args.length) {
              stack.add(_ApplyChain(args, nextIndex + 1));
            }
            step = _Apply(value, args[nextIndex]);

          // --- infer(TData / TConstr) sequencing ---

          case _InferIndAfterCheck(
            :final dataDecl,
            :final ctorDecl,
            :final ctx,
            :final args,
            :final index,
            :final teleEnv,
          ):
            // `value` is the check-success sentinel (= the expected
            // type of args[index]). Discard it; schedule evaluating
            // args[index] so we can extend the telescope env with its
            // value before checking the next arg.
            stack.add(
              _InferIndAfterEval(
                dataDecl: dataDecl,
                ctorDecl: ctorDecl,
                ctx: ctx,
                args: args,
                index: index,
                teleEnv: teleEnv,
              ),
            );
            step = _Eval(args[index], ctx.env);

          case _InferIndAfterEval(
            :final dataDecl,
            :final ctorDecl,
            :final ctx,
            :final args,
            :final index,
            :final teleEnv,
          ):
            // `value` is the evaluated args[index]. Extend the
            // telescope env and either schedule the next arg or
            // produce the final inferred type.
            final extended = teleEnv.extend(value);
            final nextIndex = index + 1;
            if (nextIndex == args.length) {
              // All args processed. Build the result Value.
              if (ctorDecl == null) {
                // TData head: result is the target sort evaluated
                // under the telescope env (though sorts don't actually
                // depend on the telescope; evaluating is uniform).
                step = _Eval(dataDecl.sort, extended);
              } else {
                // TConstr head: result is
                // VData(dataName, paramVals ++ resultIndexVals),
                // where paramVals are the first params.length entries
                // of `extended` (innermost-first in env; outermost-
                // first as arg order) and resultIndexVals come from
                // evaluating each ctorDecl.resultIndices term under
                // `extended`.
                final paramCount = dataDecl.params.length;
                // extended has `args.length` values, innermost-first.
                // arg i was pushed at the i-th iteration, so it lives
                // at index (args.length - 1 - i) in the env. Read out
                // the first paramCount args (i = 0..paramCount-1).
                final paramVals = <Value>[
                  for (var i = 0; i < paramCount; i++)
                    extended.lookup(args.length - 1 - i),
                ];
                final resultIndexVals = <Value>[
                  for (final t in ctorDecl.resultIndices) eval(t, extended),
                ];
                step = _YieldV(
                  VData(dataDecl.name, [...paramVals, ...resultIndexVals]),
                );
              }
            } else {
              // Evaluate expected type of next arg under the extended
              // telescope env, then schedule its check.
              final nextExpected = eval(
                _indexTelescope(dataDecl, ctorDecl, nextIndex).type,
                extended,
              );
              stack.add(
                _InferIndAfterCheck(
                  dataDecl: dataDecl,
                  ctorDecl: ctorDecl,
                  ctx: ctx,
                  args: args,
                  index: nextIndex,
                  teleEnv: extended,
                ),
              );
              step = _Check(ctx, args[nextIndex], nextExpected);
            }

          // --- check(TLam, VPi) sequencing ---

          case _CheckLamAnnotDone(
            :final ctx,
            :final annotTerm,
            :final body,
            :final piDom,
            :final piCod,
            :final expected,
          ):
            // `value` is the annotation's type. It must be a sort
            // (Prop or Type n). Then evaluate the annotation term
            // itself so we can subtype-compare it against the Pi's
            // domain contravariantly.
            if (_asSort(value) == null) throw NotAType(value);
            stack.add(_CheckLamAnnotV(ctx, body, piDom, piCod, expected));
            step = _Eval(annotTerm, ctx.env);

          case _CheckLamAnnotV(
            :final ctx,
            :final body,
            :final piDom,
            :final piCod,
            :final expected,
          ):
            // `value` is the evaluated annotation. Schedule
            // subtype(piDom, annotV), contravariant. On success, we
            // descend into the body with bodyCtx extended with piDom.
            stack.add(
              _CheckLamAnnotSubtype(ctx, body, piDom, piCod, value, expected),
            );
            step = _Subtype(piDom, value, ctx.level);

          case _CheckLamOpenedCod(:final bodyCtx, :final body, :final expected):
            // `value` is the opened codomain. Check the body against it.
            // The check will yield `value` on success; we need to yield
            // `expected` (the original Pi) as the check's top-level
            // success value. So wrap the whole check in a frame that
            // replaces the final yield.
            stack.add(_CheckSuccessYield(expected));
            step = _Check(bodyCtx, body, value);

          // --- check fallback sequencing ---

          case _CheckFallbackGotType(:final level, :final expected):
            // `value` is the inferred type. Use subtype (not strict
            // conv) so cumulativity lets `Type n` flow into a context
            // expecting `Type m` when n ≤ m. See SPEC §8.3.
            stack.add(_CheckFallbackConvResult(value, expected, level));
            step = _Subtype(value, expected, level);

          case _CheckSuccessYield(:final expected):
            // A successful check in a nested position has just yielded
            // its expected value; replace it with ours and continue.
            step = _YieldV(expected);

          case _InferMatchAfterMotive(:final ctx, :final matchTerm):
            // `value` is the motiveV. Re-dispatch as _Check against
            // motiveV, that runs the full arm-checking machinery and
            // ultimately yields motiveV back, which is what the
            // enclosing infer chain consumes.
            step = _Check(ctx, matchTerm, value);

          case _RecCollectIH(
            :final method,
            :final dataDecl,
            :final ctorDecl,
            :final headSpine,
            :final scrutArgs,
            :final paramCount,
            :final subArgIndex,
            :final methodArgs,
            :final ihs,
          ):
            // `value` is the IH for ctor-arg [subArgIndex] (the
            // recursive call's result). Accumulate and look for the
            // next recursive arg.
            ihs.add(value);
            var nextJ = -1;
            for (var j = subArgIndex + 1; j < ctorDecl.args.length; j++) {
              if (_isRecursiveOccurrence(
                dataDecl.name,
                ctorDecl.args[j].type,
              )) {
                nextJ = j;
                break;
              }
            }
            if (nextJ < 0) {
              // All IHs collected. Apply method to
              // [methodArgs..., ihs...].
              final allArgs = <Value>[...methodArgs, ...ihs];
              if (allArgs.isEmpty) {
                step = _YieldV(method);
              } else if (allArgs.length == 1) {
                step = _Apply(method, allArgs[0]);
              } else {
                stack.add(_ApplyChain(allArgs, 1));
                step = _Apply(method, allArgs[0]);
              }
            } else {
              // Schedule the next IH. The recursor head is the same
              // (head spine is fixed once the recursor is saturated).
              stack.add(
                _RecCollectIH(
                  method: method,
                  dataDecl: dataDecl,
                  ctorDecl: ctorDecl,
                  headSpine: headSpine,
                  scrutArgs: scrutArgs,
                  paramCount: paramCount,
                  subArgIndex: nextJ,
                  methodArgs: methodArgs,
                  ihs: ihs,
                ),
              );
              step = _Apply(
                VRec(dataDecl, headSpine),
                scrutArgs[paramCount + nextJ],
              );
            }

          case _QMatchArmAfterEval(
            :final sv,
            :final mv,
            :final cases,
            :final env,
            :final level,
            :final builtArms,
            :final armIndex,
          ):
            // `value` is the evaluated body of arm [armIndex]. Now
            // quote it at the arm's extended depth.
            final arm = cases[armIndex];
            stack.add(
              _QMatchArmAfterQuote(
                sv: sv,
                mv: mv,
                cases: cases,
                env: env,
                level: level,
                builtArms: builtArms,
                armIndex: armIndex,
              ),
            );
            step = _Quote(value, level + arm.nBinders);

          case _CheckMatchScrutineeType(
            :final ctx,
            :final matchTerm,
            :final expected,
          ):
            // `value` is the scrutinee's inferred type. It must be a
            // VData(dataName, paramsV ++ indicesV); indices drive
            // index refinement for indexed families.
            if (value is! VData) {
              throw MatchScrutineeNotInductive(value);
            }
            final scrutineeData = ctx.lookupData(value.name);
            if (scrutineeData == null) {
              throw UnknownDataOrCtor(value.name);
            }
            // Verify: every ctor arm in the elaborated TMatch belongs
            // to this data type. The elaborator guesses the scrutinee
            // type from the FIRST ctor arm and rejects inter-arm ctor
            // mismatches at that candidate, but it can't know the
            // scrutinee's actual inferred type, that's the checker's
            // job. If they disagree, we raise a dedicated
            // ScrutineeTypeMismatchesArm so callers can render a
            // crisp diagnostic pointing at the offending arm.
            for (final arm in matchTerm.cases) {
              if (arm.isWildcard) continue;
              var armCtorParentData = '';
              var foundInScrutinee = false;
              for (final c in scrutineeData.ctors) {
                if (c.name == arm.ctorName) {
                  foundInScrutinee = true;
                  break;
                }
              }
              if (foundInScrutinee) continue;
              // Find which inductive this ctor actually belongs to
              // (if any) so the diagnostic can name it.
              for (final d in ctx.env.dataDecls) {
                for (final c in d.ctors) {
                  if (c.name == arm.ctorName) {
                    armCtorParentData = d.name;
                    break;
                  }
                }
                if (armCtorParentData.isNotEmpty) break;
              }
              throw ScrutineeTypeMismatchesArm(
                arm.ctorName,
                armCtorParentData,
                scrutineeData.name,
                arm.span.isSynthetic ? null : arm.span,
              );
            }
            // SPEC §8.2 Prop-elim restriction + singleton exception.
            //
            // A match on a Prop-sorted inductive cannot in general
            // produce a Type-sorted result: combined with definitional
            // proof irrelevance (SPEC §8.2), distinct
            // proofs are def. equal, so distinct Type-valued computed
            // results would violate reflexivity.
            //
            // The singleton exception: Prop → Type is ADMITTED when
            // the inductive has ≤ 1 ctor AND that ctor has no
            // "informative" args. An arg is non-informative when its
            // type is itself Prop-sorted (proof-irrelevant, no runtime
            // data content). Params and indices don't count, they're
            // not in `ctor.args`. The rule is stated GENERALLY on the
            // data's shape, not by inductive name; `Eq`, `True`, `And`
            // all qualify structurally. `Or` (2 ctors), `Sigma[_, T]`
            // with a Type-sorted witness (informative arg) do not.
            //
            // When admitted, `Eq.rec`-style transport works: a Prop
            // proof eliminates into a Type-sorted motive because the
            // proof carries no runtime information (only 0 or 1
            // possible canonical shape, inhabiting at most one
            // equivalence class).
            if (scrutineeData.sort is TProp) {
              final expectedTerm = quote(ctx.level, expected);
              final expectedSort = infer(ctx, expectedTerm);
              if (expectedSort is! VProp) {
                // Would be Prop → Type elimination. Admit only if the
                // singleton exception applies.
                if (!_admitsSingletonElim(scrutineeData, ctx)) {
                  throw PropEliminationIntoType(
                    scrutineeData.name,
                    expectedSort,
                  );
                }
              }
            }

            // Extract the param values and the index values. For
            // non-indexed data, indicesV is empty and the coverage
            // check below reduces to the syntactic form already
            // guarded by elab.
            final paramCount = scrutineeData.params.length;
            final paramsV = value.args.sublist(0, paramCount);
            final indicesV = value.args.sublist(paramCount);

            // Coverage check for indexed families.
            //
            // Elab defers coverage on indexed data because the
            // scrutinee's index values are only visible here. A ctor
            // can be omitted from the arms if it is PROVABLY
            // unreachable under the scrutinee's indices, using
            // first-order ctor-head clash at corresponding index
            // positions. Reachable uncovered ctors → a check error.
            //
            // For non-indexed data, indexing is empty and this loop
            // is a no-op (elab already caught syntactic coverage).
            //
            // Wildcard arm absorbs any uncovered ctors.
            final hasWildcard = matchTerm.cases.any((c) => c.isWildcard);
            if (!hasWildcard && indicesV.isNotEmpty) {
              final armCtorNames = <String>{
                for (final c in matchTerm.cases)
                  if (!c.isWildcard) c.ctorName,
              };
              final reachableMissing = <String>[];
              for (final c in scrutineeData.ctors) {
                if (armCtorNames.contains(c.name)) continue;
                // Compute the ctor's result indices under a telescope
                // env made of paramsV + fresh neutrals for its args.
                // Then pairwise-check unifiability with indicesV.
                if (_ctorReachable(
                  scrutineeData,
                  c,
                  paramsV,
                  indicesV,
                  ctx.level,
                )) {
                  reachableMissing.add(c.name);
                }
              }
              if (reachableMissing.isNotEmpty) {
                throw IndexedMatchNotExhaustive(
                  scrutineeData.name,
                  reachableMissing,
                );
              }
            }

            // Honor an explicit motive (non-indexed case): the motive
            // is a type (viewed as the constant function `_ => motive`).
            // Evaluate it and check convertibility with `expected`. If
            // they disagree, the user claimed a return type the
            // surrounding context doesn't want, that's a TypeMismatch.
            // (Indexed families would instead apply the motive to the
            // scrutinee and its indices and compare via unification.)
            final matchMotive = matchTerm.motive;
            if (matchMotive != null) {
              final motiveV = eval(matchMotive, ctx.env);
              // For non-indexed data, the motive should be a type
              // (VType / VProp / VData / VPi whose head is Type-valued).
              // Treat the motive as the constant function's result
              // type and check convertibility with expected.
              final convResult = conv(
                ctx.level,
                motiveV,
                expected,
                dataDecls: ctx.dataDecls,
                metas: ctx.metas,
                topBindings: ctx.env.topBindings,
              );
              if (convResult is ConvMismatch) {
                throw TypeMismatch(
                  motiveV,
                  expected,
                  convResult,
                  level: ctx.level,
                );
              }
            }

            // Kick off arm-by-arm checking starting at index 0.
            if (matchTerm.cases.isEmpty) {
              // An empty match on a data type with zero ctors is valid
              // (unreachable code). Yield expected.
              step = _YieldV(expected);
            } else {
              step = _checkMatchArmStep(
                ctx,
                matchTerm,
                scrutineeData,
                paramsV,
                indicesV,
                0,
                expected,
                stack,
              );
            }

          case _CheckMatchArm(
            :final ctx,
            :final matchTerm,
            :final dataDecl,
            :final paramsV,
            :final indicesV,
            :final armIndex,
            :final expected,
          ):
            // The arm at `armIndex` just finished checking. Advance.
            final nextIndex = armIndex + 1;
            if (nextIndex >= matchTerm.cases.length) {
              // All arms checked. Yield expected.
              step = _YieldV(expected);
            } else {
              step = _checkMatchArmStep(
                ctx,
                matchTerm,
                dataDecl,
                paramsV,
                indicesV,
                nextIndex,
                expected,
                stack,
              );
            }

          // --- quotient infer _YieldV handlers ---

          case _InferQuotHaveCarrierType(
            :final ctx,
            :final carrier,
            :final relation,
          ):
            final carrierSort = _asSort(value);
            if (carrierSort == null) throw NotAType(value);
            stack.add(_InferQuotHaveCarrierV(ctx, relation, carrierSort));
            step = _Eval(carrier, ctx.env);

          case _InferQuotHaveCarrierV(
            :final ctx,
            :final relation,
            :final carrierSort,
          ):
            stack.add(_InferQuotAfterCarrierQuote(ctx, relation, carrierSort));
            step = _Quote(value, ctx.level);

          case _InferQuotAfterRelationCheck(:final carrierSort):
            step = _YieldV(_sortToValue(carrierSort));

          case _InferQuotLiftHaveQuotType(:final ctx, :final fn):
            if (value is! VQuot) throw NotAQuotient(value);
            final qV = value;
            stack.add(_InferQuotLiftHaveFnType(ctx, qV.carrier, qV.relation));
            step = _Infer(ctx, fn);

          case _InferQuotLiftHaveFnType(:final ctx, quotA: _, quotR: _):
            final v = value;
            if (v is! VPi) throw NotAFunction(v);
            final fresh = VNeutral(NVar(ctx.level));
            stack.add(const _InferQuotLiftAfterProof());
            step = _Eval(v.codomain.body, v.codomain.env.extend(fresh));

          case _InferQuotLiftAfterProof():
            step = _YieldV(value);

          case _QPiCod():
          case _QPiBuild():
          case _QPiBuildNormal():
          case _QLamBody():
          case _QLamBuild():
          case _QAppArg():
          case _QAppBuild():
          case _QDataArg():
          case _QConstrArg():
          case _QMatchAfterScrutinee():
          case _QMatchBuild():
          case _QQuotRelation():
          case _QQuotBuild():
          case _QQuotMk():
          case _QQuotLiftFn():
          case _QQuotLiftProof():
          case _QQuotLiftBuild():
          case _QMatchArmAfterQuote():
          case _ConvThen():
          case _ConvThenOpen():
          case _InferLamHaveBodyTerm():
          case _CheckFallbackConvResult():
          case _CheckLamAnnotSubtype():
          case _InferQuotAfterCarrierQuote():
            throw StateError(
              'internal: _YieldV on term/conv-expecting frame '
              '${frame.runtimeType}. This indicates a bug in the '
              'driver, a value has been produced where a term or '
              'conv-result was expected.',
            );
        }

      // -----------------------------------------------------------------
      // _YieldT: a term has been produced; dispatch on the top frame.
      // -----------------------------------------------------------------
      case _YieldT(:final term):
        if (stack.isEmpty) {
          return term;
        }
        final frame = stack.removeLast();
        switch (frame) {
          case _QPiCod(
            :final codomain,
            :final level,
            :final nameHint,
            :final icit,
          ):
            // We just quoted the domain. Now open the codomain and quote
            // the result at level+1. We push _QPiBuild(domain) so the
            // final TPi is built after the codomain term arrives, and
            // _QuoteAt(level+1) so the post-eval value transitions back
            // into quote mode in-loop (no Dart recursion).
            stack.add(_QPiBuild(term, nameHint, icit));
            stack.add(_QuoteAt(level + 1));
            step = _Eval(
              codomain.body,
              codomain.env.extend(VNeutral(NVar(level))),
            );

          case _QPiBuild(:final domain, :final nameHint, :final icit):
            step = _YieldT(TPi(domain, term, name: nameHint, icit: icit));

          case _QPiBuildNormal(
            :final codomainTerm,
            :final nameHint,
            :final icit,
          ):
            // Domain has just been quoted (term = domain). Reuse the
            // closure's already-normal body directly as the codomain.
            step = _YieldT(TPi(term, codomainTerm, name: nameHint, icit: icit));

          case _QLamBody(
            :final body,
            :final level,
            :final nameHint,
            :final icit,
          ):
            stack.add(_QLamBuild(term, nameHint, icit));
            stack.add(_QuoteAt(level + 1));
            step = _Eval(body.body, body.env.extend(VNeutral(NVar(level))));

          case _QLamBuild(:final domain, :final nameHint, :final icit):
            step = _YieldT(TLam(domain, term, name: nameHint, icit: icit));

          case _QAppArg(:final arg, :final level):
            stack.add(_QAppBuild(term));
            step = _Quote(arg, level);

          case _QAppBuild(:final fn):
            step = _YieldT(TApp(fn, term));

          case _QDataArg(
            :final name,
            :final collected,
            :final args,
            :final nextIndex,
            :final level,
          ):
            collected.add(term);
            if (nextIndex == args.length) {
              step = _YieldT(TData(name, collected));
            } else {
              stack.add(_QDataArg(name, collected, args, nextIndex + 1, level));
              step = _Quote(args[nextIndex], level);
            }

          case _QConstrArg(
            :final dataName,
            :final ctorName,
            :final collected,
            :final args,
            :final nextIndex,
            :final level,
          ):
            collected.add(term);
            if (nextIndex == args.length) {
              step = _YieldT(TConstr(dataName, ctorName, collected));
            } else {
              stack.add(
                _QConstrArg(
                  dataName,
                  ctorName,
                  collected,
                  args,
                  nextIndex + 1,
                  level,
                ),
              );
              step = _Quote(args[nextIndex], level);
            }

          case _QMatchArmAfterQuote(
            :final sv,
            :final mv,
            :final cases,
            :final env,
            :final level,
            :final builtArms,
            :final armIndex,
          ):
            // `term` = quoted body of arm [armIndex]. Accumulate, advance.
            final arm = cases[armIndex];
            builtArms.add(
              TMatchCase(
                arm.ctorName,
                arm.nBinders,
                term,
                arm.binderNames,
                span: arm.span,
              ),
            );
            final nextIndex = armIndex + 1;
            if (nextIndex >= cases.length) {
              // All arms built. Transition to scrutinee quoting.
              stack.add(_QMatchAfterScrutinee(mv, builtArms, level));
              step = _Quote(sv, level);
            } else {
              // Kick off arm [nextIndex]'s body evaluation.
              final nextArm = cases[nextIndex];
              var armEnv = env;
              for (var i = 0; i < nextArm.nBinders; i++) {
                armEnv = armEnv.extend(VNeutral(NVar(level + i)));
              }
              stack.add(
                _QMatchArmAfterEval(
                  sv: sv,
                  mv: mv,
                  cases: cases,
                  env: env,
                  level: level,
                  builtArms: builtArms,
                  armIndex: nextIndex,
                ),
              );
              step = _Eval(nextArm.body, armEnv);
            }

          case _QMatchAfterScrutinee(
            :final motiveV,
            :final caseTerms,
            :final level,
          ):
            // `term` = scrutineeT.
            if (motiveV == null) {
              // Null motive round-trips as null; no motive quoting
              // needed.
              step = _YieldT(TMatch(term, null, caseTerms));
            } else {
              // Schedule motive quoting, then assemble in [_QMatchBuild].
              stack.add(_QMatchBuild(term, caseTerms));
              step = _Quote(motiveV, level);
            }

          case _QMatchBuild(:final scrutineeT, :final caseTerms):
            // `term` = motiveT.
            step = _YieldT(TMatch(scrutineeT, term, caseTerms));

          case _QQuotRelation(:final relation, :final level):
            stack.add(_QQuotBuild(term));
            step = _Quote(relation, level);

          case _QQuotBuild(:final carrier):
            step = _YieldT(TQuot(carrier, term));

          case _QQuotMk():
            step = _YieldT(TQuotMk(term));

          case _QQuotLiftFn(:final fn, :final proof, :final level):
            stack.add(_QQuotLiftProof(term, proof, level));
            step = _Quote(fn, level);

          case _QQuotLiftProof(:final quot, :final proof, :final level):
            stack.add(_QQuotLiftBuild(quot, term));
            step = _Quote(proof, level);

          case _QQuotLiftBuild(:final quot, :final fn):
            step = _YieldT(TQuotLift(quot, fn, term));

          case _InferQuotAfterCarrierQuote(
            :final ctx,
            :final relation,
            :final carrierSort,
          ):
            // Infer the relation to verify it's well-typed (its type
            // must be a sort, since it's a type-level expression).
            stack.add(_InferQuotAfterRelationCheck(carrierSort));
            step = _Infer(ctx, relation);

          // --- check/infer T-consuming frames ---

          case _InferLamHaveBodyTerm(:final env, :final domV, :final nameHint):
            // `term` was produced by _Quote at level `env.depth + 1`,
            // so it's already in normal form under the closure's
            // extended env. Mark the Closure so a subsequent _Quote
            // can skip the open/eval/quote round-trip that would
            // otherwise make the enclosing `infer TLam` chain
            // quadratic.
            step = _YieldV(
              VPi(domV, Closure(env, term, bodyIsNormal: true), name: nameHint),
            );

          case _EvalArg():
          case _ApplyFn():
          case _ApplyArg():
          case _BuildLam():
          case _BuildPi():
          case _BuildData():
          case _BuildConstr():
          case _QuoteAt():
          case _ConvPairLeft():
          case _ConvPairRight():
          case _ConvThen():
          case _ConvThenOpen():
          case _InferPiHaveDomType():
          case _InferPiHaveDomV():
          case _InferPiHaveCodType():
          case _InferAppHaveFnType():
          case _InferAppHaveCheck():
          case _InferAppHaveArgV():
          case _InferLamHaveDomType():
          case _InferLamHaveDomV():
          case _InferLamHaveBodyType():
          case _InferLetHaveDomType():
          case _InferLetHaveDomV():
          case _InferLetHaveCheck():
          case _InferLetHaveBoundV():
          case _InferIndAfterCheck():
          case _InferIndAfterEval():
          case _ApplyChain():
          case _EvalLetBody():
          case _MatchAfterScrutinee():
          case _MatchDispatch():
          case _CheckLamAnnotDone():
          case _CheckLamAnnotV():
          case _CheckLamAnnotSubtype():
          case _CheckLamOpenedCod():
          case _CheckFallbackGotType():
          case _CheckFallbackConvResult():
          case _CheckSuccessYield():
          case _CheckMatchScrutineeType():
          case _CheckMatchArm():
          case _InferMatchAfterMotive():
          case _QMatchArmAfterEval():
          case _RecCollectIH():
          case _EvalProj():
          case _InferProjFieldType():
          case _EvalQuot():
          case _EvalQuotMk():
          case _EvalQuotLift():
          case _InferQuotHaveCarrierType():
          case _InferQuotHaveCarrierV():
          case _InferQuotAfterRelationCheck():
          case _InferQuotLiftHaveQuotType():
          case _InferQuotLiftHaveFnType():
          case _InferQuotLiftAfterProof():
            throw StateError(
              'internal: _YieldT on value/conv-expecting frame '
              '${frame.runtimeType}. This indicates a bug in the '
              'driver, a term has been produced where a value or '
              'conv-result was expected.',
            );
        }

      // -----------------------------------------------------------------
      // _YieldC: a ConvResult has been produced; dispatch on the top frame.
      //
      // Conv frames implement sequential AND: if the delivered result is
      // a mismatch, they propagate it unchanged (short-circuiting any
      // further comparisons in the chain). If it is Ok, they run their
      // next comparison step.
      // -----------------------------------------------------------------
      case _YieldC(:final result):
        if (stack.isEmpty) {
          return result;
        }
        final frame = stack.removeLast();
        switch (frame) {
          case _ConvThen(:final then):
            if (result is ConvMismatch) {
              step = _YieldC(result);
            } else {
              step = then;
            }

          case _ConvThenOpen(
            :final leftV,
            :final rightV,
            :final level,
            :final asSubtype,
          ):
            if (result is ConvMismatch) {
              step = _YieldC(result);
            } else {
              // Domains matched (for Pi) or bodies matched (for VLam).
              // Open both sides with a fresh neutral at `level`, then
              // compare bodies at `level+1`. The asSubtype flag
              // determines whether the final body comparison is strict
              // conv or cumulativity-aware subtype.
              final fresh = VNeutral(NVar(level));
              stack.add(
                _ConvPairLeft(rightV, fresh, level + 1, asSubtype: asSubtype),
              );
              step = _Apply(leftV, fresh);
            }

          // --- check C-consuming frame ---

          case _CheckFallbackConvResult(
            :final got,
            :final expected,
            :final level,
          ):
            if (result is ConvMismatch) {
              throw TypeMismatch(got, expected, result, level: level);
            }
            // ConvOk, the term has the expected type. Yield expected.
            step = _YieldV(expected);

          case _CheckLamAnnotSubtype(
            :final ctx,
            :final body,
            :final piDom,
            :final piCod,
            :final annotV,
            :final expected,
          ):
            // The contravariant domain check just finished.
            if (result is ConvMismatch) {
              throw TypeMismatch(annotV, piDom, result, level: ctx.level);
            }
            // OK, descend into the body. Extend ctx with piDom (NOT
            // annotV): the body will see the tighter type the caller
            // promises, which is a subtype of what the annotation
            // claimed to accept.
            final fresh = VNeutral(NVar(ctx.level));
            final bodyCtx = ctx.extend(piDom);
            stack.add(_CheckLamOpenedCod(bodyCtx, body, expected));
            step = _Apply(VLam(piDom, piCod), fresh);

          case _EvalArg():
          case _ApplyFn():
          case _ApplyArg():
          case _BuildLam():
          case _BuildPi():
          case _BuildData():
          case _BuildConstr():
          case _QuoteAt():
          case _ConvPairLeft():
          case _ConvPairRight():
          case _QPiCod():
          case _QPiBuild():
          case _QPiBuildNormal():
          case _QLamBody():
          case _QLamBuild():
          case _QAppArg():
          case _QAppBuild():
          case _QDataArg():
          case _QConstrArg():
          case _QMatchAfterScrutinee():
          case _QMatchBuild():
          case _QQuotRelation():
          case _QQuotBuild():
          case _QQuotMk():
          case _QQuotLiftFn():
          case _QQuotLiftProof():
          case _QQuotLiftBuild():
          case _QMatchArmAfterEval():
          case _QMatchArmAfterQuote():
          case _RecCollectIH():
          case _EvalProj():
          case _InferProjFieldType():
          case _EvalQuot():
          case _EvalQuotMk():
          case _EvalQuotLift():
          case _InferPiHaveDomType():
          case _InferPiHaveDomV():
          case _InferPiHaveCodType():
          case _InferAppHaveFnType():
          case _InferAppHaveCheck():
          case _InferAppHaveArgV():
          case _InferLamHaveDomType():
          case _InferLamHaveDomV():
          case _InferLamHaveBodyType():
          case _InferLamHaveBodyTerm():
          case _InferLetHaveDomType():
          case _InferLetHaveDomV():
          case _InferLetHaveCheck():
          case _InferLetHaveBoundV():
          case _InferIndAfterCheck():
          case _InferIndAfterEval():
          case _ApplyChain():
          case _EvalLetBody():
          case _MatchAfterScrutinee():
          case _MatchDispatch():
          case _CheckLamAnnotDone():
          case _CheckLamAnnotV():
          case _CheckLamOpenedCod():
          case _CheckFallbackGotType():
          case _CheckSuccessYield():
          case _CheckMatchScrutineeType():
          case _CheckMatchArm():
          case _InferMatchAfterMotive():
          case _InferQuotHaveCarrierType():
          case _InferQuotHaveCarrierV():
          case _InferQuotAfterCarrierQuote():
          case _InferQuotAfterRelationCheck():
          case _InferQuotLiftHaveQuotType():
          case _InferQuotLiftHaveFnType():
          case _InferQuotLiftAfterProof():
            throw StateError(
              'internal: _YieldC on non-conv frame '
              '${frame.runtimeType}. This indicates a bug in the '
              'driver, a conv-result has been produced where a value '
              'or term was expected.',
            );
        }
    }
  }
}

// ===========================================================================
// Level normalization and comparison (universe polymorphism).
// ===========================================================================

/// Normalize a level expression.
///
/// Flattens `LMax` chains, eliminates trivial cases:
///   - `max(u, u) → u`
///   - `max(0, u) → u`, `max(u, 0) → u`
///   - `imax(u, 0) → 0` (impredicative: Prop codomain → Pi is Prop)
///   - `imax(u, v)` when `v ≠ 0` → `max(u, v)`
///   - `succ(LLevel(n))` → `LLevel(n+1)`
Level _normalizeLevel(Level l) => switch (l) {
  LMax(lhs: final l1, rhs: final l2) => _normalizeMax(l1, l2),
  LImax(lhs: final l1, rhs: final l2) =>
    _normalizeLevel(l2) == _l0 ? _l0 : _normalizeMax(l1, l2),
  LSucc(of: final o) => switch (_normalizeLevel(o)) {
    LLevel(level: final n) => LLevel(n + 1),
    final ln => LSucc(ln),
  },
  LVar() || LLevel() => l,
};

Level _normalizeMax(Level a, Level b) {
  final na = _normalizeLevel(a);
  final nb = _normalizeLevel(b);
  if (na == nb) return na;
  if (na is LLevel && na.level == 0) return nb;
  if (nb is LLevel && nb.level == 0) return na;
  if (na is LLevel && nb is LLevel) {
    return na.level >= nb.level ? na : nb;
  }
  // Flatten nested LMax.
  final args = <Level>[];
  void collect(Level l) {
    if (l is LMax) {
      collect(l.lhs);
      collect(l.rhs);
    } else {
      args.add(l);
    }
  }

  collect(LMax(na, nb));
  args.sort(_levelCompare);
  // Deduplicate: keep only maximal args (no other arg is GTE it).
  final deduped = <Level>[];
  for (final a in args) {
    if (!deduped.any((d) => _levelGte(d, a))) {
      deduped.removeWhere((d) => _levelGte(a, d));
      deduped.add(a);
    }
  }
  if (deduped.isEmpty) return _l0;
  if (deduped.length == 1) return deduped.first;
  return _rebuildMax(deduped);
}

int _levelCompare(Level a, Level b) {
  final na = _normalizeLevel(a);
  final nb = _normalizeLevel(b);
  if (na is LLevel && nb is LLevel) return na.level.compareTo(nb.level);
  if (na is LLevel) return -1;
  if (nb is LLevel) return 1;
  if (na is LVar && nb is LVar) return na.name.compareTo(nb.name);
  if (na is LVar) return -1;
  if (nb is LVar) return 1;
  return 0;
}

Level _rebuildMax(List<Level> args) {
  var result = args[0];
  for (var i = 1; i < args.length; i++) {
    result = LMax(result, args[i]);
  }
  return result;
}

/// Structural `a >= b` on normalized levels. For cumulativity in _Subtype.
bool _levelGte(Level a, Level b) {
  final na = _normalizeLevel(a), nb = _normalizeLevel(b);
  if (na == nb) return true;
  // b is max(l1, ..., ln): a >= b iff a >= l1 && ... && a >= ln
  if (nb is LMax) return _levelGte(na, nb.lhs) && _levelGte(na, nb.rhs);
  // a is max: a >= b iff l1 >= b || ... || ln >= b
  if (na is LMax) return _levelGte(na.lhs, nb) || _levelGte(na.rhs, nb);
  // LLevel vs LVar: LLevel exact match only, LVar never >= LLevel(n>0)
  if (na is LLevel && nb is LLevel) return na.level >= nb.level;
  if (na is LVar && nb is LVar) return na.name == nb.name;
  return false;
}

/// Structural `l1 == l2` on normalized levels. For strict equality in _Conv.
bool _levelEq(Level a, Level b) => _normalizeLevel(a) == _normalizeLevel(b);

// ===========================================================================
// Sort helpers (internal).
//
// In CIC with Prop, a "sort" is either Prop or Type n. A sealed
// [_Sort] type makes dispatch explicit and prevents accidental
// arithmetic on the Prop case (which an integer-level encoding would
// admit).
// ===========================================================================

/// A universe sort: [_Prop], [_SProp], or [_TypeN].
sealed class _Sort {
  const _Sort();
}

final class _Prop extends _Sort {
  const _Prop();
}

final class _SProp extends _Sort {
  const _SProp();
}

final class _TypeN extends _Sort {
  final Level level;
  const _TypeN(this.level);
}

const _Prop _propSort = _Prop();
const _SProp _sPropSort = _SProp();

/// Read a sort from a Value, or null if it isn't one.
///
/// Returns a [_Sort] for [VSProp], [VProp] or [VType(n)]; null for
/// any other shape (a user-facing `NotAType` condition).
_Sort? _asSort(Value v) => switch (v) {
  VSProp() => _sPropSort,
  VProp() => _propSort,
  VType(:final level) => _TypeN(level),
  _ => null,
};

/// Convert a [_Sort] to its [Value] representation.
Value _sortToValue(_Sort s) => switch (s) {
  _SProp() => const VSProp(),
  _Prop() => const VProp(),
  _TypeN(:final level) => VType(level),
};

/// Classify whether a [Term] that sits as a type in a given `env`
/// resolves to a `Prop`-sorted type. Used by Prop-irrelevance: when
/// both values at a conv mismatch have types whose sort is `Prop`,
/// SPEC §8.2 admits the conversion.
///
/// Walks the term structurally without re-entering the driver, pure
/// classification, no `eval` / `apply` / `quote` calls. On unresolved
/// or unclassifiable shapes (free variables, stuck terms, top-level
/// refs we can't resolve), returns false conservatively. Irrelevance
/// declining just means structural mismatch is returned as before;
/// no soundness loss.
///
///   * `TProp` → false. Prop itself is a Type-1 sort, not a Prop-
///     sorted type, if a value has type `Prop`, it IS a proposition,
///     and irrelevance must not fire on proposition equality.
///   * `TData(name, _)` → true iff the registered data's sort is TProp.
///   * `TPi(_, body)` → recurse on `body`. A Pi's sort is Prop iff
///     its codomain's sort is Prop (impredicative-Prop PTS rule).
///   * Everything else (TApp, TBound, TTop, TRec, TMatch, TLam, TLet,
///     TType, TConstr) → false. These either aren't well-formed types
///     at the classification site, or need context we don't thread.
bool _isPropSortedTerm(Term t, List<DataDecl> dataDecls) {
  while (true) {
    switch (t) {
      case TPi(:final codomain):
        t = codomain;
        continue;
      case TData(:final name):
        for (final d in dataDecls) {
          if (d.name == name) return d.sort is TProp;
        }
        return false;
      default:
        return false;
    }
  }
}

/// Convert a declared data sort (always `TType(n)` or `TProp`) to its
/// `Value` form without re-entering the driver. The registry records
/// only these two shapes; anything else is a registry-construction
/// bug caught at decl time.
Value _sortTermToValue(Term sort) => switch (sort) {
  TType(:final level) => VType(level),
  TProp() => const VProp(),
  TSProp() => const VSProp(),
  _ => throw StateError('data sort is neither TType, TProp, nor TSProp: $sort'),
};

/// Infer the type of a `Value` well enough to classify its sort,
/// without re-entering the driver. Returns a Value representing the
/// type, or `null` when the type cannot be determined from the value
/// and the provided [dataDecls] alone.
///
/// Used by the Prop-irrelevance check at conv mismatch sites. The
/// returned Value only needs to be a suitable input to
/// [_isPropSorted]; any value shape outside {VProp, VType, VPi, VData}
/// is "unclassifiable" for irrelevance purposes and returns null.
///
/// - `VType(n) → VType(n+1)`.
/// - `VProp → VType(1)` (Prop : Type 1, SPEC §8.2).
/// - `VSProp → VType(1)` (SProp : Type 1).
/// - `VPi` → computed from codomain-Term classification (we don't
///   need the type's exact value, only its Prop-/SProp-ness; callers
///   test that directly via [_isPropSorted] / [_isSPropSorted]).
/// - `VData(name, _) → dataDecl.sort` resolved against the registry.
/// - `VConstr(dataName, …) → dataDecl.sort` of the parent data
///   (ctors live in the data's sort; params/indices don't matter
///   for sort classification).
/// - `VRec`, `VLam`, `VMatch`, `VNeutral` → null. These either need
///   ctx (for binder / topBinding resolution) or don't admit a
///   direct classification at the registry level.
Value? _inferValueType(Value v, List<DataDecl> dataDecls) {
  switch (v) {
    case VType(:final level):
      return VType(_normalizeLevel(LSucc(level)));
    case VProp():
      return _vType1;
    case VSProp():
      return _vType1;
    case VPi():
      // For irrelevance, we don't need the Pi's exact sort as a value,
      // we only need to know whether the Pi is Prop- or SProp-sorted.
      // Return a sentinel Value whose classification mirrors the Pi's:
      // we walk the body as a Term.
      //
      // Rather than compute `_piSort(...)` here (which would require
      // re-entering the driver to evaluate sub-terms), we pre-classify
      // via the term walker. If the body is Prop-sorted, return VProp
      // (sentinel); if SProp-sorted, return VSProp; otherwise VType(0)
      // (any Type sort suffices, since neither _isPropSorted nor
      // _isSPropSorted matches VType(_)).
      final codBody = v.codomain.body;
      final codDecls = v.codomain.env.dataDecls;
      if (_isPropSortedTerm(codBody, codDecls)) return const VProp();
      if (_isSPropSortedTerm(codBody, codDecls)) return const VSProp();
      return _vType0;
    case VData(:final name):
      // The type of a VData (an inductive type applied to its args) is
      // the inductive's declared SORT, VProp or VType(n). This is
      // correct: if we're asked "what type inhabits this type?", it's
      // the sort the inductive was declared at.
      for (final d in dataDecls) {
        if (d.name == name) return _sortTermToValue(d.sort);
      }
      return null;
    case VConstr(:final dataName, :final args):
      // The type of a VConstr is the VData its ctor produces, i.e.,
      // `D[params] indices...`. For irrelevance, `_isPropSorted` on
      // that VData resolves by looking up D's sort. We carry the args
      // faithfully so downstream consumers get a well-formed VData
      // even though only the head name matters for the irrelevance
      // check.
      for (final d in dataDecls) {
        if (d.name == dataName) {
          final paramCount = d.params.length;
          final dataArgs =
              args.length >= paramCount ? args.sublist(0, paramCount) : args;
          return VData(dataName, dataArgs);
        }
      }
      return null;
    case VLam():
    case VRec():
    case VFun():
    case VMatch():
    case VNeutral():
    case VDelayed():
    case VQuot():
    case VQuotMk():
    case VQuotLift():
      return null;
  }
}

/// True iff [type] is a `Prop`-sorted type, i.e., a value of type
/// [type] is a *proof*, which triggers definitional proof irrelevance
/// (SPEC §8.2).
///
/// Note the careful level-off: `_isPropSorted(VProp) = false`. If a
/// value's type is `VProp`, the value IS a proposition (not a proof),
/// and irrelevance must NOT admit equality between two distinct
/// propositions.
bool _isPropSorted(Value type, List<DataDecl> dataDecls) {
  switch (type) {
    case VProp():
      // The value's type is Prop → the value is a proposition, not a
      // proof. Irrelevance does not fire.
      return false;
    case VSProp():
      return false;
    case VType():
      // Value lives in Type n, not Prop.
      return false;
    case VData(:final name):
      // The inductive's declared sort decides it.
      for (final d in dataDecls) {
        if (d.name == name) return d.sort is TProp;
      }
      return false;
    case VPi():
      // PTS: a Pi is Prop-sorted iff its codomain is. Delegate to the
      // term walker.
      return _isPropSortedTerm(type.codomain.body, type.codomain.env.dataDecls);
    case VLam():
    case VConstr():
    case VRec():
    case VFun():
    case VMatch():
    case VNeutral():
    case VDelayed():
    case VQuot():
    case VQuotMk():
    case VQuotLift():
      // Not a type-value; conservative decline.
      return false;
  }
}

/// True iff [type] is an `SProp`-sorted type. SProp values are
/// definitionally equal — no registry needed.
bool _isSPropSorted(Value type, List<DataDecl> dataDecls) {
  switch (type) {
    case VSProp():
      return true;
    case VProp():
    case VType():
      return false;
    case VData(:final name):
      for (final d in dataDecls) {
        if (d.name == name) return d.sort is TSProp;
      }
      return false;
    case VPi():
      return _isSPropSortedTerm(
        type.codomain.body,
        type.codomain.env.dataDecls,
      );
    case VLam():
    case VConstr():
    case VRec():
    case VFun():
    case VMatch():
    case VNeutral():
    case VDelayed():
    case VQuot():
    case VQuotMk():
    case VQuotLift():
      return false;
  }
}

/// Classify whether a [Term] resolves to an `SProp`-sorted type.
/// Mirrors [_isPropSortedTerm] but checks for [TSProp].
bool _isSPropSortedTerm(Term t, List<DataDecl> dataDecls) {
  while (true) {
    switch (t) {
      case TPi(:final codomain):
        t = codomain;
        continue;
      case TData(:final name):
        for (final d in dataDecls) {
          if (d.name == name) return d.sort is TSProp;
        }
        return false;
      default:
        return false;
    }
  }
}

/// Try to admit [a] ≡ [b] by SPEC §8.2 Prop-irrelevance or SProp
/// strict irrelevance. If both values have types whose sort is `Prop`,
/// they are definitionally equal by the calculus's proof-irrelevance
/// rule. If both have types whose sort is `SProp`, they are
/// definitionally equal by strict proof irrelevance. Otherwise return
/// [ConvMismatch] as before.
///
/// Called from every conv-mismatch site in `_Conv`. When the loop-
/// local registry is null (caller didn't pass dataDecls), irrelevance
/// declines and the original mismatch is returned. This makes the
/// rule strictly additive, no existing program regresses.
ConvResult _mismatchOrIrrelevance(Value a, Value b, List<DataDecl>? dataDecls) {
  if (dataDecls == null) return ConvMismatch(a, b);
  final ta = _inferValueType(a, dataDecls);
  // Existing Prop check:
  if (ta != null && _isPropSorted(ta, dataDecls)) {
    final tb = _inferValueType(b, dataDecls);
    if (tb != null && _isPropSorted(tb, dataDecls)) return const ConvOk();
  }
  // New SProp check:
  if (ta != null && _isSPropSorted(ta, dataDecls)) {
    final tb = _inferValueType(b, dataDecls);
    if (tb != null && _isSPropSorted(tb, dataDecls)) return const ConvOk();
  }
  return ConvMismatch(a, b);
}

// ===========================================================================
// Pattern unification.
// ===========================================================================
//
// Miller's pattern fragment (1991, Abel & Pientka 2011) says: a
// unification problem `?m σ ≡ t` is solvable by `?m := λσ. t` when
//   * σ is a list of DISTINCT bound variables (the "pattern" restriction);
//   * t has no unsolved meta heads outside σ (occurs check);
//   * t mentions no bound variable outside σ (scope check / pruning).
//
// This fragment is decidable and admits most-general unifiers, which is
// what keeps Doxa's linear-time kernel invariant intact.
//
// The checks below transcribe the pattern-unification algorithm as
// presented in Kovács's elaboration-zoo.
//
// Public entry point: [_tryUnify] is called from `_Conv`'s VNeutral×*
// arm when the meta-context is populated. On success, the meta is
// solved and [ConvOk] is returned. On failure (non-pattern spine,
// failed occurs/scope check, or different-meta flex-flex), the helper
// returns `null`; the caller falls back to irrelevance + mismatch.

/// Attempt to unify `a ≡ b` by pattern unification.
///
/// Returns [ConvOk] if one side is a `VNeutral(NMeta(id) spine)` with a
/// valid pattern spine and the solve succeeds. Returns `null` if the
/// rule doesn't apply, the caller continues with the regular
/// mismatch/irrelevance path.
///
/// Callers must handle the solved-meta case themselves (unfold the
/// solution and re-dispatch conv) before calling this helper
/// `_tryUnify` declines on solved metas.
///
/// Orientation: if only one side is a meta-headed neutral, solve that
/// meta. If both sides are meta-headed:
///   * same meta + spines equal → succeed (pointwise delegated to
///     the normal `NMeta × NMeta` code in `_Conv`).
///   * different metas → decline (defer: return null). A richer
///     solver would create an intersection meta (Abel & Pientka
///     2011 §4.3); not implemented.
ConvResult? _tryUnify(Value a, Value b, int level, MetaContext metas) {
  final metaA = _metaHeadAndSpine(a);
  final metaB = _metaHeadAndSpine(b);
  if (metaA == null && metaB == null) return null;
  if (metaA != null && metaB != null) {
    // Flex-flex: caller handles pointwise same-meta compare and
    // different-meta deferral directly; don't shortcut here.
    return null;
  }
  // Flex-rigid: orient so the meta side is (idM, spineM) and the rigid
  // side is t.
  final int idM;
  final List<Value> spineM;
  final Value t;
  if (metaA != null) {
    idM = metaA.$1;
    spineM = metaA.$2;
    t = b;
  } else {
    idM = metaB!.$1;
    spineM = metaB.$2;
    t = a;
  }
  // Already solved? Decline, caller should have unfolded first.
  final entry = metas.lookup(idM);
  if (entry is! TermMetaUnsolved) return null;

  // Check the pattern restriction: every spine value must be a
  // distinct NVar neutral.  Before checking, force any solved NMeta
  // entries in the spine so that a meta whose spine includes another
  // solved meta (e.g. from _insertImplicits capturing an outer meta)
  // still admits pattern unification.
  for (var i = 0; i < spineM.length; i++) {
    if (spineM[i] is VNeutral) {
      final forced = _forceMetaHead(spineM[i], metas, null);
      if (!identical(forced, spineM[i])) {
        spineM[i] = forced;
      }
    }
  }
  final vars = <int>[];
  final seen = <int>{};
  for (final s in spineM) {
    if (s is! VNeutral) return null;
    final n = s.neutral;
    if (n is! NVar) return null;
    final lvl = n.level;
    if (seen.contains(lvl)) return null;
    seen.add(lvl);
    vars.add(lvl);
  }
  // Occurs + scope check: quote t at `level` (the conv level), then
  // walk the term to ensure (a) no TMeta(idM) occurs, and (b) every
  // TBound reachable points at a level in `vars`.
  //
  // quote reifies vars as TBound indices relative to `level`: an
  // NVar(k) becomes TBound(level - k - 1). So we build the set of
  // allowed TBound indices by mapping each pattern var's level
  // through the same conversion.
  final Term tTerm;
  try {
    tTerm = quote(level, t);
  } on StateError {
    // Quote can fail if the rigid side references unresolved state
    // we don't support yet; decline so the caller falls back.
    return null;
  }
  final allowedBound = <int>{for (final v in vars) level - v - 1};
  if (!_solutionWellScoped(tTerm, idM, allowedBound, 0)) {
    return null;
  }
  // Rename the quoted rhs so its free TBound references are encoded
  // relative to the solution's λ-chain rather than the conv level.
  //
  // Quoted rhs: a free TBound(k) at depth d refers to absolute level
  // `level - 1 - (k - d)` (when k >= d). That absolute level is some
  // pattern var at position `i` in vars.
  //
  // Solution shape: `λv0 λv1 ... λv{n-1}. body` where `vars[i]` is the
  // i-th λ from the outside. Inside body, `vars[i]` sits at de-Bruijn
  // index `n - 1 - i` (innermost binder is index 0).
  //
  // So rename TBound(k) (at depth d) → TBound(n - 1 - i + d), where
  // i is the position of `level - 1 - (k - d)` in vars. Well-
  // scopedness above guaranteed the absolute level is in vars, so
  // this mapping is total.
  final absToPos = <int, int>{for (var i = 0; i < vars.length; i++) vars[i]: i};
  final renamedBody = _renameForSolution(
    tTerm,
    level: level,
    vars: vars,
    absToPos: absToPos,
  );
  // Build the solution's λ-chain domains from the meta's declared
  // typeExpected.
  //
  // Meta invariant (established by `_closeValueOverCtx`): every
  // elaborator-emitted meta has `typeExpected = Π(b₀:T₀). Π(b₁:T₁).
  // … Π(b_{n-1}:T_{n-1}). R`, with the Pi chain closed outermost-
  // first to match the InsertedMeta application order `?M b₀ b₁ …
  // b_{n-1}` emitted at every use site. A canonical pattern-
  // unification spine matching that emit shape therefore has
  // `vars = [0, 1, …, n-1]` and the i-th Pi's domain is exactly
  // the i-th λ's domain in the solution `λ(T₀). λ(T₁). … body`.
  //
  // Why this matters: the solution is NOT just a conv-time
  // β-reduction target, the kernel's `_Infer(TMeta(id) → SOLVED →
  // _Infer(solution))` path sort-checks the solution's TLam domains at
  // every use site. A `TType(0)` placeholder is well-formed only when
  // the real outer binder happens to be a Type; any non-Type outer
  // binder (`fun test(n: Nat) = …`) produces
  // `_Check(TBound(outer), VType) → TypeMismatch`. Well-typed solutions
  // are also required by higher-order unification, universe
  // polymorphism (domain sorts aren't discardable), typeclass
  // resolution (solutions are reused across call-sites), and the WasmGC
  // codegen (which evaluates solutions and cannot assume domain
  // irrelevance). So we carry the meta's declared domain types all the
  // way through solution-formation.
  //
  // Non-canonical spines (permuted / non-contiguous vars, e.g. a
  // subset of outer binders or an out-of-order application) require
  // reordering the Pi-chain against vars, higher-order-unification
  // territory. The elaborator does not currently emit those, so we
  // decline cleanly here rather than attempt a heuristic
  // reconstruction; the caller falls back to the conv-level
  // TypeMismatch path.
  // Check for canonical spine [0, 1, …, n-1] (outermost-first,
  // matching the typeExpected Pi chain built by _closeValueOverCtx).
  // Also accept the reversed canonical spine [n-1, …, 1, 0] produced
  // by _insertImplicits which applies binders innermost-first.
  var isCanonicalSpine = true;
  var isReversedSpine = true;
  for (var i = 0; i < vars.length; i++) {
    if (vars[i] != i) isCanonicalSpine = false;
    if (vars[i] != vars.length - 1 - i) isReversedSpine = false;
  }
  if (!isCanonicalSpine && !isReversedSpine) return null;

  final domainTerms = <Term>[];
  var typeCursor = entry.typeExpected;

  if (isCanonicalSpine) {
    // Canonical: walk typeExpected outermost-first.
    for (var i = 0; i < vars.length; i++) {
      if (typeCursor is! VPi) return null;
      domainTerms.add(quote(i, typeCursor.domain));
      typeCursor = eval(
        typeCursor.codomain.body,
        typeCursor.codomain.env.extend(VNeutral(NVar(i))),
      );
    }
  } else {
    // Reversed spine vars = [n-1, …, 0] (innermost-first).
    // The Pi chain is outermost-first, but the first application
    // argument is the innermost value.  So the first λ in the
    // solution must bind the INNERMOST domain type.
    // Expand all Pi domains outermost-first, then reverse.
    final allDomains = <Value>[];
    var tc = entry.typeExpected;
    for (var i = 0; i < vars.length; i++) {
      if (tc is! VPi) return null;
      allDomains.add(tc.domain);
      tc = eval(tc.codomain.body, tc.codomain.env.extend(VNeutral(NVar(i))));
    }
    for (var i = 0; i < vars.length; i++) {
      domainTerms.add(quote(i, allDomains[vars.length - 1 - i]));
    }
  }
  // Wrap body with λ-chain outermost-first. Iterate backward so the
  // innermost λ wraps first and the outermost wraps last:
  //   step i=n-1: λ(T_{n-1}). body
  //   step i=n-2: λ(T_{n-2}). λ(T_{n-1}). body
  //   …
  //   step i=0:   λ(T₀). … λ(T_{n-1}). body
  var solution = renamedBody;
  for (var i = vars.length - 1; i >= 0; i--) {
    solution = TLam(domainTerms[i], solution);
  }
  // Inline any already-solved nested metas into the solution
  // BEFORE storing it. Lean 4 and Agda do the same, instantiating
  // metavariables in a candidate assignment before recording it.
  //
  // Rationale: if the candidate solution term references other metas
  // `?N` that are already solved, storing the raw term means later
  // unfoldings re-interpret those `?N σ` applications relative to
  // the CURRENT scope (fine for well-formed spines, pathological
  // when the solved `?N`'s solution itself contains de-Bruijn
  // references that get rebound). Inlining at solve time anchors
  // the semantics to the solve-site scope.
  final inlinedSolution = inlineSolvedMetas(solution, metas);
  // Solve-time scope check. Verify every free de-Bruijn index in the
  // candidate solution is valid under the meta's declaration-site
  // [localCtx], as Lean 4's assignment check does: a solve that would
  // bind an fvar outside the meta's declared scope is rejected, and
  // the caller falls back to an alternative unification path.
  //
  // Shape: the stored solution is `λ(T₀)...λ(T_{n-1}). body`. Its
  // own λ-chain supplies n binders; under that chain, body's free
  // TBound references (index >= n) escape into the outer scope.
  // Those escapees must point into entry.localCtx.
  if (!_solutionWellScopedUnderCtx(inlinedSolution, entry.localCtx)) {
    return null;
  }
  metas.solve(idM, inlinedSolution);
  return const ConvOk();
}

/// Attempt to unify two differently-headed meta neutrals
/// `?α σ ≡ ?β τ` by Miller / Abel-Pientka **intersection**.
///
/// Returns [ConvOk] on success (both metas solved such that the two
/// neutrals become equal); returns `null` when the rule doesn't
/// apply and the caller should fall back to a mismatch diagnostic.
///
/// ## Scope (decidable pattern fragment)
///
/// Miller's pattern fragment is the decidable subset of higher-order
/// unification: a unification problem whose solution is uniquely
/// determined by the syntactic shape of the spine. Flex-flex with
/// *different* metas but distinct-var spines is still inside the
/// pattern fragment, it just needs an extra construction.
///
/// Intersection is a standard pattern-fragment technique implemented
/// by every major proof assistant: Lean 4's flex-flex assignment
/// path, Agda (Abel & Pientka 2011 §4.3), and Coq's unification.
/// Full higher-order unification (undecidable, Huet 1975) is the
/// permanent non-goal in `SPEC.md` §1.3. Intersection is decidable
/// and is categorically different.
///
/// ## Algorithm (common-prefix case)
///
/// Given `?α x₀ x₁ … x_{m-1} ≡ ?β y₀ y₁ … y_{n-1}` with distinct-var
/// spines, let `k` be the length of the longest common positional
/// prefix, largest `k` such that `x_i == y_i` for all `i < k`. If
/// `k == 0` there is no shared binder to project through; decline.
///
/// Allocate a fresh meta `?γ` with the first `k` domains of one of
/// the existing metas' declared types (both metas must agree on
/// those domains by well-typing; we read from `?α`'s type). `?γ`'s
/// return type is the type of the unification site, i.e. the value
/// type of either side after its spine is consumed, we read that
/// from `?α`'s Pi-chain continuation.
///
/// Solve:
///
///   ?α := λ(x_0: T_0) … λ(x_{m-1}: T_{m-1}). ?γ x_0 … x_{k-1}
///   ?β := λ(y_0: T_0) … λ(y_{n-1}: T_{n-1}). ?γ y_0 … y_{k-1}
///
/// After both solves, `?α σ` unfolds to `?γ x_0 … x_{k-1}` and
/// `?β τ` unfolds to `?γ y_0 … y_{k-1}`. Since the prefix agrees
/// (x_i == y_i for i < k), both sides are literally the same value,
/// subsequent conv calls force the solved metas and compare
/// equal.
///
/// ## Scope limitation
///
/// Only the common-prefix case is implemented. Fully general
/// intersection (shared variables at arbitrary non-prefix positions,
/// e.g. `?α a b c ≡ ?β c a`) requires projecting through a permutation
/// and allocating the fresh meta with a correspondingly-permuted
/// Pi-chain. The common-prefix case covers the implicit-prefix
/// pattern that recursive calls at `append`, `map`, `plus` produce
/// (prefixes that differ only in whether one additional outer binder
/// is in scope). Non-prefix intersection is not implemented.
///
/// ## Stack safety
///
/// The construction allocates two solutions and one fresh meta
/// constant work. No kernel recursion (the conv call stack returns
/// `_YieldC(ConvOk)`; subsequent meta-force happens lazily on the
/// next conv dispatch).
///
/// ## Spine conventions
///
/// [args1] and [args2] arrive in **last-applied-first** order (the
/// order the `_Conv` NApp-walking loop accumulates). For the
/// intersection computation we reverse once to canonical
/// leftmost-first (the same order `_metaHeadAndSpine` returns),
/// compare prefix-wise, and build solutions in leftmost-first
/// `λ`-outer order.
ConvResult? _tryFlexFlexIntersect(
  int idA,
  List<Value> args1,
  int idB,
  List<Value> args2,
  int level,
  MetaContext metas,
) {
  // Both metas must be unsolved. (The force-at-top step in `_Conv`
  // unfolds solved meta heads before we get here; a solved head
  // means the solver already has work to do on the unfolded form.)
  final entryA = metas.lookup(idA);
  final entryB = metas.lookup(idB);
  if (entryA is! TermMetaUnsolved) return null;
  if (entryB is! TermMetaUnsolved) return null;

  // Canonicalize spines to leftmost-first order.
  final spineA = args1.reversed.toList();
  final spineB = args2.reversed.toList();

  // Pattern-fragment check: each arg in both spines must be a
  // distinct NVar. Collect levels as ints.
  final (varsA, okA) = _patternVars(spineA);
  if (!okA) return null;
  final (varsB, okB) = _patternVars(spineB);
  if (!okB) return null;

  // Canonical elaborator-emitted spines are `[NVar(0), NVar(1), …,
  // NVar(k-1)]` (`_insertImplicits` in elab.dart applies outermost
  // binder first). We require the canonical shape here too, matches
  // the invariant `_tryUnify` relies on, and keeps solution building
  // a direct Pi-chain walk.
  for (var i = 0; i < varsA.length; i++) {
    if (varsA[i] != i) return null;
  }
  for (var i = 0; i < varsB.length; i++) {
    if (varsB[i] != i) return null;
  }

  // Common-prefix length.
  final minLen = varsA.length < varsB.length ? varsA.length : varsB.length;
  var prefix = 0;
  while (prefix < minLen && varsA[prefix] == varsB[prefix]) {
    prefix++;
  }
  // With canonical spines `[0, 1, …]`, the prefix is always
  // `minLen`, they agree on the shared positions by construction.
  // Keep the loop for defensive generality.
  if (prefix == 0) return null;

  // Build the fresh meta's type: walk `entryA.typeExpected`'s
  // Pi chain, take the first `prefix` domains, use the opened
  // codomain after `prefix` peels as the return type.
  final domains = <Value>[];
  var cursor = entryA.typeExpected;
  for (var i = 0; i < prefix; i++) {
    if (cursor is! VPi) return null;
    domains.add(cursor.domain);
    cursor = eval(
      cursor.codomain.body,
      cursor.codomain.env.extend(VNeutral(NVar(i))),
    );
  }
  // Reassemble as a closed Pi chain. `_closeValueOverCtx`-style
  // construction: quote each domain at its binding depth and wrap.
  Term bodyTerm = quote(prefix, cursor);
  for (var i = prefix - 1; i >= 0; i--) {
    final domT = quote(i, domains[i]);
    bodyTerm = TPi(domT, bodyTerm);
  }
  final freshMetaType = eval(bodyTerm, const ENil());
  // Allocate the fresh meta with an empty local ctx, its type is
  // closed, matching the invariant `_closeValueOverCtx` maintains.
  final gammaId = metas.freshTermMeta(freshMetaType, const CNil());

  // Build solutions.
  //
  // For a meta `?m` with spine length n:
  //   solution = λ(T_0) … λ(T_{n-1}). ?γ TBound(n-1) TBound(n-2) …
  //                                     TBound(n-prefix)
  //
  // The λ-chain binds outermost-first; TBound(n-1-k) at the innermost
  // position is the k-th binder (k=0 = outermost). We want to apply
  // ?γ to the first `prefix` binders (positions 0..prefix-1), which
  // have TBound indices `n-1, n-2, …, n-prefix` under the innermost
  // of the `n` λs.
  Term buildSolution(int spineLen, MetaEntry origEntry) {
    // Extract this meta's own domain types (for the λ-chain) from
    // its typeExpected.
    final origDomains = <Term>[];
    var c = (origEntry as TermMetaUnsolved).typeExpected;
    for (var i = 0; i < spineLen; i++) {
      if (c is! VPi) {
        throw StateError(
          '_tryFlexFlexIntersect: meta typeExpected Pi-chain shorter '
          'than spine length, elaborator invariant violation',
        );
      }
      origDomains.add(quote(i, c.domain));
      c = eval(c.codomain.body, c.codomain.env.extend(VNeutral(NVar(i))));
    }
    // Build body: ?γ applied to the first `prefix` binders.
    Term body = TMeta(gammaId);
    for (var k = 0; k < prefix; k++) {
      body = TApp(body, TBound(spineLen - 1 - k));
    }
    // Wrap body in λ chain innermost-first (so iteration builds
    // outermost-last, same discipline as _tryUnify).
    var solution = body;
    for (var i = spineLen - 1; i >= 0; i--) {
      solution = TLam(origDomains[i], solution);
    }
    return solution;
  }

  final solutionA = buildSolution(varsA.length, entryA);
  final solutionB = buildSolution(varsB.length, entryB);
  // Inline solved nested metas before storing (see `_tryUnify`
  // for the rationale and Lean 4 parity citation).
  final inlinedA = inlineSolvedMetas(solutionA, metas);
  final inlinedB = inlineSolvedMetas(solutionB, metas);
  // solve-time scope check on both solutions.
  // See `_tryUnify`'s matching comment for the rationale.
  if (!_solutionWellScopedUnderCtx(inlinedA, entryA.localCtx)) return null;
  if (!_solutionWellScopedUnderCtx(inlinedB, entryB.localCtx)) return null;
  metas.solve(idA, inlinedA);
  metas.solve(idB, inlinedB);
  return const ConvOk();
}

/// const-approximation at flex-flex same-id.
///
/// Fires when `_Conv` sees `?m σ ≡ ?m τ` with diverging spines.
/// Solves `?m := λ(T₀)…λ(T_{n-1}). ?aux` where:
///   * `n = spine.length` (number of applied args at the site);
///   * `T_i` are the first n Pi-domains of the meta's declared
///     `typeExpected` (which must have ≥ n Pi layers for the
///     solve to be well-typed);
///   * `?aux` is a fresh meta whose type is the return-type
///     of `typeExpected` after peeling n Pi layers, and whose
///     `localCtx` inherits the original meta's stored
///     declaration-site scope (as Lean's constant-assignment
///     case does).
///
/// The solution is a constant function: applying it discards
/// the spine entirely and yields `?aux`, which is a
/// well-formed value under the meta's declaration-site scope.
/// Both sides `?m σ` and `?m τ` reduce to the same `?aux`,
/// succeeding where pointwise compare would have failed.
///
/// ## Gate
///
/// Fires when:
///   1. Every spine arg is an NVar (pattern fragment, same
///      check `_tryUnify` uses; non-pattern spines are out of
///      scope for solution construction);
///   2. NVars need NOT be distinct, we throw away the spine
///      entirely, so duplicate-position solutions are fine;
///   3. The meta's `typeExpected` has ≥ n Pi layers, needed
///      to supply well-typed domain terms for the λ-chain.
///
/// Declines and returns `null` otherwise (caller falls back
/// to pointwise compare, preserves prior behaviour).
///
/// ## Ordering vs pointwise
///
/// Lean runs pointwise compare FIRST and falls back to
/// const-approx on failure. Doxa's `_drive` can't observe
/// pointwise failure and retry; the caller uses a cheap
/// pointer-identity divergence check as a pre-guard:
/// all-identical spines skip const-approx (pointwise is a
/// no-op), non-identical spines attempt const-approx first.
/// See the caller's comment block at `_Conv`'s same-id branch.
ConvResult? _tryConstApproxAtSameMeta(
  int id,
  List<Value> spine,
  MetaContext metas,
) {
  final entry = metas.lookup(id);
  if (entry is! TermMetaUnsolved) return null;
  // Pattern-fragment check: every spine arg must be an NVar.
  // Distinctness is NOT required (the const-approx solution
  // discards the spine).
  for (final s in spine) {
    if (s is! VNeutral) return null;
    if (s.neutral is! NVar) return null;
  }
  final n = spine.length;
  // Build the λ-chain domains from the meta's typeExpected Pi chain.
  // At least `n` Pi layers required (matches `_tryUnify`'s technique).
  final domainTerms = <Term>[];
  var typeCursor = entry.typeExpected;
  for (var i = 0; i < n; i++) {
    if (typeCursor is! VPi) return null;
    domainTerms.add(quote(i, typeCursor.domain));
    typeCursor = eval(
      typeCursor.codomain.body,
      typeCursor.codomain.env.extend(VNeutral(NVar(i))),
    );
  }
  // `?aux` has the peeled return type AND inherits the original
  // meta's localCtx: no conv-site lctx reconstruction, because the
  // fresh meta's solution references decl-site fvars only, not the
  // use-site spine (as in Lean's constant-assignment case).
  //
  // The fresh meta's type is the opened codomain after n peels.
  // Quote + re-eval under decl-site scope to detach from the
  // opening NVar substitutions we used for cursor advance.
  final auxType = eval(quote(n, typeCursor), const ENil());
  final auxId = metas.freshTermMeta(auxType, entry.localCtx);
  // Solution: λ(T₀)…λ(T_{n-1}). ?aux, the λ-chain discards all
  // spine args; body references only `?aux`, which is closed
  // under its own localCtx.
  Term solution = TMeta(auxId);
  for (var i = n - 1; i >= 0; i--) {
    solution = TLam(domainTerms[i], solution);
  }
  // Scope check: the solution is closed under the λ-chain
  // (body is a bare TMeta(auxId) with no free TBounds) and is
  // well-scoped under entry.localCtx by construction. We still run
  // the check for defense-in-depth and parity with the other
  // solve sites.
  if (!_solutionWellScopedUnderCtx(solution, entry.localCtx)) return null;
  metas.solve(id, solution);
  return const ConvOk();
}

/// Extract the NVar-level list from a pattern-shape spine, or
/// `(<empty>, false)` if the spine is not a valid pattern (non-NVar
/// arg, or duplicate var).
(List<int>, bool) _patternVars(List<Value> spine) {
  final vars = <int>[];
  final seen = <int>{};
  for (final s in spine) {
    if (s is! VNeutral) return (const [], false);
    final n = s.neutral;
    if (n is! NVar) return (const [], false);
    if (seen.contains(n.level)) return (const [], false);
    seen.add(n.level);
    vars.add(n.level);
  }
  return (vars, true);
}

/// Renaming pass used by pattern-unif solve: remap free TBound
/// references in the quoted rhs from "relative to [level]" to
/// "relative to the solution's λ-chain over [vars]".
///
/// A free TBound(k) at walk depth d corresponds to absolute level
/// `level - 1 - (k - d)`. That level is at position `absToPos[L]`
/// in `vars`. Under a solution λ-chain of length `n = vars.length`,
/// that position's binder sits at innermost-depth `n - 1 - pos`.
/// Under `d` inner binders (from walking under lambdas/Pis inside
/// rhs), the final index is `n - 1 - pos + d`.
Term _renameForSolution(
  Term term, {
  required int level,
  required List<int> vars,
  required Map<int, int> absToPos,
}) {
  final n = vars.length;
  Term walk(Term t, int depth) => switch (t) {
    TBound(:final index) when index >= depth => () {
      final absLevel = level - 1 - (index - depth);
      final pos = absToPos[absLevel];
      if (pos == null) {
        // Out of scope, should have been caught by the well-
        // scoped check upstream. Fall through to identity as
        // a defensive no-op.
        return t;
      }
      return TBound(n - 1 - pos + depth);
    }(),
    TBound() => t,
    TType() ||
    TSProp() ||
    TProp() ||
    TFree() ||
    TTop() ||
    TRec() ||
    TMeta() => t,
    TApp(:final fn, :final arg) => TApp(walk(fn, depth), walk(arg, depth)),
    TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
      walk(domain, depth),
      walk(codomain, depth + 1),
      name: name,
      icit: icit,
    ),
    TLam(:final domain, :final body, :final name, :final icit) => TLam(
      walk(domain, depth),
      walk(body, depth + 1),
      name: name,
      icit: icit,
    ),
    TLet(:final domain, :final bound, :final body, :final name) => TLet(
      walk(domain, depth),
      walk(bound, depth),
      walk(body, depth + 1),
      name: name,
    ),
    TData(:final name, :final args) => TData(name, [
      for (final a in args) walk(a, depth),
    ]),
    TConstr(:final dataName, :final ctorName, :final args) => TConstr(
      dataName,
      ctorName,
      [for (final a in args) walk(a, depth)],
    ),
    TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
      walk(scrutinee, depth),
      motive == null ? null : walk(motive, depth),
      [
        for (final c in cases)
          TMatchCase(
            c.ctorName,
            c.nBinders,
            walk(c.body, depth + c.nBinders),
            c.binderNames,
            span: c.span,
          ),
      ],
    ),
    TQuot(:final carrier, :final relation) => TQuot(
      walk(carrier, depth),
      walk(relation, depth),
    ),
    TQuotMk(:final arg) => TQuotMk(walk(arg, depth)),
    TQuotLift(:final quot, :final fn, :final proof) => TQuotLift(
      walk(quot, depth),
      walk(fn, depth),
      walk(proof, depth),
    ),
    TProj(:final expr, :final fieldName) => TProj(walk(expr, depth), fieldName),
  };
  return walk(term, 0);
}

/// True iff every binding in [env] is
/// a fresh NVar whose level matches its own position (innermost-
/// first: env.lookup(0) = NVar(env.depth - 1), env.lookup(1) =
/// NVar(env.depth - 2), ...).
///
/// This is the shape produced by driver frames that bind arm
/// binders to fresh neutrals in order. When env has this shape, a
/// body term's free TBound references correspond uniformly to
/// outer-scope binders at a fixed shift, no per-ref substitution
/// needed.
///
/// The β-reduction that builds stuck VMatches for things like
/// `plus n_outer m_outer` produces a NON-trivial env: env entries
/// come from arg values passed in, which may be NVars at outer
/// levels or non-NVar Values. Those cases need full substitution.
/// Walk [env] forcing solved metas at the head of each entry.
/// Unsolved metas pass through unchanged; solved metas unfold via
/// `_forceMetaHead`. Returns the same `Env` instance when no entry
/// changed (identity sharing).
///
/// Needed for VMatch-vs-VMatch conv: when pattern unification
/// solves a meta that was captured in a VMatch's env at build time,
/// the env entry still points at the NMeta neutral. Arm-body
/// normalization must see the solved form, otherwise two VMatches
/// whose arm bodies differ only via a solved-meta-bound entry
/// compare unequal even though they're semantically identical.
Env _forceEnvMetas(Env env, MetaContext metas) {
  if (env is ENil) return env;
  final entries = <Value>[];
  var changed = false;
  var e = env;
  while (e is ECons) {
    final original = e.head;
    final forced = _forceMetaHead(original, metas, env.topBindings);
    if (!identical(forced, original)) changed = true;
    entries.add(forced);
    e = e.tail;
  }
  if (!changed) return env;
  // Rebuild ENil + ECons in original outer-first order. `entries`
  // is innermost-first (matching the ECons walk); to reconstruct
  // outer-to-inner via extend() we reverse. Inherit the dataDecls
  // and topBindings registries from the source env, the force
  // pass only changes values, not the surrounding registries.
  Env rebuilt = ENil.withRegistries(
    dataDecls: env.dataDecls,
    topBindings: env.topBindings,
  );
  for (final v in entries.reversed) {
    rebuilt = rebuilt.extend(v);
  }
  return rebuilt;
}

/// Extend [base] by [nBinders] fresh-NVar neutrals starting at
/// [startLevel]. Used by tier 3 of the VMatch × VMatch conv
/// branch: each side evaluates its arm body under its own
/// captured forced env (preserving outer-scope bindings at the
/// levels they were originally captured) extended with symbolic
/// NVars for the arm-local binders.
///
/// When [topBindings] is supplied, the returned env's topBindings
/// map is augmented with its entries (outer conv's snapshot wins
/// on key collisions). This lets the inner eval see the outer
/// conv's complete registry even when [base] was captured during
/// an earlier incremental build that had only prior bindings
///.
/// Build the env that correctly resolves the output of
/// `_substArmBody(_, level, nBinders)`.
///
/// `_substArmBody` normalizes outer-scope TBounds into LEVEL-
/// relative coordinates: an outer NVar(L) becomes
/// `TBound(level + depth - 1 - L)` (see its fast-path branch).
/// Arm-local TBounds `0..nBinders-1` are preserved.
///
/// Matching env, at total depth `level + nBinders`:
///
///   * `lookup(k)` for `k ∈ [0, nBinders)` → fresh arm-local
///     NVars `[NVar(level + nBinders - 1), …, NVar(level)]`
///     innermost-first (so TBound(0) = NVar(level+nBinders-1)).
///   * `lookup(nBinders + k)` for `k ∈ [0, level)` →
///     `NVar(level - 1 - k)`. I.e. TBound(nBinders + level - 1)
///     resolves to NVar(0), TBound(nBinders) resolves to
///     NVar(level - 1), the level-scope identity shifted past
///     the arm binders.
///
/// Used by VMatch × VMatch tier-3 conv to eval the env-
/// normalized arm bodies consistently across both sides. Two
/// VMatches captured at differently-populated same-depth envs
/// (the list-proof case: motive-β vs user-expression
/// reduction paths yielded different captured-env entries)
/// produce identical tier-3 values when eval'd under this
/// shared env.
Env _armIdentityEnv({
  required int level,
  required int nBinders,
  Map<String, TopBindingEntry>? topBindings,
  List<DataDecl>? dataDecls,
}) {
  var e =
      ENil.withRegistries(
            dataDecls: dataDecls ?? const <DataDecl>[],
            topBindings: topBindings ?? const <String, TopBindingEntry>{},
          )
          as Env;
  // Outer binders, extended outermost-first: NVar(0), NVar(1),
  // ..., NVar(level-1). After this phase, lookup(level-1-k) =
  // NVar(k) for k in [0, level).
  for (var i = 0; i < level; i++) {
    e = e.extend(VNeutral(NVar(i)));
  }
  // Arm binders on top: NVar(level), ..., NVar(level+nBinders-1).
  // After this phase, lookup(0) = NVar(level+nBinders-1)
  // (innermost), ..., lookup(nBinders-1) = NVar(level).
  for (var i = 0; i < nBinders; i++) {
    e = e.extend(VNeutral(NVar(level + i)));
  }
  return e;
}

bool _envIsTrivialIdentity(Env env) {
  var e = env;
  final d = env.depth;
  var pos = 0;
  while (e is ECons) {
    final h = e.head;
    if (h is! VNeutral) return false;
    final n = h.neutral;
    if (n is! NVar) return false;
    if (n.level != d - 1 - pos) return false;
    pos++;
    e = e.tail;
  }
  return true;
}

/// Substitution-based quote for a
/// VMatch arm body.
///
/// Walks [term] structurally, replacing each free TBound(k) (where
/// k >= nBinders + walkDepth, i.e. it points outside the arm-local
/// binders) with the outer-scope term form of `env.lookup(k -
/// nBinders - walkDepth)`. Arm-local and internal-lambda binders
/// are preserved.
///
/// Fast path: when the env entry is a fresh NVar neutral (the
/// typical case for binders introduced during β-reduction), we
/// compute its outer-scope TBound index directly without re-entering
/// the driver. This keeps deep-nested stuck matches (e.g. the
/// 10k-VMatch stack-safety stress case) from recursing into
/// `quote`.
///
/// Fallback: for compound env values, `quote(level + depth, v)`
/// re-enters the driver. This is the rare case (functions,
/// constructors, or further stuck computations passed as binder
/// values); acceptable trade-off for correctness.
///
/// ## TMeta spine scope-aware substitution
///
/// When [metas] is supplied and the walker encounters a
/// `TApp*(TMeta(id), arg_1, …, arg_n)` subterm, the spine args'
/// TBound indices are interpreted at the meta's **emission
/// scope** (`entry.localCtx.level`), NOT at the arm body's
/// current re-interpretation scope. The enclosing arm body may
/// have been captured inside a larger context than the meta's
/// emission scope, so a spine TBound(k) that looks like an
/// arm-local reference in the arm scope was actually an env
/// reference at emission time.
///
/// Correction: when walking a spine arg, use an env-lookup
/// threshold of `walker-depth` (i.e. 0 ignoring inner λ/Π
/// binders inside the arg), not `nBinders + walker-depth`.
/// That is: every TBound(k) in a spine arg with `k >= arg-walk-
/// depth` is an env lookup, bypassing the arm-binder threshold
/// check that the main walker uses.
Term _substArmBody(
  Term term, {
  required Env env,
  required int level,
  required int nBinders,
  MetaContext? metas,
}) {
  // Resolve a free TBound(k) (k >= threshold) as an env lookup.
  // Returns the outer-scope TBound/TTop/quoted term.
  // [envIdxAdj] adjusts the env index: use `nBinders + depth` for
  // arm-body positions (main walker) or `depth` for TMeta-spine
  // arg positions (scope-aware).
  // The quote level for the resolved binder uses [envIdxAdj] (which
  // includes nBinders for the main walker) so that the arm-local
  // binder depth is reflected in the TBound index — necessary when
  // `level > env.depth` and the main-walk vs meta-spine regimes
  // need independent shifts.
  Term resolveViaEnv(int index, int depth, int envIdxAdj) {
    final envIdx = index - envIdxAdj;
    final envValue = env.lookup(envIdx);
    if (envValue is VNeutral) {
      final n = envValue.neutral;
      if (n is NVar) {
        return TBound(level + envIdxAdj - 1 - n.level);
      }
      if (n is NTop) {
        return TTop(n.name);
      }
    }
    return quote(level + envIdxAdj, envValue);
  }

  late final Term Function(Term, int) walk;
  late final Term Function(Term, int) walkSpineArg;

  walkSpineArg = (t, argDepth) {
    // Scope-aware for nested TMeta spines inside a spine arg.
    if (metas != null) {
      final nestedSpine = _termHeadTMetaAndSpine(t);
      if (nestedSpine != null) {
        final id = nestedSpine.$1;
        final args = nestedSpine.$2;
        Term rebuilt = TMeta(id);
        for (final a in args) {
          rebuilt = TApp(rebuilt, walkSpineArg(a, argDepth));
        }
        return rebuilt;
      }
    }
    return switch (t) {
      // Scope-aware: threshold is `argDepth`, not `nBinders +
      // argDepth`. A TBound that looks arm-local here was in fact
      // an env reference at emission scope.
      TBound(:final index) when index >= argDepth => resolveViaEnv(
        index,
        argDepth,
        argDepth,
      ),
      TBound() => t,
      TType() ||
      TSProp() ||
      TProp() ||
      TFree() ||
      TTop() ||
      TRec() ||
      TMeta() => t,
      TApp(:final fn, :final arg) => TApp(
        walkSpineArg(fn, argDepth),
        walkSpineArg(arg, argDepth),
      ),
      TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
        walkSpineArg(domain, argDepth),
        walkSpineArg(codomain, argDepth + 1),
        name: name,
        icit: icit,
      ),
      TLam(:final domain, :final body, :final name, :final icit) => TLam(
        walkSpineArg(domain, argDepth),
        walkSpineArg(body, argDepth + 1),
        name: name,
        icit: icit,
      ),
      TLet(:final domain, :final bound, :final body, :final name) => TLet(
        walkSpineArg(domain, argDepth),
        walkSpineArg(bound, argDepth),
        walkSpineArg(body, argDepth + 1),
        name: name,
      ),
      TData(:final name, :final args) => TData(name, [
        for (final a in args) walkSpineArg(a, argDepth),
      ]),
      TConstr(:final dataName, :final ctorName, :final args) => TConstr(
        dataName,
        ctorName,
        [for (final a in args) walkSpineArg(a, argDepth)],
      ),
      TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
        walkSpineArg(scrutinee, argDepth),
        motive == null ? null : walkSpineArg(motive, argDepth),
        [
          for (final c in cases)
            TMatchCase(
              c.ctorName,
              c.nBinders,
              walkSpineArg(c.body, argDepth + c.nBinders),
              c.binderNames,
              span: c.span,
            ),
        ],
      ),
      TQuot(:final carrier, :final relation) => TQuot(
        walkSpineArg(carrier, argDepth),
        walkSpineArg(relation, argDepth),
      ),
      TQuotMk(:final arg) => TQuotMk(walkSpineArg(arg, argDepth)),
      TQuotLift(:final quot, :final fn, :final proof) => TQuotLift(
        walkSpineArg(quot, argDepth),
        walkSpineArg(fn, argDepth),
        walkSpineArg(proof, argDepth),
      ),
      TProj(:final expr, :final fieldName) => TProj(
        walkSpineArg(expr, argDepth),
        fieldName,
      ),
    };
  };

  walk = (t, depth) {
    // Detect a TMeta-headed spine subterm. Its spine
    // args' TBound references were emitted relative to the
    // meta's emission scope, so arm-binder indices (k < nBinders)
    // that look local in the arm scope are actually env
    // references. Walk spine args with `threshold = argDepth`
    // instead of `threshold = nBinders + argDepth`.
    if (metas != null) {
      final headSpine = _termHeadTMetaAndSpine(t);
      if (headSpine != null) {
        final id = headSpine.$1;
        final args = headSpine.$2;
        Term rebuilt = TMeta(id);
        for (final a in args) {
          rebuilt = TApp(rebuilt, walkSpineArg(a, depth));
        }
        return rebuilt;
      }
    }
    return switch (t) {
      TBound(:final index) when index >= nBinders + depth => resolveViaEnv(
        index,
        depth,
        nBinders + depth,
      ),
      TBound() => t,
      TType() ||
      TSProp() ||
      TProp() ||
      TFree() ||
      TTop() ||
      TRec() ||
      TMeta() => t,
      TApp(:final fn, :final arg) => TApp(walk(fn, depth), walk(arg, depth)),
      TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
        walk(domain, depth),
        walk(codomain, depth + 1),
        name: name,
        icit: icit,
      ),
      TLam(:final domain, :final body, :final name, :final icit) => TLam(
        walk(domain, depth),
        walk(body, depth + 1),
        name: name,
        icit: icit,
      ),
      TLet(:final domain, :final bound, :final body, :final name) => TLet(
        walk(domain, depth),
        walk(bound, depth),
        walk(body, depth + 1),
        name: name,
      ),
      TData(:final name, :final args) => TData(name, [
        for (final a in args) walk(a, depth),
      ]),
      TConstr(:final dataName, :final ctorName, :final args) => TConstr(
        dataName,
        ctorName,
        [for (final a in args) walk(a, depth)],
      ),
      TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
        walk(scrutinee, depth),
        motive == null ? null : walk(motive, depth),
        [
          for (final c in cases)
            TMatchCase(
              c.ctorName,
              c.nBinders,
              walk(c.body, depth + c.nBinders),
              c.binderNames,
              span: c.span,
            ),
        ],
      ),
      TQuot(:final carrier, :final relation) => TQuot(
        walk(carrier, depth),
        walk(relation, depth),
      ),
      TQuotMk(:final arg) => TQuotMk(walk(arg, depth)),
      TQuotLift(:final quot, :final fn, :final proof) => TQuotLift(
        walk(quot, depth),
        walk(fn, depth),
        walk(proof, depth),
      ),
      TProj(:final expr, :final fieldName) => TProj(
        walk(expr, depth),
        fieldName,
      ),
    };
  };

  return walk(term, 0);
}

/// Force a meta-headed neutral with a solved meta to its fully-
/// applied form. If [v] is `VNeutral(NMeta(id) spine)` and `id` is
/// solved, evaluate the solution term and apply the spine (leftmost
/// arg first), returning the resulting Value. Otherwise return [v]
/// unchanged.
///
/// Matches Kovács's `force` operation: drives an unsolved neutral
/// to its solution one layer at a time. Structural conv cases below
/// never see solved metas; the force-at-top pattern keeps them
/// meta-agnostic.
///
/// The optional [topBindings] argument supplies the top-binding
/// registry used to eval the solution. Solutions produced by
/// `_tryUnify` are closed terms modulo TTop references (the quoted
/// rhs may name top-level bindings that were in scope at solve
/// time). Without a topBindings map, such solutions error at
/// eval-time when they reach a `TTop(name)` lookup, because the
/// closure built by `eval(..., ENil)` has no registry to resolve
/// against. Callers thread the outer scope's topBindings so that
/// forced-value closures carry a valid map through any subsequent
/// application or traversal. When omitted we fall back to the bare
/// ENil, safe only when the caller knows all solutions involved
/// are closed ground terms with no TTop references; any caller whose
/// solutions may reference top-level bindings must thread the
/// registry.
Value _forceMetaHead(
  Value v,
  MetaContext metas, [
  Map<String, TopBindingEntry>? topBindings,
]) {
  final spine = _metaHeadAndSpine(v);
  if (spine == null) return v;
  final entry = metas.lookup(spine.$1);
  if (entry is! TermMetaSolved) return v;
  // Evaluate the solution under an empty env (topBindings threaded
  // so TTop references resolve). Pattern-unification solutions are
  // closed λ-chains whose body TBounds reference only the chain's
  // own binders; `apply(VLam, arg)` below extends the closure env
  // with each spine arg, and the body's TBounds resolve against
  // that chain env.
  //
  // Lean and Agda both substitute a metavariable's solution without
  // padding the environment: solution-internal indices resolve
  // against the mvar's declared local context, and the spine is then
  // applied as eliminations, with no decl-site fvar padding.
  final Env evalEnv =
      topBindings == null
          ? const ENil()
          : ENil.withRegistries(
            dataDecls: const <DataDecl>[],
            topBindings: topBindings,
          );
  var result = eval(entry.solution, evalEnv);
  for (final arg in spine.$2) {
    result = apply(result, arg);
  }
  return result;
}

/// If [v] is `VNeutral` whose spine ends in an `NMeta` head, return
/// `(id, spine)` where spine is in leftmost-first order (first-applied
/// first). Otherwise `null`.
(int, List<Value>)? _metaHeadAndSpine(Value v) {
  if (v is! VNeutral) return null;
  final args = <Value>[];
  var n = v.neutral;
  while (n is NApp) {
    args.add(n.arg);
    n = n.fn;
  }
  if (n is! NMeta) return null;
  // Reverse so spine[0] is the leftmost (first-applied) arg: a
  // metavariable applied to its argument spine.
  return (n.id, args.reversed.toList());
}

/// Walk [t] enforcing:
///   * no `TMeta(forbiddenId)` appears (occurs check);
///   * every `TBound(i)` with `i >= depth` points at an index in
///     [allowedAtDepth0] after shifting by `depth` (scope check).
///
/// [depth] counts binders we've descended into since the solution
/// root. References with index `< depth` are locally bound and always
/// fine; references with index `>= depth` must, after subtracting
/// `depth`, lie in the allowed set.
bool _solutionWellScoped(
  Term t,
  int forbiddenId,
  Set<int> allowedAtDepth0,
  int depth,
) {
  switch (t) {
    case TType() || TSProp() || TProp() || TFree() || TTop() || TRec():
      return true;
    case TMeta(:final id):
      return id != forbiddenId;
    case TBound(:final index):
      if (index < depth) return true;
      return allowedAtDepth0.contains(index - depth);
    case TApp(:final fn, :final arg):
      return _solutionWellScoped(fn, forbiddenId, allowedAtDepth0, depth) &&
          _solutionWellScoped(arg, forbiddenId, allowedAtDepth0, depth);
    case TPi(:final domain, :final codomain):
      return _solutionWellScoped(domain, forbiddenId, allowedAtDepth0, depth) &&
          _solutionWellScoped(
            codomain,
            forbiddenId,
            allowedAtDepth0,
            depth + 1,
          );
    case TLam(:final domain, :final body):
      return _solutionWellScoped(domain, forbiddenId, allowedAtDepth0, depth) &&
          _solutionWellScoped(body, forbiddenId, allowedAtDepth0, depth + 1);
    case TLet(:final domain, :final bound, :final body):
      return _solutionWellScoped(domain, forbiddenId, allowedAtDepth0, depth) &&
          _solutionWellScoped(bound, forbiddenId, allowedAtDepth0, depth) &&
          _solutionWellScoped(body, forbiddenId, allowedAtDepth0, depth + 1);
    case TData(:final args):
      for (final a in args) {
        if (!_solutionWellScoped(a, forbiddenId, allowedAtDepth0, depth)) {
          return false;
        }
      }
      return true;
    case TConstr(:final args):
      for (final a in args) {
        if (!_solutionWellScoped(a, forbiddenId, allowedAtDepth0, depth)) {
          return false;
        }
      }
      return true;
    case TQuot(:final carrier, :final relation):
      return _solutionWellScoped(
            carrier,
            forbiddenId,
            allowedAtDepth0,
            depth,
          ) &&
          _solutionWellScoped(relation, forbiddenId, allowedAtDepth0, depth);
    case TQuotMk(:final arg):
      return _solutionWellScoped(arg, forbiddenId, allowedAtDepth0, depth);
    case TQuotLift(:final quot, :final fn, :final proof):
      return _solutionWellScoped(quot, forbiddenId, allowedAtDepth0, depth) &&
          _solutionWellScoped(fn, forbiddenId, allowedAtDepth0, depth) &&
          _solutionWellScoped(proof, forbiddenId, allowedAtDepth0, depth);
    case TProj(:final expr):
      return _solutionWellScoped(expr, forbiddenId, allowedAtDepth0, depth);
    case TMatch(:final scrutinee, :final motive, :final cases):
      if (!_solutionWellScoped(
        scrutinee,
        forbiddenId,
        allowedAtDepth0,
        depth,
      )) {
        return false;
      }
      if (motive != null &&
          !_solutionWellScoped(motive, forbiddenId, allowedAtDepth0, depth)) {
        return false;
      }
      for (final c in cases) {
        if (!_solutionWellScoped(
          c.body,
          forbiddenId,
          allowedAtDepth0,
          depth + c.nBinders,
        )) {
          return false;
        }
      }
      return true;
  }
}

/// verify the candidate solution [t] is
/// well-scoped under the meta's declaration-site [localCtx].
///
/// A free de-Bruijn index in [t] (one with index `>= depth`, where
/// `depth` is the number of binders entered since the root) is
/// interpreted as a reference to a binder in the enclosing
/// declaration context. That reference is **valid** iff the
/// corresponding binder was already in scope when the meta was
/// allocated, i.e. its depth-adjusted index falls within
/// `[0, localCtx.level)`. An index that points past the
/// declaration-site context's depth would escape the meta's
/// scope; Lean 4's assignment check rejects exactly that case.
///
/// Iterative structure (explicit work list) preserves Doxa's
/// SPEC §4.5 no-Dart-stack-per-syntax-layer invariant: the
/// 10k-VMatch pin exercises solve-time paths at
/// depth 10 000, so the walker must not grow the Dart stack
/// per `TMatch` or `TLam` arm.
bool _solutionWellScopedUnderCtx(Term t, Ctx localCtx) {
  final allowedOuter = localCtx.level;
  // Work list of (term, walker depth). depth = count of binders
  // entered since the solution root.
  final stack = <(Term, int)>[(t, 0)];
  while (stack.isNotEmpty) {
    final (cur, depth) = stack.removeLast();
    switch (cur) {
      case TType() ||
          TSProp() ||
          TProp() ||
          TFree() ||
          TTop() ||
          TRec() ||
          TMeta():
        // TType/TProp/TFree/TTop/TRec: no indices.
        // TMeta: own indices are interpreted via the nested meta's
        // own localCtx; an unsolved TMeta here is legal, the
        // delayed records handle spine-sensitive cases. The
        // occurs check already ran at solve time.
        break;
      case TBound(:final index):
        if (index < depth) break;
        final outerIdx = index - depth;
        if (outerIdx >= allowedOuter) return false;
      case TApp(:final fn, :final arg):
        stack.add((fn, depth));
        stack.add((arg, depth));
      case TPi(:final domain, :final codomain):
        stack.add((domain, depth));
        stack.add((codomain, depth + 1));
      case TLam(:final domain, :final body):
        stack.add((domain, depth));
        stack.add((body, depth + 1));
      case TLet(:final domain, :final bound, :final body):
        stack.add((domain, depth));
        stack.add((bound, depth));
        stack.add((body, depth + 1));
      case TData(:final args):
        for (final a in args) {
          stack.add((a, depth));
        }
      case TConstr(:final args):
        for (final a in args) {
          stack.add((a, depth));
        }
      case TQuot(:final carrier, :final relation):
        stack.add((carrier, depth));
        stack.add((relation, depth));
      case TQuotMk(:final arg):
        stack.add((arg, depth));
      case TQuotLift(:final quot, :final fn, :final proof):
        stack.add((quot, depth));
        stack.add((fn, depth));
        stack.add((proof, depth));
      case TProj(:final expr):
        stack.add((expr, depth));
      case TMatch(:final scrutinee, :final motive, :final cases):
        stack.add((scrutinee, depth));
        if (motive != null) stack.add((motive, depth));
        for (final c in cases) {
          stack.add((c.body, depth + c.nBinders));
        }
    }
  }
  return true;
}

/// True iff `dataDecl` admits SPEC §8.2 singleton elimination into Type:
/// the inductive has at most one constructor, and that constructor has
/// no "informative" args.
///
/// An arg is "informative" when its value carries runtime-data content.
/// An arg is non-informative when it's either (a) Prop-sorted
/// (proof-irrelevant, no content) or (b) index-determined (its value
/// is forced by the ctor's resultIndices via pattern-refinement
/// unification, no runtime content leaks).
///
/// The (b) clause is what lets `Eq.refl : (x: A) -> Eq[A] x x` admit
/// singleton elim: `x` is Type-sorted, but its value is uniquely
/// determined by the scrutinee's indices (both `Eq`'s indices equal
/// `x`), so the pattern `refl x` on a scrutinee of type `Eq[A] a b`
/// forces `x = a = b`, no additional runtime information beyond what
/// the scrutinee already carries.
///
/// Implementation: an arg at ctor-arg-depth `j` counts as index-
/// determined iff its TBound index (from inside the ctor's arg
/// telescope) appears as the HEAD of at least one `resultIndices`
/// entry. We walk each resultIndex term and collect the set of TBound
/// indices mentioned at non-param positions; an arg is forced iff its
/// own binder is in that set.
///
/// Note: we intentionally keep this check first-order (appears-as-head
/// in resultIndices). More elaborate determinism analysis (e.g. an arg
/// forced through a non-invertible function in resultIndices) is Phase
/// 13's pattern-unification territory. The first-order rule is what
/// Lean 4 and Coq ship and what covers every stdlib proof.
///
/// Examples:
///   * `data Eq[A] : A -> A -> Prop { refl : (x: A) -> Eq[A] x x }`,
///     refl's one arg `x` is mentioned as a resultIndex head → index-
///     determined → admits. Matches Lean 4's `Eq.rec` singleton-elim.
///   * `data And[A: Prop, B: Prop] : Prop { conj : A -> B -> And[A,B] }`,
///     conj's args have Prop-sorted types → non-informative →
///     admits.
///   * `data Or[A: Prop, B: Prop] : Prop { inl : A -> Or; inr : B -> Or }`,
///     2 ctors → rejects (large-elim is unsound for Or).
///   * `data Box : Prop { box : Nat -> Box }`, box's arg is
///     Type-sorted AND doesn't appear in resultIndices → informative
///     → rejects.
///
/// Runs at match-check time. Cost is one `infer` per ctor arg + a
/// small term walk per resultIndex, bounded by the ctor's arity.
/// Public entry to [_admitsSingletonElimImpl]. Used by the elab site
/// to decide whether a data decl needs a `T.rect`
/// large-elim variant alongside the default `T.rec`.
bool admitsSingletonElim(DataDecl dataDecl, Ctx baseCtx) =>
    _admitsSingletonElim(dataDecl, baseCtx);

bool _admitsSingletonElim(DataDecl dataDecl, Ctx baseCtx) {
  // Only meaningful for Prop-sorted data.
  if (dataDecl.sort is! TProp) return false;
  // Zero ctors (e.g. a `False : Prop {}` absurdity type): vacuously
  // admits, the match is unreachable, any motive sort is fine.
  if (dataDecl.ctors.isEmpty) return true;
  // More than one ctor: never admits. Accepting would let the user
  // case-split on a proof into different runtime values, violating
  // proof-irrelevance.
  if (dataDecl.ctors.length > 1) return false;

  final ctor = dataDecl.ctors.first;
  final argCount = ctor.args.length;

  // Collect the set of TBound indices (from INSIDE the ctor's arg
  // telescope) mentioned as heads of resultIndices. These args are
  // index-determined and therefore non-informative.
  final indexDetermined = <int>{};
  for (final idx in ctor.resultIndices) {
    _collectHeadBounds(idx, indexDetermined);
  }

  // Build a telescope Ctx with the data's params bound as fresh
  // neutrals. Arg types are closed under params + preceding args,
  // so we extend incrementally as we walk.
  var ctx = baseCtx;
  for (final p in dataDecl.params) {
    final domV = eval(p.type, ctx.env);
    ctx = ctx.extend(domV);
  }

  // Classify each arg. An arg is non-informative iff either:
  //   (a) its type's sort is Prop, OR
  //   (b) its TBound index (from innermost = last-arg) is in the
  //       index-determined set.
  for (var j = 0; j < argCount; j++) {
    final arg = ctor.args[j];
    // Innermost arg has TBound index 0; arg[j] has index argCount-1-j.
    final argDeBruijn = argCount - 1 - j;
    final indexForced = indexDetermined.contains(argDeBruijn);
    if (!indexForced) {
      final argSort = infer(ctx, arg.type);
      if (argSort is! VProp) return false;
    }
    // Extend ctx for the next arg's type (closed under this binder).
    final argTypeV = eval(arg.type, ctx.env);
    ctx = ctx.extend(argTypeV);
  }
  return true;
}

/// Shift every `TBound(j)` in [term] where `j >= threshold` by
/// [shiftBy]. Used by `synthRecursorType` to relocate TBound
/// references to outer binders (e.g. data-type params) when the
/// recursor-type construction inserts new binders between the
/// index telescope and the params (methods + motive).
///
/// Binders introduced INSIDE [term] (under TPi/TLam/TLet) bump the
/// threshold accordingly so inner binders stay unshifted.
///
/// `TApp*(TMeta(id), σ)` subterms receive a uniform
/// shift. A σ argument was emitted against the meta's declaration
/// ctx by `_insertImplicits` (as `TApp(_, TBound(k))` for
/// k ∈ [0, ctx.level)), and the meta's declaration ctx contains no
/// arm-local binders from an enclosing walker. Every `TBound` in σ
/// is therefore an outer-scope
/// reference from σ's viewpoint; the threshold rule used for the
/// enclosing term's own arm-local-vs-outer discipline does not
/// apply. [uniShift] shifts all σ TBounds uniformly by [shiftBy]
/// past any binders introduced inside σ itself, preserving σ's
/// semantic reference to emission-site binders across the
/// enclosing wrap.
Term _shiftTBoundPastThreshold(
  Term term, {
  required int threshold,
  required int shiftBy,
}) {
  Term uniShift(Term t, int depth) => switch (t) {
    TBound(:final index) when index >= depth => TBound(index + shiftBy),
    TBound() => t,
    TType() ||
    TSProp() ||
    TProp() ||
    TFree() ||
    TTop() ||
    TRec() ||
    TMeta() => t,
    TApp(:final fn, :final arg) => TApp(
      uniShift(fn, depth),
      uniShift(arg, depth),
    ),
    TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
      uniShift(domain, depth),
      uniShift(codomain, depth + 1),
      name: name,
      icit: icit,
    ),
    TLam(:final domain, :final body, :final name, :final icit) => TLam(
      uniShift(domain, depth),
      uniShift(body, depth + 1),
      name: name,
      icit: icit,
    ),
    TLet(:final domain, :final bound, :final body, :final name) => TLet(
      uniShift(domain, depth),
      uniShift(bound, depth),
      uniShift(body, depth + 1),
      name: name,
    ),
    TData(:final name, :final args) => TData(name, [
      for (final a in args) uniShift(a, depth),
    ]),
    TConstr(:final dataName, :final ctorName, :final args) => TConstr(
      dataName,
      ctorName,
      [for (final a in args) uniShift(a, depth)],
    ),
    TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
      uniShift(scrutinee, depth),
      motive == null ? null : uniShift(motive, depth),
      [
        for (final c in cases)
          TMatchCase(
            c.ctorName,
            c.nBinders,
            uniShift(c.body, depth + c.nBinders),
            c.binderNames,
            span: c.span,
          ),
      ],
    ),
    TQuot(:final carrier, :final relation) => TQuot(
      uniShift(carrier, depth),
      uniShift(relation, depth),
    ),
    TQuotMk(:final arg) => TQuotMk(uniShift(arg, depth)),
    TQuotLift(:final quot, :final fn, :final proof) => TQuotLift(
      uniShift(quot, depth),
      uniShift(fn, depth),
      uniShift(proof, depth),
    ),
    TProj(:final expr, :final fieldName) => TProj(
      uniShift(expr, depth),
      fieldName,
    ),
  };

  Term walk(Term t, int depth) => switch (t) {
    TBound(:final index) when index >= threshold + depth => TBound(
      index + shiftBy,
    ),
    TBound() => t,
    TType() ||
    TSProp() ||
    TProp() ||
    TFree() ||
    TTop() ||
    TRec() ||
    TMeta() => t,
    TApp(:final fn, :final arg) =>
      (() {
        final hs = _termHeadTMetaAndSpine(t);
        if (hs != null) {
          Term rebuilt = TMeta(hs.$1);
          for (final a in hs.$2) {
            rebuilt = TApp(rebuilt, uniShift(a, depth));
          }
          return rebuilt;
        }
        return TApp(walk(fn, depth), walk(arg, depth));
      })(),
    TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
      walk(domain, depth),
      walk(codomain, depth + 1),
      name: name,
      icit: icit,
    ),
    TLam(:final domain, :final body, :final name, :final icit) => TLam(
      walk(domain, depth),
      walk(body, depth + 1),
      name: name,
      icit: icit,
    ),
    TLet(:final domain, :final bound, :final body, :final name) => TLet(
      walk(domain, depth),
      walk(bound, depth),
      walk(body, depth + 1),
      name: name,
    ),
    TData(:final name, :final args) => TData(name, [
      for (final a in args) walk(a, depth),
    ]),
    TConstr(:final dataName, :final ctorName, :final args) => TConstr(
      dataName,
      ctorName,
      [for (final a in args) walk(a, depth)],
    ),
    TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
      walk(scrutinee, depth),
      motive == null ? null : walk(motive, depth),
      [
        for (final c in cases)
          TMatchCase(
            c.ctorName,
            c.nBinders,
            walk(c.body, depth + c.nBinders),
            c.binderNames,
            span: c.span,
          ),
      ],
    ),
    TQuot(:final carrier, :final relation) => TQuot(
      walk(carrier, depth),
      walk(relation, depth),
    ),
    TQuotMk(:final arg) => TQuotMk(walk(arg, depth)),
    TQuotLift(:final quot, :final fn, :final proof) => TQuotLift(
      walk(quot, depth),
      walk(fn, depth),
      walk(proof, depth),
    ),
    TProj(:final expr, :final fieldName) => TProj(walk(expr, depth), fieldName),
  };
  return walk(term, 0);
}

/// Walk [term] collecting every [TBound] index whose binder is within
/// the ctor-arg telescope (i.e. index < argCount) that appears as a
/// HEAD position in the resultIndex expression.
///
/// We conservatively treat any TBound reached by the walk as
/// "mentioned", more aggressive analysis (distinguishing head vs.
/// argument positions) would let in a few more singleton admissions
/// but is not needed for `Eq` or any stdlib inductive we target.
void _collectHeadBounds(Term term, Set<int> acc) {
  switch (term) {
    case TBound(:final index):
      acc.add(index);
    case TApp(:final fn, :final arg):
      _collectHeadBounds(fn, acc);
      _collectHeadBounds(arg, acc);
    case TConstr(:final args):
      for (final a in args) {
        _collectHeadBounds(a, acc);
      }
    case TData(:final args):
      for (final a in args) {
        _collectHeadBounds(a, acc);
      }
    // Other term shapes (TPi, TLam, TLet, TMatch, TType, TProp, TFree,
    // TTop, TRec) don't appear in a well-typed ctor resultIndex for
    // inductives. Conservative no-op on unsupported shapes.
    default:
      return;
  }
}

/// Compute the sort of a Pi type from its domain and codomain sorts,
/// per the PTS rules in SPEC §8.2.
///
///   cod = Prop                  => Pi : Prop     (impredicative Prop)
///   cod = Type m, dom = Prop    => Pi : Type m
///   cod = Type m, dom = Type n  => Pi : Type (max n m)
Value _piSort(_Sort domSort, _Sort codSort) {
  // Impredicative: codomain in Prop or SProp means Pi is in the same
  // impredicative sort, regardless of the domain's sort.
  if (codSort is _Prop) return const VProp();
  if (codSort is _SProp) return const VSProp();
  // Otherwise codSort is Type m.
  final codLevel = (codSort as _TypeN).level;
  // Domain contributes its level; Prop and SProp are treated as level
  // 0 here (Prop/SProp -> Type m) : Type m.
  final domLevel =
      (domSort is _Prop || domSort is _SProp) ? _l0 : (domSort as _TypeN).level;
  return VType(_normalizeLevel(LMax(domLevel, codLevel)));
}

// ---------------------------------------------------------------------------
// Inductive-type telescope helpers
// ---------------------------------------------------------------------------

/// Return the telescope entry at position [index] of the combined
/// telescope for an inductive-type inference.
///
/// For a TData head inference, the combined telescope is
/// `dataDecl.params ++ dataDecl.indices` (length
/// `params.length + indices.length`).
///
/// For a TConstr head inference, the combined telescope is
/// `dataDecl.params ++ ctorDecl.args` (length
/// `params.length + ctorDecl.args.length`).
///
/// In both cases the entries' types are closed under the telescope's
/// own preceding binders, which is exactly what eval expects when the
/// telescope is walked under an accumulating env.
TelescopeEntry _indexTelescope(
  DataDecl dataDecl,
  CtorDecl? ctorDecl,
  int index,
) {
  final paramsLen = dataDecl.params.length;
  if (index < paramsLen) return dataDecl.params[index];
  final after = index - paramsLen;
  if (ctorDecl == null) {
    return dataDecl.indices[after];
  }
  return ctorDecl.args[after];
}

/// Compute the next `_Step` for checking match arm at [armIndex].
///
/// Extends the ctx with the arm's binder types (for ctor arms) and
/// schedules `_Check(armCtx, body, expected)`, preceded by a
/// `_CheckMatchArm` frame that advances to the next arm once the
/// check finishes.
///
/// Ctor arg types are evaluated under a telescope env made of
/// `paramsV` (the scrutinee's type's params). Index refinement for
/// indexed families is applied by the match-checker, not here.
_Step _checkMatchArmStep(
  Ctx ctx,
  TMatch matchTerm,
  DataDecl dataDecl,
  List<Value> paramsV,
  List<Value> indicesV,
  int armIndex,
  Value expected,
  List<_Frame> stack,
) {
  final arm = matchTerm.cases[armIndex];
  stack.add(
    _CheckMatchArm(
      ctx: ctx,
      matchTerm: matchTerm,
      dataDecl: dataDecl,
      paramsV: paramsV,
      indicesV: indicesV,
      armIndex: armIndex,
      expected: expected,
    ),
  );
  if (arm.isWildcard) {
    // Wildcard arm: ctx unchanged; check body against expected.
    return _Check(ctx, arm.body, expected);
  }
  // Ctor arm: find the ctor, extend ctx with its arg types.
  CtorDecl? ctorDecl;
  for (final c in dataDecl.ctors) {
    if (c.name == arm.ctorName) {
      ctorDecl = c;
      break;
    }
  }
  if (ctorDecl == null) {
    // Elaborator should have rejected this via UnknownCtorInMatch.
    throw StateError(
      'match: arm ctor "${arm.ctorName}" not registered in '
      '${dataDecl.name}, elaborator invariant violation.',
    );
  }
  // Evaluate each arg's type under the telescope env. The telescope
  // env at arg[j] sees [params..., args[0], ..., args[j-1]]. Params
  // come from paramsV (already Values); prior args are fresh neutrals
  // placed at the caller's ctx levels since we're about to extend ctx
  // with them.
  var teleEnv = const ENil() as Env;
  // Inject params into teleEnv (innermost-first: params[p-1] at
  // TBound(0), params[0] at TBound(p-1)).
  for (var i = paramsV.length - 1; i >= 0; i--) {
    teleEnv = teleEnv.extend(paramsV[i]);
  }
  var armCtx = ctx;
  for (var j = 0; j < ctorDecl.args.length; j++) {
    final argTypeV = eval(ctorDecl.args[j].type, teleEnv);
    armCtx = armCtx.extend(argTypeV);
    // Extend teleEnv with a fresh neutral for this arg (the arg
    // binder is now in scope for subsequent arg types).
    teleEnv = teleEnv.extend(VNeutral(NVar(armCtx.level - 1)));
  }
  // Check whether this ctor arm is unreachable: if any
  // scrutinee-index / ctor-result-index pair has a telescope-
  // fresh neutral on one side and a VConstr on the other, the
  // arm can never fire.  In that case skip the body check;
  // the arm is dead code and any body is valid.
  var armReachable = true;
  if (indicesV.isNotEmpty && ctorDecl.resultIndices.isNotEmpty) {
    checkReach:
    for (
      var i = 0;
      i < ctorDecl.resultIndices.length && i < indicesV.length;
      i++
    ) {
      final ctorIdxV = eval(ctorDecl.resultIndices[i], teleEnv);
      if ((indicesV[i] is VConstr &&
              _isTelescopeNeutral(ctorIdxV, ctx.level)) ||
          (ctorIdxV is VConstr &&
              _isTelescopeNeutral(indicesV[i], ctx.level))) {
        armReachable = false;
        break checkReach;
      }
    }
  }
  if (!armReachable) {
    // Unreachable arm: body is dead code, yield expected.
    return _YieldV(expected);
  }

  // first-order index refinement.
  //
  // Compute the ctor's resultIndices as Values under teleEnv (which
  // now has paramsV + the ctor's arg neutrals at armCtx levels).
  // Walk pairs (scrutineeIndex, ctorResultIndex) first-order to
  // collect a level-keyed substitution on `expected`. When a
  // scrutinee index is an outer-bound neutral variable that the
  // ctor's resultIndex refines to something richer (or another
  // variable), record the refinement.
  //
  // Per SPEC §4.5 this is linear-time: pure structural walk +
  // substitution, no search. Matches the original
  // deferred design note at this site.
  final armExpected = _refineExpectedForArm(
    ctx: ctx,
    armCtx: armCtx,
    expected: expected,
    scrutineeIndicesV: indicesV,
    ctorResultIndexTerms: ctorDecl.resultIndices,
    teleEnv: teleEnv,
  );

  // Non-indexed data with a variable scrutinee: the elaborator
  // per-arm expected type substitutes the scrutinee variable with
  // the ctor result (e.g. `Acc Nat rel zero` for the `zero` arm
  // when matching on `n`). Do the same substitution here so the
  // checker agrees with the elaborator's per-arm type.
  var armExpectedFinal = armExpected;
  if (indicesV.isEmpty) {
    final scrutineeV = eval(matchTerm.scrutinee, ctx.env);
    if (scrutineeV is VNeutral && scrutineeV.neutral is NVar) {
      final scrutLevel = (scrutineeV.neutral as NVar).level;
      final ctorArgs = <Value>[
        for (var k = 0; k < arm.nBinders; k++)
          VNeutral(NVar(armCtx.level - arm.nBinders + k)),
      ];
      final ctorResultV = VConstr(dataDecl.name, arm.ctorName, ctorArgs);
      armExpectedFinal = substNVar(armExpected, scrutLevel, ctorResultV);
    }
  }
  return _Check(armCtx, arm.body, armExpectedFinal);
}

/// Public entry to the kernel's per-arm first-order index refinement.
///
/// The elaborator uses this to compute the refined expected type for an
/// indexed-family match arm, so the arm body can elaborate in CHECK mode
/// against the SAME refined type the kernel will demand at post-elab
/// check time (see `_refineExpectedForArm`). The elaborator must build
/// [armCtx] and [teleEnv] exactly as `_checkMatchArmStep` does, params
/// injected innermost-first, then one fresh neutral per ctor arg at the
/// extending ctx levels. Soundness does not rest on this: the kernel
/// re-runs the identical refinement when it checks the produced TMatch.
Value refineMatchArmExpected({
  required Ctx ctx,
  required Ctx armCtx,
  required Value expected,
  required List<Value> scrutineeIndicesV,
  required List<Term> ctorResultIndexTerms,
  required Env teleEnv,
}) => _refineExpectedForArm(
  ctx: ctx,
  armCtx: armCtx,
  expected: expected,
  scrutineeIndicesV: scrutineeIndicesV,
  ctorResultIndexTerms: ctorResultIndexTerms,
  teleEnv: teleEnv,
);

/// first-order index refinement for a match arm.
///
/// Produces a refined [Value] (`armExpected`) by walking the pairs
/// `(scrutineeIndicesV[i], ctorResultIndicesV[i])` and collecting
/// a substitution keyed by absolute level; then quote-subst-eval
/// applies the substitution to [expected].
///
/// Discipline: first-order. Each pair is compared head-structurally.
/// When a scrutinee index is a neutral NVar pointing at an outer
/// binder (level < ctx.level), the ctor's resultIndex provides the
/// refinement. Ctor heads must match (coverage enforces
/// reachability). Anything else is a no-op for that index position.
Value _refineExpectedForArm({
  required Ctx ctx,
  required Ctx armCtx,
  required Value expected,
  required List<Value> scrutineeIndicesV,
  required List<Term> ctorResultIndexTerms,
  required Env teleEnv,
}) {
  final ctorResultIndicesV = <Value>[
    for (final t in ctorResultIndexTerms) eval(t, teleEnv),
  ];
  final substMap = <int, Value>{};
  final pairs =
      scrutineeIndicesV.length < ctorResultIndicesV.length
          ? scrutineeIndicesV.length
          : ctorResultIndicesV.length;
  for (var i = 0; i < pairs; i++) {
    _firstOrderRefineV(
      scrutIdx: scrutineeIndicesV[i],
      ctorIdx: ctorResultIndicesV[i],
      outerLevel: ctx.level,
      substMap: substMap,
    );
  }
  if (substMap.isEmpty) return expected;
  // Quote expected at armCtx.level (it's already in armCtx scope,
  // since any outer-bound Value stays the same when viewed from a
  // deeper Ctx, only the de-Bruijn indices in the quoted term
  // differ). Then apply the substitution on TBound references
  // corresponding to refined levels.
  final expectedT = quote(armCtx.level, expected);
  final substitutedT = _substByLevel(expectedT, substMap, armCtx);
  return eval(substitutedT, armCtx.env);
}

/// Walk a (scrutIdx, ctorIdx) pair first-order; record refinements.
void _firstOrderRefineV({
  required Value scrutIdx,
  required Value ctorIdx,
  required int outerLevel,
  required Map<int, Value> substMap,
}) {
  // Case 1: scrutIdx is an outer-bound neutral NVar.
  if (scrutIdx is VNeutral && scrutIdx.neutral is NVar) {
    final nvar = scrutIdx.neutral as NVar;
    if (nvar.level < outerLevel) {
      substMap.putIfAbsent(nvar.level, () => ctorIdx);
    }
    return;
  }
  // Case 2: both VConstr, same ctor, descend pairwise.
  if (scrutIdx is VConstr && ctorIdx is VConstr) {
    if (scrutIdx.dataName != ctorIdx.dataName ||
        scrutIdx.ctorName != ctorIdx.ctorName ||
        scrutIdx.args.length != ctorIdx.args.length) {
      return;
    }
    for (var i = 0; i < scrutIdx.args.length; i++) {
      _firstOrderRefineV(
        scrutIdx: scrutIdx.args[i],
        ctorIdx: ctorIdx.args[i],
        outerLevel: outerLevel,
        substMap: substMap,
      );
    }
    return;
  }
  // Case 3: both VData, same name, descend pairwise.
  if (scrutIdx is VData && ctorIdx is VData) {
    if (scrutIdx.name != ctorIdx.name ||
        scrutIdx.args.length != ctorIdx.args.length) {
      return;
    }
    for (var i = 0; i < scrutIdx.args.length; i++) {
      _firstOrderRefineV(
        scrutIdx: scrutIdx.args[i],
        ctorIdx: ctorIdx.args[i],
        outerLevel: outerLevel,
        substMap: substMap,
      );
    }
    return;
  }
  // Case 4: otherwise, first-order refinement can't help.
}

/// Apply a level-keyed substitution to [term]. [term] is valid in a
/// scope of [ctx.level]. A TBound(k) at depth `d` refers to absolute
/// level `ctx.level - 1 - (k - d)` when k >= d (free); otherwise
/// it's a binder introduced inside [term]. If the free reference's
/// absolute level is in [substMap], replace with the solution's
/// Term form (quoted at ctx.level, then shifted by d).
Term _substByLevel(Term term, Map<int, Value> substMap, Ctx ctx) {
  if (substMap.isEmpty) return term;
  Term walk(Term t, int depth) => switch (t) {
    TBound(:final index) when index >= depth => () {
      final absoluteLevel = ctx.level - 1 - (index - depth);
      final solution = substMap[absoluteLevel];
      if (solution == null) return t;
      final solutionT = quote(ctx.level, solution);
      return _shiftTBoundPastThreshold(solutionT, threshold: 0, shiftBy: depth);
    }(),
    TBound() => t,
    TType() ||
    TSProp() ||
    TProp() ||
    TFree() ||
    TTop() ||
    TRec() ||
    TMeta() => t,
    TApp(:final fn, :final arg) => TApp(walk(fn, depth), walk(arg, depth)),
    TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
      walk(domain, depth),
      walk(codomain, depth + 1),
      name: name,
      icit: icit,
    ),
    TLam(:final domain, :final body, :final name, :final icit) => TLam(
      walk(domain, depth),
      walk(body, depth + 1),
      name: name,
      icit: icit,
    ),
    TLet(:final domain, :final bound, :final body, :final name) => TLet(
      walk(domain, depth),
      walk(bound, depth),
      walk(body, depth + 1),
      name: name,
    ),
    TData(:final name, :final args) => TData(name, [
      for (final a in args) walk(a, depth),
    ]),
    TConstr(:final dataName, :final ctorName, :final args) => TConstr(
      dataName,
      ctorName,
      [for (final a in args) walk(a, depth)],
    ),
    TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
      walk(scrutinee, depth),
      motive == null ? null : walk(motive, depth),
      [
        for (final c in cases)
          TMatchCase(
            c.ctorName,
            c.nBinders,
            walk(c.body, depth + c.nBinders),
            c.binderNames,
            span: c.span,
          ),
      ],
    ),
    TQuot(:final carrier, :final relation) => TQuot(
      walk(carrier, depth),
      walk(relation, depth),
    ),
    TQuotMk(:final arg) => TQuotMk(walk(arg, depth)),
    TQuotLift(:final quot, :final fn, :final proof) => TQuotLift(
      walk(quot, depth),
      walk(fn, depth),
      walk(proof, depth),
    ),
    TProj(:final expr, :final fieldName) => TProj(walk(expr, depth), fieldName),
  };
  return walk(term, 0);
}

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
    // Registry invariant: ctor.resultIndices has the same length as
    // dataDecl.indices, which equals scrutineeIndices (they come
    // from VData.args's index portion). Fall through conservatively.
    return true;
  }
  // Build a telescope env: innermost-first, so params[paramCount-1]
  // lands at TBound(0). Then push fresh neutrals for the ctor's own
  // args at levels starting from the current `level` so lookups
  // within the ctor's resultIndices produce valid neutral values.
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
  // A constructor cannot match a telescope-fresh neutral: the
  // neutral was created for an opaque ctor argument and is never
  // instantiated.  Scrutinee neutrals (levels < outerLevel) are
  // rigid variables that could in principle be equal.
  if (a is VConstr && _isTelescopeNeutral(b, outerLevel)) return false;
  if (b is VConstr && _isTelescopeNeutral(a, outerLevel)) return false;
  // Any other shape: neutrals, stuck forms, mismatched kinds, the
  // first-order check gives up and returns POSSIBLE. Pattern
  // unification handles the refined cases.
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

/// Look up the parameter count for inductive [dataName] in [env]'s
/// registry. Kernel invariant: the elaborator only emits a
/// [VConstr] whose [dataName] is a registered inductive.
int _dataParamCount(Env env, String dataName) {
  final d = env.lookupData(dataName);
  if (d == null) {
    throw StateError(
      'match: scrutinee VConstr(dataName=$dataName) references an '
      'unregistered inductive. Kernel invariant violation.',
    );
  }
  return d.params.length;
}

/// True if [type] is a syntactic recursive occurrence of the inductive
/// [dataName]: i.e. the head of the type (after peeling Pi) is
/// `TData(dataName, ...)`.
///
/// Used by ι-reduction to decide, for each ctor arg, whether to
/// produce a recursive-call value after it. This is a conservative
/// head-check: an arg type whose outer shape is `Vec[A] n` matches;
/// `Nat -> Vec[A] n` (Pi) also matches after peeling, but that's an
/// arrow shape we reject during positivity checking anyway, so this
/// simpler check suffices here.
bool _isRecursiveOccurrence(String dataName, Term type) {
  var t = type;
  while (t is TPi) {
    t = t.codomain;
  }
  return t is TData && t.name == dataName;
}

/// True iff [dataDecl] is a record: single constructor, non-recursive,
/// no indices.
bool _isRecordData(DataDecl dataDecl) =>
    dataDecl.ctors.length == 1 && dataDecl.indices.isEmpty;

/// Look up a [DataDecl] by [name] in [dataDecls].
DataDecl? _lookupData(String name, List<DataDecl>? dataDecls) {
  if (dataDecls == null) return null;
  for (final d in dataDecls) {
    if (d.name == name) return d;
  }
  return null;
}

/// Extract field [fieldName] from a [VConstr] by looking up the field
/// index in the constructor's args.
Value _projectField(VConstr v, String fieldName, List<DataDecl>? dataDecls) {
  final dDecl = _lookupData(v.dataName, dataDecls);
  if (dDecl == null || dDecl.ctors.isEmpty) {
    throw StateError(
      'projectField: VConstr(${v.dataName}) has no matching DataDecl.',
    );
  }
  final ctor = dDecl.ctors.first;
  final paramCount = dDecl.params.length;
  for (var i = 0; i < ctor.args.length; i++) {
    if (ctor.args[i].name == fieldName) {
      return v.args[paramCount + i];
    }
  }
  throw StateError(
    'projectField: VConstr(${v.dataName}.${v.ctorName}) '
    'has no field named $fieldName.',
  );
}

/// Synthesize the kernel [Term] representing the recursor's type for
/// inductive [d].
///
/// The formula (dependent eliminator, CIC standard):
///
/// ```
/// T.rec : forall (params...) ,
///         forall (P : (indices...) -> T[params] indices... -> Sort) ,
///         (for each ctor C with args (a1: A1, ..., ak: Ak) producing
///          T[params] resultIndices...:
///           (a1: A1) -> ... -> (ak: Ak) ->
///             (for each recursive arg ai: P (sub-indices) ai ->) ...
///             P resultIndices (C params args))
///         -> forall (indices...) , forall (t: T[params] indices...) ,
///         P indices t
/// ```
///
/// For non-indexed inductives (List, Nat), the indices block is empty.
/// For Vec, there is one index `n: Nat`, and the motive takes both
/// the index and the scrutinee.
///
/// The synthesized Term is closed (no TFree) and uses TBound to
/// reference params, methods, indices, and scrutinee positionally.
/// This matches the existing telescope-building conventions in
/// elab.dart (`_buildFunType`).
///
/// Non-indexed cases are fully correct. Indexed cases
/// (Vec and friends) are correct for the simple uniform pattern where
/// every ctor's `resultIndices` contains only TBound references to
/// ctor args. The general case (arbitrary index expressions) is
/// deferred, positivity already ensures nothing pathological, but
/// fully-general motive-building remains an extension.
/// Synthesize the recursor's type as a closed kernel term.
///
/// When [motiveSort] is provided, it overrides the motive's target
/// sort. Default is `d.sort` (the data's declared sort, giving the
/// standard recursor). Supplying `TType(n)` produces a *large-
/// elimination* variant, valid only when [d] admits SPEC §8.2
/// singleton elimination, the elab site auto-emits these as
/// `T.rect` bindings alongside the default `T.rec`.
///
/// v2's multi-recursor approach (Coq-historical `eq_ind`/`eq_rect`
/// pattern): without universe polymorphism (v3), a sort-polymorphic
/// recursor can't be expressed as a single typed term, so we emit
/// one per motive sort we need. v3's universe poly collapses the
/// pair into a single sort-polymorphic recursor.
Term synthRecursorType(DataDecl d, {Term? motiveSort}) {
  // Quick escape for the simplest case (Nat-like: no params, no indices).
  // We build the full formula bottom-up. The algorithm:
  //
  // 1. Start with the motive-application `P indices... t` as the result
  //    type. Since we're at the innermost point, indices are TBound
  //    pointing at the index binders, and `t` is the scrutinee.
  // 2. Wrap with Pi for the scrutinee: `(t: T[params] indices...) -> ...`.
  // 3. Wrap with Pi for each index (outermost-first... no, innermost-
  //    first when unwinding): actually iterate innermost to outermost.
  // 4. Wrap with Pi for each method, in reverse order.
  // 5. Wrap with Pi for the motive.
  // 6. Wrap with Pi for each param in reverse.
  //
  // At each wrap, de Bruijn indices on the inner term are already
  // correct because we built inside-out.

  // The inner-most reference shapes:
  //   At the innermost position, the bound variables (innermost-first) are:
  //     scrutinee @ depth 0
  //     method_{last} @ depth 1
  //     ...
  //     method_0 @ depth ctors.length
  //     index_{last} @ depth ctors.length + 1
  //     ...
  //     index_0 @ depth ctors.length + indices.length
  //     motive @ depth ctors.length + indices.length + 1 (= depth of motive)
  //     param_{last} @ depth ctors.length + indices.length + 2
  //     ...
  //     param_0 @ depth ctors.length + indices.length + 1 + params.length
  //
  // Building the innermost result: P applied to indices (TBound 1..indices.length)
  // applied to scrutinee (TBound 0).

  final paramCount = d.params.length;
  final indexCount = d.indices.length;
  final ctorCount = d.ctors.length;

  // Step 1: motive-applied-to-all-indices-and-scrutinee at the inner-
  // most point.
  // motive depth from innermost = ctors.length + indices.length + 1
  final motiveDepthInner = ctorCount + indexCount + 1;
  Term result = TBound(motiveDepthInner);
  // Apply to each index (outermost-first-in-result).
  // At the innermost point, index_0 is at depth ctorCount + indices.length
  // (furthest), index_{last} is at depth ctorCount + 1.
  for (var k = 0; k < indexCount; k++) {
    // index_k is at depth ctorCount + (indices.length - k) from the
    // innermost binder (the scrutinee at depth 0).
    result = TApp(result, TBound(ctorCount + indexCount - k));
  }
  // Apply to scrutinee.
  result = TApp(result, const TBound(0));

  // Step 2: Pi-wrap for the scrutinee. Its type is T[params] indices...
  // At the point where we wrap this Pi, we're one level outer than
  // the current `result`, so all TBound references in the scrutinee's
  // type must be shifted by "the number of binders between us and
  // them." Specifically: the scrutinee's type is built at a point
  // where the `result` has not yet been wrapped, so references from
  // the scrutinee type downward see the same outer binders but not
  // the scrutinee itself.
  //
  // Scrutinee type: TData(d.name, [param_0, ..., param_{pc-1},
  //                                index_0, ..., index_{ic-1}])
  // At the pre-scrutinee-wrap depth:
  //   methods (ctorCount) are between scrutinee and indices
  //   index_{last} @ ctorCount (innermost index, just outside methods)
  //   index_0 @ ctorCount + ic - 1 (outermost index)
  //   motive @ ctorCount + ic
  //   param_{last} @ ctorCount + ic + 1
  //   param_0 @ ctorCount + ic + paramCount
  final scrutTypeDataArgs = <Term>[];
  // Params:
  for (var i = 0; i < paramCount; i++) {
    scrutTypeDataArgs.add(
      TBound(ctorCount + indexCount + 1 + paramCount - 1 - i),
    );
  }
  // Indices:
  for (var j = 0; j < indexCount; j++) {
    scrutTypeDataArgs.add(TBound(ctorCount + indexCount - 1 - j));
  }
  final scrutType = TData(d.name, scrutTypeDataArgs);
  result = TPi(scrutType, result, name: null);

  // Step 3: Wrap with Pi for each method, in reverse ctor order.
  // Methods now sit INSIDE indices (indices wrap outside methods).
  // Each method's type is computed from the ctor's telescope (after
  // params) plus a final motive-application for the resulting ctor
  // instance.
  //
  // The method for ctor C_i has type:
  //   (a_1 : A_1) -> ... -> (a_k : A_k) ->
  //     (for each recursive a_j: P resultIndices-of-subarg a_j ->) ...
  //     P resultIndices (C_i params args)
  //
  // For non-indexed / simple-indexed families, the recursive-
  // arg wrapping inside each method works out of the simple formula
  // above because resultIndices only reference the scrutinee's own
  // args.
  //
  // Building each method: inside-out again, from the final motive-app
  // back out through each ctor arg, wrapping recursive-arg IH
  // hypotheses as we go.
  //
  // To avoid drowning here, we support a simplified form: we
  // include each method as "it takes the ctor's non-param args, and
  // for each recursive arg adds one IH arg, then returns P applied
  // to the scrutinee." This is the standard dependent eliminator
  // for strictly-positive inductives.
  for (var i = ctorCount - 1; i >= 0; i--) {
    final methodType = _synthMethodType(d, i);
    result = TPi(methodType, result, name: null);
  }

  // Step 4: Wrap with Pi for each index, innermost-first (so the
  // outermost wrap lands on index_0). Indices wrap OUTSIDE methods.
  // Each index's type was elaborated under the data's telescope
  // [params ++ prior-indices], ordered innermost-first. In that scope,
  // `TBound(j)` for
  //   * j < k: refers to prior index `index_{k-1-j}`.
  //   * j >= k: refers to param `param_{paramCount - 1 - (j - k)}`.
  //
  // In the recursor's scope, at the point of wrapping index_k's Pi:
  //   * prior indices (index_0..index_{k-1}) stay at their original
  //     depths (0 .. k-1 from this wrap point, innermost-first)
  //     no shift.
  //   * params are further out: remaining indices (k more wraps), then
  //     motive (1). So the param at original depth k lands at recursor
  //     depth k + 1, i.e. shifted by 1 (the motive).
  //
  // This shift is load-bearing whenever an index type is itself a
  // TBound referring to a param (e.g. the prelude's Eq, whose index
  // type `A` refers to param A): without it the index's TBound points
  // at whatever binder sits at the pre-shift depth, so Eq.rec's
  // synthesized type is ill-formed and the derived library (sym,
  // trans, cong, subst) cannot be checked.
  for (var k = indexCount - 1; k >= 0; k--) {
    final shifted = _shiftTBoundPastThreshold(
      d.indices[k].type,
      threshold: k,
      shiftBy: 1,
    );
    result = TPi(shifted, result, name: d.indices[k].name);
  }

  // Step 5: Wrap with Pi for the motive.
  // Motive type: (indices...) -> T[params] indices... -> Sort
  // Built in its own context where params are in scope but
  // methods/indices/scrutinee are not.
  //
  // [motiveSort] overrides the default `d.sort`; when non-null the
  // caller is building a large-elimination variant (see
  // `synthRecursorType`'s doc, only valid for singleton-elim-
  // admitting Prop inductives).
  final motiveType = _synthMotiveType(d, motiveSort: motiveSort);
  result = TPi(motiveType, result, name: 'P');

  // Step 6: Wrap with Pi for each param, in reverse order.
  for (var i = paramCount - 1; i >= 0; i--) {
    result = TPi(d.params[i].type, result, name: d.params[i].name);
  }

  return result;
}

/// Build the motive's type: `(indices...) -> T[params] indices... -> Sort`.
///
/// Constructed under a scope where only the data's params are bound.
Term _synthMotiveType(DataDecl d, {Term? motiveSort}) {
  final paramCount = d.params.length;
  final indexCount = d.indices.length;

  // Innermost: Sort. Defaults to d.sort; caller supplies an override
  // only for large-elim variants.
  Term result = motiveSort ?? d.sort;

  // Wrap: (t : T[params] indices...) -> Sort.
  // At this point, indices are wrapped (TBound 0..indexCount-1) and
  // params are at depth indexCount+1..indexCount+paramCount.
  final dataArgs = <Term>[];
  for (var i = 0; i < paramCount; i++) {
    dataArgs.add(TBound(indexCount + paramCount - 1 - i));
  }
  for (var j = 0; j < indexCount; j++) {
    dataArgs.add(TBound(indexCount - 1 - j));
  }
  result = TPi(TData(d.name, dataArgs), result, name: null);

  // Wrap indices, innermost-first.
  for (var k = indexCount - 1; k >= 0; k--) {
    result = TPi(d.indices[k].type, result, name: d.indices[k].name);
  }

  return result;
}

/// Build the method type for ctor index [ctorIndex] of inductive [d].
///
/// Under a scope where only params and motive are bound (motive
/// innermost), produces:
///
/// ```
/// (a_1 : A_1) -> ... -> (a_k : A_k) ->
///   (IH_i_1 : P sub-indices(a_i_1) a_i_1) ->
///   ...
///   (IH_i_m : P sub-indices(a_i_m) a_i_m) ->
///   P ctor.resultIndices (C params args)
/// ```
///
/// where `i_1..i_m` are the positions of the recursive args. IHs are
/// grouped **after** all ctor args (not interleaved), and each IH is
/// a Pi whose DOMAIN is `P ... a_i`, i.e. the IH is a value of type
/// `P ... a_i`, not a function taking another copy of `a_i`.
///
/// Built inside-out, tracking de Bruijn depth manually at each wrap.
///
/// Correct for all SPEC §8.4 examples (Nat, List, Vec).
/// Assumptions:
///  * Each recursive arg's type is `TData(d.name, paramRefs ++ indexRefs)`
///    directly (no arrow wrapping). Positivity guarantees this.
///  * `ctor.resultIndices` reference only ctor-arg de Bruijn indices
///    (0..argCount-1), not params. Holds for all current examples.
Term _synthMethodType(DataDecl d, int ctorIndex) {
  final ctor = d.ctors[ctorIndex];
  final paramCount = d.params.length;
  final indexCount = d.indices.length;
  final argCount = ctor.args.length;

  // Track which ctor-arg positions are recursive.
  final recursivePositions = <int>[];
  for (var j = 0; j < argCount; j++) {
    if (_isRecursiveOccurrence(d.name, ctor.args[j].type)) {
      recursivePositions.add(j);
    }
  }
  final ihCount = recursivePositions.length;

  // Layout at the innermost point (depth 0 = innermost):
  //   IH_{last recursive} @ 0
  //   IH_{second-to-last} @ 1
  //   ...
  //   IH_{first recursive} @ ihCount - 1
  //   a_{k-1} @ ihCount
  //   a_{k-2} @ ihCount + 1
  //   ...
  //   a_0 @ ihCount + argCount - 1
  //   prior methods (for ctors 0..ctorIndex-1) @ ihCount + argCount ..
  //                                              ihCount + argCount + ctorIndex - 1
  //   index_{last} @ ihCount + argCount + ctorIndex
  //   ...
  //   index_0 @ ihCount + argCount + ctorIndex + indexCount - 1
  //   motive @ ihCount + argCount + ctorIndex + indexCount
  //   param_{p-1} @ ihCount + argCount + ctorIndex + indexCount + 1
  //   ...
  //   param_0 @ ihCount + argCount + ctorIndex + indexCount + paramCount
  //
  // The `ctorIndex` offset is load-bearing: when synthRecursorType
  // wraps methods outer-to-inner (method 0 outermost, method n-1
  // innermost), the method for ctor i has (ctorIndex = i) prior
  // methods already wrapped *outside* it. From the inside of method i,
  // those prior methods sit between the ctor args and the indices, so
  // omitting the offset aliases the motive with the wrong binder and
  // produces an ill-formed type (failing both checking and
  // ι-reduction).

  // Depth of ctor arg j at the innermost point:
  //   a_j @ ihCount + (argCount - 1 - j)
  int argDepthAtInner(int j) => ihCount + (argCount - 1 - j);
  final motiveDepthAtInner = ihCount + argCount + ctorIndex + indexCount;
  int paramDepthAtInner(int i) =>
      ihCount + argCount + ctorIndex + indexCount + 1 + (paramCount - 1 - i);

  // Remap a Term `t` that was elaborated under (params ++ indices ++
  // ctor.args) so TBound(k) for k < argCount refers to ctor arg
  // (argCount - 1 - k), for argCount <= k < argCount + indexCount
  // refers to index (indexCount - 1 - (k - argCount)), and for
  // k >= argCount + indexCount refers to param (k - argCount - indexCount).
  //
  // At the *innermost method point*, remap these to the method's
  // depths.
  Term remapAtInner(Term t) => switch (t) {
    TBound(:final index) when index < argCount => TBound(
      argDepthAtInner(argCount - 1 - index),
    ),
    TBound(:final index) when index < argCount + indexCount => TBound(
      ihCount + argCount + ctorIndex + (index - argCount),
    ),
    TBound(:final index) => TBound(
      paramDepthAtInner(paramCount - 1 - (index - argCount - indexCount)),
    ),
    TType() ||
    TSProp() ||
    TProp() ||
    TFree() ||
    TBound() ||
    TTop() ||
    TMeta() => t,
    TApp(:final fn, :final arg) => TApp(remapAtInner(fn), remapAtInner(arg)),
    TLam() || TPi() || TLet() => t,
    TData(:final name, :final args) => TData(name, [
      for (final a in args) remapAtInner(a),
    ]),
    TConstr(:final dataName, :final ctorName, :final args) => TConstr(
      dataName,
      ctorName,
      [for (final a in args) remapAtInner(a)],
    ),
    TRec() => t,
    TQuot() => t,
    TQuotMk() => t,
    TQuotLift() => t,
    // TMatch in a ctor arg/result-index type is not meaningful for
    // recursor synthesis, ctor signatures are types, not terms.
    // A well-typed ctor can't contain a TMatch inside its signature
    // (match is term-level), so this path is unreachable at runtime.
    // Kept exhaustive so the compiler stays green.
    TMatch() => t,
    TProj() => t,
  };

  // Build the innermost expression: P ctor.resultIndices (C params args).
  Term inner = TBound(motiveDepthAtInner);
  for (final idx in ctor.resultIndices) {
    inner = TApp(inner, remapAtInner(idx));
  }
  final ctorInstanceArgs = <Term>[
    for (var i = 0; i < paramCount; i++) TBound(paramDepthAtInner(i)),
    for (var j = 0; j < argCount; j++) TBound(argDepthAtInner(j)),
  ];
  inner = TApp(inner, TConstr(d.name, ctor.name, ctorInstanceArgs));

  // Wrap IHs from innermost outward. The innermost-wrapped IH
  // corresponds to the LAST recursive position (recursivePositions.last).
  // As we wrap each outer IH, depth-from-innermost of existing binders
  // shifts: each outer wrap adds 1 to the effective depth seen by the
  // inner-body. So when wrapping IH_m (m counted outward from
  // innermost, so the outermost IH is IH_{ihCount - 1}), the body at
  // that point has had (m) IHs wrapped under it already.
  //
  // To build the IH's TYPE (which references the recursive arg's
  // index-level args and the arg itself), we compute the references
  // AT THE POINT where the IH Pi's domain is being built, one binder
  // *outside* the next-innermost IH (if any). The invariant:
  // the IH's domain sees binders starting just below "where the IH
  // pi will sit", which corresponds to: all more-innermost IHs NOT
  // yet in scope. So for the m-th outward IH:
  //   - motive is at depth (ihCount - 1 - m) + argCount = argCount + ihCount - 1 - m
  //     Wait. Let me re-derive.
  //
  // At the moment we're building IH_m's type (to be wrapped as Pi):
  //   Already-in-scope (innermost-first): IH_{m-1 outward} at 0, ...,
  //     IH_0-outward at m-1. So m IHs already exist inside.
  //   After those: a_{k-1} at m, ..., a_0 at m + argCount - 1.
  //   Motive at m + argCount.
  //   Params at m + argCount + 1 ... m + argCount + paramCount.
  //
  // Actually a problem: when we build IH_m's DOMAIN (a type), the
  // binders visible to that type-term start FROM the current point,
  // so the "innermost-first" enumeration above is what we want.
  //
  // Let buildIHDomainAtPos(m) return the type `P sub-indices(a_j) a_j`
  // when a_j is the j-th ctor arg and IH_m (the m-th outward IH)
  // corresponds to the (ihCount - 1 - m)-th entry of recursivePositions.

  Term buildIHDomain(int mOutward) {
    // Which ctor-arg position does this IH correspond to?
    // IH_m outward corresponds to recursivePositions[ihCount - 1 - mOutward].
    // The innermost-wrapped IH (m=0 outward) matches the LAST
    // recursive position.
    final posIdx = recursivePositions[ihCount - 1 - mOutward];
    final argType = ctor.args[posIdx].type;

    // At the point where we build this IH's DOMAIN: the domain lives
    // in the OUTER context of the Pi we're about to wrap. In the
    // FINAL term, the outer-IH Pis sit *outside* this one, and the
    // inner-IH Pis sit inside. So the domain's de Bruijn context
    // (innermost-first) looks like:
    //
    //   outer IH binders (ihCount - 1 - mOutward of them, innermost),
    //   then a_{k-1} .. a_0,
    //   then prior-ctor method binders (ctorIndex of them),
    //   then index binders (indexCount of them),
    //   then motive,
    //   then params (paramCount of them, outermost).
    //
    // The outer-IH binders aren't referenced by this domain, but they
    // DO occupy slots 0..(outerCount-1), so motive / arg / param depths
    // all shift up by `outerCount = ihCount - 1 - mOutward` (the count
    // of OUTER IHs only, not inner ones). This shift is identically
    // zero for ctors with a single recursive arg (Nat.succ, List.cons,
    // Vec.vcons), so any error here stays invisible until a ctor has
    // ≥ 2 recursive args (Tree.node, Forest.fcons): test those.
    final outerCount = ihCount - 1 - mOutward;
    int argDepth(int j) => outerCount + (argCount - 1 - j);
    final motiveDepth = outerCount + argCount + ctorIndex + indexCount;
    int paramDepth(int i) =>
        outerCount +
        argCount +
        ctorIndex +
        indexCount +
        1 +
        (paramCount - 1 - i);

    // `argType` was elaborated at the point *before* ctor.args[posIdx]
    // was pushed, i.e. under scope `[ctor.args[posIdx-1], ...,
    // ctor.args[0], params...]`. Within argType, elab-TBound(index):
    //   - index < posIdx: ctor.args[posIdx - 1 - index]
    //   - index >= posIdx: param_{paramCount - 1 - (index - posIdx)}
    Term remapArgType(Term t) => switch (t) {
      TBound(:final index) when index < posIdx => TBound(
        argDepth(posIdx - 1 - index),
      ),
      TBound(:final index) => TBound(
        paramDepth(paramCount - 1 - (index - posIdx)),
      ),
      TType() ||
      TSProp() ||
      TProp() ||
      TFree() ||
      TBound() ||
      TTop() ||
      TMeta() => t,
      TApp(:final fn, :final arg) => TApp(remapArgType(fn), remapArgType(arg)),
      TLam() || TPi() || TLet() => t,
      TData(:final name, :final args) => TData(name, [
        for (final a in args) remapArgType(a),
      ]),
      TConstr(:final dataName, :final ctorName, :final args) => TConstr(
        dataName,
        ctorName,
        [for (final a in args) remapArgType(a)],
      ),
      TRec() => t,
      TQuot() => t,
      TQuotMk() => t,
      TQuotLift() => t,
      // Ctor signatures are types; TMatch is term-level and does
      // not appear inside them under any well-typed shape.
      TMatch() => t,
      TProj() => t,
    };

    // IH domain = P <sub-indices of a_posIdx> a_posIdx.
    // sub-indices come from argType (must be TData(d.name, ...) per
    // positivity). The first `paramCount` entries of its args are the
    // data's params; the remaining `indexCount` are the sub-indices.
    Term ihType = TBound(motiveDepth);
    if (argType is TData) {
      for (var k = 0; k < indexCount; k++) {
        ihType = TApp(ihType, remapArgType(argType.args[paramCount + k]));
      }
    }
    ihType = TApp(ihType, TBound(argDepth(posIdx)));
    return ihType;
  }

  // Start with `inner`. Wrap IHs innermost-first (m=0 is innermost
  // IH), which corresponds to iterating mOutward = 0 .. ihCount-1.
  Term result = inner;
  for (var mOutward = 0; mOutward < ihCount; mOutward++) {
    final ihDom = buildIHDomain(mOutward);
    result = TPi(ihDom, result, name: null);
  }

  // Now wrap the ctor args. Innermost ctor arg is a_{argCount-1},
  // outermost is a_0. Each arg's type was elaborated under
  // (params ++ prior ctor args), which matches the method's layout
  // at that wrap point:
  //   At the wrap of arg j (going outer), depth from innermost (the
  //   current result) is: argCount - 1 - j already-wrapped args + 0
  //   IHs (IHs live inside the innermost region, not outside the
  //   args). Plus param binders outside.
  //
  // Check: arg j's type was elaborated with TBound(0) meaning "the
  // innermost binder at that point," which is `a_{j-1}` (the previous
  // ctor arg) in the original scope. At our wrap point, `a_{j-1}` is
  // indeed at depth 0 (innermost), because we've already wrapped
  // `a_{j+1} .. a_{argCount-1}` as MORE INNER Pis, no wait, we're
  // wrapping outer to inner by iterating j from argCount-1 down.
  // After wrapping a_{argCount-1} innermost, THEN a_{argCount-2}
  // outer, at that outer wrap point `a_{argCount-2}` sees the
  // already-wrapped stuff inside (which includes a_{argCount-1}, the
  // IHs, and `inner`). No wait, a_{argCount-2}'s type itself was
  // elaborated BEFORE a_{argCount-1} existed, so a_{argCount-2}'s
  // type only references earlier binders.
  //
  // The correct statement: arg j's type references `TBound(k)` where
  // k < j means "prior ctor arg" and k >= j refers to params. At the
  // wrap point for arg j (when it's about to be wrapped as the new
  // outer Pi), arg j+1..argCount-1 are inside, IHs are inside, inner
  // is inside. So the "depth-0 binder" at this wrap point is arg j+1
  // if we've wrapped arg j+1 already, etc.
  //
  // But arg j's type doesn't REFERENCE arg j+1, that arg doesn't
  // exist yet in its elaboration scope. So it's fine.
  //
  // What arg j's type DOES reference: arg 0..j-1 and params. At the
  // wrap point for arg j:
  //   - arg j+1..argCount-1 already wrapped inside; total of
  //     (argCount - 1 - j) binders.
  //   - IHs wrapped inside after those args; ihCount binders.
  //   - inner sits innermost.
  //   Total binders between this wrap point and the original elab
  //   scope of arg j: (argCount - 1 - j) + ihCount.
  //
  // But wait, arg j's type doesn't see any of that; it was
  // elaborated under just (params ++ arg 0..j-1). At the wrap point,
  // the binders visible to the Pi-wrapping mechanism are whatever
  // we've placed so far. To write a TBound that references arg i
  // (i < j), we need the de Bruijn depth of arg i in the RESULT
  // scope at the wrap point.
  //
  // Actually, we don't need to remap arg j's type at all, because
  // it's being introduced as a NEW binder whose domain we provide
  // as-is. The domain's TBound references are relative to ITS OWN
  // context (the outside, where prior args and params are bound).
  // If the outside context matches what the type was elaborated
  // under, no shift is needed.
  //
  // The outside context when wrapping arg j:
  //   Innermost: arg j-1 (if any), arg j-2, ..., arg 0, motive,
  //   params... Exactly matching the elaboration scope of arg j's
  //   type (well, plus motive and param-vs-param-indexed, motive is
  //   innermost among the outside's binders above arg 0).
  //
  // Wait. The elaboration scope of arg j's type is (params ++ args 0..j-1),
  // ordered innermost-first as: arg j-1, arg j-2, ..., arg 0,
  // param_{p-1}, ..., param_0.
  //
  // At the wrap point for arg j, our OUTSIDE scope is actually:
  // motive (just introduced from the outside's perspective, will be
  // further wrapped later)... no, we haven't wrapped motive yet
  // motive is wrapped in synthRecursorType AFTER all methods are
  // built. So at the wrap point for arg j, the outside context from
  // the method's perspective has:
  //   motive, param_{p-1}, ..., param_0.
  //
  // Hmm, actually the outside context for the whole method-building
  // operation is: params bound outermost, motive innermost-of-outside.
  // Then the method itself starts wrapping args (outermost arg = arg 0,
  // innermost arg = arg argCount-1). Then inside the innermost arg,
  // IHs are wrapped. Then `inner` sits inside everything.
  //
  // So at the arg j wrap point, the OUTSIDE context (innermost-first)
  // is:
  //   arg j-1 @ 0
  //   arg j-2 @ 1
  //   ...
  //   arg 0 @ j-1
  //   motive @ j
  //   param_{p-1} @ j+1
  //   ...
  //   param_0 @ j+paramCount
  //
  // The elaboration scope of arg j's type (original) was:
  //   arg j-1 @ 0
  //   ...
  //   arg 0 @ j-1
  //   param_{p-1} @ j
  //   ...
  //   param_0 @ j+paramCount-1
  //
  // The difference: the recursor's method context has MOTIVE inserted
  // between args and params. So arg j's type's TBound(k) references:
  //   - k < j (ctor arg): same depth in both → no shift.
  //   - k >= j (param): original depth k. New depth: k + 1 (one more
  //     for the motive).
  //
  // So yes, shift by 1 the TBound references to params.

  // The ctor-arg's type was elaborated under (params ++ prior ctor args).
  // In the recursor method's scope, prior ctor args are at the same
  // positions (unchanged), but params are pushed DOWN by the binders
  // inserted between: motive (1) + prior methods (ctorIndex) + indices
  // (indexCount).
  final paramShift = 1 + ctorIndex + indexCount;
  Term shiftArgType(Term t, int j, int depth) => switch (t) {
    TBound(:final index) when index < j => t, // ctor arg, unchanged
    TBound(:final index) => TBound(index + paramShift),
    TType() ||
    TSProp() ||
    TProp() ||
    TFree() ||
    TBound() ||
    TTop() ||
    TMeta() => t,
    TApp(:final fn, :final arg) => TApp(
      shiftArgType(fn, j, depth),
      shiftArgType(arg, j, depth + 0),
    ),
    // Pis and Lams in arg types: don't shift under the new binder,
    // since the "j threshold" for this arg's own free refs stays
    // the same. We don't expect Pi inside arg types
    // (positivity rules that out for the recursive case); non-
    // recursive arg types with Pi are possible, so handle them.
    TPi(:final domain, :final codomain, :final name) => TPi(
      shiftArgType(domain, j, depth),
      shiftArgType(codomain, j + 1, depth + 1),
      name: name,
    ),
    TLam(:final domain, :final body, :final name) => TLam(
      shiftArgType(domain, j, depth),
      shiftArgType(body, j + 1, depth + 1),
      name: name,
    ),
    TLet(:final domain, :final bound, :final body, :final name) => TLet(
      shiftArgType(domain, j, depth),
      shiftArgType(bound, j, depth),
      shiftArgType(body, j + 1, depth + 1),
      name: name,
    ),
    TData(:final name, :final args) => TData(name, [
      for (final a in args) shiftArgType(a, j, depth),
    ]),
    TConstr(:final dataName, :final ctorName, :final args) => TConstr(
      dataName,
      ctorName,
      [for (final a in args) shiftArgType(a, j, depth)],
    ),
    TRec() => t,
    TQuot() => t,
    TQuotMk() => t,
    TQuotLift() => t,
    // Ctor signatures are types; TMatch is term-level.
    TMatch() => t,
    TProj() => t,
  };

  for (var j = argCount - 1; j >= 0; j--) {
    final shifted = shiftArgType(ctor.args[j].type, j, 0);
    result = TPi(shifted, result, name: ctor.args[j].name);
  }

  return result;
}

/// Substitute every occurrence of `VNeutral(NVar(scrutLevel))` in [value]
/// with [replacement]. Used for per-arm expected-type computation when
/// matching on a variable scrutinee with non-indexed data: replaces the
/// scrutinee variable with the ctor result in the expected type.
Value substNVar(Value value, int scrutLevel, Value replacement) {
  if (value is VNeutral) {
    // Descend into the neutral's components so that NVar references
    // embedded in NApp args are replaced.
    final n = value.neutral;
    switch (n) {
      case NVar(:final level):
        return level == scrutLevel ? replacement : value;
      case NApp(:final fn, :final arg):
        final newArg = substNVar(arg, scrutLevel, replacement);
        if (identical(newArg, arg)) return value;
        return VNeutral(NApp(fn, newArg));
      case NProj(:final expr, :final fieldName):
        final newExpr = substNVar(expr, scrutLevel, replacement);
        if (identical(newExpr, expr)) return value;
        return VNeutral(NProj(newExpr, fieldName));
      case NStuck():
        final newStuck = substNVar(n.value, scrutLevel, replacement);
        if (identical(newStuck, n.value)) return value;
        return VNeutral(NStuck(newStuck));
      default:
        return value;
    }
  }
  if (value is VData) {
    final newArgs = <Value>[];
    var changed = false;
    for (final a in value.args) {
      final na = substNVar(a, scrutLevel, replacement);
      newArgs.add(na);
      if (!identical(na, a)) changed = true;
    }
    return changed ? VData(value.name, newArgs) : value;
  }
  if (value is VConstr) {
    final newArgs = <Value>[];
    var changed = false;
    for (final a in value.args) {
      final na = substNVar(a, scrutLevel, replacement);
      newArgs.add(na);
      if (!identical(na, a)) changed = true;
    }
    return changed ? VConstr(value.dataName, value.ctorName, newArgs) : value;
  }
  if (value is VPi) {
    final nd = substNVar(value.domain, scrutLevel, replacement);
    return identical(nd, value.domain)
        ? value
        : VPi(nd, value.codomain, name: value.name, icit: value.icit);
  }
  if (value is VFun) {
    var changed = false;
    final newSpine = <Value>[];
    for (final a in value.spine) {
      final na = substNVar(a, scrutLevel, replacement);
      newSpine.add(na);
      if (!identical(na, a)) changed = true;
    }
    return changed
        ? VFun(
          value.name,
          value.lam,
          value.decreasingArg,
          value.arity,
          newSpine,
        )
        : value;
  }
  return value;
}
