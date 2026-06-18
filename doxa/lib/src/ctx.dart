/// Typing contexts for the bidirectional type checker.
///
/// A [Ctx] is a de-Bruijn-indexed list of types, paired with the matching
/// [Env] of values used to evaluate terms under this context. The value
/// at each binding is a fresh neutral `VNeutral(NVar(level))`, so the
/// type checker can descend under binders by extending both in lock-step
/// without ever needing to open a [Term] syntactically.
///
/// Keeping the context and the evaluation environment together in one
/// structure is what makes the "parallel lists" bookkeeping correct by
/// construction: [extend] adds a new type and the matching neutral value,
/// and [level] stays accurate without being tracked separately.
///
/// ## Inductive-type registry
///
/// Every [Ctx] also carries a reference to the program's inductive-type
/// registry as [dataDecls]. The registry is threaded unchanged across
/// every [extend] / [extendWith], binders don't affect which data decls
/// are in scope; those are determined at the top level. Checker frames
/// that need to resolve [TData] / [TConstr] references consult the
/// registry via [lookupData] / [lookupCtor].
///
/// The registry is optional in the [CNil] base case (defaults to empty)
/// so tests and kernel-only workflows don't need to plumb it.
library;

import 'env.dart';
import 'meta.dart';
import 'registry.dart';
import 'value.dart';

/// A typing context.
sealed class Ctx {
  /// Base constructor.
  const Ctx();

  /// The evaluation environment parallel to this context.
  Env get env;

  /// The de Bruijn level (= context depth).
  int get level;

  /// The inductive-type registry visible at this context.
  ///
  /// Identical across every binder, inductive declarations are
  /// top-level. Threaded through [extend] / [extendWith] unchanged.
  List<DataDecl> get dataDecls;

  /// The metavariable context, or null when metas are not
  /// in use. Identity-shared across every binder extension within a
  /// single typechecking session, all [Ctx]es produced by [extend] /
  /// [extendWith] from a root [CNil] see the same [MetaContext]
  /// instance and its mutations.
  ///
  /// Null when the kernel is used without metas (e.g. unit
  /// tests that don't exercise metavariables). The [TMeta] eval path
  /// yields a bare [NMeta] neutral without consulting the context,
  /// so null is safe at eval time; infer/check sites that need the
  /// context assert non-null and throw [StateError] with a clear
  /// diagnostic if it's missing.
  MetaContext? get metas;

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

  /// Extend the context with a new binding of [type]. The corresponding
  /// value in the environment is a fresh neutral at the current level.
  /// The [dataDecls] registry and [metas] reference are threaded
  /// through unchanged.
  Ctx extend(Value type) {
    final fresh = VNeutral(NVar(level));
    return CCons(type, fresh, env.extend(fresh), level + 1, this);
  }

  /// Extend the context with [type] and a specific [value] (rather than
  /// a fresh neutral). Used by the elaborator / CLI to bind top-level
  /// definitions to their concrete values.
  Ctx extendWith(Value type, Value value) =>
      CCons(type, value, env.extend(value), level + 1, this);

  /// Look up the type bound at de Bruijn [index].
  ///
  /// Throws [RangeError] if the index is out of range (kernel invariant
  /// violation, the elaborator should reject unbound names before they
  /// reach the checker).
  Value lookupType(int index) {
    var c = this;
    var i = index;
    while (true) {
      switch (c) {
        case CNil():
          throw RangeError('Ctx.lookupType($index) on depth $i: out of range');
        case CCons(:final type, :final rest):
          if (i == 0) return type;
          c = rest;
          i -= 1;
      }
    }
  }
}

/// The empty context.
final class CNil extends Ctx {
  /// The inductive-type registry for this context (possibly empty).
  @override
  final List<DataDecl> dataDecls;

  /// The top-level binding registry for this context (possibly empty).
  ///
  /// Top-level refs use [TTop(name)] which resolves via this map.
  /// Threaded into the parallel [env].
  final Map<String, TopBindingEntry> topBindings;

  /// The metavariable context for this elaboration, or null when
  /// metas are not in use.
  @override
  final MetaContext? metas;

  /// Creates the empty context with no registries.
  const CNil()
    : dataDecls = const <DataDecl>[],
      topBindings = const <String, TopBindingEntry>{},
      metas = null;

  /// Creates the empty context with the given [dataDecls] registry
  /// (and no top bindings). Kept for call-site compat.
  const CNil.withData(this.dataDecls)
    : topBindings = const <String, TopBindingEntry>{},
      metas = null;

  /// Creates the empty context with both registries populated.
  const CNil.withRegistries({
    required this.dataDecls,
    required this.topBindings,
    this.metas,
  });

  @override
  Env get env {
    if (dataDecls.isEmpty && topBindings.isEmpty) return const ENil();
    return ENil.withRegistries(dataDecls: dataDecls, topBindings: topBindings);
  }

  @override
  int get level => 0;
}

/// A context extended with a binding.
final class CCons extends Ctx {
  /// The type of the bound variable at index 0.
  final Value type;

  /// The value of the bound variable at index 0 in the parallel env.
  final Value value;

  /// The evaluation environment parallel to this context.
  @override
  final Env env;

  /// The current de Bruijn level.
  @override
  final int level;

  /// The outer context (indices 1, 2, ...).
  final Ctx rest;

  /// Creates a non-empty context.
  const CCons(this.type, this.value, this.env, this.level, this.rest);

  /// The registry threaded through from the base.
  @override
  List<DataDecl> get dataDecls => rest.dataDecls;

  /// The metavariable context threaded through from the base.
  @override
  MetaContext? get metas => rest.metas;
}
