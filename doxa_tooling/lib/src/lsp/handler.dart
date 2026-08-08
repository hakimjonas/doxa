/// LSP message dispatch and document management for Doxa.
///
/// Maintains the open document's text, runs the full check pipeline on
/// every edit, and serves hover/definition/completion from the semantic
/// metadata produced by Phase 3a.
library;

import '../output.dart';
import 'package:doxa/src/sem_info.dart';
import 'package:doxa/src/source.dart';
import '../web_check.dart';
import 'protocol.dart';
import 'transport.dart';

/// LSP handler: owns document state and dispatches incoming methods.
final class LspHandler {
  /// The URI of the open document (or empty if none).
  String _documentUri = '';

  /// The current source text.
  String _documentText = '';

  /// The last successful check result, used for semantic queries.
  CheckSuccess? _lastSuccess;

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

    switch (method) {
      case 'initialize':
        return _handleInitialize(id as int);

      case 'textDocument/didOpen':
        _handleDidOpen(params!);
        return null;

      case 'textDocument/didChange':
        _handleDidChange(params!);
        return null;

      case 'textDocument/didClose':
        _handleDidClose();
        return null;

      case 'textDocument/hover':
        return _handleHover(id as int, params!);

      case 'textDocument/definition':
        return _handleDefinition(id as int, params!);

      case 'textDocument/completion':
        return _handleCompletion(id as int, params!);

      case 'textDocument/semanticTokens/full':
        return _handleSemanticTokens(id as int, params!);

      case 'textDocument/references':
        return _handleReferences(id as int, params!);

      case 'textDocument/rename':
        return _handleRename(id as int, params!);

      case 'textDocument/documentSymbol':
        return _handleDocumentSymbol(id as int, params!);

      case 'textDocument/signatureHelp':
        return _handleSignatureHelp(id as int, params!);

      case 'shutdown':
        return {'jsonrpc': '2.0', 'id': id, 'result': null};

      case 'exit':
        // No response for exit; caller should break the loop.
        return {'jsonrpc': '2.0', 'id': id, 'result': null};

      default:
        // Method not supported — return null.
        return null;
    }
  }

  /// Handle `initialize`.
  Map<String, dynamic> _handleInitialize(int id) => {
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
      'serverInfo': {'name': 'doxa-lsp', 'version': '0.1.0'},
    },
  };

  /// Handle `textDocument/didOpen`.
  void _handleDidOpen(Map<String, dynamic> params) {
    final textDocument = params['textDocument'] as Map<String, dynamic>;
    _documentUri = textDocument['uri'] as String;
    _documentText = textDocument['text'] as String;
    _checkAndPublish();
  }

  /// Handle `textDocument/didChange`.
  void _handleDidChange(Map<String, dynamic> params) {
    final contentChanges = params['contentChanges'] as List<dynamic>;
    if (contentChanges.isNotEmpty) {
      final change = contentChanges.last as Map<String, dynamic>;
      _documentText = change['text'] as String;
    }
    _checkAndPublish();
  }

  /// Handle `textDocument/didClose`.
  void _handleDidClose() {
    _documentUri = '';
    _documentText = '';
    _lastSuccess = null;
    _publishDiagnostics(const <LspDiagnostic>[]);
  }

  /// Handle `textDocument/hover`.
  Map<String, dynamic> _handleHover(int id, Map<String, dynamic> params) {
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
    return {
      'jsonrpc': '2.0',
      'id': id,
      if (result != null) 'result': result.toJson(),
    };
  }

  /// Handle `textDocument/definition`.
  Map<String, dynamic> _handleDefinition(int id, Map<String, dynamic> params) {
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
    return {
      'jsonrpc': '2.0',
      'id': id,
      if (result != null) 'result': result.toJson(),
    };
  }

  /// Handle `textDocument/completion`.
  Map<String, dynamic> _handleCompletion(int id, Map<String, dynamic> params) {
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
    items.sort((a, b) => a.label.compareTo(b.label));
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': LspCompletionList(isIncomplete: false, items: items).toJson(),
    };
  }

  /// Handle `textDocument/semanticTokens/full`.
  Map<String, dynamic> _handleSemanticTokens(
    int id,
    Map<String, dynamic> params,
  ) {
    if (_lastSuccess == null) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': const LspSemanticTokens(data: <int>[]).toJson(),
      };
    }
    final infos = _lastSuccess!.semInfo;
    final data = <int>[];
    var prevLine = 0;
    var prevChar = 0;

    for (final info in infos) {
      final span = info.span;
      if (span.isSynthetic) continue;

      final pos = _positionAt(span.start);
      final length = span.end - span.start;
      if (length <= 0) continue;

      final line = pos.line - 1;
      final char = pos.column - 1;

      // Delta-encode.
      if (line == prevLine) {
        data.add(0); // same line
        data.add(char - prevChar);
      } else {
        data.add(line - prevLine);
        data.add(char);
      }
      data.add(length);
      data.add(_semanticTokenType(info.kind).legendIndex);
      final modifier = _semanticTokenModifier(info.kind);
      data.add(modifier?.bit ?? 0);

      prevLine = line;
      prevChar = char;
    }

    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': LspSemanticTokens(data: data).toJson(),
    };
  }

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
  Map<String, dynamic> _handleReferences(int id, Map<String, dynamic> params) {
    final result = _buildResult(id, params, (offset) {
      final info = _infoAt(offset);
      if (info == null) return null;
      return _referencesFor(info.name);
    });
    return {'jsonrpc': '2.0', 'id': id, if (result != null) 'result': result};
  }

  /// Handle `textDocument/rename`.
  Map<String, dynamic> _handleRename(int id, Map<String, dynamic> params) {
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
    return {'jsonrpc': '2.0', 'id': id, if (result != null) 'result': result};
  }

  /// Handle `textDocument/documentSymbol`.
  ///
  /// Returns a flat list of symbols for all top-level declarations.
  Map<String, dynamic> _handleDocumentSymbol(
    int id,
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
    int id,
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
    while (i < type.length && type[i] == ' ') i++;
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
      output = checkSourceOutput(_documentText, filename: filename);
    } catch (e) {
      _lastSuccess = null;
      final source = SourceFile(filename: _documentUri, text: _documentText);
      _publishDiagnostics([
        LspDiagnostic(
          range: LspRange(
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
    int id,
    Map<String, dynamic> params,
    T? Function(int offset) builder,
  ) {
    if (_lastSuccess == null) return null;
    final offset = _offsetFromParams(params);
    return builder(offset);
  }
}
