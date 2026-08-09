/// Elaboration: surface AST → kernel [Term].
///
/// The elaborator resolves source names to de Bruijn indices, desugars
/// `fun` declarations to value-level lambdas and Pi types, and desugars
/// multi-argument applications into nested unary applications. It also
/// performs basic scope checks that the checker cannot:
///
///   * [UnresolvedName] when an identifier doesn't name any binder or
///     earlier top-level declaration.
///   * [DuplicateDeclaration] when a name is redeclared at the top level.
///
/// ## Scope discipline
///
/// Top-level scope is sequential: a declaration sees every earlier
/// declaration. `val`/`type` bodies are non-recursive (the bound name
/// is not in scope in its own body), while a `fun` IS in scope in its
/// own body, with the structural-recursion guard (SPEC §8.6) ensuring
/// soundness; mutual `fun` / `data` blocks put every member in scope
/// in every body.
///
/// Block-scoped parameters (binders introduced by lambdas, Pis, and
/// `fun` parameters) follow standard sequential scope: each binder
/// shadows any earlier binding of the same name within its body.
library;

import 'dart:io';

import 'package:rumil/rumil.dart' show ParseError, Success, Partial, Failure;

import 'check.dart' show TypeMismatch;
import 'ctx.dart';
import 'env.dart';
import 'eval.dart';
import 'meta.dart';
import 'parse.dart' show parseProgram;
import 'pretty.dart';
import 'registry.dart';
import 'sem_info.dart';
import 'surface.dart';
import 'tactic.dart' hide conv;
import 'term.dart';
import 'value.dart';

export 'registry.dart';

// Level constants (universe polymorphism).
const _l0 = LLevel(0);
const _l1 = LLevel(1);
const _vType0 = VType(_l0);
const _vType1 = VType(_l1);

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// A kernel-level elaboration error.
sealed class ElabError implements Exception {
  /// Base constructor.
  const ElabError();

  /// The span in source where this error occurred.
  DoxaSpan get span;
}

/// An identifier doesn't name any binder or earlier top-level declaration.
final class UnresolvedName extends ElabError {
  /// The unresolved name.
  final String name;

  /// The location of the offending reference.
  @override
  final DoxaSpan span;

  /// Creates an unresolved-name error.
  const UnresolvedName(this.name, this.span);

  @override
  String toString() => 'UnresolvedName($name @ $span)';
}

/// A recursive call in a `fun` body did not pass a strict sub-term
/// of the function's designated decreasing argument.
///
/// The elaborator enforces CIC's structural-recursion rule
/// (SPEC §8.6): recursion is accepted iff every call to the function
/// (or any sibling in the same mutual block) passes, in the
/// function's designated-decreasing-argument position, a value that
/// is a syntactic strict sub-term of the caller's designated
/// argument.
///
/// Convention:
///   * The designated argument is the first explicit value-level
///     `fun` parameter (type-parameter binders don't count).
///   * A strict sub-term is a pattern binder introduced by
///     `match`ing on the designated argument, transitively, a
///     binder from a sub-match on a sub-term is itself a sub-term.
///   * Unapplied references to a recursive function (e.g. passing
///     `f` as a value) are rejected: the eventual call site may not
///     respect the structural rule, and the check can't verify it
///     up-front.
///
/// Raised by [_checkStructuralRecursion] before any body is
/// elaborated; the CLI / test harnesses then consume a
/// [CorecursiveGroup] to pre-scope co-recursive members in Ctx
/// before type-checking their bodies.
final class NonStructuralRecursion extends ElabError {
  /// The name of the recursive function (or mutual-block sibling).
  final String calleeName;

  /// The source span of the offending call.
  @override
  final DoxaSpan span;

  /// Creates a non-structural-recursion error.
  const NonStructuralRecursion(this.calleeName, this.span);

  @override
  String toString() => 'NonStructuralRecursion($calleeName @ $span)';
}

/// A cross-call from one mutual-block member to another, collected
/// during the structural-recursion walk. Used by cycle-aware analysis
/// to distinguish "unguarded edge that is part of a true cycle" from
/// "unguarded edge in an acyclic graph" (which is valid mutual recursion).
final class _CrossCall {
  final String caller;
  final String callee;
  final DoxaSpan span;
  const _CrossCall(this.caller, this.callee, this.span);
}

/// The `{struct <name>}` annotation references a parameter that does not
/// exist in the function's value parameter list.
final class StructAnnotationNotFound extends ElabError {
  /// The function name.
  final String funName;

  /// The annotated parameter name.
  final String paramName;

  /// The source span of the annotation.
  @override
  final DoxaSpan span;

  /// Creates a struct-annotation-not-found error.
  const StructAnnotationNotFound(this.funName, this.paramName, this.span);

  @override
  String toString() =>
      'StructAnnotationNotFound: fun $funName has no parameter '
      'named $paramName';
}

/// The member.
final class TerminationByParamNotFound extends ElabError {
  /// The function name.
  final String funName;

  /// The annotated parameter name.
  final String paramName;

  /// The source span of the annotation.
  @override
  final DoxaSpan span;

  /// Creates a termination-by-param-not-found error.
  const TerminationByParamNotFound(this.funName, this.paramName, this.span);

  /// Human-readable error message.
  String get message =>
      'termination_by parameter "$paramName" not found '
      'in value parameters of fun "$funName"';

  @override
  String toString() =>
      'TerminationByParamNotFound: fun $funName has no value parameter '
      'named $paramName';
}

/// A `match` expression has no ctor case AND no explicit `returning`
/// clause, so the elaborator cannot determine the scrutinee's inductive
/// type. Elaboration requires *either* at least one constructor
/// arm (which reveals the data type via the globally-unique ctor name)
/// *or* an explicit motive annotation. Wildcard-only matches without
/// a motive cannot be typed at elaboration time.
///
/// Meta-variables remove this restriction where an expected type is
/// available: the motive becomes a solvable metavariable and the
/// scrutinee's type is determined by context.
final class MatchIndeterminateType extends ElabError {
  @override
  final DoxaSpan span;

  /// Creates the error.
  const MatchIndeterminateType(this.span);

  @override
  String toString() => 'MatchIndeterminateType(@ $span)';
}

/// A `match` case named a constructor that is not registered in any
/// inductive type.
final class UnknownCtorInMatch extends ElabError {
  /// The offending ctor name.
  final String ctorName;

  @override
  final DoxaSpan span;

  /// Creates the error.
  const UnknownCtorInMatch(this.ctorName, this.span);

  @override
  String toString() => 'UnknownCtorInMatch($ctorName @ $span)';
}

/// A `match` case named a constructor that is registered but belongs
/// to a different inductive type than the scrutinee's.
///
/// Example: `match (n: Nat) { case nil => zero case succ p => p }`
/// `nil` belongs to `List`, not `Nat`.
final class CtorMismatchInMatch extends ElabError {
  /// The ctor named in the arm.
  final String ctorName;

  /// The inductive the ctor actually belongs to.
  final String ctorDataName;

  /// The inductive the match is scrutinising (inferred from the first
  /// ctor arm, or from the explicit motive).
  final String scrutineeDataName;

  @override
  final DoxaSpan span;

  /// Creates the error.
  const CtorMismatchInMatch(
    this.ctorName,
    this.ctorDataName,
    this.scrutineeDataName,
    this.span,
  );

  @override
  String toString() =>
      'CtorMismatchInMatch($ctorName of $ctorDataName, '
      'but scrutinee is $scrutineeDataName @ $span)';
}

/// A `match` arm's pattern bound a different number of variables than
/// the constructor's argument count.
final class MatchArmArityMismatch extends ElabError {
  /// The ctor name.
  final String ctorName;

  /// The number of binders the user wrote.
  final int gotBinders;

  /// The ctor's expected non-param arg count.
  final int expectedBinders;

  @override
  final DoxaSpan span;

  /// Creates the error.
  const MatchArmArityMismatch(
    this.ctorName,
    this.gotBinders,
    this.expectedBinders,
    this.span,
  );

  @override
  String toString() =>
      'MatchArmArityMismatch($ctorName: got $gotBinders binders, '
      'expected $expectedBinders @ $span)';
}

/// A `match` expression had two arms for the same constructor.
final class DuplicateMatchCase extends ElabError {
  /// The repeated ctor name.
  final String ctorName;

  /// The span of the first occurrence (for the diagnostic).
  final DoxaSpan firstSpan;

  @override
  final DoxaSpan span;

  /// Creates the error.
  const DuplicateMatchCase(this.ctorName, this.firstSpan, this.span);

  @override
  String toString() =>
      'DuplicateMatchCase($ctorName, first @ $firstSpan, again @ $span)';
}

/// A `match` did not cover every constructor of the scrutinee's
/// inductive type, and did not have a wildcard case to cover the rest.
final class NonExhaustiveMatch extends ElabError {
  /// The inductive type's name.
  final String dataName;

  /// The constructor names that weren't handled.
  final List<String> missingCtors;

  @override
  final DoxaSpan span;

  /// Creates the error.
  const NonExhaustiveMatch(this.dataName, this.missingCtors, this.span);

  @override
  String toString() =>
      'NonExhaustiveMatch($dataName, missing: $missingCtors @ $span)';
}

/// Thrown when an unannotated lambda `(x) => body` appears in a position
/// where its parameter type cannot be inferred (infer mode). Such a
/// lambda only elaborates in check mode against an explicit `Pi`, whose
/// domain supplies the parameter type.
final class LambdaRequiresAnnotation extends ElabError {
  /// The lambda parameter's name.
  final String name;

  /// The location of the offending lambda.
  @override
  final DoxaSpan span;

  /// Creates a missing-lambda-annotation error.
  const LambdaRequiresAnnotation(this.name, this.span);

  @override
  String toString() => 'LambdaRequiresAnnotation($name @ $span)';
}

/// A `data` declaration's target sort was not `Type n` or `Prop`.
///
/// Doxa inductive types live in one of the two sort families. A
/// signature like `data T : (n: Nat) -> Nat { ... }` has a final
/// codomain `Nat`, which is a type but not a sort, the elaborator
/// rejects it here so the kernel never sees a data type whose target
/// isn't a universe.
final class DataSortNotASort extends ElabError {
  /// The inductive type's name.
  final String dataName;

  /// The source location of the signature.
  @override
  final DoxaSpan span;

  /// Creates a bad-sort error.
  const DataSortNotASort(this.dataName, this.span);

  @override
  String toString() =>
      'DataSortNotASort($dataName: signature must end in Type n, Prop, or SProp @ $span)';
}

/// An SProp-inductive's constructor field is not SProp-sorted.
///
/// SProp inductives can only carry SProp-sorted fields; non-SProp fields
/// (Type-sorted or Prop-sorted data) are rejected.
final class SPropFieldNotProofIrrelevant extends ElabError {
  /// The field name.
  final String fieldName;

  /// The source location.
  @override
  final DoxaSpan span;

  /// Creates a non-SProp-field error.
  const SPropFieldNotProofIrrelevant(this.fieldName, this.span);

  @override
  String toString() =>
      'SPropFieldNotProofIrrelevant($fieldName: SProp-inductive fields '
      'must be SProp-sorted @ $span)';
}

/// A mutual-data block has a cycle in its header dependencies.
///
/// Forward-referencing headers are admitted via topological ordering,
/// `data A : B -> Type and data B : Type` elaborates (B first, then
/// A). Strict cycles like `data A : B -> Type and data B : A -> Type`
/// remain rejected: their signatures have no finite elaboration order.
/// Meta-driven signature elaboration (fresh metas for each forward-ref)
/// would handle these; absent that, we raise this error.
final class MutualHeaderCycle extends ElabError {
  /// The data names participating in the cycle, in reference order.
  final List<String> cycle;

  /// The span of the first member in the cycle.
  @override
  final DoxaSpan span;

  /// Creates a cycle error.
  const MutualHeaderCycle(this.cycle, this.span);

  @override
  String toString() => 'MutualHeaderCycle(${cycle.join(' → ')} @ $span)';
}

/// A constructor's argument type mentions the inductive type being
/// declared in a strictly-negative position.
///
/// Strict positivity: the inductive type may appear on the right of
/// arrows (subterm recursion) but not on the left (negative position).
/// Without this check, programs can encode non-terminating recursion
/// at the type level and break CIC soundness.
///
/// The canonical counterexample is `data Bad { bad : (Bad -> Bad) -> Bad }`:
/// the argument type `Bad -> Bad` has `Bad` on the left of an arrow.
///
/// The strict-positivity check: an occurrence of `T` is allowed at
/// the head of a positive-position application (`T args`, with `T`
/// absent from `args`), or nested in another inductive `S args` where
/// `S` is **covariant** in every slot that mentions `T` (computed
/// per-parameter for each registered inductive; see
/// [DataDecl.paramsCovariant]). All other occurrences, negative
/// positions under Pi, or positions inside a non-covariant slot,
/// are rejected.
///
/// Canonical accepted shapes:
///   * `T -> T` (self, positive)
///   * `List[T]` with `List` covariant in its arg (nested positivity)
///
/// Canonical rejected shapes:
///   * `(T -> X) -> T` (self-negative)
///   * `NonCov[T]` where `NonCov` takes `A` in a negative position
///     (so `T` occupies a non-covariant slot).
final class PositivityViolation extends ElabError {
  /// The parent inductive type's name.
  final String dataName;

  /// The offending constructor's name.
  final String ctorName;

  /// The 0-based index of the argument whose type fails positivity.
  final int argIndex;

  /// The source location of the constructor declaration.
  @override
  final DoxaSpan span;

  /// Creates a positivity-violation error.
  const PositivityViolation(
    this.dataName,
    this.ctorName,
    this.argIndex,
    this.span,
  );

  @override
  String toString() =>
      'PositivityViolation($dataName.$ctorName, arg $argIndex @ $span)';
}

/// A constructor's type does not end in the inductive type being
/// declared, with the expected argument shape.
///
/// Every constructor of `data T[params] : indices -> sort { ... }`
/// must have a type whose final codomain is `T[params_given] indices_given`,
/// i.e., `T` applied to exactly (params.length + indices.length) arguments.
/// The elaborator rejects constructors whose final codomain has the
/// wrong shape (different head, or wrong arity).
final class CtorResultShapeMismatch extends ElabError {
  /// The parent inductive type's name.
  final String dataName;

  /// The offending constructor's name.
  final String ctorName;

  /// The source location of the constructor declaration.
  @override
  final DoxaSpan span;

  /// A human-readable description of what was wrong.
  final String reason;

  /// Creates a constructor-result-shape error.
  const CtorResultShapeMismatch(
    this.dataName,
    this.ctorName,
    this.span,
    this.reason,
  );

  @override
  String toString() =>
      'CtorResultShapeMismatch($dataName.$ctorName @ $span: $reason)';
}

/// A name was declared more than once at the top level.
final class DuplicateDeclaration extends ElabError {
  /// The declared name.
  final String name;

  /// The location of the first (original) declaration.
  final DoxaSpan previousSpan;

  /// The location of the redeclaration.
  @override
  final DoxaSpan span;

  /// Creates a duplicate-declaration error.
  const DuplicateDeclaration(this.name, this.previousSpan, this.span);

  @override
  String toString() =>
      'DuplicateDeclaration($name, previous: $previousSpan, redeclared: $span)';
}

/// A `import` statement references a file that has already been
/// imported (directly or transitively) in the current chain.
final class CyclicImport extends ElabError {
  /// The resolved file path forming the cycle.
  final String path;

  /// The source span of the offending `import` declaration.
  @override
  final DoxaSpan span;

  /// Creates a cyclic-import error.
  const CyclicImport(this.path, this.span);

  @override
  String toString() => 'CyclicImport($path @ $span)';
}

/// The file referenced by an `import` declaration does not exist.
final class ImportFileNotFound extends ElabError {
  /// The resolved file path that could not be found.
  final String path;

  /// The source span of the offending `import` declaration.
  @override
  final DoxaSpan span;

  /// Creates a file-not-found error.
  const ImportFileNotFound(this.path, this.span);

  @override
  String toString() => 'ImportFileNotFound($path @ $span)';
}

/// A tactic block `by { ... }` failed during elaboration.
final class TacticFailed extends ElabError {
  /// The failure message from the tactic engine.
  final String message;

  /// The source span of the `by` block.
  @override
  final DoxaSpan span;

  /// Creates a tactic failure error.
  const TacticFailed(this.message, this.span);

  @override
  String toString() => 'TacticFailed($message @ $span)';
}

/// A tactic block `by { ... }` finished but did not solve the goal.
final class TacticIncomplete extends ElabError {
  /// The source span of the `by` block.
  @override
  final DoxaSpan span;

  /// Creates an incomplete-tactic error.
  const TacticIncomplete(this.span);

  @override
  String toString() => 'TacticIncomplete(@ $span)';
}

/// No instance of a typeclass was found for the given type.
final class NoInstanceFound extends ElabError {
  /// The typeclass name.
  final String className;

  /// The type that needed an instance.
  final String targetType;

  /// The source location.
  @override
  final DoxaSpan span;

  /// Creates a no-instance-found error.
  const NoInstanceFound(this.className, this.targetType, this.span);

  @override
  String toString() => 'NoInstanceFound($className for $targetType @ $span)';
}

/// Multiple overlapping instances were found for the same type.
final class OverlappingInstances extends ElabError {
  /// The typeclass name.
  final String className;

  /// The type that had multiple matching instances.
  final String targetType;

  /// The instance names that overlap.
  final List<String> instanceNames;

  /// The source location.
  @override
  final DoxaSpan span;

  /// Creates an overlapping-instances error.
  const OverlappingInstances(
    this.className,
    this.targetType,
    this.instanceNames,
    this.span,
  );

  @override
  String toString() =>
      'OverlappingInstances($className for $targetType: '
      '${instanceNames.join(", ")} @ $span)';
}

// ---------------------------------------------------------------------------
// Typeclass / instance registry
// ---------------------------------------------------------------------------

/// Metadata about a registered typeclass.
final class ClassInfo {
  /// The typeclass name (e.g. "Eq").
  final String className;

  /// The type parameter names (e.g. ["A"]).
  final List<String> typeParams;

  /// The method names and their surface types.
  final List<(String, SExpr)> methods;

  /// Optional superclass name.
  final String? superclassName;

  /// Registered instances for this class.
  final List<InstanceInfo> instances;

  /// Creates class info.
  const ClassInfo({
    required this.className,
    required this.typeParams,
    required this.methods,
    this.superclassName,
    this.instances = const [],
  });

  /// The member.
  ClassInfo withInstance(InstanceInfo info) => ClassInfo(
    className: className,
    typeParams: typeParams,
    methods: methods,
    superclassName: superclassName,
    instances: [...instances, info],
  );
}

/// A registered instance of a typeclass.
final class InstanceInfo {
  /// The target type name (e.g. "Int").
  final String targetType;

  /// The binding name of the instance value.
  final String bindingName;

  /// Creates instance info.
  const InstanceInfo(this.targetType, this.bindingName);
}

// ---------------------------------------------------------------------------
// Import state
// ---------------------------------------------------------------------------

/// The absolute path of the file currently being elaborated, used to
/// resolve relative import paths. Set by the pipeline before elaboration.
String? currentImportPath;

/// Stack of import paths currently being processed, for cycle detection.
final _importStack = <String>[];

/// Set of paths that have already been fully imported in the current
/// pipeline run. Used to make repeated imports of the same file
/// idempotent. Reset before processing each new top-level file.
final importedPaths = <String>{};

/// Resolve an import path relative to the current file's directory.
String _resolveImportPath(String importPath, String currentFile) {
  final current = Uri.file(currentFile);
  final resolved = current.resolve(importPath);
  return resolved.toFilePath();
}

/// Derive module prefix from file path: "nat.doxa" → "Nat",
/// "foo/bar.doxa" → "Bar".
String _modulePrefix(String path) {
  final filename = path.split('/').last.split('\\').last;
  final stem =
      filename.endsWith('.doxa')
          ? filename.substring(0, filename.length - '.doxa'.length)
          : filename;
  if (stem.isEmpty) return stem;
  return stem[0].toUpperCase() + stem.substring(1);
}

// ---------------------------------------------------------------------------
// Local scope
// ---------------------------------------------------------------------------

/// A cons-list of locally bound names, most-recently-bound at the head.
///
/// de Bruijn index i refers to the i-th entry from the head. Lookups are
/// linear, but lookups happen once per name reference in source, which
/// is bounded by source size, not by anything the checker or evaluator
/// does.
sealed class _LocalScope {
  const _LocalScope();

  /// Push [name] as the new innermost binding.
  _LocalScope push(String name) => _LocalCons(name, this);

  /// Return the de Bruijn index of [name], or -1 if not bound locally.
  int indexOf(String name) {
    var i = 0;
    var s = this;
    while (true) {
      switch (s) {
        case _LocalNil():
          return -1;
        case _LocalCons(:final name_, :final rest):
          if (name_ == name) return i;
          i += 1;
          s = rest;
      }
    }
  }
}

final class _LocalNil extends _LocalScope {
  const _LocalNil();
}

final class _LocalCons extends _LocalScope {
  // The binder name. Trailing-underscore to avoid shadowing `name` in
  // the enclosing class's `indexOf`.
  final String name_;
  final _LocalScope rest;
  const _LocalCons(this.name_, this.rest);
}

/// A single `fun` binder (type-param or value-param) after
/// normalization. Type-params with icity `implicit` come
/// from the source `{A: Type}` form; everything else is explicit.
final class _FunBinder {
  /// The binder's source name.
  final String name;

  /// The binder's kind / value type annotation.
  final SExpr type;

  /// Explicit vs. implicit. Implicits are elided at call
  /// sites and filled in by unification.
  final Icit icit;

  const _FunBinder(this.name, this.type, this.icit);
}

// ---------------------------------------------------------------------------
// Elaborator state (bidirectional)
// ---------------------------------------------------------------------------

/// The bundle of state threaded through the bidirectional elaborator.
///
/// Holds:
///   * [topEnv]: the surface-side view of the current program, needed
///     for name resolution (`SIdentKind`/`SDotKind`), data-registry
///     lookups, and the scratch-env machinery used when elaborating
///     mutual-block members.
///   * [ctx]: the kernel-side typing context: owns the parallel
///     [Env], local types, the inductive registry, and the shared
///     [MetaContext]. Extended in lock-step with
///     [names] whenever a binder is introduced.
///   * [names]: the elaborator-local name stack used to turn source
///     identifiers into de Bruijn indices. Kept separate from [ctx]
///     because the kernel does not need names and the checker path
///     would pay for a parallel name list on every extension.
///
/// Populated and consumed as each syntactic form is elaborated through
/// `_inferExpr` / `_checkExpr`.
final class _ElabState {
  /// The current top-level environment.
  final TopEnv topEnv;

  /// The kernel typing context (includes env, metas, dataDecls).
  final Ctx ctx;

  /// The elaborator-local name stack (de Bruijn resolution).
  final _LocalScope names;

  const _ElabState(this.topEnv, this.ctx, this.names);

  /// Extend state with a new binder [name] of [type]. The [ctx] gains
  /// a fresh neutral at the current level; [names] gains the name at
  /// the head so [lookupLocal] returns index 0 for it.
  _ElabState push(String name, Value type) =>
      _ElabState(topEnv, ctx.extend(type), names.push(name));

  /// Extend state with a let-bound binder whose type and concrete
  /// [value] are both known (the `_inferExpr(SLet)` path). Uses
  /// [Ctx.extendWith] so subsequent
  /// `_inferExpr` calls evaluate the body under an env carrying the
  /// actual bound value; the body's inferred type is then already
  /// correct in the outer scope without a post-hoc substitution.
  _ElabState pushWith(String name, Value type, Value value) =>
      _ElabState(topEnv, ctx.extendWith(type, value), names.push(name));

  /// Look up a local [name]: returns (index, type) or null if it does
  /// not name a local binder. The index is a de Bruijn index into
  /// [ctx]; the type is the value-level type bound there.
  (int, Value)? lookupLocal(String name) {
    final i = names.indexOf(name);
    if (i < 0) return null;
    return (i, ctx.lookupType(i));
  }
}

// ---------------------------------------------------------------------------
// Top-level environment
// ---------------------------------------------------------------------------

/// A single entry in the top-level environment produced by elaboration.
///
/// Top-level bindings are definitions with a declared [type] and a
/// fully-elaborated [term] body. The elaborator also publishes the
/// [span] at which the name was declared, to support
/// [DuplicateDeclaration] diagnostics.
final class TopBinding {
  /// The declared name.
  final String name;

  /// The type Term (already elaborated).
  final Term type;

  /// The value Term (already elaborated).
  final Term term;

  /// The source span of the declaration.
  final DoxaSpan span;

  /// For a structurally-recursive `fun`, the position of the designated
  /// decreasing argument (first explicit value param, counting type
  /// params; SPEC §8.6) and the total parameter count. Both null for
  /// non-recursive bindings. Threaded into [TopBindingEntry] so eval can
  /// build a guarded [VFun].
  final int? recDecreasingArg;

  /// Total parameter count of a recursive `fun`'s lambda chain. Null iff
  /// [recDecreasingArg] is null.
  final int? recArity;

  /// When true, this binding is opaque (never unfolds during conversion).
  final bool isOpaque;

  /// Creates a top-level binding.
  const TopBinding({
    required this.name,
    required this.type,
    required this.term,
    required this.span,
    this.recDecreasingArg,
    this.recArity,
    this.isOpaque = false,
  });
}

/// A co-recursive group of `fun` bindings.
///
/// A [CorecursiveGroup] is a set of [TopBinding]s that form an
/// atomic scoping unit: they must all be in `Ctx` before any of their
/// bodies is type-checked, because each member's body may reference
/// any member (itself or siblings). Mutual-block declarations
/// (`fun f ... and fun g ...`) produce one group with all members;
/// a single recursive `fun` produces a one-member group.
///
/// Rationale for first-class group structure (vs. a boolean flag on
/// each binding): matches industry practice (Coq's `Fixpoint ... with`,
/// Lean's `mutual def`, Agda's `mutual`). Recursive groups are atomic
/// in the CIC discipline, the checker scopes them together. Carrying
/// the group as a structured value means:
///
///   * The check pipeline scopes the right bindings together without
///     guessing boundaries (critical when a file has multiple mutual
///     blocks side-by-side).
///   * Later analyses (block-wide termination analysis, per-group
///     meta-variable scoping) get group metadata as first-class input
///     rather than having to re-derive it.
///   * LSP / browser-demo tooling can render a group as one unit.
///
/// Absent (i.e. `null` on [DeclResult.corecursiveGroup]) for plain
/// non-recursive bindings (`val`, `type`, auto-emitted `T.rec`,
/// non-recursive `fun`); populated only on recursive/mutual paths.
final class CorecursiveGroup {
  /// The group's members, aligned with [DeclResult.bindings].
  final List<CorecursiveMember> members;

