/// Metavariable infrastructure.
///
/// A metavariable is a kernel-level placeholder for a term the elaborator
/// has yet to fill in, inserted at positions where the user elided an
/// argument (implicit args, omitted annotations, inferred motives).
/// The design follows the metavariable-context treatment in Kovács's
/// elaboration-zoo, Lean 4, and Coq.
///
/// Key properties:
///
///  * Each meta has an integer ID; [TMeta(id)] in `term.dart` and
///    [NMeta(id)] in `value.dart` refer to this ID.
///  * Entries are a sealed hierarchy ([MetaEntry]) currently holding
///    term-metas; level-metas can be added additively by extending
///    the sealed class with [LevelMetaEntry]-style variants, matching
///    the Lean 4 pattern (`Level.mvar` vs. `Expr.mvar` as distinct
///    constructors in the same meta-context).
///  * The meta-context is owned by the elaborator, NOT by the driver
///    loop. `_drive`'s invariant ("no Dart call to another semantic
///    function") is preserved because meta lookups are local reads on
///    the context's backing list.
///  * Mutation (assigning a solution to an unsolved meta) happens
///    only in the elaborator / unifier layer. Once solved, an entry
///    is never re-solved; the append-only-plus-solve-once invariant
///    makes snapshot/restore straightforward: record the
///    list length and the list of meta-ids that were solved in the
///    scope, then truncate + re-null on failure.
library;

import 'ctx.dart';
import 'proof_state.dart';
import 'surface.dart';
import 'sem_info.dart';
import 'term.dart';
import 'value.dart';

/// An entry in the metavariable context.
///
/// Sealed hierarchy, [LevelMetaEntry]-style variants can be added
/// alongside the existing [TermMetaEntry] branches without a union
/// dance. Each variant carries the minimum data needed for the
/// unifier to decide whether a solve is well-typed + well-scoped.
sealed class MetaEntry {
  /// The source span of the construct that allocated this meta, when one
  /// was recorded.
  ///
  /// The elaborator sets it for an implicit argument it inserts at an
  /// application site, so a diagnostic about the undetermined meta can
  /// point at the use rather than the enclosing declaration. Internal
  /// allocations leave it null.
  final DoxaSpan? span;

  /// Base constructor.
  const MetaEntry({this.span});

  /// True iff this meta has been assigned a solution.
  bool get isSolved;
}

/// An unsolved term-level metavariable.
///
/// Carries:
///
///  * [typeExpected]: the Value the solution must inhabit. The
///    unifier uses it both for type-check well-formedness of
///    candidate solutions and to drive motive inference.
///  * [localCtx]: the local binder context at the metavariable's
///    insertion site. Determines which free variables a valid
///    solution may mention (Kovács's "bound-variable pattern"
///    fragment plus Abel & Pientka pruning).
final class TermMetaUnsolved extends MetaEntry {
  /// The type the solution must inhabit.
  final Value typeExpected;

  /// The local context at the meta's insertion site.
  final Ctx localCtx;

  /// Creates an unsolved term-meta entry.
  const TermMetaUnsolved(this.typeExpected, this.localCtx, {super.span});

  @override
  bool get isSolved => false;

  @override
  String toString() => 'TermMetaUnsolved(at depth ${localCtx.level})';
}

/// A solved term-level metavariable.
///
/// The [solution] is a closed kernel [Term]; the unifier guarantees
/// it does not mention de Bruijn indices that would be out of scope
/// at the meta's original insertion site (pruning enforces this).
///
/// [typeExpected] is retained from the pre-solve entry so that
/// `_Infer(TMeta)` on a solved meta can return the expected type
/// directly rather than re-inferring the solution term. Re-inferring
/// the solution is problematic because pattern-unif solutions can
/// contain quoted stuck forms (e.g. `TMatch(null motive)`) that are
/// only well-typed in a specific check context, not standalone
/// infer. In Lean, Coq, and Agda, a meta's type is stored separately from
/// its solution; this mirrors that discipline.
final class TermMetaSolved extends MetaEntry {
  /// The solution term. Closed under the local context [localCtx]
  /// that was present at the meta's original insertion site.
  final Term solution;

