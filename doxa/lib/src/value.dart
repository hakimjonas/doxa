/// Semantic values produced by evaluation.
///
/// Values are the "runtime" representation of terms during type checking
/// and normalization. Unlike [Term]s, they carry their environments with
/// them (via [Closure]s), so β-reduction never needs to substitute into
/// syntax.
///
/// A [VLam] or [VPi] holds a [Closure], a pair of the environment in
/// which the binder was introduced and the body term that still references
/// its bound variable via `TBound(0)`. Applying the closure consists of
/// extending its environment with the argument value and evaluating the
/// body.
///
/// A [VNeutral] is a computation stuck on a free variable. Stuck
/// applications layer up as `NApp` nodes so that the type checker can still
/// see the shape (e.g., `f(x)(y)`) without being able to β-reduce.
library;

import 'env.dart';
import 'registry.dart';
import 'surface.dart' show DoxaSpan;
import 'term.dart';

/// A semantic value.
sealed class Value {
  /// Base constructor.
  const Value();
}

/// A universe value at [level].
final class VType extends Value {
  /// The universe level.
  final Level level;

  /// Creates a universe value.
  const VType(this.level);
}

/// The Prop sort (v2).
///
/// `Prop : Type 1` and `Pi` from any sort to `Prop` lands in `Prop`
/// (impredicativity; SPEC §8.2).
final class VProp extends Value {
  /// Creates the Prop sort value.
  const VProp();
}

/// The strict proof-irrelevant universe sort (Gilbert et al. 2019).
///
/// `SProp : Type 1`. Two `VSProp` values are definitionally equal
/// (strict proof irrelevance).
final class VSProp extends Value {
  /// Creates the SProp sort value.
  const VSProp();
}

/// A lambda value: its evaluated domain (needed by [quote]) and the
/// body-plus-environment closure waiting for an argument.
///
/// [name] is a diagnostic hint propagated from the source `TLam`. It
/// does not participate in conversion or any semantic judgment
/// (SPEC §4.1, §4.3). Pretty-printing uses the hint to keep error
/// messages in the user's vocabulary.
final class VLam extends Value {
  /// The evaluated domain type.
  final Value domain;

  /// The body-plus-environment waiting for an argument.
  final Closure closure;

  /// Optional source name for the bound variable (diagnostic hint only).
  final String? name;

  /// Explicit vs. implicit binder. Default [Icit.explicit].
  /// Propagated from the source `TLam`.
  final Icit icit;

  /// Creates a lambda value.
  const VLam(this.domain, this.closure, {this.name, this.icit = Icit.explicit});
}

/// A Pi-type value: the domain (already evaluated) and the codomain
/// closure (evaluated lazily when a domain value is supplied).
///
/// [name] is a diagnostic hint propagated from the source `TPi`.
final class VPi extends Value {
  /// The domain value.
  final Value domain;

  /// The codomain closure.
  final Closure codomain;

  /// Optional source name for the bound variable (diagnostic hint only).
  final String? name;

  /// Explicit vs. implicit binder. Default [Icit.explicit].
  /// Propagated from the source `TPi`.
  final Icit icit;

  /// Creates a Pi-type value.
  const VPi(this.domain, this.codomain, {this.name, this.icit = Icit.explicit});
}

/// A stuck computation, a head free variable with zero or more applied
/// argument values.
final class VNeutral extends Value {
  /// The neutral form.
  final Neutral neutral;

  /// Creates a neutral value.
  const VNeutral(this.neutral);
}

/// An inductive type value: `Nat`, `List A`, `Vec A (succ n)`.
///
/// [name] identifies the declaration; [args] is params followed by
/// indices, positionally. Inductive types are canonical, two
/// `VData`s with the same name and structurally-equal args are
/// convertible but do not reduce.
final class VData extends Value {
  /// The inductive type's name.
  final String name;

  /// Parameters and indices, positionally.
  final List<Value> args;

  /// Creates a data type value.
  const VData(this.name, this.args);
}

