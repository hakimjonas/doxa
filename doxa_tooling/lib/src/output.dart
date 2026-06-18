/// Structured check output model.
///
/// The checker already computes all the data (types, values, normal forms,
/// spans, errors). This model captures that data in a structured form
/// before it is serialised to JSON for the WASM entry point or CLI `--json`
/// flag, or rendered as human-readable text for the default CLI output.
library;

import 'dart:convert';

import 'package:doxa/src/sem_info.dart';
import 'package:doxa/src/surface.dart' show DoxaSpan;

/// The result of checking a Doxa source file.
sealed class CheckOutput {
  /// Base constructor.
  const CheckOutput();

  /// Serialise this result to a JSON-compatible map.
  Map<String, dynamic> toJson();

  /// Serialise this result to a JSON string.
  String toJsonString() => jsonEncode(toJson());
}

/// The source file checked successfully.
final class CheckSuccess extends CheckOutput {
  /// Per-declaration info for every user-written declaration (prelude
  /// entries are excluded).
  final List<DeclInfo> declarations;

  /// The total number of user declarations that were checked.
  final int count;

  /// Per-position semantic metadata for every identifier reference in
  /// the source, sorted by [SemInfo.span.start].
  ///
  /// Empty when metadata collection was not requested or the source
  /// had no identifier references (e.g. a parse error).
  final List<SemInfo> semInfo;

  /// Creates a success result.
  const CheckSuccess({
    required this.declarations,
    required this.count,
    this.semInfo = const [],
  });

  @override
  Map<String, dynamic> toJson() => {
    'status': 'success',
    'declarations': [for (final d in declarations) d.toJson()],
    'count': count,
    if (semInfo.isNotEmpty) 'semInfo': [for (final s in semInfo) s.toJson()],
  };
}

/// Per-declaration summary.
final class DeclInfo {
  /// The declared name.
  final String name;

  /// The declaration kind: `"val"`, `"fun"`, `"type"`, or `"data"`.
  final String kind;

  /// Pretty-printed type, or null for data-type declarations whose type
  /// is implicit from the `data` keyword.
  final String? type;

  /// Pretty-printed normal form (for `val` and `fun` declarations), or
  /// null when normalisation is not applicable (e.g. `type` aliases and
  /// `data` declarations).
  final String? normalForm;

  /// Source span of the declaration.
  final DoxaSpan span;

  /// Creates a declaration-info entry.
  const DeclInfo({
    required this.name,
    required this.kind,
    this.type,
    this.normalForm,
    required this.span,
  });

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind,
    if (type != null) 'type': type,
    if (normalForm != null) 'normalForm': normalForm,
    'span': {'start': span.start, 'end': span.end},
  };
}

/// The source file failed to check.
final class CheckFailure extends CheckOutput {
  /// The error kind, e.g. `"parse_error"`, `"type_mismatch"`,
  /// `"unresolved_name"`, etc.
  final String kind;

  /// 1-based line number of the error.
  final int line;

  /// 1-based column number of the error.
  final int column;

  /// For type mismatches, the expected type (pretty-printed).
  final String? expected;

  /// For type mismatches, the actual (inferred) type (pretty-printed).
  final String? actual;

  /// Full human-readable diagnostic message.
  final String message;

  /// Source span of the error, or null for errors that don't have a
  /// precise source location.
  final DoxaSpan? span;

  /// Creates a failure result.
  const CheckFailure({
    required this.kind,
    required this.line,
    required this.column,
    this.expected,
    this.actual,
    required this.message,
    this.span,
  });

  @override
  Map<String, dynamic> toJson() => {
    'status': 'failure',
    'kind': kind,
    'line': line,
    'column': column,
    if (expected != null) 'expected': expected,
    if (actual != null) 'actual': actual,
    'message': message,
    if (span != null) 'span': {'start': span!.start, 'end': span!.end},
  };
}
