/// Semantic metadata recorded during elaboration.
///
/// For every resolved identifier in the source, a [SemInfo] entry records
/// the resolved name, its kind, its type, and the declaration site span.
/// This is the shared dependency that powers the REPL's `:type`/`:show`,
/// the LSP's hover/go-to-definition/completion, and the website demo's
/// per-position type display.
library;

import 'surface.dart' show DoxaSpan;

/// The kind of an identifier's semantic resolution.
enum SemInfoKind {
  /// A locally-bound variable (lambda/Pi binder, let-binding).
  localVar,

  /// A top-level declaration (`val`, `fun`, `type`).
  topBinding,

  /// A data constructor (`zero`, `succ`, `nil`, `cons`, `refl`).
  constructor,

  /// An inductive type name (`Nat`, `List`, `Bool`, `Eq`).
  dataType,

  /// An implicit parameter inserted by the elaborator.
  implicitParam,

  /// A field projection (`e.field` on a record).
  fieldProj,
}

/// Metadata for a single identifier occurrence in the source.
final class SemInfo {
  /// The span of the identifier occurrence in the source.
  final DoxaSpan span;

  /// The resolved name as it appears at the definition site.
  final String name;

  /// What kind of entity this identifier resolved to.
  final SemInfoKind kind;

  /// Pretty-printed type of the resolved entity at this position.
  final String type;

  /// The span of the declaration site, when known.
  ///
  /// Null for synthetic local binders and implicit parameters.
  final DoxaSpan? defSpan;

  /// URI-like file path containing [defSpan] when it comes from an import.
  ///
  /// Null means the declaration belongs to the document being checked or is a
  /// compiler-provided declaration without source.
  final String? defFile;

  /// Creates a semantic-info entry for one identifier occurrence.
  const SemInfo({
    required this.span,
    required this.name,
    required this.kind,
    required this.type,
    this.defSpan,
    this.defFile,
  });

  /// Serialise this entry to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'span': {'start': span.start, 'end': span.end},
    'name': name,
    'kind': kind.name,
    'type': type,
    if (defSpan != null && !defSpan!.isSynthetic)
      'defSpan': {'start': defSpan!.start, 'end': defSpan!.end},
    if (defFile != null) 'defFile': defFile,
  };
}
