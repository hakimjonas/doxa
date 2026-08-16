/// LSP message dispatch and document management for Doxa.
///
/// Maintains open document text and incremental checker sessions, then serves
/// hover, definition, and completion from the latest semantic metadata.
library;

import '../output.dart';
import 'dart:io' show File, Platform, stderr;
import 'package:doxa/doxa.dart';
import 'package:rumil/rumil.dart'
    show Failure, IncrementalStrategy, ParseError, Partial, Success, TextEdit;
import '../web_check.dart';
import '../parse_tree.dart' show parseProgramTree;
import '../syntax.dart' show DoxaGreen;
import '../cst.dart' show reparse;
import '../format.dart' show formatSource;
import '../tokenize.dart' show tokenizeDoxaSpans;
import 'package:rumil_tokens/rumil_tokens.dart'
    show Comment, Identifier, Keyword, NumberLit, Operator, Punctuation, Token;
import 'protocol.dart';
import 'transport.dart';

final class _DocumentState {
  _DocumentState({
    required this.uri,
    required this.text,
    required this.version,
  });

  final String uri;
  String text;
  int version;
  CheckSuccess? lastSuccess;
  Map<String, int> frequency = <String, int>{};
  CachedImports? cachedImports;
  IncrementalCheckSession? checkSession;
  final Set<String> importedPaths = <String>{};
  DoxaGreen? syntaxTree;
  IncrementalStrategy? lastReparseStrategy;
}

final class _IndexedDocument {
  const _IndexedDocument({
    required this.uri,
    required this.text,
    required this.success,
  });

  final String uri;
  final String text;
  final CheckSuccess success;
}

final class _SymbolTarget {
  const _SymbolTarget({
    required this.definitionUri,
    required this.kind,
    required this.definitionSpan,
    required this.name,
  });

  final String definitionUri;
  final SemInfoKind kind;
  final DoxaSpan definitionSpan;
  final String name;
}

/// LSP handler: owns open-document state and dispatches incoming methods.
final class LspHandler {
  final Map<String, _DocumentState> _documents = {};
  final Map<String, IncrementalCheckSession> _importSessions = {};
  Map<String, _IndexedDocument> _importSnapshots = {};
  _DocumentState? _activeDocument;

  String get _documentUri => _activeDocument?.uri ?? '';
  String get _documentText => _activeDocument?.text ?? '';
  set _documentText(String value) => _activeDocument?.text = value;
  CheckSuccess? get _lastSuccess => _activeDocument?.lastSuccess;
  set _lastSuccess(CheckSuccess? value) => _activeDocument?.lastSuccess = value;
  Map<String, int> get _freq => _activeDocument?.frequency ?? const {};
  set _freq(Map<String, int> value) => _activeDocument?.frequency = value;
  CachedImports? get _cachedImports => _activeDocument?.cachedImports;
  set _cachedImports(CachedImports? value) =>
      _activeDocument?.cachedImports = value;
  IncrementalCheckSession? get _checkSession => _activeDocument?.checkSession;
  set _checkSession(IncrementalCheckSession? value) =>
      _activeDocument?.checkSession = value;

  /// Request IDs that have been cancelled via $/cancelRequest.
  final Set<int> _cancelledIds = {};

  /// Enables persistent-LSP timing output on stderr for local diagnosis.
  static final _traceTiming =
      Platform.environment['DOXA_LSP_TRACE_TIMING'] == '1';

