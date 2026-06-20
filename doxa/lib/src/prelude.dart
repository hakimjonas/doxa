/// Shared prelude loading for the Doxa kernel.
///
/// Provides the ambient prelude source ([preludeSource]), a cached
/// [loadPrelude] function, and the [PreludeData] type. All tools —
/// CLI, REPL, LSP, benchmark, profiler — use this module to avoid
/// duplicating the prelude source and loading logic.
library;
import 'package:rumil/rumil.dart';

import 'elab.dart'
    show
        TopEnv,
        TopBinding,
        DataDecl,
        DeclResult,
        checkDeclResult,
        elabDecl,
        mergeNamespace;
import 'parse.dart';
import 'surface.dart';

/// The Doxa prelude source (Eq + Acc). Keep in sync with
/// `lib/stdlib/prelude.doxa`.
const String preludeSource = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}

data Acc[A: Type] : (A -> A -> Prop) -> A -> Prop {
  acc_intro : (R: A -> A -> Prop) -> (x: A) -> ((y: A) -> R y x -> Acc A R y) -> Acc A R x;
}
''';

/// The cached result of loading the prelude.
final class PreludeData {
  final List<TopBinding> bindings;
  final List<DataDecl> dataDecls;
  final Map<String, Set<String>> namespaceBindings;

  const PreludeData(this.bindings, this.dataDecls, this.namespaceBindings);
}

/// The process-wide prelude cache. Elaborated once and reused across
/// all calls to [loadPrelude].
PreludeData? _preludeCache;

/// Load and cache the prelude.
///
/// The prelude is elaborated once and cached process-wide. Safe to
/// call multiple times — subsequent calls return the cached result.
/// Throws [StateError] if the prelude fails to parse or type-check,
/// which indicates a kernel bug (the prelude source is a fixed,
/// trusted constant).
PreludeData loadPrelude() {
  final cached = _preludeCache;
  if (cached != null) return cached;

  final r = parseProgram(preludeSource);
  final prog = switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() =>
      throw StateError(
        'prelude failed to parse; this is a kernel bug. '
        'lib/stdlib/prelude.doxa must stay in sync.',
      ),
  };

  var bindings = const <TopBinding>[];
  var dataDecls = const <DataDecl>[];
  var namespaceBindings = <String, Set<String>>{};

  for (final decl in prog.decls) {
    final env = TopEnv(bindings, dataDecls, const {}, namespaceBindings);
    final produced = elabDecl(env, decl);
    final runningData = [...dataDecls, ...produced.dataDecls];
    final finalized = checkDeclResult(
      TopEnv(bindings, runningData, const {}, namespaceBindings),
      produced,
    );
    bindings = [...bindings, ...finalized];
    dataDecls = runningData;
    namespaceBindings = mergeNamespace(
      namespaceBindings,
      produced.namespaceBindings,
    );
  }

  final result = PreludeData(bindings, dataDecls, namespaceBindings);
  _preludeCache = result;
  return result;
}
