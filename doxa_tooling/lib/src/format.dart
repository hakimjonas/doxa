/// Canonical code formatter for Doxa source files.
library;

import 'package:doxa/doxa.dart';
import 'package:rumil/rumil.dart';

/// Format a Doxa source string to canonical style.
String formatSource(String source, {int lineWidth = 100}) {
  if (lineWidth < 20) {
    throw ArgumentError.value(lineWidth, 'lineWidth', 'must be at least 20');
  }
  final f = _Formatter(source, lineWidth);
  return f.format();
}

/// Check whether [source] is already formatted.
bool isFormatted(String source) {
  try {
    return formatSource(source) == source;
  } on FormatException {
    return true;
  }
}

// ---------------------------------------------------------------------------
// Simple pretty-printer document type (Wadler-style)
// ---------------------------------------------------------------------------

/// Tag for [_Doc] variants.
enum _DocKind { nil, text, line, nest, group, cat }

/// A document that can be rendered flat or with line breaks.
class _Doc {
  final _DocKind kind;
  final String? text;
  final int? nest;
  final _Doc? a, b;

  const _Doc._(this.kind, {this.text, this.nest, this.a, this.b});

  static const _Doc nil = _Doc._(_DocKind.nil);
  static _Doc txt(String s) => _Doc._(_DocKind.text, text: s);
  static const _Doc line = _Doc._(_DocKind.line);
  static _Doc nst(int n, _Doc d) => _Doc._(_DocKind.nest, nest: n, a: d);
  static _Doc grp(_Doc d) => _Doc._(_DocKind.group, a: d);
  static _Doc cat(_Doc a, _Doc b) => _Doc._(_DocKind.cat, a: a, b: b);

  /// Chain multiple docs.
  static _Doc catAll(List<_Doc> docs) {
    if (docs.isEmpty) return _Doc.nil;
    var result = docs[0];
    for (var i = 1; i < docs.length; i++) {
      result = _Doc.cat(result, docs[i]);
    }
    return result;
  }

  static _Doc get space => _Doc.txt(' ');
}

// ---------------------------------------------------------------------------
// Rendering: Wadler-style with width tracking
// ---------------------------------------------------------------------------

/// Width of [doc] in flat mode (lines count as 1 char for space).
int _docFlatWidth(_Doc doc) {
  switch (doc.kind) {
    case _DocKind.nil:
      return 0;
    case _DocKind.text:
      return doc.text!.length;
    case _DocKind.line:
      return 1; // space in flat mode
    case _DocKind.nest:
      return _docFlatWidth(doc.a!);
    case _DocKind.group:
      return _docFlatWidth(doc.a!); // always check flat first
    case _DocKind.cat:
      return _docFlatWidth(doc.a!) + _docFlatWidth(doc.b!);
  }
}

void _renderDocInner(
  _Doc doc,
  StringBuffer buf,
  int col,
  int indent,
  bool flat,
  int lineWidth,
) {
  switch (doc.kind) {
    case _DocKind.nil:
      return;
    case _DocKind.text:
      buf.write(doc.text);
    case _DocKind.line:
      if (flat) {
        buf.write(' ');
      } else {
        buf.write('\n');
        buf.write(' ' * indent);
      }
    case _DocKind.nest:
      _renderDocInner(doc.a!, buf, col, indent + doc.nest!, flat, lineWidth);
    case _DocKind.group:
      final flatWidth = _docFlatWidth(doc.a!);
      if (flat && col + flatWidth <= lineWidth) {
        _renderDocInner(doc.a!, buf, col, indent, true, lineWidth);
      } else {
        _renderDocInner(doc.a!, buf, col, indent, false, lineWidth);
      }
    case _DocKind.cat:
      final before = buf.length;
      _renderDocInner(doc.a!, buf, col, indent, flat, lineWidth);
      final consumed = buf.length - before;
      _renderDocInner(doc.b!, buf, col + consumed, indent, flat, lineWidth);
  }
}

