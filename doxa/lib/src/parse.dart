/// Surface parser for Doxa, built on Rumil parser combinators.
///
/// Produces a [SProgram] (list of [SDecl]s) with byte-offset spans on
/// every [SExpr] and [SDecl] via Rumil's `position()` primitive.
///
/// ## Grammar (matching SPEC §5.1)
///
/// ```
/// program    ::= decl*
/// decl       ::= 'val' ident (':' type)? '=' expr
///              | 'type' ident '=' type
///              | 'fun' ident typeparams? '(' params ')' ':' type '=' expr
/// expr       ::= binder | appOrArrow
/// binder     ::= '(' ident ':' expr ')' ('=>' | '->') expr
/// appOrArrow ::= cmp ( '->' expr )?
/// cmp        ::= arith ( ('==' | '<=') arith )?
/// arith      ::= app ( ('+' | '*') app )*      (with '*' tighter than '+')
/// app        ::= atom atom*                (left-associative, via pratt())
/// atom       ::= ident | 'Type' nat? | '(' expr ')'
/// ```
///
/// ## Application
///
/// Application is juxtaposition (`app ::= atom atom*`), parsed with
/// Rumil's `pratt()` precedence combinator: a left-associative infix
/// operator whose zero-width "symbol" is the lookahead "an atom begins
/// here". See [_app]. Rumil also offers a `rule()` combinator with
/// Warth et al. seed-growth left recursion; the directly-left-recursive
/// `app ::= app atom | atom` is preserved as [_appViaRule] for
/// comparison, but it is not on the live path.
library;

import 'package:rumil/rumil.dart';

import 'surface.dart';
import 'term.dart' show Icit;

/// Parse a Doxa program from source text.
///
/// Returns a Rumil `Result`. On success the `SProgram` carries spans on
/// every node; on failure the `ParseError` list carries source locations
/// for diagnostic output.
Result<ParseError, SProgram> parseProgram(String input) => _program.run(input);

/// Parse a single expression. Useful for tests and REPL-style use.
Result<ParseError, SExpr> parseExpr(String input) =>
    _ws.skipThen(_expr).thenSkip(_ws).thenSkip(eof()).run(input);

/// Parse a bracketed expression list: `[e1, e2, ...]`.
///
/// Used by the REPL's `:step simp [e1, e2]` and by tests that need the
/// same grammar as the tactic's lemma list.
Result<ParseError, List<SExpr>> parseExprList(String input) => _ws
    .skipThen(_sym('[').skipThen(_expr.sepBy(_sym(','))).thenSkip(_sym(']')))
    .thenSkip(_ws)
    .thenSkip(eof())
    .run(input);

/// Parse a single declaration. Useful for REPL-style use.
Result<ParseError, SDecl> parseDecl(String input) =>
    _ws.skipThen(_decl).thenSkip(_ws).thenSkip(eof()).run(input);

/// Parse the complete import declarations at the start of [input].
///
/// Editor features use this after a later declaration is incomplete. Import
/// paths are structural and remain safe to navigate without a complete AST.
List<SDecl> parseLeadingImports(String input) => switch (_leadingImports.run(
  input,
)) {
  Success<ParseError, List<SDecl>>(:final value) ||
  Partial<ParseError, List<SDecl>>(:final value) => value,
  Failure<ParseError, List<SDecl>>() => const [],
};

// ===========================================================================
// Whitespace and comments.
// ===========================================================================

/// A single whitespace character.
final Parser<ParseError, void> _wsChar = satisfy(
  (c) => c == ' ' || c == '\t' || c == '\r' || c == '\n',
  'whitespace',
).as<void>(null);

/// A line comment: `// ... newline`.
final Parser<ParseError, void> _lineComment = string('//')
    .skipThen(satisfy((c) => c != '\n', 'comment char').many)
    .skipThen((char('\n').as<void>(null)) | eof())
    .as<void>(null);

/// A block comment: `/* ... */` (nestable).
///
/// Nested via `defer()` for recursion, NOT `rule()`, block comment is
/// not left-recursive (the recursion is guarded by `/*`, which consumes
/// input before recursing). Using `rule()` here would memoize failures
/// at every position through Warth's LR-aware machinery, which distorts
/// error reporting in the surrounding context.
final Parser<ParseError, void> _blockComment = defer(
  () => string('/*')
      .skipThen(
        (_blockComment |
                string('*/').notFollowedBy.skipThen(anyChar()).as<void>(null))
            .many,
      )
      .skipThen(string('*/'))
      .as<void>(null),
);

/// Zero or more whitespace or comments.
final Parser<ParseError, void> _ws = (_wsChar | _lineComment | _blockComment)
    .many
    .as<void>(null);

/// Wrap a parser to consume trailing whitespace.
Parser<ParseError, A> _lex<A>(Parser<ParseError, A> p) => p.thenSkip(_ws);

/// A literal symbol that consumes trailing whitespace.
Parser<ParseError, String> _sym(String s) => _lex(string(s));

// ===========================================================================
// Keywords and identifiers.
// ===========================================================================

/// Reserved words that may not appear as identifiers.
const Set<String> _reserved = {
  'val',
  'type',
  'fun',
  'and',
  'data',
  'match',
  'case',
  'returning',
  'import',
  'theorem',
  'by',
  'Type',
  'Prop',
  'SProp',
  'Quot',
  'typeclass',
  'impl',
  'calc',
  'decreases',
};

/// A raw identifier, one letter or underscore, then alphanumeric/underscore.
///
/// Reserved words are rejected here (producing a failure) so that
/// `val`, `type`, `fun`, and `Type` can be matched as their own
/// keyword alternatives without ambiguity.
final Parser<ParseError, String> _rawIdent = (letter() | char('_'))
    .zip((alphaNum() | char('_')).many)
    .map((pair) => pair.$1 + pair.$2.join())
    .flatMap(
      (name) =>
          _reserved.contains(name)
              ? failure<ParseError, String>(
                CustomError('unexpected reserved word "$name"', Location.zero),
              )
              : succeed<ParseError, String>(name),
    );

/// A lexed identifier (consumes trailing whitespace).
final Parser<ParseError, String> _ident = _lex(_rawIdent);

/// A lexed identifier paired with its exact source span.
final Parser<ParseError, (String, DoxaSpan)> _identWithSpan =
    position<ParseError>().flatMap(
      (start) => _rawIdent
          .zip(position<ParseError>())
          .thenSkip(_ws)
          .map((pair) => (pair.$1, DoxaSpan(start, pair.$2))),
    );

/// A keyword: an exact-string match that is not followed by another
/// identifier character. Prevents `valid` from matching `val`.
Parser<ParseError, String> _keyword(String word) =>
    _lex(string(word).thenSkip((alphaNum() | char('_')).notFollowedBy));

/// A double-quoted string literal.
final Parser<ParseError, String> _strLit = _sym('"')
    .skipThen(
      satisfy((c) => c != '"', 'string character').many.map((cs) => cs.join()),
    )
    .thenSkip(_sym('"'));

/// An `import` declaration: `import "path/to/file.doxa"` or
/// `import "path/to/file.doxa" { name1, name2 }` or
/// `import "path/to/file.doxa" as Alias` or
/// `import "path/to/file.doxa" { a, b } as Alias`.
final Parser<ParseError, SDecl> _importDecl = position<ParseError>().flatMap(
  (start) => _keyword('import')
      .skipThen(_strLit)
      .flatMap(
        (path) => _sym('{')
            .skipThen(_ident.sepBy(_sym(',')))
            .thenSkip(_sym('}'))
            .optional
            .flatMap(
              (importedNames) => _keyword('as')
                  .skipThen(_ident)
                  .optional
                  .zip(position<ParseError>())
                  .map(
                    (pair) => SDecl(
                      SImportKind(
                        path,
                        importedNames: importedNames ?? const [],
                        alias: pair.$1,
                      ),
                      DoxaSpan(start, pair.$2),
                    ),
                  ),
            ),
      ),
);

/// Optional `opaque` modifier, consumed before `val` / `fun`.
final Parser<ParseError, bool> _opaqueMod = _keyword(
  'opaque',
).map((_) => true).optional.map((v) => v ?? false);

// ===========================================================================
// Atoms and type levels.
// ===========================================================================

