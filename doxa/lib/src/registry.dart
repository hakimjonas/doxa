/// The inductive-type registry.
///
/// A [DataDecl] captures everything the kernel needs to know about an
/// inductive type declaration, its parameter telescope, index telescope,
/// target sort, and list of constructor declarations. Each [CtorDecl]
/// captures an individual constructor's argument telescope and the
/// result-type indices it supplies to the inductive family.
///
/// ## Position-3 (preserved source) discipline
///
/// Each record carries a `source` field referencing the original surface
/// AST, [SDataKind] on [DataDecl], [SCtorDecl] on [CtorDecl]. The
/// checker MUST NOT read these fields; they exist to enable diagnostic-
/// grade error messages and future tooling (LSP, pretty printer) to
/// render the user's written form faithfully, the per-layer-ergonomics
/// principle (SPEC §6: honest errors).
///
/// ## Layer
///
/// This library sits between [surface.dart] + [term.dart] and
/// [ctx.dart] + [elab.dart]. Extracting it here (rather than keeping
/// the types inside [elab.dart]) lets [Ctx] carry a typed
/// `List<DataDecl>` without a cyclic import.
library;

import 'surface.dart';
import 'term.dart';

/// A single entry in a parameter, index, or constructor-argument telescope.
///
/// A telescope is a sequence of binders `(x1: T1, x2: T2, ..., xn: Tn)`
/// where each `Ti` may reference the preceding binders via de Bruijn
/// indices. Telescope entries carry name hints for diagnostics (same
/// discipline as `TLam.name` / `TPi.name`), and each entry's source
/// [span] is preserved so positivity / arity / mismatch diagnostics
/// can point at the exact source region.
///
/// The [type] Term is closed under the preceding entries: entry `i`'s
/// type may reference `TBound(j)` for any `j < i` (plus any outer
/// binders the whole telescope is nested inside).
final class TelescopeEntry {
  /// Source name hint (diagnostic only; does not participate in equality
  /// or conversion).
  final String? name;

  /// The binder's declared type, closed under preceding binders.
  final Term type;

  /// The source span of this binder's declaration.
  final DoxaSpan span;

  /// Creates a telescope entry.
  const TelescopeEntry(this.name, this.type, this.span);

  @override
  bool operator ==(Object other) =>
      other is TelescopeEntry &&
      other.name == name &&
      other.type == type &&
      other.span == span;

  @override
  int get hashCode => Object.hash('TelescopeEntry', name, type, span);

  @override
  String toString() =>
      name == null
          ? 'TelescopeEntry(_: $type)'
          : 'TelescopeEntry($name: $type)';
}

/// A telescope: an ordered sequence of [TelescopeEntry]s, each closed
/// under the preceding entries.
typedef Telescope = List<TelescopeEntry>;

/// An elaborated inductive-type declaration.
///
/// A [DataDecl] for `data Vec[A: Type] : Nat -> Type { ... }` has:
///
///   * [params]: `[A: TType(0)]`
///   * [indices]: `[_: TData("Nat", [])]`, closed under [params]
///   * [sort]: `TType(0)`
///   * [ctors]: the constructor records.
///
/// Indices and ctor arg telescopes are closed under all preceding
/// binders in the natural nesting order: params are outermost, then
/// indices (for the data type itself), and within a constructor, the
/// data type's params are the outermost binders (constructors don't
/// re-bind them; they reference them by de Bruijn index).
final class DataDecl {
  /// The inductive type's name.
  final String name;

  /// Parameter telescope.
  final Telescope params;

  /// Index telescope, closed under [params].
  final Telescope indices;

  /// Target sort, `TType(n)` or `TProp`.
  final Term sort;

  /// Constructor declarations in source order.
  final List<CtorDecl> ctors;

  /// Per-parameter covariance (from positivity analysis).
  ///
  /// `paramsCovariant[i]` is true iff the i-th parameter appears only
  /// in strictly-positive positions across every ctor's argument
  /// types. Covariant parameters allow **nested positivity**: a ctor
  /// arg of shape `T[X]`, where `T` is another inductive covariant
  /// in its first param, and `X` mentions the inductive being
  /// defined only positively, is accepted. Non-covariant parameters
  /// make `T[X]`-style nesting conservatively rejected.
  ///
  /// Same length as [params]. Empty list for non-parametric inductives.
  final List<bool> paramsCovariant;

  /// Preserved surface AST. The checker must not read this.
  final SDataKind source;

  /// The source span of the whole declaration.
  final DoxaSpan span;

  /// Creates a data declaration.
  const DataDecl({
    required this.name,
    required this.params,
    required this.indices,
    required this.sort,
    required this.ctors,
    required this.paramsCovariant,
    required this.source,
    required this.span,
  });
}

/// An elaborated constructor declaration.
///
/// For a constructor `vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n)`
/// of `Vec[A]`:
///
///   * [dataName]: `"Vec"`
///   * [name]: `"vcons"`
///   * [args]: `[(n: Nat), (_: A), (_: Vec A n)]`, each entry closed
///     under the data's [DataDecl.params] plus the preceding arg entries.
///   * [resultIndices]: `[succ n]`: the arguments the constructor
///     supplies for the data type's indices, closed under params and args.
///
/// [source] is the preserved surface AST (checker must not read).
final class CtorDecl {
  /// The parent inductive type's name.
  final String dataName;

  /// The constructor's own name.
  final String name;

  /// Argument telescope, closed under the data's params plus preceding args.
  final Telescope args;

  /// The index terms this constructor provides, closed under params + args.
  ///
  /// Must have the same length as the parent [DataDecl.indices]. Empty
  /// for non-indexed families.
  final List<Term> resultIndices;

  /// Preserved surface AST. The checker must not read this.
  final SCtorDecl source;

  /// The source span of this constructor declaration.
  final DoxaSpan span;

  /// Creates a constructor declaration.
  const CtorDecl({
    required this.dataName,
    required this.name,
    required this.args,
    required this.resultIndices,
    required this.source,
    required this.span,
  });
}