// ---------------------------------------------------------------------------
// Formatter
// ---------------------------------------------------------------------------

class _Formatter {
  final String source;
  final int lineWidth;
  final StringBuffer _buf = StringBuffer();
  int _indent = 0;
  bool _atLineStart = true;

  static const int _indentSize = 2;

  // Comment tracking
  final List<_CommentInfo> _comments = [];
  int _commentIx = 0;

  _Formatter(this.source, this.lineWidth);

  String format() {
    _extractComments();
    _buf.clear();
    _indent = 0;
    _atLineStart = true;
    _currentCol = 0;
    _commentIx = 0;

    final result = parseProgram(source);

    final program = switch (result) {
      Success<ParseError, SProgram>(:final value) => value,
      Partial<ParseError, SProgram>(:final value) => value,
      Failure<ParseError, SProgram>() =>
        throw const FormatException('Cannot format source with parse errors'),
    };

    _visitProgram(program);
    _emitCommentsBefore(source.length);

    var out = _buf.toString();
    // Collapse 3+ consecutive `\n` into 2 (at most 1 blank line).
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // Strip leading blank lines (but not leading whitespace/comments).
    out = out.replaceFirst(RegExp(r'^(\n)+'), '');
    // Ensure exactly one trailing newline.
    out = '${out.trimRight()}\n';
    return out;
  }

  // -------------------------------------------------------------------------
  // Doc helpers
  // -------------------------------------------------------------------------

  /// Render a Doc to the output buffer, tracking position for width checks.
  void _writeDoc(_Doc doc) {
    final rendered = _renderDocAt(doc, _currentCol);
    _buf.write(rendered);
    // Update column tracking based on last line in rendered output.
    final lastNl = rendered.lastIndexOf('\n');
    _atLineStart = lastNl >= 0;
    _currentCol =
        lastNl >= 0
            ? rendered.length - lastNl - 1
            : _currentCol + rendered.length;
  }

  /// Current column on the output line (0-based).  Updated by [_writeDoc].
  int _currentCol = 0;

  /// Render [doc] assuming the current column is [startCol].
  String _renderDocAt(_Doc doc, int startCol) {
    final buf = StringBuffer();
    _renderDocInner(doc, buf, startCol, 0, false, lineWidth);
    return buf.toString();
  }

  // -------------------------------------------------------------------------
  // Comment extraction
  // -------------------------------------------------------------------------

  /// Scan [source] for `//` line comments and `/* */` block comments.
  /// Returns spans as [_CommentInfo] records for later emission.
  ///
  /// Uses a simple string scanner instead of the full tokenizer
  /// because we only need comment boundaries — not token classification.
  /// This eliminates a redundant tokenizer pass (parseProgram already
  /// tokenizes internally).
  void _extractComments() {
    _comments.clear();
    var i = 0;
    final len = source.length;
    while (i < len) {
      if (source[i] == '/' && i + 1 < len) {
        if (source[i + 1] == '/') {
          // Line comment: scan to end of line.
          final start = i;
          i += 2;
          while (i < len && source[i] != '\n') {
            i++;
          }
          _comments.add(_CommentInfo(start, i, source.substring(start, i)));
          continue;
        } else if (source[i + 1] == '*') {
          // Block comment: scan to `*/`.
          final start = i;
          i += 2;
          while (i + 1 < len && !(source[i] == '*' && source[i + 1] == '/')) {
            i++;
          }
          if (i + 1 < len) i += 2;
          _comments.add(_CommentInfo(start, i, source.substring(start, i)));
          continue;
        }
      }
      i++;
    }
  }

  void _emitCommentsBefore(int offset) {
    while (_commentIx < _comments.length) {
      final c = _comments[_commentIx];
      if (c.start >= offset) break;

      final isFreshLine =
          c.start == 0 ||
          source[c.start - 1] == '\n' ||
          source[c.start - 1] == '\r';

      if (isFreshLine) {
        if (!_atLineStart) {
          _newline();
        }
        _write(c.text);
        _newline();
      } else {
        _space();
        _write(c.text);
        _newline();
      }
      _commentIx++;
    }
  }