/// A constructor value: `zero`, `succ n`, `cons x xs`.
///
/// [dataName] is the parent inductive; [ctorName] is the constructor.
/// [args] is: data-type parameters first, then the constructor's own
/// arguments, positionally. Constructors are canonical, when a
/// recursor meets a `VConstr` the ι-rule dispatches.
final class VConstr extends Value {
  /// The parent inductive's name.
  final String dataName;

  /// The constructor's name.
  final String ctorName;

  /// Positional args: data params first, then constructor-specific.
  final List<Value> args;

  /// Creates a constructor value.
  const VConstr(this.dataName, this.ctorName, this.args);
}

/// A recursor value.
///
/// `VRec(dataDecl, spine)` represents the partial application of the
/// inductive type's dependent eliminator. The spine accumulates args
/// via `apply`; when saturated (the spine holds motive, one method per
/// constructor, then indices and a scrutinee at the final position),
/// ι-reduction fires if the scrutinee is canonical. Otherwise the
/// `VRec` stays stuck, its quote form is a series of `TApp`s over a
/// `TRec` head.
///
/// See `apply` in `eval.dart` for the ι-reduction logic.
final class VRec extends Value {
  /// The inductive type's full declaration. Carrying the decl
  /// directly (rather than just the name) means [apply]'s ι-reduction
  /// has immediate access to the ctor telescope shapes without going
  /// through a registry lookup at reduction time.
  final DataDecl dataDecl;

  /// Accumulated arguments applied to the recursor, in left-to-right
  /// application order: motive first, then one method per ctor in the
  /// order they appear in [DataDecl.ctors], then indices (if any),
  /// then the scrutinee at the final position.
  final List<Value> spine;

  /// Creates a recursor value with the given accumulated [spine].
  const VRec(this.dataDecl, this.spine);
}

/// A guarded recursive top-level function, partially or fully applied
/// but STUCK because its designated decreasing argument is not yet a
/// canonical constructor (SPEC §8.6 fix-reduction).
///
/// Background. A recursive `fun` (e.g. `map`, `append`, `plus`) is
/// stored as a `VLam` chain whose innermost body is a `match` on the
/// decreasing argument. Before this type existed, applying such a
/// `fun` to a NEUTRAL argument (a variable, not a `cons …`/`succ …`)
/// eagerly β-reduced into the body, hit the `match`, and produced a
/// stuck [VMatch]. That stuck match captured the *caller's* env, and
/// when it was later quoted into a type and re-evaluated at a different
/// depth (the metavariable-typed-expected-type path), its arm bodies,
/// stored verbatim, mis-resolved the function's own parameters
/// (a captured-env depth mismatch).
///
/// CIC's `fix` reduction rule (and Lean/Coq/Agda's WHNF) only unfold a
/// recursive definition when its recursive argument is a constructor.
/// [VFun] implements exactly that: it accumulates a [spine] via
/// `apply`; once the spine fills the [decreasingArg] position with a
/// canonical [VConstr], it unfolds by applying the stored [lam] to the
/// whole spine. Until then it stays stuck, quoting to `TTop(name)`
/// applied to the quoted spine (depth-portable, never frozen as an
/// expanded match) and comparing convertibly to another [VFun] of the
/// same [name] by spine.
///
/// This mirrors [VRec]'s discipline (stuck eliminator that ι-reduces
/// only on a canonical scrutinee), extended to user `fun`s.
final class VFun extends Value {
  /// The function's top-level name. Quote form is `TTop(name)`.
  final String name;

  /// The function's underlying lambda value (the `VLam` chain stored in
  /// the top-binding registry). Carried directly so unfolding needs no
  /// registry lookup, matching [VRec]'s self-contained `dataDecl`.
  final Value lam;

  /// The de-Bruijn position (in left-to-right application order, among
  /// ALL parameters including type params) of the designated decreasing
  /// argument. The fun unfolds once `spine.length > decreasingArg` and
  /// `spine[decreasingArg]` is a canonical [VConstr].
  final int decreasingArg;