  /// The type the solution inhabits, retained from the pre-solve
  /// [TermMetaUnsolved.typeExpected] so `_Infer(TMeta)` doesn't need
  /// to re-infer the solution term. `checkDeclResult` audits the
  /// solution against this type (and [localCtx]) at the declaration
  /// boundary, rejecting an ill-typed solution instead of storing it.
  final Value typeExpected;

  /// The local context at the meta's original insertion site
  /// preserved verbatim from the pre-solve [TermMetaUnsolved.localCtx].
  ///
  /// Free de-Bruijn indices in [solution] are interpreted under
  /// this context, NOT under whatever context a later call site
  /// carries. This mirrors Lean 4's discipline of attaching a local
  /// context to each metavariable declaration. Downstream scope-aware
  /// substitution reads [localCtx.level] to decide whether a caller's
  /// context supplies enough binders to admit the solution, and
  /// declines to substitute when it doesn't.
  final Ctx localCtx;

  /// Creates a solved term-meta entry.
  const TermMetaSolved(
    this.solution,
    this.typeExpected,
    this.localCtx, {
    super.span,
  });

  @override
  bool get isSolved => true;

  @override
  String toString() => 'TermMetaSolved($solution)';
}

/// The mutable metavariable context.
///
/// One instance is created per top-level typechecking session by the
/// elaborator. All [Env]s and [Ctx]es within that session share the
/// same instance by identity.
///
/// Thread-safety: the checker is single-threaded; no locking needed.
/// If Doxa ever gets a concurrent elaborator it will need to either
/// shard the context or add fine-grained locking.
final class MetaContext {
  /// The backing list. Index = meta ID. Append-only for new metas;
  /// individual entries mutate exactly once (unsolved → solved).
  final List<MetaEntry> _entries = <MetaEntry>[];

  /// Accumulated semantic metadata for identifier references during
  /// elaboration of the current declaration.
  ///
  /// Populated by the expression elaborator when this context's
  /// [MetaContext] is installed on the [Ctx] used during elaboration.
  /// Null by default; set to a mutable list to enable collection.
  List<SemInfo>? semInfos;

  /// Proof-state snapshots for `by { ... }` tactic blocks, recorded by
  /// the tactic elaborator as each block finishes.
  ///
  /// Mirrors the [semInfos] collection pattern: null by default; set
  /// to a mutable list by callers of `elabDecl` that want collection
  /// (the LSP pipeline). Each entry is an immutable snapshot, so the
  /// list is append-only and survives the solve-once mutation of the
  /// entries themselves.
  List<ProofStateBlock>? proofStateSink;

  /// Creates an empty metavariable context.
  MetaContext();

  /// The number of metas allocated in this context.
  int get length => _entries.length;

  /// Allocate a fresh unsolved term-meta and return its id.
  int freshTermMeta(Value typeExpected, Ctx localCtx, {DoxaSpan? span}) {
    final id = _entries.length;
    _entries.add(TermMetaUnsolved(typeExpected, localCtx, span: span));
    return id;
  }

  /// Look up the entry for [id]. Throws if [id] is out of range
  /// an out-of-range id at lookup time is a kernel invariant
  /// violation (TMeta(id) emitted without a corresponding entry).
  MetaEntry lookup(int id) {
    if (id < 0 || id >= _entries.length) {
      throw StateError(
        'MetaContext.lookup($id) out of range (length=${_entries.length})',
      );
    }
    return _entries[id];
  }

  /// True iff [id] has been solved.
  bool isSolved(int id) => lookup(id).isSolved;

  /// Return the solution term for [id]. Throws if unsolved.
  Term solutionOf(int id) {
    final entry = lookup(id);
    if (entry is! TermMetaSolved) {
      throw StateError(
        'MetaContext.solutionOf($id): meta is not solved (entry: $entry)',
      );
    }
    return entry.solution;
  }

  /// Solve [id] with [term]. Throws if already solved or if [id] is
  /// out of range. Enforces the solve-once invariant that makes
  /// snapshot/restore straightforward.
  void solve(int id, Term term) {
    final entry = lookup(id);
    if (entry is! TermMetaUnsolved) {
      throw StateError(
        'MetaContext.solve($id): already solved (entry: $entry)',
      );
    }
    _entries[id] = TermMetaSolved(
      term,
      entry.typeExpected,
      entry.localCtx,
      span: entry.span,
    );
  }