/// An unsigned integer literal (for universe levels).
final Parser<ParseError, int> _nat = digit().many1.map(
  (ds) => int.parse(ds.join()),
);

/// `Type` or `Type N`.
final Parser<ParseError, SExprKind> _typeKind = _keyword(
  'Type',
).skipThen(_lex(_nat).optional).map<SExprKind>(STypeKind.new);

/// `Prop`.
final Parser<ParseError, SExprKind> _propKind = _keyword(
  'Prop',
).map<SExprKind>((_) => const SPropKind());

/// `SProp`.
final Parser<ParseError, SExprKind> _spropKind = _keyword(
  'SProp',
).map<SExprKind>((_) => const SSPropKind());

/// Wrap an `SExprKind` parser so it picks up start/end spans.
///
/// `spanned(p)` parses a kind, also capturing its start and end offsets,
/// and produces an `SExpr` carrying both. Used on every kind-producing
/// sub-parser so spans attach uniformly.
Parser<ParseError, SExpr> _spanned(Parser<ParseError, SExprKind> p) =>
    position<ParseError>()
        .zip(p)
        .zip(position<ParseError>())
        .map((pair) => SExpr(pair.$1.$2, DoxaSpan(pair.$1.$1, pair.$2)));

// ===========================================================================
// Expressions.
//
// Shape of the grammar:
//
//   expr       := binder | appOrArrow
//   binder     := '(' ident ':' expr ')' ('=>' | '->') expr
//   appOrArrow := cmp ('->' expr)?
//   cmp        := arith (('==' | '<=') arith)?     -- non-associative
//   arith      := add                             -- '+' is left-associative
//   add        := mul ('+' mul)*
//   mul        := app ('*' app)*
//   app        := rule { app atom | atom }   -- direct left recursion
//   atom       := ident | Type [n] | '(' expr ')'
//
// The four infix operators expand to identifier applications at parse time,
// so they produce ordinary applications: `a + b` is `App(App(plus, a), b)`.
// See [_expandInfix] and [doxaInfixOperators].
//
// `binder` and a parenthesized expression share the prefix `(`. The
// parser tries `binder` first; Rumil's `Or` unconditionally restores
// state on failure (see `rumil/lib/src/interpreter.dart` case `Or`), so
// a failed binder backtracks cleanly to `appOrArrow` even after partial
// consumption. No `attempt` wrapper is needed.
//
// `app` is the showcase for Rumil: the rule `app := app atom | atom`
// is directly left-recursive. Warth seed-growth (activated by wrapping
// the rule in `rule(...)`) turns the self-reference into a fixed-point
// iteration, producing the left-folded shape `(((a b) c) d)` without
// any `chainl1` / precedence-climbing workaround.
// ===========================================================================

/// Top-level expression.
///
/// `_binder` and `_appOrArrow` share the prefix `(`. Rumil's `Or`
/// unconditionally restores position on failure (see
/// `rumil/lib/src/interpreter.dart` case `Or`, which calls `state.restore`
/// whenever the left branch fails, regardless of what it consumed). That
/// means `_binder | _appOrArrow` backtracks cleanly when the `(ident : ty)`
/// header fails to match, no `attempt` wrapper needed.
///
/// The `.expect` is applied to the alternatives only. [_noChainedComparison]
/// runs after it, so a chained-comparison diagnostic is not rewritten to the
/// generic "expected an expression" message; the location still comes from the
/// deepest failure in either case.
final Parser<ParseError, SExpr> _expr = defer(
  () => (_matchExpr | _binder | _implicitBinder | _appOrArrow)
      .expect('expected an expression')
      .thenSkip(_noChainedComparison),
);

/// A single `val` binding inside a block: `'val' ident (':' type)? '=' expr`.
///
/// Carries its own start position so the desugared [SLetKind] can be
/// spanned from the `val` keyword through the block's result.
///
/// When [isRec] is true, the binding is a recursive `val rec` whose
/// [domain] is the return type and [funParams] are the value parameters.
typedef _ValBinding =
    ({
      int start,
      String name,
      DoxaSpan nameSpan,
      SExpr? domain,
      SExpr bound,
      bool isRec,
      List<(String, SExpr, DoxaSpan)> funParams,
    });

/// Optional `rec` keyword modifier on a `val` binding.
final Parser<ParseError, bool> _recMod = _keyword(
  'rec',
).map((_) => true).optional.map((v) => v ?? false);

/// Value parameters for a `val rec` binding: `'(' name ':' expr (',' name ':' expr)* ')'`.
final Parser<ParseError, List<(String, SExpr, DoxaSpan)>> _recValueParams =
    _sym('(')
        .skipThen(
          _identWithSpan
              .flatMap<(String, SExpr, DoxaSpan)>(
                (name) =>
                    _sym(':').skipThen(_expr).map((t) => (name.$1, t, name.$2)),
              )
              .sepBy(_sym(',')),
        )
        .thenSkip(_sym(')'));

final Parser<ParseError, _ValBinding> _valBinding = position<ParseError>()
    .flatMap(
      (start) => _keyword('val')
          .skipThen(_recMod)
          .flatMap(
            (isRec) => _identWithSpan.flatMap((name) {
              if (isRec) {
                // val rec f(x: T): R = body
                return _recValueParams.flatMap(
                  (params) => _sym(':')
                      .skipThen(_expr)
                      .flatMap(
                        (retType) => _sym('=')
                            .skipThen(_expr)
                            .map(
                              (body) => (
                                start: start,
                                name: name.$1,
                                nameSpan: name.$2,
                                domain: retType,
                                bound: body,
                                isRec: true,
                                funParams: params,
                              ),
                            ),
                      ),
                );
              } else {
                // val f(: T)? = expr
                return _sym(':')
                    .skipThen(_expr)
                    .optional
                    .flatMap(
                      (domain) => _sym('=')
                          .skipThen(_expr)
                          .map(
                            (bound) => (
                              start: start,
                              name: name.$1,
                              nameSpan: name.$2,
                              domain: domain,
                              bound: bound,
                              isRec: false,
                              funParams: const [],
                            ),
                          ),
                    );
              }
            }),
          ),
    );

/// Block expression: `'{' (val-binding ';')* result-expr '}'`, local
/// bindings in ML-family value-block style. Zero or more
/// `val name (: type)? = expr` bindings, each terminated by `;`,
/// followed by a single result expression that is the block's value
/// (implicit, there is no `in` or `return` keyword; the trailing
/// expression IS the value, and a block MUST have one).
///
/// The `;` separator is required between block items: the combinator
/// parser is not newline-sensitive, and `;` is already the separator in
/// `data` ctor lists.
///
/// Desugars to a right-nested chain of [SLetKind]: `{ val x = a; val y =
/// b; r }` becomes `let x = a in (let y = b in r)` at the kernel level.
/// Each binding's span runs from its own `val` keyword to the end of the
/// block, matching the scope the binder governs.
final Parser<ParseError, SExpr> _blockExpr = _sym('{').skipThen(
  _valBinding
      .thenSkip(_sym(';'))
      .many
      .flatMap(
        (bindings) =>
            _expr.zip(position<ParseError>()).thenSkip(_sym('}')).map((pair) {
              final result = pair.$1;
              final end = pair.$2;
              // Fold bindings right-to-left so the first binding is outermost.
              var body = result;
              for (final b in bindings.reversed) {
                if (b.isRec) {
                  // Build lambda chain from params and body.
                  var bound = b.bound;
                  for (final p in b.funParams.reversed) {
                    bound = SExpr(
                      SLamKind(p.$1, p.$2, bound, paramSpan: p.$3),
                      DoxaSpan(b.start, end),
                    );
                  }
                  // Build Pi type from params and return type.
                  var domain = b.domain!;
                  for (final p in b.funParams.reversed) {
                    domain = SExpr(
                      SPiKind(p.$1, p.$2, domain, paramSpan: p.$3),
                      DoxaSpan(b.start, end),
                    );
                  }
                  body = SExpr(
                    SLetKind(
                      b.name,
                      domain,
                      bound,
                      body,
                      isRec: true,
                      paramSpan: b.nameSpan,
                    ),
                    DoxaSpan(b.start, end),
                  );
                } else {
                  body = SExpr(
                    SLetKind(
                      b.name,
                      b.domain,
                      b.bound,
                      body,
                      paramSpan: b.nameSpan,
                    ),
                    DoxaSpan(b.start, end),
                  );
                }
              }
              return body;
            }),
      ),
);