  /// The total number of parameters the [lam] chain expects before its
  /// body (the `match`) is reached. The fun never unfolds before the
  /// spine is at least this long (a partial application can't reduce).
  final int arity;

  /// Accumulated arguments in left-to-right application order.
  final List<Value> spine;

  /// Creates a guarded recursive-function value.
  const VFun(this.name, this.lam, this.decreasingArg, this.arity, this.spine);
}

/// A single case arm of a stuck [VMatch].
///
/// Mirrors [TMatchCase] at the value level. The [body] is still a
/// `Term`, closures over the arm's pattern binders are deferred to
/// ι-reduction time, at which point we extend the captured [env]
/// with the ctor's non-param args (innermost-first, matching Doxa's
/// existing Closure discipline) and evaluate.
///
/// [binderNames] and [span] are diagnostic hints; do not participate
/// in convertibility or equality. The span is preserved through
/// ι-reduction + quote so diagnostics on elaborated programs can
/// still cite the originating source region.
final class VMatchCase {
  /// The ctor this arm matches, or empty string `""` for a wildcard.
  final String ctorName;

  /// The number of pattern binders (0 for wildcards).
  final int nBinders;

  /// The arm's right-hand side, opening over [nBinders] binders.
  final Term body;

  /// Diagnostic names for the pattern binders.
  final List<String?> binderNames;

  /// The arm's source span (synthetic for arms not from source).
  final DoxaSpan span;

  /// Creates a match-case value.
  const VMatchCase(
    this.ctorName,
    this.nBinders,
    this.body,
    this.binderNames, {
    this.span = DoxaSpan.synthetic,
  });

  /// True iff this is a wildcard arm.
  bool get isWildcard => ctorName.isEmpty;
}

/// A pattern-match value, stuck on a non-canonical scrutinee.
///
/// `VMatch(scrutinee, motive, cases, env)` is a pattern-match value
/// that could not reduce because the scrutinee did not evaluate to a
/// canonical [VConstr]. Mirrors [VRec]'s discipline: a first-class
/// [Value] (not a [Neutral]) so that a stuck match can sit anywhere
/// a value can, including with a scrutinee that is itself a stuck
/// [VRec] or another [VMatch].
///
///   * [scrutinee]: the (already evaluated) scrutinee value. Stuck.
///   * [motive]: the (already evaluated) motive value, or null if
///                   the source `TMatch.motive` was null (user omitted
///                   `returning`, so the motive is implicit from the
///                   check context). Held so that convertibility of
///                   two stuck matches can compare motives pointwise
///                   (SPEC §4.3); two stuck matches with null motives
///                   converge on the cases alone.
///   * [cases]: the arm list in source order. Each arm's body
///                   is still a [Term] (not yet applied to binders);
///                   ι-reduction supplies the binders from the ctor
///                   value when the scrutinee later becomes canonical.
///   * [env]: the environment captured at the point the match
///                   was evaluated. Case bodies evaluate against this
///                   env extended by their pattern binders.
///
/// Quote form: `TMatch(quote(scrutinee), quote(motive), cases)` with
/// each case's body quoted at `level + nBinders` under the captured
/// env extended with fresh neutrals for each binder. The null motive
/// round-trips as null.
final class VMatch extends Value {
  /// The scrutinee value (stuck).
  final Value scrutinee;

  /// The motive value, or null if the source match did not carry a
  /// `returning` clause.
  final Value? motive;

  /// The case arms.
  final List<VMatchCase> cases;

  /// The environment captured at match-eval time.
  final Env env;

  /// Creates a stuck match value.
  const VMatch(this.scrutinee, this.motive, this.cases, this.env);
}

/// A quotient type value: `Quot(A, R)`.
final class VQuot extends Value {
  final Value carrier;
  final Value relation;
  const VQuot(this.carrier, this.relation);
}

/// A quotient element value: `Quot.mk(a)`.
final class VQuotMk extends Value {
  final Value arg;
  const VQuotMk(this.arg);
}

