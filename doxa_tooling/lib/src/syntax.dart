/// Token and syntax alphabets for Doxa's surface grammar.
///
/// These are the `Tok` and `Syn` type parameters for [GreenNode] and
/// [RedTree]. Every Phase 1+ consumer references these enums; adding a
/// new keyword or syntax construct requires an entry in exactly one place.
///
/// This module also provides the canonical `rumil_tokens` Token →
/// [DoxaToken] mapping used by both [parse_tree.dart] and [cst.dart].
library;

import 'package:rumil/rumil.dart';
import 'package:rumil_tokens/rumil_tokens.dart'
    show
        Token,
        Keyword,
        TypeName,
        Comment,
        NumberLit,
        Punctuation,
        Operator,
        Whitespace,
        Plain,
        Spanned;

import 'tokenize.dart' show tokenizeDoxaSpans;

// ---------------------------------------------------------------------------
// Token alphabet (terminals / leaf nodes)
// ---------------------------------------------------------------------------

/// Every classified span the tokenizer / parser can produce.
enum DoxaToken {
  /// `(`
  lparen,

  /// `)`
  rparen,

  /// `{`
  lbrace,

  /// `}`
  rbrace,

  /// `[`
  lbracket,

  /// `]`
  rbracket,

  /// `:`
  colon,

  /// `;`
  semicolon,

  /// `,`
  comma,

  /// `|`
  pipe,

  /// `.`
  dot,

  /// `->`
  arrow,

  /// `=>`
  fatArrow,

  /// `=`
  eq,

  /// keyword `fun`
  kwFun,

  /// keyword `data`
  kwData,

  /// keyword `val`
  kwVal,

  /// keyword `type`
  kwType,

  /// keyword `match`
  kwMatch,

  /// keyword `case`
  kwCase,

  /// keyword `returning`
  kwReturning,

  /// keyword `and`
  kwAnd,

  /// keyword `import`
  kwImport,

  /// keyword `typeclass`
  kwTypeclass,

  /// keyword `impl`
  kwImpl,

  /// universe sort `Type`
  sortType,

  /// universe sort `Prop`
  sortProp,

  /// identifier (any case)
  ident,

  /// numeric literal
  number,

  /// comment (`//` or `/* */`)
  comment,

  /// whitespace
  whitespace,

  /// unexpected / unmatched character
  error,
}

// ---------------------------------------------------------------------------
// Syntax alphabet (non-terminal nodes)
// ---------------------------------------------------------------------------

/// Every non-terminal node in the concrete syntax tree.
enum DoxaSyntax {
  /// entire source file
  sourceFile,

  /// `import "path/to/file.doxa"`
  importDecl,

  /// `val name : type = expr`
  valDecl,

  /// `type name = type`
  typeDecl,

  /// `fun name[params](args): type = body`
  funDecl,

  /// `data name[params] : indices -> sort { ctors }`
  dataDecl,

  /// a single constructor declaration inside `data`
  ctorDecl,

  /// `(x: A) => body`
  lambda,

  /// `(x: A) -> B`
  piType,

  /// juxtaposition `f x y`
  app,

  /// `match scrutinee { cases }`
  match,

  /// `case ctor b1 b2 => body`
  matchCase,

  /// `case _ => body`
  wildcardCase,

  /// `{ val x = e; ... result }`
  block,

  /// a single `val x = e` inside a block
  blockBinding,

  /// explicit type parameter list `[A, B: Type]`
  typeParams,

  /// a single type parameter `A` or `A: Type`
  typeParam,

  /// `fun` declaration's type parameter group `[A: Type]`
  funTypeParams,

  /// the `fun` parameter list `(x: A, y: B)`
  funTypeParamGroup,

  /// explicit value parameter list `(x: A, y: B)`
  valueParams,

  /// a single value parameter `x: T`
  valueParam,

  /// type argument list at use site `[A, B]`
  typeArgs,

  /// identifier reference
  ident,

  /// numeric literal
  number,

  /// universe `Type n`
  universe,

  /// full source program
  program,

  /// bracketed binder `(x: A) -> ...` or `(x: A) => ...`
  binder,

  /// application-or-arrow grouping
  appOrArrow,

  /// an atom in application position
  atom,

  /// identifier atom (with optional typeargs)
  identAtom,

  /// dotted-name suffix `.rec`
  dotSuffix,

  /// constructor pattern in match arm
  ctorPattern,

  /// bound variable inside a constructor pattern
  patternBinder,

  /// the body expression of a `fun` declaration
  funBody,

  /// a single member of a `fun ... and fun ...` block
  funMember,

  /// the body (ctor list) of a `data` declaration
  dataBody,

  /// `typeclass name[params] { methods }`
  typeclassDecl,

  /// `impl TypeClassRef { members }`
  implDecl,

  /// a single member of a `data ... and data ...` block
  dataMember,

  /// constructor list inside `data { ... }`
  ctorList,

  /// a single arm of a match expression
  caseArm,
}

// ---------------------------------------------------------------------------
// Type aliases
// ---------------------------------------------------------------------------

/// GreenNode specialised for Doxa.
typedef DoxaGreen = GreenNode<DoxaToken, DoxaSyntax>;

