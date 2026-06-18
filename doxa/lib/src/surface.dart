/// Surface AST for Doxa.
///
/// Produced by `parse.dart`, consumed by `elab.dart`.
///
/// ## Span discipline
///
/// Every [SExpr] and [SDecl] carries a [DoxaSpan], a byte-offset range
/// into the source text. The AST node shapes themselves are the sealed
/// [SExprKind] and [SDeclKind] hierarchies, which are pure structure
/// with no position data. The wrappers [SExpr] and [SDecl] pair a kind
/// with its span.
///
/// This mirrors the rust-analyzer kind/wrapper pattern: the kind is what
/// it is, the wrapper is where it is. Transformations that preserve shape
/// preserve span by construction (see [SExpr.withKind]). Equality
/// comparisons of AST shape work via `.kind` and ignore spans.
library;

// ---------------------------------------------------------------------------
// Spans
// ---------------------------------------------------------------------------

/// A byte-offset range into the source string.
///
/// [start] is inclusive, [end] is exclusive. Line and column are resolved
/// at error-formatting time from the original source, not stored here.
final class DoxaSpan {
  /// The inclusive start offset.
  final int start;

  /// The exclusive end offset.
  final int end;

  /// Creates a span.
  const DoxaSpan(this.start, this.end);

  /// The length of this span in bytes.
  int get length => end - start;

  /// A synthetic span with no source backing.
  ///
  /// Used for AST nodes introduced by elaboration (e.g. desugared Pi
  /// wrappers on `fun` declarations) that do not correspond to a literal
  /// region of source text.
  static const DoxaSpan synthetic = DoxaSpan(-1, -1);

  /// True if this span is synthetic (has no source backing).
  bool get isSynthetic => start < 0;

  @override
  bool operator ==(Object other) =>
      other is DoxaSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash('DoxaSpan', start, end);

  @override
  String toString() =>
      isSynthetic ? 'DoxaSpan(synthetic)' : 'DoxaSpan($start..$end)';
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// The shape of a surface expression (position-free).
sealed class SExprKind {
  /// Base constructor.
  const SExprKind();
}

/// An identifier reference: `x`, `price`, `Nat`.
final class SIdentKind extends SExprKind {
  /// The identifier name.
  final String name;

  /// Creates an identifier.
  const SIdentKind(this.name);

  @override
  bool operator ==(Object other) => other is SIdentKind && other.name == name;

  @override
  int get hashCode => Object.hash('SIdentKind', name);

  @override
  String toString() => 'SIdentKind($name)';
}

/// A qualified name: `<qualifier>.<name>`.
///
/// Produced by the parser for source forms like `Nat.rec` or
/// `Map.Inner.foo`. The qualifier is itself an [SExpr], typically
/// an [SIdentKind] or another [SDotKind] (nested dots parse as a
/// left-folded chain via a postfix `.ident` star).
///
/// Semantics: the elaborator flattens a fully-dotted qualifier chain
/// to its literal string form and resolves as a top-level name. This
/// is the "dot = type-associated name" convention: `Nat.rec` is looked
/// up as the top-level binding named
/// `"Nat.rec"`. Only literal lookup is supported.
final class SDotKind extends SExprKind {
  /// The left-hand side of the dot (the qualifier).
  final SExpr qualifier;

  /// The right-hand side of the dot (the field / member name).
  final String name;

  /// Creates a dotted reference.
  const SDotKind(this.qualifier, this.name);

  @override
  bool operator ==(Object other) =>
      other is SDotKind && other.qualifier == qualifier && other.name == name;

  @override
  int get hashCode => Object.hash('SDotKind', qualifier, name);

  @override
  String toString() => 'SDotKind($qualifier, $name)';
}

/// A universe reference: `Type` (level inferred) or `Type k`.
final class STypeKind extends SExprKind {
  /// The explicit universe level, or null for "infer it."
  ///
  /// A level-less `Type` defaults to 0 during elaboration.
  final int? level;

  /// Creates a universe reference.
  const STypeKind(this.level);

  @override
  bool operator ==(Object other) => other is STypeKind && other.level == level;

  @override
  int get hashCode => Object.hash('STypeKind', level);

  @override
  String toString() => level == null ? 'STypeKind' : 'STypeKind($level)';
}

/// The `Prop` sort (v2). A single value, Prop takes no level.
final class SPropKind extends SExprKind {
  /// Creates the Prop reference.
  const SPropKind();

  @override
  bool operator ==(Object other) => other is SPropKind;

  @override
  int get hashCode => Object.hash('SPropKind', 0);

