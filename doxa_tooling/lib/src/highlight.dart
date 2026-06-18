/// Syntax highlighting for Doxa: converts token streams to HTML with
/// unified CSS class names.
///
/// ## CSS class names (unified across all rendering contexts)
///
/// | Token class | CSS class | CSS variable |
/// |-------------|-----------|--------------|
/// | keyword     | `tok-keyword` | `--tok-kw` |
/// | sort        | `tok-sort`    | `--tok-type` |
/// | comment     | `tok-comment` | `--tok-comment` |
/// | number      | `tok-number`  | `--tok-num` |
/// | punctuation | `tok-punct`   | `--tok-punct` |
/// | error       | `tok-error`   | (new) |
///
/// Identifiers (type-name, binder, constructor, and plain identifiers)
/// receive no CSS class — they inherit the base text color. Semantic
/// refinement in Layer 3 may add distinct classes later.
library;

import 'tokenize.dart';

// ---------------------------------------------------------------------------
// CSS class mapping
// ---------------------------------------------------------------------------

/// Returns the unified CSS class name for [token], or `null` for tokens
/// that should render as plain text (identifiers, whitespace).
String? cssClassFor(Token token) => switch (token) {
  Keyword _ => 'tok-keyword',
  TypeName _ => 'tok-sort',
  Comment _ => 'tok-comment',
  NumberLit _ => 'tok-number',
  Punctuation _ => 'tok-punct',
  Operator _ => 'tok-punct',
  Plain _ => 'tok-error',
  _ => null,
};

// ---------------------------------------------------------------------------
// HTML generation
// ---------------------------------------------------------------------------

/// Produces a `<pre><code class="language-doxa">` block with syntax-highlighted
/// spans for [source].
String highlightDoxaBlock(String source) {
  final buf =
      StringBuffer()
        ..write('<pre><code class="language-doxa">')
        ..write(highlightDoxaInline(source))
        ..write('</code></pre>');
  return buf.toString();
}

/// Produces highlighted inline HTML (no surrounding `<pre><code>`) for
/// embedding inside an existing code element.
String highlightDoxaInline(String source) {
  final spans = tokenizeDoxaSpans(source);
  final buf = StringBuffer();
  for (final s in spans) {
    final cls = cssClassFor(s.token);
    final escaped = _escapeHtml(s.token.text);
    if (cls != null) {
      buf.write('<span class="$cls">$escaped</span>');
    } else {
      buf.write(escaped);
    }
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Node-based output (for server-side template engines)
// ---------------------------------------------------------------------------

/// A plain-text or highlighted segment of source.
///
/// Consumers that render to DOM directly (e.g. server-side Dart templates)
/// can use this to build their own element trees instead of parsing HTML.
final class DoxaSegment {
  /// The segment's text, already HTML-escaped.
  final String text;

  /// The CSS class name, or `null` for plain text.
  final String? cssClass;

  /// Creates a segment.
  const DoxaSegment(this.text, {this.cssClass});
}

/// Tokenize [source] into a list of [DoxaSegment]s for custom rendering.
///
/// Each segment carries an optional CSS class name and pre-escaped HTML
/// text. Concatenating the `.text` of all segments reproduces the
/// original source (after un-escaping).
List<DoxaSegment> tokenizeToSegments(String source) {
  final spans = tokenizeDoxaSpans(source);
  return [
    for (final s in spans)
      DoxaSegment(_escapeHtml(s.token.text), cssClass: cssClassFor(s.token)),
  ];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// HTML-escape a plain-text string.
String _escapeHtml(String s) {
  // Optimisation: avoid allocation when no characters need escaping.
  if (!s.contains('&') && !s.contains('<') && !s.contains('>')) {
    return s;
  }
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
