/// Pure parse, elaborate, and check pipeline for tooling clients.
library;

import 'package:doxa/doxa.dart';
import 'package:rumil/rumil.dart';

import 'output.dart';

/// Check [src] from a newly resolved import baseline.
CheckOutput checkSourceOutput(
  String src, {
  String filename = 'playground.doxa',
}) => _run(src: src, filename: filename);

/// Check [src] using a caller-provided resolved import baseline.
CheckOutput checkSourceWithCache(
  String src, {
  required String filename,
  required CachedImports cache,
}) => _run(src: src, filename: filename, cachedImports: cache);

/// Resolved imports reusable by fresh checks.
final class CachedImports {
  /// Bindings supplied by the prelude and imported modules.
  final List<TopBinding> bindings;

  /// Data declarations supplied by the prelude and imported modules.
  final List<DataDecl> dataDecls;

  /// Imported namespace entries.
  final Map<String, Set<String>> namespaceBindings;

  /// Imported typeclass entries.
  final Map<String, ClassInfo> classRegistry;

  /// Number of prelude bindings and data declarations.
  final int preludeDeclCount;

  /// Import source locations and resolution state.
  final ImportState importState;

  /// Creates a resolved import baseline.
  const CachedImports({
    required this.bindings,
    required this.dataDecls,
    required this.namespaceBindings,
    required this.classRegistry,
    required this.preludeDeclCount,
    required this.importState,
  });
}

/// Incremental state for one editable document.
///
/// Records retain finalized output only. A new [TopEnv] is reconstructed from
/// the import baseline and declaration deltas for every update.
final class IncrementalCheckSession {
  /// Filename used for source spans and relative imports.
  final String filename;
  CachedImports? _imports;
  List<_SessionDecl> _records = const [];
  List<String>? _rootImportDeclarationSlices;

  /// First declaration elaborated by the latest update, or `-1` on parse failure.
  int lastRecheckStart = -1;

  /// Leading declaration records reused by the latest update.
  int lastReusedDeclarationCount = 0;

  /// Declarations elaborated by the latest update.
  int lastRecheckedDeclarationCount = 0;

  /// Full-reset reason for the latest update, when there was one.
  String? lastFallbackReason;

  /// Time spent parsing the latest source revision.
  int lastParseMilliseconds = 0;

  /// Time spent reconstructing and checking the latest declaration suffix.
  int lastCheckMilliseconds = 0;

  /// Creates a session for [filename].
  IncrementalCheckSession({required this.filename});

  /// Whether the current import baseline reads [path].
  bool importsPath(String path) =>
      _imports?.importState.sourceFiles.containsKey(path) ?? false;

  /// Discard the resolved import baseline and all declaration records.
  ///
  /// Call this when an imported file changes outside the document's own LSP
  /// text stream. The next [update] resolves imports before checking again.
  void invalidateImports() {
    _imports = null;
    _records = const [];
    _rootImportDeclarationSlices = null;
  }

  /// Check [source] using the longest unchanged declaration prefix.
  CheckOutput update(
    String source, {
    Map<String, String> sourceOverrides = const {},
  }) {
    final file = SourceFile(filename: filename, text: source);
    final parseWatch = Stopwatch()..start();
    final parsed = _parse(file);
    lastParseMilliseconds = parseWatch.elapsedMilliseconds;
    if (parsed.program == null) {
      lastRecheckStart = -1;
      lastReusedDeclarationCount = 0;
      lastRecheckedDeclarationCount = 0;
      lastFallbackReason = 'parse_failure';
      return parsed.failure!;
    }
    final program = parsed.program!;
    final importSlices = _rootImportSlices(program, source);
    final importsChanged =
        _rootImportDeclarationSlices != null &&
        !_sameStrings(_rootImportDeclarationSlices!, importSlices);
    if (_imports == null || importsChanged) {
      _records = const [];
      _imports = null;
      lastFallbackReason =
          importsChanged ? 'root_imports_changed' : 'initial_check';
      final resolved = _resolveImports(
        file,
        program,
        sourceOverrides: sourceOverrides,
      );
      if (resolved.failure != null) {
        lastRecheckStart = 0;
        lastReusedDeclarationCount = 0;
        lastRecheckedDeclarationCount = 0;
        return resolved.failure!;
      }
      _imports = resolved.cache!;
    } else {
      lastFallbackReason = null;
    }
    _rootImportDeclarationSlices = importSlices;

    var reused = 0;
    while (reused < _records.length && reused < program.decls.length) {
      final old = _records[reused];
      final decl = program.decls[reused];
      if (old.span != decl.span || old.sourceSlice != _slice(source, decl)) {
        break;
      }
      reused++;
    }
    lastRecheckStart = reused;
    lastReusedDeclarationCount = reused;
    lastRecheckedDeclarationCount = program.decls.length - reused;
    final checkWatch = Stopwatch()..start();
    final result = _checkDeclarations(
      file: file,
      program: program,
      imports: _imports!,
      prefix: _records.take(reused).toList(),
      start: reused,
    );
    lastCheckMilliseconds = checkWatch.elapsedMilliseconds;
    _records = result.records;
    return result.output;
  }
}