/// A stuck quotient lift (waiting for the quot argument to become VQuotMk).
/// Once the quot is canonical, ι-reduction fires: lift(mk(a), f, proof) → f(a).
final class VQuotLift extends Value {
  final Value quot;
  final Value fn;
  final Value proof;
  const VQuotLift(this.quot, this.fn, this.proof);
}

/// A β-redex whose reduction is deferred until a driver operation
/// (conv, quote, apply) forces it. This lazy, force-on-demand
/// discipline is shared by Lean, Coq, Agda, and elaboration-zoo.
///
/// Semantics: `VDelayed(c, a)` represents the value
/// `eval(c.body, c.env.extend(a))` without actually performing the
/// substitution. Forcing it runs that eval. Structural conv of two
/// `VDelayed`s sharing the same `closure` identity compares `arg`s
/// pointwise without forcing, preserving any pattern-fragment
/// spine shape inside `c.body`'s meta applications.
///
/// Motivation. Without lazy motive unfolding, applying a
/// recursor's motive `P` to a canonical argument (e.g.
/// `P (cons A h t)` in the step's expected type) β-reduces the
/// motive body eagerly. When the body contains metas whose spines
/// were pattern-fragment `[A, ys]` at elab time, substituting a
/// non-variable argument for `ys` produces `[A, cons A h t]`
/// breaking pattern fragment. Keeping the application stuck at
/// `VDelayed` preserves the meta spines so later conv/unification
/// can still fire.
final class VDelayed extends Value {
  /// The deferred closure.
  final Closure closure;

  /// The argument awaiting β-substitution.
  final Value arg;

  /// Creates a deferred β-redex value.
  const VDelayed(this.closure, this.arg);
}

/// A binder body paired with the environment that captured it.
///
/// Closures are shared freely and must never be mutated: multiple [VLam]s
/// and [VPi]s may hold the same [Closure] instance, and even within a
/// single closure the [env] may be shared with unrelated closures.
final class Closure {
  /// The captured environment.
  final Env env;

  /// The binder body. Its `TBound(0)` references the bound variable
  /// supplied when the closure is applied.
  final Term body;

  /// Optimization hint: [body] is already in normal form in scope
  /// `env.extend(fresh)` at level `env.depth + 1`.
  ///
  /// When true, `quote(VPi(_, this), level)` can reuse [body] directly
  /// as the Pi's codomain term at `level` instead of re-running the
  /// open → eval → quote round-trip (that round-trip is identity on
  /// terms already in normal form). Set at the single construction
  /// site where the invariant is locally true, `_InferLamHaveBodyTerm`,
  /// and read only from `_Quote(VPi)`.
  ///
  /// Safe default is `false`: a closure whose body came from a raw
  /// surface term (the common case via `_Eval(TPi|TLam)`) has no such
  /// guarantee.
  final bool bodyIsNormal;

  /// Creates a closure.
  const Closure(this.env, this.body, {this.bodyIsNormal = false});
}

/// A neutral form: a free variable (by level), optionally applied to
/// argument values.
sealed class Neutral {
  /// Base constructor.
  const Neutral();
}

/// A free variable at de Bruijn [level], counted from the root of the
/// enclosing context.
///
/// Using levels rather than indices makes neutrals position-stable:
/// the same `NVar(3)` refers to the same binder regardless of how many
/// further binders are opened above it.
final class NVar extends Neutral {
  /// The de Bruijn level.
  final int level;

  /// Creates a variable neutral.
  const NVar(this.level);
}

/// A stuck application of neutral [fn] to argument value [arg].
final class NApp extends Neutral {
  /// The stuck head.
  final Neutral fn;

  /// The applied argument value.
  final Value arg;

  /// Creates an application neutral.
  const NApp(this.fn, this.arg);
}