  @override
  String toString() {
    if (_entries.isEmpty) return 'MetaContext(empty)';
    final parts = <String>[];
    for (var i = 0; i < _entries.length; i++) {
      parts.add('?$i: ${_entries[i]}');
    }
    return 'MetaContext(${parts.join(', ')})';
  }

  /// Create a point-in-time snapshot of this context's state.
  MetaSnapshot snapshot() {
    final solved = <int, Term>{};
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i] is TermMetaSolved) {
        solved[i] = (_entries[i] as TermMetaSolved).solution;
      }
    }
    return MetaSnapshot(_entries.length, solved);
  }

  /// Restore this context to a previous snapshot state.
  void restore(MetaSnapshot snap) {
    while (_entries.length > snap.entriesLength) {
      _entries.removeLast();
    }
    for (var i = 0; i < _entries.length; i++) {
      final wasSolved = snap.solved.containsKey(i);
      final entry = _entries[i];
      if (wasSolved && entry is! TermMetaSolved) {
        final unsolved = entry as TermMetaUnsolved;
        _entries[i] = TermMetaSolved(
          snap.solved[i]!,
          unsolved.typeExpected,
          unsolved.localCtx,
          span: unsolved.span,
        );
      } else if (!wasSolved && entry is TermMetaSolved) {
        _entries[i] = TermMetaUnsolved(
          entry.typeExpected,
          entry.localCtx,
          span: entry.span,
        );
      }
    }
  }
}

/// A point-in-time capture of [MetaContext] state.
///
/// Records the entries-list length and, for each meta that was solved,
/// the solution term. On restore, entries are truncated to the recorded
/// length and each entry's solve state is matched to the snapshot.
final class MetaSnapshot {
  /// The length of the entries list at snapshot time.
  final int entriesLength;

  /// Meta id → solution term for each solved meta at snapshot time.
  final Map<int, Term> solved;

  /// Creates a snapshot.
  const MetaSnapshot(this.entriesLength, this.solved);
}

/// VMatch tier-1 variant of [inlineSolvedMetas]
/// that PRESERVES `TApp*(TMeta(id), σ)` subterms intact so
/// downstream [_substArmBody] (the scope-aware walker) can
/// interpret σ's TBound indices against the captured env instead
/// of pre-flattening them into the solution's λ-chain at a scope
/// that no longer matches the walker's actual env depth.
///
/// Why a separate function. The eager-inline variant
/// [inlineSolvedMetas] flattens `TApp*(TMeta, σ)` into
/// `TApp*(solution, σ)`, correct when the enclosing term stays
/// at the same scope, but wrong at VMatch tier-1 where the inlined
/// arm body continues to cross scope boundaries as nested VMatch
/// walks open with smaller envs. The scope-displacement shows up
/// as σ's TBound indices being reinterpreted under the wrong env.
///
/// By PRESERVING the `TApp*(TMeta, σ)` skeleton, tier-1's pass
/// leaves the scope-discipline decision to [_substArmBody]'s
/// `walkSpineArg`, which interprets each σ arg's TBound with
/// the correct threshold (walker-depth, not arm-binder-depth)
/// against the captured env.
///
/// Behavior spec:
///   * `TMeta(id)` bare (not inside a TApp chain): if solved,
///     substitute with `entry.solution`. If the solution itself
///     is another bare meta, recurse into it. This handles
///     const-approximation aux-metas, they're bare TMetas with
///     no spine, so no scope-displacement concern.
///   * `TApp*(TMeta(id), σ)`: LEAVE INTACT. Do not substitute
///     the TMeta head. Recurse into σ args structurally, σ may
///     contain its own bare TMetas or nested TMeta σ subterms,
///     which get processed on descent, but do NOT recurse into
///     `entry.solution`.
///   * All other term forms: structural recursion pass-through.
Term inlineSolvedBareMetas(Term term, MetaContext metas) {
  late final Term Function(Term) walk;
  walk = (t) {
    // Detect TApp*(TMeta, σ) at the top of this subterm. If
    // present, preserve the skeleton and recurse into σ args
    // only, DO NOT touch the TMeta head or its solution.
    final headSpine = _termHeadTMetaAndSpine(t);
    if (headSpine != null) {
      final id = headSpine.$1;
      final args = headSpine.$2;
      Term rebuilt = TMeta(id);
      for (final a in args) {
        rebuilt = TApp(rebuilt, walk(a));
      }
      return rebuilt;
    }
    return switch (t) {
      TMeta(:final id) => () {
        final entry = metas.lookup(id);
        if (entry is! TermMetaSolved) return t;
        // Bare TMeta: safe to substitute. The solution has no
        // spine at this position, so no scope-displacement.
        return walk(entry.solution);
      }(),
      TType() ||
      TUnknown() ||
      TSProp() ||
      TProp() ||
      TFree() ||
      TTop() ||
      TRec() ||
      TBound() => t,
      TApp(:final fn, :final arg) => TApp(walk(fn), walk(arg)),
      TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
        walk(domain),
        walk(codomain),
        name: name,
        icit: icit,
      ),
      TLam(:final domain, :final body, :final name, :final icit) => TLam(
        walk(domain),
        walk(body),
        name: name,
        icit: icit,
      ),
      TLet(:final domain, :final bound, :final body, :final name) => TLet(
        walk(domain),
        walk(bound),
        walk(body),
        name: name,
      ),
      TData(:final name, :final args) => TData(name, [
        for (final a in args) walk(a),
      ]),
      TConstr(:final dataName, :final ctorName, :final args) => TConstr(
        dataName,
        ctorName,
        [for (final a in args) walk(a)],
      ),
      TMatch(:final scrutinee, :final motive, :final cases) =>
        TMatch(walk(scrutinee), motive == null ? null : walk(motive), [
          for (final c in cases)
            TMatchCase(
              c.ctorName,
              c.nBinders,
              walk(c.body),
              c.binderNames,
              span: c.span,
            ),
        ]),
      TQuot(:final carrier, :final relation) => TQuot(
        walk(carrier),
        walk(relation),
      ),
      TQuotMk(:final arg) => TQuotMk(walk(arg)),
      TQuotLift(:final fn, :final proof) => TQuotLift(walk(fn), walk(proof)),
      TQuotSound(:final lhs, :final rhs, :final proof) => TQuotSound(
        walk(lhs),
        walk(rhs),
        walk(proof),
      ),
      TProj(:final expr, :final fieldName) => TProj(walk(expr), fieldName),
    };
  };
  return walk(term);
}