// ---------------------------------------------------------------------------
// Pattern matching
// ---------------------------------------------------------------------------

/// A pattern-binder: an identifier OR a literal `_` (wildcard binder).
///
/// Stored as the literal string `"_"` for underscores so downstream
/// code can distinguish "user wrote `_`" from a named binder. This
/// matches the discipline on lambda parameters (the parser rejects
/// reserved words as identifiers, so `_` can't accidentally collide
/// with anything).
final Parser<ParseError, String> _patternBinder =
    _lex(
      char('_'),
    ).thenSkip((alphaNum() | char('_')).notFollowedBy).as<String>('_') |
    _ident;

/// A constructor case pattern: `<ctor-name> <binder>*`. Returns
/// `(ctor, binders)`.
///
/// No leading `case` keyword here, the caller ([_caseArm]) consumes
/// that. The ctor name is a plain ident; binders are zero or more
/// pattern binders. Wildcard-only case `_` is handled separately by
/// [_caseArm] so that `case _ => body` parses as [SWildcardCase],
/// not as "ctor named `_` with no binders."
final Parser<ParseError, (String, List<String>)> _ctorPattern = _ident.flatMap(
  (ctor) => _patternBinder.many.map((binders) => (ctor, binders)),
);

/// A single case arm: `case <pattern> => expr`.
///
/// Pattern is either the wildcard `_` (producing [SWildcardCase]) or
/// a ctor + binders pattern (producing [SMatchCase]). The body
/// expression terminates naturally at the next `case` keyword or the
/// closing `}` because both are reserved / grammar-structural.
final Parser<ParseError, SMatchCaseArm> _caseArm = position<ParseError>()
    .flatMap(
      (start) => _keyword('case').skipThen(
        // Wildcard first: `_` followed by `=>`. Use attempt-like pattern
        // via the `| _ctorPattern` branch since the wildcard's `_` could
        // otherwise look like a zero-arg ctor named `_`, but `_ident`
        // accepts `_` as an ident start, so we must explicitly detect
        // wildcard before falling through.
        (_lex(char('_'))
                .thenSkip((alphaNum() | char('_')).notFollowedBy)
                .skipThen(_sym('=>'))
                .skipThen(defer(() => _expr).zip(position<ParseError>()))
                .map<SMatchCaseArm>(
                  (pair) => SWildcardCase(pair.$1, DoxaSpan(start, pair.$2)),
                )) |
            _ctorPattern
                .thenSkip(_sym('=>'))
                .flatMap(
                  (pat) => defer(() => _expr)
                      .zip(position<ParseError>())
                      .map(
                        (pair) => SMatchCase(
                          pat.$1,
                          pat.$2,
                          pair.$1,
                          DoxaSpan(start, pair.$2),
                        ),
                      ),
                ),
      ),
    );

/// `match expr ('returning' expr)? '{' case* '}'`.
///
/// Match arms take no separator (SPEC.md, Inductive types and matching): `case` is reserved and
/// is its own terminator; `}` closes the block. See the
/// `data` ctor list for the contrast, ctor signatures are type
/// expressions that would otherwise run into each other, so `;` is
/// grammatically required there.
final Parser<ParseError, SExpr> _matchExpr = position<ParseError>().flatMap(
  (start) => _keyword('match')
      .skipThen(defer(() => _expr))
      .flatMap(
        (scrutinee) => _keyword('returning')
            .skipThen(defer(() => _expr))
            .optional
            .flatMap(
              (motive) => _sym('{')
                  .skipThen(_caseArm.many)
                  .thenSkip(_sym('}'))
                  .zip(position<ParseError>())
                  .map(
                    (pair) => SExpr(
                      SMatchKind(scrutinee, motive, pair.$1),
                      DoxaSpan(start, pair.$2),
                    ),
                  ),
            ),
      ),
);

/// `(' ident (':' expr)? ')' ('=>' | '->') expr`, a dependent binder.
///
/// When the separator is `=>` we build an [SLamKind]; when `->` an
/// [SPiKind] with a named parameter. The domain annotation is optional:
/// `(x) => body` is an unannotated lambda whose parameter type is taken
/// from the expected `Pi` in check mode. A domain-less `->` is rejected
/// (a `Pi` needs an explicit domain), so the unannotated form only
/// accepts `=>`. When the header `(x)` is not followed by an arrow this
/// branch fails and backtracks, letting `_appOrArrow` parse `(x)` as a
/// parenthesized atom.
final Parser<ParseError, SExpr> _binder = position<ParseError>().flatMap(
  (start) => _sym('(')
      .skipThen(_identWithSpan)
      .flatMap(
        (name) => _sym(':')
            .skipThen(_expr)
            .optional
            .flatMap(
              (domain) => _sym(')').skipThen(
                // Both `->` and `=>` produce an SLamKind when the domain
                // is null (unannotated `(x) -> body` or `(x) => body`).
                // For annotated binders, `=>` is a lambda and `->` is a Pi.
                (domain == null
                        ? (_sym('->').as<String>('->') |
                            _sym('=>').as<String>('=>'))
                        : (_sym('=>').as<String>('=>') |
                            _sym('->').as<String>('->')))
                    .flatMap(
                      (arrow) => _expr.zip(position<ParseError>()).map((pair) {
                        final body = pair.$1;
                        final end = pair.$2;
                        final span = DoxaSpan(start, end);
                        final kind =
                            domain == null || arrow == '=>'
                                ? SLamKind(
                                  name.$1,
                                  domain,
                                  body,
                                  paramSpan: name.$2,
                                )
                                : SPiKind(
                                  name.$1,
                                  domain,
                                  body,
                                  paramSpan: name.$2,
                                );
                        return SExpr(kind, span);
                      }),
                    ),
              ),
            ),
      ),
);

/// `{x : T} -> body` or `{x : T} => body` — implicit binder.
final Parser<ParseError, SExpr> _implicitBinder = position<ParseError>()
    .flatMap(
      (start) => _sym('{')
          .skipThen(_identWithSpan)
          .flatMap(
            (name) => _sym(':')
                .skipThen(_expr)
                .flatMap(
                  (domain) => _sym('}').skipThen(
                    (_sym('=>').as<String>('=>') | _sym('->').as<String>('->'))
                        .flatMap(
                          (arrow) =>
                              _expr.zip(position<ParseError>()).map((pair) {
                                final body = pair.$1;
                                final end = pair.$2;
                                final span = DoxaSpan(start, end);
                                final kind =
                                    arrow == '=>'
                                        ? SLamKind(
                                          name.$1,
                                          domain,
                                          body,
                                          icit: Icit.implicit,
                                          paramSpan: name.$2,
                                        )
                                        : SPiKind(
                                          name.$1,
                                          domain,
                                          body,
                                          icit: Icit.implicit,
                                          paramSpan: name.$2,
                                        );
                                return SExpr(kind, span);
                              }),
                        ),
                  ),
                ),
          ),
    );

// ---------------------------------------------------------------------------
// Infix operators
// ---------------------------------------------------------------------------

/// The four infix operators of the surface language.
///
/// Recorded once so the parser and the formatter share one description of the
/// surface. `bindingPower` orders them; `associates` is false for the two
/// comparisons, which do not chain, and true for `*` and `+`, which chain to
/// the left. (No right-associative operator exists.)
///
/// Each operator expands to one named identifier, resolved like any other
/// identifier at the use site. `+` is always `plus`, never an overloaded
/// arithmetic operation. `*` is always `multiply`, which can resolve to a
/// class projection when a constraint supplies the dictionary.
const List<({String symbol, String name, int bindingPower, bool associates})>
doxaInfixOperators = [
  (symbol: '*', name: 'multiply', bindingPower: 30, associates: true),
  (symbol: '+', name: 'plus', bindingPower: 20, associates: true),
  (symbol: '<=', name: 'leq', bindingPower: 10, associates: false),
  (symbol: '==', name: 'equals', bindingPower: 10, associates: false),
];

/// Symbol to expanded name, the lookup the parser's expansion step uses.
final Map<String, String> _infixName = {
  for (final op in doxaInfixOperators) op.symbol: op.name,
};