  void _emitRemainingComments() {
    _emitCommentsBefore(source.length);
  }

  // -------------------------------------------------------------------------
  // Output helpers
  // -------------------------------------------------------------------------

  void _write(String text) {
    _buf.write(text);
    _atLineStart = false;
    _currentCol += text.length;
  }

  void _newline() {
    _buf.write('\n');
    _atLineStart = true;
    _currentCol = 0;
    _writeIndent();
  }

  void _writeIndent() {
    if (_atLineStart && _indent > 0) {
      final spaces = ' ' * (_indent * _indentSize);
      _buf.write(spaces);
      _currentCol += spaces.length;
    }
  }

  void _indentBy(int delta) {
    _indent += delta;
  }

  void _space() {
    if (!_atLineStart) {
      _buf.write(' ');
      _currentCol += 1;
    }
  }

  // -------------------------------------------------------------------------
  // Program
  // -------------------------------------------------------------------------

  void _visitProgram(SProgram program) {
    final decls = program.decls.toList();

    // Sort imports to the front in alphabetical order
    final nonImport = <SDecl>[];
    final imports = <SDecl>[];
    for (final d in decls) {
      if (d.kind is SImportKind) {
        imports.add(d);
      } else {
        nonImport.add(d);
      }
    }
    imports.sort(_compareImportDecls);

    var first = true;
    for (final d in [...imports, ...nonImport]) {
      _emitCommentsBefore(d.span.start);
      if (first) {
        first = false;
      } else {
        _newline();
        _newline();
      }
      _visitDecl(d);
    }
    _emitRemainingComments();
  }

  int _compareImportDecls(SDecl a, SDecl b) {
    final ka = a.kind as SImportKind;
    final kb = b.kind as SImportKind;
    final cmp = ka.path.compareTo(kb.path);
    if (cmp != 0) return cmp;
    final aa = ka.alias ?? '';
    final ab = kb.alias ?? '';
    return aa.compareTo(ab);
  }

  // -------------------------------------------------------------------------
  // Declarations
  // -------------------------------------------------------------------------

  void _visitDecl(SDecl decl) {
    switch (decl.kind) {
      case SImportKind():
        _visitImportDecl(decl.kind as SImportKind);
      case SValKind():
        _visitValDecl(decl.kind as SValKind);
      case STypeAliasKind():
        _visitTypeAlias(decl.kind as STypeAliasKind);
      case SDataKind():
        _visitData(decl.kind as SDataKind);
      case SDataBlockKind():
        _visitDataBlock(decl.kind as SDataBlockKind);
      case SFunKind():
        _visitFun(decl.kind as SFunKind);
      case SFunBlockKind():
        _visitFunBlock(decl.kind as SFunBlockKind);
      case STypeclassKind():
        _visitTypeclass(decl.kind as STypeclassKind);
      case SImplKind():
        _visitImpl(decl.kind as SImplKind);
    }
  }

  void _visitImportDecl(SImportKind k) {
    _write('import "${k.path}"');
    if (k.importedNames.isNotEmpty) {
      _write(' { ${k.importedNames.join(', ')} }');
    }
    if (k.alias != null) {
      _write(' as ${k.alias}');
    }
  }

  void _visitValDecl(SValKind k) {
    if (k.body.kind is SByKind) {
      _write('theorem ${k.name} : ');
      _writeDoc(_visit(k.body));
      return;
    }
    if (k.isOpaque) {
      _write('opaque ');
    }
    _write('val ${k.name}');
    if (k.type != null) {
      _space();
      _write(': ');
      _writeDoc(_visit(k.type!));
    }
    _space();
    _write('= ');
    _writeDoc(_visit(k.body));
  }