  @override
  String toString() => 'SPropKind';
}

/// A function application: `f(x)`.
///
/// Multi-argument applications `f(x, y)` desugar during parsing into
/// nested [SAppKind]s: `SApp(SApp(f, x), y)`.
final class SAppKind extends SExprKind {
  /// The function expression.
  final SExpr fn;

  /// The argument.
  final SExpr arg;

  /// Creates an application.
  const SAppKind(this.fn, this.arg);

  @override
  bool operator ==(Object other) =>
      other is SAppKind && other.fn == fn && other.arg == arg;

  @override
  int get hashCode => Object.hash('SAppKind', fn, arg);

  @override
  String toString() => 'SAppKind($fn, $arg)';
}

/// A lambda abstraction: `(x: A) => body` or `(x) => body`.
///
/// The domain annotation is optional. When absent (`(x) => body`), the
/// lambda only elaborates in check mode against an explicit `VPi`, whose
/// domain supplies the parameter type (SPEC §5.1 "only in check mode").
final class SLamKind extends SExprKind {
  /// The parameter name.
  final String param;

  /// The parameter's type annotation, or null when unannotated.
  final SExpr? domain;

  /// The body.
  final SExpr body;

  /// Creates a lambda.
  const SLamKind(this.param, this.domain, this.body);

  @override
  bool operator ==(Object other) =>
      other is SLamKind &&
      other.param == param &&
      other.domain == domain &&
      other.body == body;

  @override
  int get hashCode => Object.hash('SLamKind', param, domain, body);

  @override
  String toString() => 'SLamKind($param, $domain, $body)';
}

/// A local let-binding: `let x: T = e1 in e2` or `let x = e1 in e2`
/// (v2). The type annotation is optional, when absent, elaboration
/// infers the type from the bound expression.
final class SLetKind extends SExprKind {
  /// The name of the bound variable.
  final String param;

  /// The optional type annotation.
  final SExpr? domain;

  /// The bound expression.
  final SExpr bound;

  /// The body. May reference [param] as a free variable (elaborated
  /// into a de Bruijn index pointing at the let's binder).
  final SExpr body;

  /// Creates a let-binding.
  const SLetKind(this.param, this.domain, this.bound, this.body);

  @override
  bool operator ==(Object other) =>
      other is SLetKind &&
      other.param == param &&
      other.domain == domain &&
      other.bound == bound &&
      other.body == body;

  @override
  int get hashCode => Object.hash('SLetKind', param, domain, bound, body);

  @override
  String toString() => 'SLetKind($param, ${domain ?? "_"}, $bound, $body)';
}

/// A dependent function type: `(x: A) -> B`, or a non-dependent arrow
/// `A -> B` (when [param] is null).
final class SPiKind extends SExprKind {
  /// The parameter name, or null for a non-dependent arrow.
  final String? param;

  /// The domain type.
  final SExpr domain;

  /// The codomain. Uses [param] as a free variable if this is dependent.
  final SExpr codomain;

  /// Creates a Pi type.
  const SPiKind(this.param, this.domain, this.codomain);

  @override
  bool operator ==(Object other) =>
      other is SPiKind &&
      other.param == param &&
      other.domain == domain &&
      other.codomain == codomain;

  @override
  int get hashCode => Object.hash('SPiKind', param, domain, codomain);

  @override
  String toString() => 'SPiKind($param, $domain, $codomain)';
}

/// A pattern-match expression.
///
/// `match scrutinee ('returning' motive)? '{' case* '}'`
///
/// * [scrutinee]: the expression being examined.
/// * [motive]: optional explicit motive annotation (the `returning` clause).
///   When null, the elaborator infers it from the expected type via the
///   expected type.
/// * [cases]: the case arms in source order. Each is either an
///   [SMatchCase] (a ctor pattern with binders) or an [SWildcardCase].
///   Arms take no separator, `case` serves as its own terminator. See
///   SYNTAX.md's note on why this diverges from `data` ctor lists (where
///   `;` is grammatically required).
final class SMatchKind extends SExprKind {
  /// The scrutinee.
  final SExpr scrutinee;

  /// Optional explicit motive (the `returning P` clause).
  final SExpr? motive;

  /// The case arms in source order.
  final List<SMatchCaseArm> cases;

  /// Creates a match expression.
  const SMatchKind(this.scrutinee, this.motive, this.cases);

  @override
  bool operator ==(Object other) =>
      other is SMatchKind &&
      other.scrutinee == scrutinee &&
      other.motive == motive &&
      _listEq(other.cases, cases);

  @override
  int get hashCode =>
      Object.hash('SMatchKind', scrutinee, motive, Object.hashAll(cases));