/// An infix operator as it appeared in the source: its text and its own span.
///
/// The span covers the symbol characters only. Trailing whitespace is consumed
/// (the parser is whitespace-insensitive) but excluded from the span, so an
/// expansion can point a diagnostic at the symbol the user wrote.
typedef _OpToken = ({String symbol, DoxaSpan span});

/// Match [symbol] as an infix operator, consuming trailing whitespace.
Parser<ParseError, _OpToken> _opToken(String symbol) => position<ParseError>()
    .zip(string(symbol))
    .zip(position<ParseError>())
    .thenSkip(_ws)
    .map((pair) => (symbol: symbol, span: DoxaSpan(pair.$1.$1, pair.$2)));

/// Expand `lhs op rhs` into the ordinary application `name lhs rhs`.
///
/// The synthesized function identifier carries the operator's own span, so an
/// [UnresolvedName] for an operator with no matching binding points at the
/// symbol rather than at the whole expression.
SExpr _expandInfix(_OpToken op, SExpr lhs, SExpr rhs) {
  final name = _infixName[op.symbol]!;
  final span = DoxaSpan(lhs.span.start, rhs.span.end);
  return SExpr(
    SAppKind(
      SExpr(SAppKind(SExpr(SIdentKind(name), op.span), lhs), op.span),
      rhs,
    ),
    span,
  );
}

/// A left-associative chain of [op] over [operand], folded left.
///
/// `a op b op c` becomes `(a op b) op c`. The trailing pair list is parsed
/// with `many`, so the loop is iterative and a failed operand after a matched
/// operator backtracks the whole pair (leaving the operator unconsumed) rather
/// than swallowing it.
Parser<ParseError, SExpr> _leftChain(
  Parser<ParseError, SExpr> operand,
  Parser<ParseError, _OpToken> op,
) => operand.flatMap(
  (first) => op
      .zip(operand)
      .many
      .map(
        (rest) => rest.fold<SExpr>(
          first,
          (lhs, step) => _expandInfix(step.$1, lhs, step.$2),
        ),
      ),
);

/// Arithmetic level: `*` over `+`, both left-associative.
///
/// The two chains are nested rather than given to [pratt] because the
/// expansion needs each operator's own span, which the Pratt `combine`
/// callback does not receive. The nesting order is the precedence recorded in
/// [doxaInfixOperators]: `*` (30) tighter than `+` (20), both tighter than the
/// comparisons (10), which [_cmp] handles at its own level.
final Parser<ParseError, SExpr> _arith = defer(
  () => _leftChain(_leftChain(_app, _opToken('*')), _opToken('+')),
);

/// A comparison operator: `<=` or `==`.
final Parser<ParseError, _OpToken> _cmpOp = _opToken('<=') | _opToken('==');

/// Comparison level: at most one `<=` or `==`.
///
/// The tail accepts a single operator, so a second comparison operator is left
/// unconsumed for [_noChainedComparison] to report. That keeps the level
/// non-associative without giving the second operator a silent association.
final Parser<ParseError, SExpr> _cmp = defer(
  () => _arith.flatMap(
    (lhs) => _cmpOp
        .flatMap((op) => _arith.map((rhs) => _expandInfix(op, lhs, rhs)))
        .or(succeed<ParseError, SExpr>(lhs)),
  ),
);

/// Reject a comparison operator immediately after a complete expression.
///
/// Comparison is non-associative: `a <= b <= c` and `a == b == c` are errors,
/// not a left or right association. The failure is raised on the second
/// operator's own first character (so the reported position is the operator,
/// not the start of the expression) and its expected-set names the operator.
/// A parenthesized left operand is a complete expression of its own, so
/// `(a <= b) == c` parses.
///
/// The lookahead is `optional` so that "no comparison operator follows" is a
/// success here. `Or` cannot be used, because it would also swallow the
/// diagnostic this parser raises when one does follow.
final Parser<ParseError, void> _noChainedComparison = _cmpOp.lookAhead.optional
    .flatMap(
      (op) =>
          op == null
              ? succeed<ParseError, void>(null)
              : satisfy(
                (_) => false,
                'the comparison to end here; "${op.symbol}" does not '
                'associate, so parenthesize the left comparison',
              ).as<void>(null),
    );

/// `cmp ('->' expr)?`, an expression, optionally followed by a
/// non-dependent arrow.
final Parser<ParseError, SExpr> _appOrArrow = position<ParseError>().flatMap(
  (start) => _cmp.flatMap(
    (head) => _sym('->')
        .skipThen(_expr.zip(position<ParseError>()))
        .map(
          (pair) =>
              SExpr(SPiKind(null, head, pair.$1), DoxaSpan(start, pair.$2)),
        )
        .or(succeed<ParseError, SExpr>(head)),
  ),
);

/// Application `app := app atom | atom`, via the Pratt combinator.
///
/// Application is juxtaposition, modelled as a left-associative infix
/// operator whose "symbol" is the zero-width [_atomStart] lookahead (it
/// commits iff another atom begins next, consuming nothing). The Pratt loop
/// then parses that atom as the RHS operand and the `fn` folds it left:
/// `(((a b) c) d)`. The combined span is reconstructed from the operands'
/// own spans, identical to the directly-left-recursive version.
///
/// This is the Lean-4-inspired path: a proof checker parsed by the precedence
/// combinator Lean's parser inspired, and ~1.37x faster on the corpus than the
/// Warth seed-growth `rule()` version (measured via tool/parse_bench.dart). The
/// `rule()` version is kept as [_appViaRule], it is AST-identical and is the
/// reference data point for the upstream keep-rule() decision; it is NOT a
/// fallback and nothing dispatches to it.
final Parser<ParseError, SExpr> _app = pratt<SExpr>(_atom, [
  InfixLeft<SExpr>(
    _atomStart,
    _appBp,
    (SExpr f, SExpr arg) =>
        SExpr(SAppKind(f, arg), DoxaSpan(f.span.start, arg.span.end)),
  ),
]);

/// Binding power for application (juxtaposition). Application binds tighter
/// than anything else in the expression grammar; it is the only operator in
/// this Pratt table, so the absolute value is immaterial, only that it is
/// positive (so the loop fires at all).
const int _appBp = 100;

/// Guard for "an atom begins here", used as the zero-width juxtaposition
/// operator symbol. An atom is a parenthesized expression, or an identifier
/// (`Type`/`Prop` are identifiers at this point), but NOT a reserved word:
/// after `match m {` the next token `case` starts like an identifier yet must
/// not be eaten as an application argument. So the guard reuses `_rawIdent`
/// (which rejects reserved words) rather than a bare first-char test.
///
/// `_rawIdent` does not consume trailing whitespace and never recurses into a
/// parenthesized sub-expression, so this lookahead is cheap, it avoids the
/// double-parse that `_atom.lookAhead` incurs on `(big expr)` operands.
///
/// The keyword atoms `Type` and `Prop` are reserved (so `_rawIdent` rejects
/// them) yet are valid atom-starts, `Type Type` is a legal application, so
/// they are matched explicitly alongside the paren and bare-identifier cases.
///
/// `{` is deliberately NOT an atom-start: a block `{ … }` is not consumed as
/// a bare application argument, because `match scrut { arms }` parses its
/// scrutinee through `_app` and a `{`-as-argument would swallow the match
/// body's brace. A block used as an argument must be parenthesized
/// (`f ({ … })`), exactly as `match`/binder forms must be. In
/// non-argument positions (after `=`, a function body, inside parens) a
/// bare block parses fine via `_atomImpl`.
/// Zero-width lookahead that commits to application iff the next token
/// starts an atom: `(`, `Type`, `Prop`, or an identifier (excluding
/// keywords that belong to the enclosing declaration grammar).
final Parser<ParseError, void> _atomStart =
    (char('(').as<void>(null) |
            _rawKeyword('Type').as<void>(null) |
            _rawKeyword('Prop').as<void>(null) |
            _rawKeyword('calc').as<void>(null) |
            _rawIdent.as<void>(null))
        .lookAhead;

/// A reserved word as a raw token (no trailing-whitespace consumption, with a
/// word-boundary guard so `Typeof` is not read as `Type`). Used only by the
/// juxtaposition lookahead; the real atom parsers use the `_lex`'d keywords.
Parser<ParseError, String> _rawKeyword(String word) =>
    string(word).thenSkip((alphaNum() | char('_')).notFollowedBy);

