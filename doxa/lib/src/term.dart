/// The kernel term language and locally-nameless binder operations.
///
/// Doxa's kernel uses a locally-nameless representation (McBride & McKinna
/// 2004): bound variables are de Bruijn indices, free variables carry their
/// source names. This gives capture-free binder operations by construction
/// while preserving names at binder sites for display.
///
/// Two operations cross the bound/free boundary:
///
///  * [openTerm] replaces `TBound 0` in a term with a fresh free variable,
///    used when descending under a binder during type checking.
///  * [closeTerm] replaces a free variable with `TBound 0`, used when
///    constructing a binder from a source name.
///
/// The invariant [closeTerm] then [openTerm] with the same name is the
/// identity (and vice versa) is enforced by the test suite.
library;

import 'surface.dart' show DoxaSpan;

/// Binder icity, whether a Pi / Lam is explicit or implicit.
///
/// Explicit binders are supplied at the call site by the user;
/// implicit binders are supplied by the elaborator via a fresh
/// metavariable, solved by pattern unification during subsequent
/// checking. This explicit/implicit distinction on binders is the
/// standard one (Lean's binder info, elaboration-zoo's icitness).
///
/// Participation in equality: icity IS compared by `conv` and by
/// `Term`/`Value` equality. A Pi `{A: Type} -> A -> A` is a
/// different type from `(A: Type) -> A -> A`, call-site insertion
/// rules differ, and a function of one type cannot silently stand
/// in for the other.
enum Icit {
  /// A binder supplied explicitly by the caller at the application
  /// site, the default for Pi and Lambda.
  explicit,

  /// A binder the caller elides; the elaborator inserts a fresh
  /// metavariable and pattern unification solves it during checking.
  implicit,
}

/// A universe level expression.
///
/// Universe levels express the hierarchy of `Type n`. The level algebra
/// supports concrete levels, variables (declaration-scoped), successor,
/// maximum, and impredicative maximum.
///
/// This mirrors Lean 4's `level` ADT (per-declaration level variables),
/// omitting level metavariables (handled by the elaborator as fresh
/// `LLevel` assignments). See PHASE_15 docs for design rationale.
sealed class Level {
  const Level();
}

/// Concrete universe level: `Type 0`, `Type 1`, etc.
final class LLevel extends Level {
  final int level;
  const LLevel(this.level);

  @override
  bool operator ==(Object other) => other is LLevel && other.level == level;

  @override
  int get hashCode => Object.hash('LLevel', level);

  @override
  String toString() => 'LLevel($level)';
}

/// Level variable (declaration-scoped): bound per top-level declaration.
final class LVar extends Level {
  final String name;
  const LVar(this.name);

  @override
  bool operator ==(Object other) => other is LVar && other.name == name;

  @override
  int get hashCode => Object.hash('LVar', name);

  @override
  String toString() => 'LVar($name)';
}

/// Level successor: `succ(l)` for `Type l : Type (l+1)`.
final class LSucc extends Level {
  final Level of;
  const LSucc(this.of);

  @override
  bool operator ==(Object other) => other is LSucc && other.of == of;

  @override
  int get hashCode => Object.hash('LSucc', of);

  @override
  String toString() => 'LSucc($of)';
}

/// Maximum of two levels. Used for Pi types and inductive parameters.
final class LMax extends Level {
  final Level lhs;
  final Level rhs;
  const LMax(this.lhs, this.rhs);

  @override
  bool operator ==(Object other) =>
      other is LMax && other.lhs == lhs && other.rhs == rhs;

  @override
  int get hashCode => Object.hash('LMax', lhs, rhs);

  @override
  String toString() => 'LMax($lhs, $rhs)';
}

/// Impredicative maximum: `imax(u, v) = 0` when `v == 0`, else `max(u, v)`.
///
/// Used so `(Type u → Prop) : Type 0` not `Type u`. In Doxa, `Prop` is
/// level 0 for Pi-sort computation.
final class LImax extends Level {
  final Level lhs;
  final Level rhs;
  const LImax(this.lhs, this.rhs);