  @override
  String toString() =>
      motive == null
          ? 'SMatchKind($scrutinee, $cases)'
          : 'SMatchKind($scrutinee returning $motive, $cases)';
}

/// A single case arm in a match expression. Sealed: exactly
/// [SMatchCase] (ctor pattern) or [SWildcardCase].
sealed class SMatchCaseArm {
  /// Base constructor.
  const SMatchCaseArm();

  /// The arm's source span (covers `case ... => body`).
  DoxaSpan get span;

  /// The arm's right-hand side.
  SExpr get body;
}

/// A constructor case arm: `case <ctor> <binder>* => body`.
///
/// [ctor] is the constructor name as it appears in source (elaboration
/// resolves it against the scrutinee's type). [binders] are the pattern
/// variable names, one per constructor argument. Underscore binders
/// (`_`) are allowed and stored literally as `"_"`, elaboration treats
/// them as unused but still introduces the binder slot.
final class SMatchCase extends SMatchCaseArm {
  /// The constructor name.
  final String ctor;

  /// The pattern binders, in left-to-right order.
  final List<String> binders;

  @override
  final SExpr body;

  @override
  final DoxaSpan span;

  /// Creates a ctor case arm.
  const SMatchCase(this.ctor, this.binders, this.body, this.span);

  @override
  bool operator ==(Object other) =>
      other is SMatchCase &&
      other.ctor == ctor &&
      _listEq(other.binders, binders) &&
      other.body == body &&
      other.span == span;

  @override
  int get hashCode =>
      Object.hash('SMatchCase', ctor, Object.hashAll(binders), body, span);

  @override
  String toString() => 'SMatchCase($ctor ${binders.join(' ')} => $body)';
}

/// A wildcard case arm: `case _ => body`. Matches any residual
/// constructor. Semantically equivalent to providing a case for every
/// unlisted constructor; at elaboration time it makes the coverage
/// check pass with whatever ctors weren't explicitly named.
final class SWildcardCase extends SMatchCaseArm {
  @override
  final SExpr body;

  @override
  final DoxaSpan span;

  /// Creates a wildcard case arm.
  const SWildcardCase(this.body, this.span);

  @override
  bool operator ==(Object other) =>
      other is SWildcardCase && other.body == body && other.span == span;

  @override
  int get hashCode => Object.hash('SWildcardCase', body, span);

  @override
  String toString() => 'SWildcardCase(_ => $body)';
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A surface expression: a [SExprKind] paired with a source [DoxaSpan].
///
/// Equality includes both kind and span so that round-trip tests (parse
/// → serialize → parse) can be exact. To compare ignoring spans, compare
/// `.kind` directly.
final class SExpr {
  /// The structural shape of this expression.
  final SExprKind kind;

  /// The source span covering this expression.
  final DoxaSpan span;

  /// Creates a spanned expression.
  const SExpr(this.kind, this.span);

  /// Create a new [SExpr] with a different [kind] but the same [span].
  SExpr withKind(SExprKind newKind) => SExpr(newKind, span);

  @override
  bool operator ==(Object other) =>
      other is SExpr && other.kind == kind && other.span == span;

  @override
  int get hashCode => Object.hash('SExpr', kind, span);

  @override
  String toString() => 'SExpr($kind @ $span)';
}

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

/// The shape of a top-level declaration (position-free).
sealed class SDeclKind {
  /// Base constructor.
  const SDeclKind();

  /// The bound name.
  String get name;
}

/// A value binding: `val x: T = e` or `val x = e`.
final class SValKind extends SDeclKind {
  @override
  final String name;

  /// The optional type annotation.
  final SExpr? type;

  /// The bound expression.
  final SExpr body;

  /// Creates a val declaration.
  const SValKind(this.name, this.type, this.body);

  @override
  bool operator ==(Object other) =>
      other is SValKind &&
      other.name == name &&
      other.type == type &&
      other.body == body;

  @override
  int get hashCode => Object.hash('SValKind', name, type, body);

  @override
  String toString() => 'SValKind($name, $type, $body)';
}

/// A type alias: `type N = T`.
final class STypeAliasKind extends SDeclKind {
  @override
  final String name;

  /// The aliased type expression.
  final SExpr body;

  /// Creates a type alias.
  const STypeAliasKind(this.name, this.body);

  @override
  bool operator ==(Object other) =>
      other is STypeAliasKind && other.name == name && other.body == body;

  @override
  int get hashCode => Object.hash('STypeAliasKind', name, body);