final class _SessionDecl {
  final String sourceSlice;
  final DoxaSpan span;
  final List<TopBinding> bindings;
  final List<DataDecl> dataDecls;
  final Map<String, ClassInfo> classRegistry;
  final Map<String, Set<String>> namespaceBindings;
  final List<DeclInfo> declarations;
  final List<SemInfo> semInfo;
  final List<CheckError> errors;
  final List<ProofStateBlock> proofState;

  const _SessionDecl({
    required this.sourceSlice,
    required this.span,
    this.bindings = const [],
    this.dataDecls = const [],
    this.classRegistry = const {},
    this.namespaceBindings = const {},
    this.declarations = const [],
    this.semInfo = const [],
    this.errors = const [],
    this.proofState = const [],
  });

  _SessionDecl withDeclarations(List<DeclInfo> next) => _SessionDecl(
    sourceSlice: sourceSlice,
    span: span,
    bindings: bindings,
    dataDecls: dataDecls,
    classRegistry: classRegistry,
    namespaceBindings: namespaceBindings,
    declarations: next,
    semInfo: semInfo,
    errors: errors,
    proofState: proofState,
  );
}

final class _State {
  List<TopBinding> bindings;
  List<DataDecl> dataDecls;
  Map<String, Set<String>> namespaces;
  Map<String, ClassInfo> classes;
  final ImportState importState;

  _State(CachedImports imports)
    : bindings = imports.bindings.toList(),
      dataDecls = imports.dataDecls.toList(),
      namespaces = _copyNamespaces(imports.namespaceBindings),
      classes = Map<String, ClassInfo>.from(imports.classRegistry),
      importState = _copyImportState(imports.importState);

  void apply(_SessionDecl record) {
    bindings = [...bindings, ...record.bindings];
    dataDecls = [...dataDecls, ...record.dataDecls];
    classes = {...classes, ...record.classRegistry};
    namespaces = mergeNamespace(namespaces, record.namespaceBindings);
  }
}

CheckOutput _run({
  required String src,
  required String filename,
  CachedImports? cachedImports,
}) {
  final file = SourceFile(filename: filename, text: src);
  final parsed = _parse(file);
  if (parsed.program == null) return parsed.failure!;
  final resolved =
      cachedImports == null ? _resolveImports(file, parsed.program!) : null;
  if (resolved?.failure != null) return resolved!.failure!;
  return _checkDeclarations(
    file: file,
    program: parsed.program!,
    imports: cachedImports ?? resolved!.cache!,
  ).output;
}

({SProgram? program, CheckFailure? failure}) _parse(SourceFile file) {
  final result = parseProgram(file.text);
  return switch (result) {
    Success<ParseError, SProgram>(:final value) ||
    Partial<ParseError, SProgram>(
      :final value,
    ) => (program: value, failure: null),
    Failure<ParseError, SProgram>(:final furthest) => (
      program: null,
      failure: CheckFailure(
        errors: [
          CheckError(
            kind: 'parse_error',
            line: furthest.line,
            column: furthest.column,
            message: _parseFailureMessage(
              result as Failure<ParseError, Object?>,
            ),
            span: DoxaSpan(furthest.offset, furthest.offset),
          ),
        ],
      ),
    ),
  };
}