  /// Creates a co-recursive group.
  const CorecursiveGroup(this.members);
}

/// A single member of a [CorecursiveGroup].
///
/// Carries the surface [SFunKind] alongside the binding index as
/// "provenance": later passes (termination analysis, metavariable
/// scoping, diagnostics) need the originating surface syntax for
/// rich error messages and per-member analysis. The core `check()`
/// function remains pure, it never reads [surfaceKind]; the field
/// is orchestrator/tooling metadata.
final class CorecursiveMember {
  /// Index into the containing [DeclResult.bindings].
  final int bindingIndex;

  /// The surface `fun` declaration this member came from.
  ///
  /// Provenance only, consumed by orchestrators (CLI), diagnostics,
  /// and later analysis passes; not by the core type-checker.
  final SFunKind surfaceKind;

  /// Creates a co-recursive-group member.
  const CorecursiveMember(this.bindingIndex, this.surfaceKind);
}

/// The accumulated top-level environment after elaborating declarations.
///
/// Provides [Ctx] and [Env] views for the checker and evaluator, plus
/// name lookup for references in later declarations. This
/// additionally carries the [dataDecls] registry (see [DataDecl]) so
/// the checker can look up inductive type declarations and their
/// constructors.
final class TopEnv {
  /// The declarations in source order.
  final List<TopBinding> bindings;

  /// The inductive-type declarations in source order.
  ///
  /// Separate from [bindings] because inductive declarations contribute
  /// structured information (parameter/index/constructor telescopes)
  /// that the type checker needs to inspect, not just a type and a
  /// value. Name resolution for the data type itself and its
  /// constructors still flows through [bindings] so `indexOfFromEnd`
  /// works uniformly for all kinds of top-level names.
  final List<DataDecl> dataDecls;

  /// The typeclass registry: class name → [ClassInfo].
  ///
  /// Populated by `typeclass` declarations and consulted by instance
  /// resolution during implicit argument insertion.
  final Map<String, ClassInfo> classRegistry;

  /// Namespace-qualified name index: prefix → set of unqualified names
  /// available under that prefix.
  ///
  /// Built during import processing and data-decl elaboration.
  /// Consulted by dotted-name resolution to resolve `Nat.plus` as
  /// `plus` in the `Nat` namespace.
  final Map<String, Set<String>> namespaceBindings;

  /// Creates a top environment wrapping [bindings] and optional
  /// inductive [dataDecls], [classRegistry], and [namespaceBindings].
  const TopEnv(
    this.bindings, [
    this.dataDecls = const <DataDecl>[],
    this.classRegistry = const {},
    this.namespaceBindings = const {},
  ]);

  /// The empty top environment.
  static const TopEnv empty = TopEnv(<TopBinding>[]);

  /// Look up a name qualified by namespace prefix.
  /// Returns true if [name] is registered under [namespace].
  bool lookupQualified(String namespace, String name) {
    final ns = namespaceBindings[namespace];
    return ns != null && ns.contains(name);
  }

  /// Look up a name's 1-based index from the end of the list.
  ///
  /// Returns -1 if not found. Used by elaboration to turn source
  /// references to top-level names into de Bruijn indices relative to
  /// the local scope. The caller is responsible for adjusting the index
  /// by [localDepth] (the current local binder depth).
  int indexOfFromEnd(String name) {
    for (var i = bindings.length - 1; i >= 0; i--) {
      if (bindings[i].name == name) {
        return bindings.length - 1 - i;
      }
    }
    return -1;
  }

  /// The span of an existing binding with [name], or null.
  ///
  /// Searches both [bindings] and [dataDecls], a `data Nat` must be
  /// visible to duplicate-declaration diagnostics even before its
  /// name is registered as a [TopBinding]. Returns the
  /// first match in declaration order.
  DoxaSpan? spanOf(String name) {
    for (final b in bindings) {
      if (b.name == name) return b.span;
    }
    for (final d in dataDecls) {
      if (d.name == name) return d.span;
      for (final c in d.ctors) {
        if (c.name == name) return c.span;
      }
    }
    return null;
  }

  /// Look up an inductive-type declaration by name, or null if absent.
  DataDecl? lookupData(String name) {
    for (final d in dataDecls) {
      if (d.name == name) return d;
    }
    return null;
  }

  /// Look up a constructor by its parent data name and its own name,
  /// or null if absent.
  CtorDecl? lookupCtor(String dataName, String ctorName) {
    final data = lookupData(dataName);
    if (data == null) return null;
    for (final c in data.ctors) {
      if (c.name == ctorName) return c;
    }
    return null;
  }

