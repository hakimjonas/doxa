/// Resolved imports reusable by fresh checks.
library;

import 'package:doxa/doxa.dart';

/// Bindings and namespace data supplied by the prelude and imported modules.
final class CachedImports {
  /// Bindings supplied by the prelude and imported modules.
  final List<TopBinding> bindings;

  /// Data declarations supplied by the prelude and imported modules.
  final List<DataDecl> dataDecls;

  /// Imported namespace entries.
  final Map<String, Set<String>> namespaceBindings;

  /// Imported typeclass entries.
  final Map<String, ClassInfo> classRegistry;

  /// Number of prelude bindings and data declarations.
  final int preludeDeclCount;

  /// Import source locations and resolution state.
  final ImportState importState;

  /// Creates a resolved import baseline.
  const CachedImports({
    required this.bindings,
    required this.dataDecls,
    required this.namespaceBindings,
    required this.classRegistry,
    required this.preludeDeclCount,
    required this.importState,
  });
}