/// Helper (shared with [inlineSolvedBareMetas]): if [t] is
/// `TApp*(TMeta(id), a1, …, an)`, return `(id, [a1, …, an])` with
/// args in leftmost-first order. Otherwise return null.
///
/// Kept local rather than shared with eval.dart's
/// `_termHeadTMetaAndSpine`: meta.dart sits below eval.dart in the
/// dependency graph and cannot import from it.
(int, List<Term>)? _termHeadTMetaAndSpine(Term t) {
  final args = <Term>[];
  var cur = t;
  while (cur is TApp) {
    args.add(cur.arg);
    cur = cur.fn;
  }
  if (cur is! TMeta) return null;
  return (cur.id, args.reversed.toList());
}

/// Walk [term], replacing every solved `TMeta(id)` with its
/// solution term. Unsolved metas stay as `TMeta(id)`.
///
/// Motivation. [MetaContext] is per-declaration: solutions live inside
/// the elaborating declaration's private context. Once that declaration
/// finishes type-checking, any subsequent declaration that reads the
/// finished decl's stored term (via [TopEnv.toCtx]'s `eval`, or by
/// re-checking against the running `topEnv`) is driving a FRESH, empty
/// [MetaContext]: any `TMeta(id)` left in the stored term resolves via
/// `eval` to a stuck `VNeutral(NMeta(id))`, breaking convertibility even
/// though the meta was solved at the original elaboration time. The
/// symptom is e.g. "expected: match ?c { ... cons (?0 ?c h) ... }"
/// compared against a semantically-equal actual type, where each `?0`
/// in the print was a solved meta that was never inlined.
///
/// Strategy. One structural pass over [term]. When we hit a
/// `TMeta(id)`:
///
///   * unsolved → leave it in place; the caller's usual unsolved-meta
///     diagnostic path will surface it.
///   * solved   → recursively inline the solution term, so chains of
///     the form "?a solved to λ.?b, ?b solved to ..." all collapse
///     to meta-free terms in one pass.
///
/// No β-reduction. Solutions produced by the unifier (`_tryUnify`)
/// are λ-chains; the surrounding `TApp` spine at each use site
/// β-reduces when the resulting term is `eval`'d next.
///
/// Correctness. Substitution preserves typing: if `Γ ⊢ M : T` and
/// `M` contains `?id` solved with a well-typed `S`, then
/// `Γ ⊢ M[?id ↦ S] : T`. The solve-well-typed invariant is
/// established in `_tryUnify` via the scope check plus the
/// per-position Pi-domain λ-wrapping of the solution.
///
/// Termination. Pattern unification's occurs check rejects any
/// solution that would mention the meta it solves. Therefore solved
/// metas form a DAG keyed on solve-order; the recursive call in the
/// `TMeta` branch below terminates in linear time in total solution
/// size.
///
/// Note: at VMatch tier-1 arm-body inlining use
/// [inlineSolvedBareMetas] instead: it preserves
/// `TApp*(TMeta, σ)` for the scope-aware `_substArmBody` walker.
/// This function is the eager-flatten variant used everywhere
/// else (declaration finalization, solve-site pre-solve zonk).
Term inlineSolvedMetas(Term term, MetaContext metas, {int outerDepth = 0}) {
  Term walk(Term t, int depth) => switch (t) {
    TMeta(:final id) => () {
      final entry = metas.lookup(id);
      if (entry is! TermMetaSolved) return t;
      // Two stored shapes are legal. An open solution has a free TBound
      // referring into [entry.localCtx]; its root lives at that
      // declaration ambient. A closed solution has no free indices (its
      // own λ-chain binds the local context, or the unification spine),
      // so its root lives at ambient 0. Classifying by free indices and
      // walking each shape at its own root ambient is what makes a
      // nested solution's ambient independent of the use site's.
      final open = solutionHasFreeIndices(entry.solution);
      if (!_solutionAdmissibleAtDepth(entry, depth)) return t;
      final delta = depth - entry.localCtx.level;
      final shifted =
          open && delta != 0
              ? _shiftFreeIndices(entry.solution, delta)
              : entry.solution;
      return walk(shifted, open ? entry.localCtx.level : 0);
    }(),
    TType() ||
    TUnknown() ||
    TSProp() ||
    TProp() ||
    TFree() ||
    TTop() ||
    TRec() ||
    TBound() => t,
    TApp(:final fn, :final arg) => () {
      // Flat-right inlining: collect the right spine (arg chain)
      // iteratively to avoid stack overflow on deeply right-nested
      // chains like TApp(f, TApp(g, TApp(h, x))).
      final newFn = walk(fn, depth);
      final rights = <Term>[];
      var cur = arg;
      while (cur is TApp) {
        rights.add(cur.fn);
        cur = cur.arg;
      }
      var result = walk(cur, depth);
      for (final f in rights.reversed) {
        result = TApp(walk(f, depth), result);
      }
      return TApp(newFn, result);
    }(),
    TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
      walk(domain, depth),
      walk(codomain, depth + 1),
      name: name,
      icit: icit,
    ),
    TLam(:final domain, :final body, :final name, :final icit) => TLam(
      walk(domain, depth),
      walk(body, depth + 1),
      name: name,
      icit: icit,
    ),
    TLet(:final domain, :final bound, :final body, :final name) => TLet(
      walk(domain, depth),
      walk(bound, depth),
      walk(body, depth + 1),
      name: name,
    ),
    TData(:final name, :final args) => TData(name, [
      for (final a in args) walk(a, depth),
    ]),
    TConstr(:final dataName, :final ctorName, :final args) => TConstr(
      dataName,
      ctorName,
      [for (final a in args) walk(a, depth)],
    ),
    TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
      walk(scrutinee, depth),
      motive == null ? null : walk(motive, depth),
      [
        for (final c in cases)
          TMatchCase(
            c.ctorName,
            c.nBinders,
            walk(c.body, depth + c.nBinders),
            c.binderNames,
            span: c.span,
          ),
      ],
    ),
    TQuot(:final carrier, :final relation) => TQuot(
      walk(carrier, depth),
      walk(relation, depth),
    ),
    TQuotMk(:final arg) => TQuotMk(walk(arg, depth)),
    TQuotLift(:final fn, :final proof) => TQuotLift(
      walk(fn, depth),
      walk(proof, depth),
    ),
    TQuotSound(:final lhs, :final rhs, :final proof) => TQuotSound(
      walk(lhs, depth),
      walk(rhs, depth),
      walk(proof, depth),
    ),
    TProj(:final expr, :final fieldName) => TProj(walk(expr, depth), fieldName),
  };
  return walk(term, outerDepth);
}