  /// Checks if [id] has been cancelled.  If so, returns a cancellation
  /// error response and clears the cancelled flag.
  Map<String, dynamic>? _checkCancelled(Object? id) {
    if (id is! int || !_cancelledIds.remove(id)) return null;
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32800, 'message': 'Request cancelled'},
    };
  }

  /// Creates an LSP handler with no open document.
  LspHandler();

  /// The Rumil strategy used for the most recent edit to [uri].
  ///
  /// Exposed for protocol tests and performance telemetry.
  String? lastReparseStrategyFor(String uri) =>
      _documents[uri]?.lastReparseStrategy?.name;

  /// Semantic invalidation metrics for the latest update to [uri].
  ({int start, int reused, int rechecked, String? fallback})?
  lastCheckMetricsFor(String uri) {
    final session = _documents[uri]?.checkSession;
    if (session == null) return null;
    return (
      start: session.lastRecheckStart,
      reused: session.lastReusedDeclarationCount,
      rechecked: session.lastRecheckedDeclarationCount,
      fallback: session.lastFallbackReason,
    );
  }

  /// Process a single incoming LSP message.
  ///
  /// Returns a response to send back, or null for notifications that
  /// produce no response.
  Map<String, dynamic>? handle(Map<String, dynamic> message) {
    final method = message['method'] as String?;
    final id = message['id'];
    final params = message['params'] as Map<String, dynamic>?;

    // Common cancellation check for all request handlers.
    if (id != null) {
      final cancelled = _checkCancelled(id);
      if (cancelled != null) return cancelled;
    }

    if (method?.startsWith('textDocument/') == true &&
        method != 'textDocument/didOpen' &&
        method != 'textDocument/didClose') {
      final uri = _uriFromParams(params);
      final document = uri == null ? null : _documents[uri];
      if (document == null) {
        if (id == null) return null;
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32602, 'message': 'Document is not open: $uri'},
        };
      }
      _activeDocument = document;
    }

    switch (method) {
      case 'initialize':
        return _handleInitialize(id);

      case 'textDocument/didOpen':
        _handleDidOpen(params!);
        return null;

      case 'textDocument/didChange':
        _handleDidChange(params!);
        return null;

      case 'textDocument/didClose':
        _handleDidClose(params!);
        return null;

      case 'textDocument/hover':
        return _handleHover(id, params!);

      case 'textDocument/definition':
        return _handleDefinition(id, params!);

      case 'textDocument/completion':
        return _handleCompletion(id, params!);

      case 'textDocument/semanticTokens/full':
        return _handleSemanticTokens(id, params!);

      case 'textDocument/references':
        return _handleReferences(id, params!);

      case 'textDocument/rename':
        return _handleRename(id, params!);

      case 'textDocument/prepareRename':
        return _handlePrepareRename(id, params!);

      case 'textDocument/documentSymbol':
        return _handleDocumentSymbol(id, params!);

      case 'textDocument/signatureHelp':
        return _handleSignatureHelp(id, params!);

      case 'textDocument/codeLens':
        return _handleCodeLens(id, params!);

      case 'textDocument/formatting':
        return _handleFormatting(id, params!);

      case 'textDocument/foldingRange':
        return _handleFoldingRange(id, params!);

      case 'textDocument/inlayHint':
        return _handleInlayHint(id, params!);

      case '\$/cancelRequest':
        final cancelId = params?['id'];
        if (cancelId is int) _cancelledIds.add(cancelId);
        return null;

      case 'workspace/didChangeConfiguration':
        return null; // Acknowledged; no configuration to consume yet.

      case 'initialized':
      case 'textDocument/didSave':
        return null;

      case 'workspace/didChangeWatchedFiles':
        _handleWatchedFiles(params);
        return null;

      case 'shutdown':
        if (id == null) return null;
        return {'jsonrpc': '2.0', 'id': id, 'result': null};

      case 'exit':
        return null;

      default:
        if (id == null) return null;
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        };
    }
  }

  /// Handle `initialize`.
  Map<String, dynamic> _handleInitialize(Object? id) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': {
      'capabilities': {
        'textDocumentSync': 1, // Full content sync
        'hoverProvider': true,
        'definitionProvider': true,
        'referencesProvider': true,
        'renameProvider': <String, dynamic>{'prepareProvider': true},
        'documentSymbolProvider': true,
        'documentFormattingProvider': true,
        'foldingRangeProvider': true,
        'signatureHelpProvider': <String, dynamic>{
          'triggerCharacters': ['(', ','],
        },
        'completionProvider': <String, dynamic>{
          'triggerCharacters': <String>[],
        },
        'semanticTokensProvider': {
          'legend': {
            'tokenTypes': [
              for (final t in LspSemanticTokenType.values) t.label,
            ],
            'tokenModifiers': [
              for (final m in LspSemanticTokenModifier.values) m.label,
            ],
          },
          'full': true,
        },
      },
      'serverInfo': {'name': 'doxa-lsp', 'version': '0.8.2'},
      'positionEncoding': 'utf-16',
    },
  };

  /// Handle `textDocument/didOpen`.
  void _handleDidOpen(Map<String, dynamic> params) {
    final textDocument = params['textDocument'] as Map<String, dynamic>;
    final uri = textDocument['uri'] as String;
    _activeDocument = _DocumentState(
      uri: uri,
      text: textDocument['text'] as String,
      version: textDocument['version'] as int? ?? 0,
    );
    _documents[uri] = _activeDocument!;
    if (uri.startsWith('file:')) {
      _invalidateImportSnapshotsFor(Uri.parse(uri).toFilePath());
    }
    _activeDocument!.syntaxTree = _syntaxTreeFor(_documentText);
    _freq = <String, int>{};
    _cachedImports = null;
    _checkAndPublish();
    _recheckDependents(uri);
  }

  /// Handle `textDocument/didChange`.
  void _handleDidChange(Map<String, dynamic> params) {
    final textDocument = params['textDocument'] as Map<String, dynamic>;
    final uri = textDocument['uri'] as String;
    final document = _documents[uri];
    if (document == null) return;
    _activeDocument = document;
    final version = textDocument['version'] as int?;
    if (version != null && version <= document.version) return;
    final contentChanges = params['contentChanges'] as List<dynamic>;
    if (contentChanges.isNotEmpty) {
      final change = contentChanges.last as Map<String, dynamic>;
      final newText = change['text'] as String;
      _updateSyntaxTree(document, newText);
      _documentText = newText;
      if (uri.startsWith('file:')) {
        _invalidateImportSnapshotsFor(Uri.parse(uri).toFilePath());
      }
    }
    if (version != null) document.version = version;
    _freq = <String, int>{};
    _checkAndPublish();
    _recheckDependents(uri);
  }

  /// Handle `textDocument/didClose`.
  void _handleDidClose(Map<String, dynamic> params) {
    final textDocument = params['textDocument'] as Map<String, dynamic>;
    final uri = textDocument['uri'] as String;
    final document = _documents.remove(uri);
    if (document == null) return;
    if (uri.startsWith('file:')) {
      _invalidateImportSnapshotsFor(Uri.parse(uri).toFilePath());
    }
    _activeDocument = document;
    _publishDiagnostics(const <LspDiagnostic>[]);
    if (identical(_activeDocument, document)) _activeDocument = null;
    _recheckDependents(uri);
  }

  void _handleWatchedFiles(Map<String, dynamic>? params) {
    final changedPaths = <String>{
      for (final change in (params?['changes'] as List<dynamic>? ?? const []))
        if (change case {'uri': final String uri} when uri.startsWith('file:'))
          Uri.parse(uri).toFilePath(),
    };
    for (final path in changedPaths) {
      _invalidateImportSnapshotsFor(path);
    }
    final previous = _activeDocument;
    for (final document in _documents.values) {
      final session = document.checkSession;
      if (changedPaths.isNotEmpty &&
          !changedPaths.any((path) => _importsPath(document, path))) {
        continue;
      }
      _activeDocument = document;
      // An import baseline retains parsed external files, so it cannot be
      // reused after a dependency changes on disk.
      session?.invalidateImports();
      _checkSession = null;
      _cachedImports = null;
      _checkAndPublish();
    }
    _activeDocument = previous;
  }

  void _recheckDependents(String uri) {
    if (!uri.startsWith('file:')) return;
    final path = Uri.parse(uri).toFilePath();
    final previous = _activeDocument;
    for (final document in _documents.values) {
      if (document.uri == uri || !_importsPath(document, path)) {
        continue;
      }
      _activeDocument = document;
      document.checkSession?.invalidateImports();
      _cachedImports = null;
      _checkAndPublish();
    }
    _activeDocument = previous;
  }

  bool _importsPath(_DocumentState document, String path) =>
      document.importedPaths.contains(path) ||
      document.checkSession?.importsPath(path) == true;

  String? _uriFromParams(Map<String, dynamic>? params) {
    final textDocument = params?['textDocument'] as Map<String, dynamic>?;
    return textDocument?['uri'] as String?;
  }

  void _updateSyntaxTree(_DocumentState document, String newText) {
    final previousTree = document.syntaxTree;
    if (previousTree == null) {
      document.syntaxTree = _syntaxTreeFor(newText);
      document.lastReparseStrategy = IncrementalStrategy.fullReparse;
      return;
    }
    final edit = _minimalEdit(document.text, newText);
    final result = reparse(previousTree, document.text, edit);
    document.syntaxTree = result.tree;
    document.lastReparseStrategy = result.strategy;
  }

  TextEdit _minimalEdit(String previous, String next) {
    var start = 0;
    final sharedLength =
        previous.length < next.length ? previous.length : next.length;
    while (start < sharedLength &&
        previous.codeUnitAt(start) == next.codeUnitAt(start)) {
      start++;
    }
    var previousEnd = previous.length;
    var nextEnd = next.length;
    while (previousEnd > start &&
        nextEnd > start &&
        previous.codeUnitAt(previousEnd - 1) == next.codeUnitAt(nextEnd - 1)) {
      previousEnd--;
      nextEnd--;
    }
    // Rumil's token update anchors an insertion at the token beginning at its
    // offset. Include one shared code unit on the left so an insertion at an
    // identifier's end is checked against that identifier, not its following
    // whitespace token.
    if (start == previousEnd && start > 0) {
      start--;
    }
    return TextEdit(start, previousEnd, next.substring(start, nextEnd));
  }

  DoxaGreen? _syntaxTreeFor(String source) => switch (parseProgramTree(
    source,
  )) {
    Success(:final value) || Partial(:final value) => value.tree,
    _ => null,
  };

  /// Handle `textDocument/hover`.
  Map<String, dynamic> _handleHover(Object? id, Map<String, dynamic> params) {
    final offset = _offsetFromParams(params);
    final info = _infoAt(offset);
    final declaration = info == null ? _declarationAt(offset) : null;
    final builtin =
        info == null && declaration == null ? _builtinHoverAt(offset) : null;
    if (info == null && declaration == null && builtin == null) {
      return {'jsonrpc': '2.0', 'id': id, 'result': null};
    }
    final pos = _positionAt(offset);
    final result = LspHover(
      contents: switch ((info, declaration, builtin)) {
        (final info?, _, _) => '```doxa\n${info.name} : ${info.type}\n```',
        (_, final declaration?, _) =>
          '```doxa\n${declaration.name} : ${declaration.type ?? 'Type'}\n```',
        (_, _, final builtin?) => builtin,
        _ => throw StateError('unreachable'),
      },
      range: LspRange(
        start: LspPosition(line: pos.line - 1, character: pos.column - 1),
        end: LspPosition(line: pos.line - 1, character: pos.column - 1),
      ),
    );
    return {'jsonrpc': '2.0', 'id': id, 'result': result.toJson()};
  }

  /// Handle `textDocument/definition`.
  Map<String, dynamic> _handleDefinition(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final offset = _offsetFromParams(params);
    final importedFile = _importDefinitionAt(offset);
    if (importedFile != null) {
      return {'jsonrpc': '2.0', 'id': id, 'result': importedFile.toJson()};
    }
    final result = _buildResult(id, params, (offset) {
      final info = _infoAt(offset);
      final importedDefinition =
          info == null ? _importedDefinitionAt(offset) : null;
      if (importedDefinition != null) return importedDefinition;
      final defSpan = info?.defSpan ?? _declarationAt(offset)?.span;
      if (defSpan == null) return null;
      final importState = _cachedImports?.importState;
      final defFile =
          info == null
              ? null
              : importState?.definitionFiles[_unqualifiedName(info.name)] ??
                  info.defFile;
      final defText = defFile == null ? _documentText : _sourceTextFor(defFile);
      if (defText == null) return null;
      final defOffset =
          info == null
              ? defSpan.start
              : _definitionNameOffset(defText, defSpan, info.name);
      final defPos = _positionIn(defText, defOffset);
      return LspLocation(
        uri: defFile == null ? _documentUri : Uri.file(defFile).toString(),
        range: LspRange(
          start: LspPosition(
            line: defPos.line - 1,
            character: defPos.column - 1,
          ),
          end: LspPosition(line: defPos.line - 1, character: defPos.column - 1),
        ),
      );
    });
    return {'jsonrpc': '2.0', 'id': id, 'result': result?.toJson()};
  }

  /// Handle `textDocument/completion`.
  Map<String, dynamic> _handleCompletion(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final offset = _offsetFromParams(params);
    // Extract the word prefix the user has typed up to the cursor.
    final prefix = _wordPrefixAt(offset);
    final typeByName = <String, String>{};
    final defKindByName = <String, String>{};
    if (_lastSuccess != null) {
      // Build a type map from SemInfo entries.
      for (final info in _lastSuccess!.semInfo) {
        if (info.span.start <= offset) {
          typeByName[info.name] = info.type;
        }
      }
      // Also map declaration kinds to decide symbol kind labels.
      for (final decl in _lastSuccess!.declarations) {
        if (decl.span.start <= offset) {
          if (decl.type != null) {
            typeByName.putIfAbsent(decl.name, () => decl.type!);
          }
          defKindByName.putIfAbsent(decl.name, () => decl.kind);
        }
      }
    }
    final items = <LspCompletionItem>[];
    for (final entry in typeByName.entries) {
      final name = entry.key;
      // Filter by prefix if the user has started typing.
      if (prefix.isNotEmpty && !name.startsWith(prefix)) continue;
      final type = entry.value;
      final kindLabel = defKindByName[name];
      final detail = kindLabel != null ? '$kindLabel :: $type' : type;
      items.add(
        LspCompletionItem(label: name, detail: detail, filterText: name),
      );
    }
    // Sort by frequency desc, then alphabetically.
    items.sort((a, b) {
      final fa = _freq[a.label] ?? 0;
      final fb = _freq[b.label] ?? 0;
      if (fa != fb) return fb.compareTo(fa);
      return a.label.compareTo(b.label);
    });
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': LspCompletionList(isIncomplete: false, items: items).toJson(),
    };
  }

  /// Handle `textDocument/semanticTokens/full`.
  ///
  /// Produces both syntax-level tokens (keywords, comments, numbers,
  /// operators) from the Doxa tokenizer and semantic tokens from the
  /// last type-check result.  All are delta-encoded into a single
  /// LSP semantic tokens array.
  Map<String, dynamic> _handleSemanticTokens(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final tokens =
        <({int line, int char, int length, int typeIndex, int modifierBits})>[];

    // Syntax tokens from the Doxa tokenizer (always available).
    for (final spanned in tokenizeDoxaSpans(_documentText)) {
      final type = _syntaxTokenType(spanned.token);
      if (type == null) continue;
      final pos = _positionAt(spanned.start);
      tokens.add((
        line: pos.line - 1,
        char: pos.column - 1,
        length: spanned.end - spanned.start,
        typeIndex: type.legendIndex,
        modifierBits: 0,
      ));
    }

    // Semantic tokens from the last successful type-check.
    if (_lastSuccess != null) {
      for (final info in _lastSuccess!.semInfo) {
        final span = info.span;
        if (span.isSynthetic) continue;
        final length = span.end - span.start;
        if (length <= 0) continue;
        final pos = _positionAt(span.start);
        final type = _semanticTokenType(info.kind);
        final modifier = _semanticTokenModifier(info.kind);
        tokens.add((
          line: pos.line - 1,
          char: pos.column - 1,
          length: length,
          typeIndex: type.legendIndex,
          modifierBits: modifier?.bit ?? 0,
        ));
      }

      // Declaration names are binders, so elaboration does not emit SemInfo
      // for them. Imported data declarations likewise need a source-level
      // fallback when they appear in data-only files.
      final declarationTypes = <String, LspSemanticTokenType>{
        for (final declaration in _lastSuccess!.declarations)
          declaration.name: switch (declaration.kind) {
            'data' => LspSemanticTokenType.type_,
            'fun' => LspSemanticTokenType.function,
            _ => LspSemanticTokenType.variable,
          },
      };
      final importedDataTypes = {
        for (final data in _cachedImports?.dataDecls ?? const <DataDecl>[])
          data.name,
      };
      final importedConstructors = {
        for (final data in _cachedImports?.dataDecls ?? const <DataDecl>[])
          for (final ctor in data.ctors) ctor.name,
      };
      for (final spanned in tokenizeDoxaSpans(_documentText)) {
        if (spanned.token is! Identifier || _infoAt(spanned.start) != null) {
          continue;
        }
        final type =
            declarationTypes[spanned.token.text] ??
            (importedDataTypes.contains(spanned.token.text)
                ? LspSemanticTokenType.type_
                : importedConstructors.contains(spanned.token.text)
                ? LspSemanticTokenType.enumMember
                : null);
        if (type == null) continue;
        final pos = _positionAt(spanned.start);
        tokens.add((
          line: pos.line - 1,
          char: pos.column - 1,
          length: spanned.end - spanned.start,
          typeIndex: type.legendIndex,
          modifierBits: 0,
        ));
      }
    }

    // Sort by (line, char) for correct delta encoding.
    tokens.sort((a, b) {
      final c = a.line.compareTo(b.line);
      return c != 0 ? c : a.char.compareTo(b.char);
    });

    // Delta-encode.
    final data = <int>[];
    var prevLine = 0;
    var prevChar = 0;
    for (final t in tokens) {
      if (t.line == prevLine) {
        data.add(0);
        data.add(t.char - prevChar);
      } else {
        data.add(t.line - prevLine);
        data.add(t.char);
      }
      data.add(t.length);
      data.add(t.typeIndex);
      data.add(t.modifierBits);
      prevLine = t.line;
      prevChar = t.char;
    }

    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': LspSemanticTokens(data: data).toJson(),
    };
  }

  /// Map a syntax [Token] to an [LspSemanticTokenType], or null when the
  /// token kind does not warrant highlighting (whitespace, identifiers, etc.).
  LspSemanticTokenType? _syntaxTokenType(Token token) => switch (token) {
    Keyword _ => LspSemanticTokenType.keyword,
    Comment _ => LspSemanticTokenType.comment,
    NumberLit _ => LspSemanticTokenType.number,
    Operator _ => LspSemanticTokenType.operator_,
    Punctuation _ => null,
    _ => null,
  };

  /// Map a [SemInfoKind] to a [LspSemanticTokenType].
  LspSemanticTokenType _semanticTokenType(SemInfoKind kind) => switch (kind) {
    SemInfoKind.dataType => LspSemanticTokenType.type_,
    SemInfoKind.constructor => LspSemanticTokenType.enumMember,
    SemInfoKind.topBinding => LspSemanticTokenType.variable,
    SemInfoKind.localVar => LspSemanticTokenType.variable,
    SemInfoKind.implicitParam => LspSemanticTokenType.parameter,
    SemInfoKind.fieldProj => LspSemanticTokenType.property,
  };

  /// Map a [SemInfoKind] to a [LspSemanticTokenModifier], or null.
  LspSemanticTokenModifier? _semanticTokenModifier(SemInfoKind kind) =>
      switch (kind) {
        SemInfoKind.topBinding => LspSemanticTokenModifier.readonly,
        _ => null,
      };

  /// Handle `textDocument/references`.
  Map<String, dynamic> _handleReferences(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final result = _buildResult(id, params, (offset) {
      final target = _symbolTargetAt(offset);
      if (target == null) return null;
      final context = params['context'] as Map<String, dynamic>?;
      final includeDeclaration =
          context?['includeDeclaration'] as bool? ?? true;
      return _referencesFor(target, includeDeclaration: includeDeclaration);
    });
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result':
          result == null
              ? null
              : [for (final location in result) location.toJson()],
    };
  }

  /// Handle `textDocument/rename`.
  Map<String, dynamic> _handleRename(Object? id, Map<String, dynamic> params) {
    final newName = params['newName'] as String?;
    if (newName == null || newName.isEmpty) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32602, 'message': 'newName is required'},
      };
    }
    final result = _buildResult(id, params, (offset) {
      final target = _symbolTargetAt(offset);
      if (target == null) return null;
      final refs = _referencesFor(target);
      if (refs.isEmpty) return null;
      // Build text edits grouped by the document containing each reference.
      final changes = <String, List<LspTextEdit>>{};
      for (final ref in refs) {
        changes
            .putIfAbsent(ref.uri, () => <LspTextEdit>[])
            .add(LspTextEdit(range: ref.range, newText: newName));
      }
      return LspWorkspaceEdit(changes: changes).toJson();
    });
    return {'jsonrpc': '2.0', 'id': id, 'result': result};
  }

  /// Handle `textDocument/prepareRename`.
  Map<String, dynamic> _handlePrepareRename(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final result = _buildResult(id, params, _renameRangeAt);
    return {'jsonrpc': '2.0', 'id': id, 'result': result?.toJson()};
  }

  /// Handle `textDocument/documentSymbol`.
  ///
  /// Returns a flat list of symbols for all top-level declarations.
  Map<String, dynamic> _handleDocumentSymbol(
    Object? id,
    Map<String, dynamic> params,
  ) {
    if (_lastSuccess == null) {
      return {'jsonrpc': '2.0', 'id': id, 'result': <Map<String, dynamic>>[]};
    }
    final symbols = <LspDocumentSymbol>[];
    for (final decl in _lastSuccess!.declarations) {
      final pos = _positionAt(decl.span.start);
      final endPos = _positionAt(decl.span.end);
      final namePos = _positionAt(
        _definitionNameOffset(_documentText, decl.span, decl.name),
      );
      final kind = switch (decl.kind) {
        'data' => LspSymbolKind.struct,
        'type' => LspSymbolKind.interface,
        'fun' => LspSymbolKind.function,
        'typeclass' => LspSymbolKind.class_,
        'impl' => LspSymbolKind.class_,
        _ => LspSymbolKind.variable, // val, import
      };
      symbols.add(
        LspDocumentSymbol(
          name: decl.name,
          detail: decl.type,
          kind: kind,
          range: LspRange(
            start: LspPosition(line: pos.line - 1, character: 0),
            end: LspPosition(
              line: endPos.line - 1,
              character: endPos.column - 1,
            ),
          ),
          selectionRange: LspRange(
            start: LspPosition(
              line: namePos.line - 1,
              character: namePos.column - 1,
            ),
            end: LspPosition(
              line: namePos.line - 1,
              character: namePos.column - 1 + decl.name.length,
            ),
          ),
        ),
      );
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': [for (final s in symbols) s.toJson()],
    };
  }

  /// Handle `textDocument/signatureHelp`.
  ///
  /// When the user types `fun_name(`, inspects the text before the cursor
  /// to determine which function is being called, looks up its type, and
  /// extracts the parameter signature.
  Map<String, dynamic> _handleSignatureHelp(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final offset = _offsetFromParams(params);
    // Walk back past whitespace / '(' / ',' to find the function name.
    var pos = offset - 1;
    while (pos >= 0 && !_isIdentChar(_documentText, pos)) {
      pos--;
    }
    // Now pos is at the last char of the identifier before the cursor.
    if (pos < 0) {
      return {'jsonrpc': '2.0', 'id': id, 'result': null};
    }
    final nameEnd = pos + 1;
    var nameStart = pos;
    while (nameStart >= 0 && _isIdentChar(_documentText, nameStart)) {
      nameStart--;
    }
    nameStart++;
    if (nameStart >= nameEnd) {
      return {'jsonrpc': '2.0', 'id': id, 'result': null};
    }
    final funcName = _documentText.substring(nameStart, nameEnd);
    // Count commas between the matching '(' and cursor position.
    final parenStart = _documentText.lastIndexOf('(', offset);
    if (parenStart == -1) {
      return {'jsonrpc': '2.0', 'id': id, 'result': null};
    }
    var commas = 0;
    for (var i = parenStart + 1; i < offset; i++) {
      if (_documentText[i] == ',') commas++;
    }

    // Look up the function's type from semInfo or declarations.
    String? funcType;
    if (_lastSuccess != null) {
      for (final info in _lastSuccess!.semInfo) {
        if (info.name == funcName && info.span.start <= offset) {
          funcType = info.type;
          break;
        }
      }
      if (funcType == null) {
        for (final decl in _lastSuccess!.declarations) {
          if (decl.name == funcName && decl.span.start <= offset) {
            funcType = decl.type;
            break;
          }
        }
      }
    }
    if (funcType == null) {
      return {'jsonrpc': '2.0', 'id': id, 'result': null};
    }

    // Parse the Pi-type chain to extract parameter labels.
    final params_ = _parsePiParams(funcType, funcName);
    final signature = LspSignatureInformation(
      label: '$funcName${params_.isNotEmpty ? ' ' : ''}${params_.join(' ')}',
      parameters: [for (final p in params_) LspParameterInformation(label: p)],
    );
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result':
          LspSignatureHelp(
            signatures: [signature],
            activeSignature: 0,
            activeParameter:
                params_.isNotEmpty ? commas.clamp(0, params_.length - 1) : 0,
          ).toJson(),
    };
  }

  /// Handle `textDocument/codeLens`.
  ///
  /// Retained for future actionable Doxa proof tooling. The server does not
  /// currently advertise Code Lens because declaration types duplicate source.
  Map<String, dynamic> _handleCodeLens(
    Object? id,
    Map<String, dynamic> params,
  ) {
    if (_lastSuccess == null) {
      return {'jsonrpc': '2.0', 'id': id, 'result': <Map<String, dynamic>>[]};
    }
    final lenses = <LspCodeLens>[];
    for (final decl in _lastSuccess!.declarations) {
      final pos = _positionAt(decl.span.start);
      final typeStr = decl.type ?? decl.kind;
      lenses.add(
        LspCodeLens(
          range: LspRange(
            start: LspPosition(line: pos.line - 1, character: pos.column - 1),
            end: LspPosition(line: pos.line - 1, character: pos.column - 1),
          ),
          command: LspCommand(title: typeStr, command: ''),
        ),
      );
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': [for (final l in lenses) l.toJson()],
    };
  }

  /// Handle `textDocument/inlayHint`.
  ///
  /// Returns type annotations for declarations that have type
  /// information available from the last successful check.
  Map<String, dynamic> _handleInlayHint(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final hints = <Map<String, dynamic>>[];
    if (_lastSuccess == null) {
      return {'jsonrpc': '2.0', 'id': id, 'result': hints};
    }

    for (final decl in _lastSuccess!.declarations) {
      final type = decl.type;
      if (type == null) continue;
      final nameOffset = _definitionNameOffset(
        _documentText,
        decl.span,
        decl.name,
      );
      final pos = _positionAt(nameOffset);
      // Show the type as an inlay hint after the declaration name.
      hints.add({
        'position': {
          'line': pos.line - 1,
          'character': pos.column - 1 + decl.name.length,
        },
        'label': ': $type',
        'paddingLeft': true,
        'kind': 1, // Type
      });
    }

    return {'jsonrpc': '2.0', 'id': id, 'result': hints};
  }

  /// Handle `textDocument/formatting`.
  ///
  /// Delegates to the formatter library and returns a single text edit
  /// replacing the whole document.
  Map<String, dynamic> _handleFormatting(
    Object? id,
    Map<String, dynamic> params,
  ) {
    try {
      final options = params['options'] as Map<String, dynamic>?;
      final lineWidth = options?['lineWidth'] as int? ?? 100;
      final formatted = formatSource(_documentText, lineWidth: lineWidth);
      final edit = LspTextEdit(
        range: LspRange(
          start: const LspPosition(line: 0, character: 0),
          end: _endPosition(),
        ),
        newText: formatted,
      );
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': [edit.toJson()],
      };
    } catch (e) {
      return {'jsonrpc': '2.0', 'id': id, 'result': <Map<String, dynamic>>[]};
    }
  }

  /// Handle `textDocument/foldingRange`.
  ///
  /// Returns foldable regions: consecutive import lines, data type
  /// definitions, function bodies, and match arms.
  Map<String, dynamic> _handleFoldingRange(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final folds = <LspFoldingRange>[];
    final lines = _documentText.split('\n');
    var i = 0;
    var importStart = -1;

    while (i < lines.length) {
      final trimmed = lines[i].trimLeft();

      // Consecutive import declarations.
      if (trimmed.startsWith('import ')) {
        if (importStart < 0) importStart = i;
        i++;
        continue;
      }
      if (importStart >= 0 && i - importStart >= 2) {
        folds.add(
          LspFoldingRange(
            startLine: importStart,
            endLine: i - 1,
            kind: 'imports',
          ),
        );
      }
      importStart = -1;

      // Multi-line declarations: data, fun, typeclass, impl, match.
      if (trimmed.startsWith('data ') ||
          trimmed.startsWith('fun ') ||
          trimmed.startsWith('typeclass ') ||
          trimmed.startsWith('impl ') ||
          trimmed.startsWith('match ') ||
          trimmed.startsWith('val ') && trimmed.contains('={')) {
        final startLine = i;
        // Find the matching closing brace.
        var depth = 0;
        var started = false;
        while (i < lines.length) {
          for (var j = 0; j < lines[i].length; j++) {
            if (lines[i][j] == '{') {
              depth++;
              started = true;
            } else if (lines[i][j] == '}') {
              depth--;
            }
          }
          i++;
          if (started && depth == 0) break;
        }
        if (i - startLine >= 2) {
          folds.add(
            LspFoldingRange(
              startLine: startLine,
              endLine: i - 1,
              kind: 'region',
            ),
          );
        }
        continue;
      }

      // Block comments spanning multiple lines.
      if (trimmed.contains('/*') && !trimmed.contains('*/')) {
        final startLine = i;
        while (i < lines.length && !lines[i].contains('*/')) {
          i++;
        }
        if (i < lines.length) i++;
        if (i - startLine >= 2) {
          folds.add(
            LspFoldingRange(
              startLine: startLine,
              endLine: i - 1,
              kind: 'comment',
            ),
          );
        }
        continue;
      }

      i++;
    }

    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': [for (final f in folds) f.toJson()],
    };
  }

  /// The position at the very end of the document.
  LspPosition _endPosition() {
    final lines = _documentText.split('\n');
    return LspPosition(line: lines.length - 1, character: lines.last.length);
  }

  /// Extract the word prefix before [offset] (identifier characters only).
  String _wordPrefixAt(int offset) {
    var start = offset - 1;
    while (start >= 0 && _isIdentChar(_documentText, start)) {
      start--;
    }
    start++;
    if (start >= offset) return '';
    return _documentText.substring(start, offset);
  }

  /// Whether the character at [pos] in [_documentText] is an identifier
  /// character (letters, digits, underscores).
  bool _isIdentChar(String text, int pos) {
    if (pos < 0 || pos >= text.length) return false;
    final c = text.codeUnitAt(pos);
    return (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) ||
        c == 95;
  }

  /// Parse a pretty-printed Pi-type like `(m: Nat) -> (n: Nat) -> Nat`
  /// into a list of parameter labels `["(m: Nat)", "(n: Nat)"]`.
  static List<String> _parsePiParams(String type, String funcName) {
    final params = <String>[];
    var i = 0;
    // Skip leading spaces.
    while (i < type.length && type[i] == ' ') {
      i++;
    }
    while (i < type.length && type[i] == '(') {
      final start = i;
      var depth = 1;
      i++;
      while (i < type.length && depth > 0) {
        if (type[i] == '(') depth++;
        if (type[i] == ')') depth--;
        if (depth > 0) i++;
      }
      params.add(type.substring(start, i + 1));
      i++;
      // Skip ' -> ' separator.
      while (i < type.length &&
          (type[i] == ' ' || type[i] == '-' || type[i] == '>')) {
        i++;
      }
    }
    return params;
  }

  /// Find all source-backed references to [target] in open documents.
  ///
  /// Returns a list of LspLocation, one per occurrence including the
  /// declaration site when requested.
  List<LspLocation> _referencesFor(
    _SymbolTarget target, {
    bool includeDeclaration = true,
  }) {
    final locations = <LspLocation>[];
    final seen = <String>{};
    if (includeDeclaration) {
      final definitionDocument = _documentForUri(target.definitionUri);
      if (definitionDocument != null) {
        final definition = _definitionNameSpan(target, definitionDocument);
        locations.add(_locationForSpan(definition, definitionDocument));
        seen.add(_spanKey(definitionDocument, definition));
      }
    }
    for (final document in _indexedDocuments()) {
      for (final info in document.success.semInfo) {
        if (!_matchesTarget(info, document, target)) continue;
        final reference = _referenceNameSpan(info, target.name, document.text);
        if (reference == null || !seen.add(_spanKey(document, reference))) {
          continue;
        }
        locations.add(_locationForSpan(reference, document));
      }
    }
    return locations;
  }

  String _spanKey(_IndexedDocument document, DoxaSpan span) =>
      '${_canonicalDocumentUri(document.uri)}:${span.start}:${span.end}';

  LspLocation _locationForSpan(DoxaSpan span, _IndexedDocument document) =>
      LspLocation(uri: document.uri, range: _rangeForSpan(span, document.text));

  LspRange? _renameRangeAt(int offset) {
    final target = _symbolTargetAt(offset);
    if (target == null) return null;
    final info = _infoAt(offset) ?? _infoAt(offset - 1);
    final span =
        info == null
            ? _definitionNameSpan(target, _activeIndexedDocument!)
            : _referenceNameSpan(info, target.name, _documentText);
    return span == null ? null : _rangeForSpan(span);
  }

  LspRange _rangeForSpan(DoxaSpan span, [String? text]) {
    final pos = _positionIn(text ?? _documentText, span.start);
    final endPos = _positionIn(text ?? _documentText, span.end);
    return LspRange(
      start: LspPosition(line: pos.line - 1, character: pos.column - 1),
      end: LspPosition(line: endPos.line - 1, character: endPos.column - 1),
    );
  }

  _SymbolTarget? _symbolTargetAt(int offset) {
    final info = _infoAt(offset) ?? _infoAt(offset - 1);
    if (info != null) return _symbolTargetForInfo(info);
    final declaration = _declarationAt(offset) ?? _declarationAt(offset - 1);
    return declaration == null
        ? null
        : _symbolTargetForDeclaration(declaration);
  }

  _SymbolTarget? _symbolTargetForInfo(SemInfo info) {
    final definitionSpan = info.defSpan;
    if (definitionSpan == null || definitionSpan.isSynthetic) {
      return null;
    }
    if (info.kind case SemInfoKind.topBinding || SemInfoKind.dataType) {
      final name = _unqualifiedName(info.name);
      final definitionUri = _definitionUriFor(info, _activeIndexedDocument!);
      final definitionDocument = _documentForUri(definitionUri);
      final declaration = definitionDocument?.success.declarations.where(
        (declaration) =>
            declaration.span == definitionSpan &&
            declaration.name == name &&
            _semanticKindForDeclaration(declaration) == info.kind,
      );
      if (declaration == null || declaration.isEmpty) return null;
      return _SymbolTarget(
        definitionUri: definitionUri,
        kind: info.kind,
        definitionSpan: definitionSpan,
        name: name,
      );
    }
    return null;
  }

  _SymbolTarget? _symbolTargetForDeclaration(DeclInfo declaration) {
    final kind = _semanticKindForDeclaration(declaration);
    if (kind == null) return null;
    return _SymbolTarget(
      definitionUri: _canonicalDocumentUri(_documentUri),
      kind: kind,
      definitionSpan: declaration.span,
      name: declaration.name,
    );
  }

  SemInfoKind? _semanticKindForDeclaration(DeclInfo declaration) =>
      switch (declaration.kind) {
        'data' || 'typeclass' => SemInfoKind.dataType,
        'val' || 'fun' || 'type' => SemInfoKind.topBinding,
        _ => null,
      };

  DoxaSpan _definitionNameSpan(
    _SymbolTarget target,
    _IndexedDocument document,
  ) {
    final offset = _definitionNameOffset(
      document.text,
      target.definitionSpan,
      target.name,
    );
    return DoxaSpan(offset, offset + target.name.length);
  }

  DoxaSpan? _referenceNameSpan(SemInfo info, String name, String text) {
    if (info.span.isSynthetic) return null;
    for (final token in tokenizeDoxaSpans(text).reversed) {
      if (token.end > info.span.end) continue;
      if (token.start < info.span.start) break;
      if (token.token is Identifier && token.token.text == name) {
        return DoxaSpan(token.start, token.end);
      }
    }
    return null;
  }

  bool _matchesTarget(
    SemInfo info,
    _IndexedDocument document,
    _SymbolTarget target,
  ) =>
      info.kind == target.kind &&
      info.defSpan == target.definitionSpan &&
      _definitionUriFor(info, document) == target.definitionUri;

  String _definitionUriFor(SemInfo info, _IndexedDocument document) =>
      info.defFile == null
          ? _canonicalDocumentUri(document.uri)
          : _canonicalFileUri(info.defFile!);

  _IndexedDocument? get _activeIndexedDocument {
    final document = _activeDocument;
    final success = document?.lastSuccess;
    return document == null || success == null
        ? null
        : _IndexedDocument(
          uri: document.uri,
          text: document.text,
          success: success,
        );
  }

  Iterable<_IndexedDocument> _indexedDocuments() sync* {
    for (final document in _documents.values) {
      final success = document.lastSuccess;
      if (success == null) continue;
      yield _IndexedDocument(
        uri: document.uri,
        text: document.text,
        success: success,
      );
    }
    yield* _importSnapshots.values;
  }

  _IndexedDocument? _documentForUri(String uri) {
    for (final document in _indexedDocuments()) {
      if (_canonicalDocumentUri(document.uri) == uri) return document;
    }
    return null;
  }

  String _canonicalDocumentUri(String uri) =>
      uri.startsWith('file:')
          ? _canonicalFileUri(Uri.parse(uri).toFilePath())
          : uri;

  String _canonicalFileUri(String path) {
    final file = File(path);
    final canonicalPath =
        file.existsSync()
            ? file.resolveSymbolicLinksSync()
            : file.absolute.path;
    return Uri.file(canonicalPath).toString();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Run the check pipeline and publish diagnostics.
  void _checkAndPublish() {
    final stopwatch = Stopwatch()..start();
    final filename =
        _documentUri.startsWith('file://')
            ? Uri.parse(_documentUri).toFilePath()
            : _documentUri;
    final CheckOutput output;
    try {
      final session =
          _checkSession ??= IncrementalCheckSession(filename: filename);
      output = session.update(
        _documentText,
        sourceOverrides: _openDocumentSources(),
      );
    } catch (e) {
      _lastSuccess = null;
      _cachedImports = null;
      _checkSession = null;
      _publishDiagnostics([
        LspDiagnostic(
          range: const LspRange(
            start: LspPosition(line: 0, character: 0),
            end: LspPosition(line: 0, character: 0),
          ),
          severity: LspDiagnosticSeverity.error,
          message: 'Internal error: $e',
          source: 'doxa',
        ),
      ]);
      return;
    }
    switch (output) {
      case CheckSuccess _:
        _lastSuccess = output;
        // Cache import resolution for subsequent edits.
        if (output.imports != null) {
          _cachedImports = output.imports as CachedImports?;
          final document = _activeDocument;
          if (document != null) {
            document.importedPaths
              ..clear()
              ..addAll(
                _cachedImports?.importState.sourceFiles.keys ?? const {},
              );
          }
        }
        // Build frequency map from SemInfo references.
        _freq = <String, int>{};
        for (final info in output.semInfo) {
          _freq[info.name] = (_freq[info.name] ?? 0) + 1;
        }
        _refreshImportSnapshots();
        // Publish empty diagnostics on success.
        _publishDiagnostics(<LspDiagnostic>[]);
      case final CheckFailure failure:
        _lastSuccess = null;
        _cachedImports = null;
        final source = SourceFile(filename: _documentUri, text: _documentText);
        final diagnostics = <LspDiagnostic>[];
        for (final error in failure.errors) {
          final pos =
              error.span != null
                  ? source.positionAt(error.span!.start)
                  : source.positionAt(0);
          final endPos =
              error.span != null ? source.positionAt(error.span!.end) : pos;
          diagnostics.add(
            LspDiagnostic(
              range: LspRange(
                start: LspPosition(
                  line: pos.line - 1,
                  character: pos.column - 1,
                ),
                end: LspPosition(
                  line: endPos.line - 1,
                  character: endPos.column - 1,
                ),
              ),
              severity: LspDiagnosticSeverity.error,
              message: error.message,
              source: 'doxa',
            ),
          );
        }
        _publishDiagnostics(diagnostics);
    }
    if (_traceTiming) {
      final session = _checkSession;
      stderr.writeln(
        'doxa-lsp check uri=$_documentUri version=${_activeDocument?.version} '
        'reparse=${_activeDocument?.lastReparseStrategy?.name ?? 'open'} '
        'parseMs=${session?.lastParseMilliseconds ?? 0} '
        'checkMs=${session?.lastCheckMilliseconds ?? 0} '
        'start=${session?.lastRecheckStart ?? -1} '
        'reused=${session?.lastReusedDeclarationCount ?? 0} '
        'rechecked=${session?.lastRecheckedDeclarationCount ?? 0} '
        'fallback=${session?.lastFallbackReason ?? 'none'} '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    }
  }

  Map<String, String> _openDocumentSources() => {
    for (final document in _documents.values)
      if (document.uri.startsWith('file:'))
        Uri.parse(document.uri).toFilePath(): document.text,
  };

  void _refreshImportSnapshots() {
    final sources = <String, SourceFile>{};
    for (final document in _documents.values) {
      final imports = document.lastSuccess?.imports as CachedImports?;
      if (imports != null) {
        sources.addAll(imports.importState.sourceFiles);
      }
    }
    final openUris = {
      for (final document in _documents.values)
        _canonicalDocumentUri(document.uri),
    };
    final overrides = _openDocumentSources();
    final next = <String, _IndexedDocument>{};
    for (final entry in sources.entries) {
      final path = entry.key;
      final uri = _canonicalFileUri(path);
      if (openUris.contains(uri)) continue;
      final session = _importSessions.putIfAbsent(
        path,
        () => IncrementalCheckSession(filename: path),
      );
      final output = session.update(
        entry.value.text,
        sourceOverrides: overrides,
      );
      if (output is CheckSuccess) {
        next[uri] = _IndexedDocument(
          uri: Uri.file(path).toString(),
          text: entry.value.text,
          success: output,
        );
      }
    }
    _importSessions.removeWhere((path, _) => !sources.containsKey(path));
    _importSnapshots = next;
  }

  void _invalidateImportSnapshotsFor(String path) {
    for (final session in _importSessions.values) {
      if (session.filename == path || session.importsPath(path)) {
        session.invalidateImports();
      }
    }
  }

  /// Send a `textDocument/publishDiagnostics` notification.
  void _publishDiagnostics(List<LspDiagnostic> diagnostics) {
    final params = LspPublishDiagnosticsParams(
      uri: _documentUri,
      diagnostics: diagnostics,
      version: _activeDocument?.version,
    );
    final msg = {
      'jsonrpc': '2.0',
      'method': 'textDocument/publishDiagnostics',
      'params': params.toJson(),
    };
    try {
      sendLspMessage(msg);
    } catch (e) {
      // Silently drop diagnostics on transport failure.
      // This can happen in piped mode due to a Dart runtime
      // contention issue between stdin.readLineSync and
      // stdout.write. The initialize/hover/definition handlers
      // will still work on the next stdin read cycle.
    }
  }

  /// Look up the [SemInfo] at a given byte [offset].
  SemInfo? _infoAt(int offset) {
    if (_lastSuccess == null) return null;
    final infos = _lastSuccess!.semInfo;
    // Binary search: find the last SemInfo with span.start <= offset.
    var lo = 0;
    var hi = infos.length - 1;
    var result = -1;
    while (lo <= hi) {
      final mid = lo + ((hi - lo) >> 1);
      if (infos[mid].span.start <= offset) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (result < 0) return null;
    final candidate = infos[result];
    // Verify the offset falls within the span.
    if (offset >= candidate.span.start && offset < candidate.span.end) {
      return candidate;
    }
    return null;
  }

  /// Returns the declaration whose name occupies [offset]. Declaration names
  /// are binders, so elaboration does not emit SemInfo for their own spans.
  DeclInfo? _declarationAt(int offset) {
    if (_lastSuccess == null) return null;
    final word = _wordAt(offset);
    if (word == null) return null;
    for (final declaration in _lastSuccess!.declarations) {
      if (declaration.name != word) continue;
      final nameOffset = _documentText.indexOf(word, declaration.span.start);
      if (nameOffset >= declaration.span.start &&
          nameOffset < declaration.span.end &&
          offset >= nameOffset &&
          offset < nameOffset + word.length) {
        return declaration;
      }
    }
    return null;
  }

  String? _builtinHoverAt(int offset) => switch (_wordAt(offset)) {
    'Type' => '```doxa\nType : Type 1\n```\n\nThe universe of types.',
    'Prop' => '```doxa\nProp : Type\n```\n\nThe sort of propositions.',
    'fun' => '```doxa\nfun\n```\n\nDeclares a named function.',
    'data' => '```doxa\ndata\n```\n\nDeclares an inductive type.',
    'val' => '```doxa\nval\n```\n\nDeclares a named value.',
    'import' =>
      '```doxa\nimport\n```\n\nLoads declarations from another Doxa file.',
    'match' => '```doxa\nmatch\n```\n\nEliminates an inductive value by cases.',
    'case' =>
      '```doxa\ncase\n```\n\nIntroduces one branch of a match expression.',
    'typeclass' =>
      '```doxa\ntypeclass\n```\n\nDeclares an interface with operations.',
    'impl' => '```doxa\nimpl\n```\n\nDefines an implementation of a typeclass.',
    _ => null,
  };

  String? _wordAt(int offset) {
    if (offset < 0 || offset >= _documentText.length) return null;
    var start = offset;
    var end = offset;
    while (start > 0 && _isIdentChar(_documentText, start - 1)) {
      start--;
    }
    while (end < _documentText.length && _isIdentChar(_documentText, end)) {
      end++;
    }
    return start == end ? null : _documentText.substring(start, end);
  }

  String? _sourceTextFor(String path) =>
      _cachedImports?.importState.sourceFiles[path]?.text;

  String _unqualifiedName(String name) =>
      name.contains('.') ? name.substring(name.lastIndexOf('.') + 1) : name;

  LspLocation? _importDefinitionAt(int offset) {
    if (!_documentUri.startsWith('file:')) return null;
    final parsed = parseProgram(_documentText);
    final declarations = switch (parsed) {
      Success<ParseError, SProgram>(:final value) ||
      Partial<ParseError, SProgram>(:final value) => value.decls,
      Failure<ParseError, SProgram>() => parseLeadingImports(_documentText),
    };
    for (final declaration in declarations) {
      if (offset < declaration.span.start || offset >= declaration.span.end) {
        continue;
      }
      final kind = declaration.kind;
      if (kind is! SImportKind) return null;
      final sourcePath = Uri.parse(_documentUri).toFilePath();
      final target = File(Uri.file(sourcePath).resolve(kind.path).toFilePath());
      final targetPath =
          target.existsSync()
              ? target.resolveSymbolicLinksSync()
              : target.absolute.path;
      return LspLocation(
        uri: Uri.file(targetPath).toString(),
        range: const LspRange(
          start: LspPosition(line: 0, character: 0),
          end: LspPosition(line: 0, character: 0),
        ),
      );
    }
    return null;
  }

  LspLocation? _importedDefinitionAt(int offset) {
    final name = _wordAt(offset);
    if (name == null) return null;
    final importState = _cachedImports?.importState;
    final defFile = importState?.definitionFiles[name];
    final defSpan = importState?.definitionSpans[name];
    if (defFile == null || defSpan == null) return null;
    final defText = _sourceTextFor(defFile);
    if (defText == null) return null;
    final defOffset = _definitionNameOffset(defText, defSpan, name);
    final defPos = _positionIn(defText, defOffset);
    return LspLocation(
      uri: Uri.file(defFile).toString(),
      range: LspRange(
        start: LspPosition(line: defPos.line - 1, character: defPos.column - 1),
        end: LspPosition(
          line: defPos.line - 1,
          character: defPos.column - 1 + name.length,
        ),
      ),
    );
  }

  int _definitionNameOffset(String text, DoxaSpan span, String name) {
    final unqualifiedName = _unqualifiedName(name);
    final offset = text.indexOf(unqualifiedName, span.start);
    return offset >= span.start && offset < span.end ? offset : span.start;
  }

  ({int line, int column}) _positionIn(String text, int offset) =>
      SourceFile(filename: '', text: text).positionAt(offset);

  /// Extract the byte offset from LSP params (position object).
  int _offsetFromParams(Map<String, dynamic> params) {
    final position = params['position'] as Map<String, dynamic>;
    final line = position['line'] as int;
    final character = position['character'] as int;
    // Convert 0-based LSP position to byte offset.
    var lineStart = 0;
    for (var i = 0; i < line && lineStart < _documentText.length; i++) {
      lineStart = _documentText.indexOf('\n', lineStart) + 1;
      if (lineStart == 0) break;
    }
    return lineStart + character;
  }

  /// Resolve a byte offset to a 1-based (line, column) pair.
  ({int line, int column}) _positionAt(int offset) {
    final source = SourceFile(filename: '', text: _documentText);
    return source.positionAt(offset);
  }

  /// Build a result by extracting the offset from [params] and applying
  /// [builder], returning null when [builder] returns null.
  T? _buildResult<T>(
    Object? id,
    Map<String, dynamic> params,
    T? Function(int offset) builder,
  ) {
    if (_lastSuccess == null) return null;
    final offset = _offsetFromParams(params);
    return builder(offset);
  }
}