/// Warth seed-growth version, preserved for comparison. This is the original
/// "rule() showcase": the directly left-recursive `app := app atom | atom`
/// turned into a fixed-point by `rule(...)`. Kept as a live data point for the
/// upstream keep-rule() decision, DO NOT delete without that being settled.
// ignore: unused_element
final Parser<ParseError, SExpr> _appViaRule = rule<ParseError, SExpr>(
  () => position<ParseError>().flatMap(
    (start) =>
        _appViaRule
            .zip(_atom.zip(position<ParseError>()))
            .map(
              (pair) => SExpr(
                SAppKind(pair.$1, pair.$2.$1),
                DoxaSpan(start, pair.$2.$2),
              ),
            ) |
        _atom,
  ),
);

/// An atomic expression.
final Parser<ParseError, SExpr> _atom = defer(() => _atomImpl);

/// Type-level application suffix: `'[' expr (',' expr)* ']'`.
///
/// Applied as a left-folded application: `List[A]` → `App(List, A)`,
/// `Map[K, V]` → `App(App(Map, K), V)`. This is the surface form that
/// visually marks type-parameter slots at use sites; see SPEC.md, Terms and
/// sorts.
final Parser<ParseError, List<SExpr>> _typeArgs = _sym(
  '[',
).skipThen(defer(() => _expr).sepBy1(_sym(','))).thenSkip(_sym(']'));

/// A single `.ident` suffix, used for chained dotted names.
///
/// Captures the dot-side ident's end position so the enclosing
/// [_identAtom] can correctly compute the span of the resulting
/// [SDotKind].
final Parser<ParseError, (String, int)> _dotSuffix = _sym(
  '.',
).skipThen(_ident.zip(position<ParseError>()));

/// An identifier, optionally followed by a [_typeArgs] suffix and
/// zero or more `.ident` chain parts.
///
/// Examples:
///   `foo`            → `SIdentKind("foo")`
///   `List[A]`        → `SApp(SIdent("List"), SIdent("A"))`
///   `Nat.rec`        → `SDot(SIdent("Nat"), "rec")`
///   `Map[K, V].find` → `SDot(SApp(SApp(SIdent("Map"), SIdent("K")), SIdent("V")), "find")`
///   `Outer.Mid.leaf` → `SDot(SDot(SIdent("Outer"), "Mid"), "leaf")`
///
/// The grammar `ident typeArgs? ('.' ident)*` is right-linear with a
/// postfix-star on `.ident`, which avoids the need for Warth LR on
/// this single production. A left-recursive grammar would be more
/// direct in the abstract, but Rumil's LR machinery appears to
/// misbehave when a [rule] is nested inside another [rule] (as would
/// be required for a left-recursive atom inside the already-LR
/// `_app`); this postfix form achieves the same result without the
/// interaction. The resulting AST shape is identical to what an LR
/// grammar would produce.
final Parser<ParseError, SExpr> _identAtom = position<ParseError>().flatMap(
  (start) => _rawIdent.zip(position<ParseError>()).thenSkip(_ws).flatMap((
    identAndEnd,
  ) {
    final name = identAndEnd.$1;
    final identEnd = identAndEnd.$2;
    final bareIdent = SExpr(SIdentKind(name), DoxaSpan(start, identEnd));
    // Optional [typeArgs].
    return _typeArgs
        .zip(position<ParseError>())
        .map((pair) {
          final args = pair.$1;
          final end = pair.$2;
          final span = DoxaSpan(start, end);
          SExpr result = bareIdent;
          for (final arg in args) {
            result = SExpr(SAppKind(result, arg), span);
          }
          return result;
        })
        .or(succeed<ParseError, SExpr>(bareIdent))
        .flatMap(
          (headExpr) => _dotSuffix.many.map((dots) {
            // Left-fold dots onto headExpr.
            SExpr result = headExpr;
            for (final dot in dots) {
              final dotName = dot.$1;
              final dotEnd = dot.$2;
              result = SExpr(
                SDotKind(result, dotName),
                DoxaSpan(start, dotEnd),
              );
            }
            return result;
          }),
        );
  }),
);

/// One step of a `calc` chain: `expr '=' expr (':=' | '=') expr`.
///
/// The first `=` is the relation being chained; the second (optionally
/// written `:=`) separates the step's right endpoint from its proof. The
/// endpoint and proof expressions use the ordinary expression grammar, so
/// `=` is never an operator inside them.
final Parser<ParseError, SCalcStep> _calcStep = position<ParseError>().flatMap(
  (start) => defer(() => _expr).flatMap(
    (lhs) => _sym('=')
        .skipThen(defer(() => _expr))
        .flatMap(
          (rhs) => (_sym(':').skipThen(_sym('=')) | _sym('='))
              .skipThen(defer(() => _expr))
              .zip(position<ParseError>())
              .map(
                (pair) =>
                    SCalcStep(lhs, rhs, pair.$1, DoxaSpan(start, pair.$2)),
              ),
        ),
  ),
);

final Parser<ParseError, SExpr> _atomImpl = () {
  // Order: sort keywords first (so they're not eaten by ident), then
  // parenthesized expression, then a brace block, then quotient forms,
  // then tactic by-block, then identifier-with-optional-type-args.
  final typeAtom = _spanned(_typeKind);
  final propAtom = _spanned(_propKind);
  final spropAtom = _spanned(_spropKind);
  final parenAtom = _sym('(').skipThen(_expr).thenSkip(_sym(')'));
  // Quotient type `Quot(A, R)`, or the soundness primitive
  // `Quot.sound h`. `Quot` is reserved, so the dotted form needs its own
  // branch: `.sound` cannot come through the generic dotted-name path. Like
  // `mk value`, the primitive takes its witness by juxtaposition.
  final quotSoundAtom = position<ParseError>().flatMap(
    (start) => _keyword('Quot')
        .skipThen(_sym('.'))
        .skipThen(_keyword('sound'))
        .skipThen(defer(() => _expr).zip(position<ParseError>()))
        .map(
          (pair) => SExpr(SQuotSoundKind(pair.$1), DoxaSpan(start, pair.$2)),
        ),
  );
  // Quotient type: Quot(A, R)
  final quotAtom = position<ParseError>().flatMap(
    (start) => _keyword('Quot')
        .skipThen(_sym('('))
        .skipThen(defer(() => _expr))
        .flatMap(
          (carrier) => _sym(',')
              .skipThen(defer(() => _expr))
              .thenSkip(_sym(')'))
              .zip(position<ParseError>())
              .map(
                (pair) => SExpr(
                  SQuotKind(carrier, pair.$1),
                  DoxaSpan(start, pair.$2),
                ),
              ),
        ),
  );
  // Quotient injection: mk a
  final mkAtom = position<ParseError>().flatMap(
    (start) => _keyword('mk')
        .skipThen(defer(() => _expr).zip(position<ParseError>()))
        .map((pair) => SExpr(SQuotMkKind(pair.$1), DoxaSpan(start, pair.$2))),
  );
  // Quotient lift: lift(fn, proof)
  final liftAtom = position<ParseError>().flatMap(
    (start) => _keyword('lift')
        .skipThen(_sym('('))
        .skipThen(defer(() => _expr))
        .flatMap(
          (fn) => _sym(',')
              .skipThen(defer(() => _expr))
              .thenSkip(_sym(')'))
              .zip(position<ParseError>())
              .map(
                (pair) =>
                    SExpr(SQuotLiftKind(fn, pair.$1), DoxaSpan(start, pair.$2)),
              ),
        ),
  );
  // Tactic by-block: `by { ... }`.
  final byAtom = position<ParseError>().flatMap(
    (start) => _tacticBlock
        .zip(position<ParseError>())
        .map((pair) => SExpr(SByKind(pair.$1), DoxaSpan(start, pair.$2))),
  );
  // Equality chain: `calc(e1 = e2 := p; e2 = e3 := q)`.
  final calcAtom = position<ParseError>().flatMap(
    (start) => _keyword('calc')
        .skipThen(_sym('('))
        .skipThen(_calcStep.sepBy1(_sym(';')))
        .thenSkip(_sym(')'))
        .zip(position<ParseError>())
        .map((pair) => SExpr(SCalcKind(pair.$1), DoxaSpan(start, pair.$2))),
  );

  return typeAtom |
      propAtom |
      spropAtom |
      parenAtom |
      _blockExpr |
      quotSoundAtom |
      quotAtom |
      mkAtom |
      liftAtom |
      byAtom |
      calcAtom |
      _identAtom;
}();