  void _visitTypeAlias(STypeAliasKind k) {
    _write('type ${k.name} = ');
    _writeDoc(_visit(k.body));
  }

  void _visitData(SDataKind k) {
    _write('data ${k.name}');
    _visitTypeParamList(k.typeParams);
    _space();
    _write(': ');
    _writeDoc(_visit(k.signature));
    _space();
    _write('{');
    _indentBy(1);
    _newline();
    for (var i = 0; i < k.ctors.length; i++) {
      final ctor = k.ctors[i];
      _write('${ctor.name} : ');
      _writeDoc(_visit(ctor.type));
      _write(';');
      if (i < k.ctors.length - 1) _newline();
    }
    _indentBy(-1);
    _newline();
    _write('}');
  }

  void _visitDataBlock(SDataBlockKind k) {
    for (var i = 0; i < k.members.length; i++) {
      if (i > 0) {
        _space();
        _write('and data ');
      } else {
        _write('data ');
      }
      _visitDataBody(k.members[i].data);
    }
  }

  void _visitDataBody(SDataKind k) {
    _write(k.name);
    _visitTypeParamList(k.typeParams);
    _space();
    _write(': ');
    _writeDoc(_visit(k.signature));
    _space();
    _write('{');
    _indentBy(1);
    _newline();
    for (var i = 0; i < k.ctors.length; i++) {
      final ctor = k.ctors[i];
      _write('${ctor.name} : ');
      _writeDoc(_visit(ctor.type));
      _write(';');
      if (i < k.ctors.length - 1) _newline();
    }
    _indentBy(-1);
    _newline();
    _write('}');
  }

  void _visitFun(SFunKind k, {bool withKeyword = true}) {
    if (k.isOpaque) {
      _write('opaque ');
    }
    if (withKeyword) _write('fun ');
    _write(k.name);
    _visitFunTypeParams(k.typeParams);
    _write('(');
    for (var i = 0; i < k.params.length; i++) {
      if (i > 0) _write(', ');
      final pname = k.params[i].$1;
      final ptype = k.params[i].$2;
      _write('$pname: ');
      _writeDoc(_visit(ptype));
    }
    _write(')');
    _space();
    _write(': ');

    var returnType = k.returnType;
    List<String>? extractedTby;
    if (k.terminationBy == null) {
      final ext = _extractTerminationBy(returnType);
      if (ext.tby != null) {
        extractedTby = ext.tby;
        returnType = ext.realRet;
      }
    }
    _writeDoc(_visit(returnType));

    if (k.structAnn != null) {
      _space();
      _write('{struct ${k.structAnn}}');
    }

    final tby = k.terminationBy ?? extractedTby;
    if (tby != null) {
      _space();
      _write('termination_by (${tby.join(', ')})');
    }

    if (k.body.kind is SLetKind) {
      _space();
      _write('{');
      _indentBy(1);
      _newline();
      _visitSLetChain(k.body);
      _indentBy(-1);
      _newline();
      _write('}');
    } else {
      _space();
      _write('= ');
      _writeDoc(_visit(k.body));
    }
  }

  void _visitSLetChain(SExpr expr) {
    var cur = expr;
    while (cur.kind is SLetKind) {
      final let = cur.kind as SLetKind;
      if (let.isRec) {
        _write('val rec ${let.param}');
        final params = _extractLambdaParams(let.bound);
        for (final p in params) {
          final n = p.$1;
          final t = p.$2;
          _write('($n: ');
          _writeDoc(_visit(t));
          _write(')');
        }
        _write(': ');
        _writeDoc(_visit(_extractPiReturnType(let.domain!)));
        _space();
        _write('= ');
        _writeDoc(_visit(_innermostLambdaBody(let.bound)));
      } else {
        _write('val ${let.param}');
        if (let.domain != null) {
          _write(': ');
          _writeDoc(_visit(let.domain!));
        }
        _space();
        _write('= ');
        _writeDoc(_visit(let.bound));
      }
      _write(';');
      _newline();
      cur = let.body;
    }
    _writeDoc(_visit(cur));
  }

