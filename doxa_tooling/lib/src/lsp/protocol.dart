/// LSP protocol types for the Doxa language server.
///
/// Minimal set of type definitions and serialisation for the LSP
/// methods Doxa supports. Every type has a `toJson()` method for
/// JSON-RPC serialisation.
library;

/// A position in a text document (0-based line and character).
final class LspPosition {
  /// 0-based line index.
  final int line;

  /// 0-based character offset on the line.
  final int character;

  /// Creates a position.
  const LspPosition({required this.line, required this.character});

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {'line': line, 'character': character};
}

/// A range in a text document.
final class LspRange {
  /// Start position (inclusive).
  final LspPosition start;

  /// End position (exclusive in LSP convention).
  final LspPosition end;

  /// Creates a range.
  const LspRange({required this.start, required this.end});

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };
}

/// A location in a text document (URI + range).
final class LspLocation {
  /// The document URI.
  final String uri;

  /// The range within the document.
  final LspRange range;

  /// Creates a location.
  const LspLocation({required this.uri, required this.range});

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {'uri': uri, 'range': range.toJson()};
}

/// The result of an LSP `textDocument/hover` request.
final class LspHover {
  /// The hover contents (markdown string).
  final String contents;

  /// An optional range to highlight.
  final LspRange? range;

  /// Creates a hover result.
  const LspHover({required this.contents, this.range});

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'contents': contents,
    if (range != null) 'range': range!.toJson(),
  };
}

/// Diagnostic severity (mirrors LSP DiagnosticSeverity).
enum LspDiagnosticSeverity {
  /// An error.
  error(1),

  /// A warning.
  warning(2),

  /// Information.
  information(3),

  /// A hint.
  hint(4);

  /// The integer value as defined by the LSP spec.
  final int value;

  /// Creates a severity level.
  const LspDiagnosticSeverity(this.value);
}

/// A diagnostic produced by the checker.
final class LspDiagnostic {
  /// The range where the diagnostic applies.
  final LspRange range;

  /// The severity (1=error, 2=warning, 3=info, 4=hint).
  final LspDiagnosticSeverity? severity;

  /// The human-readable diagnostic message.
  final String message;

  /// The source identifier (e.g. `"doxa"`).
  final String? source;

  /// Creates a diagnostic.
  const LspDiagnostic({
    required this.range,
    this.severity,
    required this.message,
    this.source,
  });

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'range': range.toJson(),
    if (severity != null) 'severity': severity!.value,
    'message': message,
    if (source != null) 'source': source,
  };
}

/// Parameters for the `textDocument/publishDiagnostics` notification.
final class LspPublishDiagnosticsParams {
  /// The document URI.
  final String uri;

  /// The diagnostics to publish.
  final List<LspDiagnostic> diagnostics;

  /// Creates a publish-diagnostics params object.
  const LspPublishDiagnosticsParams({
    required this.uri,
    required this.diagnostics,
  });

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'uri': uri,
    'diagnostics': [for (final d in diagnostics) d.toJson()],
  };
}

/// A completion item.
final class LspCompletionItem {
  /// The display label.
  final String label;

  /// Additional detail (e.g. the type).
  final String? detail;

  /// Documentation string.
  final String? documentation;

  /// Creates a completion item.
  const LspCompletionItem({
    required this.label,
    this.detail,
    this.documentation,
  });

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'label': label,
    if (detail != null) 'detail': detail,
    if (documentation != null) 'documentation': documentation,
  };
}

/// A text edit that replaces a range of text.
final class LspTextEdit {
  /// The range to replace.
  final LspRange range;

  /// The new text.
  final String newText;

  /// Creates a text edit.
  const LspTextEdit({required this.range, required this.newText});

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'range': range.toJson(),
    'newText': newText,
  };
}

/// A workspace edit containing changes to documents.
final class LspWorkspaceEdit {
  /// Changes keyed by document URI.
  final Map<String, List<LspTextEdit>> changes;

  /// Creates a workspace edit.
  const LspWorkspaceEdit({required this.changes});

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'changes': {
      for (final entry in changes.entries)
        entry.key: [for (final edit in entry.value) edit.toJson()],
    },
  };
}

/// Semantic tokens returned by `textDocument/semanticTokens/full`.
final class LspSemanticTokens {
  /// The flat token data array (delta-encoded).
  final List<int> data;

  /// Creates semantic tokens.
  const LspSemanticTokens({required this.data});

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {'data': data};
}

/// Semantic token types registered by the server.
///
/// Each index corresponds to an entry in the token types legend.
enum LspSemanticTokenType {
  /// `type` (1)
  type_,

  /// `class` (2)
  class_,

  /// `enumMember` (10)
  enumMember,

  /// `variable` (8)
  variable,

  /// `function` (12)
  function,

  /// `method` (13)
  method,

  /// `parameter` (7)
  parameter,

  /// `property` (9)
  property,

  /// `keyword` (15)
  keyword,

  /// `modifier` (16)
  modifier,

  /// `namespace` (0)
  namespace;

  /// The string representation for the legend.
  String get label => switch (this) {
    LspSemanticTokenType.type_ => 'type',
    LspSemanticTokenType.class_ => 'class',
    LspSemanticTokenType.enumMember => 'enumMember',
    LspSemanticTokenType.variable => 'variable',
    LspSemanticTokenType.function => 'function',
    LspSemanticTokenType.method => 'method',
    LspSemanticTokenType.parameter => 'parameter',
    LspSemanticTokenType.property => 'property',
    LspSemanticTokenType.keyword => 'keyword',
    LspSemanticTokenType.modifier => 'modifier',
    LspSemanticTokenType.namespace => 'namespace',
  };

  /// The index in the legend array.
  int get legendIndex {
    var i = 0;
    for (final t in LspSemanticTokenType.values) {
      if (t == this) return i;
      i++;
    }
    return 0;
  }
}

/// Semantic token modifiers.
enum LspSemanticTokenModifier {
  /// `readonly`
  readonly;

  /// The string representation for the legend.
  String get label => switch (this) {
    LspSemanticTokenModifier.readonly => 'readonly',
  };

  /// The bitmask for encoding (1 << index).
  int get bit => 1 << index;
}

/// A completion list returned by `textDocument/completion`.
final class LspCompletionList {
  /// True if the list is not complete (e.g. the user should continue
  /// typing to narrow results).
  final bool isIncomplete;

  /// The completion items.
  final List<LspCompletionItem> items;

  /// Creates a completion list.
  const LspCompletionList({this.isIncomplete = false, required this.items});

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'isIncomplete': isIncomplete,
    'items': [for (final i in items) i.toJson()],
  };
}