  @override
  String toString() => 'STypeAliasKind($name, $body)';
}

/// One member of a mutual `data` block: a data-kind plus the source
/// span of this specific member.
///
/// Exists because the "kind has no position data; wrapper does"
/// discipline from this file's header means [SDataKind] itself
/// cannot carry a span, but a mutual block needs per-member spans
/// for precise positivity / shape diagnostics (SPEC §6). This
/// wrapper is the named analogue of [SCtorDecl] for the block
/// context, kind + span, sitting inside the containing block kind.
final class SDataBlockMember {
  /// The data declaration.
  final SDataKind data;

  /// This member's source span (from the `data` or `and data` keyword
  /// through the closing `}` of its ctor list).
  final DoxaSpan span;

  /// Creates a block-member wrapper.
  const SDataBlockMember(this.data, this.span);

  @override
  String toString() => 'SDataBlockMember(${data.name} @ $span)';
}

/// A block of mutually-declared `data` decls:
/// `data A ... and data B ... and data C ...`.
///
/// All data names in the block are in scope during every ctor's
/// elaboration, so ctors of A can mention B and vice versa.
/// Positivity is checked across the whole mutual set: a ctor's arg
/// type may not mention ANY of the block's names in a strictly-
/// negative position.
///
/// Single `data` decls (with no `and`) parse as `SDataKind` directly,
/// not wrapped in this block type, mirroring how `fun` / `SFunKind`
/// and `SFunBlockKind` relate.
final class SDataBlockKind extends SDeclKind {
  /// The block's members (≥ 1; the block form is only emitted by the
  /// parser when `and data` chains produce ≥ 2).
  final List<SDataBlockMember> members;

  /// Creates a mutual data block.
  const SDataBlockKind(this.members);

  /// The first name in the block (for duplicate-decl diagnostics).
  @override
  String get name => members.first.data.name;

  @override
  String toString() =>
      'SDataBlockKind([${members.map((m) => m.data.name).join(', ')}])';
}

/// One member of a mutual `fun` block: a fun-kind plus the source
/// span of this specific member. Same discipline as [SDataBlockMember].
final class SFunBlockMember {
  /// The function declaration.
  final SFunKind fun;

  /// This member's source span.
  final DoxaSpan span;

  /// Creates a block-member wrapper.
  const SFunBlockMember(this.fun, this.span);

  @override
  String toString() => 'SFunBlockMember(${fun.name} @ $span)';
}

/// A block of mutually-declared `fun`s: `fun f ... and fun g ... and fun h ...`.
///
/// All names in the block are in scope during each body's elaboration
/// Recursion, self or mutual, is accepted
/// when the structural-recursion check passes (see
/// `NonStructuralRecursion` in elab.dart): every recursive call must
/// pass a strict sub-term of the caller's designated decreasing
/// argument. Blocks produce a [CorecursiveGroup] which the CLI
/// consumes to pre-scope the members in Ctx before checking any body.
final class SFunBlockKind extends SDeclKind {
  /// The block's members (≥ 1).
  final List<SFunBlockMember> members;

  /// Creates a mutual fun block.
  const SFunBlockKind(this.members);

  /// The first name in the block is the block's representative name
  /// (for duplicate-decl checking at the block-start span); callers
  /// iterate over .members for the full member list.
  @override
  String get name => members.first.fun.name;

  @override
  String toString() =>
      'SFunBlockKind([${members.map((m) => m.fun.name).join(', ')}])';
}

/// A function declaration: `fun f[A: Type](x: A): A = x`.
///
/// Desugars during elaboration to an `SValKind` whose type is the
/// implied Pi over type params and value params, and whose body is the
/// nested lambdas over the same.
final class SFunKind extends SDeclKind {
  @override
  final String name;

  /// Type parameters, each with an optional kind annotation and an
  /// icity flag. Explicit type params are written
  /// `[A: Type]`; implicit type params are written `{A: Type}`.
  /// Both may be mixed in sequence: `fun f[A: Type]{B: Type}(...)`
  /// is `A` explicit then `B` implicit.
  final List<SFunTypeParam> typeParams;

  /// Value parameters, each with a required type annotation.
  final List<(String, SExpr)> params;

  /// The declared return type.
  final SExpr returnType;

  /// The body.
  final SExpr body;

  /// Creates a fun declaration.
  const SFunKind(
    this.name,
    this.typeParams,
    this.params,
    this.returnType,
    this.body,
  );

  @override
  String toString() =>
      'SFunKind($name, typeParams: $typeParams, params: $params, '
      'returnType: $returnType, body: $body)';
}

/// A single type-parameter entry on a `fun` declaration.
///
/// Carries the name, the optional kind annotation, and the icity
/// flag (explicit for `[A: Type]` or implicit for `{A: Type}`).
final class SFunTypeParam {
  /// The parameter's source name.
  final String name;