  List<(String, SExpr)> _extractLambdaParams(SExpr expr) {
    final params = <(String, SExpr)>[];
    var cur = expr;
    while (cur.kind is SLamKind) {
      final lam = cur.kind as SLamKind;
      if (lam.domain != null) {
        params.add((lam.param, lam.domain!));
      }
      cur = lam.body;
    }
    return params;
  }

  SExpr _extractPiReturnType(SExpr expr) {
    var cur = expr;
    while (cur.kind is SPiKind) {
      cur = (cur.kind as SPiKind).codomain;
    }
    return cur;
  }

  SExpr _innermostLambdaBody(SExpr expr) {
    var cur = expr;
    while (cur.kind is SLamKind) {
      cur = (cur.kind as SLamKind).body;
    }
    return cur;
  }

  void _visitFunBlock(SFunBlockKind k) {
    for (var i = 0; i < k.members.length; i++) {
      if (i > 0) {
        _space();
        _write('and ');
      }
      _visitFun(k.members[i].fun, withKeyword: i == 0);
    }
  }

  void _visitTypeclass(STypeclassKind k) {
    _write('typeclass ${k.name}');
    _visitTypeParamList(k.typeParams);
    if (k.superclass != null) {
      _write(': ');
      _writeDoc(_visit(k.superclass!));
    }
    _space();
    _write('{');
    _indentBy(1);
    _newline();
    for (var i = 0; i < k.methods.length; i++) {
      _visitClassMethod(k.methods[i]);
      _write(';');
      if (i < k.methods.length - 1) _newline();
    }
    _indentBy(-1);
    _newline();
    _write('}');
  }

  void _visitClassMethod(SClassMethod m) {
    _write('fun ${m.name}');
    final (params, retType) = _decomposePi(m.type!);
    _write('(');
    for (var i = 0; i < params.length; i++) {
      if (i > 0) _write(', ');
      final n = params[i].$1;
      final t = params[i].$2;
      _write('$n: ');
      _writeDoc(_visit(t));
    }
    _write(')');
    _write(': ');
    _writeDoc(_visit(retType));
    if (m.defaultBody != null) {
      _space();
      _write('= ');
      _writeDoc(_visit(m.defaultBody!));
    }
  }

  (List<(String, SExpr)>, SExpr) _decomposePi(SExpr expr) {
    final params = <(String, SExpr)>[];
    var cur = expr;
    while (cur.kind is SPiKind) {
      final pi = cur.kind as SPiKind;
      if (pi.param != null) {
        params.add((pi.param!, pi.domain));
      }
      cur = pi.codomain;
    }
    return (params, cur);
  }

  void _visitImpl(SImplKind k) {
    _write('impl ');
    final ref = k.typeclassRef;
    if (ref.kind is SAppKind) {
      final app = ref.kind as SAppKind;
      _writeDoc(_visit(app.fn));
      _write('[');
      _writeDoc(_visit(app.arg));
      _write(']');
    } else {
      _writeDoc(_visit(ref));
    }
    _space();
    _write('{');
    _indentBy(1);
    _newline();
    for (var i = 0; i < k.members.length; i++) {
      _visitFun(k.members[i]);
      _write(';');
      if (i < k.members.length - 1) _newline();
    }
    _indentBy(-1);
    _newline();
    _write('}');
  }

  // -------------------------------------------------------------------------
  // Expression formatting (returns Doc)
  // -------------------------------------------------------------------------