  @override
  bool operator ==(Object other) =>
      other is LImax && other.lhs == lhs && other.rhs == rhs;

  @override
  int get hashCode => Object.hash('LImax', lhs, rhs);

  @override
  String toString() => 'LImax($lhs, $rhs)';
}

/// A kernel term.
sealed class Term {
  /// Base constructor.
  const Term();
}

/// A universe, `Type n`, inhabited by the types at level `n`.
final class TType extends Term {
  /// The universe level.
  final Level level;

  /// Creates a universe at [level].
  const TType(this.level);

  @override
  bool operator ==(Object other) => other is TType && other.level == level;

  @override
  int get hashCode => Object.hash('TType', level);

  @override
  String toString() => 'TType($level)';
}

/// The sort of propositions.
///
/// `Prop` is impredicative: a Pi whose codomain is in `Prop` is itself
/// in `Prop`, regardless of the domain's sort. `Prop` itself has type
/// `Type 1` (SPEC §8.2). Introduced in v2.
final class TProp extends Term {
  /// Creates the Prop sort.
  const TProp();

  @override
  bool operator ==(Object other) => other is TProp;

  @override
  int get hashCode => Object.hash('TProp', 0);

  @override
  String toString() => 'TProp';
}

/// The strict proof-irrelevant universe sort (Gilbert et al. 2019).
///
/// `SProp` is impredicative and strict: any two `SProp` values are
/// definitionally equal regardless of their internal structure.
/// `SProp` itself has type `Type 1`.
final class TSProp extends Term {
  /// Creates the SProp sort.
  const TSProp();

  @override
  bool operator ==(Object other) => other is TSProp;

  @override
  int get hashCode => Object.hash('TSProp', 0);

  @override
  String toString() => 'TSProp';
}

/// A bound variable, referenced by its de Bruijn index.
///
/// Index 0 is the innermost enclosing binder.
final class TBound extends Term {
  /// The de Bruijn index.
  final int index;

  /// Creates a bound-variable reference.
  const TBound(this.index);

  @override
  bool operator ==(Object other) => other is TBound && other.index == index;

  @override
  int get hashCode => Object.hash('TBound', index);

  @override
  String toString() => 'TBound($index)';
}

/// A free variable, referenced by its source name.
final class TFree extends Term {
  /// The source name.
  final String name;

  /// Creates a free-variable reference.
  const TFree(this.name);

  @override
  bool operator ==(Object other) => other is TFree && other.name == name;

  @override
  int get hashCode => Object.hash('TFree', name);

  @override
  String toString() => 'TFree($name)';
}

/// A function application `f(a)`.
final class TApp extends Term {
  /// The function being applied.
  final Term fn;

  /// The argument.
  final Term arg;

  /// Creates an application.
  const TApp(this.fn, this.arg);

  @override
  bool operator ==(Object other) =>
      other is TApp && other.fn == fn && other.arg == arg;

  @override
  int get hashCode => Object.hash('TApp', fn, arg);

  @override
  String toString() => 'TApp($fn, $arg)';
}

/// Primitive projection: `e.field` for a single-constructor record type.
final class TProj extends Term {
  /// The record expression being projected from.
  final Term expr;

  /// The field name.
  final String fieldName;

  const TProj(this.expr, this.fieldName);

  @override
  bool operator ==(Object other) =>
      other is TProj && other.expr == expr && other.fieldName == fieldName;

  @override
  int get hashCode => Object.hash('TProj', expr, fieldName);

  @override
  String toString() => 'TProj($expr, $fieldName)';
}

/// A lambda abstraction `(x: domain) => body`.
///
/// The body uses `TBound(0)` to reference the bound variable. The
/// optional [name] is a diagnostic hint carrying the user's source name
/// for the bound variable, it does not participate in equality,
/// conversion, or any semantic judgment (SPEC §3.2).
final class TLam extends Term {
  /// The annotated domain type.
  final Term domain;

  /// The body. References to the bound variable use [TBound] with index 0.
  final Term body;

