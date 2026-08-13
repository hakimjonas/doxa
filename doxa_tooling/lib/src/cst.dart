/// Concrete syntax tree accessors and incremental reparse for Doxa.
///
/// Builds on [parse_tree.dart] and the rumil [RedTree] infrastructure to
/// provide position-indexed queries, source reconstruction, and
/// incremental reparse after text edits.
library;

import 'package:rumil/rumil.dart';

import 'parse_tree.dart';

export 'syntax.dart' show DoxaToken, DoxaSyntax, DoxaGreen, DoxaRed;

// ---------------------------------------------------------------------------
// Combined parse -> RedTree
// ---------------------------------------------------------------------------

/// Parse [source] and return a [DoxaRed] for position-indexed queries.
Result<ParseError, DoxaRed> parseProgramCst(String source) =>
    parseProgramTree(source).map((pt) => DoxaRed(pt.tree, source));

/// Parse a single expression and return a [DoxaRed].
Result<ParseError, DoxaRed> parseExprCst(String source) =>
    parseExprTree(source).map((pt) => DoxaRed(pt.tree, source));

// ---------------------------------------------------------------------------
// Position queries
// ---------------------------------------------------------------------------

/// Find the deepest syntax node containing [offset] in [tree].
DoxaRed? nodeAt(DoxaRed tree, int offset) => tree.nodeAt(offset);

/// Walk up to the enclosing declaration or block from [node].
DoxaRed? enclosingDecl(DoxaRed node) {
  var current = node;
  while (current.parentNode != null) {
    current = current.parentNode!;
    if (current.syntaxKind case final DoxaSyntax kind? when _isDeclKind(kind)) {
      return current;
    }
  }
  return null;
}

bool _isDeclKind(DoxaSyntax kind) => switch (kind) {
  DoxaSyntax.valDecl ||
  DoxaSyntax.typeDecl ||
  DoxaSyntax.funDecl ||
  DoxaSyntax.dataDecl ||
  DoxaSyntax.ctorDecl ||
  DoxaSyntax.match ||
  DoxaSyntax.block => true,
  _ => false,
};

/// The children of [node], as an iterable.
List<DoxaRed> childrenOf(DoxaRed node) => node.children;

/// Reconstruct the original source text from [tree].
String toSource(DoxaRed tree) => tree.text;

// ---------------------------------------------------------------------------
// Incremental reparse
// ---------------------------------------------------------------------------

Parser<ParseError, DoxaGreen> _buildFullParser() {
  final all = anyChar().many.capture;
  return all
      .flatMap((source) {
        final result = parseProgramTree(source);
        final tree =
            result.valueOrNull?.tree ??
            GreenTree<DoxaToken, DoxaSyntax>(
              DoxaSyntax.sourceFile,
              tokenizeAsGreens(source),
            );
        return succeed<ParseError, DoxaGreen>(tree);
      })
      .thenSkip(eof());
}

Parser<ParseError, DoxaGreen> _buildDeclarationParser(DoxaSyntax kind) {
  final all = anyChar().many.capture;
  return all
      .flatMap((source) {
        final result = parseProgramTree(source);
        final tree = switch (result) {
          Success(:final value) || Partial(:final value) => (value.tree
                  as GreenTree<DoxaToken, DoxaSyntax>)
              .children
              .whereType<GreenTree<DoxaToken, DoxaSyntax>>()
              .firstWhere(
                (node) => node.kind == kind,
                orElse: () => GreenTree(kind, tokenizeAsGreens(source)),
              ),
          _ => GreenTree(kind, tokenizeAsGreens(source)),
        };
        return succeed<ParseError, DoxaGreen>(tree);
      })
      .thenSkip(eof());
}

/// Build the [ReparseableParsers] for Doxa grammar.
///
/// The whole-file parser ([ReparseableParsers.full]) calls
/// [parseProgramTree] to produce a structured green tree. Sub-parsers for
/// declaration-level blocks are reparsed through the existing AST parser, then
/// converted back to their corresponding green subtree. This retains one
/// grammar authority while allowing Rumil to splice an edited declaration.
///
/// On parse failure the tokenizer produces a flat token tree so the
/// lossless invariant is preserved.
ReparseableParsers<DoxaToken, DoxaSyntax> buildDoxaReparser() =>
    ReparseableParsers<DoxaToken, DoxaSyntax>(
      full: _buildFullParser(),
      byKind: {
        for (final kind in <DoxaSyntax>[
          DoxaSyntax.importDecl,
          DoxaSyntax.valDecl,
          DoxaSyntax.typeDecl,
          DoxaSyntax.funDecl,
          DoxaSyntax.dataDecl,
          DoxaSyntax.typeclassDecl,
          DoxaSyntax.implDecl,
        ])
          kind: _buildDeclarationParser(kind),
      },
      isSimpleToken: isSimpleToken,
      onParseFailure:
          (source) => GreenTree<DoxaToken, DoxaSyntax>(
            DoxaSyntax.sourceFile,
            tokenizeAsGreens(source),
          ),
    );

/// Reparser configuration that skips token-level updates.
///
/// Use this when an edit inserts syntax punctuation beside an otherwise simple
/// token. The token-level path assumes the replacement stays within the same
/// lexical token class.
ReparseableParsers<DoxaToken, DoxaSyntax> buildDoxaStructuralReparser() {
  final parsers = buildDoxaReparser();
  return ReparseableParsers<DoxaToken, DoxaSyntax>(
    full: parsers.full,
    byKind: parsers.byKind,
    isSimpleToken: (_) => false,
    onParseFailure: parsers.onParseFailure,
  );
}

// ---------------------------------------------------------------------------
// Convenience wrapper
// ---------------------------------------------------------------------------

/// Incrementally reparse [source] after [edit], using [previousTree].
///
/// When no [parsers] is provided, [buildDoxaReparser] is used.
IncrementalResult<DoxaToken, DoxaSyntax> reparse(
  DoxaGreen previousTree,
  String previousSource,
  TextEdit edit, {
  ReparseableParsers<DoxaToken, DoxaSyntax>? parsers,
}) {
  final p = parsers ?? buildDoxaReparser();
  return incrementalParse(previousTree, previousSource, edit, p);
}