  _Doc _visit(SExpr expr) => switch (expr.kind) {
    SIdentKind(:final name) => _Doc.txt(name),
    STypeKind(:final level) =>
      level == null ? _Doc.txt('Type') : _Doc.txt('Type $level'),
    SPropKind() => _Doc.txt('Prop'),
    SSPropKind() => _Doc.txt('SProp'),
    SAppKind(:final fn, :final arg) => _visitApp(fn, arg),
    SLamKind(:final param, :final domain, :final body, :final icit) =>
      _visitLam(param, domain, body, isImplicit: icit == Icit.implicit),
    SPiKind(:final param, :final domain, :final codomain, :final icit) =>
      _visitPi(param, domain, codomain, isImplicit: icit == Icit.implicit),
    SMatchKind(:final scrutinee, :final motive, :final cases) => _visitMatch(
      scrutinee,
      motive,
      cases,
    ),
    SLetKind(
      :final param,
      :final domain,
      :final bound,
      :final body,
      :final isRec,
    ) =>
      _visitBlock(param, domain, bound, body, isRec),
    SDotKind(:final qualifier, :final name) => _Doc.cat(
      _visit(qualifier),
      _Doc.txt('.$name'),
    ),
    SQuotKind(:final carrier, :final relation) => _Doc.catAll([
      _Doc.txt('Quot('),
      _visit(carrier),
      _Doc.txt(', '),
      _visit(relation),
      _Doc.txt(')'),
    ]),
    SQuotMkKind(:final arg) => _Doc.catAll([
      _Doc.txt('Quot.mk('),
      _visit(arg),
      _Doc.txt(')'),
    ]),
    SQuotLiftKind(:final fn, :final proof) => _Doc.catAll([
      _Doc.txt('Quot.lift('),
      _visit(fn),
      _Doc.txt(', '),
      _visit(proof),
      _Doc.txt(')'),
    ]),
    SIntersectionKind(:final constraints) => _Doc.catAll([
      for (var i = 0; i < constraints.length; i++) ...[
        if (i > 0) _Doc.txt(' & '),
        _visit(constraints[i]),
      ],
    ]),
    SByKind(:final steps) => _visitBy(steps),
  };

  _Doc _visitApp(SExpr fn, SExpr arg) {
    final fnDoc = _visit(fn);
    final argDoc = _visit(arg);
    final needsParens =
        arg.kind is SLamKind ||
        (arg.kind is SPiKind && (arg.kind as SPiKind).param != null) ||
        arg.kind is SAppKind ||
        arg.kind is SLetKind;
    final wrappedArg =
        needsParens
            ? _Doc.catAll([_Doc.txt('('), argDoc, _Doc.txt(')')])
            : argDoc;
    // Inline application: no grouping. Long chains are handled by
    // strategic groups at enclosing boundaries (= body, -> codomain).
    return _Doc.catAll([fnDoc, _Doc.space, wrappedArg]);
  }

  _Doc _visitLam(
    String param,
    SExpr? domain,
    SExpr body, {
    bool isImplicit = false,
  }) {
    final parts = <_Doc>[];
    if (isImplicit) {
      parts.add(_Doc.txt('{$param'));
      if (domain != null) {
        parts.add(_Doc.txt(': '));
        parts.add(_visit(domain));
      }
      parts.add(_Doc.txt('} -> '));
    } else {
      parts.add(_Doc.txt('($param'));
      if (domain != null) {
        parts.add(_Doc.txt(': '));
        parts.add(_visit(domain));
        parts.add(_Doc.txt(') => '));
      } else {
        parts.add(_Doc.txt(') -> '));
      }
    }
    parts.add(_visit(body));
    return _Doc.catAll(parts);
  }

  _Doc _visitPi(
    String? param,
    SExpr domain,
    SExpr codomain, {
    bool isImplicit = false,
  }) {
    if (param == null) {
      // Non-dependent arrow
      final domainDoc = _visit(domain);
      final domainWrapped =
          domain.kind is SPiKind
              ? _Doc.catAll([_Doc.txt('('), domainDoc, _Doc.txt(')')])
              : domainDoc;
      return _Doc.grp(
        _Doc.catAll([
          domainWrapped,
          _Doc.space,
          _Doc.txt('-> '),
          _Doc.nst(_indentSize, _visit(codomain)),
        ]),
      );
    }
    final open = isImplicit ? _Doc.txt('{$param: ') : _Doc.txt('($param: ');
    final close = isImplicit ? _Doc.txt('} -> ') : _Doc.txt(') -> ');
    return _Doc.grp(
      _Doc.catAll([
        open,
        _visit(domain),
        close,
        _Doc.nst(_indentSize, _visit(codomain)),
      ]),
    );
  }