/// Whether [term] mentions any `TMeta(_)`, solved or not.
///
/// Used after [inlineSolvedMetas] to decide whether a term is meta-free:
/// once the solved entries are inlined, any remaining `TMeta` is unsolved.
/// The elaborator uses it to reject an inferred type that still depends on an
/// undetermined metavariable instead of storing the raw id, which later
/// evaluation would read as a stuck neutral under a fresh meta context.
///
/// Iterative walk via an explicit stack, so depth does not consume Dart
/// call frames (SPEC §4.5).
bool termContainsMeta(Term term) => firstMetaIdIn(term) != null;

/// The id of the first `TMeta(id)` in [term], or null when the term
/// mentions none.
///
/// Walks the term with the same fixed child order as [termContainsMeta],
/// so the result is deterministic. After [inlineSolvedMetas], the id found
/// is an unsolved metavariable; the elaborator uses its recorded span to
/// point an undetermined-declaration diagnostic at the application that
/// left it unsolved.
int? firstMetaIdIn(Term term) {
  final stack = <Term>[term];
  while (stack.isNotEmpty) {
    final cur = stack.removeLast();
    switch (cur) {
      case TMeta(:final id):
        return id;
      case TType():
      case TUnknown():
      case TProp():
      case TSProp():
      case TBound():
      case TFree():
      case TTop():
      case TRec():
        break;
      case TApp(:final fn, :final arg):
        stack.add(fn);
        stack.add(arg);
      case TLam(:final domain, :final body):
        stack.add(domain);
        stack.add(body);
      case TPi(:final domain, :final codomain):
        stack.add(domain);
        stack.add(codomain);
      case TLet(:final domain, :final bound, :final body):
        stack.add(domain);
        stack.add(bound);
        stack.add(body);
      case TData(:final args):
        stack.addAll(args);
      case TConstr(:final args):
        stack.addAll(args);
      case TMatch(:final scrutinee, :final motive, :final cases):
        stack.add(scrutinee);
        if (motive != null) stack.add(motive);
        for (final c in cases) {
          stack.add(c.body);
        }
      case TQuot(:final carrier, :final relation):
        stack.add(carrier);
        stack.add(relation);
      case TQuotMk(:final arg):
        stack.add(arg);
      case TQuotLift(:final fn, :final proof):
        stack.add(fn);
        stack.add(proof);
      case TQuotSound(:final lhs, :final rhs, :final proof):
        stack.add(lhs);
        stack.add(rhs);
        stack.add(proof);
      case TProj(:final expr):
        stack.add(expr);
    }
  }
  return null;
}

