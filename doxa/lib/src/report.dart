/// Diagnostic formatting: turn errors into user-facing strings.
///
/// This is the final step of Doxa's error-reporting pipeline. Each of
/// the error families (`ParseError` from Rumil, `ElabError` from
/// elaboration, `DoxaCheckError` from type checking) is rendered into a
/// consistent format with source span, kind, and (for type mismatches)
/// the diff path plus pretty-printed expected/got types.
///
/// The output format matches SPEC §6.2:
///
/// ```
/// error: type mismatch
///   at input.doxa:4:17
///   expected: (A: Type) -> A -> A
///   actual:   (A: Type) -> A -> A -> A
///   first difference at codomain:
///     expected:  A -> A
///     actual:    A -> A -> A
/// ```
library;

import 'package:rumil/rumil.dart';

import 'check.dart';
import 'diff.dart';
import 'elab.dart';
import 'eval.dart';
import 'pretty.dart';
import 'source.dart';
import 'surface.dart';
import 'value.dart';

/// Format a Rumil [ParseError] against [source].
String reportParseError(SourceFile source, ParseError error) {
  final sb = StringBuffer();
  sb.writeln('error: parse error');
  sb.writeln(
    '  at ${source.filename}:${error.location.line}:${error.location.column}',
  );
  sb.writeln('  $error');
  return sb.toString();
}

/// Format a Rumil-returned [Failure] carrying one or more parse errors.
String reportParseFailure(
  SourceFile source,
  Failure<ParseError, Object?> failure,
) {
  // Rumil returns a list of errors. Merge them into one diagnostic,
  // using the furthest location as the primary span.
  final sb = StringBuffer();
  sb.writeln('error: parse error');
  sb.writeln(
    '  at ${source.filename}:${failure.furthest.line}:${failure.furthest.column}',
  );
  for (final e in failure.errors) {
    sb.writeln('  $e');
  }
  return sb.toString();
}

