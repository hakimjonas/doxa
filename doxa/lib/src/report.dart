/// Diagnostic formatting: turn errors into user-facing strings.
///
/// This is the final step of Doxa's error-reporting pipeline. Each of
/// the error families (`ParseError` from Rumil, `ElabError` from
/// elaboration, `DoxaCheckError` from type checking) is rendered into a
/// consistent format with source span, kind, and (for type mismatches)
/// the diff path plus pretty-printed expected/got types.
///
/// All report functions accept an optional [AnsiColor] for colourised
/// terminal output. When omitted, ANSI escapes are disabled (suitable
/// for piped or JSON output).
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
String reportParseError(
  SourceFile source,
  ParseError error, {
  AnsiColor? color,
}) {
  final c = color ?? const AnsiColor(false);
  final sb = StringBuffer();
  sb.writeln("${c.error('error')}: parse error");
  sb.writeln(
    '  at ${source.filename}:${error.location.line}:${error.location.column}',
  );
  sb.writeln('  $error');
  return sb.toString();
}

/// Format a Rumil-returned [Failure] carrying one or more parse errors.
String reportParseFailure(
  SourceFile source,
  Failure<ParseError, Object?> failure, {
  AnsiColor? color,
}) {
  final c = color ?? const AnsiColor(false);
  final sb = StringBuffer();
  sb.writeln("${c.error('error')}: parse error");
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
/// The [span] argument is the source span to blame.
String reportCheckError(
  SourceFile source,
  DoxaCheckError error,
  DoxaSpan span, {
  AnsiColor? color,
}) {
  final c = color ?? const AnsiColor(false);
  final sb = StringBuffer();
  switch (error) {
    case TypeMismatch(:final got, :final expected, level: final ctxLevel):
      sb.writeln("${c.error('error')}: type mismatch");
      sb.write(
        source.formatContext(
          span,
          color: c,
          label:
              'expected ${_prettyValueAt(expected, ctxLevel)}, '
              'found ${_prettyValueAt(got, ctxLevel)}',
        ),
      );
      final diff = diffValues(got, expected);
      if (!diff.isTopLevel) {
        sb.writeln(
          '  ${c.bold}= note${c.reset}: '
          'first difference at ${diff.describePath()}',
        );
        final innerLevel = ctxLevel + diff.level;
        final innerNames = <String?>[
          ...List<String?>.filled(ctxLevel, null),
          ...diff.binderNames,
        ];
        sb.writeln(
          '    expected: '
          '${_prettyValueAt(diff.expected, innerLevel, innerNames)}',
        );
        sb.writeln(
          '    actual:   '
          '${_prettyValueAt(diff.got, innerLevel, innerNames)}',
        );
      }
    case NotAFunction(:final actualType):
      sb.writeln("${c.error('error')}: not a function");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  applied value has type: ${_prettyValueAt(actualType, 0)}');
    case NotAType(:final actualType):
      sb.writeln("${c.error('error')}: not a type");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  expected a universe (Type n), got: ${_prettyValueAt(actualType, 0)}',
      );
    case UnexpectedFree(:final name):
      sb.writeln("${c.error('error')}: unexpected free variable in kernel");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  variable: $name');
      sb.writeln('  this indicates an elaborator bug and should be reported.');
    case UnknownDataOrCtor(:final dataName, :final ctorName):
      sb.writeln("${c.error('error')}: unknown inductive reference");
      sb.write(source.formatContext(span, color: c));
      if (ctorName == null) {
        sb.writeln('  no `data` declaration named "$dataName" is in scope');
      } else {
        sb.writeln(
          '  no constructor "$ctorName" for inductive type "$dataName"',
        );
      }
    case InductiveArityMismatch(
      :final dataName,
      :final ctorName,
      :final gotArity,
      :final expectedArity,
    ):
      sb.writeln("${c.error('error')}: inductive-type arity mismatch");
      sb.write(source.formatContext(span, color: c));
      final who = ctorName == null ? dataName : '$dataName.$ctorName';
      sb.writeln(
        '  "$who" expects $expectedArity argument'
        '${expectedArity == 1 ? '' : 's'}, got $gotArity',
      );
    case MatchMotiveRequired():
      sb.writeln(
        "${c.error('error')}: match expression needs a motive in this position",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  A match used in a position where its type cannot be inferred',
      );
      sb.writeln('  from context must carry an explicit `returning <type>`');
      sb.writeln(
        '  clause. Alternatively, annotate the enclosing `val` or `fun` '
        'return type.',
      );
    case ScrutineeTypeMismatchesArm(
      :final armCtorName,
      :final armCtorDataName,
      :final scrutineeDataName,
    ):
      sb.writeln(
        "${c.error('error')}: match arm does not fit the scrutinee type",
      );
      sb.write(source.formatContext(span, color: c));
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
      sb.writeln(
        "${c.error('error')}: match scrutinee is not an inductive-type value",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  scrutinee has type: ${_prettyValueAt(actualType, 0)}');
      sb.writeln('  `match` requires a scrutinee whose type is a registered');
      sb.writeln('  `data` declaration (e.g. Nat, List[A], etc.).');
    case IndexedMatchNotExhaustive(
      :final dataName,
      :final missingReachableCtors,
    ):
      sb.writeln("${c.error('error')}: indexed-family match is not exhaustive");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  $dataName has uncovered reachable constructor'
        '${missingReachableCtors.length == 1 ? '' : 's'}: '
        '${missingReachableCtors.join(', ')}.',
      );
      sb.writeln('  Add explicit arms or a wildcard `case _ => ...`.');
    case PropEliminationIntoType(:final dataName, :final resultSort):
      sb.writeln("${c.error('error')}: Prop elimination into Type");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  match on "$dataName" (a Prop-sorted inductive) cannot produce',
      );
      sb.writeln(
        '  a Type-sorted result (inferred sort: '
        '${_prettyValueAt(resultSort, 0)}).',
      );
    case NotAQuotient(:final actual):
      sb.writeln("${c.error('error')}: not a quotient type");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  expected a quotient type (Quot(A, R)), '
        'got: ${_prettyValueAt(actual, 0)}',
      );
    case QuotMkInInferMode():
      sb.writeln("${c.error('error')}: quotient injection in infer mode");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  `mk a` cannot be used in a position where its type cannot '
        'be inferred.',
      );
      sb.writeln(
        '  Provide an expected type via an annotation, or use the value '
        'where its quotient type is known (e.g. as an argument).',
      );
    case QuotFnNotRespectingRelation(:final got, :final expected):
      sb.writeln(
        "${c.error('error')}: quotient lift function does not respect the relation",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  expected compatibility proof type: '
        '${_prettyValueAt(expected, 0)}',
      );
      sb.writeln('  actual: ${_prettyValueAt(got, 0)}');
  }
  return sb.toString();
}