String _parseFailureMessage(Failure<ParseError, Object?> failure) {
  for (final error in failure.errors) {
    if (error is CustomError) return error.message;
  }
  return 'invalid syntax';
}

({CachedImports? cache, CheckFailure? failure}) _resolveImports(
  SourceFile file,
  SProgram program, {
  Map<String, String> sourceOverrides = const {},
}) {
  final prelude =
      isStdlibPreludePath(file.filename)
          ? const PreludeData([], [], {})
          : loadPrelude();
  final importState = ImportState()..currentImportPath = file.filename;
  final resolver = ImportResolver(
    importState,
    prelude: prelude,
    sourceOverrides: sourceOverrides,
  );
  try {
    resolver.processTransitiveImports(program);
  } on ElabError catch (e) {
    final reportSource = importState.sourceFileFor(e.span) ?? file;
    return (
      cache: null,
      failure: CheckFailure(errors: [_elabCheckError(file, reportSource, e)]),
    );
  } on DoxaCheckError catch (e) {
    return (
      cache: null,
      failure: CheckFailure(
        errors: [
          CheckError(
            kind: 'check_error',
            line: 0,
            column: 0,
            message: e.toString(),
          ),
        ],
      ),
    );
  }
  return (
    cache: CachedImports(
      bindings: resolver.bindings,
      dataDecls: resolver.dataDecls,
      namespaceBindings: resolver.namespaceBindings,
      classRegistry: resolver.classRegistry,
      preludeDeclCount: prelude.bindings.length + prelude.dataDecls.length,
      importState: importState,
    ),
    failure: null,
  );
}

({CheckOutput output, List<_SessionDecl> records}) _checkDeclarations({
  required SourceFile file,
  required SProgram program,
  required CachedImports imports,
  List<_SessionDecl> prefix = const [],
  int start = 0,
}) {
  final state = _State(imports);
  final records = <_SessionDecl>[];
  for (final record in prefix) {
    state.apply(record);
    records.add(record);
  }
  for (var i = start; i < program.decls.length; i++) {
    final record = _processDeclaration(file, program.decls[i], state);
    state.apply(record);
    records.add(record);
  }
  final errors = [for (final record in records) ...record.errors];
  final proofState = [for (final record in records) ...record.proofState]
    ..sort((a, b) => a.span.start.compareTo(b.span.start));
  if (errors.isNotEmpty) {
    return (
      output: CheckFailure(errors: errors, proofState: proofState),
      records: records,
    );
  }

  final completedRecords = [
    for (var i = 0; i < records.length; i++)
      if (i < start && _hasCompletedNormalForms(records[i]))
        records[i]
      else
        records[i].withDeclarations(
          _withNormalForms(
            records[i].declarations,
            state.bindings,
            state.dataDecls,
          ),
        ),
  ];
  final declarations = [
    for (final record in completedRecords) ...record.declarations,
  ];
  final semInfo = [for (final record in records) ...record.semInfo]
    ..sort((a, b) => a.span.start.compareTo(b.span.start));
  return (
    output: CheckSuccess(
      declarations: declarations,
      count:
          state.bindings.length +
          state.dataDecls.length -
          imports.preludeDeclCount,
      semInfo: semInfo,
      proofState: proofState,
      imports: imports,
    ),
    records: completedRecords,
  );
}

bool _hasCompletedNormalForms(_SessionDecl record) => record.declarations.every(
  (declaration) =>
      (declaration.kind != 'val' && declaration.kind != 'fun') ||
      declaration.normalForm != null,
);