/// Whether [solution] has a free de Bruijn index, i.e. one not bound by a
/// binder inside the solution itself.
///
/// This classifies a stored solution's shape. An open solution's free
/// indices refer into the meta's declaration-site `localCtx`, so its root
/// lives at `localCtx.level`. A closed solution (a λ-chain over the local
/// context or over a unification spine) has none, so its root lives at
/// ambient 0. [inlineSolvedMetas] and the declaration audit both use this
/// classification to choose the ambient level of the solution root.
bool solutionHasFreeIndices(Term solution) {
  final stack = <(Term, int)>[(solution, 0)];
  while (stack.isNotEmpty) {
    final (current, depth) = stack.removeLast();
    switch (current) {
      case TBound(:final index):
        if (index >= depth) return true;
      case TType() ||
          TUnknown() ||
          TSProp() ||
          TProp() ||
          TFree() ||
          TTop() ||
          TRec() ||
          TMeta():
        break;
      case TApp(:final fn, :final arg):
        stack.add((fn, depth));
        stack.add((arg, depth));
      case TPi(:final domain, :final codomain):
        stack.add((domain, depth));
        stack.add((codomain, depth + 1));
      case TLam(:final domain, :final body):
        stack.add((domain, depth));
        stack.add((body, depth + 1));
      case TLet(:final domain, :final bound, :final body):
        stack.add((domain, depth));
        stack.add((bound, depth));
        stack.add((body, depth + 1));
      case TData(:final args):
        for (final a in args) {
          stack.add((a, depth));
        }
      case TConstr(:final args):
        for (final a in args) {
          stack.add((a, depth));
        }
      case TMatch(:final scrutinee, :final motive, :final cases):
        stack.add((scrutinee, depth));
        if (motive != null) stack.add((motive, depth));
        for (final c in cases) {
          stack.add((c.body, depth + c.nBinders));
        }
      case TQuot(:final carrier, :final relation):
        stack.add((carrier, depth));
        stack.add((relation, depth));
      case TQuotMk(:final arg):
        stack.add((arg, depth));
      case TQuotLift(:final fn, :final proof):
        stack.add((fn, depth));
        stack.add((proof, depth));
      case TQuotSound(:final lhs, :final rhs, :final proof):
        stack.add((lhs, depth));
        stack.add((rhs, depth));
        stack.add((proof, depth));
      case TProj(:final expr):
        stack.add((expr, depth));
    }
  }
  return false;
}

