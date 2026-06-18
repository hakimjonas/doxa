/// Bidirectional type checker error types.
///
/// The [infer] and [check] functions live in `eval.dart` alongside the
/// unified driver, integration there is what guarantees the checker's
/// depth is bounded by the driver's frame stack, not the host call stack.
/// This file declares the structured error types those functions raise.
///
/// A higher layer wraps these with source spans to form user-facing
/// diagnostics.
library;

import 'surface.dart' show DoxaSpan;
import 'value.dart';

// Re-export the ConvMismatch referenced by TypeMismatch. The actual
// ConvMismatch class lives in eval.dart; this import makes it visible
// from callers that only import check.dart.
export 'eval.dart' show ConvMismatch, check, infer;

/// A kernel-level type-checking error.
///
/// These errors carry no source spans. The full [DoxaError] hierarchy
/// with spans wraps these for user-facing diagnostics.
sealed class DoxaCheckError implements Exception {
  /// Base constructor.
  const DoxaCheckError();
}

/// The inferred type did not match the expected type.
///
/// [level] is the de Bruijn level of the context at which [got] and
/// [expected] are live. The renderer uses it to seed the pretty-
/// printer's outer-binder count so that free variables at depths
/// `< level` quote to valid placeholders (`?a`, `?b`, …) instead of
/// the negative-index lie `?-N` they'd produce under a level-0
/// assumption.
///
/// SPEC §6.2 commits to rendering the user's original binder names
/// (e.g. `A` for `fun id[A: Type]...`). Tier 1 of that commitment
/// not-lying placeholders for outer binders, is delivered via this
/// field. Tier 2 (propagating actual user names through the Ctx into
/// errors, so `?a` becomes `A`) is future work, since it touches Ctx
/// shape and interacts with metavariable scoping.
final class TypeMismatch extends DoxaCheckError {
  /// The type that was inferred for the term.
  final Value got;

  /// The type that was expected by the context.
  final Value expected;

  /// The underlying conv mismatch; the innermost diverging pair.
  final Object innerMismatch;

  /// The Ctx level at which the mismatch was raised.
  final int level;

  /// The source span of the offending sub-expression, when the error is
  /// raised during elaboration (where the surface AST node, and thus its
  /// span, is in scope). Null when raised from the span-free kernel
  /// `check`/`infer` pass. Diagnostic-only: it never affects typing,
  /// conversion, or equality, the kernel stays span-free, and this field
  /// is the elaborator's contribution to the source-to-semantic map. The
  /// reporter prefers this span over the enclosing declaration's when
  /// present, so the caret lands on the offending term.
  final DoxaSpan? span;

  /// Creates a type mismatch error. [innerMismatch] is typed as [Object]
  /// here to avoid a circular import with `eval.dart`; callers can cast
  /// it to [ConvMismatch] (re-exported from this library) when needed.
  const TypeMismatch(
    this.got,
    this.expected,
    this.innerMismatch, {
    this.level = 0,
    this.span,
  });

  /// Returns a copy of this error carrying [span], unless a span is
  /// already set (the innermost attach wins, the elaborator attaches at
  /// the deepest sub-expression that threw, and re-throws on the way out
  /// must not overwrite it with a wider enclosing span).
  TypeMismatch withSpan(DoxaSpan span) =>
      this.span != null
          ? this
          : TypeMismatch(
            got,
            expected,
            innerMismatch,
            level: level,
            span: span,
          );

  @override
  String toString() =>
      'TypeMismatch(got: $got, expected: $expected, '
      'innerMismatch: $innerMismatch, level: $level, span: $span)';
}

/// A term was applied where a function type was required, but the
/// inferred type was not a [VPi].
final class NotAFunction extends DoxaCheckError {
  /// The type of the non-function term being applied.
  final Value actualType;

  /// Creates a not-a-function error.
  const NotAFunction(this.actualType);

  @override
  String toString() => 'NotAFunction(actualType: $actualType)';
}