_SessionDecl _processDeclaration(SourceFile file, SDecl decl, _State state) {
  final slice = _slice(file.text, decl);
  if (decl.kind case SImportKind(:final alias, :final path)) {
    if (alias == null) {
      return _SessionDecl(sourceSlice: slice, span: decl.span);
    }
    state.importState.push(file.filename);
    try {
      state.importState.resolvePath(path);
    } finally {
      state.importState.pop();
    }
    final names = state.namespaces[_importPrefix(path)];
    return _SessionDecl(
      sourceSlice: slice,
      span: decl.span,
      namespaceBindings: names == null ? const {} : {alias: names},
    );
  }
  final kind = switch (decl.kind) {
    SValKind _ => 'val',
    STypeAliasKind _ => 'type',
    SFunKind _ || SFunBlockKind _ => 'fun',
    SDataKind _ || SDataBlockKind _ => 'data',
    SImportKind _ => '',
    STypeclassKind _ => 'typeclass',
    SImplKind _ => 'impl',
  };
  // Collect proof-state snapshots for the declaration's `by` blocks.
  // The sink is owned by this call so the snapshots survive a failed
  // elaboration (TacticFailed records its open goals first).
  final proofState = <ProofStateBlock>[];
  try {
    final sourceNames = declNames(decl);
    final produced = elabDecl(
      TopEnv(
        state.bindings,
        state.dataDecls,
        state.classes,
        state.namespaces,
        state.importState,
      ),
      decl,
      proofStateSink: proofState,
    );
    final data = produced.dataDecls;
    final bindings = checkDeclResult(
      TopEnv(
        state.bindings,
        [...state.dataDecls, ...data],
        {...state.classes, ...produced.classRegistry},
        state.namespaces,
        state.importState,
      ),
      produced,
    );
    return _SessionDecl(
      sourceSlice: slice,
      span: decl.span,
      bindings: bindings,
      dataDecls: data,
      classRegistry: produced.classRegistry,
      namespaceBindings: produced.namespaceBindings,
      semInfo: produced.metas?.semInfos ?? const [],
      proofState: _sortedProofState(proofState),
      declarations: [
        for (final d in data)
          if (sourceNames.contains(d.name))
            DeclInfo(
              name: d.name,
              kind: kind,
              type: prettyTerm(d.sort, outerDepth: 0),
              span: d.span,
            ),
        for (final d in data)
          for (final c in d.ctors)
            if (sourceNames.contains(c.name))
              DeclInfo(
                name: c.name,
                kind: 'ctor',
                type: prettyTerm(ctorSignatureTerm(d, c), outerDepth: 0),
                span: c.span,
              ),
        for (final b in bindings)
          if (sourceNames.contains(b.name))
            DeclInfo(
              name: b.name,
              kind: kind,
              type: prettyTerm(b.type, outerDepth: 0),
              span: b.span,
            ),
      ],
    );
  } on DoxaCheckError catch (e) {
    final span = switch (e) {
      TypeMismatch(:final span?) => span,
      ScrutineeTypeMismatchesArm(:final armSpan?) => armSpan,
      _ => decl.span,
    };
    final reportSource = state.importState.sourceFileFor(span) ?? file;
    final pos = reportSource.positionAt(span.start);
    final values = switch (e) {
      TypeMismatch(:final got, :final expected, level: final level) => (
        _prettyValueAt(expected, level),
        _prettyValueAt(got, level),
      ),
      _ => (null, null),
    };
    return _SessionDecl(
      sourceSlice: slice,
      span: decl.span,
      errors: [
        CheckError(
          kind: _checkErrorKind(e),
          line: pos.line,
          column: pos.column,
          expected: values.$1,
          actual: values.$2,
          message: reportCheckError(reportSource, e, span),
          span: span.isSynthetic ? null : span,
        ),
      ],
      proofState: _sortedProofState(proofState),
    );
  } on ElabError catch (e) {
    final reportSource = state.importState.sourceFileFor(e.span) ?? file;
    return _SessionDecl(
      sourceSlice: slice,
      span: decl.span,
      errors: [_elabCheckError(reportSource, reportSource, e)],
      proofState: _sortedProofState(proofState),
    );
  }
}

/// Sort proof-state snapshots into document order for stable output.
List<ProofStateBlock> _sortedProofState(List<ProofStateBlock> blocks) {
  if (blocks.length < 2) return List.unmodifiable(blocks);
  final sorted = [...blocks]
    ..sort((a, b) => a.span.start.compareTo(b.span.start));
  return List.unmodifiable(sorted);
}

CheckError _elabCheckError(
  SourceFile positionSource,
  SourceFile reportSource,
  ElabError e,
) {
  final pos = positionSource.positionAt(e.span.start);
  return CheckError(
    kind: _elabErrorKind(e),
    line: pos.line,
    column: pos.column,
    message: reportElabError(reportSource, e),
    span: e.span.isSynthetic ? null : e.span,
  );
}