// ===========================================================================
// Declarations.
// ===========================================================================

/// A `val` declaration: `opaque? val name (':' type)? '=' expr`.
final Parser<ParseError, SDecl> _valDecl = position<ParseError>().flatMap(
  (start) => _opaqueMod.flatMap(
    (isOpaque) => _keyword('val')
        .skipThen(_ident)
        .flatMap(
          (name) => _sym(':').optional
              .flatMap((colon) {
                if (colon == null) {
                  return succeed<ParseError, SExpr?>(null);
                }
                return _expr;
              })
              .flatMap(
                (type) => _sym('=')
                    .skipThen(_expr.zip(position<ParseError>()))
                    .map(
                      (pair) => SDecl(
                        SValKind(name, type, pair.$1, isOpaque: isOpaque),
                        DoxaSpan(start, pair.$2),
                      ),
                    ),
              ),
        ),
  ),
);

/// A `type` alias declaration: `type name '=' expr`.
final Parser<ParseError, SDecl> _typeDecl = position<ParseError>().flatMap(
  (start) => _keyword('type')
      .skipThen(_ident)
      .flatMap(
        (name) => _sym('=')
            .skipThen(_expr.zip(position<ParseError>()))
            .map(
              (pair) => SDecl(
                STypeAliasKind(name, pair.$1),
                DoxaSpan(start, pair.$2),
              ),
            ),
      ),
);

/// Type parameters: `[ name (':' expr)? (',' name (':' expr)?)* ]`.
final Parser<ParseError, List<(String, SExpr?)>> _typeParams = _sym('[')
    .skipThen(
      _ident
          .flatMap<(String, SExpr?)>(
            (name) =>
                _sym(':').skipThen(_expr).optional.map((kind) => (name, kind)),
          )
          .sepBy(_sym(',')),
    )
    .thenSkip(_sym(']'));

/// `fun` type parameters: a sequence of one or more
/// bracket groups, each either `[A, B: Type, ...]` (explicit) or
/// `{A, B: Type, ...}` (implicit). Groups may be freely mixed, e.g.
/// `fun f[A]{B: Type}(x: A): B = ...`. Within a single group, all
/// entries share the group's icity.
///
/// Constraint syntax `[A: Eq & Ord]` is supported in explicit `[...]`
/// groups only. In implicit `{...}` groups, the annotation
/// as a kind annotation (e.g. `{x: A}` means x has type A, not that
/// A is a constraint on x).
Parser<ParseError, List<SFunTypeParam>> _funTypeParamGroup(
  String open,
  String close,
  bool isImplicit,
) => _sym(open)
    .skipThen(
      _identWithSpan
          .flatMap<SFunTypeParam>(
            (name) => _sym(
              ':',
            ).skipThen(_funParamAnnotation(isImplicit)).optional.map((result) {
              SExpr? kind;
              List<SExpr> constraints;
              if (result == null) {
                kind = null;
                constraints = const [];
              } else {
                final (k, cs) = result;
                kind = k;
                constraints = cs;
              }
              return SFunTypeParam(
                name.$1,
                kind,
                isImplicit: isImplicit,
                constraints: constraints,
                span: name.$2,
              );
            }),
          )
          .sepBy(_sym(',')),
    )
    .thenSkip(_sym(close));

/// Parse the annotation after `:` in a type parameter.
///
/// For explicit `[...]` groups, supports constraint syntax:
///   - `Type`, `Prop`, `SProp` → kind annotation, no constraints
///   - `Eq` → treated as constraint, kind defaults to null
///   - `Eq & Ord` → multiple constraints
///
/// For implicit `{...}` groups, the annotation is a plain kind.
Parser<ParseError, (SExpr?, List<SExpr>)> _funParamAnnotation(bool isImplicit) {
  if (isImplicit) {
    // Implicit groups: plain kind annotation (no type expression).
    return _expr.map((e) => (e, const <SExpr>[]));
  }
  // Explicit groups: may be kind annotation or constraint(s).
  return _expr.sepBy1(_sym('&')).map((exprs) {
    final first = exprs.first;
    // Single sort keyword → kind annotation.
    if (exprs.length == 1 &&
        (first.kind is STypeKind ||
            first.kind is SPropKind ||
            first.kind is SSPropKind)) {
      return (first, const <SExpr>[]);
    }
    // Constraint(s).
    return (null, exprs);
  });
}

final Parser<ParseError, List<SFunTypeParam>> _funTypeParams =
    _funTypeParamGroup('[', ']', false)
        .or(_funTypeParamGroup('{', '}', true))
        .many
        .map((groups) => [for (final g in groups) ...g]);

/// Value parameters: `( name ':' expr (',' name ':' expr)* )` or `()`.
final Parser<ParseError, List<(String, SExpr, DoxaSpan)>> _valueParams = _sym(
      '(',
    )
    .skipThen(
      _identWithSpan
          .flatMap<(String, SExpr, DoxaSpan)>(
            (name) =>
                _sym(':').skipThen(_expr).map((t) => (name.$1, t, name.$2)),
          )
          .sepBy(_sym(','))
          .optional
          .map((r) => r ?? []),
    )
    .thenSkip(_sym(')'));

/// Optional `{struct <name>}` annotation on a `fun` declaration.
///
/// Parsed as a whole atom so that the opening `{` is only consumed when
/// followed by `struct`. If the current position is NOT `{struct`, the
/// parser returns null without consuming input.
final Parser<ParseError, String?> _structAnn =
    _sym('{')
        .skipThen(_keyword('struct'))
        .skipThen(_ident)
        .thenSkip(_sym('}'))
        .optional;

/// Optional `decreases (name, name, ...)` annotation on a `fun`
/// declaration. Returns the list of parameter names, or null when the
/// annotation is absent. `decreases` is reserved, so the return-type
/// expression stops before it and this combinator runs in the ordinary
/// case. Once the keyword is present the parser commits: a missing
/// `(` is a parse error at the keyword's successor, not a silent
/// fallback to the structural-recursion check.
final Parser<ParseError, List<String>?> _decreases = _keyword(
  'decreases',
).optional.flatMap(
  (kw) =>
      kw == null
          ? succeed<ParseError, List<String>?>(null)
          : _sym('(').skipThen(_ident.sepBy(_sym(','))).thenSkip(_sym(')')),
);

/// Build a `fun` body parser with the given [isOpaque] flag.
///
/// The parser chain is: name typeParams? valueParams ':' expr structAnn?
/// decreases? '=' (expr | blockExpr).
Parser<ParseError, SFunKind> _mkFunBody(bool isOpaque) => _ident.flatMap(
  (name) => _funTypeParams.flatMap(
    (tps) => _valueParams.optional.flatMap(
      (ps) => _sym(':')
          .skipThen(_expr)
          .flatMap(
            (ret) => _structAnn.flatMap(
              (structAnn) => _decreases.flatMap(
                (tby) => (_sym('=').skipThen(_expr) | _blockExpr).map((body) {
                  final params = ps ?? const <(String, SExpr, DoxaSpan)>[];
                  return SFunKind(
                    name,
                    tps,
                    [for (final param in params) (param.$1, param.$2)],
                    ret,
                    body,
                    isOpaque: isOpaque,
                    structAnn: structAnn,
                    decreases: tby,
                    paramSpans: [for (final param in params) param.$3],
                  );
                }),
              ),
            ),
          ),
    ),
  ),
);

/// Build a fun-block-member parser with the given [isOpaque] flag.
Parser<ParseError, SFunBlockMember> _mkFunMember(bool isOpaque) =>
    position<ParseError>().flatMap(
      (start) => _mkFunBody(isOpaque)
          .zip(position<ParseError>())
          .map((pair) => SFunBlockMember(pair.$1, DoxaSpan(start, pair.$2))),
    );

