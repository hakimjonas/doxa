/// Pure pipeline driver for the full Doxa parse → elaborate → check
/// pipeline, producing structured [CheckOutput].
///
/// This is the I/O-free core used by the WasmGC browser entry
/// (`web/doxa_check.dart`) and by native harnesses/tests that want to
/// exercise the whole pipeline without spawning a subprocess or wiring
/// up [IOSink]s.
///
/// Three entry points:
///
///   * [checkSourceString] — returns a human-readable diagnostic string
///     (kept for backward compat with existing callers).
///   * [checkSourceJson] — returns the result serialised as JSON.
///   * [checkSourceOutput] — returns the structured [CheckOutput].
library;

import 'package:rumil/rumil.dart';

import 'package:doxa/doxa.dart' show loadPrelude;
import 'package:doxa/doxa.dart';
import 'output.dart';

/// Run the full pipeline and return the structured [CheckOutput].
CheckOutput checkSourceOutput(
  String src, {
  String filename = 'playground.doxa',
}) {
  final source = SourceFile(filename: filename, text: src);
  final parseResult = parseProgram(source.text);
  final program = switch (parseResult) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() => null,
  };
  if (program == null) {
    final failure = parseResult as Failure<ParseError, Object?>;
    final line = failure.furthest.line;
    final column = failure.furthest.column;
    final message = reportParseFailure(source, failure);
    return CheckFailure(
      errors: [
        CheckError(
          kind: 'parse_error',
          line: line,
          column: column,
          message: message,
        ),
      ],
    );
  }

  final prelude = loadPrelude();
  final importState = ImportState();
  importState.currentImportPath = filename;
  importState.importedPaths.clear();

  // Pre-resolve and process all transitive imports.
  final resolver = ImportResolver(importState, prelude: prelude);
  try {
    resolver.processTransitiveImports(program);
  } on ElabError catch (e) {
    final reportSource = importState.sourceFileFor(e.span) ?? source;
    return CheckFailure(
      errors: [
        CheckError(
          kind: 'elab_error',
          line: source.positionAt(e.span.start).line,
          column: source.positionAt(e.span.start).column,
          message: reportElabError(reportSource, e),
          span: e.span.isSynthetic ? null : e.span,
        ),
      ],
    );
  } on DoxaCheckError catch (e) {
    return CheckFailure(
      errors: [
        CheckError(
          kind: 'check_error',
          line: 0,
          column: 0,
          message: e.toString(),
        ),
      ],
    );
  }

  var bindings = resolver.bindings;
  var dataDecls = resolver.dataDecls;
  var namespaceBindings = resolver.namespaceBindings;
  var classRegistry = resolver.classRegistry;
  final preludeDeclCount = prelude.bindings.length + prelude.dataDecls.length;
  final declarations = <DeclInfo>[];
  final allSemInfos = <SemInfo>[];

  // Multi-error accumulator.
  final errors = <Map<String, dynamic>>[];
  final poisonedNames = <String>{};

  for (final decl in program.decls) {
    final String currentKind = switch (decl.kind) {
      SValKind _ => 'val',
      STypeAliasKind _ => 'type',
      SFunKind _ => 'fun',
      SFunBlockKind _ => 'fun',
      SDataKind _ => 'data',
      SDataBlockKind _ => 'data',
      SImportKind _ => 'import',
      STypeclassKind _ => 'typeclass',
      SImplKind _ => 'impl',
    };

    final prevBindingsLen = bindings.length;
    final prevDataDeclsLen = dataDecls.length;

    try {
      final produced = elabDecl(
        TopEnv(
          bindings,
          dataDecls,
          classRegistry,
          namespaceBindings,
          importState,
        ),
        decl,
      );
      final runningData = [...dataDecls, ...produced.dataDecls];
      final checkBindings =
          decl.kind is SImportKind
              ? [...bindings, ...produced.bindings]
              : bindings;
      final checkClassRegistry = {...classRegistry, ...produced.classRegistry};
      final finalized = checkDeclResult(
        TopEnv(
          checkBindings,
          runningData,
          checkClassRegistry,
          namespaceBindings,
          importState,
        ),
        produced,
      );
      bindings = [...bindings, ...finalized];
      dataDecls = runningData;
      classRegistry = checkClassRegistry;
      namespaceBindings = mergeNamespace(
        namespaceBindings,
        produced.namespaceBindings,
      );

      // Collect semantic metadata from this declaration's elaboration.
      final declSemInfos = produced.metas?.semInfos;
      if (declSemInfos != null && declSemInfos.isNotEmpty) {
        allSemInfos.addAll(declSemInfos);
      }

      for (var i = prevDataDeclsLen; i < dataDecls.length; i++) {
        final dd = dataDecls[i];
        declarations.add(
          DeclInfo(
            name: dd.name,
            kind: currentKind,
            type: prettyTerm(dd.sort, outerDepth: 0),
            span: dd.span,
          ),
        );
      }

      for (var i = prevBindingsLen; i < bindings.length; i++) {
        final binding = bindings[i];
        final typeStr = prettyTerm(binding.type, outerDepth: 0);
        declarations.add(
          DeclInfo(
            name: binding.name,
            kind: currentKind,
            type: typeStr,
            span: binding.span,
          ),
        );
      }
    } on DoxaCheckError catch (e) {
      final reportSpan = switch (e) {
        TypeMismatch(:final span) when span != null => span,
        ScrutineeTypeMismatchesArm(:final armSpan) when armSpan != null =>
          armSpan,
        _ => decl.span,
      };
      final reportSource = importState.sourceFileFor(reportSpan) ?? source;
      final message = reportCheckError(reportSource, e, reportSpan);
      final pos = reportSource.positionAt(reportSpan.start);
      final (expected, actual) = switch (e) {
        TypeMismatch(:final got, :final expected, level: final level) => (
          _prettyValueAt(expected, level),
          _prettyValueAt(got, level),
        ),
        _ => (null, null),
      };
      errors.add({
        'kind': _checkErrorKind(e),
        'line': pos.line,
        'column': pos.column,
        'expected': expected,
        'actual': actual,
        'message': message,
        'span': reportSpan.isSynthetic ? null : reportSpan,
      });
      for (final n in declNames(decl)) {
        poisonedNames.add(n);
      }
    } on ElabError catch (e) {
      final reportSource = importState.sourceFileFor(e.span) ?? source;
      final message = reportElabError(reportSource, e);
      final pos = reportSource.positionAt(e.span.start);
      errors.add({
        'kind': _elabErrorKind(e),
        'line': pos.line,
        'column': pos.column,
        'message': message,
        'span': e.span.isSynthetic ? null : e.span,
      });
      for (final n in declNames(decl)) {
        poisonedNames.add(n);
      }
    }
  }

  if (errors.isNotEmpty) {
    return CheckFailure(
      errors: [
        for (final e in errors)
          CheckError(
            kind: e['kind'] as String,
            line: e['line'] as int,
            column: e['column'] as int,
            expected: e['expected'] as String?,
            actual: e['actual'] as String?,
            message: e['message'] as String,
            span: e['span'] as DoxaSpan?,
          ),
      ],
    );
  }

  // Compute normal forms for val/fun declarations in the full environment
  // (which includes all accumulated top-level bindings).
  final nfEnv = _buildFullEnv(bindings, dataDecls);
  final bindingByName = {for (final b in bindings) b.name: b};
  final completedDeclarations = [
    for (final d in declarations)
      if ((d.kind == 'val' || d.kind == 'fun') &&
          bindingByName.containsKey(d.name))
        DeclInfo(
          name: d.name,
          kind: d.kind,
          type: d.type,
          normalForm: _truncate(
            prettyTerm(
              quote(0, eval(bindingByName[d.name]!.term, nfEnv)),
              outerDepth: 0,
            ),
            500,
          ),
          span: d.span,
        )
      else
        d,
  ];

  final n = bindings.length + dataDecls.length - preludeDeclCount;
  allSemInfos.sort((a, b) => a.span.start.compareTo(b.span.start));
  return CheckSuccess(
    declarations: completedDeclarations,
    count: n,
    semInfo: allSemInfos,
  );
}