List<DeclInfo> _withNormalForms(
  List<DeclInfo> declarations,
  List<TopBinding> bindings,
  List<DataDecl> dataDecls,
) {
  final env = _buildFullEnv(bindings, dataDecls);
  final byName = {for (final binding in bindings) binding.name: binding};
  return [
    for (final declaration in declarations)
      if ((declaration.kind == 'val' || declaration.kind == 'fun') &&
          byName.containsKey(declaration.name))
        DeclInfo(
          name: declaration.name,
          kind: declaration.kind,
          type: declaration.type,
          normalForm: _truncate(
            prettyTerm(
              quote(0, eval(byName[declaration.name]!.term, env)),
              outerDepth: 0,
            ),
            500,
          ),
          span: declaration.span,
        )
      else
        declaration,
  ];
}

String _slice(String source, SDecl declaration) =>
    source.substring(declaration.span.start, declaration.span.end);

List<String> _rootImportSlices(SProgram program, String source) => [
  for (final declaration in program.decls)
    if (declaration.kind is SImportKind) _slice(source, declaration),
];

String _importPrefix(String path) {
  final filename = path.split('/').last;
  final stem =
      filename.endsWith('.doxa')
          ? filename.substring(0, filename.length - '.doxa'.length)
          : filename;
  return stem.isEmpty ? stem : stem[0].toUpperCase() + stem.substring(1);
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, Set<String>> _copyNamespaces(Map<String, Set<String>> source) => {
  for (final entry in source.entries) entry.key: Set<String>.from(entry.value),
};

ImportState _copyImportState(ImportState source) {
  final copy = ImportState()..currentImportPath = source.currentImportPath;
  copy.importedPaths.addAll(source.importedPaths);
  copy.sourceFiles.addAll(source.sourceFiles);
  copy.definitionFiles.addAll(source.definitionFiles);
  copy.definitionSpans.addAll(source.definitionSpans);
  return copy;
}

Env _buildFullEnv(List<TopBinding> bindings, List<DataDecl> dataDecls) {
  var entries = <String, TopBindingEntry>{};
  for (final binding in bindings) {
    final stubs = {
      ...entries,
      binding.name: TopBindingEntry(
        const VNeutral(NVar(0)),
        VNeutral(NTop(binding.name)),
        isOpaque: binding.isOpaque,
        recDecreasingArg: binding.recDecreasingArg,
        recArity: binding.recArity,
      ),
    };
    final env = ENil.withRegistries(dataDecls: dataDecls, topBindings: stubs);
    entries = {
      ...entries,
      binding.name: TopBindingEntry(
        eval(binding.type, env),
        eval(binding.term, env),
        isOpaque: binding.isOpaque,
        recDecreasingArg: binding.recDecreasingArg,
        recArity: binding.recArity,
      ),
    };
  }
  assert(() {
    for (final entry in entries.entries) {
      final value = entry.value.value;
      if (value is VNeutral && value.neutral is NTop) {
        throw StateError('_buildFullEnv: stub left behind for "${entry.key}"');
      }
    }
    return true;
  }());
  return ENil.withRegistries(dataDecls: dataDecls, topBindings: entries);
}

/// Check [src] and return a human-readable result.
String checkSourceString(String src, {String filename = 'playground.doxa'}) {
  final output = checkSourceOutput(src, filename: filename);
  return switch (output) {
    CheckSuccess(:final count) =>
      'OK: $count ${count == 1 ? "declaration" : "declarations"} checked',
    CheckFailure(:final message) => message,
  };
}

/// Check [src] and return a JSON result.
String checkSourceJson(String src, {String filename = 'playground.doxa'}) =>
    checkSourceOutput(src, filename: filename).toJsonString();

String _truncate(String value, int maxLength) =>
    value.length <= maxLength ? value : '${value.substring(0, maxLength)}...';

String _checkErrorKind(DoxaCheckError error) => switch (error) {
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

String _elabErrorKind(ElabError error) => switch (error) {
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

String _prettyValueAt(Value value, int level) =>
    prettyTerm(quote(level, value), outerDepth: level);