/// Format a [DoxaCheckError] against [source].
///
/// For [TypeMismatch] errors, reconstructs the diff path between the
/// inferred and expected types and renders both in surface syntax using
/// the name hints preserved by elaboration (see SPEC §3.2).
///
/// The [span] argument is the source span to blame. The checker itself
/// does not yet thread spans, so callers pass the span of the checked
/// declaration / expression.
String reportCheckError(
  SourceFile source,
  DoxaCheckError error,
  DoxaSpan span,
) {
  final sb = StringBuffer();
  switch (error) {
    case TypeMismatch(:final got, :final expected, level: final ctxLevel):
      sb.writeln('error: type mismatch');
      sb.writeln('  at ${source.formatStart(span)}');
      // Render expected/actual at the Ctx level the error was raised
      // at. This seeds the pretty-printer's outer-binder count so
      // free variables that point at the user's enclosing binders
      // (e.g. a fun's type parameters) render as placeholders
      // (`?a`, `?b`, …) rather than negative-index lies (`?-3`).
      // SPEC §6.2 tier 1; tier 2 (real user names like `A`) is future
      // work.
      sb.writeln('  expected: ${_prettyValueAt(expected, ctxLevel)}');
      sb.writeln('  actual:   ${_prettyValueAt(got, ctxLevel)}');
      final diff = diffValues(got, expected);
      if (!diff.isTopLevel) {
        sb.writeln('  first difference at ${diff.describePath()}:');
        // The diff walker uses a self-relative level (counting its
        // own binder descents from 0). For the rendered fragment
        // we offset by the Ctx level the error was raised at, so the
        // full outer scope seen by the renderer is ctxLevel + diff.level.
        final innerLevel = ctxLevel + diff.level;
        final innerNames = <String?>[
          ...List<String?>.filled(ctxLevel, null),
          ...diff.binderNames,
        ];
        sb.writeln(
          '    expected:  ${_prettyValueAt(diff.expected, innerLevel, innerNames)}',
        );
        sb.writeln(
          '    actual:    ${_prettyValueAt(diff.got, innerLevel, innerNames)}',
        );
      }
    case NotAFunction(:final actualType):
      sb.writeln('error: not a function');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  applied value has type: ${_prettyValueAt(actualType, 0)}');
    case NotAType(:final actualType):
      sb.writeln('error: not a type');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  expected a universe (Type n), got: ${_prettyValueAt(actualType, 0)}',
      );
    case UnexpectedFree(:final name):
      sb.writeln('internal error: unexpected free variable in kernel');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  variable: $name');
      sb.writeln('  this indicates an elaborator bug and should be reported.');
    case UnknownDataOrCtor(:final dataName, :final ctorName):
      sb.writeln('error: unknown inductive reference');
      sb.writeln('  at ${source.formatStart(span)}');
      if (ctorName == null) {
        sb.writeln('  no `data` declaration named "$dataName" is in scope');
      } else {
        sb.writeln(
          '  no constructor "$ctorName" for inductive type "$dataName"',
        );
      }
      sb.writeln(
        '  (this indicates an elaborator or kernel-plumbing bug; '
        'the elaborator should reject unresolved names before they '
        'reach the checker)',
      );
    case InductiveArityMismatch(
      :final dataName,
      :final ctorName,
      :final gotArity,
      :final expectedArity,
    ):
      sb.writeln('error: inductive-type arity mismatch');
      sb.writeln('  at ${source.formatStart(span)}');
      final who = ctorName == null ? dataName : '$dataName.$ctorName';
      sb.writeln(
        '  "$who" expects $expectedArity argument'
        '${expectedArity == 1 ? '' : 's'}, got $gotArity',
      );
    case MatchMotiveRequired():
      sb.writeln('error: match expression needs a motive in this position');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  A match used in a position where its type cannot be inferred',
      );
      sb.writeln('  from context must carry an explicit `returning <type>`');
      sb.writeln(
        '  clause. Alternatively, place the match in a position with a',
      );
      sb.writeln('  known expected type (e.g. annotate the enclosing `val` or');
      sb.writeln('  `fun` return type).');
    case ScrutineeTypeMismatchesArm(
      :final armCtorName,
      :final armCtorDataName,
      :final scrutineeDataName,
    ):
      sb.writeln('error: match arm does not fit the scrutinee type');
      sb.writeln('  at ${source.formatStart(span)}');
      if (armCtorDataName.isEmpty) {
        sb.writeln(
          '  "$armCtorName" is not a constructor of $scrutineeDataName,',
        );
        sb.writeln('  and is not registered anywhere in scope.');
      } else {
        sb.writeln(
          '  "$armCtorName" is a constructor of $armCtorDataName, but',
        );
        sb.writeln('  the scrutinee has inductive type $scrutineeDataName.');
      }
    case MatchScrutineeNotInductive(:final actualType):
      sb.writeln('error: match scrutinee is not an inductive-type value');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  scrutinee has type: ${_prettyValueAt(actualType, 0)}');
      sb.writeln('  `match` requires a scrutinee whose type is a registered');
      sb.writeln('  `data` declaration (e.g. Nat, List[A], etc.).');
    case IndexedMatchNotExhaustive(
      :final dataName,
      :final missingReachableCtors,
    ):
      sb.writeln('error: indexed-family match is not exhaustive');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  $dataName has uncovered reachable constructor'
        '${missingReachableCtors.length == 1 ? '' : 's'}: '
        '${missingReachableCtors.join(', ')}.',
      );
      sb.writeln('  Add explicit arms or a wildcard `case _ => ...`.');
      sb.writeln(
        '  Unreachable ctors (by ctor-head clash with the scrutinee\'s',
      );
      sb.writeln(
        '  indices, e.g. `vnil` on a `Vec[A] (succ n)`) may be omitted.',
      );
    case PropEliminationIntoType(:final dataName, :final resultSort):
      sb.writeln('error: Prop elimination into Type');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  match on "$dataName" (a Prop-sorted inductive) cannot produce',
      );
      sb.writeln(
        '  a Type-sorted result (inferred sort: '
        '${_prettyValueAt(resultSort, 0)}).',
      );
      sb.writeln('  SPEC §8.2 restricts Prop → Type elimination: allowing it');
      sb.writeln('  would combine with definitional proof irrelevance to give');
      sb.writeln('  inconsistency. The singleton-elimination exception admits');
      sb.writeln('  Prop → Type when the inductive has ≤ 1 ctor and no');
      sb.writeln('  informative args; this inductive does not qualify.');
    case NotAQuotient(:final actual):
      sb.writeln('error: not a quotient type');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  expected a quotient type (Quot(A, R)), '
        'got: ${_prettyValueAt(actual, 0)}',
      );
    case QuotMkInInferMode():
      sb.writeln('error: quotient injection in infer mode');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  `mk a` cannot be used in a position where its type cannot '
        'be inferred.',
      );
      sb.writeln(
        '  Provide an expected type via an annotation, or use the value '
        'where its quotient type is known (e.g. as an argument).',
      );
    case QuotFnNotRespectingRelation(:final got, :final expected):
      sb.writeln('error: quotient lift function does not respect the relation');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  expected compatibility proof type: '
        '${_prettyValueAt(expected, 0)}',
      );
      sb.writeln('  actual: ${_prettyValueAt(got, 0)}');
  }
  return sb.toString();
}

