/// Concrete syntax tree accessors and incremental reparse for Doxa.
///
/// Builds on [parse_tree.dart] and the rumil [RedTree] infrastructure to
/// provide position-indexed queries, source reconstruction, and
/// incremental reparse after text edits.
library;

import 'package:rumil/rumil.dart';

import 'parse_tree.dart';
import 'tokenize.dart' show tokenizeDoxaSpans;

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
        final parsed = switch (result) {
          Success(:final value) => value,
          _ => null,
        };
        if (parsed == null ||
            parsed.ast.decls.length != 1 ||
            parsed.ast.decls.single.span.start != 0 ||
            parsed.ast.decls.single.span.end != source.length) {
          return failure<ParseError, DoxaGreen>(
            CustomError('expected one complete declaration', Location.zero),
          );
        }
        final tree = parsed.tree as GreenTree<DoxaToken, DoxaSyntax>;
        final children =
            tree.children.whereType<GreenTree<DoxaToken, DoxaSyntax>>();
        if (children.length != 1 || children.single.kind != kind) {
          return failure<ParseError, DoxaGreen>(
            CustomError('declaration kind changed', Location.zero),
          );
        }
        return succeed<ParseError, DoxaGreen>(children.single);
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
  final safeTokenUpdate = _canUpdateTokenInPlace(
    previousTree,
    previousSource,
    edit,
    p,
  );
  final selected =
      safeTokenUpdate
          ? p
          : ReparseableParsers<DoxaToken, DoxaSyntax>(
            full: p.full,
            byKind: p.byKind,
            isSimpleToken: (_) => false,
            onParseFailure: p.onParseFailure,
          );
  return incrementalParse(previousTree, previousSource, edit, selected);
}

bool _canUpdateTokenInPlace(
  DoxaGreen previousTree,
  String previousSource,
  TextEdit edit,
  ReparseableParsers<DoxaToken, DoxaSyntax> parsers,
) {
  final node = DoxaRed(previousTree, previousSource).nodeAt(edit.startOffset);
  final green = node?.green;
  if (node == null || green is! GreenToken<DoxaToken, DoxaSyntax>) {
    return false;
  }
  if (!parsers.isSimpleToken(green.kind) ||
      edit.startOffset < node.offset ||
      edit.endOffset > node.endOffset) {
    return false;
  }

  final newTokenText =
      green.text.substring(0, edit.startOffset - node.offset) +
      edit.newText +
      green.text.substring(edit.endOffset - node.offset);
  if (newTokenText.isEmpty) return false;

  final newEnd = node.endOffset + edit.lengthDelta;
  final newSource = edit.apply(previousSource);
  final retokenized = tokenizeDoxaSpans(newSource);
  return retokenized.any(
    (span) =>
        span.start == node.offset &&
        span.end == newEnd &&
        span.token.text == newTokenText &&
        tokenKind(span.token) == green.kind,
  );
}
