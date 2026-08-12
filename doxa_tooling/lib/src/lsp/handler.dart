/// LSP message dispatch and document management for Doxa.
///
/// Maintains the open document's text, runs the full check pipeline on
/// every edit, and serves hover/definition/completion from the semantic
/// metadata produced by Phase 3a.
library;

import '../output.dart';
import 'package:doxa/doxa.dart';
import '../web_check.dart';
import '../format.dart' show formatSource;
import '../tokenize.dart' show tokenizeDoxaSpans;
import 'package:rumil_tokens/rumil_tokens.dart'
    show Keyword, Comment, NumberLit, Operator, Punctuation, Token;
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
}

/// LSP handler: owns open-document state and dispatches incoming methods.
final class LspHandler {
  final Map<String, _DocumentState> _documents = {};
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

  /// Request IDs that have been cancelled via $/cancelRequest.
  final Set<int> _cancelledIds = {};

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

      case 'workspace/didChangeWatchedFiles':
        _handleWatchedFiles();
        return null;

      case 'shutdown':
        return {'jsonrpc': '2.0', 'id': id, 'result': null};

      case 'exit':
        // No response for exit; caller should break the loop.
        return {'jsonrpc': '2.0', 'id': id, 'result': null};

      default:
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
        'renameProvider': true,
        'documentSymbolProvider': true,
        'codeLensProvider': <String, dynamic>{'resolveProvider': false},
        'documentFormattingProvider': true,
        'foldingRangeProvider': true,
        'inlayHintProvider': true,
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
    _freq = <String, int>{};
    _cachedImports = null;
    _checkAndPublish();
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
      _documentText = change['text'] as String;
    }
    if (version != null) document.version = version;
    _freq = <String, int>{};
    _checkAndPublish();
  }

  /// Handle `textDocument/didClose`.
  void _handleDidClose(Map<String, dynamic> params) {
    final textDocument = params['textDocument'] as Map<String, dynamic>;
    final uri = textDocument['uri'] as String;
    final document = _documents.remove(uri);
    if (document == null) return;
    _activeDocument = document;
    _publishDiagnostics(const <LspDiagnostic>[]);
    if (identical(_activeDocument, document)) _activeDocument = null;
  }

  void _handleWatchedFiles() {
    final previous = _activeDocument;
    for (final document in _documents.values) {
      _activeDocument = document;
      _checkAndPublish();
    }
    _activeDocument = previous;
  }

  String? _uriFromParams(Map<String, dynamic>? params) {
    final textDocument = params?['textDocument'] as Map<String, dynamic>?;
    return textDocument?['uri'] as String?;
  }

  /// Handle `textDocument/hover`.
  Map<String, dynamic> _handleHover(Object? id, Map<String, dynamic> params) {
    final result = _buildResult(id, params, (offset) {
      final info = _infoAt(offset);
      if (info == null) return null;
      final pos = _positionAt(offset);
      final range = LspRange(
        start: LspPosition(line: pos.line - 1, character: pos.column - 1),
        end: LspPosition(line: pos.line - 1, character: pos.column - 1),
      );
      return LspHover(
        contents: '```doxa\n${info.name} : ${info.type}\n```',
        range: range,
      );
    });
    return {'jsonrpc': '2.0', 'id': id, 'result': result?.toJson()};
  }

  /// Handle `textDocument/definition`.
  Map<String, dynamic> _handleDefinition(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final result = _buildResult(id, params, (offset) {
      final info = _infoAt(offset);
      if (info?.defSpan == null) return null;
      final defPos = _positionAt(info!.defSpan!.start);
      return LspLocation(
        uri: _documentUri,
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
      final info = _infoAt(offset);
      if (info == null) return null;
      return _referencesFor(info.name);
    });
    return {'jsonrpc': '2.0', 'id': id, 'result': result};
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
      final info = _infoAt(offset);
      if (info == null) return null;
      final refs = _referencesFor(info.name);
      if (refs.isEmpty) return null;
      // Build text edits: one per reference span.
      final edits = <LspTextEdit>[];
      for (final ref in refs) {
        edits.add(LspTextEdit(range: ref.range, newText: newName));
      }
      return LspWorkspaceEdit(changes: {_documentUri: edits}).toJson();
    });
    return {'jsonrpc': '2.0', 'id': id, 'result': result};
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
            end: LspPosition(line: endPos.line - 1, character: 0),
          ),
          selectionRange: LspRange(
            start: LspPosition(line: pos.line - 1, character: pos.column - 1),
            end: LspPosition(
              line: pos.line - 1,
              character: pos.column - 1 + decl.name.length,
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
  /// Returns one code lens per top-level declaration showing its type.
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
      final pos = _positionAt(decl.span.start);
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
      final formatted = formatSource(_documentText);
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

  /// Find all references to [name] in the current document.
  ///
  /// Returns a list of LspLocation, one per occurrence (including the
  /// definition site itself when a defSpan is available).
  List<LspLocation> _referencesFor(String name) {
    if (_lastSuccess == null) return <LspLocation>[];
    final infos = _lastSuccess!.semInfo;
    final locations = <LspLocation>[];
    for (final info in infos) {
      if (info.name == name && !info.span.isSynthetic) {
        final pos = _positionAt(info.span.start);
        final endPos = _positionAt(info.span.end);
        locations.add(
          LspLocation(
            uri: _documentUri,
            range: LspRange(
              start: LspPosition(line: pos.line - 1, character: pos.column - 1),
              end: LspPosition(
                line: endPos.line - 1,
                character: endPos.column - 1,
              ),
            ),
          ),
        );
      }
    }
    return locations;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Run the check pipeline and publish diagnostics.
  void _checkAndPublish() {
    final filename =
        _documentUri.startsWith('file://')
            ? Uri.parse(_documentUri).toFilePath()
            : _documentUri;
    final CheckOutput output;
    try {
      if (_cachedImports != null) {
        output = checkSourceWithCache(
          _documentText,
          filename: filename,
          cache: _cachedImports!,
        );
      } else {
        output = checkSourceOutput(_documentText, filename: filename);
      }
    } catch (e) {
      _lastSuccess = null;
      _cachedImports = null;
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
        }
        // Build frequency map from SemInfo references.
        _freq = <String, int>{};
        for (final info in output.semInfo) {
          _freq[info.name] = (_freq[info.name] ?? 0) + 1;
        }
        // Publish empty diagnostics on success.
        _publishDiagnostics(<LspDiagnostic>[]);
      case final CheckFailure failure:
        _lastSuccess = null;
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
  }

  /// Send a `textDocument/publishDiagnostics` notification.
  void _publishDiagnostics(List<LspDiagnostic> diagnostics) {
    final params = LspPublishDiagnosticsParams(
      uri: _documentUri,
      diagnostics: diagnostics,
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