/// A position that required a type yielded a term whose type was not a
/// [VType]. For example, the domain of a Pi must have type [VType(n)].
final class NotAType extends DoxaCheckError {
  /// The type of the non-type term.
  final Value actualType;

  /// Creates a not-a-type error.
  const NotAType(this.actualType);

  @override
  String toString() => 'NotAType(actualType: $actualType)';
}

/// A [TFree] reached the checker. [TFree] is only emitted by elaboration
/// as a placeholder; the elaborator must close all binders before handing
/// off to the checker.
final class UnexpectedFree extends DoxaCheckError {
  /// The source name of the free variable.
  final String name;

  /// Creates an unexpected-free-variable error.
  const UnexpectedFree(this.name);

  @override
  String toString() => 'UnexpectedFree(name: $name)';
}

/// A reference to an inductive type or constructor could not be resolved.
///
/// Raised by the checker when a [TData] or [TConstr] term references a
/// name that is not in the registry. This indicates an elaborator bug
/// (the elaborator should reject unresolved names before they reach
/// the checker) or a program produced outside the elaborator.
final class UnknownDataOrCtor extends DoxaCheckError {
  /// The inductive type's name.
  final String dataName;

  /// The constructor's name, or null if the reference was to the data
  /// type itself.
  final String? ctorName;

  /// Creates an unknown-data-or-ctor error.
  const UnknownDataOrCtor(this.dataName, [this.ctorName]);

  @override
  String toString() =>
      ctorName == null
          ? 'UnknownDataOrCtor(data: $dataName)'
          : 'UnknownDataOrCtor(ctor: $dataName.$ctorName)';
}

/// A [TData] or [TConstr] was applied to the wrong number of arguments.
///
/// An inductive type `T[params] : indices -> sort` must be applied to
/// exactly `params.length + indices.length` arguments to be a
/// well-formed type expression. A constructor with telescope
/// `(params; ctorArgs)` must be applied to exactly
/// `params.length + ctorArgs.length` arguments.
final class InductiveArityMismatch extends DoxaCheckError {
  /// The inductive type's name.
  final String dataName;

  /// The constructor's name, or null for a [TData] arity error.
  final String? ctorName;

  /// The number of arguments actually supplied.
  final int gotArity;

  /// The expected number of arguments.
  final int expectedArity;

  /// Creates an inductive-arity mismatch error.
  const InductiveArityMismatch({
    required this.dataName,
    this.ctorName,
    required this.gotArity,
    required this.expectedArity,
  });

  @override
  String toString() =>
      ctorName == null
          ? 'InductiveArityMismatch(data: $dataName, got: $gotArity, expected: $expectedArity)'
          : 'InductiveArityMismatch(ctor: $dataName.$ctorName, got: $gotArity, expected: $expectedArity)';
}

/// A `match` expression appeared in a position where its type could
/// not be inferred (i.e. there was no expected type from the
/// surrounding check context), and the user did not supply an
/// explicit `returning` clause.
///
/// With metavariables, the motive is inferred from the expected type
/// when one is available; this error fires only when neither an
/// expected type nor an explicit `returning` clause is present.
final class MatchMotiveRequired extends DoxaCheckError {
  /// Creates the error.
  const MatchMotiveRequired();

  @override
  String toString() => 'MatchMotiveRequired()';
}

/// A `match` arm named a constructor of the wrong inductive type, the
/// scrutinee's inferred type is different from the arm's ctor's
/// parent data type.
///
/// Example: `match (n: Nat) { case true_ => ... }`, `true_` belongs
/// to `Bool`, not `Nat`.
///
/// Detected at check-time (the elaborator itself can't know the
/// scrutinee's actual inferred type; it only infers "from the first
/// ctor arm" which gives a *candidate*; disagreements between the
/// candidate and the real inferred type surface here).
///
/// Carries the arm's source span so the diagnostic can point at the
/// offending arm (not the whole declaration). [armCtorDataName]
/// is empty when the ctor is not registered anywhere.
final class ScrutineeTypeMismatchesArm extends DoxaCheckError {
  /// The ctor named in the offending arm.
  final String armCtorName;