/// Build an [Env] that has all [bindings] evaluated as [TopBindingEntry]s
/// and all [dataDecls] registered, so `TTop(name)` references resolve.
Env _buildFullEnv(List<TopBinding> bindings, List<DataDecl> dataDecls) {
  var acc = <String, TopBindingEntry>{};
  for (final b in bindings) {
    // Pre-seed with a stub so recursive self-references resolve
    // (same pattern as checkDeclResult for corecursive groups).
    final stubAcc = {
      ...acc,
      b.name: TopBindingEntry(
        VNeutral(NVar(0)), // placeholder — type doesn't self-reference
        VNeutral(NTop(b.name)),
        isOpaque: b.isOpaque,
        recDecreasingArg: b.recDecreasingArg,
        recArity: b.recArity,
      ),
    };
    final env = ENil.withRegistries(dataDecls: dataDecls, topBindings: stubAcc);
    final typeV = eval(b.type, env);
    final termV = eval(b.term, env);
    acc = {
      ...acc,
      b.name: TopBindingEntry(
        typeV,
        termV,
        isOpaque: b.isOpaque,
        recDecreasingArg: b.recDecreasingArg,
        recArity: b.recArity,
      ),
    };
  }
  // Verify no stub entries remain — every binding should have been
  // fully evaluated (stubs are VNeutral(NTop(name)) placeholders).
  assert(() {
    for (final entry in acc.entries) {
      final v = entry.value.value;
      if (v is VNeutral && v.neutral is NTop) {
        throw StateError(
          '_buildFullEnv: stub left behind for "${entry.key}" — '
          'binding was pre-seeded but never evaluated',
        );
      }
    }
    return true;
  }());
  return ENil.withRegistries(dataDecls: dataDecls, topBindings: acc);
}