  /// Optional source name for the bound variable (diagnostic hint only).
  final String? name;

  /// Explicit vs. implicit binder. Default [Icit.explicit].
  /// Participates in equality, an implicit-domain lambda is a
  /// distinct kernel term from an explicit-domain one.
  final Icit icit;

  /// Creates a lambda. Pass [name] to preserve the source identifier for
  /// pretty-printing; leave null for synthesized binders. Pass
  /// [icit] = [Icit.implicit] for an implicit-binder lambda (matches
  /// a `{A: _}` surface binder).
  const TLam(this.domain, this.body, {this.name, this.icit = Icit.explicit});

  @override
  bool operator ==(Object other) =>
      other is TLam &&
      other.domain == domain &&
      other.body == body &&
      other.icit == icit;

  @override
  int get hashCode => Object.hash('TLam', domain, body, icit);

  @override
  String toString() {
    final prefix = icit == Icit.implicit ? 'TLam{imp}' : 'TLam';
    return name == null
        ? '$prefix($domain, $body)'
        : '$prefix[$name]($domain, $body)';
  }
}

/// A local let-binding `let x: domain = bound in body` (v2).
///
/// [domain] is the bound variable's type. [bound] is the expression
/// the name refers to. [body] uses `TBound(0)` for the let-bound
/// variable. The optional [name] is a diagnostic hint.
///
/// Evaluation inlines the let by extending the environment with the
/// evaluated bound expression and evaluating the body in the extended
/// environment. No `VLet` value exists: after eval, lets leave no
/// trace. Quoting therefore loses the let structure (normal forms
/// are post-reduction), which is acceptable since lets are about
/// sharing during checking, not about preserving source shape.
final class TLet extends Term {
  /// The annotated type of the bound variable.
  final Term domain;

  /// The expression the bound name refers to.
  final Term bound;

  /// The body. Uses `TBound(0)` to refer to the let-bound variable.
  final Term body;

  /// Optional source name for the bound variable (diagnostic hint only).
  final String? name;

  /// Creates a let-binding.
  const TLet(this.domain, this.bound, this.body, {this.name});

  @override
  bool operator ==(Object other) =>
      other is TLet &&
      other.domain == domain &&
      other.bound == bound &&
      other.body == body;

  @override
  int get hashCode => Object.hash('TLet', domain, bound, body);

  @override
  String toString() =>
      name == null
          ? 'TLet($domain, $bound, $body)'
          : 'TLet[$name]($domain, $bound, $body)';
}

/// An inductive type reference: `Nat`, `List A`, `Vec A (succ n)`.
///
/// [name] identifies the inductive declaration in the enclosing
/// [TopEnv] registry. [args] is the positional list of parameters
/// followed by indices. For a type with no params or indices
/// ([Nat]), [args] is empty.
///
/// TData is a canonical type value: two TData references with the
/// same name and structurally-equal args are convertible. It does
/// not reduce (inductive types are canonical).
final class TData extends Term {
  /// The inductive type's name (registry key).
  final String name;

  /// Parameters and indices, positionally (params first, then indices).
  final List<Term> args;

  /// Creates a data type reference.
  const TData(this.name, this.args);

