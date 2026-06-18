/// Doxa tokenizer: classifies source spans using a [rumil_tokens] grammar.
///
/// Provides a single source of truth for syntax highlighting across all
/// rendering contexts (server-side Dart, WASM client, static build).
/// Every consumer calls the same grammar → same token classes → same CSS.
library;

import 'package:rumil/rumil.dart';
import 'package:rumil_tokens/rumil_tokens.dart';

export 'package:rumil_tokens/rumil_tokens.dart' show
    Token,
    Spanned,
    LangGrammar,
    Keyword,
    TypeName,
    Comment,
    NumberLit,
    Punctuation,
    Operator,
    Identifier,
    Whitespace,
    Plain;

// ---------------------------------------------------------------------------
// Grammar
// ---------------------------------------------------------------------------

/// [LangGrammar] for Doxa surface syntax.
///
/// Token classification (matching `docs/TOOLING_PLAN.md`):
///
/// | Plan token class | rumil_tokens class | Examples         |
/// |------------------|--------------------|------------------|
/// | `keyword`        | [Keyword]          | `fun data val type match case returning and` |
/// | `sort`           | [TypeName]         | `Type Prop`      |
/// | `comment`        | [Comment]          | `// …`, `/* … */`|
/// | `number`         | [NumberLit]        | `0 1 2`          |
/// | `punctuation`    | [Punctuation]      | `(){}[]:;,|.=`   |
/// | `punctuation`    | [Operator]         | `-> =>`          |
/// | `type-name`      | [Identifier]       | `Nat List Bool` (semantic refinement in Layer 3) |
/// | `binder`         | [Identifier]       | params, lambda binders (approximate, refined in Layer 3) |
/// | `constructor`    | [Identifier]       | `zero succ nil cons` (approximate, refined in Layer 3) |
/// | `identifier`     | [Identifier]       | everything else  |
/// | `error`          | [Plain]            | unexpected chars |
const LangGrammar doxaGrammar = LangGrammar(
  name: 'doxa',
  keywords: [
    'fun',
    'data',
    'val',
    'type',
    'match',
    'case',
    'returning',
    'and',
  ],
  types: ['Type', 'Prop'],
  lineComment: '//',
  blockComment: ('/*', '*/'),
  stringDelimiters: [],
  punctuationChars: '(){}[]:;,|.=',
  multiCharOperators: ['->', '=>'],
);

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

/// Pre-built tokenizer parser for [doxaGrammar].
///
/// Cache this when tokenizing many sources against the same grammar.
final Parser<ParseError, List<Spanned<Token>>> doxaTokenizer =
    buildTokenizer(doxaGrammar);

/// Tokenize [source] into a lossless list of classified tokens.
///
/// Concatenating every token's `.text` reproduces [source] exactly.
/// Equivalent to `tokenizeDoxaSpans(source).map((s) => s.token).toList()`.
List<Token> tokenizeDoxa(String source) =>
    tokenize(source, doxaGrammar);

/// Tokenize [source] into [Spanned] tokens carrying byte offsets.
///
/// The returned list satisfies:
/// - Lossless: `spans.map((s) => s.token.text).join() == source`
/// - Anchored: first span starts at 0, last ends at `source.length`
/// - Contiguous: `spans[i].end == spans[i+1].start`
List<Spanned<Token>> tokenizeDoxaSpans(String source) =>
    tokenizeSpans(source, doxaGrammar);
