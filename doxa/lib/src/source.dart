/// Source-file wrapping for error reporting.
///
/// A [SourceFile] pairs the raw input with an optional filename (for
/// diagnostic output) and resolves byte offsets into line and column
/// positions.
///
/// Line starts are computed once on construction so repeated line/col
/// lookups during diagnostic formatting are O(log n) rather than O(n).
/// The cost is trivial and it keeps diagnostic formatting linear in
/// the number of diagnostics, not in source length.
library;

import 'surface.dart';

/// A loaded source file.
final class SourceFile {
  /// The filename used in diagnostics (e.g., `input.doxa`). When reading
  /// from stdin or a REPL, pass `<stdin>` or similar.
  final String filename;

  /// The full source text.
  final String text;

  /// Byte offsets at which each line starts (inclusive). `lineStarts[0]`
  /// is always 0. `lineStarts.length` is the number of lines.
  late final List<int> _lineStarts = _computeLineStarts(text);

  /// Creates a source file.
  SourceFile({required this.filename, required this.text});

  /// Resolve a byte offset to a 1-based (line, column) pair.
  ///
  /// If [offset] is past the end of input, returns the position of the
  /// last character plus one (so diagnostics at EOF still have a
  /// sensible location).
  ({int line, int column}) positionAt(int offset) {
    if (offset < 0) return (line: 1, column: 1);
    final bounded = offset > text.length ? text.length : offset;
    final lineIndex = _findLine(bounded);
    final column = bounded - _lineStarts[lineIndex] + 1;
    return (line: lineIndex + 1, column: column);
  }

  /// The full text of the line containing [offset] (without the
  /// trailing newline).
  String lineAt(int offset) {
    if (offset < 0) return text.isEmpty ? '' : _line(0);
    final bounded = offset > text.length ? text.length : offset;
    final idx = _findLine(bounded);
    return _line(idx);
  }

  /// Format a span as `filename:line:column`.
  String formatStart(DoxaSpan span) {
    if (span.isSynthetic) return '$filename:<synthesized>';
    final pos = positionAt(span.start);
    return '$filename:${pos.line}:${pos.column}';
  }

  int _findLine(int offset) {
    // Binary search on _lineStarts.
    var lo = 0;
    var hi = _lineStarts.length - 1;
    while (lo < hi) {
      final mid = lo + ((hi - lo + 1) >> 1);
      if (_lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  String _line(int index) {
    final start = _lineStarts[index];
    final end =
        index + 1 < _lineStarts.length
            ? _lineStarts[index + 1] - 1
            : text.length;
    // Strip a trailing \r if present (for CRLF line endings).
    if (end > start && text.codeUnitAt(end - 1) == 0x0D) {
      return text.substring(start, end - 1);
    }
    return text.substring(start, end);
  }

  static List<int> _computeLineStarts(String text) {
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        starts.add(i + 1);
      }
    }
    return starts;
  }
}
