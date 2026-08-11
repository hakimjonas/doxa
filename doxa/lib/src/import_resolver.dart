/// Pre-resolving import resolver: transitively parses all imported
/// files, topologically sorts them, and processes each file's
/// declarations exactly once (elaborate + check in dependency order).
///
/// Replaces the recursive `_processImport` path for batch-mode
/// pipelines (`checkSource`, `checkSourceOutput`).  The REPL still
/// uses `_processImport` directly because it processes declarations
/// one at a time and cannot pre-resolve.
library;

import 'dart:io';

import 'package:rumil/rumil.dart' show ParseError, Success, Partial, Failure;

import 'check.dart' show DoxaCheckError;
import 'elab.dart'
    show
        ImportState,
        TopEnv,
        TopBinding,
        DataDecl,
        ClassInfo,
        ElabError,
        CyclicImport,
        ImportFileNotFound,
        elabDecl,
        checkDeclResult,
        mergeNamespace;
import 'parse.dart' show parseProgram;
import 'prelude.dart' show PreludeData;
import 'source.dart' show SourceFile;
import 'surface.dart' show SProgram, SImportKind, DoxaSpan;

/// Derive module prefix from file path: "nat.doxa" → "Nat",
/// "foo/bar.doxa" → "Bar".  Duplicated from `elab.dart`'s private
/// `_modulePrefix`.
String _modulePrefix(String path) {
  final filename = path.split('/').last.split('\\').last;
  final stem =
      filename.endsWith('.doxa')
          ? filename.substring(0, filename.length - '.doxa'.length)
          : filename;
  if (stem.isEmpty) return stem;
  return stem[0].toUpperCase() + stem.substring(1);
}

/// Parsed and dependency info for a single file.
final class _FileInfo {
  final SProgram program;
  final List<String> imports;
  const _FileInfo(this.program, this.imports);
}

/// Pre-resolving import resolver for batch-mode pipelines.
///
/// Usage:
/// ```dart
/// final resolver = ImportResolver(importState, prelude: prelude);
/// resolver.processTransitiveImports(rootProgram);
/// // resolver.bindings, resolver.dataDecls, etc. are now populated.
/// ```
final class ImportResolver {
  final ImportState importState;
  final PreludeData prelude;

  final Map<String, _FileInfo> _files = {};
  final Map<String, List<String>> _deps = {};
  final List<String> _topo = [];
  String _rootPath = '';

  List<TopBinding> _bindings;
  List<DataDecl> _dataDecls;
  Map<String, Set<String>> _namespaceBindings;
  Map<String, ClassInfo> _classRegistry;

  ImportResolver(this.importState, {required this.prelude})
    : _bindings = prelude.bindings.toList(),
      _dataDecls = prelude.dataDecls.toList(),
      _namespaceBindings = Map<String, Set<String>>.from(
        prelude.namespaceBindings,
      ),
      _classRegistry = <String, ClassInfo>{};

  List<TopBinding> get bindings => _bindings;
  List<DataDecl> get dataDecls => _dataDecls;
  Map<String, Set<String>> get namespaceBindings => _namespaceBindings;
  Map<String, ClassInfo> get classRegistry => _classRegistry;

  // ----------------------------------------------------------------
  // Public entry point
  // ----------------------------------------------------------------

  /// Process all transitive imports of [rootProgram].
  ///
  /// The root file's non-import declarations are NOT processed here —
  /// the caller must handle them afterward.  Only imported files are
  /// elaborated and checked.
  void processTransitiveImports(SProgram rootProgram) {
    _discover(rootProgram);
    _buildDeps();
    _toposort();
    _processAll();
  }

  // ----------------------------------------------------------------
  // Discovery
  // ----------------------------------------------------------------

  void _discover(SProgram rootProg) {
    final rootPath = importState.currentImportPath;
    if (rootPath == null) {
      throw StateError(
        'ImportResolver: currentImportPath must be set before discovery',
      );
    }
    _rootPath = _absPath(rootPath);
    _files[_rootPath] = _FileInfo(rootProg, _importPathsOf(rootProg));

    final queue = <String>[];
    for (final imp in _importPathsOf(rootProg)) {
      final r = _resolve(imp, _rootPath);
      if (r != null) queue.add(r);
    }

    while (queue.isNotEmpty) {
      final path = queue.removeAt(0);
      if (_files.containsKey(path)) continue;
      if (importState.importStack.contains(path)) {
        throw CyclicImport(path, const DoxaSpan(-1, -1));
      }

      if (!File(path).existsSync()) {
        throw ImportFileNotFound(path, const DoxaSpan(-1, -1));
      }

      final source = File(path).readAsStringSync();
      importState.sourceFiles[path] = SourceFile(filename: path, text: source);

      final r = parseProgram(source);
      final prog = switch (r) {
        Success<ParseError, SProgram>(:final value) => value,
        Partial<ParseError, SProgram>(:final value) => value,
        Failure<ParseError, SProgram>() =>
          throw StateError('Failed to parse import: $path'),
      };

      final imports = _importPathsOf(prog);
      _files[path] = _FileInfo(prog, imports);

      // Enqueue transitive deps, using push/pop for relative resolution.
      importState.push(path);
      try {
        for (final imp in imports) {
          final r = _resolve(imp, path);
          if (r != null && !_files.containsKey(r)) queue.add(r);
        }
      } finally {
        importState.pop();
      }
    }
  }