  /// Optional kind annotation (`Type`, `Type 1`, etc.). Null when
  /// the user wrote `[A]` / `{A}` without a colon.
  final SExpr? kind;

  /// `true` iff the parameter was written with `{…}` syntax.
  final bool isImplicit;

  /// Creates a type-parameter entry.
  const SFunTypeParam(this.name, this.kind, {required this.isImplicit});

  @override
  String toString() {
    final brackets =
        isImplicit
            ? '{$name${kind == null ? "" : ": $kind"}}'
            : '[$name${kind == null ? "" : ": $kind"}]';
    return brackets;
  }
}

/// An inductive type declaration: `data Name[params] : indices -> sort { ctors }`.
///
/// Examples (SPEC §8.4):
///
/// ```
/// data Nat : Type { zero : Nat; succ : Nat -> Nat }
/// data List[A: Type] : Type { nil : List[A]; cons : A -> List[A] -> List[A] }
/// data Vec[A: Type] : Nat -> Type {
///   vnil  : Vec[A] zero
///   vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n)
/// }
/// ```
///
/// [typeParams] is the parameter telescope (`[A: Type, ...]`).
/// [indices] is the list of index types appearing before the target sort
/// (for `Vec`, `[Nat]`; for parametric-only types like `List`, empty).
/// [sort] is the universe the family lives in (`Type`, `Type 1`, `Prop`).
/// [ctors] is the list of constructor declarations in source order.
///
/// Each [SCtorDecl] stores its declared type as an [SExpr]. Elaboration
/// decomposes that arrow structure into an argument telescope plus result
/// indices (see `DataDecl` and `CtorDecl` in `elab.dart`).
final class SDataKind extends SDeclKind {
  @override
  final String name;

  /// Parameter telescope, each with an optional kind annotation.
  final List<(String, SExpr?)> typeParams;

  /// The full "indices -> sort" expression written after `:`.
  ///
  /// For a non-indexed family this is just the sort (`Type`, `Type 1`,
  /// `Prop`). For an indexed family it is a Pi chain whose codomain is
  /// the target sort and whose domains are the index types, in order:
  /// `Nat -> Type` for `data Vec[A] : Nat -> Type`. Elaboration walks
  /// the Pi chain to split indices from the target sort.
  ///
  /// Keeping this as one [SExpr] rather than splitting indices and
  /// sort at parse time means the parser reuses the existing
  /// expression grammar and the elaborator does the structural
  /// decomposition in one place.
  final SExpr signature;

  /// Constructor declarations in source order.
  final List<SCtorDecl> ctors;

  /// Creates a data-type declaration.
  const SDataKind(this.name, this.typeParams, this.signature, this.ctors);

  @override
  String toString() =>
      'SDataKind($name, typeParams: $typeParams, signature: $signature, '
      'ctors: $ctors)';
}

/// A single constructor declaration inside an [SDataKind].
///
/// [type] is the full declared type including argument arrows and the
/// result-type shape (e.g. `(n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n)`).
/// [span] covers the constructor's source text.
final class SCtorDecl {
  /// The constructor's name (e.g. `zero`, `succ`, `cons`, `vcons`).
  final String name;

  /// The full declared type (arrows + result indices).
  final SExpr type;

  /// The source span of this constructor.
  final DoxaSpan span;

  /// Creates a constructor declaration.
  const SCtorDecl(this.name, this.type, this.span);

  @override
  bool operator ==(Object other) =>
      other is SCtorDecl &&
      other.name == name &&
      other.type == type &&
      other.span == span;

  @override
  int get hashCode => Object.hash('SCtorDecl', name, type, span);

  @override
  String toString() => 'SCtorDecl($name : $type @ $span)';
}

/// A top-level declaration: a [SDeclKind] paired with a source [DoxaSpan].
final class SDecl {
  /// The structural shape.
  final SDeclKind kind;

  /// The source span covering this declaration.
  final DoxaSpan span;

  /// Creates a spanned declaration.
  const SDecl(this.kind, this.span);

  /// The bound name.
  String get name => kind.name;

  @override
  bool operator ==(Object other) =>
      other is SDecl && other.kind == kind && other.span == span;

  @override
  int get hashCode => Object.hash('SDecl', kind, span);

  @override
  String toString() => 'SDecl($kind @ $span)';
}

/// A Doxa program: a sequence of declarations.
final class SProgram {
  /// The program's declarations in source order.
  final List<SDecl> decls;

  /// Creates a program.
  const SProgram(this.decls);
}