/// Shift every free [TBound] in [term] by [shiftBy], preserving indices
/// bound inside the term.
///
/// Used when an open solution is substituted at a use site deeper than
/// its declaration site: a free index `i` at the declaration site becomes
/// `i + shiftBy` at the use site, where
/// `shiftBy = useSiteAmbient - localCtx.level`.
Term _shiftFreeIndices(Term term, int shiftBy) {
  if (shiftBy == 0) return term;
  Term walk(Term t, int depth) => switch (t) {
    TBound(:final index) when index >= depth => TBound(index + shiftBy),
    TBound() ||
    TType() ||
    TUnknown() ||
    TSProp() ||
    TProp() ||
    TFree() ||
    TTop() ||
    TRec() ||
    TMeta() => t,
    TApp(:final fn, :final arg) => TApp(walk(fn, depth), walk(arg, depth)),
    TPi(:final domain, :final codomain, :final name, :final icit) => TPi(
      walk(domain, depth),
      walk(codomain, depth + 1),
      name: name,
      icit: icit,
    ),
    TLam(:final domain, :final body, :final name, :final icit) => TLam(
      walk(domain, depth),
      walk(body, depth + 1),
      name: name,
      icit: icit,
    ),
    TLet(:final domain, :final bound, :final body, :final name) => TLet(
      walk(domain, depth),
      walk(bound, depth),
      walk(body, depth + 1),
      name: name,
    ),
    TData(:final name, :final args) => TData(name, [
      for (final a in args) walk(a, depth),
    ]),
    TConstr(:final dataName, :final ctorName, :final args) => TConstr(
      dataName,
      ctorName,
      [for (final a in args) walk(a, depth)],
    ),
    TMatch(:final scrutinee, :final motive, :final cases) => TMatch(
      walk(scrutinee, depth),
      motive == null ? null : walk(motive, depth),
      [
        for (final c in cases)
          TMatchCase(
            c.ctorName,
            c.nBinders,
            walk(c.body, depth + c.nBinders),
            c.binderNames,
            span: c.span,
          ),
      ],
    ),
    TQuot(:final carrier, :final relation) => TQuot(
      walk(carrier, depth),
      walk(relation, depth),
    ),
    TQuotMk(:final arg) => TQuotMk(walk(arg, depth)),
    TQuotLift(:final fn, :final proof) => TQuotLift(
      walk(fn, depth),
      walk(proof, depth),
    ),
    TQuotSound(:final lhs, :final rhs, :final proof) => TQuotSound(
      walk(lhs, depth),
      walk(rhs, depth),
      walk(proof, depth),
    ),
    TProj(:final expr, :final fieldName) => TProj(walk(expr, depth), fieldName),
  };
  return walk(term, 0);
}

/// Predicate: is [entry]'s solution usable at an occurrence whose ambient
/// context level is [ambientLevel]?
///
/// A closed solution is self-contained and usable anywhere. An open
/// solution's free indices point into [TermMetaSolved.localCtx], so it is
/// usable only where that whole context is in scope:
/// `ambientLevel >= entry.localCtx.level`. Below that the inliner leaves
/// the meta in place rather than shifting indices negative.
bool _solutionAdmissibleAtDepth(TermMetaSolved entry, int ambientLevel) {
  if (!solutionHasFreeIndices(entry.solution)) return true;
  return ambientLevel >= entry.localCtx.level;
}
