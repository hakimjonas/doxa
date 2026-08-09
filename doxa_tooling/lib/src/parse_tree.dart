/// GreenNode concrete syntax tree for Doxa.
///
/// Builds a lossless [GreenNode] tree by aligning the Phase 0 tokenizer
/// output with the existing AST ([SProgram]) spans. This avoids
/// duplicating the 800-line parser while still producing a position-
/// indexable, source-reconstructable CST.
///
/// The existing `parse.dart` and `parseProgram`/`parseExpr` are unchanged.
library;

import 'package:rumil/rumil.dart';
import 'package:rumil_tokens/rumil_tokens.dart' show Spanned, Token;

import 'package:doxa/doxa.dart';
import 'package:doxa/doxa.dart';
import 'syntax.dart';
import 'tokenize.dart' show tokenizeDoxaSpans;

export 'syntax.dart'
    show
        DoxaToken,
        DoxaSyntax,
        DoxaGreen,
        DoxaRed,
        reparsableKinds,
        isSimpleToken,
        isErrorToken,
        tokenKind,
        tokenToGreen,
        tokenizeAsGreens;

// ---------------------------------------------------------------------------
// Result type
// ---------------------------------------------------------------------------

/// The result of a tree-producing parse.
final class ParseTreeResult {
  /// The SExpr/SDecl abstract syntax tree.
  final SProgram ast;

  /// The lossless GreenNode concrete syntax tree.
  final DoxaGreen tree;

  /// Creates a parse tree result.
  const ParseTreeResult(this.ast, this.tree);
}

// ---------------------------------------------------------------------------
// Top-level entry points
// ---------------------------------------------------------------------------

/// Parse [source] into both an AST and a GreenNode CST.
///
/// The existing callers of [parseProgram] are unchanged — this is an
/// additive entry point.
Result<ParseError, ParseTreeResult> parseProgramTree(String source) {
  final r = parseProgram(source);
  if (r case Success<ParseError, SProgram>(:final value)) {
    return Success(ParseTreeResult(value, _buildTree(source, value)), 0);
  }
  if (r case Partial<ParseError, SProgram>(:final value)) {
    return Partial(
      ParseTreeResult(value, _buildTree(source, value)),
      () => const [],
      0,
    );
  }
  final fallback = GreenTree<DoxaToken, DoxaSyntax>(
    DoxaSyntax.sourceFile,
    tokenizeAsGreens(source),
  );
  return Partial(
    ParseTreeResult(const SProgram([]), fallback),
    () => const [],
    0,
  );
}

/// Parse a single expression into both an AST and a GreenNode CST.
Result<ParseError, ParseTreeResult> parseExprTree(String source) {
  final r = parseExpr(source);
  if (r case Success<ParseError, SExpr>(:final value)) {
    final program = SProgram([
      SDecl(SValKind('\$expr', null, value), DoxaSpan(0, source.length)),
    ]);
    return Success(ParseTreeResult(program, _buildTree(source, program)), 0);
  }
  return Partial(
    ParseTreeResult(
      const SProgram([]),
      GreenTree(DoxaSyntax.sourceFile, tokenizeAsGreens(source)),
    ),
    () => const [],
    0,
  );
}

// ---------------------------------------------------------------------------
// Tree building: tokenizer + AST spans
// ---------------------------------------------------------------------------

/// Build a [DoxaGreen] tree from [source] by grouping tokenization spans
/// according to the AST's declaration structure.
DoxaGreen _buildTree(String source, SProgram program) {
  final tokens = tokenizeDoxaSpans(source);
  if (source.isEmpty) {
    return GreenTree<DoxaToken, DoxaSyntax>(DoxaSyntax.sourceFile, []);
  }

  final declNodes = <DoxaGreen>[];
  var ti = 0;

  for (final decl in program.decls) {
    ti = _emitLeading(tokens, ti, decl.span.start, declNodes);
    final (node, nextTi) = _buildDeclNode(tokens, ti, decl);
    declNodes.add(node);
    ti = nextTi;
  }

  while (ti < tokens.length) {
    declNodes.add(tokenToGreen(tokens[ti]));
    ti++;
  }

  return GreenTree<DoxaToken, DoxaSyntax>(DoxaSyntax.sourceFile, declNodes);
}

int _emitLeading(
  List<Spanned<Token>> tokens,
  int ti,
  int start,
  List<DoxaGreen> out,
) {
  while (ti < tokens.length && tokens[ti].end <= start) {
    out.add(tokenToGreen(tokens[ti]));
    ti++;
  }
  return ti;
}

(DoxaGreen, int) _buildDeclNode(
  List<Spanned<Token>> tokens,
  int ti,
  SDecl decl,
) {
  final syn = switch (decl.kind) {
    SImportKind _ => DoxaSyntax.importDecl,
    SValKind _ => DoxaSyntax.valDecl,
    STypeAliasKind _ => DoxaSyntax.typeDecl,
    SFunKind _ => DoxaSyntax.funDecl,
    SFunBlockKind _ => DoxaSyntax.funDecl,
    SDataKind _ => DoxaSyntax.dataDecl,
    SDataBlockKind _ => DoxaSyntax.dataDecl,
    STypeclassKind _ => DoxaSyntax.dataDecl,
    SImplKind _ => DoxaSyntax.valDecl,
  };

  final children = <DoxaGreen>[];
  final end = decl.span.end;

  if (end < 0) {
    while (ti < tokens.length) {
      children.add(tokenToGreen(tokens[ti]));
      ti++;
    }
    return (GreenTree(syn, children), ti);
  }

  while (ti < tokens.length && tokens[ti].end <= end) {
    children.add(tokenToGreen(tokens[ti]));
    ti++;
  }

  return (GreenTree(syn, children), ti);
}