  /// The inductive type the ctor actually belongs to, or empty if
  /// the ctor is unregistered.
  final String armCtorDataName;

  /// The inductive type inferred for the scrutinee.
  final String scrutineeDataName;

  /// The arm's source span.
  final DoxaSpan? armSpan;

  /// Creates the error.
  const ScrutineeTypeMismatchesArm(
    this.armCtorName,
    this.armCtorDataName,
    this.scrutineeDataName,
    this.armSpan,
  );

  @override
  String toString() =>
      'ScrutineeTypeMismatchesArm($armCtorName of $armCtorDataName vs '
      'scrutinee: $scrutineeDataName)';
}

/// A `match`'s scrutinee had a type that was not an inductive type
/// (not a `VData`). For example, matching on a lambda or a universe.
final class MatchScrutineeNotInductive extends DoxaCheckError {
  /// The scrutinee's inferred type (which wasn't a VData).
  final Value actualType;

  /// Creates the error.
  const MatchScrutineeNotInductive(this.actualType);

  @override
  String toString() => 'MatchScrutineeNotInductive($actualType)';
}

/// Check-time coverage error for an indexed-family match: at least
/// one uncovered constructor is reachable given the scrutinee's
/// actual indices, so the match is not exhaustive.
///
/// Elaboration defers coverage for indexed data because the
/// scrutinee's index values are only known at check time (e.g.
/// `Vec[A] (succ n)` has `(succ n)` as its index, which refines
/// reachability per ctor). Check-time unreachability detection uses
/// first-order ctor-head clash: if a ctor's result-index position
/// has a different head than the scrutinee's index position, that
/// ctor is unreachable and may be omitted. Anything else requires
/// full unification.
///
/// [missingReachableCtors] lists the uncovered ctors that the
/// first-order check could NOT rule out as unreachable. The user
/// must either add arms for them or a wildcard, or (if they believe
/// the case actually is unreachable but the first-order check can't
/// prove it) rely on richer unification, which is not yet available
/// here.
final class IndexedMatchNotExhaustive extends DoxaCheckError {
  /// The scrutinee's inductive type name.
  final String dataName;

  /// Constructors not covered that are reachable under the scrutinee's
  /// actual indices.
  final List<String> missingReachableCtors;

  /// Creates the error.
  const IndexedMatchNotExhaustive(this.dataName, this.missingReachableCtors);

  @override
  String toString() =>
      'IndexedMatchNotExhaustive($dataName, '
      'missing: $missingReachableCtors)';
}

/// SPEC §8.2 Prop-elim restriction: a match on a Prop-sorted inductive
/// cannot produce a Type-sorted result without the singleton-elimination
/// exception. Accepting Prop → Type would leak information from the
/// proof world into the computational world, combined with
/// definitional proof irrelevance this is a direct path to
/// inconsistency (two distinct proofs of the same Prop would compute
/// to distinct Type-values, contradicting reflexivity).
///
/// The singleton exception (allow Prop → Type when the inductive has
/// ≤ 1 ctor and that ctor carries no informative args) is what lets
/// `Eq` live at Prop sort, without it, `Eq.rec` over Prop-valued
/// propositions can't transport Type-sorted goals, which is the
/// standard CIC shape for equality reasoning. This error fires when
/// the elimination is Prop → Type and the singleton exception does
/// not apply.
///
/// Diagnostic cites the scrutinee's data name and the result's
/// inferred sort so the user can see exactly where the barrier sits.
final class PropEliminationIntoType extends DoxaCheckError {
  /// The Prop-sorted inductive the match scrutinised.
  final String dataName;

  /// The inferred sort of the match's result (`Type n` or a stuck
  /// neutral, rendered by the diagnostic layer).
  final Value resultSort;

  /// Creates the error.
  const PropEliminationIntoType(this.dataName, this.resultSort);

  @override
  String toString() =>
      'PropEliminationIntoType($dataName, result sort: $resultSort)';
}