/// Run the full pipeline and return a human-readable result string.
///
/// Delegates to [checkSourceOutput] and formats the result.
String checkSourceString(String src, {String filename = 'playground.doxa'}) {
  final output = checkSourceOutput(src, filename: filename);
  return switch (output) {
    CheckSuccess(:final count) =>
      'OK: $count ${count == 1 ? "declaration" : "declarations"} checked',
    CheckFailure(:final message) => message,
  };
}

/// Run the full pipeline and return the result as a JSON string.
String checkSourceJson(String src, {String filename = 'playground.doxa'}) =>
    checkSourceOutput(src, filename: filename).toJsonString();

/// Truncate [s] to at most [maxLen] characters, appending `"..."` when
/// truncated.
String _truncate(String s, int maxLen) {
  if (s.length <= maxLen) return s;
  return '${s.substring(0, maxLen)}...';
}

/// Map a [DoxaCheckError] to a short diagnostic kind string.
String _checkErrorKind(DoxaCheckError e) => switch (e) {
  TypeMismatch _ => 'type_mismatch',
  NotAFunction _ => 'not_a_function',
  NotAType _ => 'not_a_type',
  UnexpectedFree _ => 'internal_error',
  UnknownDataOrCtor _ => 'unknown_reference',
  InductiveArityMismatch _ => 'inductive_arity_mismatch',
  MatchMotiveRequired _ => 'match_motive_required',
  ScrutineeTypeMismatchesArm _ => 'scrutinee_type_mismatches_arm',
  MatchScrutineeNotInductive _ => 'match_scrutinee_not_inductive',
  IndexedMatchNotExhaustive _ => 'match_not_exhaustive',
  PropEliminationIntoType _ => 'prop_elimination_into_type',
  NotAQuotient _ => 'not_a_quotient',
  QuotMkInInferMode _ => 'quot_mk_in_infer_mode',
  QuotFnNotRespectingRelation _ => 'quot_fn_not_respecting_relation',
};

/// Map an [ElabError] to a short diagnostic kind string.
String _elabErrorKind(ElabError e) => switch (e) {
  UnresolvedName _ => 'unresolved_name',
  DuplicateDeclaration _ => 'duplicate_declaration',
  LambdaRequiresAnnotation _ => 'lambda_requires_annotation',
  NonStructuralRecursion _ => 'non_structural_recursion',
  DataSortNotASort _ => 'data_sort_not_a_sort',
  SPropFieldNotProofIrrelevant _ => 'sprop_field_not_proof_irrelevant',
  MutualHeaderCycle _ => 'mutual_header_cycle',
  CtorResultShapeMismatch _ => 'ctor_result_shape_mismatch',
  PositivityViolation _ => 'positivity_violation',
  MatchIndeterminateType _ => 'match_indeterminate_type',
  UnknownCtorInMatch _ => 'unknown_ctor_in_match',
  CtorMismatchInMatch _ => 'ctor_mismatch_in_match',
  MatchArmArityMismatch _ => 'match_arm_arity_mismatch',
  DuplicateMatchCase _ => 'duplicate_match_case',
  NonExhaustiveMatch _ => 'nonexhaustive_match',
  CyclicImport _ => 'cyclic_import',
  ImportFileNotFound _ => 'import_file_not_found',
  StructAnnotationNotFound _ => 'struct_annotation_not_found',
  TerminationByParamNotFound _ => 'termination_by_param_not_found',
  TacticFailed _ => 'tactic_failed',
  TacticIncomplete _ => 'tactic_incomplete',
  NoInstanceFound _ => 'no_instance_found',
  OverlappingInstances _ => 'overlapping_instances',
};

/// Pretty-print a [Value] by quoting at [level] and rendering.
String _prettyValueAt(Value v, int level) =>
    prettyTerm(quote(level, v), outerDepth: level);