  /// The [Ctx] representing this top environment to the type checker.
  ///
  /// Top-level bindings go into the parallel [Env.topBindings] map
  /// (via [CNil.withRegistries]), NOT
  /// into a CCons chain. The Ctx chain is reserved for local binders
  /// introduced by [Ctx.extend] / [Ctx.extendWith]. References to
  /// top-level names resolve through [TTop(name)] at eval time.
  ///
  /// Each binding is evaluated in an env that already has all prior
  /// bindings registered, so later bindings can reference earlier
  /// ones via TTop without an out-of-scope error.
  Ctx toCtx({MetaContext? metas}) {
    // Build the topBindings map incrementally. Each binding's type
    // and term evaluate in an env with all EARLIER bindings already
    // registered (so `later` can reference `earlier` via TTop).
    final acc = <String, TopBindingEntry>{};
    for (final b in bindings) {
      // Build an interim env with `acc` as the visible topBindings.
      final env = ENil.withRegistries(dataDecls: dataDecls, topBindings: acc);
      final type = eval(b.type, env);
      final value = eval(b.term, env);
      acc[b.name] = TopBindingEntry(
        type,
        value,
        recDecreasingArg: b.recDecreasingArg,
        recArity: b.recArity,
        isOpaque: b.isOpaque,
      );
    }
    return CNil.withRegistries(
      dataDecls: dataDecls,
      topBindings: acc,
      metas: metas,
    );
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Elaborate a [SExpr] into a kernel [Term] in an empty local scope.
///
/// Any top-level references are resolved against [topEnv]; any free
/// name not in [topEnv] raises [UnresolvedName]. The produced term is
/// in fully de-Bruijn-indexed form (no [TFree]) and is valid input to
/// the evaluator.
Term elabExpr(TopEnv topEnv, SExpr expr) =>
    _elabExpr(topEnv, const _LocalNil(), expr);

/// Elaborate [expr] against [topEnv] with local binder [names] (innermost first).
///
/// Constructs a [_LocalScope] from [names] and delegates to [_elabExpr].
/// Each local name becomes a de Bruijn binder with a placeholder type;
/// the resulting term has correct de Bruijn indices for the given local
/// names. The calling tactic's own [infer] pass uses the real
/// [TacticState.ctx] for type checking.
Term elabExprInScope(
  TopEnv topEnv,
  List<String> names,
  SExpr expr, {
  MetaContext? metas,
}) {
  // names is innermost-first. _LocalScope.push adds to the head,
  // so push outermost-first to get the correct index order.
  var scope = const _LocalNil() as _LocalScope;
  for (var i = names.length - 1; i >= 0; i--) {
    scope = scope.push(names[i]);
  }
  return _elabExpr(topEnv, scope, expr, metas: metas);
}

/// Type-check every binding in [result] and return the bindings
/// with solved metavariables inlined (see [inlineSolvedMetas]).
///
/// Type-checking uses the running [topEnv] for non-recursive bindings
/// and pre-scopes [result.corecursiveGroup]'s members in Ctx for
/// recursive/mutual bindings: for a single recursive
/// `fun` or a `fun ... and ...` mutual block, all group members are
/// visible in the Ctx under which ANY of their bodies type-check.
/// Each member's `(type, VNeutral(NVar(level)))` self-neutral is
/// installed before any check fires. The body's TBound indices (laid
/// out at elab time against a scratch TopEnv that includes the
/// members) then resolve correctly into this pre-scoped Ctx.
///
/// For non-recursive paths (`val`, `type`, `data`, non-recursive
/// `fun`), [result.corecursiveGroup] is null and the loop falls back
/// to the per-binding check against the running env.
///
/// Meta inlining. After every body is checked (which is
/// where pattern unification fires and meta solutions are
/// committed), we walk each binding's `type` and `term` through
/// [inlineSolvedMetas] to replace any solved `TMeta(id)` with its
/// solution term. This is necessary because [MetaContext] is
/// per-declaration: downstream decls do
/// not see the original decl's meta context, so any raw `TMeta(id)`
/// that survived would resolve opaquely via `eval` to
/// `VNeutral(NMeta(id))` and break conv. See [inlineSolvedMetas]'s
/// block comment for the detailed rationale.
///
/// Returns the bindings from [result] with metas inlined. Callers
/// should use the returned list (not `result.bindings`) when
/// extending the running [topEnv].
///
/// Throws whatever [check] throws ([DoxaCheckError] for type errors,
/// kernel invariant exceptions otherwise).
List<TopBinding> checkDeclResult(TopEnv topEnv, DeclResult result) {
  // Thread the elaboration-time MetaContext onto the check-time Ctx
  // so `_Infer(TMeta)` and `_Conv(NMeta)` follow solutions. Null when
  // the decl never allocated metas; `Ctx.metas` is already nullable.
  final metas = result.metas;
  final group = result.corecursiveGroup;
  if (group == null) {
    // Pre-seed self-referencing bindings (termination_by funs that
    // reference themselves via TTop).  Without this, checking the
    // body fails because TTop(name) can't resolve to the binding
    // being checked.
    final needsStub = result.bindings.where((b) => b.isOpaque).toList();
    if (needsStub.isNotEmpty) {
      final baseCtx = _ctxWithMetas(topEnv.toCtx(), metas);
      final stubs = <String, TopBindingEntry>{};
      for (final b in needsStub) {
        final typeV = eval(b.type, baseCtx.env);
        stubs[b.name] = TopBindingEntry(
          typeV,
          VNeutral(NTop(b.name)),
          isOpaque: true,
        );
      }
      final ctx = _ctxWithTopBindings(baseCtx, stubs, metas: metas);
      for (final binding in result.bindings) {
        final expectedV = eval(binding.type, ctx.env);
        check(ctx, binding.term, expectedV);
      }
      return _finalizeDeclBindings(result.bindings, metas);
    }
    for (final binding in result.bindings) {
      final ctx = _ctxWithMetas(topEnv.toCtx(), metas);
      check(ctx, binding.term, eval(binding.type, ctx.env));
    }
    return _finalizeDeclBindings(result.bindings, metas);
  }
  // Pre-scope the whole group by installing each member as a stub
  // in topBindings. The stub's type is the member's declared type;
  // the stub's value is `VNeutral(NTop(name))`, a neutral keyed
  // on the member's name, quoting back to `TTop(name)`. During
  // check-time reduction, references to the member stay stuck
  // (conv compares two NTops by name, so `f == f` at the stub
  // level holds as expected).
  //
  // Install all stubs first, THEN check each body against the
  // augmented env. This way self- and sibling-references in any
  // body resolve consistently.
  final baseCtx = topEnv.toCtx();
  final memberTypes = <Value>[];
  final stubs = <String, TopBindingEntry>{};
  for (final m in group.members) {
    final binding = result.bindings[m.bindingIndex];
    final typeV = eval(binding.type, baseCtx.env);
    memberTypes.add(typeV);
    stubs[binding.name] = TopBindingEntry(
      typeV,
      VNeutral(NTop(binding.name)),
      isOpaque: binding.isOpaque,
    );
  }
  // Ctx with the group's stubs installed in topBindings AND the
  // elab-time MetaContext threaded. The local-binder chain is
  // unchanged (the group members are NOT de-Bruijn-indexed
  // they're name-indexed via TTop).
  final groupCtx = _ctxWithTopBindings(baseCtx, stubs, metas: metas);
  // Check each member's body.
  for (var i = 0; i < group.members.length; i++) {
    final binding = result.bindings[group.members[i].bindingIndex];
    final term =
        metas != null ? inlineSolvedMetas(binding.term, metas) : binding.term;
    check(groupCtx, term, memberTypes[i]);
  }
  return _finalizeDeclBindings(result.bindings, metas);
}

/// Return [bindings] with every solved meta in each binding's
/// `type` and `term` inlined (via [inlineSolvedMetas]). If [metas]
/// is null, return [bindings] unchanged (the decl never allocated
/// metas, so there is nothing to inline).
///
/// Called at the tail of [checkDeclResult]. See that function's
/// block comment and [inlineSolvedMetas]'s block comment for the
/// motivation.
List<TopBinding> _finalizeDeclBindings(
  List<TopBinding> bindings,
  MetaContext? metas,
) {
  if (metas == null) return bindings;
  return [
    for (final b in bindings)
      TopBinding(
        name: b.name,
        type: inlineSolvedMetas(b.type, metas),
        term: inlineSolvedMetas(b.term, metas),
        span: b.span,
        recDecreasingArg: b.recDecreasingArg,
        recArity: b.recArity,
        isOpaque: b.isOpaque,
      ),
  ];
}

/// Produce a Ctx identical to [base] except with [additional] entries
/// merged into its parallel env's topBindings. Preserves the local-
/// binder chain and all other state. Threads [metas] through so that
/// elab-time meta solutions are visible at check time for
/// `_Infer(TMeta)`.
///
/// The check-time helper for installing co-recursive stubs without
/// introducing mutation into the Ctx hierarchy.
Ctx _ctxWithTopBindings(
  Ctx base,
  Map<String, TopBindingEntry> additional, {
  MetaContext? metas,
}) {
  final baseEnv = base.env;
  // The base Ctx is always constructed from TopEnv.toCtx() which
  // returns a CNil with both registries populated. Rebuild a CNil
  // with the augmented topBindings.
  return CNil.withRegistries(
    dataDecls: baseEnv.dataDecls,
    topBindings: {...baseEnv.topBindings, ...additional},
    metas: metas,
  );
}

/// Rebuild [base] with [metas] installed on `Ctx.metas`. No-op when
/// [metas] is null OR [base] is not a [CNil] (local binders wrap an
/// unchanged base). Used at non-recursive-decl check entry sites.
Ctx _ctxWithMetas(Ctx base, MetaContext? metas) {
  if (metas == null) return base;
  if (base is CNil) {
    final env = base.env;
    return CNil.withRegistries(
      dataDecls: env.dataDecls,
      topBindings: env.topBindings,
      metas: metas,
    );
  }
  return base;
}

/// Elaborate a list of surface declarations into a [TopEnv].
///
/// Each declaration sees the accumulated environment of all previous
/// declarations and none of the later ones. Self- and mutual
/// recursion within `fun` declarations is allowed; the
/// structural-recursion check guards soundness.
///
/// The loop is a fold: each step produces a new [TopEnv] from the
/// previous one plus the newly-elaborated declaration. No mutation
/// of shared lists, a pure-functional fold.
TopEnv elabProgram(SProgram program) =>
    program.decls.fold(TopEnv.empty, (env, decl) {
      final produced = elabDecl(env, decl);
      return TopEnv(
        [...env.bindings, ...produced.bindings],
        [...env.dataDecls, ...produced.dataDecls],
        {...env.classRegistry, ...produced.classRegistry},
        mergeNamespace(env.namespaceBindings, produced.namespaceBindings),
      );
    });

/// The member.
Map<String, Set<String>> mergeNamespace(
  Map<String, Set<String>> a,
  Map<String, Set<String>> b,
) {
  if (b.isEmpty) return a;
  final result = Map<String, Set<String>>.from(a);
  for (final entry in b.entries) {
    result[entry.key] = {...?result[entry.key], ...entry.value};
  }
  return result;
}

/// The output of elaborating a single declaration.
///
/// `val`, `type`, and `fun` decls contribute [TopBinding]s. A
/// `fun ... and ...` block contributes multiple bindings. A `data`
/// decl contributes one [DataDecl] and no bindings. A mixed block
/// (e.g. mutual `data`) may contribute both.
///
/// [corecursiveGroup] is non-null iff the
/// produced bindings form a recursive/mutual group that must be
/// pre-scoped together before any body type-checks. The CLI and test
/// harnesses honor this: when present, all members get pushed into
/// Ctx with self-neutral values before any single body is checked.
/// Absent for non-recursive paths (`val`, `type`, `data`, single
/// non-recursive `fun`).
typedef DeclResult =
    ({
      List<TopBinding> bindings,
      List<DataDecl> dataDecls,
      CorecursiveGroup? corecursiveGroup,
      // The per-declaration MetaContext. Populated when elaboration
      // allocated fresh metas via `insert'` (or any other insertion
      // mechanism). Consumers that re-check the elaborated term (notably
      // `checkDeclResult`) must install this on the check-time Ctx so the
      // kernel's `_Infer(TMeta)` / `_Conv(NMeta)` paths can resolve them.
      //
      // Null when the decl's elaboration pipeline never touched metas
      // (e.g. pure `data` declarations that don't run the expression
      // elaborator).
      MetaContext? metas,
      // Typeclass registry updates: class name → ClassInfo.
      // Populated by `typeclass` declarations and updated by `impl`
      // declarations. Merged into `TopEnv.classRegistry` by callers.
      Map<String, ClassInfo> classRegistry,
      // Namespace-qualified name index updates: prefix → set of
      // unqualified names. Built during import processing and data
      // declaration elaboration. Merged into
      // `TopEnv.namespaceBindings` by callers.
      Map<String, Set<String>> namespaceBindings,
    });

/// Elaborate a single declaration in the context of [topEnv].
///
/// Raises [DuplicateDeclaration], [UnresolvedName],
/// [RecursionNotYetSupported], [DataSortNotASort], or
/// [CtorResultShapeMismatch] on the usual elaboration errors.
DeclResult elabDecl(TopEnv topEnv, SDecl decl) => _elabDecl(topEnv, decl);

/// Extract all names defined by a declaration, for poison tracking /
/// diagnostic contexts.
///
/// When a declaration fails, all its names are marked as "poisoned" so
/// subsequent declarations that reference them get a clear diagnostic
/// rather than an opaque "unresolved name" error.
Set<String> declNames(SDecl decl) {
  switch (decl.kind) {
    case SValKind(:final name):
    case STypeAliasKind(:final name):
    case SFunKind(:final name):
      return {name};
    case SFunBlockKind(:final members):
      return {for (final m in members) m.fun.name};
    case SDataKind(:final name, :final ctors):
      return {
        name,
        ...{for (final c in ctors) c.name},
      };
    case SDataBlockKind(:final members):
      final names = <String>{};
      for (final m in members) {
        names.add(m.data.name);
        for (final c in m.data.ctors) {
          names.add(c.name);
        }
      }
      return names;
    case SImportKind(:final path):
      return {path};
    case STypeclassKind(:final name):
      return {name};
    case SImplKind():
      return {};
  }
}

// ---------------------------------------------------------------------------
// Tactic elaboration
// ---------------------------------------------------------------------------

/// Elaborate a `by { ... }` tactic block against an expected type.
///
/// Creates a fresh goal meta, compiles the tactic steps, and runs them.
/// If no alternative succeeds, throws [TacticFailed].
Term _elabTacticBlock(
  _ElabState state,
  SByKind kind,
  Value expected,
  DoxaSpan span,
) {
  final metas = state.ctx.metas;
  if (metas == null) {
    throw StateError('SByKind elaboration requires a MetaContext');
  }
  // Create a fresh meta for the goal type.
  final goalMetaId = metas.freshTermMeta(expected, state.ctx);
  // Try each alternative in order.
  for (final alt in kind.steps) {
    final tstate = TacticState(metas, state.ctx, goalMetaId);
    final result = _runTacticSteps(alt, tstate, state);
    if (result is TacticOk) {
      try {
        return metas.solutionOf(goalMetaId);
      } catch (_) {
        continue;
      }
    }
  }
  throw TacticFailed('tactic block: no alternative succeeded', span);
}

/// Run a sequence of tactic steps, using [_ElabState] for expression
/// elaboration so local binders introduced by `intro` are visible.
TacticResult _runTacticSteps(
  List<STacticStep> steps,
  TacticState tstate,
  _ElabState est,
) {
  var currentTstate = tstate;
  var currentEst = est;
  for (final step in steps) {
    final (result, newEst) = switch (step) {
      STacticIntro(:final name) => _runIntro(
        currentTstate,
        currentEst,
        name: name,
      ),
      STacticExact(:final expr) => (
        _runExact(expr, currentTstate, currentEst),
        currentEst,
      ),
      STacticApply(:final expr) => (
        _runApply(expr, currentTstate, currentEst),
        currentEst,
      ),
      STacticRefl() => (_runRefl(currentTstate), currentEst),
      STacticRewrite(:final expr) => (
        _runRewrite(expr, currentTstate, currentEst),
        currentEst,
      ),
      STacticInduction(:final name) => (
        _runInduction(name, currentTstate, currentEst),
        currentEst,
      ),
      STacticTrivial() => (_runTrivial(currentTstate), currentEst),
    };
    switch (result) {
      case TacticOk(:final term, :final metas, :final subMeta):
        if (subMeta != null) {
          currentTstate.metas.solve(currentTstate.currentMeta, term);
        }
        // Use the updated ctx and names from the new _ElabState
        // (intro extends both ctx and local name scope).
        currentTstate = TacticState(
          metas,
          newEst.ctx,
          subMeta ?? currentTstate.currentMeta,
          currentTstate.binderNames,
        );
        currentEst = newEst;
      case TacticFail():
        return result;
    }
  }
  return TacticOk(const TType(LLevel(0)), currentTstate.metas);
}

(TacticResult, _ElabState) _runIntro(
  TacticState tstate,
  _ElabState est, {
  String? name,
}) {
  final goalType = tstate.goalType;
  if (goalType is! VPi) {
    return (const TacticFail('intro: goal is not a function type'), est);
  }
  final pi = goalType;
  final freshName = name ?? pi.name ?? 'h';
  // Extend the TacticState's Ctx.
  final newCtx = tstate.ctx.extend(pi.domain);
  // Update the ElabState's names so further tactics can resolve `freshName`.
  final newEst = est.push(freshName, pi.domain);
  final codArg = VNeutral(NVar(newCtx.level - 1));
  final codVal = eval(pi.codomain.body, pi.codomain.env.extend(codArg));
  final subMetaId = tstate.metas.freshTermMeta(codVal, newCtx);
  final bodyTerm = TMeta(subMetaId);
  final lamTerm = TLam(
    quote(tstate.ctx.level, pi.domain),
    bodyTerm,
    name: freshName,
  );
  return (TacticOk(lamTerm, tstate.metas, subMeta: subMetaId), newEst);
}

TacticResult _runExact(SExpr expr, TacticState tstate, _ElabState est) {
  // Try to elaborate the expression using the full elaborator with the
  // tactic's local scope.
  Term term;
  try {
    term = _elabExpr(est.topEnv, est.names, expr, metas: est.ctx.metas);
  } catch (_) {
    // Fallback: if the expression is a simple identifier, look it up
    // in the local scope and construct a TBound.
    if (expr.kind case SIdentKind(:final name)) {
      final idx = est.names.indexOf(name);
      if (idx >= 0) {
        term = TBound(idx);
      } else {
        return TacticFail('exact: unresolved name "$name"');
      }
    } else {
      rethrow;
    }
  }
  return exact(term)(tstate);
}

TacticResult _runApply(SExpr expr, TacticState tstate, _ElabState est) {
  final topEnv = est.topEnv;
  final names = est.names;
  final term = _elabExpr(topEnv, names, expr);
  return tacticApply(term)(tstate);
}

TacticResult _runRefl(TacticState tstate) => refl(tstate);

TacticResult _runRewrite(SExpr expr, TacticState tstate, _ElabState est) {
  final topEnv = est.topEnv;
  final names = est.names;
  final term = _elabExpr(topEnv, names, expr);
  return rewrite(term)(tstate);
}

TacticResult _runInduction(String name, TacticState tstate, _ElabState est) {
  final binderIdx = est.names.indexOf(name);
  if (binderIdx < 0) {
    return TacticFail('induction: variable "$name" not in scope');
  }
  return inductionAt(binderIdx)(tstate);
}

TacticResult _runTrivial(TacticState tstate) => trivial(tstate);

// ---------------------------------------------------------------------------
// Expression elaboration
// ---------------------------------------------------------------------------

/// Infer-mode elaboration: produce a Term paired with its inferred
/// type as a Value.
///
/// The returned [Value] is correct whenever [state.ctx] faithfully
/// models the local binders. The [_elabExpr] shim may call this with a
/// state whose [Ctx] carries placeholder types for the binders it does
/// not track; the shim discards the [Value] in that case, so no bogus
/// type leaks.
(Term, Value) _inferExpr(_ElabState state, SExpr expr) {
  // Provenance seed (see `_checkExpr`): attach `expr.span` to a
  // `TypeMismatch` raised while inferring this expression, innermost
  // frame winning.
  try {
    return _inferExprInner(state, expr);
  } on TypeMismatch catch (e) {
    throw e.withSpan(expr.span);
  }
}

(Term, Value) _inferExprInner(_ElabState state, SExpr expr) {
  switch (expr.kind) {
    case SIdentKind(:final name):
      final local = state.lookupLocal(name);
      if (local != null) {
        final (index, type) = local;
        _recordSemInfo(
          state,
          expr.span,
          name,
          SemInfoKind.localVar,
          type,
          null,
        );
        return (TBound(index), type);
      }
      // Inductive-type registry: resolve to TData / TConstr before
      // falling back to the ordinary bindings list. Mirrors the
      // precedence rule from `_elabExpr`.
      final dataDecl = state.topEnv.lookupData(name);
      if (dataDecl != null) {
        final sigTerm = _dataSignatureTerm(dataDecl);
        final sigValue = eval(sigTerm, state.ctx.env);
        _recordSemInfo(
          state,
          expr.span,
          name,
          SemInfoKind.dataType,
          sigValue,
          dataDecl.span,
        );
        return (TData(name, const <Term>[]), sigValue);
      }
      for (final d in state.topEnv.dataDecls) {
        for (final c in d.ctors) {
          if (c.name == name) {
            final sigTerm = _ctorSignatureTerm(d, c);
            final sigValue = eval(sigTerm, state.ctx.env);
            _recordSemInfo(
              state,
              expr.span,
              name,
              SemInfoKind.constructor,
              sigValue,
              c.span,
            );
            return (TConstr(d.name, name, const <Term>[]), sigValue);
          }
        }
      }
      if (state.topEnv.indexOfFromEnd(name) < 0) {
        throw UnresolvedName(name, expr.span);
      }
      final topEntry = state.ctx.env.lookupTop(name);
      if (topEntry == null) {
        throw StateError(
          '_inferExpr: TTop($name) has no env.topBindings entry '
          'but topEnv.indexOfFromEnd resolved it. Kernel invariant '
          'violation.',
        );
      }
      _recordSemInfo(
        state,
        expr.span,
        name,
        SemInfoKind.topBinding,
        topEntry.type,
        state.topEnv.spanOf(name),
      );
      return (TTop(name), topEntry.type);

    case STypeKind(:final level):
      final n = level ?? 0;
      return (TType(LLevel(n)), VType(LLevel(n + 1)));

    case SPropKind():
      return (const TProp(), _vType1);

    case SSPropKind():
      return (const TSProp(), _vType1);

    case SDotKind(:final qualifier, :final name):
      // Try record projection first: elaborate the qualifier; if its
      // type is a record type, treat .name as a field projection.
      try {
        final (qualT, qualV) = _inferExpr(state, qualifier);
        if (qualV is VData && _isRecord(qualV.name, state.topEnv.dataDecls)) {
          final fieldType = _fieldType(qualV, name, state.topEnv.dataDecls);
          _recordSemInfo(
            state,
            expr.span,
            name,
            SemInfoKind.fieldProj,
            fieldType,
            null,
          );
          return (TProj(qualT, name), fieldType);
        }
      } catch (_) {
        // Fall through to name qualification.
      }

      // Try namespace-qualified lookup: Nat.plus → look up `plus`
      // in namespace `Nat`. Also handles type-applied qualifiers
      // like `Acc[Nat].rec` where the qualifier is `App(Ident("Acc"), ...)`.
      String? qualName;
      if (qualifier.kind is SIdentKind) {
        qualName = (qualifier.kind as SIdentKind).name;
      } else if (qualifier.kind is SAppKind) {
        final fn = (qualifier.kind as SAppKind).fn.kind;
        if (fn is SIdentKind) qualName = fn.name;
      }
      if (qualName != null && state.topEnv.lookupQualified(qualName, name)) {
        // Resolve `name` against the full registry: constructors,
        // data types, and top bindings, in that order (mirroring
        // SIdentKind resolution).
        for (final d in state.topEnv.dataDecls) {
          for (final c in d.ctors) {
            if (c.name == name) {
              final sigTerm = _ctorSignatureTerm(d, c);
              final sigValue = eval(sigTerm, state.ctx.env);
              _recordSemInfo(
                state,
                expr.span,
                '$qualName.$name',
                SemInfoKind.constructor,
                sigValue,
                c.span,
              );
              return (TConstr(d.name, name, const <Term>[]), sigValue);
            }
          }
        }
        final dataDecl = state.topEnv.lookupData(name);
        if (dataDecl != null) {
          final sigTerm = _dataSignatureTerm(dataDecl);
          final sigValue = eval(sigTerm, state.ctx.env);
          _recordSemInfo(
            state,
            expr.span,
            '$qualName.$name',
            SemInfoKind.dataType,
            sigValue,
            dataDecl.span,
          );
          return (TData(name, const <Term>[]), sigValue);
        }
        final topEntry = state.ctx.env.lookupTop(name);
        if (topEntry != null) {
          _recordSemInfo(
            state,
            expr.span,
            '$qualName.$name',
            SemInfoKind.topBinding,
            topEntry.type,
            state.topEnv.spanOf(name),
          );
          return (TTop(name), topEntry.type);
        }
      }

      final flat = _flattenDottedIdent(expr);
      if (flat == null) {
        throw UnresolvedName(
          '<non-literal qualifier in dotted reference>',
          expr.span,
        );
      }
      final local = state.lookupLocal(flat);
      if (local != null) {
        final (index, type) = local;
        _recordSemInfo(
          state,
          expr.span,
          flat,
          SemInfoKind.localVar,
          type,
          null,
        );
        return (TBound(index), type);
      }
      if (state.topEnv.indexOfFromEnd(flat) < 0) {
        throw UnresolvedName(flat, expr.span);
      }
      final topEntry = state.ctx.env.lookupTop(flat);
      if (topEntry == null) {
        throw StateError(
          '_inferExpr: dotted TTop($flat) has no env.topBindings '
          'entry but topEnv.indexOfFromEnd resolved it. Kernel '
          'invariant violation.',
        );
      }
      _recordSemInfo(
        state,
        expr.span,
        flat,
        SemInfoKind.topBinding,
        topEntry.type,
        state.topEnv.spanOf(flat),
      );
      return (TTop(flat), topEntry.type);

    case SPiKind(:final param, :final domain, :final codomain, :final icit):
      // Pi-type elaboration. Sort computation follows `_piSort` in
      // eval.dart (SPEC §8.2 PTS rules). We infer both sides and
      // compute the Pi's sort when both sides inferred cleanly,
      // falling back to a placeholder otherwise.
      final (domT, domSort) = _inferExpr(state, domain);
      final domV = eval(domT, state.ctx.env);
      final binderName = param ?? ' _';
      final (codT, codSort) = _inferExpr(
        state.push(binderName, domV),
        codomain,
      );
      final resultV = _computePiSort(domSort, codSort) ?? _vType0;
      return (TPi(domT, codT, name: param, icit: icit), resultV);

    case SLetKind(
      :final param,
      :final domain,
      :final bound,
      :final body,
      :final isRec,
    ):
      if (isRec) {
        // Recursive local binding `val rec f(x: T): R = body; result`.
        // The domain is a Pi type built by the parser, and the bound is
        // a lambda chain. Self-references inside the lambda body are NOT
        // supported (use a top-level `fun` for full recursion). The
        // result body CAN reference the function via the TLet binder.
        // At eval time, the TLet wraps the bound in a VFun guard.
        final (piTerm, _) = _inferExpr(state, domain!);
        final piV = eval(piTerm, state.ctx.env);

        // Extract params and inner body from the lambda chain bound.
        final List<SExpr> paramDomains = [];
        final List<String> paramNames = [];
        SExpr innerBody = bound;
        var extracting = true;
        while (extracting) {
          switch (innerBody.kind) {
            case SLamKind(:final param, :final domain, :final body):
              paramNames.add(param);
              paramDomains.add(domain!);
              innerBody = body;
            default:
              extracting = false;
          }
        }

        // Elaborate param domains and build the TLam chain.
        // The lambda body is elaborated WITHOUT the rec name in scope.
        var funState = state;
        final domainTerms = <Term>[];
        for (var i = 0; i < paramNames.length; i++) {
          final (domT, _) = _inferExpr(funState, paramDomains[i]);
          final domV = eval(domT, funState.ctx.env);
          domainTerms.add(domT);
          funState = funState.push(paramNames[i], domV);
        }
        Term funcBody = _inferExpr(funState, innerBody).$1;
        for (var i = paramNames.length - 1; i >= 0; i--) {
          funcBody = TLam(domainTerms[i], funcBody, name: paramNames[i]);
        }
        final boundV = eval(funcBody, state.ctx.env);
        // Build TLet with isRec: the body elaborates under pushWith
        // so TBound(0) resolves to the VFun at eval time.
        const decreasingArg = 0;
        final arity = paramNames.length;
        final (bodyTerm, bodyV) = _inferExpr(
          state.pushWith(param, piV, boundV),
          body,
        );
        return (
          TLet(
            piTerm,
            funcBody,
            bodyTerm,
            name: param,
            isRec: true,
            recDecreasingArg: decreasingArg,
            recArity: arity,
          ),
          bodyV,
        );
      }
      // Non-recursive let-binding.
      final Term domainTerm;
      final Term boundTerm;
      if (domain == null) {
        // Inferred binder: synthesize the bound expr's type and quote
        // it back to a domain term in the current scope.
        final (inferredBound, boundType) = _inferExpr(state, bound);
        boundTerm = inferredBound;
        domainTerm = quote(state.ctx.level, boundType);
      } else {
        // Annotated binder: elaborate domain, then check bound against it.
        final (annTerm, _) = _inferExpr(state, domain);
        domainTerm = annTerm;
        final domainV = eval(domainTerm, state.ctx.env);
        boundTerm = _checkExpr(state, bound, domainV);
      }
      final domainV = eval(domainTerm, state.ctx.env);
      final boundV = eval(boundTerm, state.ctx.env);
      final (bodyTerm, bodyV) = _inferExpr(
        state.pushWith(param, domainV, boundV),
        body,
      );
      return (TLet(domainTerm, boundTerm, bodyTerm, name: param), bodyV);

    case SLamKind(:final param, :final domain, :final body, :final icit):
      // Lambda elaboration in infer mode. An unannotated lambda
      // (`(x) => body`) cannot synthesize its domain here; it only
      // elaborates in check mode against an explicit Pi (see `_checkExpr`
      // case 2). Reject it with a dedicated error.
      if (domain == null) {
        throw LambdaRequiresAnnotation(param, expr.span);
      }
      //
      // Body elaboration pushes the binder with its REAL Value-level
      // type (domV) into state and recursively calls `_inferExpr`.
      // Implicit-arg insertion inside a lambda body needs the real
      // type when resolving identifier refs.
      //
      // The returned VPi's codomain closure holds the body's INFERRED
      // TYPE quoted back to a term. A `TType(0)` placeholder here would
      // be fine when the returned VPi is discarded but LIES when a
      // lambda is passed as an argument to an implicit function (the
      // arg type unification would see `Type` instead of the real
      // codomain and solve the implicit incorrectly). So we compute the
      // real codomain, quote(bodyV) at pushed depth, wrapped in a
      // closure over the outer env.
      //
      // `bodyIsNormal` stays set since quote produces a normal
      // form by construction (keeps the linear-time Pi-quote fast
      // path).
      final (domT, _) = _inferExpr(state, domain);
      final domV = eval(domT, state.ctx.env);
      final pushed = state.push(param, domV);
      final (bodyT, bodyV) = _inferExpr(pushed, body);
      final bodyTypeT = quote(pushed.ctx.level, bodyV);
      return (
        TLam(domT, bodyT, name: param, icit: icit),
        VPi(
          domV,
          Closure(state.ctx.env, bodyTypeT, bodyIsNormal: true),
          name: param,
          icit: icit,
        ),
      );

    case SAppKind():
      // Fully iterative SApp processing — O(1) stack regardless of
      // nesting depth. Collects all application levels (handling both
      // left-deep multi-arg `f(a)(b)(c)` and right-deep nested
      // `f(g(...(x)...))` chains) into a flat list, then processes
      // from innermost to outermost in a single loop.

      // 1. Walk the expression collecting all SApp levels.
      //    Follow the fn chain for left-deep, arg chain for right-deep.
      //    Each entry: (fnExpr, argExpr, followFn).
      final fns = <SExpr>[], argExprs = <SExpr>[], followFn = <bool>[];
      var cur = expr;
      while (cur.kind is SAppKind) {
        final k = cur.kind as SAppKind;
        fns.add(k.fn);
        argExprs.add(k.arg);
        if (k.fn.kind is SAppKind) {
          followFn.add(true);
          cur = k.fn;
        } else if (k.arg.kind is SAppKind) {
          followFn.add(false);
          cur = k.arg;
        } else {
          followFn.add(false);
          break;
        }
      }

      // 2. Process from innermost (last) to outermost (first).
      //    Maintain running (resultT, resultV).
      Term? resultT;
      Value? resultV;
      for (var i = fns.length - 1; i >= 0; i--) {
        // 2a. Determine function head term and value.
        final Term headT;
        final Value headV;
        if (i == fns.length - 1 || !followFn[i]) {
          // Innermost or right-deep: infer the fn expression.
          final (rawFT, rawFV) = _inferExpr(state, fns[i]);
          final (impT, impV) = _insertImplicits(state, rawFT, rawFV);
          headT = impT;
          headV = impV;
        } else {
          // Left-deep non-innermost: the fn is the previous result.
          final (impT, impV) = _insertImplicits(state, resultT!, resultV!);
          headT = impT;
          headV = impV;
        }

        // 2b. Determine the argument term.
        final Term argT;
        // When an opaque placeholder is resolved via TTop, headV is a
        // VNeutral(NTop(name)).  Extract the real Pi type from
        // topBindings so argument elaboration checks against the
        // correct domain.
        final headVAsPi =
            headV is VPi
                ? headV
                : (headV is VNeutral && headV.neutral is NTop
                    ? (switch (state.ctx.env
                        .lookupTop((headV.neutral as NTop).name)
                        ?.type) {
                      final VPi pi => pi,
                      _ => null,
                    })
                    : null);
        if (i == fns.length - 1 || followFn[i]) {
          // Innermost or left-deep: arg is a raw SExpr.
          if (headVAsPi != null) {
            argT = _checkExpr(state, argExprs[i], headVAsPi.domain);
          } else {
            argT = _inferExpr(state, argExprs[i]).$1;
          }
        } else {
          // Right-deep non-innermost: arg is the previous result.
          if (headVAsPi != null) {
            final sr = subtype(
              state.ctx.level,
              resultV!,
              headVAsPi.domain,
              dataDecls: state.ctx.dataDecls,
              metas: state.ctx.metas,
              topBindings: state.ctx.env.topBindings,
            );
            if (sr is ConvMismatch) {
              throw TypeMismatch(
                resultV,
                headVAsPi.domain,
                sr,
                level: state.ctx.level,
              );
            }
          }
          argT = resultT!;
        }

        // 2c. Build result term.
        final builtT = switch (headT) {
          TData(:final name, :final args) =>
            TData(name, [...args, argT]) as Term,
          TConstr(:final dataName, :final ctorName, :final args) => TConstr(
            dataName,
            ctorName,
            [...args, argT],
          ),
          _ => TApp(headT, argT),
        };

        // 2d. Advance type value to codomain.
        Value builtV = _vType0;
        if (headVAsPi != null) {
          final argV = eval(argT, state.ctx.env);
          try {
            builtV = eval(
              headVAsPi.codomain.body,
              headVAsPi.codomain.env.extend(argV),
            );
          } on StateError catch (_) {
            // The codomain eval failed — the VPi was built at a
            // different env depth.  Use the current elaboration env
            // which has the function params pushed at the right depth.
            final strippedV = _stripBodyIsNormal(headVAsPi) as VPi;
            builtV = eval(strippedV.codomain.body, state.ctx.env.extend(argV));
          }
        }

        resultT = builtT;
        resultV = builtV;
      }

      return (resultT!, resultV!);

    case SMatchKind():
      // SMatchKind routed to `_elabMatch`, which consumes
      // `_ElabState` directly, with real motive inference for the
      // explicit-motive case.
      //
      // Doxa motive convention (SPEC §8.5, matches kernel
      // `_InferMatchAfterMotive`): the motive IS the match's result
      // type directly, NOT a function from scrutinee-and-indices to
      // result type. `match n returning Nat -> Nat { ... }` means
      // the whole match-expression has type `Nat -> Nat`. Evaluating
      // the elaborated motive term under `state.ctx.env` yields the
      // inferred Value.
      //
      // No-returning path (motive is null in the emitted TMatch)
      // returns a VType(0) placeholder. The kernel's _Infer(TMatch)
      // would throw `MatchMotiveRequired` there; the check-mode path
      // handles no-motive by synthesizing from `expected` (and pattern
      // unification solves indexed-family motives).
      final term = _elabMatch(state, expr);
      final matchTerm = term as TMatch;
      if (matchTerm.motive == null) {
        return (term, _vType0);
      }
      final motiveV = eval(matchTerm.motive!, state.ctx.env);
      return (term, motiveV);

    case SQuotKind(:final carrier, :final relation):
      final (carrierT, carrierV) = _inferExpr(state, carrier);
      // Relation should be A → A → Prop. Infer it.
      final (relationT, _) = _inferExpr(state, relation);
      final quotTerm = TQuot(carrierT, relationT);
      // The type of Quot(A, R) is Type 0 (or the sort of A)
      final resultV = carrierV is VType ? VType(carrierV.level) : _vType0;
      return (quotTerm, resultV);

    case SQuotMkKind(:final arg):
      // TQuotMk cannot be inferred in isolation; we need the expected
      // quotient type. Fall back to inferring the arg and wrapping in
      // a generic VQuot placeholder.
      final (argT, argV) = _inferExpr(state, arg);
      return (TQuotMk(argT), VQuot(argV, const VProp()));

    case SQuotLiftKind(:final fn, :final proof):
      final (fnT, fnV) = _inferExpr(state, fn);
      final (proofT, proofV) = _inferExpr(state, proof);
      // We need the quotient to apply the lift to. Create a placeholder.
      return (TQuotLift(const TType(_l0), fnT, proofT), _vType0);

    case SIntersectionKind(:final constraints):
      throw UnresolvedName(
        'intersection constraint (${constraints.join(" & ")}) used as an expression',
        expr.span,
      );

    case SByKind():
      throw TacticFailed(
        'by { ... } requires an expected type (check mode)',
        expr.span,
      );
  }
}

/// Record a [SemInfo] entry during elaboration, if semantic metadata
/// collection is enabled on the current [MetaContext].
void _recordSemInfo(
  _ElabState state,
  DoxaSpan span,
  String name,
  SemInfoKind kind,
  Value type,
  DoxaSpan? defSpan,
) {
  final infos = state.ctx.metas?.semInfos;
  if (infos == null) return;
  infos.add(
    SemInfo(
      span: span,
      name: name,
      kind: kind,
      type: prettyTerm(quote(state.ctx.level, type), outerDepth: 0),
      defSpan: defSpan?.isSynthetic == true ? null : defSpan,
    ),
  );
}

/// Check-mode elaboration: produce a Term whose type is [expected].
///
/// Dispatch order (following the check rule in Kovács's
/// elaboration-zoo implicit-arguments stage):
///
///   1. **Implicit-Pi auto-λ**. If [expected] is
///      `VPi(_, _, Icit.implicit)`, regardless of [expr]'s shape,
///      introduce an implicit lambda and recurse against the opened
///      codomain, i.e. `check Γ e (Pi x {A} B) = Lam x {A} (check
///      (Γ, x:A) e B)`. The user need not write a lambda; the
///      elaborator supplies one.
///
///   2. **SLamKind against explicit Pi**. Sort-check the
///      SLam's annotation, unify with `expected.domain`, push state,
///      check body against the opened codomain. The surface grammar
///      only produces annotated SLam today, so the no-domain branch
///      is substrate for future unannotated-lambda inference.
///
///   3. **SMatchKind without `returning`**. Emit
///      TMatch with motive=null; the kernel's check-mode TMatch path
///      (`_CheckMatchScrutineeType` in eval.dart) uses `expected` as
///      the constant motive at each arm. Handles all non-dependent
///      check-mode matches end-to-end. Dependent-motive cases where
///      `expected`'s shape depends on scrutinee indices are handled by
///      index refinement via pattern unification at elab time, the
///      kernel stays dumb per SPEC §4.5's linear-time invariant.
///
///   4. **Infer-then-conv fallback**. For every other
///      combination: infer [expr]'s type, conv against [expected],
///      raise `TypeMismatch` on mismatch. This is also the hook at
///      which coercion insertion, typeclass resolution, and the
///      elaborator's own `insert'` plug in.
///
/// Invariant: the returned [Term] has type [expected] in [state.ctx]
/// modulo whatever meta-solves conv commits (see [conv]'s metas
/// parameter, pattern unification).
// ignore: unused_element
Term _checkExpr(_ElabState state, SExpr expr, Value expected) {
  // Provenance seed: a `TypeMismatch` raised while checking `expr` (or
  // any sub-expression, since `_checkExpr`/`_inferExpr` recurse) carries
  // no span when it leaves the kernel's conv. We attach `expr.span` here.
  // `withSpan` keeps the innermost attach: the deepest `_checkExpr` frame
  // (smallest sub-expression) tags the error first, and the enclosing
  // frames' re-throws leave that precise span intact. This is the first
  // consumer of the elaborator's source-to-semantic map; the same site
  // is where a future hover/go-to-def channel would record facts.
  try {
    return _checkExprInner(state, expr, expected);
  } on TypeMismatch catch (e) {
    throw e.withSpan(expr.span);
  }
}

Term _checkExprInner(_ElabState state, SExpr expr, Value expected) {
  // 0. Auto-`refl`. A bare `refl` (a plain identifier resolving to the
  // prelude's `Eq.refl`) checked against `Eq[A] x y` is sugar for
  // `refl x` with the type and index inferred, provided `x` and `y`
  // are definitionally equal. We leave the term as the bare nullary
  // `TConstr('Eq', 'refl', [])`; the kernel's check-mode auto-refl rule
  // then fills the `[A, x]` arguments from the expected type. (Routing
  // val/arm bodies through check mode would otherwise insert the
  // implicit type argument and strand the explicit `x`.)
  final ek = expr.kind;
  if (ek is SIdentKind &&
      ek.name == 'refl' &&
      expected is VData &&
      expected.name == 'Eq' &&
      expected.args.length == 3 &&
      state.topEnv.lookupData('Eq') != null) {
    return const TConstr('Eq', 'refl', <Term>[]);
  }

  // 1. Implicit-Pi auto-λ.
  //    Introduces an implicit λ when the expression is not already an
  //    implicit lambda written by the user.  If the user wrote
  //    `{x: A} => body` and the expected type is `{x: A} -> B`, the
  //    SLamKind check (case 2 below) will handle it directly.
  if (expected is VPi &&
      expected.icit == Icit.implicit &&
      !(expr.kind is SLamKind &&
          (expr.kind as SLamKind).icit == Icit.implicit)) {
    final name = expected.name ?? '_';
    // Domain term for the introduced TLam: quote expected.domain at
    // the outer level so it's a well-scoped Term relative to the
    // current state. (The kernel re-evals it at check time.)
    final domTerm = quote(state.ctx.level, expected.domain);
    // Open the codomain at the current level; the introduced lambda's
    // body will be checked under the extended state at level+1.
    final opened = eval(
      expected.codomain.body,
      expected.codomain.env.extend(VNeutral(NVar(state.ctx.level))),
    );
    final pushed = state.push(name, expected.domain);
    final bodyT = _checkExpr(pushed, expr, opened);
    return TLam(domTerm, bodyT, name: expected.name, icit: Icit.implicit);
  }

  // 2. SLamKind against explicit or implicit Pi.
  //    When the expected Pi is implicit but the lambda is explicit, or
  //    vice versa, the icit mismatch is handled by the auto-λ case (1)
  //    or falls through to infer-then-conv below.  Here we match the
  //    common case where both sides agree.
  final kind = expr.kind;
  if (kind is SLamKind && expected is VPi) {
    // The domain term for the introduced TLam. When the lambda carries
    // an annotation, infer it and unify with expected.domain (sort-check
    // is subsumed by the conv, a non-sort domain would still mismatch
    // expected.domain structurally). When unannotated (`(x) => body`),
    // take the domain straight from the expected Pi by quoting
    // expected.domain at the outer level.
    final lamDomain = kind.domain;
    final Term domT;
    if (lamDomain == null) {
      domT = quote(state.ctx.level, expected.domain);
    } else {
      final (annT, _) = _inferExpr(state, lamDomain);
      final domV = eval(annT, state.ctx.env);
      final domConv = conv(
        state.ctx.level,
        domV,
        expected.domain,
        dataDecls: state.ctx.dataDecls,
        metas: state.ctx.metas,
        topBindings: state.ctx.env.topBindings,
      );
      if (domConv is ConvMismatch) {
        throw TypeMismatch(
          domV,
          expected.domain,
          domConv,
          level: state.ctx.level,
        );
      }
      domT = annT;
    }
    // Check body against the opened codomain under the pushed state.
    // We use expected.domain for the binder's type, for the annotated
    // case it's been conv'd equal to the annotation, and it's the
    // original closure-captured shape the codomain closure was built
    // against.
    final opened = eval(
      expected.codomain.body,
      expected.codomain.env.extend(VNeutral(NVar(state.ctx.level))),
    );
    final pushed = state.push(kind.param, expected.domain);
    final bodyT = _checkExpr(pushed, kind.body, opened);
    return TLam(domT, bodyT, name: kind.param, icit: kind.icit);
  }

  // 3. SMatchKind without explicit `returning` motive: pass
  //    `expected` to `_elabMatch` to drive per-arm check-mode
  //    elaboration with first-order index refinement. For non-
  //    indexed data or when refinement is trivial, this collapses
  //    to checking each arm body against `expected` directly (a
  //    constant motive). For indexed families, first-order refinement
  //    solves the `Vec.tail`-shape cases where the result type depends
  //    on the scrutinee's index.
  //
  //    The explicit-motive case (`match n returning P { ... }`) falls
  //    through to the infer-then-conv path: the evaluated P is the
  //    inferred Value, and conv checks P ≡ expected. Non-first-order
  //    cases (a motive that needs higher-order unification) still
  //    fail here, closing that gap requires a meta-driven path.
  if (kind is SMatchKind && kind.motive == null) {
    return _elabMatch(state, expr, expected: expected);
  }

  // 3.5. SByKind: tactic block. Check against expected type.
  if (kind is SByKind) {
    return _elabTacticBlock(state, kind, expected, expr.span);
  }

  // 4. Infer-then-conv fallback.
  final (rawTerm, rawInferred) = _inferExpr(state, expr);
  // Insert trailing implicit arguments before converting against the
  // expected type. A term whose inferred type still has leading implicit
  // Pi binders, e.g. a bare constructor `nil : {A: Type} -> List A`, or
  // `cons x xs` whose element type is implicit, is finished here by
  // solving those implicits against `expected` via metavariables, unless
  // `expected` is itself an implicit Pi (case 1 above already handled
  // that by introducing a λ). This is the leaf counterpart to the
  // implicit insertion done at application heads.
  final (term, inferred) =
      expected is VPi && expected.icit == Icit.implicit
          ? (rawTerm, rawInferred)
          : _insertImplicits(state, rawTerm, rawInferred);
  // Check mode accepts a subtype: `inferred ≤ expected` (cumulative on
  // universes), not strict equality, matching the kernel's `_Check`
  // fallback. Using strict conv here would reject e.g.
  // `val x: Type 1 = Type` (where `Type : Type 1`).
  final result = subtype(
    state.ctx.level,
    inferred,
    expected,
    dataDecls: state.ctx.dataDecls,
    metas: state.ctx.metas,
    topBindings: state.ctx.env.topBindings,
  );
  if (result is ConvMismatch) {
    throw TypeMismatch(inferred, expected, result, level: state.ctx.level);
  }
  return term;
}

/// Build the Term-level telescope-Pi signature of an inductive-type
/// head: `(params) -> (indices) -> sort`.
///
/// Each telescope entry's [type] is closed under the preceding
/// entries (registry invariant); the result is closed under params
/// and indices. Eval under any env: the Pi chain shadows outer
/// bindings at these indices, so local bindings in a caller's env
/// don't leak into the signature's scope, and `env.topBindings`
/// threads through so `TTop` references in telescope types resolve.
Term _dataSignatureTerm(DataDecl d) {
  Term result = d.sort;
  for (var i = d.indices.length - 1; i >= 0; i--) {
    final e = d.indices[i];
    result = TPi(e.type, result, name: e.name);
  }
  for (var i = d.params.length - 1; i >= 0; i--) {
    final e = d.params[i];
    result = TPi(e.type, result, name: e.name);
  }
  return result;
}

/// Build the Term-level telescope-Pi signature of a constructor:
/// `(params) -> (args) -> TData(dataName, <paramRefs> ++ resultIndices)`.
///
/// [CtorDecl.resultIndices] stores ONLY the index-arity portion
/// (constructed as `ccData.args.sublist(params.length)` in
/// `_elabDataCtors`), so we must prepend `TBound`-refs to the
/// surrounding params. At the innermost point of the built Pi
/// chain, param `i` sits at de Bruijn index
/// `args.length + (params.length - 1 - i)`, i.e. `args.length` for
/// `params[p-1]` and `args.length + p - 1` for `params[0]`.
Term _ctorSignatureTerm(DataDecl d, CtorDecl c) {
  final paramCount = d.params.length;
  final argCount = c.args.length;
  final resultArgs = <Term>[
    for (var i = 0; i < paramCount; i++)
      TBound(argCount + (paramCount - 1 - i)),
    ...c.resultIndices,
  ];
  Term result = TData(d.name, resultArgs);
  for (var i = argCount - 1; i >= 0; i--) {
    final e = c.args[i];
    result = TPi(e.type, result, name: e.name);
  }
  // The data type's parameters are IMPLICIT on a constructor: they are
  // inferred at the use site from the expected type, so `cons x xs` and
  // `nil` are written without spelling out the element type (the data
  // type itself keeps them explicit, see `_dataSignatureTerm`, so
  // `List[Nat]` as a type expression still takes its argument). The
  // inserted-implicit machinery fills the corresponding `TConstr` arg
  // slots with metavariables that pattern unification then solves.
  for (var i = paramCount - 1; i >= 0; i--) {
    final e = d.params[i];
    result = TPi(e.type, result, name: e.name, icit: Icit.implicit);
  }
  return result;
}

/// Peel leading implicit Pi's from [fV] by allocating fresh metas,
/// appending them to [fT] (folded into TData/TConstr args lists;
/// wrapped in TApp otherwise), and opening the codomain closure with
/// the meta's neutral value (the elaboration-zoo insertion technique).
///
/// No-op when `state.ctx.metas` is null (paths without a meta context).
/// When present, every implicit Pi in the head's type consumes one
/// fresh meta.
///
/// Pattern unification scope. The inserted meta is NOT a bare
/// `TMeta(id)`: it is applied to all outer bound variables visible
/// at [state] (the inserted-meta shape used by elaboration-zoo), so
/// the pattern-unification solve can produce a λ-abstracted solution
/// that's well-typed under the meta's allocation context. Without
/// this, a nullary meta has an empty allowed-scope and can only solve
/// to closed terms, so recursive implicit functions
/// (`dup{A}(xs) = match xs { ... dup rest }`) fail because the
/// solution `?0 := A` isn't closed.
///
/// The "fold into args vs wrap in TApp" discipline mirrors the SApp
/// arm's result-term construction: TData/TConstr heads carry args
/// lists because the kernel's `_Apply` rejects them as non-function
/// values; wrapping them in TApp would produce an ill-typed term.
/// In practice data types and constructors today declare their
/// params explicitly (no `{A}` on `data`), so the TData/TConstr
/// branches are forward-compat substrate, not hit by current
/// programs.
(Term, Value) _insertImplicits(_ElabState state, Term fT, Value fV) {
  final metas = state.ctx.metas;
  if (metas == null) return (fT, fV);
  var curT = fT;
  var curV = fV;
  while (curV is VPi && curV.icit == Icit.implicit) {
    // Check if this implicit is class-constrained (instance search).
    final domain = curV.domain;
    if (domain is VData &&
        state.topEnv.classRegistry.containsKey(domain.name)) {
      final className = domain.name;
      final classInfo = state.topEnv.classRegistry[className]!;
      // Try to find a matching instance. The domain args are the
      // type parameters of the class (e.g. `Eq[Int]` → args = [Int]).
      // Match against registered instances by checking if the
      // instance's target type matches the domain args.
      final candidates = <InstanceInfo>[];
      for (final inst in classInfo.instances) {
        // Simple name-based matching: check if the instance's
        // target type name appears in the domain args.
        // For this initial implementation, we do a basic structural
        // match: if the domain has 1 arg that is a TTop or VNeutral
        // matching the instance's targetType.
        if (domain.args.length == 1) {
          final argStr = _valueTypeName(domain.args.first);
          if (argStr == inst.targetType) {
            candidates.add(inst);
          }
        }
      }
      if (candidates.length == 1) {
        // Exactly one matching instance — use it directly.
        final instanceTerm = TTop(candidates.first.bindingName);
        curT = switch (curT) {
          TData(:final name, :final args) =>
            TData(name, [...args, instanceTerm]) as Term,
          TConstr(:final dataName, :final ctorName, :final args) => TConstr(
            dataName,
            ctorName,
            [...args, instanceTerm],
          ),
          _ => TApp(curT, instanceTerm),
        };
        curV = eval(
          curV.codomain.body,
          curV.codomain.env.extend(eval(instanceTerm, state.ctx.env)),
        );
        continue;
      }
      if (candidates.isEmpty && domain.args.length == 1) {
        // No instance found but args are concrete — error.
        // If args contain metas, we defer by allocating a meta.
        if (_isFullyConcrete(domain.args.first)) {
          throw NoInstanceFound(
            className,
            _valueTypeName(domain.args.first) ?? '?',
            state.topEnv.spanOf(className) ?? DoxaSpan.synthetic,
          );
        }
      }
      if (candidates.length > 1) {
        throw OverlappingInstances(
          className,
          _valueTypeName(domain.args.first) ?? '?',
          candidates.map((c) => c.bindingName).toList(),
          state.topEnv.spanOf(className) ?? DoxaSpan.synthetic,
        );
      }
    }

    // Allocate a fresh term-meta. To allow the solution to reference
    // outer bound variables, the meta's STORED TYPE is the domain
    // closed over the current Ctx's binders. The meta at the use site
    // is then APPLIED to each outer bound variable (the inserted-meta
    // shape), making the solution a function that opens back to
    // the value at the use site. Without this, a bare meta can
    // only solve to closed terms and implicit inference fails for
    // any function whose solution references a surrounding binder.
    final closedType = _closeValueOverCtx(curV.domain, state.ctx);
    final metaId = metas.freshTermMeta(closedType, state.ctx);
    // Build the meta applied to every outer bound variable. At this
    // depth, TBound(k) for k in [0, state.ctx.level) references
    // each binder in scope (innermost at TBound(0)).
    Term insertedMetaTerm = TMeta(metaId);
    for (var k = state.ctx.level - 1; k >= 0; k--) {
      insertedMetaTerm = TApp(insertedMetaTerm, TBound(k));
    }
    final metaValue = eval(insertedMetaTerm, state.ctx.env);
    curT = switch (curT) {
      TData(:final name, :final args) =>
        TData(name, [...args, insertedMetaTerm]) as Term,
      TConstr(:final dataName, :final ctorName, :final args) => TConstr(
        dataName,
        ctorName,
        [...args, insertedMetaTerm],
      ),
      _ => TApp(curT, insertedMetaTerm),
    };
    // Open the codomain with the meta's value; the resulting Value
    // is fV with the implicit binder consumed.
    curV = eval(curV.codomain.body, curV.codomain.env.extend(metaValue));
  }
  return (curT, curV);
}

/// Try to extract a type name from a [Value] for instance resolution.
/// Returns null if the value doesn't have a simple name.
String? _valueTypeName(Value v) => switch (v) {
  VNeutral(:final neutral) => switch (neutral) {
    NTop(:final name) => name,
    _ => null,
  },
  VData(:final name) => name,
  VConstr(:final dataName) => dataName,
  _ => null,
};

/// Check whether a [Value] contains no metavariables (is fully concrete).
bool _isFullyConcrete(Value v) => switch (v) {
  VType() => true,
  VProp() => true,
  VSProp() => true,
  VPi() => false, // Pi with unresolved codomain env might have metas
  VData(:final args) => args.every(_isFullyConcrete),
  VConstr(:final args) => args.every(_isFullyConcrete),
  VNeutral(:final neutral) => _isNeutralConcrete(neutral),
  _ => true,
};

bool _isNeutralConcrete(Neutral n) => switch (n) {
  NTop() => true,
  NVar() => true,
  NProj(:final expr) => _isFullyConcrete(expr),
  _ => false, // NMeta, NStuck etc. are not concrete
};

/// Close a [Value] over all binders in [ctx], producing the Value
/// of type `(outer-binders) → original-type`. Used by
/// `_insertImplicits` to give inserted metas a closed type that
/// admits solutions referencing outer binders.
///
/// Builds a VPi chain outermost-first. The domains come from the
/// ctx's binder types; the codomain at each layer is a closure over
/// the extended env. We quote the original type into a Term at
/// ctx.level, wrap that term in the Pi chain, then eval once under
/// an empty env to produce the Value.
Value _closeValueOverCtx(Value type, Ctx ctx) {
  if (ctx is CNil) return type;
  // Collect binder types innermost-first by walking the Ctx.
  final binderTypes = <Value>[];
  var c = ctx;
  while (c is CCons) {
    binderTypes.add(c.type);
    c = c.rest;
  }
  // Quote the body type at ctx.level so TBound references in it
  // are valid under the same depth as the Pi chain we're about
  // to build.
  final Term body = quote(ctx.level, type);
  // Wrap in Pi chain: innermost binder (at TBound(0)) has its type
  // quoted at the corresponding earlier depth.
  //
  // binderTypes[0] is the innermost binder (current depth - 1);
  // binderTypes.last is the outermost (depth 0). To build the Pi
  // outermost-first, iterate binderTypes in reverse so the
  // outermost wraps last.
  //
  // Each binder's type at its binding depth: binder at level k was
  // bound when the depth was k; quoting its type at depth k gives
  // a term valid in the outer scope up to level k. Which is what
  // we want.
  var curBody = body;
  // Iterate innermost-first: wrap Pi(binderType, curBody) with
  // binderType quoted at its own depth.
  var depth = ctx.level;
  for (var i = 0; i < binderTypes.length; i++) {
    depth -= 1;
    final domT = quote(depth, binderTypes[i]);
    curBody = TPi(domT, curBody);
  }
  // Eval under an env carrying the ctx's registries (NOT a bare ENil):
  // the closed Pi's codomain closures may now reference `TTop(name)`
  // for a guarded recursive `fun`, and forcing
  // such a closure later (e.g. in `_tryUnify`'s domain walk) must
  // resolve the top binding. A bare ENil has no registry and throws
  // "TTop(map) with no matching entry". The Pi chain is closed (its
  // body's free TBounds are bound by its own λ-binders), so the env
  // contributes only the dataDecls/topBindings registries, never stray
  // bound values.
  final closingEnv = ENil.withRegistries(
    dataDecls: ctx.env.dataDecls,
    topBindings: ctx.env.topBindings,
  );
  return eval(curBody, closingEnv);
}

/// Compute the sort of a Pi-type from its domain-and-codomain sort
/// values, per the PTS rules in SPEC §8.2. Mirrors `_piSort` in
/// eval.dart, expressed directly over [Value] rather than the
/// private `_Sort` ADT so it's callable from the elaborator.
///
///   cod = Prop                 => Pi : Prop     (impredicative Prop)
///   cod = Type m, dom = Prop   => Pi : Type m
///   cod = Type m, dom = Type n => Pi : Type (imax n m)
///
/// Returns null when either side isn't a recognisable sort; the
/// caller supplies a placeholder.
Value? _computePiSort(Value domSort, Value codSort) {
  if (codSort is VProp) return const VProp();
  if (codSort is VSProp) return const VSProp();
  if (codSort is! VType) return null;
  final codLevel = codSort.level;
  final Level domLevel;
  if (domSort is VProp || domSort is VSProp) {
    domLevel = _l0;
  } else if (domSort is VType) {
    domLevel = domSort.level;
  } else {
    return null;
  }
  return VType(LMax(domLevel, codLevel));
}

/// Strip `bodyIsNormal` from a VPi and its nested codomain closures.
/// Needed when a VPi built at one env depth (e.g. during
/// `_buildFunType`) is later used at a different depth (e.g. in
/// `_shimState`).  The fast-eval path for `bodyIsNormal: true` bodies
/// requires the original depth; stripping the flag forces the standard
/// eval path which adapts to the current context.
Value _stripBodyIsNormal(Value v) => switch (v) {
  VPi(:final domain, :final codomain, :final name, :final icit) => VPi(
    domain,
    Closure(codomain.env, codomain.body, bodyIsNormal: false),
    name: name,
    icit: icit,
  ),
  _ => v,
};

/// Build an `_ElabState` approximating the current [topEnv] + [locals]
/// for the `_elabExpr` shim. Each local binder is pushed into [Ctx]
/// with a placeholder [VType(0)] type, the shim discards any [Value]
/// returned by `_inferExpr`, so the placeholder never leaks.
///
/// Top bindings are stubbed as `VNeutral(NTop(name))` at the value
/// slot: `_inferExpr` may call `eval(argT, state.ctx.env)` on arg
/// terms that reference top bindings (e.g. a recursive `plus` inside
/// a mutual-block member's body), and the real `topEnv.toCtx()`
/// evaluation of pre-binding stubs (whose sentinel term is
/// `TType(0)`; see `_elabFunBlock` pass 1) would yield a bogus
/// `VType(0)` that crashes `_Apply`. Stubbing every top-binding value
/// as an NTop neutral matches `checkDeclResult`'s co-recursive-group
/// discipline and ensures `eval` on elab-time terms stays stuck
/// rather than reducing through an invalid top binding.
///
_ElabState _shimState(TopEnv topEnv, _LocalScope locals, {MetaContext? metas}) {
  // Build a Ctx with real top-binding values where available, and
  // NTop neutral stubs for mutual-block pre-bindings (whose sentinel
  // term is `TType(0)` per `_elabFunBlock` pass 1, evaluating it
  // would yield a bogus `VType(0)` that crashes `_Apply` when body
  // code references them).
  //
  // Check-mode elaboration inside `_buildFunBody` needs REAL values
  // for `type Foo = ...` bindings so that a body referencing `Foo` in
  // an identifier position can fold against its definition.
  // Unconditionally stubbing would break e.g. `church_bool.doxa`'s
  // `fun if_[A](b: Bool, ...)` where the body needs Bool's Pi chain to
  // drive application type-checking.
  //
  // Discrimination rule: a binding is a mutual-pre-stub iff its
  // type is a VPi chain AND its term syntactically equals
  // `TType(0)` (the sentinel in `_elabFunBlock`). Legitimate
  // `type X = Type` has term `TType(0)` but type `VType(1)` (Type
  // 1), distinguishable.
  final entries = <String, TopBindingEntry>{};
  for (final b in topEnv.bindings) {
    final env = ENil.withRegistries(
      dataDecls: topEnv.dataDecls,
      topBindings: entries,
    );
    var typeV = eval(b.type, env);
    final Value valueV;
    if (b.term == const TType(_l0) && typeV is VPi) {
      // Mutual-pre-binding sentinel: stub as NTop neutral.
      valueV = VNeutral(NTop(b.name));
      // The VPi closures were created during `_buildFunType` at a
      // higher env depth (function params pushed).  Strip
      // `bodyIsNormal` so the codomain re-evaluates correctly.
      typeV = _stripBodyIsNormal(typeV);
    } else {
      valueV = eval(b.term, env);
    }
    entries[b.name] = TopBindingEntry(
      typeV,
      valueV,
      recDecreasingArg: b.recDecreasingArg,
      recArity: b.recArity,
      isOpaque: b.isOpaque,
    );
  }
  var ctx =
      CNil.withRegistries(
            dataDecls: topEnv.dataDecls,
            topBindings: entries,
            metas: metas,
          )
          as Ctx;

  // Unwind locals into outermost-first order so we push them in that
  // order.
  final names = <String>[];
  var s = locals;
  while (s is _LocalCons) {
    names.add(s.name_);
    s = s.rest;
  }
  var scope = const _LocalNil() as _LocalScope;
  for (var i = names.length - 1; i >= 0; i--) {
    ctx = ctx.extend(const VType(_l0));
    scope = scope.push(names[i]);
  }
  return _ElabState(topEnv, ctx, scope);
}

Term _elabExpr(
  TopEnv topEnv,
  _LocalScope locals,
  SExpr expr, {
  MetaContext? metas,
}) {
  switch (expr.kind) {
    // Every SExprKind routes through `_inferExpr` with the Value
    // discarded. `_shimState` gives local binders placeholder types;
    // the Value returned may be a placeholder too for sub-expressions
    // not yet type-checked, but the shim discards it either way.
    case SIdentKind():
    case SDotKind():
    case STypeKind():
    case SPropKind():
    case SSPropKind():
    case SAppKind():
    case SPiKind():
    case SLetKind():
    case SLamKind():
    case SMatchKind():
    case SQuotKind():
    case SQuotMkKind():
    case SQuotLiftKind():
    case SIntersectionKind():
    case SByKind():
      final (term, _) = _inferExpr(
        _shimState(topEnv, locals, metas: metas),
        expr,
      );
      return term;
  }
}

/// Elaborate a `match` expression. An optional [expected] drives
/// per-arm check-mode with first-order index refinement.
///
/// Coverage and arity are fully checked here against the registry.
///
/// When [expected] is provided (check-mode entry), each ctor arm's
/// body is elaborated in check mode against a refined expected type
/// computed by first-order matching of scrutinee indices against
/// ctor resultIndices. For non-indexed data (or when the refinement
/// is trivial), this collapses to checking against [expected]
/// unchanged. Non-first-order cases where refinement would require
/// higher-order unification fall back to the minimal path
/// (check body against [expected] verbatim); closing that gap
/// requires meta-driven unification.
///
/// When [expected] is null (infer-mode entry), arm bodies are
/// elaborated in infer mode with binder types set to [VType(0)]
/// placeholders, the Ctx type at each binder is not consulted
/// by any migrated `_inferExpr` logic for a binder-indexing purpose.
/// The resulting TMatch has `motive = null` when the user omitted
/// `returning`, and the kernel's post-elab check applies the
/// constant-motive-from-expected rule.

/// Substitute [scrutLevel] with [replacement] in all binder types within
/// [ctx]. Walks the immutable CCons chain and creates new nodes for
/// binders whose types changed; unchanged nodes are shared.
Ctx substNVarInCtx(Ctx ctx, int scrutLevel, Value replacement) {
  switch (ctx) {
    case CNil():
      return ctx;
    case CCons(
      :final type,
      :final value,
      :final env,
      :final level,
      :final rest,
    ):
      final newType = substNVar(type, scrutLevel, replacement);
      final newRest = substNVarInCtx(rest, scrutLevel, replacement);
      if (identical(newType, type) && identical(newRest, rest)) {
        return ctx;
      }
      return CCons(newType, value, env, level, newRest);
  }
}

/// Walk [ctx] and re-evaluate each binder type at [armLevel] in [armEnv].
/// This reduces stuck VMatch values whose scrutinee became a VConstr
/// after hypothesis refinement substitution.
Ctx _normalizeChangedCtx(Ctx ctx, int armLevel, Env armEnv) {
  switch (ctx) {
    case CNil():
      return ctx;
    case CCons(
      :final type,
      :final value,
      :final env,
      :final level,
      :final rest,
    ):
      final newRest = _normalizeChangedCtx(rest, armLevel, armEnv);
      final newType = eval(quote(armLevel, type), armEnv);
      if (identical(newType, type) && identical(newRest, rest)) {
        return ctx;
      }
      return CCons(newType, value, env, level, newRest);
  }
}

Term _elabMatch(_ElabState state, SExpr expr, {Value? expected}) {
  final match = expr.kind as SMatchKind;
  final (scrutineeT, scrutineeV) = _inferExpr(state, match.scrutinee);

  // Determine the scrutinee's inductive type. Three sources, tried
  // in order:
  //   1. The explicit `returning` motive's declared return type. We
  //      elaborate the motive and let the checker verify it.
  //   2. The first non-wildcard arm's ctor name resolves (via the
  //      registry) to a DataDecl. That decl's name is the scrutinee's
  //      data type.
  //   3. Neither → `MatchIndeterminateType`.
  DataDecl? scrutineeData;
  for (final arm in match.cases) {
    if (arm is SMatchCase) {
      final ctor = _lookupCtorAnywhere(state.topEnv, arm.ctor);
      if (ctor == null) {
        throw UnknownCtorInMatch(arm.ctor, arm.span);
      }
      scrutineeData = state.topEnv.lookupData(ctor.dataName);
      break;
    }
  }
  // If no ctor arm revealed the type AND no explicit motive present,
  // we cannot elaborate (wildcard-only matches without a motive need
  // an expected type to recover the scrutinee's type).
  if (scrutineeData == null && match.motive == null) {
    throw MatchIndeterminateType(expr.span);
  }

  // If explicit motive present, elaborate it to a term. Null means
  // "user omitted `returning`; checker synthesizes the constant motive
  // from the expected type". We deliberately use null (a distinct
  // non-term value) rather than a sentinel term so the checker cannot
  // silently confuse "implicit motive" with "user literally wrote a
  // term that happens to look like our sentinel".
  //
  // The non-indexed case has a constant-function motive (explicit or
  // implicit), the arm bodies all have the same type. Indexed
  // families refine the motive per arm.
  final Term? motiveT =
      match.motive == null ? null : _inferExpr(state, match.motive!).$1;

  // Extract scrutinee params for real arm-binder types. This is
  // unconditional: SApp drives check-mode on nested args, which
  // conv-compares arm-binder types against expected domains, so arm
  // binders need REAL types
  // even in infer-mode match elaboration, not a VType(0)
  // placeholder).
  // conv-compares arm-binder types against expected domains, so arm
  // binders need REAL types
  // even in infer-mode match elaboration, not a VType(0)
  // placeholder).
  //
  // For VNeutral scrutinees (e.g., a function-parameter scrutinee in a
  // mutual-fun block), extract the data-type arguments from the scrutinee's
  // type in the context.
  List<Value>? scrutineeAllArgs;
  if (scrutineeV is VData && scrutineeData != null) {
    scrutineeAllArgs = scrutineeV.args;
  } else if (scrutineeV is VNeutral &&
      scrutineeV.neutral is NVar &&
      scrutineeData != null) {
    final scrutLevel = (scrutineeV.neutral as NVar).level;
    final scrutIdx = state.ctx.level - 1 - scrutLevel;
    if (scrutIdx >= 0) {
      final scrutType = state.ctx.lookupType(scrutIdx);
      if (scrutType is VData && scrutType.name == scrutineeData.name) {
        scrutineeAllArgs = scrutType.args;
      }
    }
  }

  List<Value>? paramsV;
  if (scrutineeAllArgs != null && scrutineeData != null) {
    final paramCount = scrutineeData.params.length;
    if (scrutineeAllArgs.length >= paramCount) {
      paramsV = scrutineeAllArgs.sublist(0, paramCount);
    }
  }

  // Validate ctor arms: each ctor must belong to scrutineeData, arity
  // must match, no duplicates. Track the first span per ctor for
  // duplicate reporting.
  final caseTerms = <TMatchCase>[];
  final seenCtors = <String, DoxaSpan>{};
  var hasWildcard = false;

  for (final arm in match.cases) {
    switch (arm) {
      case SMatchCase():
        final ctor = _lookupCtorAnywhere(state.topEnv, arm.ctor);
        if (ctor == null) {
          throw UnknownCtorInMatch(arm.ctor, arm.span);
        }
        if (scrutineeData != null && ctor.dataName != scrutineeData.name) {
          throw CtorMismatchInMatch(
            arm.ctor,
            ctor.dataName,
            scrutineeData.name,
            arm.span,
          );
        }
        // If we had no scrutineeData from a prior arm, set it now.
        scrutineeData ??= state.topEnv.lookupData(ctor.dataName);
        final expectedBinders = ctor.args.length;
        if (arm.binders.length != expectedBinders) {
          throw MatchArmArityMismatch(
            arm.ctor,
            arm.binders.length,
            expectedBinders,
            arm.span,
          );
        }
        if (seenCtors.containsKey(arm.ctor)) {
          throw DuplicateMatchCase(arm.ctor, seenCtors[arm.ctor]!, arm.span);
        }
        seenCtors[arm.ctor] = arm.span;
        // Elaborate body under state extended with arm binders. Each
        // binder's name is the user's source name (or "_" for
        // wildcards). Push left-to-right so the innermost binder
        // (TBound(0)) corresponds to the LAST arm binder, matching
        // the eval-time env-extension discipline.
        //
        // In check-mode entry (expected != null, paramsV available),
        // push REAL ctor-arg types (evaluated under paramsV + prior
        // arg neutrals) so the arm body's local binders have their
        // proper types in Ctx; body is then checked against a per-arm
        // refined expected type.
        //
        // In infer-mode (expected == null or scrutinee not well-
        // typed enough to extract params), fall back to VType(0)
        // placeholders and infer-mode body elaboration.
        var armState = state;
        // The telescope env built alongside the arm binders: params
        // (innermost-first) followed by one fresh neutral per ctor arg,
        // at the extending ctx levels. Mirrors `_checkMatchArmStep`'s
        // `teleEnv`, and is reused below to drive per-arm index
        // refinement. Null when paramsV is unavailable (infer-mode entry
        // or an under-applied scrutinee type).
        //
        // For ARG TYPE COMPUTATION we build a parallel enriched teleEnv
        // that replaces selected neutrals with actual scrutinee index
        // values.  A ctor arg gets the enriched value only when its
        // TBound reference appears as the function head of a TApp in a
        // subsequent arg type term (e.g. `R` in `R y x` inside `f`'s
        // type for `acc_intro`).  Named data-constructor arguments
        // (`n` in `Lt n m`) keep their neutral so the pattern binder
        // retains its own de-Bruijn identity.
        //
        // The standard armTeleEnv (all neutrals) is preserved for the
        // index refinement in `refineMatchArmExpected`.
        Env? armTeleEnv;
        if (paramsV != null) {
          // Determine which ctor args need actual index values.
          final argToIndexValue = <int, Value>{};
          if (scrutineeAllArgs != null && scrutineeData != null) {
            final paramCount = scrutineeData.params.length;
            if (scrutineeAllArgs.length > paramCount) {
              final indexValues = scrutineeAllArgs.sublist(paramCount);
              final argCount = ctor.args.length;
              for (
                var pos = 0;
                pos < ctor.resultIndices.length && pos < indexValues.length;
                pos++
              ) {
                final idxTerm = ctor.resultIndices[pos];
                if (idxTerm is TBound) {
                  final argIdx = argCount - 1 - idxTerm.index;
                  if (argIdx >= 0 && argIdx < argCount) {
                    argToIndexValue[argIdx] = indexValues[pos];
                  }
                }
              }
            }
          }
          // WILDCARD binders (`_`) get the enriched scrutinee index
          // value (they have no pattern-identity to preserve, e.g.
          // `acc_intro _ _ f`).  NAMED binders keep their neutral
          // (e.g. `y_` in `lt_trans y_ ...`), since substituting the
          // scrutinee's index value would alias the pattern binder
          // with a different variable at a different de-Bruijn level.
          final argNeedsEnrichment = <int>{};
          for (var j = 0; j < ctor.args.length; j++) {
            if (argToIndexValue.containsKey(j) && arm.binders[j] == '_') {
              argNeedsEnrichment.add(j);
            }
          }
          var teleEnv = const ENil() as Env;
          Env enrichedTeleEnv = teleEnv;
          for (var i = paramsV.length - 1; i >= 0; i--) {
            teleEnv = teleEnv.extend(paramsV[i]);
            enrichedTeleEnv = enrichedTeleEnv.extend(paramsV[i]);
          }
          for (var j = 0; j < ctor.args.length; j++) {
            // Compute arg type using enriched env so that closure-bound
            // index values β-reduce properly.
            final argTypeV = eval(ctor.args[j].type, enrichedTeleEnv);
            armState = armState.push(arm.binders[j], argTypeV);
            final neutral = VNeutral(NVar(armState.ctx.level - 1));
            teleEnv = teleEnv.extend(neutral);
            enrichedTeleEnv = enrichedTeleEnv.extend(
              argNeedsEnrichment.contains(j) ? argToIndexValue[j]! : neutral,
            );
          }
          armTeleEnv = teleEnv;
        } else {
          for (final b in arm.binders) {
            armState = armState.push(b, const VType(_l0));
          }
        }

        // Refine existing binder types that reference the scrutinee
        // variable. When the scrutinee is a neutral NVar, substitute it
        // with the constructor result value in all binder types so that
        // hypothesis types (e.g. `h: Eq Bool (even n) true_`) are refined
        // per arm (e.g. to `Eq Bool (even (succ k)) true_` in the succ arm).
        //
        // We eval scrutineeT (not scrutineeV from _inferExpr) because
        // _inferExpr returns the TYPE for local variables, not the
        // binder value. Evaluating the term in the state env gives us
        // the actual binder value (VNeutral(NVar(level))).
        if (scrutineeData != null) {
          final scrutineeValue = eval(scrutineeT, state.ctx.env);
          if (scrutineeValue is VNeutral && scrutineeValue.neutral is NVar) {
            final scrutLevel = (scrutineeValue.neutral as NVar).level;
            final ctorArgs = <Value>[
              for (var k = 0; k < ctor.args.length; k++)
                VNeutral(NVar(armState.ctx.level - ctor.args.length + k)),
            ];
            final ctorResultV = VConstr(
              scrutineeData.name,
              ctor.name,
              ctorArgs,
            );
            final substitutedCtx = substNVarInCtx(
              armState.ctx,
              scrutLevel,
              ctorResultV,
            );
            // Re-evaluate changed binder types by quoting at the arm
            // context level and evaluating in the arm env. This reduces
            // stuck VMatch values whose scrutinee became a VConstr.
            final armLevel = armState.ctx.level;
            final armEnv = armState.ctx.env;
            armState = _ElabState(
              armState.topEnv,
              _normalizeChangedCtx(substitutedCtx, armLevel, armEnv),
              armState.names,
            );
          }
        }

        // Elaborate the arm body. When the match has an expected type we
        // elaborate the body in CHECK mode against the arm's result
        // type, propagating the expected type into leaf positions
        // needed for bare nullary constructors whose type parameter is
        // implicit (`case none => none`, or `case vnil => vnil` in an
        // indexed family).
        //
        // For NON-indexed families the arm's result type is exactly
        // `expected`. For INDEXED families it is `expected` refined under
        // the constructor's index equations: e.g. matching `v : Vec[A] n`
        // with `returning Vec[A] (f n)`, the `vnil` arm's expected is
        // `Vec[A] (f zero)`, NOT raw `expected`. We compute that refined
        // type with the kernel's own first-order refinement
        // (`refineMatchArmExpected`) so the body checks against the SAME
        // type the kernel will demand at post-elab check time. Soundness
        // does not rest on this: the kernel independently re-runs the
        // refinement and re-checks the produced arm body.
        //
        // When refinement isn't possible (no expected type, or paramsV
        // unavailable so no teleEnv was built) we fall back to infer-mode
        // elaboration and let the kernel do the check.
        final Term bodyT;
        if (expected != null && scrutineeData != null) {
          if (scrutineeData.indices.isEmpty) {
            // For non-indexed data, the expected type may still depend
            // on the scrutinee variable (e.g. `Acc ... n` in nat_wf).
            // Refine per arm by substituting the scrutinee NVar with
            // the ctor result value.
            final Value armExpected;
            final scrutineeValue = eval(scrutineeT, state.ctx.env);
            if (scrutineeValue is VNeutral && scrutineeValue.neutral is NVar) {
              final scrutLevel = (scrutineeValue.neutral as NVar).level;
              final ctorArgs = <Value>[
                for (var k = 0; k < ctor.args.length; k++)
                  VNeutral(NVar(armState.ctx.level - ctor.args.length + k)),
              ];
              final ctorResultV = VConstr(
                scrutineeData.name,
                ctor.name,
                ctorArgs,
              );
              final rawV = substNVar(expected, scrutLevel, ctorResultV);
              // Normalize stuck function applications by quoting at the
              // arm context level and evaluating in the arm env. This
              // handles NVars from both the original and arm contexts.
              armExpected = eval(
                quote(armState.ctx.level, rawV),
                armState.ctx.env,
              );
            } else {
              armExpected = expected;
            }
            bodyT = _checkExpr(armState, arm.body, armExpected);
          } else if (armTeleEnv != null && scrutineeAllArgs != null) {
            final paramCount = scrutineeData.params.length;
            final scrutineeIndicesV = scrutineeAllArgs.sublist(paramCount);
            final armExpected = refineMatchArmExpected(
              ctx: state.ctx,
              armCtx: armState.ctx,
              expected: expected,
              scrutineeIndicesV: scrutineeIndicesV,
              ctorResultIndexTerms: ctor.resultIndices,
              teleEnv: armTeleEnv,
            );
            bodyT = _checkExpr(armState, arm.body, armExpected);
          } else {
            bodyT = _inferExpr(armState, arm.body).$1;
          }
        } else {
          bodyT = _inferExpr(armState, arm.body).$1;
        }

        caseTerms.add(
          TMatchCase(arm.ctor, arm.binders.length, bodyT, [
            for (final b in arm.binders) b == '_' ? null : b,
          ], span: arm.span),
        );

      case SWildcardCase():
        hasWildcard = true;
        // Same reasoning as ctor arms: elab-time infers, kernel-time
        // checks with refinement (wildcards unify with no ctor, so
        // there's no refinement, but `_checkMatchArmStep` still
        // routes wildcard arms through the check-mode path).
        final bodyT = _inferExpr(state, arm.body).$1;
        caseTerms.add(
          TMatchCase('', 0, bodyT, const <String?>[], span: arm.span),
        );
    }
  }

  // Coverage check. Two regimes:
  //
  //   * Non-indexed data (scrutineeData.indices is empty): elab-time
  //     syntactic coverage. Every ctor must appear in `seenCtors` OR
  //     a wildcard is present. Failure raises `NonExhaustiveMatch`
  //     eagerly. This is exhaustive because no ctor can be made
  //     unreachable without indices.
  //
  //   * Indexed data (scrutineeData.indices not empty): defer coverage
  //     to the checker. A ctor can be unreachable when its
  //     `resultIndices` clash with the scrutinee's actual indices
  //     (e.g. `vnil : Vec[A] zero` is unreachable when matching on
  //     `Vec[A] (succ n)` because `zero` ≠ `succ _`). Elab doesn't
  //     know the scrutinee's indices, only the checker does.
  //     `IndexedMatchNotExhaustive` fires there if any uncovered
  //     ctor is actually reachable.
  //
  // If scrutineeData is null (wildcard-only + explicit motive),
  // coverage is implicitly satisfied by the wildcard.
  final isIndexed = scrutineeData != null && scrutineeData.indices.isNotEmpty;
  if (scrutineeData != null && !hasWildcard && !isIndexed) {
    final missing = <String>[];
    for (final c in scrutineeData.ctors) {
      if (!seenCtors.containsKey(c.name)) missing.add(c.name);
    }
    if (missing.isNotEmpty) {
      throw NonExhaustiveMatch(scrutineeData.name, missing, expr.span);
    }
  }

  return TMatch(scrutineeT, motiveT, caseTerms);
}

/// Look up a ctor by name anywhere in [topEnv]'s registry. Ctor names
/// are globally unique (enforced at `data`-decl time), so at most one
/// hit. Returns null if no ctor by that name is registered.
CtorDecl? _lookupCtorAnywhere(TopEnv topEnv, String name) {
  for (final d in topEnv.dataDecls) {
    for (final c in d.ctors) {
      if (c.name == name) return c;
    }
  }
  return null;
}

/// If [expr] is a literal dotted-ident chain (e.g. `Nat.rec`,
/// `Map.Inner.foo`), return the flattened `"Nat.rec"` string.
/// Otherwise return null.
///
/// Used by dotted-name resolution in `_elabExpr`. Rejects dots on
/// non-ident qualifiers like `(f x).baz`, those would need UFCS /
/// method-call semantics, which are not supported.
String? _flattenDottedIdent(SExpr expr) {
  switch (expr.kind) {
    case SIdentKind(:final name):
      return name;
    case SDotKind(:final qualifier, :final name):
      final q = _flattenDottedIdent(qualifier);
      if (q == null) return null;
      return '$q.$name';
    case SAppKind(:final fn):
      // Type-applied qualifiers like `Acc[Nat].rec`: strip type args
      // and flatten to `Acc.rec` so the flat topBindings lookup works.
      return _flattenDottedIdent(fn);
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Declaration elaboration
// ---------------------------------------------------------------------------

/// Elaborate a single declaration, producing a [TopBinding] to be added
/// to the running environment.
///
/// Raises [DuplicateDeclaration] if the name already exists in
/// [topEnv]; raises [UnresolvedName] on any free identifier in the
/// declaration's body that is neither locally bound nor a name defined
/// earlier in [topEnv].
DeclResult _elabDecl(TopEnv topEnv, SDecl decl) {
  _checkDuplicate(topEnv, decl);
  final kind = decl.kind;
  // Per-declaration MetaContext, fresh per call: `insert'` and
  // downstream check-site insertion
  // allocate into this context; `checkDeclResult` installs it on
  // the check-time Ctx so the kernel's `_Infer(TMeta)` path
  // resolves solutions back to their solved terms.
  // Also enable semantic metadata collection.
  final metas = MetaContext()..semInfos = <SemInfo>[];
  switch (kind) {
    case SValKind(:final name, :final type, :final body):
      final Term bodyTerm;
      final Term typeTerm;
      if (type != null) {
        // Elaborate the declared type first, then elaborate the body in
        // CHECK mode against it. Threading the expected type into the
        // body lets the expected type reach leaf positions, e.g. a bare
        // nullary constructor whose type parameter is implicit
        // (`val xs: List[Nat] = nil`) solves its parameter from the
        // declared type.
        typeTerm = _elabExpr(topEnv, const _LocalNil(), type, metas: metas);
        final valState = _shimState(topEnv, const _LocalNil(), metas: metas);
        // Validate that the declared type is itself a well-formed type
        // (its own type is a sort) BEFORE checking the body against it.
        // This preserves the `NotAType` diagnostic for an ill-formed
        // declared type (e.g. `val bad: f -> Type = …` where `f` is not a
        // type): without this, the body's check would surface a less
        // precise `type mismatch` first.
        infer(valState.ctx, typeTerm);
        final expectedV = eval(typeTerm, valState.ctx.env);
        bodyTerm = _checkExpr(valState, body, expectedV);
      } else {
        bodyTerm = _elabExpr(topEnv, const _LocalNil(), body, metas: metas);
        final inferred = infer(topEnv.toCtx(), bodyTerm);
        typeTerm = quote(topEnv.bindings.length, inferred);
      }
      return (
        bindings: [
          TopBinding(
            name: name,
            type: typeTerm,
            term: bodyTerm,
            span: decl.span,
            isOpaque: kind.isOpaque,
          ),
        ],
        dataDecls: const <DataDecl>[],
        corecursiveGroup: null,
        metas: metas,
        classRegistry: const {},
        namespaceBindings: const {},
      );

    case STypeAliasKind(:final name, :final body):
      final bodyTerm = _elabExpr(topEnv, const _LocalNil(), body, metas: metas);
      final inferred = infer(topEnv.toCtx(), bodyTerm);
      final typeTerm = quote(topEnv.bindings.length, inferred);
      return (
        bindings: [
          TopBinding(
            name: name,
            type: typeTerm,
            term: bodyTerm,
            span: decl.span,
          ),
        ],
        dataDecls: const <DataDecl>[],
        corecursiveGroup: null,
        metas: metas,
        classRegistry: const {},
        namespaceBindings: const {},
      );

    case SFunKind():
      // A single `fun` is a 1-member mutual block. Delegate to
      // _elabFunBlock so the recursive / non-recursive split,
      // structural-recursion check, self-pre-registration, and
      // CorecursiveGroup emission all live in exactly one place.
      //
      // This is cheap: TTop(name) is position-independent, so
      // collapsing the single-fun path into
      // the block path costs nothing and removes the duplicated
      // "dummy TType(0) placeholder" site.
      final blockResult = _elabFunBlock(topEnv, decl.span, [
        SFunBlockMember(kind, decl.span),
      ], metas: metas);
      return (
        bindings: blockResult.bindings,
        dataDecls: const <DataDecl>[],
        corecursiveGroup:
            blockResult.group.members.isEmpty ? null : blockResult.group,
        metas: metas,
        classRegistry: const {},
        namespaceBindings: const {},
      );

    case SDataKind():
      // Elaborate the declaration into a DataDecl, and in the same
      // step produce the `T.rec` TopBinding (plus `T.rect` for Prop-
      // sorted singletons) so user code can reference the recursors
      // by name.
      final dataDecl = _elabData(topEnv, decl.span, kind);
      final recBindings = _makeRecBindings(topEnv, dataDecl, decl.span);
      final nsNames = {
        for (final b in recBindings) b.name,
        for (final c in dataDecl.ctors) c.name,
      };
      return (
        bindings: recBindings,
        dataDecls: [dataDecl],
        corecursiveGroup: null,
        metas: metas,
        classRegistry: const {},
        namespaceBindings: {kind.name: nsNames},
      );

    case SDataBlockKind(:final members):
      // Mutual `data` block. Elaborate the
      // whole block in two passes; each member gets its own T.rec
      // binding (plus `T.rect` if applicable) spanned to the member
      // (not the whole block).
      final dataDecls = _elabDataBlock(topEnv, decl.span, members);
      final recBindings = [
        // Each recursor binding gets its parent data decl's span
        // (which is the member's span, not the block's) so
        // diagnostics on a recursor cite its own data.
        for (final d in dataDecls) ..._makeRecBindings(topEnv, d, d.span),
      ];
      return (
        bindings: recBindings,
        dataDecls: dataDecls,
        corecursiveGroup: null,
        metas: metas,
        classRegistry: const {},
        namespaceBindings: {
          for (final d in dataDecls)
            d.name: {
              for (final b in _makeRecBindings(topEnv, d, d.span)) b.name,
              for (final c in d.ctors) c.name,
            },
        },
      );

    case SImportKind(:final path, :final importedNames, :final alias):
      return _processImport(
        topEnv,
        path,
        decl.span,
        importedNames: importedNames,
        alias: alias,
      );

    case SFunBlockKind(:final members):
      // Mutual `fun ... and ...` block. The block-level _elabFunBlock
      // handles duplicate detection, structural-recursion check,
      // two-pass elaboration, and produces the CorecursiveGroup
      // describing the atomic scoping unit. When the block is actually
      // non-recursive (members don't reference each other), the group
      // is empty and we emit null so the CLI falls back to per-binding
      // check.
      final blockResult = _elabFunBlock(
        topEnv,
        decl.span,
        members,
        metas: metas,
      );
      return (
        bindings: blockResult.bindings,
        dataDecls: const <DataDecl>[],
        corecursiveGroup:
            blockResult.group.members.isEmpty ? null : blockResult.group,
        metas: metas,
        classRegistry: const {},
        namespaceBindings: const {},
      );

    case STypeclassKind(
      :final name,
      :final typeParams,
      :final methods,
      :final superclass,
    ):
      return _elabTypeclass(
        topEnv,
        decl.span,
        name,
        typeParams,
        methods,
        superclass,
        metas: metas,
      );

    case SImplKind(:final typeclassRef, :final members):
      return _elabImpl(topEnv, decl.span, typeclassRef, members, metas: metas);
  }
}

/// Build a synthetic lambda body from a method's body and param names.
// ignore: unused_element
Term _buildMethodLambda(
  List<(String, SExpr)> params,
  Term body,
  List<Term> domains,
) {
  var result = body;
  for (var i = params.length - 1; i >= 0; i--) {
    result = TLam(domains[i], result, name: params[i].$1);
  }
  return result;
}

/// Build a surface Pi type for a method: `(x1: T1) -> ... -> (xn: Tn) -> R`.
// ignore: unused_element
SExpr _buildMethodPiType(
  String name,
  List<(String, SExpr)> params,
  SExpr retType,
) {
  var ty = retType;
  const span = DoxaSpan.synthetic;
  for (final p in params.reversed) {
    ty = SExpr(SPiKind(p.$1, p.$2, ty), span);
  }
  return ty;
}

/// Elaborate a `typeclass` declaration by desugaring it to a `data`
/// declaration with a single `mk` constructor.
///
/// `typeclass Eq[A] { fun equals(x: A, y: A): Bool }`
/// ↓
/// `data Eq[A] : Type { mk : (equals: (x: A) -> (y: A) -> Bool) -> Eq[A] }`
DeclResult _elabTypeclass(
  TopEnv topEnv,
  DoxaSpan span,
  String name,
  List<(String, SExpr?)> typeParams,
  List<SClassMethod> methods,
  SExpr? superclass, {
  MetaContext? metas,
}) {
  // Build the mk constructor's argument type.
  // For superclasses, the first field is the superclass instance.
  final ctorFields = <SExpr>[];
  final ctorFieldNames = <String>[];

  if (superclass != null) {
    // Superclass becomes first field: `(eqInst: Eq[A])`.
    // Build `Eq[A]` from superclass expr applied to type param idents.
    var superTy = superclass;
    for (final tp in typeParams) {
      superTy = SExpr(
        SAppKind(superTy, SExpr(SIdentKind(tp.$1), DoxaSpan.synthetic)),
        DoxaSpan.synthetic,
      );
    }
    ctorFields.add(superTy);
    ctorFieldNames.add('superInst');
  }

  for (final m in methods) {
    final methodType = m.type!;
    ctorFields.add(methodType);
    ctorFieldNames.add(m.name);
  }

  // Build the result type: `Eq[A]` applied to type params.
  SExpr resultType = SExpr(SIdentKind(name), DoxaSpan.synthetic);
  for (final tp in typeParams) {
    resultType = SExpr(
      SAppKind(resultType, SExpr(SIdentKind(tp.$1), DoxaSpan.synthetic)),
      DoxaSpan.synthetic,
    );
  }

  // Build the ctor Pi chain: `(equals: (x: A) -> ...) -> Eq[A]`
  SExpr ctorType = resultType;
  for (var i = ctorFields.length - 1; i >= 0; i--) {
    ctorType = SExpr(
      SPiKind(ctorFieldNames[i], ctorFields[i], ctorType),
      DoxaSpan.synthetic,
    );
  }

  final ctorDecl = SCtorDecl('mk_$name', ctorType, DoxaSpan.synthetic);
  const signature = SExpr(STypeKind(null), DoxaSpan.synthetic);
  final sDataKind = SDataKind(name, typeParams, signature, [ctorDecl]);

  // Elaborate the data declaration.
  final dataDecl = _elabData(topEnv, span, sDataKind);
  final recBindings = _makeRecBindings(topEnv, dataDecl, span);

  // Register in classRegistry.
  final methodInfos = <(String, SExpr)>[
    for (final m in methods) (m.name, m.type!),
  ];

  return (
    bindings: recBindings,
    dataDecls: [dataDecl],
    corecursiveGroup: null,
    metas: metas,
    classRegistry: {
      name: ClassInfo(
        className: name,
        typeParams: typeParams.map((t) => t.$1).toList(),
        methods: methodInfos,
        superclassName:
            superclass != null
                ? (superclass.kind is SIdentKind
                    ? (superclass.kind as SIdentKind).name
                    : null)
                : null,
      ),
    },
    namespaceBindings: const {},
  );
}

/// Elaborate an `impl` declaration: `impl Eq[Int] { fun equals(x, y) { ... } }`.
///
/// Desugars to a `val` binding whose value is the `mk(...)` constructor
/// applied to the method implementations.
DeclResult _elabImpl(
  TopEnv topEnv,
  DoxaSpan span,
  SExpr typeclassRef,
  List<SFunKind> members, {
  MetaContext? metas,
}) {
  // Resolve the typeclass reference to get the class name.
  final String className;
  switch (typeclassRef.kind) {
    case SIdentKind(:final name):
      className = name;
    case SAppKind(:final fn):
      if (fn.kind case SIdentKind(:final name)) {
        className = name;
      } else {
        throw UnresolvedName('<complex typeclass ref>', typeclassRef.span);
      }
    default:
      throw UnresolvedName('<complex typeclass ref>', typeclassRef.span);
  }

  final classInfo = topEnv.classRegistry[className];
  if (classInfo == null) {
    throw UnresolvedName('typeclass "$className" not found', typeclassRef.span);
  }

  // Elaborate the typeclass reference to get its full type.
  final refTerm = _elabExpr(
    topEnv,
    const _LocalNil(),
    typeclassRef,
    metas: metas,
  );

  // Build the constructor application: mk(method1, method2, ...)
  // First, elaborate each method body as a lambda.
  final methodTerms = <Term>[];

  for (final member in members) {
    // Find the corresponding method in the class.
    final methodInfo =
        classInfo.methods.where((m) => m.$1 == member.name).firstOrNull;
    if (methodInfo == null) {
      // Unknown method - this will be caught by type checking.
      break;
    }
    final allBinders = <_FunBinder>[
      for (final tp in member.typeParams)
        _FunBinder(
          tp.name,
          tp.kind ?? const SExpr(STypeKind(null), DoxaSpan.synthetic),
          tp.isImplicit ? Icit.implicit : Icit.explicit,
        ),
      for (final p in member.params) _FunBinder(p.$1, p.$2, Icit.explicit),
    ];
    final bodyTerm = _buildFunBody(
      topEnv,
      allBinders,
      member.body,
      member.returnType,
      metas: metas,
    );
    methodTerms.add(bodyTerm);
  }

  if (methodTerms.length != classInfo.methods.length) {
    throw StateError(
      'impl $className: expected ${classInfo.methods.length} methods, '
      'got ${methodTerms.length}',
    );
  }

  // Build `mk` constructor term with all arguments (type args + methods).
  // TConstr takes the full spine: data type params followed by ctor args.
  final typeArgTerms = <Term>[];
  switch (typeclassRef.kind) {
    case SAppKind(:final arg):
      typeArgTerms.add(_elabExpr(topEnv, const _LocalNil(), arg, metas: metas));
    case _:
      break;
  }
  final Term implTerm = TConstr(className, 'mk_$className', [
    ...typeArgTerms,
    ...methodTerms,
  ]);

  // Generate synthetic name for the instance.
  final targetType = switch (typeclassRef.kind) {
    SAppKind(:final arg) => switch (arg.kind) {
      SIdentKind(:final name) => name,
      _ => '',
    },
    _ => '',
  };
  final instanceName =
      targetType.isNotEmpty
          ? '_impl_${className}_$targetType'
          : '_impl_$className';

  // Determine target type for instance registration.

  return (
    bindings: [
      TopBinding(name: instanceName, type: refTerm, term: implTerm, span: span),
    ],
    dataDecls: const <DataDecl>[],
    corecursiveGroup: null,
    metas: metas,
    classRegistry: {
      className: classInfo.withInstance(InstanceInfo(targetType, instanceName)),
    },
    namespaceBindings: const {},
  );
}

/// Process an `import "path"` declaration, optionally filtering to
/// only the named bindings when [importedNames] is non-empty.
///
/// Loads the imported file, recursively elaborates and type-checks its
/// declarations, and returns the merged bindings and data decls.
/// Detects cycles via [_importStack] and rejects duplicates against
/// the calling [topEnv].
DeclResult _processImport(
  TopEnv topEnv,
  String path,
  DoxaSpan span, {
  List<String> importedNames = const [],
  String? alias,
}) {
  if (currentImportPath == null) {
    throw StateError(
      'currentImportPath is not set; cannot resolve import "$path"',
    );
  }
  final resolvedPath = _resolveImportPath(path, currentImportPath!);

  // Idempotent import: if this file was already imported (by a prior
  // import at the current level), silently return no new bindings.
  if (importedPaths.contains(resolvedPath)) {
    return (
      bindings: const <TopBinding>[],
      dataDecls: const <DataDecl>[],
      corecursiveGroup: null,
      metas: MetaContext()..semInfos = <SemInfo>[],
      classRegistry: const {},
      namespaceBindings: const {},
    );
  }

  if (_importStack.contains(resolvedPath)) {
    throw CyclicImport(resolvedPath, span);
  }

  final file = File(resolvedPath);
  if (!file.existsSync()) {
    throw ImportFileNotFound(resolvedPath, span);
  }
  final source = file.readAsStringSync();
  final parseResult = parseProgram(source);
  final prog = switch (parseResult) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() =>
      throw StateError('Failed to parse import: $resolvedPath'),
  };

  _importStack.add(resolvedPath);
  final prevFilePath = currentImportPath;
  currentImportPath = resolvedPath;

  try {
    var localBindings = const <TopBinding>[];
    var localDataDecls = const <DataDecl>[];
    var localNamespace = <String, Set<String>>{};
    var localClassRegistry = <String, ClassInfo>{};

    for (final decl in prog.decls) {
      final runningEnv = TopEnv(
        [...topEnv.bindings, ...localBindings],
        [...topEnv.dataDecls, ...localDataDecls],
        {...topEnv.classRegistry, ...localClassRegistry},
        mergeNamespace(topEnv.namespaceBindings, localNamespace),
      );
      final produced = _elabDecl(runningEnv, decl);
      final runningData = [...localDataDecls, ...produced.dataDecls];
      // For import decls inside the imported file, expand the env so
      // checkDeclResult can verify cross-references within the import.
      final checkBindings =
          decl.kind is SImportKind
              ? [...topEnv.bindings, ...localBindings, ...produced.bindings]
              : [...topEnv.bindings, ...localBindings];
      final checkEnv = TopEnv(
        checkBindings,
        [...topEnv.dataDecls, ...runningData],
        {...topEnv.classRegistry, ...localClassRegistry},
        mergeNamespace(topEnv.namespaceBindings, localNamespace),
      );
      final finalized = checkDeclResult(checkEnv, produced);
      localBindings = [...localBindings, ...finalized];
      localDataDecls = runningData;
      localClassRegistry = {...localClassRegistry, ...produced.classRegistry};
      localNamespace = mergeNamespace(
        localNamespace,
        produced.namespaceBindings,
      );
    }

    // Selective import: filter to only the named bindings.
    if (importedNames.isNotEmpty) {
      localBindings =
          localBindings.where((b) => importedNames.contains(b.name)).toList();
      localDataDecls =
          localDataDecls.where((d) => importedNames.contains(d.name)).toList();
    }

    // Check for duplicates against the calling topEnv.
    final seen = <String>{};
    for (final b in localBindings) {
      if (!seen.add(b.name)) {
        throw DuplicateDeclaration(b.name, span, span);
      }
      final existing = topEnv.spanOf(b.name);
      if (existing != null) {
        throw DuplicateDeclaration(b.name, existing, span);
      }
    }
    for (final d in localDataDecls) {
      if (!seen.add(d.name)) {
        throw DuplicateDeclaration(d.name, span, span);
      }
      final existing = topEnv.spanOf(d.name);
      if (existing != null) {
        throw DuplicateDeclaration(d.name, existing, span);
      }
    }

    importedPaths.add(resolvedPath);

    // Build namespace-qualified entries.
    final modPrefix = alias ?? _modulePrefix(path);
    final nsMap = <String, Set<String>>{};
    if (modPrefix.isNotEmpty) {
      final names = <String>{
        for (final b in localBindings) b.name,
        for (final d in localDataDecls) d.name,
        for (final d in localDataDecls)
          for (final c in d.ctors) c.name,
      };
      if (names.isNotEmpty) {
        nsMap[modPrefix] = names;
      }
    }

    return (
      bindings: localBindings,
      dataDecls: localDataDecls,
      corecursiveGroup: null,
      metas: MetaContext()..semInfos = <SemInfo>[],
      classRegistry: localClassRegistry,
      namespaceBindings: nsMap,
    );
  } finally {
    currentImportPath = prevFilePath;
    _importStack.removeLast();
  }
}

/// Elaborate a single `fun` into a [TopBinding].
/// Build implicit [SExpr] for a constraint applied to a type param:
/// `App(constraintExpr, Ident(paramName))`.
SExpr _constraintApp(SExpr constraint, String paramName) => SExpr(
  SAppKind(constraint, SExpr(SIdentKind(paramName), DoxaSpan.synthetic)),
  DoxaSpan.synthetic,
);

/// Build constraint binders for a type parameter with constraints.
/// Each constraint becomes an implicit binder: `(inst: Eq[A])`.
List<_FunBinder> _constraintBinders(SFunTypeParam tp) => [
  for (final c in tp.constraints)
    _FunBinder(
      'inst_${tp.name}_${c.hashCode}',
      _constraintApp(c, tp.name),
      Icit.implicit,
    ),
];

TopBinding _elabFun(
  TopEnv topEnv,
  DoxaSpan span,
  SFunKind kind, {
  MetaContext? metas,
}) {
  final allBinders = <_FunBinder>[
    for (final tp in kind.typeParams) ...[
      _FunBinder(
        tp.name,
        tp.kind ?? const SExpr(STypeKind(null), DoxaSpan.synthetic),
        tp.isImplicit ? Icit.implicit : Icit.explicit,
      ),
      ..._constraintBinders(tp),
    ],
    for (final p in kind.params) _FunBinder(p.$1, p.$2, Icit.explicit),
  ];
  final funBodyTerm = _buildFunBody(
    topEnv,
    allBinders,
    kind.body,
    kind.returnType,
    metas: metas,
  );
  final funTypeTerm = _buildFunType(
    topEnv,
    allBinders,
    kind.returnType,
    metas: metas,
  );
  return TopBinding(
    name: kind.name,
    type: funTypeTerm,
    term: funBodyTerm,
    span: span,
    isOpaque: kind.isOpaque,
  );
}

/// Elaborate a `fun ... and ...` block.
///
/// Discipline (matches Coq `Fixpoint ... with`, Lean `mutual def`,
/// Agda `mutual`):
///
///   1. Check duplicates within the block and against the enclosing
///      [topEnv].
///   2. Run the structural-recursion walker on every member
///      ([checkStructuralRecursion]). Rejects any non-structural
///      recursive call with [NonStructuralRecursion] *before*
///      producing any terms, if the block can't be accepted, we
///      don't want to emit partially-elaborated bindings.
///   3. Pass 1: elaborate each member's *signature* (type only)
///      against the outer [topEnv]. Signatures cannot reference
///      sibling members (the "header independence" limitation;
///      lifting it would require metavariables). Pre-build
///      [TopBinding]s with placeholder terms.
///   4. Pass 2: build a scratch [TopEnv] with all pre-bindings
///      registered, then elaborate each body against it. Sibling
///      and self references now resolve to the pre-registered
///      positions; TBound indices point at the right slots.
///   5. Returns both the fully-elaborated bindings and a
///      [CorecursiveGroup] describing the block. The CLI and test
///      harnesses use the group to pre-scope all members in Ctx
///      before type-checking any body (see bin/doxa.dart).
({List<TopBinding> bindings, CorecursiveGroup group}) _elabFunBlock(
  TopEnv topEnv,
  DoxaSpan blockSpan,
  List<SFunBlockMember> members, {
  MetaContext? metas,
}) {
  // Check duplicates within the block + against the outer env.
  final seen = <String, DoxaSpan>{};
  for (final m in members) {
    final f = m.fun;
    final prev = seen[f.name];
    if (prev != null) {
      throw DuplicateDeclaration(f.name, prev, m.span);
    }
    final existing = topEnv.spanOf(f.name);
    if (existing != null) {
      throw DuplicateDeclaration(f.name, existing, m.span);
    }
    seen[f.name] = m.span;
  }

  // Extract termination_by from return-type expressions.
  // The parser cannot distinguish `fun f(...): T termination_by (x) = body`
  // from `fun f(...): T termination_by (x) = body` because `_expr`
  // greedily consumes `termination_by (args)` as application arguments.
  // We walk the return-type AST and extract the suffix before elaboration.
  final extractedTby = <SFunBlockMember, ({List<String> tby, SExpr realRet})>{};
  for (final m in members) {
    final extracted = _extractTerminationBy(m.fun.returnType);
    if (extracted.tby != null) {
      extractedTby[m] = (tby: extracted.tby!, realRet: extracted.realRet);
    }
  }

  // Structural-recursion check. Runs on every member BEFORE we
  // elaborate any body, so a non-structural program fails early
  // with a clean surface-level error and no half-elaborated state.
  // Members with `termination_by` skip this check (well-founded
  // recursion doesn't need the structural sub-term check).
  final memberNames = {for (final m in members) m.fun.name};
  final memberDeclIdxs = <String, int>{
    for (final m in members) m.fun.name: _designatedArgIndex(m.fun) ?? 0,
  };
  final unguardedCrossCalls = <_CrossCall>[];
  for (final m in members) {
    if (m.fun.terminationBy == null && extractedTby[m] == null) {
      _checkStructuralRecursion(
        m.fun,
        memberNames,
        memberDeclIdxs,
        callerName: m.fun.name,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    }
    // Validate {struct name} annotation even for non-recursive members.
    if (m.fun.structAnn != null &&
        _findParamIndex(m.fun, m.fun.structAnn!) < 0) {
      throw StructAnnotationNotFound(m.fun.name, m.fun.structAnn!, m.span);
    }
    // Validate termination_by parameter names.
    final tby = extractedTby[m]?.tby ?? m.fun.terminationBy;
    if (tby != null) {
      for (final p in tby) {
        if (_findParamIndex(m.fun, p) < 0) {
          throw TerminationByParamNotFound(m.fun.name, p, m.span);
        }
      }
    }
  }
  _analyzeCrossCallCycles(unguardedCrossCalls, memberNames);

  // Pass 1: elaborate each member's signature against the outer
  // topEnv. Sibling references in signatures would fail with
  // UnresolvedName here, the "header independence" limitation
  // (lifting it would require metavariables).
  final preBindings = <TopBinding>[];
  for (final m in members) {
    final retType = extractedTby[m]?.realRet ?? m.fun.returnType;
    final typeTerm = _buildFunType(
      topEnv,
      [
        for (final tp in m.fun.typeParams) ...[
          _FunBinder(
            tp.name,
            tp.kind ?? const SExpr(STypeKind(null), DoxaSpan.synthetic),
            tp.isImplicit ? Icit.implicit : Icit.explicit,
          ),
          ..._constraintBinders(tp),
        ],
        for (final p in m.fun.params) _FunBinder(p.$1, p.$2, Icit.explicit),
      ],
      retType,
      metas: metas,
    );
    preBindings.add(
      TopBinding(
        name: m.fun.name,
        type: typeTerm,
        term: const TType(
          _l0,
        ), // never evaluated, TTop resolves via topBindings
        span: m.span,
        isOpaque: true, // stays stuck as NTop during elaboration
      ),
    );
  }

  // Pass 2: elaborate each body against a scratch env with all
  // siblings pre-registered. Sibling refs within bodies emit
  // `TTop(sibling.name)`, NOT
  // position-indexed TBound, so the scratch env's bindings list
  // order doesn't matter. All that matters is that
  // `indexOfFromEnd(name)` succeeds at elab time. Because TTop is
  // name-indexed, a block mixing non-recursive and recursive members
  // cannot suffer index drift.
  final scratchEnv = TopEnv([
    ...topEnv.bindings,
    ...preBindings,
  ], topEnv.dataDecls);
  final elaborated = <TopBinding>[];
  for (final m in members) {
    final fun =
        extractedTby[m] != null
            ? SFunKind(
              m.fun.name,
              m.fun.typeParams,
              m.fun.params,
              extractedTby[m]!.realRet,
              m.fun.body,
              isOpaque: m.fun.isOpaque,
              structAnn: m.fun.structAnn,
              terminationBy: extractedTby[m]!.tby,
            )
            : m.fun;
    elaborated.add(_elabFun(scratchEnv, m.span, fun, metas: metas));
    // Mark termination_by bindings as opaque so checkDeclResult
    // pre-seeds them as stubs during checking.
    if (fun.terminationBy != null) {
      elaborated.last = TopBinding(
        name: elaborated.last.name,
        type: elaborated.last.type,
        term: elaborated.last.term,
        span: elaborated.last.span,
        isOpaque: true,
      );
    }
  }

  // Decide whether the block contains any actual recursion. If
  // not, we DON'T emit a CorecursiveGroup, the bindings are
  // independent of each other and the plain per-binding check-
  // time discipline is correct. CorecursiveGroup is only for
  // members that need self/sibling stubs during their own check
  // (i.e. for bodies that would otherwise evaluate a yet-unknown
  // value during type-checking).
  //
  // Members with `termination_by` are excluded from this check:
  // they use well-founded recursion via `Acc.rec` and must
  // NOT receive a VFun guard or CorecursiveGroup stub.
  final isRecursive = members.any(
    (m) =>
        m.fun.terminationBy == null &&
        extractedTby[m] == null &&
        (_hasRecursiveReference(m.fun.body, memberNames) ||
            _hasRecursiveReference(m.fun.returnType, memberNames)),
  );

  if (!isRecursive) {
    return (
      bindings: elaborated,
      group: const CorecursiveGroup(<CorecursiveMember>[]),
    );
  }

  // Recursive: build the CorecursiveGroup. Each member paired with
  // its source SFunKind (provenance for later passes / diagnostics).
  final group = CorecursiveGroup([
    for (var i = 0; i < members.length; i++)
      CorecursiveMember(i, members[i].fun),
  ]);
  // Stamp guarded-reduction metadata onto each recursive member's
  // binding. The designated decreasing argument is
  // the first explicit value param (SPEC §8.6), or the `{struct name}`
  // annotation if present. It sits in the lambda chain AFTER all type
  // params, so its de-Bruijn position is `typeParams.length` by
  // default, adjusted to the annotated param's position. A member
  // with no value params has no decreasing argument and is left
  // unguarded (it can't recurse structurally anyway). `recArity` is
  // the full param count.
  final guarded = <TopBinding>[];
  for (final b in elaborated) {
    final fun = members.firstWhere((m) => m.fun.name == b.name).fun;
    if (fun.params.isEmpty) {
      guarded.add(b);
      continue;
    }
    final int decreasing;
    if (fun.structAnn != null) {
      decreasing = _findParamIndex(fun, fun.structAnn!);
      if (decreasing < 0) {
        throw StructAnnotationNotFound(
          fun.name,
          fun.structAnn!,
          members.firstWhere((m) => m.fun.name == b.name).span,
        );
      }
    } else {
      decreasing = fun.typeParams.length;
    }
    final arity = fun.typeParams.length + fun.params.length;
    guarded.add(
      TopBinding(
        name: b.name,
        type: b.type,
        term: b.term,
        span: b.span,
        recDecreasingArg: decreasing,
        recArity: arity,
        isOpaque: b.isOpaque,
      ),
    );
  }
  return (bindings: guarded, group: group);
}

/// Build `(A) => (x) => body` for a binder list `[(A, _), (x, _)]`.
/// Each lambda's icity is taken from the binder (implicit for
/// `{A: Type}`-style type params, explicit otherwise).
///
/// The body is elaborated in CHECK mode against the fun's return type
/// (first elaborated and evaluated under the extended state). This is
/// what enables `_elabMatch`'s first-order index-
/// refinement path to fire for `fun`-declared bodies like
/// `vtail{A}{n}(v: Vec[A] (succ n)): Vec[A] n = match v { ... }`.
/// Infer mode would produce a TMatch with motive=null and defer to
/// the kernel's post-elab check, which treats `expected` as constant
/// and rejects dependent-index cases.
Term _buildFunBody(
  TopEnv topEnv,
  List<_FunBinder> binders,
  SExpr body,
  SExpr returnType, {
  MetaContext? metas,
}) {
  // Build `_ElabState` from the outer topEnv, starting with no
  // locals. Push each binder with its real Value-level type so the
  // body's `_inferExpr` / `_checkExpr` paths see proper types at
  // each binder (critical for arm-binder Ctx correctness).
  var state = _shimState(topEnv, const _LocalNil(), metas: metas);
  final domains = <Term>[];
  for (final b in binders) {
    final (domT, _) = _inferExpr(state, b.type);
    final domV = eval(domT, state.ctx.env);
    domains.add(domT);
    state = state.push(b.name, domV);
  }
  // Elaborate the return type under the binder-extended state; eval
  // to get the expected Value for body check-mode elaboration.
  final (returnT, _) = _inferExpr(state, returnType);
  final returnV = eval(returnT, state.ctx.env);
  // Check-mode body elaboration: this is where the refinement
  // path fires for dependent matches.
  Term result = _checkExpr(state, body, returnV);
  // Wrap right-to-left with lambdas using the pre-computed domains.
  // Preserve the source parameter name as a diagnostic hint on each λ.
  for (var i = binders.length - 1; i >= 0; i--) {
    result = TLam(
      domains[i],
      result,
      name: binders[i].name,
      icit: binders[i].icit,
    );
  }
  return result;
}

/// Build `(A: KA) -> (x: Tx) -> R` for a binder list `[(A, KA), (x, Tx)]`.
/// Each Pi's icity is taken from the binder (implicit for
/// `{A: Type}`-style type params, explicit otherwise).
///
/// Lazy-motive parity: this mirrors [_buildFunBody]'s real-
/// types discipline. Each binder is pushed into the state with its
/// actual Value-level type (eval'd from the just-elaborated domain
/// Term) so that subsequent domain / return-type elaboration sees
/// correct binder types, enabling SApp's new check-mode arg
/// elaboration to drive motive β-substitution into nested args.
Term _buildFunType(
  TopEnv topEnv,
  List<_FunBinder> binders,
  SExpr returnType, {
  MetaContext? metas,
}) {
  var state = _shimState(topEnv, const _LocalNil(), metas: metas);
  final domains = <Term>[];
  for (final b in binders) {
    final (domT, _) = _inferExpr(state, b.type);
    final domV = eval(domT, state.ctx.env);
    domains.add(domT);
    state = state.push(b.name, domV);
  }
  final (returnT, _) = _inferExpr(state, returnType);
  // Preserve source parameter names as diagnostic hints on each Pi.
  Term result = returnT;
  for (var i = binders.length - 1; i >= 0; i--) {
    result = TPi(
      domains[i],
      result,
      name: binders[i].name,
      icit: binders[i].icit,
    );
  }
  return result;
}

void _checkDuplicate(TopEnv topEnv, SDecl decl) {
  final existing = topEnv.spanOf(decl.name);
  if (existing != null) {
    throw DuplicateDeclaration(decl.name, existing, decl.span);
  }
}

// ---------------------------------------------------------------------------
// Structural-recursion checker
// ---------------------------------------------------------------------------

/// Walks [kind]'s body, return type, and parameter types looking for
/// references to names in [blockMembers], the set of functions in
/// the same mutual block as [kind], including [kind.name] itself.
/// Each such reference must appear in applied form where the
/// designated-arg-position argument is a syntactic strict sub-term of
/// [kind]'s own designated decreasing argument. Anything else raises
/// [NonStructuralRecursion].
///
/// The designated argument convention: the first explicit value-level
/// `fun` parameter. Type-parameter binders ([SFunKind.typeParams])
/// don't count. A function with no value parameters has no designated
/// argument, so any reference to a block member from its body is
/// non-structural by definition.
///
/// Strict sub-term relation (syntactic):
///   * A pattern binder introduced by `match`ing on the designated
///     argument (or any strict sub-term of it) is itself a strict
///     sub-term.
///   * No other identifier qualifies, in particular, the designated
///     argument itself is NOT a strict sub-term of itself (that
///     would admit non-terminating self-recursion).
///
/// The walker tracks shadowing: lambda params, `let` binders, inner
/// `match` binders, and Pi binders that mask a block-member name
/// suppress the check for that occurrence. Dotted references
/// (`Foo.bar`) whose qualifier is a bare ident also walk into the
/// qualifier for shadowing purposes.
///
/// Exposed as a stand-alone, directly testable entry point; the
/// elaboration pipeline invokes it from [_elabDecl]'s `fun` paths.
void checkStructuralRecursion(
  SFunKind kind,
  Set<String> blockMembers, [
  Map<String, int> memberDeclIdxs = const <String, int>{},
  List<SFunKind> blockKinds = const <SFunKind>[],
]) {
  final calls = <_CrossCall>[];
  final allKinds = [kind, ...blockKinds];
  for (final k in allKinds) {
    _checkStructuralRecursion(
      k,
      blockMembers,
      memberDeclIdxs,
      callerName: k.name,
      unguardedCrossCalls: calls,
    );
  }
  _analyzeCrossCallCycles(calls, blockMembers);
}

/// Find the de-Bruijn position of a value parameter [name] in [fun].
/// Returns the position counting type params first, so the first value
/// param has position [fun.typeParams.length]. Returns -1 if not found.
/// Extract `termination_by` parameter names from the return-type
/// expression of [fun]. The parser cannot distinguish
/// `fun f(...): T termination_by (x) = body` from a regular application
/// `T termination_by (x)`, so we walk the return-type AST to detect
/// a `termination_by(args...)` suffix.
///
/// Returns a record `(tbyNames, realReturnType)` where [tbyNames] are
/// the extracted parameter names (null if not found) and [realReturnType]
/// is the corrected return type (original if not found).
({List<String>? tby, SExpr realRet}) _extractTerminationBy(SExpr returnType) {
  // Walk SAppKind chain: App(App(...App(realRet, term_by), arg0), arg1)
  // Collect args from outermost to term_by.
  final chain = <SAppKind>[];
  SExpr? cur = returnType;
  while (cur != null && cur.kind is SAppKind) {
    chain.add(cur.kind as SAppKind);
    cur = (cur.kind as SAppKind).fn;
  }
  // Find the innermost app whose arg is `termination_by`.
  var termByIdx = -1;
  for (var i = chain.length - 1; i >= 0; i--) {
    final arg = chain[i].arg.kind;
    if (arg is SIdentKind && arg.name == 'termination_by') {
      termByIdx = i;
      break;
    }
  }
  if (termByIdx < 0) return (tby: null, realRet: returnType);
  // Collect args ABOVE termByIdx (outer apps: termByIdx-1 down to 0).
  final names = <String>[];
  for (var i = termByIdx - 1; i >= 0; i--) {
    final arg = chain[i].arg.kind;
    if (arg is SIdentKind) {
      names.add(arg.name);
    } else {
      // Non-ident arg — this is a real application, not termination_by.
      return (tby: null, realRet: returnType);
    }
  }
  // The real return type is the fn of the app at termByIdx.
  final realRet = chain[termByIdx].fn;
  return (tby: names, realRet: realRet);
}

int _findParamIndex(SFunKind fun, String name) {
  for (var i = 0; i < fun.params.length; i++) {
    if (fun.params[i].$1 == name) return fun.typeParams.length + i;
  }
  return -1;
}

/// Compute the position of the designated argument among the value params.
/// Returns null when there is no designated argument. The returned index
/// is relative to the value-param list only (not including type params),
/// matching the arg position in application calls where type args are
/// implicit/elided.
int? _designatedArgIndex(SFunKind kind) {
  if (kind.params.isEmpty) return null;
  if (kind.structAnn != null) {
    for (var i = 0; i < kind.params.length; i++) {
      if (kind.params[i].$1 == kind.structAnn) return i;
    }
    // Should not reach here if structAnn was validated earlier.
    return null;
  }
  return 0; // first value param
}

void _checkStructuralRecursion(
  SFunKind kind,
  Set<String> blockMembers,
  Map<String, int> memberDeclIdxs, {
  required String callerName,
  required List<_CrossCall> unguardedCrossCalls,
}) {
  // Shadow set: type-params and all value-params start in scope
  // (they mask any block-member name that coincides with them).
  final shadowed = <String>{
    for (final tp in kind.typeParams) tp.name,
    for (final p in kind.params) p.$1,
  };
  // Designated argument: the `{struct <name>}` annotation, or the
  // first explicit value param if no annotation is given.
  final String? designated =
      kind.structAnn ?? (kind.params.isNotEmpty ? kind.params.first.$1 : null);
  final int? designatedIdx = _designatedArgIndex(kind);

  // Walk the body and the return type, both are in the function's
  // scope, so both can mention block members. Param types and
  // type-param bounds walk with an empty scope (no designated arg),
  // so any block-member reference there is non-structural (they
  // execute before any pattern match could introduce sub-terms).
  _walkForRecursion(
    expr: kind.body,
    blockMembers: blockMembers,
    designated: designated,
    designatedIdx: designatedIdx,
    subTerms: const <String>{},
    shadowed: shadowed,
    memberDeclIdxs: memberDeclIdxs,
    callerName: callerName,
    unguardedCrossCalls: unguardedCrossCalls,
  );
  _walkForRecursion(
    expr: kind.returnType,
    blockMembers: blockMembers,
    designated: designated,
    designatedIdx: designatedIdx,
    subTerms: const <String>{},
    shadowed: shadowed,
    memberDeclIdxs: memberDeclIdxs,
    callerName: callerName,
    unguardedCrossCalls: unguardedCrossCalls,
  );
  for (final p in kind.params) {
    _walkForRecursion(
      expr: p.$2,
      blockMembers: blockMembers,
      designated: null,
      designatedIdx: null,
      subTerms: const <String>{},
      shadowed: const <String>{},
      memberDeclIdxs: memberDeclIdxs,
      callerName: callerName,
      unguardedCrossCalls: unguardedCrossCalls,
    );
  }
  for (final tp in kind.typeParams) {
    if (tp.kind != null) {
      _walkForRecursion(
        expr: tp.kind!,
        blockMembers: blockMembers,
        designated: null,
        designatedIdx: null,
        subTerms: const <String>{},
        shadowed: const <String>{},
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    }
  }
}

/// Run a DFS on the unguarded-cross-call graph. If a cycle exists, throw
/// [NonStructuralRecursion] for the first cross-call participating in a
/// cycle. A DAG of unguarded edges is accepted (mutual recursion where
/// each path through the call graph eventually reaches a guarded call).
///
/// Self-loops (caller == callee) are already rejected as immediate
/// [NonStructuralRecursion] by the walker, so they never reach here.
void _analyzeCrossCallCycles(
  List<_CrossCall> unguardedCrossCalls,
  Set<String> blockMembers,
) {
  if (unguardedCrossCalls.isEmpty) return;
  // Build adjacency list.
  final graph = <String, List<_CrossCall>>{};
  for (final c in unguardedCrossCalls) {
    (graph[c.caller] ??= []).add(c);
  }
  // DFS state.
  final white = <String>{...blockMembers};
  final grey = <String>{};
  final black = <String>{};
  void dfs(String node) {
    white.remove(node);
    grey.add(node);
    final edges = graph[node];
    if (edges != null) {
      for (final e in edges) {
        if (grey.contains(e.callee)) {
          throw NonStructuralRecursion(e.callee, e.span);
        }
        if (white.contains(e.callee)) {
          dfs(e.callee);
        }
      }
    }
    grey.remove(node);
    black.add(node);
  }

  for (final n in white.toList()) {
    dfs(n);
  }
}

/// Returns true if [name] is a dotted inductively-generated recursor
/// name (e.g. `Nat.ind`, `Bool.rec`, `Eq.rect`).
bool _isInductiveRecursor(String name) {
  final dot = name.indexOf('.');
  if (dot < 0) return false;
  final suffix = name.substring(dot + 1);
  return suffix == 'ind' || suffix == 'rec' || suffix == 'rect';
}

/// Walk the step lambda of an induction principle call (e.g. `Nat.ind`).
/// The step function has shape `(k: Nat) => (ih: ...) => body`.  The
/// predecessor parameter `k` is added to [subTerms] when walking the
/// body, since `k` is a strict sub-term of the induction scrutinee.
void _walkStepForInd(
  SExpr step, {
  required Set<String> blockMembers,
  required String? designated,
  required int? designatedIdx,
  required Set<String> subTerms,
  required Set<String> shadowed,
  required Map<String, int> memberDeclIdxs,
  required String callerName,
  required List<_CrossCall> unguardedCrossCalls,
}) {
  if (step.kind is! SLamKind) return;
  final lam = step.kind as SLamKind;
  // Walk domain.
  if (lam.domain != null) {
    _walkForRecursion(
      expr: lam.domain!,
      blockMembers: blockMembers,
      designated: designated,
      designatedIdx: designatedIdx,
      subTerms: subTerms,
      shadowed: shadowed,
      memberDeclIdxs: memberDeclIdxs,
      callerName: callerName,
      unguardedCrossCalls: unguardedCrossCalls,
    );
  }
  // Walk the body with the predecessor parameter (k) in subTerms.
  _walkForRecursion(
    expr: lam.body,
    blockMembers: blockMembers,
    designated: designated,
    designatedIdx: designatedIdx,
    subTerms: {...subTerms, lam.param},
    shadowed: {...shadowed, lam.param},
    memberDeclIdxs: memberDeclIdxs,
    callerName: callerName,
    unguardedCrossCalls: unguardedCrossCalls,
  );
}

/// Core walker for [_checkStructuralRecursion]. Descends into the
/// surface AST, tracking shadowed names and sub-term bindings. Every
/// reference to a block member is checked for structurality.
void _walkForRecursion({
  required SExpr expr,
  required Set<String> blockMembers,
  required String? designated,
  int? designatedIdx,
  required Set<String> subTerms,
  required Set<String> shadowed,
  Map<String, int> memberDeclIdxs = const <String, int>{},
  String callerName = '',
  List<_CrossCall> unguardedCrossCalls = const <_CrossCall>[],
}) {
  switch (expr.kind) {
    case SIdentKind(:final name):
      if (blockMembers.contains(name) && !shadowed.contains(name)) {
        // Unapplied block-member reference, e.g. `f` used as a
        // value. Reject: we can't verify the eventual call site.
        throw NonStructuralRecursion(name, expr.span);
      }
    case STypeKind():
    case SPropKind():
    case SSPropKind():
      return;
    case SDotKind(:final qualifier):
      // Walk the qualifier for shadowing purposes, but DON'T flag a
      // bare dotted reference like `Foo.bar` against block names
      // (block names are plain, not dotted, we'd match `Foo.bar`
      // as a whole only if the mutual block literally declared a
      // name `Foo.bar`, which it can't without a dotted lhs on a
      // `fun`, which is unsupported).
      _walkForRecursion(
        expr: qualifier,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    case SAppKind():
      // Application chain. Flatten left-to-right so we can inspect
      // the head and the positional arg list. If the head is a
      // block member, check the designated-arg-position argument.
      final (head, args) = _flattenApp(expr);
      final headKind = head.kind;
      if (headKind is SIdentKind &&
          blockMembers.contains(headKind.name) &&
          !shadowed.contains(headKind.name)) {
        // The designated-arg position is determined by [`designatedIdx`]
        // when available (from `{struct name}` annotation), or defaults
        // to index 0 (first explicit value param). Calls with explicit
        // type args (e.g. `f[TypeArg] x`) flatten to `args = [TypeArg,
        // x]`; that case is not distinguished here (it would need per-
        // callee type-param counts). Implicit arguments sidestep it.
        if (args.isEmpty) {
          throw NonStructuralRecursion(headKind.name, head.span);
        }
        // Try the CALLEE's designated arg index (from memberDeclIdxs)
        // first.  If the argument at that position is a valid sub-term,
        // use it.  Otherwise fall back to the caller's designatedIdx.
        // This allows both directions of a mutual block to pass: e.g.
        // nat_wf → nat_wf_help k y h uses the caller's index (k is a
        // sub-term of n), while nat_wf_help → nat_wf y_ uses the
        // callee's index (y_ is a sub-term of h).
        int daIdx;
        final calleeIdx = memberDeclIdxs[headKind.name];
        if (calleeIdx != null && calleeIdx < args.length) {
          final calleeArg = args[calleeIdx];
          final calleeIdent = calleeArg.kind;
          final calleeName =
              calleeIdent is SIdentKind ? calleeIdent.name : null;
          if (calleeName != null && subTerms.contains(calleeName)) {
            daIdx = calleeIdx;
          } else {
            daIdx = designatedIdx ?? 0;
          }
        } else {
          daIdx = designatedIdx ?? 0;
        }
        if (daIdx >= args.length) {
          throw NonStructuralRecursion(headKind.name, expr.span);
        }
        final designatedArg = args[daIdx];
        final argIdent = designatedArg.kind;
        final argName = argIdent is SIdentKind ? argIdent.name : null;
        if (argName == null || !subTerms.contains(argName)) {
          if (headKind.name == callerName) {
            // Self-call unguarded: always a cycle, reject immediately.
            throw NonStructuralRecursion(headKind.name, expr.span);
          }
          // Cross-call unguarded: collect for cycle analysis,
          // but only when we have a real caller (not from a
          // recursive descent within the same function body).
          if (callerName.isNotEmpty) {
            unguardedCrossCalls.add(
              _CrossCall(callerName, headKind.name, expr.span),
            );
          } else {
            throw NonStructuralRecursion(headKind.name, expr.span);
          }
        }
        // Walk the other args normally (they may contain more block
        // references).
        for (var i = 1; i < args.length; i++) {
          _walkForRecursion(
            expr: args[i],
            blockMembers: blockMembers,
            designated: designated,
            designatedIdx: designatedIdx,
            subTerms: subTerms,
            shadowed: shadowed,
            memberDeclIdxs: memberDeclIdxs,
            callerName: callerName,
            unguardedCrossCalls: unguardedCrossCalls,
          );
        }
      } else {
        // Non-block-member head: walk fn + arg normally.
        // Special case: induction principles like `Nat.ind(motive, base,
        // step, scrutinee)`.  If the scrutinee (4th arg) is a sub-term,
        // then the predecessor parameter of the step lambda is also a
        // sub-term.
        final (flatHead, flatArgs) = _flattenApp(expr);
        final headName = _flattenDottedIdent(flatHead);
        final isInd = headName != null && _isInductiveRecursor(headName);
        if (isInd && flatArgs.length >= 4) {
          // Argument layout: [motive, base, step, scrutinee].
          final scrutinee = flatArgs[3];
          final scrName =
              scrutinee.kind is SIdentKind
                  ? (scrutinee.kind as SIdentKind).name
                  : null;
          final scrIsSubTerm =
              (scrName != null && subTerms.contains(scrName)) ||
              (scrName != null && scrName == designated);
          // Walk mot, base, step, scrutinee normally.
          for (var i = 0; i < flatArgs.length; i++) {
            if (i == 2 && scrIsSubTerm) {
              // Step lambda: (k: Nat) => (ih: ...) => body.
              // k is a sub-term of scrutinee via induction.
              final step = flatArgs[2];
              _walkStepForInd(
                step,
                blockMembers: blockMembers,
                designated: designated,
                designatedIdx: designatedIdx,
                subTerms: subTerms,
                shadowed: shadowed,
                memberDeclIdxs: memberDeclIdxs,
                callerName: callerName,
                unguardedCrossCalls: unguardedCrossCalls,
              );
            } else {
              _walkForRecursion(
                expr: flatArgs[i],
                blockMembers: blockMembers,
                designated: designated,
                designatedIdx: designatedIdx,
                subTerms: subTerms,
                shadowed: shadowed,
                memberDeclIdxs: memberDeclIdxs,
                callerName: callerName,
                unguardedCrossCalls: unguardedCrossCalls,
              );
            }
          }
        } else {
          // Default: walk fn + arg from the original SAppKind.
          final app = expr.kind as SAppKind;
          _walkForRecursion(
            expr: app.fn,
            blockMembers: blockMembers,
            designated: designated,
            designatedIdx: designatedIdx,
            subTerms: subTerms,
            shadowed: shadowed,
            memberDeclIdxs: memberDeclIdxs,
            callerName: callerName,
            unguardedCrossCalls: unguardedCrossCalls,
          );
          _walkForRecursion(
            expr: app.arg,
            blockMembers: blockMembers,
            designated: designated,
            designatedIdx: designatedIdx,
            subTerms: subTerms,
            shadowed: shadowed,
            memberDeclIdxs: memberDeclIdxs,
            callerName: callerName,
            unguardedCrossCalls: unguardedCrossCalls,
          );
        }
      }
    case SLamKind(:final param, :final domain, :final body):
      if (domain != null) {
        _walkForRecursion(
          expr: domain,
          blockMembers: blockMembers,
          designated: designated,
          designatedIdx: designatedIdx,
          subTerms: subTerms,
          shadowed: shadowed,
          memberDeclIdxs: memberDeclIdxs,
          callerName: callerName,
          unguardedCrossCalls: unguardedCrossCalls,
        );
      }
      _walkForRecursion(
        expr: body,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: {...shadowed, param},
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    case SPiKind(:final param, :final domain, :final codomain):
      _walkForRecursion(
        expr: domain,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
      _walkForRecursion(
        expr: codomain,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: param == null ? shadowed : {...shadowed, param},
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    case SLetKind(:final param, :final domain, :final bound, :final body):
      if (domain != null) {
        _walkForRecursion(
          expr: domain,
          blockMembers: blockMembers,
          designated: designated,
          designatedIdx: designatedIdx,
          subTerms: subTerms,
          shadowed: shadowed,
          memberDeclIdxs: memberDeclIdxs,
          callerName: callerName,
          unguardedCrossCalls: unguardedCrossCalls,
        );
      }
      _walkForRecursion(
        expr: bound,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
      _walkForRecursion(
        expr: body,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: {...shadowed, param},
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    case SMatchKind(:final scrutinee, :final motive, :final cases):
      _walkForRecursion(
        expr: scrutinee,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
      if (motive != null) {
        _walkForRecursion(
          expr: motive,
          blockMembers: blockMembers,
          designated: designated,
          designatedIdx: designatedIdx,
          subTerms: subTerms,
          shadowed: shadowed,
          memberDeclIdxs: memberDeclIdxs,
          callerName: callerName,
          unguardedCrossCalls: unguardedCrossCalls,
        );
      }
      // Determine whether the scrutinee names a known sub-term, if
      // so, pattern binders in each arm are themselves sub-terms.
      final scrutKind = scrutinee.kind;
      final scrutName = scrutKind is SIdentKind ? scrutKind.name : null;
      final scrutIsSubTerm =
          scrutName != null &&
          (scrutName == designated || subTerms.contains(scrutName));
      for (final arm in cases) {
        switch (arm) {
          case SMatchCase(:final binders, :final body):
            final extendedShadow = <String>{...shadowed};
            final extendedSubTerms = <String>{...subTerms};
            for (final b in binders) {
              if (b == '_') continue;
              extendedShadow.add(b);
              if (scrutIsSubTerm) extendedSubTerms.add(b);
            }
            _walkForRecursion(
              expr: body,
              blockMembers: blockMembers,
              designated: designated,
              designatedIdx: designatedIdx,
              subTerms: extendedSubTerms,
              shadowed: extendedShadow,
              memberDeclIdxs: memberDeclIdxs,
              callerName: callerName,
              unguardedCrossCalls: unguardedCrossCalls,
            );
          case SWildcardCase(:final body):
            _walkForRecursion(
              expr: body,
              blockMembers: blockMembers,
              designated: designated,
              designatedIdx: designatedIdx,
              subTerms: subTerms,
              shadowed: shadowed,
              memberDeclIdxs: memberDeclIdxs,
              callerName: callerName,
              unguardedCrossCalls: unguardedCrossCalls,
            );
        }
      }
    case SQuotKind(:final carrier, :final relation):
      _walkForRecursion(
        expr: carrier,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
      _walkForRecursion(
        expr: relation,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    case SQuotMkKind(:final arg):
      _walkForRecursion(
        expr: arg,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    case SQuotLiftKind(:final fn, :final proof):
      _walkForRecursion(
        expr: fn,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
      _walkForRecursion(
        expr: proof,
        blockMembers: blockMembers,
        designated: designated,
        designatedIdx: designatedIdx,
        subTerms: subTerms,
        shadowed: shadowed,
        memberDeclIdxs: memberDeclIdxs,
        callerName: callerName,
        unguardedCrossCalls: unguardedCrossCalls,
      );
    case SIntersectionKind():
    case SByKind():
      return;
  }
}

/// True iff [expr] contains any unshadowed reference to a name in
/// [blockMembers]. Used by [_elabDecl] to decide whether a single
/// `fun` is self-recursive and therefore needs co-recursive pre-
/// registration at check-time. Non-recursive funs don't need any
/// pre-scoping (doing so over-extends Ctx and breaks the body's
/// TBound indices), so emitting a [CorecursiveGroup] for them is
/// wrong.
///
/// This scan is pure-existential: returns `true` on the first hit
/// without structural checking. Structural validity is the
/// [_checkStructuralRecursion] walker's job; this helper just
/// decides "is there recursion at all?"
bool _hasRecursiveReference(SExpr expr, Set<String> blockMembers) =>
    _hasRecursiveReferenceAt(expr, blockMembers, const <String>{});

bool _hasRecursiveReferenceAt(
  SExpr expr,
  Set<String> blockMembers,
  Set<String> shadowed,
) {
  switch (expr.kind) {
    case SIdentKind(:final name):
      return blockMembers.contains(name) && !shadowed.contains(name);
    case STypeKind():
    case SPropKind():
    case SSPropKind():
      return false;
    case SDotKind(:final qualifier):
      return _hasRecursiveReferenceAt(qualifier, blockMembers, shadowed);
    case SAppKind(:final fn, :final arg):
      return _hasRecursiveReferenceAt(fn, blockMembers, shadowed) ||
          _hasRecursiveReferenceAt(arg, blockMembers, shadowed);
    case SLamKind(:final param, :final domain, :final body):
      return (domain != null &&
              _hasRecursiveReferenceAt(domain, blockMembers, shadowed)) ||
          _hasRecursiveReferenceAt(body, blockMembers, {...shadowed, param});
    case SPiKind(:final param, :final domain, :final codomain):
      return _hasRecursiveReferenceAt(domain, blockMembers, shadowed) ||
          _hasRecursiveReferenceAt(
            codomain,
            blockMembers,
            param == null ? shadowed : {...shadowed, param},
          );
    case SLetKind(:final param, :final domain, :final bound, :final body):
      if (domain != null &&
          _hasRecursiveReferenceAt(domain, blockMembers, shadowed)) {
        return true;
      }
      return _hasRecursiveReferenceAt(bound, blockMembers, shadowed) ||
          _hasRecursiveReferenceAt(body, blockMembers, {...shadowed, param});
    case SMatchKind(:final scrutinee, :final motive, :final cases):
      if (_hasRecursiveReferenceAt(scrutinee, blockMembers, shadowed)) {
        return true;
      }
      if (motive != null &&
          _hasRecursiveReferenceAt(motive, blockMembers, shadowed)) {
        return true;
      }
      for (final arm in cases) {
        switch (arm) {
          case SMatchCase(:final binders, :final body):
            final extended = <String>{...shadowed};
            for (final b in binders) {
              if (b != '_') extended.add(b);
            }
            if (_hasRecursiveReferenceAt(body, blockMembers, extended)) {
              return true;
            }
          case SWildcardCase(:final body):
            if (_hasRecursiveReferenceAt(body, blockMembers, shadowed)) {
              return true;
            }
        }
      }
      return false;
    case SQuotKind(:final carrier, :final relation):
      return _hasRecursiveReferenceAt(carrier, blockMembers, shadowed) ||
          _hasRecursiveReferenceAt(relation, blockMembers, shadowed);
    case SQuotMkKind(:final arg):
      return _hasRecursiveReferenceAt(arg, blockMembers, shadowed);
    case SQuotLiftKind(:final fn, :final proof):
      return _hasRecursiveReferenceAt(fn, blockMembers, shadowed) ||
          _hasRecursiveReferenceAt(proof, blockMembers, shadowed);
    case SIntersectionKind():
    case SByKind():
      return false;
  }
}

/// Flatten a left-associated `SApp` chain into `(head, [arg1, arg2, …])`.
///
/// The parser produces `f x y z` as
/// `SApp(SApp(SApp(f, x), y), z)`: head innermost, args growing to
/// the right. This helper walks `fn` repeatedly collecting args,
/// then reverses so the returned list is in left-to-right source
/// order.
(SExpr, List<SExpr>) _flattenApp(SExpr expr) {
  final args = <SExpr>[];
  var cur = expr;
  while (cur.kind is SAppKind) {
    final app = cur.kind as SAppKind;
    args.add(app.arg);
    cur = app.fn;
  }
  return (cur, args.reversed.toList());
}

// ---------------------------------------------------------------------------
// `data` elaboration
// ---------------------------------------------------------------------------

/// Elaborate a `data` declaration into a [DataDecl].
///
/// Three passes internally:
///   1. Build the parameter telescope under a local scope.
///   2. Elaborate the signature under params scope; decompose its Pi
///      chain into indices (domains) and the target sort (final
///      codomain). Reject non-sort codomains.
///   3. Install a scratch [TopEnv] that has the data name registered
///      (so constructor signatures can reference it), then elaborate
///      each constructor type. Decompose each ctor type's Pi chain
///      into its arg telescope and result, and verify the result is
///      `TData(name, args)` with matching arity. Reject other shapes.
///
/// Intra-block ctor-name uniqueness is checked against a scratch set
/// here as well, because constructors don't go into [TopEnv.bindings],
/// so the spanOf check in [_checkDuplicate] wouldn't catch
/// ctor-vs-ctor duplicates.
/// A skeletal data declaration produced by the first-pass header
/// elaboration. Carries enough structure to be registered in a
/// scratch registry so sibling (mutual) ctors can reference it.
class _DataHeader {
  final SDataKind kind;
  final DoxaSpan span;
  final List<TelescopeEntry> params;
  final List<TelescopeEntry> indices;
  final Term sort;
  final _LocalScope paramScope;
  const _DataHeader({
    required this.kind,
    required this.span,
    required this.params,
    required this.indices,
    required this.sort,
    required this.paramScope,
  });

  /// The "partial" DataDecl used to stage this header into a scratch
  /// TopEnv while mutual ctors are being elaborated.
  ///
  /// [paramsCovariant] defaults to "every param not-covariant",
  /// safe because no ctor types have been elaborated yet, so no
  /// nested-positivity queries can succeed through this partial.
  /// The final DataDecl overrides this with the true computed
  /// covariance.
  DataDecl partial() => DataDecl(
    name: kind.name,
    params: List.unmodifiable(params),
    indices: List.unmodifiable(indices),
    sort: sort,
    ctors: const <CtorDecl>[],
    paramsCovariant: List<bool>.filled(params.length, false),
    source: kind,
    span: span,
  );
}

/// Elaborate a `data` declaration's header, its params, signature
/// decomposition (indices + sort), without touching its ctors.
///
/// Returns a [_DataHeader] that can be registered as a partial
/// [DataDecl] in a scratch TopEnv. Used by both the single-data
/// elaborator ([_elabData]) and the mutual-block elaborator
/// ([_elabDataBlock]).
_DataHeader _elabDataHeader(TopEnv topEnv, DoxaSpan span, SDataKind kind) {
  // Pass 1: parameter telescope.
  final params = <TelescopeEntry>[];
  var paramScope = const _LocalNil() as _LocalScope;
  for (final tp in kind.typeParams) {
    final paramName = tp.$1;
    final paramKind = tp.$2 ?? const SExpr(STypeKind(null), DoxaSpan.synthetic);
    final kindTerm = _elabExpr(topEnv, paramScope, paramKind);
    params.add(TelescopeEntry(paramName, kindTerm, paramKind.span));
    paramScope = paramScope.push(paramName);
  }

  // Pass 2: signature under params scope; peel the Pi chain into
  // indices + target sort.
  final signatureTerm = _elabExpr(topEnv, paramScope, kind.signature);
  final indices = <TelescopeEntry>[];
  Term cursor = signatureTerm;
  var indexScope = paramScope;
  while (cursor is TPi) {
    final pi = cursor;
    final hint = pi.name;
    indices.add(TelescopeEntry(hint, pi.domain, kind.signature.span));
    indexScope = indexScope.push(hint ?? ' _idx${indices.length}');
    cursor = pi.codomain;
  }
  final sort = cursor;
  if (sort is! TType && sort is! TProp && sort is! TSProp) {
    throw DataSortNotASort(kind.name, kind.signature.span);
  }

  return _DataHeader(
    kind: kind,
    span: span,
    params: params,
    indices: indices,
    sort: sort,
    paramScope: paramScope,
  );
}

/// True iff [t] is an SProp-sorted type term, i.e., its sort is
/// [TSProp]. Used by SProp-inductive field validation.
bool _termIsSPropSorted(Term t, List<DataDecl> dataDecls) {
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

/// Elaborate the ctors of a single data declaration.
///
/// [scratchEnv] must already include all mutually-declared data
/// decls as partial [DataDecl]s (so sibling names resolve during
/// ctor-type elaboration). [mutualNames] is the full set of
/// mutually-declared names, used for strict-positivity checking
/// across the block.
List<CtorDecl> _elabDataCtors(
  _DataHeader header,
  TopEnv scratchEnv,
  Set<String> mutualNames,
) {
  final ctors = <CtorDecl>[];
  final kind = header.kind;
  final params = header.params;
  final indices = header.indices;
  // Build an `_ElabState` with params pushed under their real Value-
  // level types (evaluated from the elaborated kindTerms). This
  // matches the lazy-motive discipline in `_buildFunBody` /
  // `_buildFunType`: SApp's check-mode arg elab requires correct
  // binder types, so we can't use the `_shimState` placeholder
  // (VType(0)) for params.
  var ctorState = _shimState(scratchEnv, const _LocalNil());
  var teleEnv = ctorState.ctx.env;
  for (final p in params) {
    final paramTypeV = eval(p.type, teleEnv);
    ctorState = ctorState.push(p.name ?? '_', paramTypeV);
    teleEnv = ctorState.ctx.env;
  }
  for (final sctor in kind.ctors) {
    final (ctorType, _) = _inferExpr(ctorState, sctor.type);
    // Walk the Pi chain: each domain is an arg-telescope entry; the
    // final codomain must be the saturated data type.
    final args = <TelescopeEntry>[];
    Term cc = ctorType;
    var argScope = header.paramScope;
    while (cc is TPi) {
      final pi = cc;
      final hint = pi.name;
      args.add(TelescopeEntry(hint, pi.domain, sctor.type.span));
      argScope = argScope.push(hint ?? ' _arg${args.length}');
      cc = pi.codomain;
    }
    // Final codomain: must be TData(kind.name, args) with exactly
    // params.length + indices.length arguments.
    if (cc is! TData) {
      throw CtorResultShapeMismatch(
        kind.name,
        sctor.name,
        sctor.span,
        'constructor result must be the inductive type \'${kind.name}\' '
        'applied to its parameters and indices; got '
        '${cc.runtimeType}',
      );
    }
    final ccData = cc;
    if (ccData.name != kind.name) {
      throw CtorResultShapeMismatch(
        kind.name,
        sctor.name,
        sctor.span,
        'constructor result is \'${ccData.name}\' but this declaration '
        'is for \'${kind.name}\'',
      );
    }
    final expectedArity = params.length + indices.length;
    if (ccData.args.length != expectedArity) {
      throw CtorResultShapeMismatch(
        kind.name,
        sctor.name,
        sctor.span,
        'constructor result applied to ${ccData.args.length} argument'
        '${ccData.args.length == 1 ? '' : 's'}, expected $expectedArity '
        '(${params.length} parameter${params.length == 1 ? '' : 's'} + '
        '${indices.length} ind'
        '${indices.length == 1 ? 'ex' : 'ices'})',
      );
    }
    // SProp field validation: all constructor fields must be SProp-sorted.
    if (header.sort is TSProp) {
      for (final arg in args) {
        if (!_termIsSPropSorted(arg.type, scratchEnv.dataDecls)) {
          throw SPropFieldNotProofIrrelevant(arg.name ?? '_', arg.span);
        }
      }
    }

    // Strict positivity: each ctor arg type must have every name in
    // [mutualNames] only in strictly-positive positions (or not at all).
    // For a single-data decl, mutualNames = {kind.name}. For a mutual
    // block, mutualNames is the full set so negative occurrences of
    // ANY block member are rejected.
    for (var i = 0; i < args.length; i++) {
      if (!_strictlyPositiveInAny(
        mutualNames,
        args[i].type,
        registry: scratchEnv.dataDecls,
      )) {
        throw PositivityViolation(kind.name, sctor.name, i, args[i].span);
      }
    }

    // The result's index args start after the params.
    final resultIndices = ccData.args.sublist(params.length);

    ctors.add(
      CtorDecl(
        dataName: kind.name,
        name: sctor.name,
        args: List.unmodifiable(args),
        resultIndices: List.unmodifiable(resultIndices),
        source: sctor,
        span: sctor.span,
      ),
    );
  }

  return ctors;
}

/// Build the `T.rec` TopBinding for a fully-elaborated [DataDecl].
///
/// Shared between the single-data and mutual-block paths. The binding
/// Build the `T.rec` TopBinding(s) for a fully-elaborated [DataDecl].
///
/// Recursor binding structure (the multi-recursor bridge, full
/// universe polymorphism would collapse these into a single
/// sort-polymorphic recursor):
///
///   * `T.rec`, emitted for every inductive. Motive target sort = data's declared
///     sort. For Prop data this is the J-rule-shape recursor; for
///     Type data this is the induction-over-values recursor.
///   * `T.ind`, emitted for Type-sorted data. Motive target sort =
///     `Prop`. The "Prop-motive" variant: sound for every inductive (Type → Prop
///     elimination has no singleton restriction), used for proving
///     Prop-sorted properties by induction on values. Needed for
///     `plus_zero`/`plus_succ`/`plus_comm` style proofs.
///   * `T.rect`, emitted for Prop-sorted data that admits SPEC §8.2
///     singleton elimination. Motive target sort = `Type 0`. The
///     "large-elim" variant, used for Eq.rec-style transport. Only
///     emitted when [admitsSingletonElim] holds.
///
/// Matches Coq's `_rec` / `_ind` / `_rect` naming conventions.
List<TopBinding> _makeRecBindings(
  TopEnv env,
  DataDecl dataDecl,
  DoxaSpan span,
) {
  // SProp-sorted data: only the default .rec (no .ind/.rect).
  // The motive sort stays as SProp; elimination into Type is forbidden.
  if (dataDecl.sort is TSProp) {
    return [
      TopBinding(
        name: '${dataDecl.name}.rec',
        type: synthRecursorType(dataDecl, motiveSort: const TSProp()),
        term: TRec(dataDecl.name, motiveSort: const TSProp()),
        span: span,
      ),
    ];
  }

  final bindings = <TopBinding>[
    TopBinding(
      name: '${dataDecl.name}.rec',
      type: synthRecursorType(dataDecl),
      term: TRec(dataDecl.name),
      span: span,
    ),
  ];
  // Auto-emit T.ind (Prop motive) for Type-sorted data. Always valid,
  // Type → Prop has no restriction, and required for proof-
  // producing induction (e.g. plus_zero/plus_comm-style proofs).
  if (dataDecl.sort is! TProp) {
    bindings.add(
      TopBinding(
        name: '${dataDecl.name}.ind',
        type: synthRecursorType(dataDecl, motiveSort: const TProp()),
        term: TRec(dataDecl.name, motiveSort: const TProp()),
        span: span,
      ),
    );
  }
  // Auto-emit T.rect for Prop-sorted singleton-admitting inductives.
  // admitsSingletonElim runs on the elab-time Ctx, at this point the
  // data decl has already been registered (by _elabData, which calls
  // this helper after the DataDecl is built and added in the
  // decl-result path). We use `env.toCtx()` extended by the decl.
  if (dataDecl.sort is TProp) {
    final ctx = TopEnv(env.bindings, [...env.dataDecls, dataDecl]).toCtx();
    if (admitsSingletonElim(dataDecl, ctx)) {
      bindings.add(
        TopBinding(
          name: '${dataDecl.name}.rect',
          type: synthRecursorType(dataDecl, motiveSort: const TType(_l0)),
          term: TRec(dataDecl.name, motiveSort: const TType(_l0)),
          span: span,
        ),
      );
    }
  }
  return bindings;
}

/// Elaborate a single `data` declaration into a full [DataDecl].
///
/// Orchestrates [_elabDataHeader] and [_elabDataCtors] with a
/// self-only mutual-names set. See [_elabDataBlock] for the mutual
/// case.
DataDecl _elabData(TopEnv topEnv, DoxaSpan span, SDataKind kind) {
  // Check ctor names don't collide with each other or with existing
  // top-level names.
  final ctorSeen = <String, DoxaSpan>{};
  for (final c in kind.ctors) {
    final prev = ctorSeen[c.name];
    if (prev != null) {
      throw DuplicateDeclaration(c.name, prev, c.span);
    }
    final existing = topEnv.spanOf(c.name);
    if (existing != null) {
      throw DuplicateDeclaration(c.name, existing, c.span);
    }
    ctorSeen[c.name] = c.span;
  }

  final header = _elabDataHeader(topEnv, span, kind);
  // Scratch env with this data registered as a partial so its ctors'
  // signatures can reference the data name.
  final scratchEnv = TopEnv(topEnv.bindings, [
    ...topEnv.dataDecls,
    header.partial(),
  ]);
  final ctors = _elabDataCtors(header, scratchEnv, {kind.name});
  final paramsCovariant = _computeParamsCovariant(header.params, ctors);
  return DataDecl(
    name: kind.name,
    params: List.unmodifiable(header.params),
    indices: List.unmodifiable(header.indices),
    sort: header.sort,
    ctors: List.unmodifiable(ctors),
    paramsCovariant: List.unmodifiable(paramsCovariant),
    source: kind,
    span: span,
  );
}

/// Elaborate a mutual `data ... and data ...` block.
///
/// Two-pass discipline:
///   1. Elaborate each member's header (params, indices, sort)
///      against the outer [topEnv], producing a [_DataHeader]. Also
///      validates each name's uniqueness against the outer env and
///      against sibling names in the same block.
///   2. Register ALL headers as partials in a single scratch env,
///      then elaborate each member's ctors against that scratch env
///      with `mutualNames = {all block member names}` so cross-
///      references resolve and positivity spans the whole block.
///
/// Returns the fully-formed [DataDecl]s in the block's declaration
/// order.
///
/// Span caveat (shared with `SFunBlockKind`): each member's produced
/// [DataDecl] carries the *block's* span, not the individual member's,
/// because the parser's `_dataBody` production does not capture
/// per-member positions. Per-member spans would need either a span
/// field on [SDataKind] (which breaks the "kind has no span"
/// invariant) or `(SDataKind, DoxaSpan)` pairs threaded through the
/// block.
List<DataDecl> _elabDataBlock(
  TopEnv topEnv,
  DoxaSpan blockSpan,
  List<SDataBlockMember> members,
) {
  // Uniqueness: data names must be distinct within the block and not
  // collide with anything in the outer topEnv. Ctor names across all
  // block members must be distinct too. Each collision diagnostic
  // cites the per-member span (not the block span) so users see the
  // actual offending declaration (SPEC §6).
  final blockDataNames = <String, DoxaSpan>{};
  final blockCtorNames = <String, DoxaSpan>{};
  for (final m in members) {
    final d = m.data;
    final prevData = blockDataNames[d.name];
    if (prevData != null) {
      throw DuplicateDeclaration(d.name, prevData, m.span);
    }
    final existingData = topEnv.spanOf(d.name);
    if (existingData != null) {
      throw DuplicateDeclaration(d.name, existingData, m.span);
    }
    blockDataNames[d.name] = m.span;
    for (final c in d.ctors) {
      final prevCtor = blockCtorNames[c.name];
      if (prevCtor != null) {
        throw DuplicateDeclaration(c.name, prevCtor, c.span);
      }
      final existingCtor = topEnv.spanOf(c.name);
      if (existingCtor != null) {
        throw DuplicateDeclaration(c.name, existingCtor, c.span);
      }
      // Ctor names also can't collide with any data name in the
      // block (unusual but check for completeness).
      final dataCollide = blockDataNames[c.name];
      if (dataCollide != null) {
        throw DuplicateDeclaration(c.name, dataCollide, c.span);
      }
      blockCtorNames[c.name] = c.span;
    }
  }

  // Pass 1: headers, elaborated in topological order so a header
  // that references a sibling (e.g. `data A : B -> Type and data B
  // : Type`) elaborates AFTER the sibling's partial is registered.
  //
  // Headers may mention siblings. Dependency detection walks each
  // member's param-kinds and signature for SIdentKind / SDotKind
  // references that match a sibling name; topological sort then drives
  // the pass-1 order. Strict cycles (e.g. `data A : B -> Type and data
  // B : A -> Type`) are rejected with a dedicated error: ordering the
  // headers cannot resolve a genuine cycle.
  final blockMemberNames = {for (final m in members) m.data.name};
  final headerDeps = <String, Set<String>>{
    for (final m in members)
      m.data.name: _collectHeaderDependencies(m.data, blockMemberNames),
  };
  final orderedIndices = _topoSortHeaders(members, headerDeps);

  final partials = <DataDecl>[];
  final elaboratedHeaders = List<_DataHeader?>.filled(members.length, null);
  for (final idx in orderedIndices) {
    final m = members[idx];
    // Each header sees `topEnv` extended with the partials of
    // already-elaborated siblings.
    final headerEnv =
        partials.isEmpty
            ? topEnv
            : TopEnv(topEnv.bindings, [...topEnv.dataDecls, ...partials]);
    final h = _elabDataHeader(headerEnv, m.span, m.data);
    elaboratedHeaders[idx] = h;
    partials.add(h.partial());
  }
  final headers = [for (final h in elaboratedHeaders) h!];

  // Pass 2: scratch env with all partials (built by pass 1 in
  // topo order) registered, then elaborate each member's ctors
  // with mutualNames = all block member names.
  final scratchEnv = TopEnv(topEnv.bindings, [
    ...topEnv.dataDecls,
    ...partials,
  ]);
  final mutualNames = blockMemberNames;

  final results = <DataDecl>[];
  for (final header in headers) {
    final ctors = _elabDataCtors(header, scratchEnv, mutualNames);
    final paramsCovariant = _computeParamsCovariant(header.params, ctors);
    results.add(
      DataDecl(
        name: header.kind.name,
        params: List.unmodifiable(header.params),
        indices: List.unmodifiable(header.indices),
        sort: header.sort,
        ctors: List.unmodifiable(ctors),
        paramsCovariant: List.unmodifiable(paramsCovariant),
        source: header.kind,
        span: header.span,
      ),
    );
  }
  return results;
}

/// Walk a data member's header (param kinds + signature) collecting
/// sibling-member names referenced.
/// Used to build the dependency graph for topological ordering of
/// pass-1 header elaboration.
///
/// Shadowing is tracked the same way `_hasRecursiveReference` does:
/// a lambda/Pi/let binder shadows a matching identifier within its
/// body. (In practice, data headers don't use these shapes much,
/// but handling them correctly is cheap and matches the existing
/// walker.)
Set<String> _collectHeaderDependencies(
  SDataKind kind,
  Set<String> blockMembers,
) {
  final deps = <String>{};
  // Walk each param's kind expression.
  for (final tp in kind.typeParams) {
    final paramKind = tp.$2;
    if (paramKind != null) {
      _collectRefs(paramKind, blockMembers, const <String>{}, deps);
    }
  }
  // Walk the signature (indices + target sort).
  _collectRefs(kind.signature, blockMembers, const <String>{}, deps);
  // Self-reference doesn't count as a dependency, a header may
  // legitimately recur on its own name in indices (though this is
  // unusual and elab's positivity check fires on actual usage).
  deps.remove(kind.name);
  return deps;
}

void _collectRefs(
  SExpr expr,
  Set<String> blockMembers,
  Set<String> shadowed,
  Set<String> acc,
) {
  switch (expr.kind) {
    case SIdentKind(:final name):
      if (blockMembers.contains(name) && !shadowed.contains(name)) {
        acc.add(name);
      }
    case STypeKind():
    case SPropKind():
    case SSPropKind():
      break;
    case SDotKind(:final qualifier):
      _collectRefs(qualifier, blockMembers, shadowed, acc);
    case SAppKind(:final fn, :final arg):
      _collectRefs(fn, blockMembers, shadowed, acc);
      _collectRefs(arg, blockMembers, shadowed, acc);
    case SLamKind(:final param, :final domain, :final body):
      if (domain != null) {
        _collectRefs(domain, blockMembers, shadowed, acc);
      }
      _collectRefs(body, blockMembers, {...shadowed, param}, acc);
    case SPiKind(:final param, :final domain, :final codomain):
      _collectRefs(domain, blockMembers, shadowed, acc);
      _collectRefs(
        codomain,
        blockMembers,
        param == null ? shadowed : {...shadowed, param},
        acc,
      );
    case SLetKind(:final param, :final domain, :final bound, :final body):
      if (domain != null) {
        _collectRefs(domain, blockMembers, shadowed, acc);
      }
      _collectRefs(bound, blockMembers, shadowed, acc);
      _collectRefs(body, blockMembers, {...shadowed, param}, acc);
    case SMatchKind(:final scrutinee, :final motive, :final cases):
      _collectRefs(scrutinee, blockMembers, shadowed, acc);
      if (motive != null) {
        _collectRefs(motive, blockMembers, shadowed, acc);
      }
      for (final arm in cases) {
        switch (arm) {
          case SMatchCase(:final binders, :final body):
            final extended = <String>{...shadowed};
            for (final b in binders) {
              if (b != '_') extended.add(b);
            }
            _collectRefs(body, blockMembers, extended, acc);
          case SWildcardCase(:final body):
            _collectRefs(body, blockMembers, shadowed, acc);
        }
      }
    case SQuotKind(:final carrier, :final relation):
      _collectRefs(carrier, blockMembers, shadowed, acc);
      _collectRefs(relation, blockMembers, shadowed, acc);
    case SQuotMkKind(:final arg):
      _collectRefs(arg, blockMembers, shadowed, acc);
    case SQuotLiftKind(:final fn, :final proof):
      _collectRefs(fn, blockMembers, shadowed, acc);
      _collectRefs(proof, blockMembers, shadowed, acc);
    case SIntersectionKind():
    case SByKind():
      break;
  }
}

/// Topologically sort data-block members by their header
/// dependencies. Returns the member indices in an order where each
/// member's dependencies precede it. Raises [MutualHeaderCycle] if
/// the dependency graph contains a cycle.
///
/// Uses Kahn's algorithm, simple, O(V+E), produces a deterministic
/// order for independent members (preserves source order within
/// groups of equal-depth members).
List<int> _topoSortHeaders(
  List<SDataBlockMember> members,
  Map<String, Set<String>> deps,
) {
  // indegree[i] = number of deps[members[i].name] still unresolved.
  final indegree = List<int>.filled(members.length, 0);
  final nameToIndex = <String, int>{
    for (var i = 0; i < members.length; i++) members[i].data.name: i,
  };
  // Forward edges: for each name N, `dependents[N]` = members whose
  // header depends on N.
  final dependents = <String, List<int>>{};
  for (var i = 0; i < members.length; i++) {
    final name = members[i].data.name;
    final ds = deps[name] ?? const <String>{};
    indegree[i] = ds.length;
    for (final d in ds) {
      dependents.putIfAbsent(d, () => <int>[]).add(i);
    }
  }
  // Kahn: queue all zero-indegree members in source order.
  final order = <int>[];
  final queue = <int>[
    for (var i = 0; i < members.length; i++)
      if (indegree[i] == 0) i,
  ];
  while (queue.isNotEmpty) {
    final i = queue.removeAt(0);
    order.add(i);
    final name = members[i].data.name;
    for (final dependent in dependents[name] ?? const <int>[]) {
      indegree[dependent] -= 1;
      if (indegree[dependent] == 0) queue.add(dependent);
    }
  }
  if (order.length != members.length) {
    // Cycle: every member not in `order` is part of some SCC.
    final cycleMembers = <String>[];
    for (var i = 0; i < members.length; i++) {
      if (!order.contains(i)) cycleMembers.add(members[i].data.name);
    }
    throw MutualHeaderCycle(
      cycleMembers,
      members[nameToIndex[cycleMembers.first]!].span,
    );
  }
  return order;
}

// ---------------------------------------------------------------------------
// Strict-positivity check
// ---------------------------------------------------------------------------

/// True if any name in [dataNames] appears somewhere in [term].
///
/// Used as the first-gate test: the positivity check only runs the
/// deeper analysis when forbidden names actually occur. Walks the
/// term literally without consulting the registry, a literal
/// occurrence anywhere (including inside another inductive's args)
/// counts. Nested covariance is resolved by
/// [_strictlyPositiveInAny], not by this predicate.
bool _occursInAny(Set<String> dataNames, Term term) => switch (term) {
  TType() ||
  TSProp() ||
  TProp() ||
  TFree() ||
  TBound() ||
  TTop() ||
  TMeta() => false,
  TData(:final name, :final args) =>
    dataNames.contains(name) || args.any((a) => _occursInAny(dataNames, a)),
  TConstr(:final args) => args.any((a) => _occursInAny(dataNames, a)),
  TRec(dataName: final recName) => dataNames.contains(recName),
  TApp(:final fn, :final arg) =>
    _occursInAny(dataNames, fn) || _occursInAny(dataNames, arg),
  TLam(:final domain, :final body) =>
    _occursInAny(dataNames, domain) || _occursInAny(dataNames, body),
  TLet(:final domain, :final bound, :final body) =>
    _occursInAny(dataNames, domain) ||
        _occursInAny(dataNames, bound) ||
        _occursInAny(dataNames, body),
  TPi(:final domain, :final codomain) =>
    _occursInAny(dataNames, domain) || _occursInAny(dataNames, codomain),
  TMatch(:final scrutinee, :final motive, :final cases) =>
    _occursInAny(dataNames, scrutinee) ||
        (motive != null && _occursInAny(dataNames, motive)) ||
        cases.any((c) => _occursInAny(dataNames, c.body)),
  TQuot(:final carrier, :final relation) =>
    _occursInAny(dataNames, carrier) || _occursInAny(dataNames, relation),
  TQuotMk(:final arg) => _occursInAny(dataNames, arg),
  TQuotLift(:final quot, :final fn, :final proof) =>
    _occursInAny(dataNames, quot) ||
        _occursInAny(dataNames, fn) ||
        _occursInAny(dataNames, proof),
  TProj(:final expr, fieldName: final _) => _occursInAny(dataNames, expr),
};

/// True if any name in [dataNames] appears only in strictly-positive
/// positions in [term], where [term] is the type of a constructor
/// argument.
///
/// Per SPEC §8.4: a forbidden name may appear as the head of a
/// saturated application (with the forbidden set not occurring in the
/// args), or not at all, or on the right of arrows (subterm
/// recursion). It must NOT appear on the left of an arrow (negative
/// position).
///
/// For mutual `data` blocks, [dataNames] is the full set of block
/// members, a ctor of A cannot have B (another block member) in a
/// strictly-negative position either, because the mutual fixed-point
/// would otherwise admit non-termination.
///
/// Nested positivity is handled by consulting each registered
/// inductive's [DataDecl.paramsCovariant]: a ctor arg of shape
/// `S[X]` is accepted if `S` is covariant in its param and `X` is
/// itself strictly-positive in the forbidden set. See
/// [PositivityViolation]'s doc comment for the full policy.
bool _strictlyPositiveInAny(
  Set<String> dataNames,
  Term term, {
  List<DataDecl> registry = const <DataDecl>[],
}) {
  // 1. Absent from the term → no occurrence, so positive.
  if (!_occursInAny(dataNames, term)) return true;

  // 2. Saturated-head occurrence of a forbidden name: T args where T
  //    is in dataNames and the args do not contain any of dataNames.
  if (term is TData &&
      dataNames.contains(term.name) &&
      !term.args.any((a) => _occursInAny(dataNames, a))) {
    return true;
  }

  // 3. Pi type: no dataName may occur in the domain; must be
  //    strictly-positive in the codomain.
  if (term is TPi) {
    if (_occursInAny(dataNames, term.domain)) return false;
    return _strictlyPositiveInAny(dataNames, term.codomain, registry: registry);
  }

  // 4. Nested covariant occurrence: `S args` where `S` is an OTHER
  //    (non-forbidden) inductive type, looked up in [registry], and
  //    for each arg, either dataNames don't occur in the arg or S is
  //    covariant in that arg's position AND the arg is strictly
  //    positive (recursively).
  //
  //    Canonical example: `List[Tree[A]]` where `Tree` is being
  //    defined. `List` is covariant in its first param; `Tree[A]`
  //    has `Tree` positively. So `List[Tree[A]]` is a valid ctor
  //    arg type.
  if (term is TData && !dataNames.contains(term.name)) {
    for (final d in registry) {
      if (d.name != term.name) continue;
      // Arity mismatch shouldn't happen after type-checking, be
      // defensive anyway.
      if (d.paramsCovariant.length > term.args.length) return false;
      for (var i = 0; i < term.args.length; i++) {
        final argTerm = term.args[i];
        if (!_occursInAny(dataNames, argTerm)) continue;
        // The forbidden set occurs in this arg. The arg is a param
        // slot iff i < paramsCovariant.length (indices are checked
        // against the full forbidden rule).
        final isParam = i < d.paramsCovariant.length;
        final covariantHere = isParam && d.paramsCovariant[i];
        if (!covariantHere) return false;
        if (!_strictlyPositiveInAny(dataNames, argTerm, registry: registry)) {
          return false;
        }
      }
      return true;
    }
    // S not found in registry, defensive fallthrough, reject.
    return false;
  }

  // Anything else: a dataName occurs but not in a recognised positive
  // position. Conservatively reject.
  return false;
}

/// True if [term], treated as a ctor arg type, has `TBound(boundVar)`
/// references to a specific parameter binder appearing only in
/// strictly-positive positions (never on the left of an arrow).
///
/// Used during [_elabData] finalization to compute each param's
/// covariance entry. [depth] tracks how many binders have been
/// descended past from the ctor-arg's original scope; the target
/// param-binder index shifts by +1 per binder crossed.
bool _isParamStrictlyPositive(Term term, int boundVar) =>
// TBound alone is positive — a bare bound variable reference.
// Negative positions are
// only created by appearing in a Pi domain, which is guarded
// below by explicitly refusing to enter if the param occurs
// in the domain.
switch (term) {
  TType() ||
  TSProp() ||
  TProp() ||
  TFree() ||
  TBound() ||
  TTop() ||
  TMeta() => true,
  TData(:final args) => args.every(
    (a) => _isParamStrictlyPositive(a, boundVar),
  ),
  TConstr(:final args) => args.every(
    (a) => _isParamStrictlyPositive(a, boundVar),
  ),
  TApp(:final fn, :final arg) =>
    _isParamStrictlyPositive(fn, boundVar) &&
        _isParamStrictlyPositive(arg, boundVar),
  // Pi: the param must NOT occur in the domain at all, and must
  // be strictly positive in the codomain (shifted by one binder).
  TPi(:final domain, :final codomain) =>
    !_boundOccursIn(domain, boundVar) &&
        _isParamStrictlyPositive(codomain, boundVar + 1),
  // Lambda / Let bodies go under a new binder too; the param
  // level shifts.
  TLam(:final domain, :final body) =>
    _isParamStrictlyPositive(domain, boundVar) &&
        _isParamStrictlyPositive(body, boundVar + 1),
  TLet(:final domain, :final bound, :final body) =>
    _isParamStrictlyPositive(domain, boundVar) &&
        _isParamStrictlyPositive(bound, boundVar) &&
        _isParamStrictlyPositive(body, boundVar + 1),
  TRec() => true,
  // Ctor signatures are types (not terms), so TMatch cannot occur
  // inside one under any well-typed shape. Kept exhaustive to keep
  // the compiler happy. Policy: conservatively treat as positive
  // (the boundVar doesn't occur); if a TMatch ever reaches this
  // walker it's a kernel invariant violation rather than a
  // positivity concern.
  TMatch() => true,
  TQuot(:final carrier, :final relation) =>
    _isParamStrictlyPositive(carrier, boundVar) &&
        _isParamStrictlyPositive(relation, boundVar),
  TQuotMk(:final arg) => _isParamStrictlyPositive(arg, boundVar),
  TQuotLift(:final quot, :final fn, :final proof) =>
    _isParamStrictlyPositive(quot, boundVar) &&
        _isParamStrictlyPositive(fn, boundVar) &&
        _isParamStrictlyPositive(proof, boundVar),
  TProj(:final expr, fieldName: final _) => _isParamStrictlyPositive(
    expr,
    boundVar,
  ),
};

/// Does TBound(target) occur anywhere in [term] (adjusting for binder
/// descent)?
bool _boundOccursIn(Term term, int target) => switch (term) {
  TType() || TSProp() || TProp() || TFree() || TTop() || TMeta() => false,
  TBound(:final index) => index == target,
  TData(:final args) => args.any((a) => _boundOccursIn(a, target)),
  TConstr(:final args) => args.any((a) => _boundOccursIn(a, target)),
  TApp(:final fn, :final arg) =>
    _boundOccursIn(fn, target) || _boundOccursIn(arg, target),
  TPi(:final domain, :final codomain) =>
    _boundOccursIn(domain, target) || _boundOccursIn(codomain, target + 1),
  TLam(:final domain, :final body) =>
    _boundOccursIn(domain, target) || _boundOccursIn(body, target + 1),
  TLet(:final domain, :final bound, :final body) =>
    _boundOccursIn(domain, target) ||
        _boundOccursIn(bound, target) ||
        _boundOccursIn(body, target + 1),
  TRec() => false,
  // See comment on _isParamStrictlyPositive's TMatch case.
  TMatch() => false,
  TQuot(:final carrier, :final relation) =>
    _boundOccursIn(carrier, target) || _boundOccursIn(relation, target),
  TQuotMk(:final arg) => _boundOccursIn(arg, target),
  TQuotLift(:final quot, :final fn, :final proof) =>
    _boundOccursIn(quot, target) ||
        _boundOccursIn(fn, target) ||
        _boundOccursIn(proof, target),
  TProj(:final expr, fieldName: final _) => _boundOccursIn(expr, target),
};

/// Compute the per-parameter covariance list for an elaborated data
/// declaration's ctors.
///
/// For each param `i` (counted outermost-first, i=0 is the first
/// declared param), check that in every ctor-arg type, TBound
/// references to that param appear only in strictly-positive
/// positions (never in a Pi domain).
///
/// At a ctor-arg type's top-level scope, the binders are:
///   [args[j-1], ..., args[0], params[p-1], ..., params[0]]
/// innermost-first. So param `i` is at depth `j + (paramCount - 1 - i)`
/// for the j-th ctor arg type.
List<bool> _computeParamsCovariant(
  List<TelescopeEntry> params,
  List<CtorDecl> ctors,
) {
  final p = params.length;
  if (p == 0) return const <bool>[];
  final result = List<bool>.filled(p, true);
  for (var i = 0; i < p; i++) {
    for (final c in ctors) {
      for (var j = 0; j < c.args.length; j++) {
        final depth = j + (p - 1 - i);
        if (!_isParamStrictlyPositive(c.args[j].type, depth)) {
          result[i] = false;
          break;
        }
      }
      if (!result[i]) break;
    }
  }
  return result;
}

/// True iff the data type named [dataName] is a record (single ctor,
/// no indices).
bool _isRecord(String dataName, List<DataDecl> dataDecls) {
  for (final d in dataDecls) {
    if (d.name == dataName) {
      return d.ctors.length == 1 && d.indices.isEmpty;
    }
  }
  return false;
}

/// True if [term] contains `TBound(ctorArgIdx)` in function-head position
/// of a `TApp`, accounting for TPi/TLam binder shifts. Used by the enriched
/// teleEnv to decide which ctor args need actual index values (closure
/// applications like `R y x` need the real `R`; data-constructor arguments
/// like `n` in `Lt n m` keep their neutral).
/// True if [term] contains `TBound(ctorArgIdx)` in function-head position
/// of a `TApp`, accounting for TPi/TLam binder shifts. Used by the enriched
/// teleEnv to decide which ctor args need actual index values (closure
/// applications like `R y x` need the real `R`; data-constructor arguments
/// Note: the enriched teleEnv uses a wildcard-only filter
/// (arm.binders[j] == '_'), which is sufficient for all current patterns.
/// An earlier `_termHasTAppAtCtorIdx` function that scanned subsequent arg
/// types for TApp function-head references was removed as dead code. If a
/// future constructor needs enrichment for a named binder that appears in
/// a closure application, revive that scan.

/// Substitute [scrutLevel] NVar references in [value] with [replacement].
/// Used by match-arm expected-type refinement for non-indexed data whose
/// return type depends on the scrutinee variable. Delegates to
/// [substNVar] in eval.dart.
// (The implementation lives in eval.dart as a public function so the
// checker can also use it for consistent per-arm expected types.)

/// Compute the type of [fieldName] in record type [dataV] (a VData with
/// args containing the params). Looks up the field in the constructor's
/// args telescope and evaluates its type under the param env.
Value _fieldType(VData dataV, String fieldName, List<DataDecl> dataDecls) {
  DataDecl? decl;
  for (final d in dataDecls) {
    if (d.name == dataV.name) {
      decl = d;
      break;
    }
  }
  if (decl == null) {
    throw StateError('_fieldType: unknown data type ${dataV.name}');
  }
  final ctor = decl.ctors.first;
  for (var i = 0; i < ctor.args.length; i++) {
    if (ctor.args[i].name == fieldName) {
      final fieldTypeTerm = ctor.args[i].type;
      // Build env: preceding args as placeholders, then params
      // + preceding fields. Fields after fieldIndex are NOT
      // pushed so de Bruijn indices resolve correctly.
      final paramCount = decl.params.length;
      Env env = const ENil();
      for (var j = 0; j < i; j++) {
        env = env.extend(VNeutral(NVar(1000 + j)));
      }
      for (var j = paramCount + i - 1; j >= 0; j--) {
        env = env.extend(dataV.args[j]);
      }
      return eval(fieldTypeTerm, env);
    }
  }
  throw StateError(
    '_fieldType: record ${dataV.name} has no field named $fieldName',
  );
}