  _Doc _visitMatch(SExpr scrutinee, SExpr? motive, List<SMatchCaseArm> cases) {
    final caseDocs = <_Doc>[];
    for (var i = 0; i < cases.length; i++) {
      final arm = cases[i];
      switch (arm) {
        case SMatchCase(:final ctor, :final binders, :final body):
          caseDocs.add(
            _Doc.catAll([
              _Doc.txt('case $ctor'),
              for (final b in binders) _Doc.cat(_Doc.space, _Doc.txt(b)),
              _Doc.txt(' => '),
              _visit(body),
            ]),
          );
        case SWildcardCase(:final body):
          caseDocs.add(_Doc.catAll([_Doc.txt('case _ => '), _visit(body)]));
      }
    }
    return _Doc.catAll([
      _Doc.txt('match '),
      _visit(scrutinee),
      if (motive != null) ...[
        _Doc.space,
        _Doc.txt('returning '),
        _visit(motive),
      ],
      _Doc.txt(' {'),
      _Doc.nst(
        _indentSize,
        _Doc.catAll([
          _Doc.line,
          _Doc.catAll([
            for (var i = 0; i < caseDocs.length; i++) ...[
              if (i > 0) _Doc.line,
              caseDocs[i],
            ],
          ]),
        ]),
      ),
      _Doc.line,
      _Doc.txt('}'),
    ]);
  }

  _Doc _visitBlock(
    String param,
    SExpr? domain,
    SExpr bound,
    SExpr body,
    bool isRec,
  ) => _Doc.catAll([
    _Doc.txt('{'),
    _Doc.nst(
      _indentSize,
      _Doc.catAll([
        _Doc.line,
        _visitSLetChainDocFromLet(param, domain, bound, body, isRec),
        _Doc.line,
      ]),
    ),
    _Doc.txt('}'),
  ]);

  _Doc _visitSLetChainDocFromLet(
    String param,
    SExpr? domain,
    SExpr bound,
    SExpr body,
    bool isRec,
  ) {
    final bindParts = <_Doc>[];
    if (isRec) {
      bindParts.add(_Doc.txt('val rec $param'));
      for (final p in _extractLambdaParams(bound)) {
        bindParts.add(_Doc.txt('(${p.$1}: '));
        bindParts.add(_visit(p.$2));
        bindParts.add(_Doc.txt(')'));
      }
      bindParts.add(_Doc.txt(': '));
      bindParts.add(_visit(_extractPiReturnType(domain!)));
      bindParts.add(_Doc.space);
      bindParts.add(_Doc.txt('= '));
      bindParts.add(_visit(_innermostLambdaBody(bound)));
    } else {
      bindParts.add(_Doc.txt('val $param'));
      if (domain != null) {
        bindParts.add(_Doc.txt(': '));
        bindParts.add(_visit(domain));
      }
      bindParts.add(_Doc.space);
      bindParts.add(_Doc.txt('= '));
      bindParts.add(_visit(bound));
    }
    final bodyDoc =
        body.kind is SLetKind
            ? _visitSLetChainDocFromLet(
              (body.kind as SLetKind).param,
              (body.kind as SLetKind).domain,
              (body.kind as SLetKind).bound,
              (body.kind as SLetKind).body,
              (body.kind as SLetKind).isRec,
            )
            : _visit(body);
    return _Doc.catAll([
      _Doc.catAll(bindParts),
      _Doc.txt(';'),
      _Doc.line,
      bodyDoc,
    ]);
  }