  List<String> _importPathsOf(SProgram prog) {
    return [
      for (final decl in prog.decls)
        if (decl.kind case SImportKind(:final path)) path,
    ];
  }

  String? _resolve(String importPath, String currentFile) {
    final current = Uri.file(currentFile);
    return current.resolve(importPath).toFilePath();
  }

  String _absPath(String path) => Uri.file(path).toFilePath();

  // ----------------------------------------------------------------
  // Dependency graph
  // ----------------------------------------------------------------

  void _buildDeps() {
    for (final entry in _files.entries) {
      final a = entry.key;
      final seen = <String>{};
      final deps = <String>[];
      for (final rawDep in entry.value.imports) {
        final b = _resolve(rawDep, a);
        if (b != null && _files.containsKey(b) && seen.add(b)) {
          deps.add(b);
        }
      }
      _deps[a] = deps;
    }
  }

  // ----------------------------------------------------------------
  // Topological sort (Kahn's algorithm)
  // ----------------------------------------------------------------

  void _toposort() {
    // Edge: A imports B → edge B → A (B must come before A).
    // in-degree of A = how many files A imports (A waits for them).
    final inDeg = <String, int>{};
    for (final path in _files.keys) {
      inDeg[path] = _deps[path]!.length;
    }

    final queue = <String>[];
    for (final entry in inDeg.entries) {
      if (entry.value == 0) queue.add(entry.key);
    }

    _topo.clear();
    while (queue.isNotEmpty) {
      final path = queue.removeAt(0);
      _topo.add(path);

      // Find all files that import [path] and decrement their in-degree.
      for (final entry in _deps.entries) {
        final other = entry.key;
        if (entry.value.contains(path)) {
          inDeg[other] = (inDeg[other] ?? 1) - 1;
          if (inDeg[other] == 0) queue.add(other);
        }
      }
    }

    if (_topo.length != _files.length) {
      throw const CyclicImport('(import cycle)', DoxaSpan(-1, -1));
    }
  }

  // ----------------------------------------------------------------
  // Processing
  // ----------------------------------------------------------------

  void _processAll() {
    for (final path in _topo) {
      importState.currentImportPath = path;
      if (path == _rootPath) continue; // skip root — caller handles it
      _processFile(path);
    }
  }

  void _processFile(String path) {
    final info = _files[path]!;
    importState.importedPaths.add(path);
    importState.push(path);
    try {
      for (final decl in info.program.decls) {
        if (decl.kind is SImportKind) continue;

        final env = TopEnv(
          _bindings,
          _dataDecls,
          _classRegistry,
          _namespaceBindings,
          importState,
        );

        try {
          final produced = elabDecl(env, decl);
          final runningData = [..._dataDecls, ...produced.dataDecls];
          final finalized = checkDeclResult(
            TopEnv(
              _bindings,
              runningData,
              {..._classRegistry, ...produced.classRegistry},
              _namespaceBindings,
              importState,
            ),
            produced,
          );
          _bindings = [..._bindings, ...finalized];
          _dataDecls = runningData;
          _classRegistry = {..._classRegistry, ...produced.classRegistry};
          _namespaceBindings = mergeNamespace(
            _namespaceBindings,
            produced.namespaceBindings,
          );
        } on DoxaCheckError {
          rethrow;
        } on ElabError {
          rethrow;
        }
      }

      // Build namespace entry for this file.  Include ALL currently
      // accumulated bindings and data decls, not just the ones added
      // by this file.  Matches _processImport's behaviour where
      // `localBindings` contains transitively-imported names.
      final modPrefix = _modulePrefix(path);
      if (modPrefix.isNotEmpty) {
        final newNames = <String>{
          for (final b in _bindings) b.name,
          for (final d in _dataDecls) d.name,
          for (final d in _dataDecls)
            for (final c in d.ctors) c.name,
        };
        _namespaceBindings = mergeNamespace(_namespaceBindings, {
          modPrefix: newNames,
        });
      }
    } finally {
      importState.pop();
    }
  }
}