/// Format an [ElabError] against [source].
String reportElabError(SourceFile source, ElabError error, {AnsiColor? color}) {
  final c = color ?? const AnsiColor(false);
  final sb = StringBuffer();
  switch (error) {
    case UnresolvedName(:final name, :final span):
      sb.writeln("${c.error('error')}: unresolved name");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  no binding for "$name" in scope');
    case DuplicateDeclaration(:final name, :final previousSpan, :final span):
      sb.writeln("${c.error('error')}: duplicate declaration");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  "$name" was previously declared here:');
      sb.writeln('    ${source.formatStart(previousSpan)}');
    case LambdaRequiresAnnotation(:final name, :final span):
      sb.writeln("${c.error('error')}: lambda requires a type annotation");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  write `($name: T) => ...`, or place the lambda where its');
      sb.writeln('  type is expected (e.g. a `val` with a function type).');
    case NonStructuralRecursion(:final calleeName, :final span):
      sb.writeln("${c.error('error')}: non-structural recursion");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  The call to "$calleeName" does not pass a strict sub-term');
      sb.writeln(
        '  of the function\'s designated decreasing argument. Pattern binders',
      );
      sb.writeln(
        '  from a `match` on the designated argument are valid strict',
      );
      sb.writeln('  sub-terms. This is the SPEC §8.6 soundness rule');
      sb.writeln('  for CIC termination.');
    case DataSortNotASort(:final dataName, :final span):
      sb.writeln(
        "${c.error('error')}: data declaration signature must end in a sort",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  "$dataName"\'s signature must end in `Type n`, `Prop`, or `SProp`.',
      );
    case SPropFieldNotProofIrrelevant(:final fieldName, :final span):
      sb.writeln(
        "${c.error('error')}: SProp-inductive field is not SProp-sorted",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  "$fieldName" has a non-SProp type. All fields of an SProp-sorted',
      );
      sb.writeln('  inductive must themselves be SProp-sorted.');
    case MutualHeaderCycle(:final cycle, :final span):
      sb.writeln("${c.error('error')}: mutual-data header cycle");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  Members ${cycle.join(", ")} form a cycle through their header',
      );
      sb.writeln('  signatures; restructure so header dependencies are a DAG.');
    case CtorResultShapeMismatch(
      :final dataName,
      :final ctorName,
      :final span,
      :final reason,
    ):
      sb.writeln(
        "${c.error('error')}: constructor result type does not match its data declaration",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  $dataName.$ctorName: $reason');
    case PositivityViolation(
      :final dataName,
      :final ctorName,
      :final argIndex,
      :final span,
    ):
      sb.writeln("${c.error('error')}: positivity violation");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  $dataName.$ctorName\'s argument ${argIndex + 1} mentions '
        "'$dataName' in a strictly-negative position.",
      );
      sb.writeln('  An inductive type may appear on the RIGHT of arrows in a');
      sb.writeln(
        '  constructor\'s argument types (subterm recursion), but not',
      );
      sb.writeln('  on the LEFT (negative position).');
    case MatchIndeterminateType(:final span):
      sb.writeln(
        "${c.error('error')}: match scrutinee type cannot be determined",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  Add at least one `case <ctor>` arm or an explicit');
      sb.writeln('  `returning <type>` clause.');
    case UnknownCtorInMatch(:final ctorName, :final span):
      sb.writeln("${c.error('error')}: unknown constructor in match arm");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  "$ctorName" is not a constructor of any declared data type.',
      );
    case CtorMismatchInMatch(
      :final ctorName,
      :final ctorDataName,
      :final scrutineeDataName,
      :final span,
    ):
      sb.writeln(
        "${c.error('error')}: constructor does not match scrutinee type",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  "$ctorName" is a constructor of $ctorDataName, but the');
      sb.writeln('  scrutinee has inductive type $scrutineeDataName.');
    case MatchArmArityMismatch(
      :final ctorName,
      :final gotBinders,
      :final expectedBinders,
      :final span,
    ):
      sb.writeln(
        "${c.error('error')}: match arm pattern has the wrong number of binders",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  "$ctorName" takes $expectedBinders argument'
        '${expectedBinders == 1 ? '' : 's'}, but the pattern binds '
        '$gotBinders.',
      );
    case DuplicateMatchCase(:final ctorName, :final firstSpan, :final span):
      sb.writeln("${c.error('error')}: duplicate case in match");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  "$ctorName" was already handled at ${source.formatStart(firstSpan)}.',
      );
    case NonExhaustiveMatch(:final dataName, :final missingCtors, :final span):
      sb.writeln("${c.error('error')}: match is not exhaustive");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  $dataName has uncovered constructor'
        '${missingCtors.length == 1 ? '' : 's'}: '
        '${missingCtors.join(', ')}.',
      );
      sb.writeln('  Add explicit arms or a wildcard `case _ => ...`.');
    case CyclicImport(:final path, :final span):
      sb.writeln("${c.error('error')}: cyclic import");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  import of "$path" would create a cycle in the import graph.',
      );
    case ImportFileNotFound(:final path, :final span):
      sb.writeln("${c.error('error')}: import file not found");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  cannot find file: $path');
    case StructAnnotationNotFound(
      :final funName,
      :final paramName,
      :final span,
    ):
      sb.writeln(
        "${c.error('error')}: struct annotation references non-existent parameter",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  "$funName" has no value parameter named "$paramName".');
      sb.writeln(
        '  The `{struct name}` annotation must name a value parameter',
      );
      sb.writeln('  of the annotated function.');
    case TerminationByParamNotFound(
      :final funName,
      :final paramName,
      :final span,
    ):
      sb.writeln("${c.error('error')}: termination_by parameter not found");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  "$funName" has no value parameter named "$paramName".');
      sb.writeln(
        '  The `termination_by` annotation must name value parameters',
      );
      sb.writeln('  of the annotated function.');
    case TacticFailed(:final message, :final span):
      sb.writeln("${c.error('error')}: tactic failed");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  $message');
    case TacticIncomplete(:final span):
      sb.writeln("${c.error('error')}: tactic block did not solve the goal");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  The tactic sequence finished but the goal remains unsolved.',
      );
      sb.writeln('  Add more steps or a different approach.');
    case NoInstanceFound(:final className, :final targetType, :final span):
      sb.writeln("${c.error('error')}: no instance found");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  No instance of typeclass "$className" found for type "$targetType".',
      );
    case OverlappingInstances(
      :final className,
      :final targetType,
      :final instanceNames,
      :final span,
    ):
      sb.writeln("${c.error('error')}: overlapping instances");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  Multiple instances of typeclass "$className" match type "$targetType": '
        '${instanceNames.join(", ")}.',
      );
      sb.writeln('  Use a more specific instance or remove the overlap.');
  }
  return sb.toString();
}

/// Pretty-print a [Value] by quoting it at the supplied [level] and
/// rendering with the compact printer (depth-capped) pre-populated
/// with that many outer placeholder scopes.
String _prettyValueAt(
  Value v,
  int level, [
  List<String?> outerNames = const <String?>[],
]) => prettyTermCompact(
  quote(level, v),
  outerDepth: level,
  outerNames: outerNames,
);
