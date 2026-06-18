/// Environments mapping de Bruijn indices to semantic values.
///
/// [Env] is an immutable cons-list. `ENil` is the empty environment;
/// `ECons(head, tail)` prepends a new binding with `head` at de Bruijn
/// index 0 and `tail` holding the previously-visible bindings shifted
/// up by one.
///
/// Environments are shared by reference across closures. Never mutate
/// an [Env] in place: doing so would corrupt every closure that captured
/// it. This is why [Env] is sealed and its fields are `final`.
///
/// ## Inductive-type registry
///
/// Every [Env] carries a reference to the inductive-type registry via
/// [dataDecls]. The registry is identical across every binder, it is
/// determined at the top level and threaded through every [extend].
/// Closures inherit their captured Env, so [VRec] reductions fired
/// anywhere retain access to the registry they need.
///
/// The registry is stored here (on [Env]) rather than passed per-step
/// because closures persist across scopes and must carry their
/// registry reference intrinsically: this layer is the honest place
/// for it.
///
/// ## Top-level binding registry
///
/// Every [Env] additionally carries a [topBindings] map from name to
/// `(type, value)` pairs, the top-level bindings visible at this
/// env. References from within a body to a top-level binding use
/// [TTop(name)] at the kernel level, resolved via this map. Like
/// [dataDecls], this is threaded unchanged through every [extend]
/// (the set of top-level bindings doesn't change when a local binder
/// opens).
///
/// For co-recursive groups, the group's members
/// are installed in [topBindings] with `(type, VNeutral(NTop(name)))`
/// stubs before any body is checked, so self- and sibling-references
/// behave as stuck neutrals during check-time reduction. See
/// `checkDeclResult` in elab.dart.
library;

import 'registry.dart';
import 'value.dart';

/// A top-level binding's recorded type and value.
///
/// Pair type used in [Env.topBindings]. Named for clarity over a bare
/// `(Value, Value)` record, which would mix meanings at read sites.
final class TopBindingEntry {
  /// The binding's type.
  final Value type;

  /// The binding's value. For ordinary (non-recursive) bindings this
  /// is the fully-evaluated body. For co-recursive group members
  /// during their own check, it's a [VNeutral(NTop(name))] stub.
  final Value value;

  /// For a structurally-recursive `fun`, the de-Bruijn position (in
  /// left-to-right application order, counting ALL parameters including
  /// type params) of the designated decreasing argument, i.e. the
  /// first explicit value parameter (SPEC §8.6). Null for non-recursive
  /// bindings (`val`, `type`, recursors, non-recursive `fun`).
  ///
  /// When non-null, evaluating `TTop(name)` yields a guarded [VFun]
  /// instead of the raw [value]: the function stays stuck until its
  /// decreasing argument is a canonical constructor, mirroring CIC's
  /// `fix` reduction rule. [recArity] is the total
  /// parameter count the function's lambda chain expects.
  final int? recDecreasingArg;

  /// The total parameter count of a recursive `fun`'s lambda chain
  /// (type params + value params). Null iff [recDecreasingArg] is null.
  final int? recArity;

  /// Creates a top-binding entry. [recDecreasingArg]/[recArity] are set
  /// only for structurally-recursive `fun`s (see [recDecreasingArg]).
  const TopBindingEntry(
    this.type,
    this.value, {
    this.recDecreasingArg,
    this.recArity,
  });
}

/// An immutable environment of de-Bruijn-indexed values.
sealed class Env {
  /// Base constructor.
  const Env();

  /// The inductive-type registry visible at this context.
  ///
  /// Threaded through [extend] unchanged: inductive declarations are
  /// top-level, so binders don't change which are in scope. Consumers
  /// use [lookupData] / [lookupCtor] to resolve references.
  List<DataDecl> get dataDecls;

  /// The top-level binding registry visible at this context.
  /// Maps binding name → (type, value).
  ///
  /// Threaded through [extend] unchanged for the same reason as
  /// [dataDecls]: top-level scope doesn't move under local binders.
  /// Consumer is the [TTop] eval case in eval.dart, which resolves
  /// [TTop(name)] by map lookup.
  Map<String, TopBindingEntry> get topBindings;