/// A `fun` declaration, possibly chained with `and` into a mutual
/// block. Block members carry per-member [SFunBlockMember] spans
/// (SPEC §6) so diagnostics in a mutual fun block cite the
/// individual function, not the whole block.
final Parser<ParseError, SDecl> _funDecl = position<ParseError>().flatMap(
  (start) => _opaqueMod.flatMap(
    (isOpaque) => _keyword('fun')
        .skipThen(_mkFunMember(isOpaque))
        .flatMap(
          (first) => _keyword('and')
              .skipThen(_mkFunMember(isOpaque))
              .many
              .zip(position<ParseError>())
              .map((pair) {
                final more = pair.$1;
                final end = pair.$2;
                final blockSpan = DoxaSpan(start, end);
                if (more.isEmpty) {
                  return SDecl(first.fun, blockSpan);
                }
                return SDecl(SFunBlockKind([first, ...more]), blockSpan);
              }),
        ),
  ),
);

/// A single constructor declaration inside a `data { ... }` block:
/// `ident ':' expr`. The span covers the whole constructor.
final Parser<ParseError, SCtorDecl> _ctorDecl = position<ParseError>().flatMap(
  (start) => _ident.flatMap(
    (name) => _sym(':')
        .skipThen(_expr.zip(position<ParseError>()))
        .map((pair) => SCtorDecl(name, pair.$1, DoxaSpan(start, pair.$2))),
  ),
);

/// The body of a `data` declaration: `'{' ctor (';' ctor)* ';'? '}'`.
///
/// Semicolons separate constructors; a trailing semicolon is allowed.
/// An empty body parses but the elaborator rejects data types with no
/// constructors.
/// Separator between constructors in a `data` body: `|` or `;`.
final Parser<ParseError, String> _ctorSep = _sym('|') | _sym(';');

final Parser<ParseError, ({List<SCtorDecl> ctors, int bodyEnd})> _ctorList =
    _sym('{')
        .skipThen(_ctorDecl.sepBy(_ctorSep))
        .thenSkip(_ctorSep.optional)
        .zip(string('}').zip(position<ParseError>()).thenSkip(_ws))
        .map((pair) => (ctors: pair.$1, bodyEnd: pair.$2.$2));

/// Walk a Pi chain to find the rightmost expression (the result type).
SExpr _resultType(SExpr expr) {
  var cur = expr;
  while (cur.kind is SPiKind) {
    cur = (cur.kind as SPiKind).codomain;
  }
  return cur;
}

/// True when [expr] is a (possibly applied) reference to [dataName].
bool _isDataRef(SExpr expr, String dataName) {
  switch (expr.kind) {
    case SIdentKind(:final name):
      return name == dataName;
    case SAppKind(:final fn):
      return _isDataRef(fn, dataName);
    default:
      return false;
  }
}

/// Detect whether a list of constructor entries is a product form
/// (field declarations) vs. a sum form (constructor declarations).
///
/// A product form has entries whose result type does NOT reference
/// the data type name. A sum form has at least one entry whose
/// result type references the data type name.
bool _isProductForm(List<SCtorDecl> ctors, String dataName) =>
    ctors.isNotEmpty &&
    ctors.every((c) => !_isDataRef(_resultType(c.type), dataName));

/// Desugar product-form fields into a single `mk` constructor.
///
/// `data Point[A: Type] : Type { x: A; y: A }` desugars to
/// `data Point[A: Type] : Type { mk : (x: A) -> (y: A) -> Point[A] }`.
List<SCtorDecl> _desugarProduct(
  List<SCtorDecl> fields,
  String dataName,
  List<(String, SExpr?)> tps,
) {
  const span = DoxaSpan.synthetic;
  // Build result type: DataName applied to type params.
  SExpr resultType = SExpr(SIdentKind(dataName), span);
  for (final tp in tps) {
    resultType = SExpr(
      SAppKind(resultType, SExpr(SIdentKind(tp.$1), span)),
      span,
    );
  }
  // Build Pi chain from fields (right-to-left) using named binders.
  SExpr ctorType = resultType;
  for (final field in fields.reversed) {
    ctorType = SExpr(SPiKind(field.name, field.type, ctorType), span);
  }
  return [SCtorDecl('mk', ctorType, span)];
}

/// A single `data` body (post-`data` or post-`and data` keyword):
/// ident typeparams? ':' expr '{' (ctors | fields) '}'.
///
/// Supports both sum form (constructor declarations with `;` or `|`
/// separators) and product form (field declarations that desugar to
/// a single `mk` constructor).
///
/// Returns the [SDataKind] alone; the containing [_dataDecl] wraps it
/// in an [SDecl] directly or inside an [SDataBlockKind] when chained.
final Parser<ParseError, SDataKind> _dataBody = _ident.flatMap(
  (name) => _typeParams.optional.flatMap(
    (tps) => _sym(':')
        .skipThen(_expr)
        .flatMap(
          (signature) => _ctorList.map((body) {
            final resolvedTps = tps ?? const <(String, SExpr?)>[];
            if (_isProductForm(body.ctors, name)) {
              return SDataKind(
                name,
                resolvedTps,
                signature,
                _desugarProduct(body.ctors, name, resolvedTps),
                productFields: body.ctors,
                bodyEnd: body.bodyEnd,
              );
            }
            return SDataKind(
              name,
              resolvedTps,
              signature,
              body.ctors,
              bodyEnd: body.bodyEnd,
            );
          }),
        ),
  ),
);

/// One member inside a mutual `data` block, pre-wrapped with its
/// own per-member source span. The start is captured before the
/// `data` / `and data` keyword; the end is captured after the
/// closing `}`.
final Parser<ParseError, SDataBlockMember> _dataMember = position<ParseError>()
    .flatMap(
      (start) => _dataBody
          .zip(position<ParseError>())
          .map((pair) => SDataBlockMember(pair.$1, DoxaSpan(start, pair.$2))),
    );

/// A `data` declaration, possibly chained with `and data` into a
/// mutual block.
///
/// Grammar:
///   dataDecl := 'data' dataBody ('and' 'data' dataBody)*
///
/// When no `and` appears the result is a plain [SDataKind] wrapped in
/// an [SDecl]. When `and data` chains, the result is wrapped in an
/// [SDataBlockKind] with [SDataBlockMember] entries preserving each
/// member's own span, so diagnostics on individual block members can
/// cite precise source regions (SPEC §6).
final Parser<ParseError, SDecl> _dataDecl = position<ParseError>().flatMap(
  (start) => _keyword('data')
      .skipThen(_dataMember)
      .flatMap(
        (first) =>
            (_keyword('and').skipThen(_keyword('data')).skipThen(_dataMember))
                .many
                .zip(position<ParseError>())
                .map((pair) {
                  final more = pair.$1;
                  final end = pair.$2;
                  final blockSpan = DoxaSpan(start, end);
                  if (more.isEmpty) {
                    return SDecl(first.data, blockSpan);
                  }
                  return SDecl(SDataBlockKind([first, ...more]), blockSpan);
                }),
      ),
);

// ===========================================================================
// Tactics and theorem declarations.
// ===========================================================================

/// A single tactic step inside a `by { ... }` block.
final Parser<ParseError, STacticStep> _tacticStep =
    _keyword(
      'intro',
    ).skipThen(_ident.optional).map<STacticStep>(STacticIntro.new) |
    _keyword(
      'exact',
    ).skipThen(defer(() => _expr)).map<STacticStep>(STacticExact.new) |
    _keyword(
      'apply',
    ).skipThen(defer(() => _expr)).map<STacticStep>(STacticApply.new) |
    _keyword('refl').map<STacticStep>((_) => const STacticRefl()) |
    _keyword(
      'rewrite',
    ).skipThen(defer(() => _expr)).map<STacticStep>(STacticRewrite.new) |
    _keyword(
      'induction',
    ).skipThen(_ident).map<STacticStep>(STacticInduction.new) |
    _keyword('revert').skipThen(_ident).map<STacticStep>(STacticRevert.new) |
    _keyword('simp')
        .skipThen(_tacticLemmaList.optional)
        .map<STacticStep>((lemmas) => STacticSimp(lemmas ?? const <SExpr>[])) |
    _keyword('cases').skipThen(_ident).map<STacticStep>(STacticCases.new) |
    _keyword(
      'constructor',
    ).map<STacticStep>((_) => const STacticConstructor()) |
    _keyword('auto')
        .skipThen(_lex(_nat).optional)
        .map<STacticStep>((depth) => STacticAuto(depth ?? 5)) |
    _keyword('omega').map<STacticStep>((_) => const STacticOmega()) |
    _keyword('trivial').map<STacticStep>((_) => const STacticTrivial()) |
    _keyword('have')
        .skipThen(_ident)
        .flatMap(
          (name) => _sym(':')
              .skipThen(defer(() => _expr))
              .flatMap(
                (type) => (_sym(':').skipThen(_sym('=')) | _sym('='))
                    .skipThen(defer(() => _expr))
                    .optional
                    .map<STacticStep>(
                      (proof) => STacticHave(name, type, proof),
                    ),
              ),
        );