/// A non-[NVar] stuck [Value] at the head of a neutral spine.
///
/// Some stuck values, a [VMatch] whose scrutinee is canonical but
/// of a non-function return type reached mid-elaboration, a
/// saturated-but-stuck [VRec] on a neutral scrutinee, behave like
/// neutrals: they cannot reduce further until something under them
/// becomes canonical, and they can still be applied, quoted, or
/// compared for convertibility. Wrapping them with [NStuck] lets the
/// existing [NApp] spine uniformly carry applied args on top of any
/// such stuck head without bespoke Apply-dispatch per Value kind.
///
/// The wrapped [value] must not be a [VLam] (would β-reduce), a
/// [VPi] / [VType] / [VProp] (not an application head), a [VData]
/// / [VConstr] (non-function), or a [VNeutral] (already neutral
/// caller should use the underlying neutral directly). Concretely,
/// only [VMatch] today; future stuck forms can add here.
final class NStuck extends Neutral {
  /// The wrapped stuck value.
  final Value value;

  /// Creates a stuck-head neutral.
  const NStuck(this.value);
}

/// A reference to a top-level binding that is currently "opaque",
/// either because it's being type-checked right now (a recursive
/// `fun` inside its own body) or because the checker is walking
/// under a `TTop(name)` whose resolution has been deliberately
/// stubbed (co-recursive groups install [NTop(name)] stubs in
/// [Env.topBindings] before any body is checked, so self- and
/// sibling-references behave as stuck neutrals during check-time
/// reduction).
///
/// Neutral form because:
///   * [TTop(name)] with a stubbed [NTop] head cannot reduce
///     further until the group check completes and real bodies are
///     installed.
///   * It must still be applicable, `f x` where `f` is stubbed
///     should extend the spine via [NApp], matching every other
///     neutral.
///   * It must compare equal to itself across conv: two references
///     to the same-name stub are definitionally equal.
///
/// The wrapped [name] is the same string keyed into
/// [Env.topBindings].
final class NTop extends Neutral {
  /// The top-level binding's name.
  final String name;

  /// Creates a top-level stub neutral.
  const NTop(this.name);
}

/// A stuck primitive projection: `neutral.fieldName`.
///
/// Produced when evaluating `TProj(e, fieldName)` and `e` evaluates to a
/// non-[VConstr] value (a [VNeutral] in practice). The projection stays
/// stuck until the record expression becomes a [VConstr].
final class NProj extends Neutral {
  /// The stuck record expression being projected from.
  final Value expr;

  /// The field name being accessed.
  final String fieldName;

  /// Creates a projection neutral.
  const NProj(this.expr, this.fieldName);

  @override
  bool operator ==(Object other) =>
      other is NProj && other.expr == expr && other.fieldName == fieldName;

  @override
  int get hashCode => Object.hash('NProj', expr, fieldName);

  @override
  String toString() => 'NProj($expr, $fieldName)';
}

/// An unsolved metavariable's neutral head.
///
/// `VNeutral(NMeta(id))` is the value produced by evaluating a
/// [TMeta(id)] whose entry in the [MetaContext] is still unsolved.
/// When the meta is later solved, the evaluator transparently unfolds
/// the reference rather than reaching the neutral case; that is the
/// difference between [NMeta] and [NTop], which never unfolds (top-
/// level bindings are values in their own right, not placeholders).
///
/// Dispatch:
///
///  * `apply(VNeutral(NMeta(id)), arg)` → extend spine via `NApp`,
///    identical to [NVar]. The meta remains stuck until solved.
///  * `conv(VNeutral(NMeta(id) spine), t)` → hand off to the unifier
///    (the single semantic hook for the metavariable machinery).
///  * `quote(VNeutral(NMeta(id) spine), level)` → produce
///    `TMeta(id)` applied to the quoted spine.
///
/// First-class `Neutral` subclass (not wrapped in `NStuck`) so
/// exhaustive switches dispatch by type and the defunctionalized-
/// driver invariant ("new ADT case, not new driver function") is
/// preserved. As in Lean and elaboration-zoo, a metavariable is its
/// own first-class form rather than a wrapper around another.
final class NMeta extends Neutral {
  /// The metavariable's id, an index into the enclosing
  /// [MetaContext].
  final int id;

  /// Creates a metavariable neutral.
  const NMeta(this.id);
}