/// Format an [ElabError] against [source].
String reportElabError(SourceFile source, ElabError error) {
  final sb = StringBuffer();
  switch (error) {
    case UnresolvedName(:final name, :final span):
      sb.writeln('error: unresolved name');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  no binding for "$name" in scope');
    case DuplicateDeclaration(:final name, :final previousSpan, :final span):
      sb.writeln('error: duplicate declaration');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  "$name" was previously declared here:');
      sb.writeln('    ${source.formatStart(previousSpan)}');
    case LambdaRequiresAnnotation(:final name, :final span):
      sb.writeln('error: lambda requires a type annotation');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  write `($name: T) => ...`, or place the lambda where its');
      sb.writeln('  type is expected (e.g. a `val` with a function type); an');
      sb.writeln('  unannotated lambda only checks against a known `Pi` type.');
    case NonStructuralRecursion(:final calleeName, :final span):
      sb.writeln('error: non-structural recursion');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  The call to "$calleeName" does not pass a strict sub-term');
      sb.writeln(
        '  of the function\'s designated decreasing argument (the first',
      );
      sb.writeln(
        '  explicit value parameter) in that position. Pattern binders',
      );
      sb.writeln(
        '  from a `match` on the designated argument are valid strict',
      );
      sb.writeln('  sub-terms; passing the designated argument itself, or any');
      sb.writeln('  other value, is not. This is the SPEC §8.6 soundness rule');
      sb.writeln('  for CIC termination.');
    case DataSortNotASort(:final dataName, :final span):
      sb.writeln('error: data declaration signature must end in a sort');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  "$dataName"\'s signature must end in `Type n`, `Prop`, or `SProp`, not a',
      );
      sb.writeln('  concrete type. Check the arrow chain after the `:`.');
    case SPropFieldNotProofIrrelevant(:final fieldName, :final span):
      sb.writeln('error: SProp-inductive field is not SProp-sorted');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  "$fieldName" has a non-SProp type. All fields of an SProp-sorted',
      );
      sb.writeln('  inductive must themselves be SProp-sorted.');
    case MutualHeaderCycle(:final cycle, :final span):
      sb.writeln('error: mutual-data header cycle');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  Members ${cycle.join(", ")} form a cycle through their header',
      );
      sb.writeln(
        '  signatures; no topological order exists. Restructure so the',
      );
      sb.writeln('  header dependencies are a DAG, or move the cross-ref');
      sb.writeln(
        '  to ctor arg types (which are elaborated in pass 2 against a',
      );
      sb.writeln('  scratch env with every sibling partial registered).');
    case CtorResultShapeMismatch(
      :final dataName,
      :final ctorName,
      :final span,
      :final reason,
    ):
      sb.writeln(
        'error: constructor result type does not match its data declaration',
      );
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  $dataName.$ctorName: $reason');
    case PositivityViolation(
      :final dataName,
      :final ctorName,
      :final argIndex,
      :final span,
    ):
      sb.writeln('error: positivity violation');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  $dataName.$ctorName\'s argument ${argIndex + 1} mentions '
        "'$dataName' in a strictly-negative position.",
      );
      sb.writeln('  An inductive type may appear on the RIGHT of arrows in a');
      sb.writeln(
        '  constructor\'s argument types (subterm recursion), but not',
      );
      sb.writeln(
        '  on the LEFT (negative position), otherwise the type admits',
      );
      sb.writeln('  non-terminating recursion and the kernel loses soundness.');
    case MatchIndeterminateType(:final span):
      sb.writeln('error: match scrutinee type cannot be determined');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  Add at least one `case <ctor>` arm (which reveals the');
      sb.writeln('  inductive type via the ctor name) or an explicit');
      sb.writeln('  `returning <type>` clause. A wildcard-only match cannot');
      sb.writeln('  be elaborated without one of these.');
    case UnknownCtorInMatch(:final ctorName, :final span):
      sb.writeln('error: unknown constructor in match arm');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  "$ctorName" is not a constructor of any declared data type.',
      );
    case CtorMismatchInMatch(
      :final ctorName,
      :final ctorDataName,
      :final scrutineeDataName,
      :final span,
    ):
      sb.writeln('error: constructor does not match scrutinee type');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  "$ctorName" is a constructor of $ctorDataName, but the');
      sb.writeln('  scrutinee has inductive type $scrutineeDataName.');
    case MatchArmArityMismatch(
      :final ctorName,
      :final gotBinders,
      :final expectedBinders,
      :final span,
    ):
      sb.writeln('error: match arm pattern has the wrong number of binders');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  "$ctorName" takes $expectedBinders argument'
        '${expectedBinders == 1 ? '' : 's'}, but the pattern binds '
        '$gotBinders.',
      );
    case DuplicateMatchCase(:final ctorName, :final firstSpan, :final span):
      sb.writeln('error: duplicate case in match');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  "$ctorName" was already handled at ${source.formatStart(firstSpan)}.',
      );
    case NonExhaustiveMatch(:final dataName, :final missingCtors, :final span):
      sb.writeln('error: match is not exhaustive');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  $dataName has uncovered constructor'
        '${missingCtors.length == 1 ? '' : 's'}: '
        '${missingCtors.join(', ')}.',
      );
      sb.writeln('  Add explicit arms or a wildcard `case _ => ...`.');
    case CyclicImport(:final path, :final span):
      sb.writeln('error: cyclic import');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  import of "$path" would create a cycle in the import graph.',
      );
    case ImportFileNotFound(:final path, :final span):
      sb.writeln('error: import file not found');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  cannot find file: $path');
    case StructAnnotationNotFound(
      :final funName,
      :final paramName,
      :final span,
    ):
      sb.writeln('error: struct annotation references non-existent parameter');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  "$funName" has no value parameter named "$paramName".');
      sb.writeln(
        '  The `{struct name}` annotation must name a value parameter',
      );
      sb.writeln('  of the annotated function.');
    case TacticFailed(:final message, :final span):
      sb.writeln('error: tactic failed');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln('  $message');
    case TacticIncomplete(:final span):
      sb.writeln('error: tactic block did not solve the goal');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  The tactic sequence finished but the goal remains unsolved.',
      );
      sb.writeln('  Add more steps or a different approach.');
    case NoInstanceFound(:final className, :final targetType, :final span):
      sb.writeln('error: no instance found');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  No instance of typeclass "$className" found for type "$targetType".',
      );
    case OverlappingInstances(
      :final className,
      :final targetType,
      :final instanceNames,
      :final span,
    ):
      sb.writeln('error: overlapping instances');
      sb.writeln('  at ${source.formatStart(span)}');
      sb.writeln(
        '  Multiple instances of typeclass "$className" match type "$targetType": '
        '${instanceNames.join(", ")}.',
      );
      sb.writeln('  Use a more specific instance or remove the overlap.');
  }
  return sb.toString();
}

/// Pretty-print a [Value] by quoting it at the supplied [level] and
/// rendering with the printer pre-populated with that many outer
/// placeholder scopes.
///
/// Sub-values returned by the diff walker may reference free neutrals
/// whose levels are internal to the walker. Passing the walker's
/// reported level ensures those references (a) quote to valid
/// (non-negative) de Bruijn indices and (b) render as placeholder
/// identifiers (`?a`, `?b`, …) rather than `?-1`.
String _prettyValueAt(
  Value v,
  int level, [
  List<String?> outerNames = const <String?>[],
]) => prettyTerm(quote(level, v), outerDepth: level, outerNames: outerNames);