  @override
  bool operator ==(Object other) {
    if (other is! TData ||
        other.name != name ||
        other.args.length != args.length) {
      return false;
    }
    for (var i = 0; i < args.length; i++) {
      if (args[i] != other.args[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash('TData', name, Object.hashAll(args));

  @override
  String toString() => args.isEmpty ? 'TData($name)' : 'TData($name, $args)';
}

/// The recursor for an inductive type.
///
/// `TRec(dataName)` is the kernel term that evaluates to the recursor
/// value [VRec] for the inductive type named [dataName]. It appears
/// only as the RHS of the mechanically-generated `T.rec` top-level
/// binding, never in user-written code. This narrow role is the
/// difference between Doxa and systems like Coq that expose recursors
/// at the kernel-term level for user use: Doxa's users work through
/// `T.rec` as a top-level name, not through a syntactic primitive.
///
/// At eval time, `TRec(name)` looks up the [DataDecl] in the env's
/// registry and yields `VRec(dataDecl, spine: [])`. Each subsequent
/// application extends the spine; when the spine is saturated with
/// a canonical [VConstr] at the scrutinee position, ι-reduction fires
/// (see [apply] in `eval.dart`).
final class TRec extends Term {
  /// The inductive type's name.
  final String dataName;

  /// Optional motive-sort override (the multi-recursor bridge).
  ///
  /// The default-sort recursor (`null` here) binds as `T.rec` with
  /// motive target = data's declared sort. For Prop-sorted
  /// singletons (SPEC §8.2 singleton-elim), the elab site also auto-
  /// emits a *large-elimination* variant bound as `T.rect` with
  /// motive target = `Type 0`, represented here as `TRec(name,
  /// motiveSort: TType(0))`. Equality and reduction are name-only;
  /// the sort discriminator affects only the synthesized type the
  /// kernel exposes via `infer(TRec)`.
  ///
  /// Full universe polymorphism would collapse this pair into a single
  /// sort-polymorphic recursor; absent that, multiple bindings per
  /// inductive is the Coq-historical approach.
  final Term? motiveSort;

  /// Creates a recursor reference for the inductive type named [dataName].
  const TRec(this.dataName, {this.motiveSort});

  @override
  bool operator ==(Object other) =>
      other is TRec &&
      other.dataName == dataName &&
      other.motiveSort == motiveSort;

  @override
  int get hashCode => Object.hash('TRec', dataName, motiveSort);

  @override
  String toString() =>
      motiveSort == null
          ? 'TRec($dataName)'
          : 'TRec($dataName, motiveSort: $motiveSort)';
}

/// A reference to a top-level binding by name.
///
/// Every reference from within a declaration's body to another top-
/// level binding (a `val`, `type`, `fun`, or auto-emitted `T.rec`)
/// uses this term form, never a de-Bruijn-indexed [TBound] into a
/// mutable bindings list. At eval time the kernel looks up [name] in
/// the enclosing [Env]'s top-binding map to retrieve the value.
///
/// This is the standard CIC discipline (Coq's `Const`, Lean's
/// `Expr.const`, Agda's `QName`). Top-level names are globally
/// scoped; de Bruijn is reserved for local binders only. The split
/// has three properties:
///
///   1. **Env-length independence.** The length of the enclosing
///      [TopEnv.bindings] list changes as declarations are processed,
///      but a [TTop(name)] term's meaning doesn't drift with it.
///      This avoids a class of mutual-block bugs (the "mixed block"
///      case) where members pre-registered with body TBound indices
///      could silently misalign with a later-constructed context.
///   2. **No scratch env.** Sibling references within a mutual block
///      resolve naturally via [TTop(name)], no pre-registration
///      plumbing needed at elab time.
///   3. **Meta-variable friendly.** Metavariables split cleanly along
///      the same axis: global metas scope to names, local metas to de
///      Bruijn levels. Unifying top-level refs with de Bruijn
///      would have forced that split to be retrofitted.
///
/// Distinct from [TRec]: [TRec] is an eliminator whose application
/// triggers ι-reduction against canonical constructors; [TTop] is a
/// pure definition lookup that simply unfolds to its registered
/// value. Merging them would pollute ι-reduction semantics.
final class TTop extends Term {
  /// The top-level binding's name.
  final String name;

  /// Creates a top-level reference.
  const TTop(this.name);

  @override
  bool operator ==(Object other) => other is TTop && other.name == name;

  @override
  int get hashCode => Object.hash('TTop', name);

  @override
  String toString() => 'TTop($name)';
}

/// A metavariable placeholder, referenced by integer id.
///
/// Metavariables are introduced by the elaborator at positions where
/// the user elided an argument (implicit args, omitted type annotations,
/// inferred motives). Each `TMeta(id)` refers to an entry in the
/// elaborator's [MetaContext]; when the entry is later solved, the
/// meta transparently unfolds to its solution during evaluation.
///
/// Design:
///
///   * Meta ids are integers, no name, no source span directly on
///     the Term. Source context lives in the MetaContext entry and
///     flows to user-facing diagnostics through there.
///   * Args are never carried on the Term itself; a meta applied to
///     arguments elaborates to `TApp(TApp(TMeta(id), arg1), arg2)`,
///     keeping the kernel's application machinery uniform over metas
///     and regular functions.
///   * The corresponding Neutral shape is [NMeta] (not an `NStuck`
///     around a `VMeta`), a first-class `Neutral` subclass so
///     exhaustive switches dispatch by type rather than by an inner
///     tag.
///
/// Where elaboration-zoo distinguishes a bare meta from an "inserted"
/// meta carrying its bound-variable spine, Doxa represents the spine
/// with ordinary `TApp` because the driver already normalises
/// applications.
final class TMeta extends Term {
  /// The metavariable's id. Refers to an entry in the enclosing
  /// [MetaContext].
  final int id;

  /// Creates a metavariable reference.
  const TMeta(this.id);

  @override
  bool operator ==(Object other) => other is TMeta && other.id == id;

  @override
  int get hashCode => Object.hash('TMeta', id);

  @override
  String toString() => 'TMeta($id)';
}

/// An inductive type constructor: `zero`, `succ n`, `cons x xs`.
///
/// [dataName] identifies which inductive the constructor belongs to.
/// [ctorName] identifies which constructor. [args] is the positional
/// arg list: first the data type's own parameters (so `cons`'s args
/// are `[A, head, tail]` for `List A`), then the constructor's own
/// arguments.
final class TConstr extends Term {
  /// The parent inductive type's name.
  final String dataName;

  /// The constructor's name.
  final String ctorName;

  /// Positional args: data params first, then constructor-specific args.
  final List<Term> args;

  /// Creates a constructor reference.
  const TConstr(this.dataName, this.ctorName, this.args);

  @override
  bool operator ==(Object other) {
    if (other is! TConstr ||
        other.dataName != dataName ||
        other.ctorName != ctorName ||
        other.args.length != args.length) {
      return false;
    }
    for (var i = 0; i < args.length; i++) {
      if (args[i] != other.args[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash('TConstr', dataName, ctorName, Object.hashAll(args));

  @override
  String toString() =>
      args.isEmpty
          ? 'TConstr($dataName.$ctorName)'
          : 'TConstr($dataName.$ctorName, $args)';
}

/// A dependent function type `(x: domain) -> codomain`.
///
/// The codomain uses `TBound(0)` to reference the bound variable. A
/// non-dependent arrow `A -> B` is the special case where the codomain
/// does not mention `TBound(0)`. The optional [name] is a diagnostic
/// hint for the bound variable; it does not participate in equality or
/// any semantic judgment (SPEC §3.2).
final class TPi extends Term {
  /// The domain type.
  final Term domain;

  /// The codomain. References to the bound variable use [TBound] with index 0.
  final Term codomain;

  /// Optional source name for the bound variable (diagnostic hint only).
  final String? name;

  /// Explicit vs. implicit binder. Default [Icit.explicit].
  /// An implicit-Pi `{A: Type} -> A -> A` is a DIFFERENT type from
  /// the explicit `(A: Type) -> A -> A` because call-site insertion
  /// rules differ; conv therefore compares icity.
  final Icit icit;

  /// Creates a Pi-type. Pass [name] for dependent Pi with a named binder;
  /// leave null for non-dependent arrows or synthesized binders. Pass
  /// [icit] = [Icit.implicit] for an implicit-binder Pi.
  const TPi(this.domain, this.codomain, {this.name, this.icit = Icit.explicit});

  @override
  bool operator ==(Object other) =>
      other is TPi &&
      other.domain == domain &&
      other.codomain == codomain &&
      other.icit == icit;

  @override
  int get hashCode => Object.hash('TPi', domain, codomain, icit);

  @override
  String toString() {
    final prefix = icit == Icit.implicit ? 'TPi{imp}' : 'TPi';
    return name == null
        ? '$prefix($domain, $codomain)'
        : '$prefix[$name]($domain, $codomain)';
  }
}

/// A single arm of a [TMatch], a constructor case or a wildcard.
///
/// [ctorName] is the constructor's name, or empty string `""` for a
/// wildcard arm. [nBinders] is the number of de Bruijn slots the arm's
/// body opens over; a wildcard has `nBinders == 0` (the scrutinee
/// value itself is not bound, the user uses `case _` when they
/// don't need to refer to the value). For a ctor arm, `nBinders`
/// equals the number of the ctor's non-param arguments (elaborator
/// enforces this against the registry).
///
/// [body] uses `TBound(nBinders - 1 - i)` to reach the `i`-th pattern
/// binder (left-to-right in source order), matching the existing
/// Closure-over-args convention (innermost-first in the env).
/// [binderNames] carries the source names as diagnostic hints, same
/// discipline as [TLam.name] / [TPi.name].
///
/// [span] carries the arm's source region so check-time diagnostics
/// (e.g. a ctor-doesn't-match-scrutinee error) can point at the
/// specific arm. Synthetic for arms not produced from source.
final class TMatchCase {
  /// The constructor name, or empty string `""` for a wildcard.
  final String ctorName;

  /// The number of pattern binders opened by [body]. Equals
  /// `binderNames.length`.
  final int nBinders;

  /// The arm's right-hand side, opening over [nBinders] binders.
  final Term body;

  /// Diagnostic-only source names for the pattern binders. `"_"` is
  /// preserved literally. Same length as [nBinders].
  final List<String?> binderNames;

  /// The arm's source span (covers `case ... => body`). Synthetic
  /// for arms built outside of surface elaboration.
  final DoxaSpan span;

  /// Creates a match arm.
  const TMatchCase(
    this.ctorName,
    this.nBinders,
    this.body,
    this.binderNames, {
    this.span = DoxaSpan.synthetic,
  });

  /// True iff this is a wildcard arm (`case _`).
  bool get isWildcard => ctorName.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! TMatchCase ||
        other.ctorName != ctorName ||
        other.nBinders != nBinders ||
        other.body != body) {
      return false;
    }
    // binderNames and span are diagnostic hints; they do not
    // participate in equality or conversion.
    return true;
  }

  @override
  int get hashCode => Object.hash('TMatchCase', ctorName, nBinders, body);

  @override
  String toString() =>
      isWildcard
          ? 'TMatchCase(_, $body)'
          : 'TMatchCase($ctorName^$nBinders, $body)';
}

/// A pattern-match expression.
///
/// Kernel primitive (SPEC §8.5), not desugared to [TRec]. Carries:
///
///   * [scrutinee]: the expression being matched.
///   * [motive]: the return-type family, or **null** if the user
///                   omitted the `returning` clause and the checker
///                   should synthesize the constant motive from the
///                   expected type. When non-null: a `Type`-valued
///                   function of the scrutinee (and its indices, for
///                   indexed families); the type of each arm's body
///                   is obtained by applying the motive to the ctor's
///                   indices + reconstructed value.
///   * [cases]: the arms in source order. ι-reduction
///                   dispatches on a canonical [VConstr] scrutinee by
///                   walking [cases] left-to-right and firing the
///                   first match (exact ctor name or wildcard).
///
/// Invariants maintained by the elaborator:
///   * Every ctor of the scrutinee's data type is covered by exactly
///     one non-wildcard arm, OR a single wildcard arm is present.
///   * Each arm's [TMatchCase.nBinders] matches the ctor's arg count
///     (zero for wildcard).
///   * No two non-wildcard arms share a ctor name.
///
/// Why [motive] is nullable rather than a sentinel term: a null is
/// syntactically distinct from any valid term, so the checker cannot
/// accidentally skip verification of a user-written motive. A
/// sentinel term (e.g. `TType(0)`) would silently match a user who
/// literally wrote `returning Type`, which is a real soundness hole.
///
/// No user-facing surface form uses [TMatch] directly, it is produced
/// only by elaborating [SMatchKind].
final class TMatch extends Term {
  /// The scrutinee expression.
  final Term scrutinee;

  /// The motive, a `Type`-valued function of the scrutinee, or null
  /// if the user did not supply an explicit `returning` clause (in
  /// which case the checker synthesizes the constant motive from the
  /// expected type). See class docstring.
  final Term? motive;

  /// The arms in source order.
  final List<TMatchCase> cases;

  /// Creates a match term.
  const TMatch(this.scrutinee, this.motive, this.cases);

  @override
  bool operator ==(Object other) {
    if (other is! TMatch ||
        other.scrutinee != scrutinee ||
        other.motive != motive ||
        other.cases.length != cases.length) {
      return false;
    }
    for (var i = 0; i < cases.length; i++) {
      if (cases[i] != other.cases[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash('TMatch', scrutinee, motive, Object.hashAll(cases));

  @override
  String toString() => 'TMatch($scrutinee, $motive, $cases)';
}

/// Quotient type formation: `Quot(A, R)` where A is the carrier and
/// R: A → A → Prop is the equivalence relation.
final class TQuot extends Term {
  final Term carrier;
  final Term relation;
  const TQuot(this.carrier, this.relation);

  @override
  bool operator ==(Object other) =>
      other is TQuot && other.carrier == carrier && other.relation == relation;

  @override
  int get hashCode => Object.hash('TQuot', carrier, relation);

  @override
  String toString() => 'TQuot($carrier, $relation)';
}

/// Inject an element into a quotient: `Quot.mk(a)`.
final class TQuotMk extends Term {
  final Term arg;
  const TQuotMk(this.arg);

  @override
  bool operator ==(Object other) => other is TQuotMk && other.arg == arg;

  @override
  int get hashCode => Object.hash('TQuotMk', arg);

  @override
  String toString() => 'TQuotMk($arg)';
}

/// Eliminate from a quotient: `Quot.lift(quot, f, proof)`.
/// f: A → B, proof: (x y: A) → R x y → Eq B (f x) (f y)
final class TQuotLift extends Term {
  final Term quot;
  final Term fn;
  final Term proof;
  const TQuotLift(this.quot, this.fn, this.proof);

  @override
  bool operator ==(Object other) =>
      other is TQuotLift &&
      other.quot == quot &&
      other.fn == fn &&
      other.proof == proof;

  @override
  int get hashCode => Object.hash('TQuotLift', quot, fn, proof);

  @override
  String toString() => 'TQuotLift($quot, $fn, $proof)';
}

// ---------------------------------------------------------------------------
// Locally-nameless binder operations.
// ---------------------------------------------------------------------------

/// Open the outermost binder of [term] by replacing `TBound(0)` with a
/// free variable named [name], decrementing deeper bound indices.
///
/// Use this when descending under a binder during checking: the body of
/// a lambda or Pi has its `TBound(0)` references rewritten to `TFree(name)`
/// so the checker can place `(name, domain)` in the context.
Term openTerm(Term term, String name) => _openAt(term, 0, name);

/// Close a term under a new binder by replacing the free variable named
/// [name] with `TBound(0)`, incrementing deeper bound indices to make
/// room for the new binder.
///
/// Use this when building a [TLam] or [TPi] from a source name that was
/// previously free in the body.
Term closeTerm(Term term, String name) => _closeAt(term, 0, name);

Term _openAt(Term term, int depth, String name) => switch (term) {
  TType() => term,
  TProp() => term,
  TSProp() => term,
  TFree() => term,
  TMeta() => term,
  TBound(:final index) when index == depth => TFree(name),
  TBound(:final index) when index > depth => TBound(index - 1),
  TBound() => term,
  TApp(:final fn, :final arg) => TApp(
    _openAt(fn, depth, name),
    _openAt(arg, depth, name),
  ),
  TLam(:final domain, :final body, name: final n, :final icit) => TLam(
    _openAt(domain, depth, name),
    _openAt(body, depth + 1, name),
    name: n,
    icit: icit,
  ),
  TPi(:final domain, :final codomain, name: final n, :final icit) => TPi(
    _openAt(domain, depth, name),
    _openAt(codomain, depth + 1, name),
    name: n,
    icit: icit,
  ),
  TLet(:final domain, :final bound, :final body, name: final n) => TLet(
    _openAt(domain, depth, name),
    _openAt(bound, depth, name),
    _openAt(body, depth + 1, name),
    name: n,
  ),
  TData(name: final dn, :final args) => TData(dn, [
    for (final a in args) _openAt(a, depth, name),
  ]),
  TConstr(:final dataName, :final ctorName, :final args) => TConstr(
    dataName,
    ctorName,
    [for (final a in args) _openAt(a, depth, name)],
  ),
  TProj(:final expr, :final fieldName) => TProj(
    _openAt(expr, depth, name),
    fieldName,
  ),
  TRec() => term,
  TTop() => term,
  TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
    _openAt(scrutinee, depth, name),
    motive == null ? null : _openAt(motive, depth, name),
    [
      for (final c in cases)
        TMatchCase(
          c.ctorName,
          c.nBinders,
          _openAt(c.body, depth + c.nBinders, name),
          c.binderNames,
          span: c.span,
        ),
    ],
  ),
  TQuot(:final carrier, :final relation) => TQuot(
    _openAt(carrier, depth, name),
    _openAt(relation, depth, name),
  ),
  TQuotMk(:final arg) => TQuotMk(_openAt(arg, depth, name)),
  TQuotLift(:final quot, :final fn, :final proof) => TQuotLift(
    _openAt(quot, depth, name),
    _openAt(fn, depth, name),
    _openAt(proof, depth, name),
  ),
};

Term _closeAt(Term term, int depth, String name) => switch (term) {
  TType() => term,
  TProp() => term,
  TSProp() => term,
  TMeta() => term,
  TFree(name: final n) when n == name => TBound(depth),
  TFree() => term,
  TBound(:final index) when index >= depth => TBound(index + 1),
  TBound() => term,
  TApp(:final fn, :final arg) => TApp(
    _closeAt(fn, depth, name),
    _closeAt(arg, depth, name),
  ),
  TLam(:final domain, :final body, name: final n, :final icit) => TLam(
    _closeAt(domain, depth, name),
    _closeAt(body, depth + 1, name),
    name: n,
    icit: icit,
  ),
  TPi(:final domain, :final codomain, name: final n, :final icit) => TPi(
    _closeAt(domain, depth, name),
    _closeAt(codomain, depth + 1, name),
    name: n,
    icit: icit,
  ),
  TLet(:final domain, :final bound, :final body, name: final n) => TLet(
    _closeAt(domain, depth, name),
    _closeAt(bound, depth, name),
    _closeAt(body, depth + 1, name),
    name: n,
  ),
  TData(name: final dn, :final args) => TData(dn, [
    for (final a in args) _closeAt(a, depth, name),
  ]),
  TConstr(:final dataName, :final ctorName, :final args) => TConstr(
    dataName,
    ctorName,
    [for (final a in args) _closeAt(a, depth, name)],
  ),
  TProj(:final expr, :final fieldName) => TProj(
    _closeAt(expr, depth, name),
    fieldName,
  ),
  TRec() => term,
  TTop() => term,
  TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
    _closeAt(scrutinee, depth, name),
    motive == null ? null : _closeAt(motive, depth, name),
    [
      for (final c in cases)
        TMatchCase(
          c.ctorName,
          c.nBinders,
          _closeAt(c.body, depth + c.nBinders, name),
          c.binderNames,
          span: c.span,
        ),
    ],
  ),
  TQuot(:final carrier, :final relation) => TQuot(
    _closeAt(carrier, depth, name),
    _closeAt(relation, depth, name),
  ),
  TQuotMk(:final arg) => TQuotMk(_closeAt(arg, depth, name)),
  TQuotLift(:final quot, :final fn, :final proof) => TQuotLift(
    _closeAt(quot, depth, name),
    _closeAt(fn, depth, name),
    _closeAt(proof, depth, name),
  ),
};
