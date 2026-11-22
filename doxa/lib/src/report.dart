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
  bool isDoxaChar(int cp) =>
      (cp >= 65 && cp <= 90) || // A-Z
      (cp >= 97 && cp <= 122) || // a-z
      cp == 95 || // _
      (cp >= 48 && cp <= 57) || // 0-9
      cp == 40 ||
      cp == 41 || // ( )
      cp == 123 ||
      cp == 125 || // { }
      cp == 58 || // :
      cp == 61 || // =
      cp == 60 || // < (for <=)
      cp == 42 || // * (infix multiplication)
      cp == 43 || // + (infix addition)
      cp == 44 || // ,
      cp == 46 || // .
      cp == 45 || // - (for ->)
      cp == 47 || // / (comments)
      cp == 32 ||
      cp == 10 ||
      cp == 9 ||
      cp == 13; // whitespace

  for (final e in failure.errors) {
    final msg = '$e';
    sb.writeln('  $msg');
  }
  // Inspect the character at the deepest failure position. If it is not
  // a valid Doxa start character, the error was likely caused by a
  // stray character the user intended as part of an identifier or
  // expression. This is position-driven — independent of whatever rumil
  // error message was produced.
  final offset = failure.furthest.offset;
  if (offset < source.text.length) {
    final ch = source.text[offset];
    if (!isDoxaChar(ch.codeUnitAt(0))) {
      sb.writeln('  note: «$ch» is not a valid character in Doxa');
    }
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
    case InvalidMetaSolution(
      :final metaId,
      :final typeExpected,
      :final level,
      :final cause,
    ):
      sb.writeln("${c.error('error')}: solved metavariable is ill-typed");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  ?$metaId was solved with a term that does not have its expected type',
      );
      sb.writeln('  ${_prettyValueAt(typeExpected, level)}');
      switch (cause) {
        case TypeMismatch(:final got, :final expected, level: final innerLevel):
          sb.writeln(
            '  solution mismatch: expected '
            '${_prettyValueAt(expected, innerLevel)}, '
            'found ${_prettyValueAt(got, innerLevel)}',
          );
        default:
          sb.writeln('  ${cause.toString()}');
      }
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
    case UnknownTypeReached(:final site):
      sb.writeln("${c.error('error')}: internal error: unknown type");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  the elaborator needed a type it does not know ($site).');
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
    case QuotMkInInferMode():
      sb.writeln("${c.error('error')}: quotient injection in infer mode");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  `mk a` needs the quotient type it injects into, which only an',
      );
      sb.writeln('  expected type supplies. Annotate the binding:');
      sb.writeln('    val q: Quot(A, R) = mk a');
    case QuotLiftInInferMode():
      sb.writeln("${c.error('error')}: quotient elimination in infer mode");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  `lift f h` has type `Quot(A, R) -> B`, which only an expected',
      );
      sb.writeln('  type supplies. Annotate the binding:');
      sb.writeln('    val g: Quot(A, R) -> B = lift f h');
    case QuotSoundInInferMode():
      sb.writeln("${c.error('error')}: quotient soundness proof in infer mode");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  `Quot.sound h` proves `Eq (Quot(A, R)) (mk a) (mk b)`, which only',
      );
      sb.writeln('  an expected equality supplies.');
    case NotAQuotient(:final actual):
      sb.writeln("${c.error('error')}: not a quotient type");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  expected a quotient type (Quot(A, R)), or a function from one, '
        'got: ${_prettyValueAt(actual, 0)}',
      );
    case QuotLiftNeedsConstantResult(:final expected):
      sb.writeln(
        "${c.error('error')}: quotient elimination needs a constant result type",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  the result type may not read the quotient element; '
        'got: ${_prettyValueAt(expected, 0)}',
      );
    case QuotSoundNeedsInjection(:final expected):
      sb.writeln(
        "${c.error('error')}: quotient soundness needs an equality of injections",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  expected `Eq (Quot(A, R)) (mk a) (mk b)`, '
        'got: ${_prettyValueAt(expected, 0)}',
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
      sb.writeln(
        '  sub-terms. This is the structural-recursion rule '
        '(SPEC, Structural recursion)',
      );
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
    case UnannotatedDeclIndeterminate(:final name, :final span):
      sb.writeln(
        "${c.error('error')}: cannot infer the type of declaration \"$name\"",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  The body leaves an implicit argument undetermined, so the');
      sb.writeln('  declaration has no type. Annotate it:');
      sb.writeln('    val $name: T = ...');
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
    case ImportPackageNotFound(
      :final importPath,
      :final packageName,
      :final currentFile,
      :final configPath,
      :final malformedSpecifier,
      :final span,
    ):
      sb.writeln("${c.error('error')}: package import not found");
      sb.write(source.formatContext(span, color: c));
      if (malformedSpecifier) {
        sb.writeln('  cannot resolve "$importPath":');
        sb.writeln('  a package import needs a name and a path.');
        sb.writeln('  Use `package:<name>/<path>`.');
      } else if (configPath == null) {
        sb.writeln('  cannot resolve "$importPath":');
        sb.writeln(
          '  no .dart_tool/package_config.json was found above $currentFile.',
        );
        sb.writeln('  Run `dart pub get` in that project.');
      } else {
        sb.writeln('  cannot resolve "$importPath":');
        sb.writeln('  package "$packageName" is not declared in $configPath.');
        sb.writeln(
          '  Add it to the project dependencies and run `dart pub get`.',
        );
      }
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
    case TerminationByUnsupported(:final span):
      sb.writeln("${c.error('error')}: termination_by is not supported");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  The `termination_by` annotation is rejected: its measure is not',
      );
      sb.writeln(
        '  checked, and the fuel desugaring can accept non-terminating',
      );
      sb.writeln(
        '  recursions. Use structural recursion, or `Acc.rec` with `nat_wf`.',
      );
    case QuotientUnsupported(:final span):
      sb.writeln(
        "${c.error('error')}: quotient construction and elimination are not supported",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  `mk` and `lift` are rejected until the kernel checks the lift',
      );
      sb.writeln(
        '  compatibility proof. `Quot(A, R)` still forms a type; use a data type',
      );
      sb.writeln('  or a setoid-style encoding.');
    case TypeclassUnsupported(:final span, :final reason):
      sb.writeln("${c.error('error')}: typeclass form not supported");
      sb.write(source.formatContext(span, color: c));
      if (reason != null) {
        sb.writeln('  $reason.');
      } else {
        sb.writeln(
          '  The `typeclass` and `impl` surface is partially implemented:',
        );
        sb.writeln(
          '  single-parameter classes with method signatures and instances',
        );
        sb.writeln('  resolve, but this form is outside that slice.');
      }
    case SuperclassUnsupported(
      :final className,
      :final superclassName,
      :final span,
    ):
      sb.writeln(
        "${c.error('error')}: typeclass superclasses are not implemented",
      );
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  typeclass "$className: $superclassName" declares a superclass.',
      );
      sb.writeln(
        '  Superclasses are out of scope; pass the parent dictionary explicitly.',
      );
    case UnknownTypeclass(:final className, :final span):
      sb.writeln("${c.error('error')}: unknown typeclass");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  The impl names typeclass "$className", which is not declared or imported.',
      );
    case TypeclassArityMismatch(
      :final className,
      :final expected,
      :final got,
      :final span,
    ):
      sb.writeln("${c.error('error')}: typeclass arity mismatch");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  typeclass "$className" takes $expected type '
        'argument${expected == 1 ? '' : 's'}, but this impl applies $got.',
      );
    case MissingInstanceMethod(
      :final className,
      :final methodName,
      :final span,
    ):
      sb.writeln("${c.error('error')}: incomplete instance");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  The impl for "$className" is missing method "$methodName".',
      );
      sb.writeln(
        '  An instance must implement every method the class declares.',
      );
    case UnknownInstanceMethod(
      :final className,
      :final methodName,
      :final span,
    ):
      sb.writeln("${c.error('error')}: unknown instance method");
      sb.write(source.formatContext(span, color: c));
      sb.writeln('  typeclass "$className" has no method "$methodName".');
    case UnsupportedInstanceTarget(
      :final className,
      :final targetType,
      :final reason,
      :final span,
    ):
      sb.writeln("${c.error('error')}: unsupported instance target");
      sb.write(source.formatContext(span, color: c));
      if (reason != null) {
        sb.writeln('  $reason.');
        sb.writeln('  Instance search matches the target head and matches the');
        sb.writeln(
          '  target arguments positionally against the instance parameters.',
        );
      } else {
        sb.writeln(
          '  The impl for "$className" targets "$targetType", which is not',
        );
        sb.writeln(
          '  headed by a named type constructor. Instance search matches the',
        );
        sb.writeln('  head constructor, so the target must be a data type.');
      }
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
    case InstanceSearchDepthExceeded(
      :final className,
      :final targetType,
      :final depth,
      :final span,
    ):
      sb.writeln("${c.error('error')}: instance search depth exceeded");
      sb.write(source.formatContext(span, color: c));
      sb.writeln(
        '  Searching for "$className" at "$targetType" exceeded the depth '
        'bound of $depth.',
      );
      sb.writeln(
        '  The instance chain is too deep; the search is stopped rather '
        'than continued.',
      );
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