/// RedTree specialised for Doxa.
typedef DoxaRed = RedTree<DoxaToken, DoxaSyntax>;

// ---------------------------------------------------------------------------
// Token mapping (canonical — one copy, used by parse_tree.dart and
// cst.dart)
// ---------------------------------------------------------------------------

/// Map a `rumil_tokens` [Token] to a [DoxaToken] green node kind.
///
/// This is the single source of truth for the Phase 0 → Phase 1 token
/// bridge. Both the CST builder ([parse_tree.dart]) and the incremental
/// reparser ([cst.dart]) call this.
DoxaToken tokenKind(Token t) => switch (t) {
  Keyword _ => _keywordKind(t.text),
  TypeName _ => _typeNameKind(t.text),
  Comment _ => DoxaToken.comment,
  NumberLit _ => DoxaToken.number,
  Punctuation _ => _punctKind(t.text),
  Operator _ => _punctKind(t.text),
  Whitespace _ => DoxaToken.whitespace,
  Plain _ => DoxaToken.error,
  _ => DoxaToken.error,
};

DoxaToken _keywordKind(String text) => switch (text) {
  'fun' => DoxaToken.kwFun,
  'data' => DoxaToken.kwData,
  'val' => DoxaToken.kwVal,
  'type' => DoxaToken.kwType,
  'match' => DoxaToken.kwMatch,
  'case' => DoxaToken.kwCase,
  'returning' => DoxaToken.kwReturning,
  'and' => DoxaToken.kwAnd,
  'import' => DoxaToken.kwImport,
  'typeclass' => DoxaToken.kwTypeclass,
  'impl' => DoxaToken.kwImpl,
  _ => DoxaToken.error,
};

DoxaToken _typeNameKind(String text) => switch (text) {
  'Type' => DoxaToken.sortType,
  'Prop' => DoxaToken.sortProp,
  _ => DoxaToken.ident,
};

DoxaToken _punctKind(String text) => switch (text) {
  '(' => DoxaToken.lparen,
  ')' => DoxaToken.rparen,
  '{' => DoxaToken.lbrace,
  '}' => DoxaToken.rbrace,
  '[' => DoxaToken.lbracket,
  ']' => DoxaToken.rbracket,
  ':' => DoxaToken.colon,
  ';' => DoxaToken.semicolon,
  ',' => DoxaToken.comma,
  '|' => DoxaToken.pipe,
  '.' => DoxaToken.dot,
  '=' => DoxaToken.eq,
  '->' => DoxaToken.arrow,
  '=>' => DoxaToken.fatArrow,
  _ => DoxaToken.error,
};

/// Convert a [Spanned] token from rumil_tokens to a [DoxaGreen] token node.
///
/// Convenience wrapper around [tokenKind] that produces a [GreenToken]
/// directly.
DoxaGreen tokenToGreen(Spanned<Token> span) =>
    GreenToken<DoxaToken, DoxaSyntax>(tokenKind(span.token), span.token.text);

/// Tokenize [source] using the Phase 0 tokenizer and return flat green
/// token nodes.
List<DoxaGreen> tokenizeAsGreens(String source) {
  final spans = tokenizeDoxaSpans(source);
  return [for (final s in spans) tokenToGreen(s)];
}

// ---------------------------------------------------------------------------
// Reparse boundaries
// ---------------------------------------------------------------------------

/// Syntax kinds that are valid reparse boundaries.
///
/// A reparse boundary is a node whose full source text can be re-parsed
/// independently. Declaration-level nodes are natural boundaries because
/// they form self-contained units.
const Set<DoxaSyntax> reparsableKinds = {
  DoxaSyntax.sourceFile,
  DoxaSyntax.importDecl,
  DoxaSyntax.valDecl,
  DoxaSyntax.typeDecl,
  DoxaSyntax.funDecl,
  DoxaSyntax.dataDecl,
  DoxaSyntax.typeclassDecl,
  DoxaSyntax.implDecl,
  DoxaSyntax.ctorDecl,
  DoxaSyntax.block,
  DoxaSyntax.binder,
  DoxaSyntax.match,
  DoxaSyntax.matchCase,
  DoxaSyntax.wildcardCase,
  DoxaSyntax.funBody,
  DoxaSyntax.dataBody,
  DoxaSyntax.typeParams,
  DoxaSyntax.funTypeParams,
  DoxaSyntax.valueParams,
};

// ---------------------------------------------------------------------------
// Simple-token predicate
// ---------------------------------------------------------------------------

/// Returns `true` when [token] is a simple token that can be updated
/// in-place during incremental reparse (Tier 1).
///
/// Simple tokens are those whose text never affects the parse tree
/// structure: comments, whitespace, identifiers, numbers.
/// Keywords and sorts are NOT simple because changing `val` to `fun`
/// could change the declaration kind.
bool isSimpleToken(DoxaToken token) => switch (token) {
  DoxaToken.comment ||
  DoxaToken.whitespace ||
  DoxaToken.ident ||
  DoxaToken.number ||
  DoxaToken.error => true,
  _ => false,
};

/// Whether a [DoxaToken] is considered an error token (for tree validation).
bool isErrorToken(DoxaToken token) => token == DoxaToken.error;