  _Doc _visitBy(List<List<STacticStep>> steps) {
    final parts = <_Doc>[
      _Doc.txt('by {'),
      _Doc.nst(
        _indentSize,
        _Doc.catAll([
          _Doc.line,
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) ...[_Doc.txt(' |'), _Doc.line],
            for (var j = 0; j < steps[i].length; j++) ...[
              if (j > 0) _Doc.txt('; '),
              _visitTacticStep(steps[i][j]),
            ],
          ],
          _Doc.line,
        ]),
      ),
      _Doc.txt('}'),
    ];
    return _Doc.catAll(parts);
  }

  _Doc _visitTacticStep(STacticStep step) => switch (step) {
    STacticIntro(:final name) =>
      name == null ? _Doc.txt('intro') : _Doc.txt('intro $name'),
    STacticExact(:final expr) => _Doc.catAll([
      _Doc.txt('exact '),
      _visit(expr),
    ]),
    STacticApply(:final expr) => _Doc.catAll([
      _Doc.txt('apply '),
      _visit(expr),
    ]),
    STacticRefl() => _Doc.txt('refl'),
    STacticRewrite(:final expr) => _Doc.catAll([
      _Doc.txt('rewrite '),
      _visit(expr),
    ]),
    STacticInduction(:final name) => _Doc.txt('induction $name'),
    STacticTrivial() => _Doc.txt('trivial'),
  };

  // -------------------------------------------------------------------------
  // Type parameter formatting
  // -------------------------------------------------------------------------

  void _visitTypeParamList(List<(String, SExpr?)> params) {
    if (params.isEmpty) return;
    _write('[');
    for (var i = 0; i < params.length; i++) {
      if (i > 0) _write(', ');
      final pname = params[i].$1;
      final pkind = params[i].$2;
      _write(pname);
      if (pkind != null) {
        _write(': ');
        _writeDoc(_visit(pkind));
      }
    }
    _write(']');
  }

  void _visitFunTypeParams(List<SFunTypeParam> params) {
    if (params.isEmpty) return;
    var i = 0;
    while (i < params.length) {
      final icity = params[i].isImplicit;
      if (icity) {
        _write('{');
      } else {
        _write('[');
      }
      var first = true;
      while (i < params.length && params[i].isImplicit == icity) {
        if (!first) _write(', ');
        first = false;
        final p = params[i];
        _write(p.name);
        if (p.kind != null) {
          _write(': ');
          _writeDoc(_visit(p.kind!));
        } else if (p.constraints.isNotEmpty) {
          _write(': ');
          _writeDoc(_visit(p.constraints.first));
          for (var j = 1; j < p.constraints.length; j++) {
            _write(' & ');
            _writeDoc(_visit(p.constraints[j]));
          }
        }
        i++;
      }
      if (icity) {
        _write('}');
      } else {
        _write(']');
      }
    }
  }

  ({List<String>? tby, SExpr realRet}) _extractTerminationBy(SExpr returnType) {
    final chain = <SAppKind>[];
    SExpr? cur = returnType;
    while (cur != null && cur.kind is SAppKind) {
      chain.add(cur.kind as SAppKind);
      cur = (cur.kind as SAppKind).fn;
    }
    var termByIdx = -1;
    for (var i = chain.length - 1; i >= 0; i--) {
      final arg = chain[i].arg.kind;
      if (arg is SIdentKind && arg.name == 'termination_by') {
        termByIdx = i;
        break;
      }
    }
    if (termByIdx < 0) return (tby: null, realRet: returnType);
    final names = <String>[];
    for (var i = termByIdx - 1; i >= 0; i--) {
      final arg = chain[i].arg.kind;
      if (arg is SIdentKind) {
        names.add(arg.name);
      } else {
        return (tby: null, realRet: returnType);
      }
    }
    final realRet = chain[termByIdx].fn;
    return (tby: names, realRet: realRet);
  }
}

class _CommentInfo {
  final int start;
  final int end;
  final String text;
  const _CommentInfo(this.start, this.end, this.text);
}