/// Parse one tactic step, as written after `:step` in the REPL.
///
/// Returns the same [STacticStep] the by-block parser produces, so the
/// REPL and a `by` block accept identical surface syntax.
Result<ParseError, STacticStep> parseTacticStep(String input) =>
    _ws.skipThen(_tacticStep).thenSkip(_ws).thenSkip(eof()).run(input);

/// A bracketed lemma list for `simp`: `[e1, e2, ...]`.
final Parser<ParseError, List<SExpr>> _tacticLemmaList = _sym(
  '[',
).skipThen(defer(() => _expr).sepBy(_sym(','))).thenSkip(_sym(']'));

/// A sequence of tactic steps separated by `;`: `step; step; ...`.
final Parser<ParseError, List<STacticStep>> _tacticAlternative = _tacticStep
    .sepBy1(_sym(';'));

/// A `by { ... }` block: `by { alt1 | alt2 | ... }`.
///
/// Returns the list of alternatives, each alternative being a list of
/// sequentially-composed steps.
final Parser<ParseError, List<List<STacticStep>>> _tacticBlock = _keyword('by')
    .skipThen(_sym('{'))
    .skipThen(_tacticAlternative.sepBy1(_sym('|')))
    .thenSkip(_sym('}'));

/// A `theorem` declaration: `theorem name : type := expr`.
///
/// Desugars to a [SValKind] with the same structure as `val`.
/// Accepts both `:=` and `=` as the body marker.
final Parser<ParseError, SDecl> _theoremDecl = position<ParseError>().flatMap(
  (start) => _keyword('theorem')
      .skipThen(_ident)
      .flatMap(
        (name) => _sym(':')
            .skipThen(_expr)
            .flatMap(
              (type) => (_sym(':').skipThen(_sym('=')) | _sym('='))
                  .skipThen(_expr.zip(position<ParseError>()))
                  .map(
                    (pair) => SDecl(
                      SValKind(name, type, pair.$1),
                      DoxaSpan(start, pair.$2),
                    ),
                  ),
            ),
      ),
);

/// A method inside a `typeclass`: `fun name params ':' retType ('=' expr)?`.
final Parser<ParseError, SClassMethod> _classMethod = position<ParseError>()
    .flatMap(
      (start) => _keyword('fun')
          .skipThen(_ident)
          .flatMap(
            (name) => _valueParams.optional.flatMap(
              (params) => _sym(':')
                  .skipThen(_expr)
                  .flatMap(
                    (retType) => (_sym('=').skipThen(_expr)).optional.flatMap(
                      (defaultBody) => _buildMethodBody(
                        name,
                        params ?? const [],
                        retType,
                        defaultBody,
                        start,
                      ),
                    ),
                  ),
            ),
          ),
    );

SExpr _buildMethodPi(
  String name,
  List<(String, SExpr, DoxaSpan)> params,
  SExpr retType,
  DoxaSpan span,
) {
  // A method with no parameters is its return type; give it the method
  // span so a duplicate diagnostic can point at the declaration.
  var ty = params.isEmpty ? SExpr(retType.kind, span) : retType;
  for (final p in params.reversed) {
    ty = SExpr(SPiKind(p.$1, p.$2, ty, paramSpan: p.$3), span);
  }
  return ty;
}

Parser<ParseError, SClassMethod> _buildMethodBody(
  String name,
  List<(String, SExpr, DoxaSpan)> params,
  SExpr retType,
  SExpr? defaultBody,
  int start,
) {
  final methodSpan =
      retType.span.isSynthetic
          ? DoxaSpan.synthetic
          : DoxaSpan(start, retType.span.end);
  final body = defaultBody;
  return succeed<ParseError, SClassMethod>(
    SClassMethod(
      name,
      _buildMethodPi(name, params, retType, methodSpan),
      defaultBody: body,
    ),
  );
}

/// A `typeclass` declaration: `typeclass Eq[A] { fun equals(x: A, y: A): Bool }`.
final Parser<ParseError, SDecl> _typeclassDecl = position<ParseError>().flatMap(
  (start) => _keyword('typeclass')
      .skipThen(_ident)
      .flatMap(
        (name) => _typeParams.optional.flatMap(
          (tps) => _sym(':')
              .skipThen(_expr)
              .optional
              .flatMap(
                (superclass) => _sym('{')
                    .skipThen(_classMethod.thenSkip(_sym(';').optional).many)
                    .thenSkip(_sym('}'))
                    .zip(position<ParseError>())
                    .map(
                      (pair) => SDecl(
                        STypeclassKind(
                          name,
                          tps ?? const [],
                          pair.$1,
                          superclass: superclass,
                        ),
                        DoxaSpan(start, pair.$2),
                      ),
                    ),
              ),
        ),
      ),
);

/// An `impl` declaration:
/// `impl Eq[Int] { fun equals(x, y) { x == y } }` or
/// `impl[A: Eq] Eq[List A] { ... }`.
///
/// The optional type-parameter groups come before the class reference and
/// use the same bracket and constraint syntax as `fun`. No expression
/// starts with `[`, so `[...]` after `impl` is unambiguous. A `{...}`
/// group could also begin a block expression, but an instance without a
/// class reference is invalid either way, so the two readings cannot both
/// parse.
///
/// Each member is a full `fun` declaration (starting with `fun` keyword).
final Parser<ParseError, SDecl> _implDecl = position<ParseError>().flatMap(
  (start) => _keyword('impl')
      .skipThen(_funTypeParams)
      .flatMap(
        (typeParams) => _expr.flatMap(
          (typeclassRef) => _sym('{')
              .skipThen(_implFunMember.thenSkip(_sym(';').optional).many)
              .thenSkip(_sym('}'))
              .zip(position<ParseError>())
              .map(
                (pair) => SDecl(
                  SImplKind(typeParams, typeclassRef, pair.$1),
                  DoxaSpan(start, pair.$2),
                ),
              ),
        ),
      ),
);

/// A single `fun` inside an `impl` block, consuming `fun` keyword.
final Parser<ParseError, SFunKind> _implFunMember = _keyword(
  'fun',
).skipThen(_mkFunBody(false));

/// Any declaration.
///
/// Order matters: `_dataDecl` is tried before `_funDecl` so that the mutual
/// `fun … and …` parser does not encounter stray `and` tokens left by a
/// preceding `data` block. Each sub-parser starts with its own keyword and
/// consumes trailing whitespace; Rumil's `Or` restores state on failure, so
/// an earlier alternative that partially consumes input (e.g. `_opaqueMod`
/// inside `_funDecl` when the keyword turns out to be `data`) is fully
/// rolled back.
final Parser<ParseError, SDecl> _decl =
    _typeclassDecl |
    _implDecl |
    _importDecl |
    _dataDecl |
    _theoremDecl |
    _valDecl |
    _typeDecl |
    _funDecl;

/// Parse zero or more declarations until EOF, preserving the furthest parse
/// position from failed declarations. Unlike [_decl.many], when a declaration
/// fails partway through the [_decl] parser (e.g. due to an invalid character),
/// the failure's [Location] is kept by the [_or] combinator's position
/// comparison so diagnostics cite the actual problem rather than the start of
/// the declaration.
final Parser<ParseError, List<SDecl>> _programDecls = defer(
  () => _decl
      .flatMap((first) => _programDecls.map((rest) => [first, ...rest]))
      .or(_ws.skipThen(eof()).map((_) => <SDecl>[])),
);

/// A leading sequence of complete imports, without an EOF requirement.
final Parser<ParseError, List<SDecl>> _leadingImports = _ws.skipThen(
  _importDecl.many,
);

/// A program: leading whitespace, declarations, eof.
final Parser<ParseError, SProgram> _program = _ws
    .skipThen(_programDecls)
    .map(SProgram.new);