  /// The number of bindings visible. `ENil.depth == 0`;
  /// `ECons(_, tail).depth == tail.depth + 1`.
  ///
  /// Cached so that `depth` is O(1); used by `_Quote`'s fast path
  /// for closures whose bodies are already in normal form, checking
  /// that the closure's captured depth matches the current quote
  /// level is the invariant that makes body reuse safe.
  int get depth;

  /// Prepend [value] as the new index-0 binding.
  Env extend(Value value) => ECons(value, this);

  /// Return a new [Env] with [topBindings] augmented by [additional].
  /// Existing entries with the same keys in [additional] are
  /// overwritten (e.g. to replace a stub with a real value once a
  /// co-recursive group's check completes).
  ///
  /// The local-binder structure ([ECons] chain) is preserved; only
  /// the top-binding map changes. Future [extend] calls continue
  /// threading the new map.
  Env withTopBindings(Map<String, TopBindingEntry> additional);

  /// Look up the value at de Bruijn index [index].
  ///
  /// Throws [RangeError] if [index] is out of bounds for this environment,
  /// which indicates a kernel invariant violation (an unbound de Bruijn
  /// index reached evaluation) rather than a user error.
  Value lookup(int index) {
    var env = this;
    var i = index;
    while (true) {
      switch (env) {
        case ENil():
          throw RangeError(
            'Env.lookup($index) on depth $i: index out of bounds. '
            'This indicates a kernel invariant violation (open term '
            'reached evaluation).',
          );
        case ECons(:final head, :final tail):
          if (i == 0) return head;
          env = tail;
          i -= 1;
      }
    }
  }

  /// Look up an inductive-type declaration by name, or null if absent.
  DataDecl? lookupData(String name) {
    for (final d in dataDecls) {
      if (d.name == name) return d;
    }
    return null;
  }

  /// Look up a constructor by its parent data name and its own name,
  /// or null if absent.
  CtorDecl? lookupCtor(String dataName, String ctorName) {
    final data = lookupData(dataName);
    if (data == null) return null;
    for (final c in data.ctors) {
      if (c.name == ctorName) return c;
    }
    return null;
  }

  /// Look up a top-level binding by name, or null if absent.
  /// Used by the [TTop(name)] eval case.
  TopBindingEntry? lookupTop(String name) => topBindings[name];
}

/// The empty environment.
final class ENil extends Env {
  /// The inductive-type registry for this environment (possibly empty).
  @override
  final List<DataDecl> dataDecls;

  /// The top-level binding registry (possibly empty).
  @override
  final Map<String, TopBindingEntry> topBindings;

  /// Creates the empty environment with no data decls and no top
  /// bindings.
  const ENil()
    : dataDecls = const <DataDecl>[],
      topBindings = const <String, TopBindingEntry>{};

  /// Creates the empty environment with the given registries.
  const ENil.withRegistries({
    required this.dataDecls,
    required this.topBindings,
  });

  /// Creates the empty environment with the given [dataDecls] registry
  /// and an empty top-binding map. Kept for call-site compat.
  const ENil.withData(this.dataDecls)
    : topBindings = const <String, TopBindingEntry>{};

  @override
  int get depth => 0;

  @override
  Env withTopBindings(Map<String, TopBindingEntry> additional) =>
      ENil.withRegistries(
        dataDecls: dataDecls,
        topBindings: {...topBindings, ...additional},
      );
}

/// An environment prepending [head] at index 0 over [tail].
final class ECons extends Env {
  /// The value at de Bruijn index 0.
  final Value head;

  /// The remaining environment (indices 1, 2, ...).
  final Env tail;

  @override
  final int depth;

  /// Creates a non-empty environment.
  ECons(this.head, this.tail) : depth = tail.depth + 1;

  /// The registry threaded through from [tail].
  @override
  List<DataDecl> get dataDecls => tail.dataDecls;

  /// The top-binding registry threaded through from [tail].
  @override
  Map<String, TopBindingEntry> get topBindings => tail.topBindings;

  /// Return a new [ECons] whose [tail] has the augmented top-binding
  /// map. This preserves the local-binder structure (the [head] is
  /// identity) while threading the new top bindings through [tail].
  @override
  Env withTopBindings(Map<String, TopBindingEntry> additional) =>
      ECons(head, tail.withTopBindings(additional));
}
