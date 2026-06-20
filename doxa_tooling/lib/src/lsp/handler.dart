/// LSP message dispatch and document management for Doxa.
///
/// Maintains the open document's text, runs the full check pipeline on
/// every edit, and serves hover/definition/completion from the semantic
/// metadata produced by Phase 3a.
library;

import '../output.dart';
import 'package:doxa/src/sem_info.dart';
import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart';
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
    final names = <String>{};
    if (_lastSuccess != null) {
      // Collect unique names from SemInfo entries whose occurrence span
      // is before or at the current offset (approximates "in scope").
      for (final info in _lastSuccess!.semInfo) {
        if (info.span.start <= offset) {
          names.add(info.name);
        }
      }
      // Also include all declaration names whose span starts at or
      // before the offset.
      for (final decl in _lastSuccess!.declarations) {
        if (decl.span.start <= offset) {
          names.add(decl.name);
        }
      }
    }
    final items = names.map((n) => LspCompletionItem(label: n)).toList();
    items.sort((a, b) => a.label.compareTo(b.label));
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': LspCompletionList(items: items).toJson(),
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
    final output = checkSourceOutput(_documentText, filename: _documentUri);
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
    sendLspMessage({
      'jsonrpc': '2.0',
      'method': 'textDocument/publishDiagnostics',
      'params': params.toJson(),
    });
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
