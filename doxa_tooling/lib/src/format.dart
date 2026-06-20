/// Canonical code formatter for Doxa source files.
library;

import 'package:doxa/src/parse.dart' show parseProgram;
import 'package:doxa/src/surface.dart';
import 'package:doxa_tooling/src/tokenize.dart' show tokenizeDoxaSpans;
import 'package:rumil/rumil.dart';
import 'package:rumil_tokens/rumil_tokens.dart' show Comment;

/// Format a Doxa source string to canonical style.
String formatSource(String source) {
  final f = _Formatter(source);
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

class _Formatter {
  final String source;
  final StringBuffer _buf = StringBuffer();
  int _indent = 0;
  bool _atLineStart = true;

  static const int _indentSize = 2;

  // Comment tracking
  final List<_CommentInfo> _comments = [];
  int _commentIx = 0;

  _Formatter(this.source);

  String format() {
    _extractComments();
    _buf.clear();
    _indent = 0;
    _atLineStart = true;
    _commentIx = 0;

    final result = parseProgram(source);
    final program = switch (result) {
      Success<ParseError, SProgram>(:final value) => value,
      Partial<ParseError, SProgram>(:final value) => value,
      Failure<ParseError, SProgram>() =>
        throw FormatException('Cannot format source with parse errors'),
    };

    _visitProgram(program);
    _emitCommentsBefore(source.length);

    var out = _buf.toString();
    // Collapse 3+ consecutive `\n` into 2 (at most 1 blank line).
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // Strip leading blank lines (but not leading whitespace/comments).
    out = out.replaceFirst(RegExp(r'^(\n)+'), '');
    // Ensure exactly one trailing newline.
    out = out.trimRight() + '\n';
    return out;
  }

  // -------------------------------------------------------------------------
  // Comment extraction
  // -------------------------------------------------------------------------

  void _extractComments() {
    _comments.clear();
    final spans = tokenizeDoxaSpans(source);
    for (final s in spans) {
      if (s.token is Comment) {
        _comments.add(_CommentInfo(s.start, s.end, s.token.text));
      }
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
  }

  void _newline() {
    _buf.write('\n');
    _atLineStart = true;
    _writeIndent();
  }

  void _writeIndent() {
    if (_atLineStart && _indent > 0) {
      final spaces = ' ' * (_indent * _indentSize);
      _buf.write(spaces);
    }
  }

  void _indentBy(int delta) {
    _indent += delta;
  }

  void _space() {
    if (!_atLineStart) {
      _buf.write(' ');
    }
  }

  // -------------------------------------------------------------------------
  // Program
  // -------------------------------------------------------------------------

  void _visitProgram(SProgram program) {
    var decls = program.decls.toList();

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
    var cmp = ka.path.compareTo(kb.path);
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
      _visit(k.body);
      return;
    }
    if (k.isOpaque) {
      _write('opaque ');
    }
    _write('val ${k.name}');
    if (k.type != null) {
      _space();
      _write(': ');
      _visit(k.type!);
    }
    _space();
    _write('= ');
    _visit(k.body);
  }

  void _visitTypeAlias(STypeAliasKind k) {
    _write('type ${k.name} = ');
    _visit(k.body);
  }

  void _visitData(SDataKind k) {
    _write('data ${k.name}');
    _visitTypeParamList(k.typeParams);
    _space();
    _write(': ');
    _visit(k.signature);
    _space();
    _write('{');
    _indentBy(1);
    _newline();
    for (var i = 0; i < k.ctors.length; i++) {
      final ctor = k.ctors[i];
      _write('${ctor.name} : ');
      _visit(ctor.type);
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
    _visit(k.signature);
    _space();
    _write('{');
    _indentBy(1);
    _newline();
    for (var i = 0; i < k.ctors.length; i++) {
      final ctor = k.ctors[i];
      _write('${ctor.name} : ');
      _visit(ctor.type);
      _write(';');
      if (i < k.ctors.length - 1) _newline();
    }
    _indentBy(-1);
    _newline();
    _write('}');
  }

  void _visitFun(SFunKind k) {
    if (k.isOpaque) {
      _write('opaque ');
    }
    _write('fun ${k.name}');
    _visitFunTypeParams(k.typeParams);
    _write('(');
    for (var i = 0; i < k.params.length; i++) {
      if (i > 0) _write(', ');
      final pname = k.params[i].$1;
      final ptype = k.params[i].$2;
      _write('$pname: ');
      _visit(ptype);
    }
    _write(')');
    _space();
    _write(': ');

    // The parser may have consumed `termination_by (args)` as part of
    // the return-type expression. Extract it and format it separately.
    var returnType = k.returnType;
    List<String>? extractedTby;
    if (k.terminationBy == null) {
      final ext = _extractTerminationBy(returnType);
      if (ext.tby != null) {
        extractedTby = ext.tby;
        returnType = ext.realRet;
      }
    }
    _visit(returnType);

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
      _visit(k.body);
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
          _visit(t);
          _write(')');
        }
        _write(': ');
        _visit(_extractPiReturnType(let.domain!));
        _space();
        _write('= ');
        _visit(_innermostLambdaBody(let.bound));
      } else {
        _write('val ${let.param}');
        if (let.domain != null) {
          _write(': ');
          _visit(let.domain!);
        }
        _space();
        _write('= ');
        _visit(let.bound);
      }
      _write(';');
      _newline();
      cur = let.body;
    }
    _visit(cur);
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
      _visitFun(k.members[i].fun);
    }
  }

  void _visitTypeclass(STypeclassKind k) {
    _write('typeclass ${k.name}');
    _visitTypeParamList(k.typeParams);
    if (k.superclass != null) {
      _write(': ');
      _visit(k.superclass!);
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
    for (final p in params) {
      final n = p.$1;
      final t = p.$2;
      _write('($n: ');
      _visit(t);
      _write(')');
    }
    _write(': ');
    _visit(retType);
    if (m.defaultBody != null) {
      _space();
      _write('= ');
      _visit(m.defaultBody!);
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
    _visit(k.typeclassRef);
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
  // Expression formatting
  // -------------------------------------------------------------------------

  void _visit(SExpr expr) {
    switch (expr.kind) {
      case SIdentKind(:final name):
        _write(name);
      case STypeKind(:final level):
        if (level == null) {
          _write('Type');
        } else {
          _write('Type $level');
        }
      case SPropKind():
        _write('Prop');
      case SSPropKind():
        _write('SProp');
      case SAppKind(:final fn, :final arg):
        _visitApp(fn, arg);
      case SLamKind(:final param, :final domain, :final body):
        _visitLam(param, domain, body);
      case SPiKind(:final param, :final domain, :final codomain):
        _visitPi(param, domain, codomain);
      case SMatchKind(:final scrutinee, :final motive, :final cases):
        _visitMatch(scrutinee, motive, cases);
      case SLetKind(
        :final param,
        :final domain,
        :final bound,
        :final body,
        :final isRec,
      ):
        _visitBlock(param, domain, bound, body, isRec);
      case SDotKind(:final qualifier, :final name):
        _visit(qualifier);
        _write('.$name');
      case SQuotKind(:final carrier, :final relation):
        _write('Quot(');
        _visit(carrier);
        _write(', ');
        _visit(relation);
        _write(')');
      case SQuotMkKind(:final arg):
        _write('Quot.mk(');
        _visit(arg);
        _write(')');
      case SQuotLiftKind(:final fn, :final proof):
        _write('Quot.lift(');
        _visit(fn);
        _write(', ');
        _visit(proof);
        _write(')');
      case SIntersectionKind(:final constraints):
        for (var i = 0; i < constraints.length; i++) {
          if (i > 0) _write(' & ');
          _visit(constraints[i]);
        }
      case SByKind(:final steps):
        _visitBy(steps);
    }
  }

  void _visitApp(SExpr fn, SExpr arg) {
    _visit(fn);
    _space();
    final needsParens =
        arg.kind is SLamKind ||
        (arg.kind is SPiKind && (arg.kind as SPiKind).param != null) ||
        arg.kind is SAppKind;
    if (needsParens) {
      _write('(');
      _visit(arg);
      _write(')');
    } else {
      _visit(arg);
    }
  }

  void _visitLam(String param, SExpr? domain, SExpr body) {
    _write('($param');
    if (domain != null) {
      _write(': ');
      _visit(domain);
    }
    _write(') => ');
    _visit(body);
  }

  void _visitPi(String? param, SExpr domain, SExpr codomain) {
    if (param == null) {
      final domainParens = domain.kind is SPiKind;
      if (domainParens) {
        _write('(');
        _visit(domain);
        _write(')');
      } else {
        _visit(domain);
      }
      _space();
      _write('-> ');
      _visit(codomain);
    } else {
      _write('($param: ');
      _visit(domain);
      _write(') -> ');
      _visit(codomain);
    }
  }

  void _visitMatch(SExpr scrutinee, SExpr? motive, List<SMatchCaseArm> cases) {
    _write('match ');
    _visit(scrutinee);
    if (motive != null) {
      _space();
      _write('returning ');
      _visit(motive);
    }
    _space();
    _write('{');
    _indentBy(1);
    _newline();
    for (var i = 0; i < cases.length; i++) {
      final arm = cases[i];
      switch (arm) {
        case SMatchCase(:final ctor, :final binders, :final body):
          _write('case $ctor');
          for (final b in binders) {
            _space();
            _write(b);
          }
          _space();
          _write('=> ');
          _visit(body);
        case SWildcardCase(:final body):
          _write('case _ => ');
          _visit(body);
      }
      if (i < cases.length - 1) _newline();
    }
    _indentBy(-1);
    _newline();
    _write('}');
  }

  void _visitBlock(
    String param,
    SExpr? domain,
    SExpr bound,
    SExpr body,
    bool isRec,
  ) {
    _write('{');
    _indentBy(1);
    _newline();
    _visitSLetChainFromLet(param, domain, bound, body, isRec);
    _indentBy(-1);
    _newline();
    _write('}');
  }

  void _visitSLetChainFromLet(
    String param,
    SExpr? domain,
    SExpr bound,
    SExpr body,
    bool isRec,
  ) {
    if (isRec) {
      _write('val rec $param');
      final params = _extractLambdaParams(bound);
      for (final p in params) {
        final n = p.$1;
        final t = p.$2;
        _write('($n: ');
        _visit(t);
        _write(')');
      }
      _write(': ');
      _visit(_extractPiReturnType(domain!));
      _space();
      _write('= ');
      _visit(_innermostLambdaBody(bound));
    } else {
      _write('val $param');
      if (domain != null) {
        _write(': ');
        _visit(domain);
      }
      _space();
      _write('= ');
      _visit(bound);
    }
    _write(';');
    _newline();

    if (body.kind is SLetKind) {
      final next = body.kind as SLetKind;
      _visitSLetChainFromLet(
        next.param,
        next.domain,
        next.bound,
        next.body,
        next.isRec,
      );
    } else {
      _visit(body);
    }
  }

  void _visitBy(List<List<STacticStep>> steps) {
    _write('by {');
    _indentBy(1);
    _newline();
    for (var i = 0; i < steps.length; i++) {
      final alt = steps[i];
      for (var j = 0; j < alt.length; j++) {
        if (j > 0) _write('; ');
        _visitTacticStep(alt[j]);
      }
      if (i < steps.length - 1) {
        _write(' |');
        _newline();
      }
    }
    _indentBy(-1);
    _newline();
    _write('}');
  }

  void _visitTacticStep(STacticStep step) {
    switch (step) {
      case STacticIntro(:final name):
        _write('intro');
        if (name != null) {
          _space();
          _write(name);
        }
      case STacticExact(:final expr):
        _write('exact ');
        _visit(expr);
      case STacticApply(:final expr):
        _write('apply ');
        _visit(expr);
      case STacticRefl():
        _write('refl');
      case STacticRewrite(:final expr):
        _write('rewrite ');
        _visit(expr);
      case STacticInduction(:final name):
        _write('induction $name');
      case STacticTrivial():
        _write('trivial');
    }
  }

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
        _visit(pkind);
      }
    }
    _write(']');
  }

  void _visitFunTypeParams(List<SFunTypeParam> params) {
    if (params.isEmpty) return;
    // Group consecutive params by icity.
    var i = 0;
    while (i < params.length) {
      final icity = params[i].isImplicit;
      if (icity) { _write('{'); } else { _write('['); }
      var first = true;
      while (i < params.length && params[i].isImplicit == icity) {
        if (!first) _write(', ');
        first = false;
        final p = params[i];
        _write(p.name);
        if (p.kind != null) {
          _write(': ');
          _visit(p.kind!);
        } else if (p.constraints.isNotEmpty) {
          _write(': ');
          _visit(p.constraints.first);
          for (var j = 1; j < p.constraints.length; j++) {
            _write(' & ');
            _visit(p.constraints[j]);
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

  /// Extract `termination_by (args)` suffix from the return-type
  /// expression. The parser cannot distinguish
  /// `fun f(): T termination_by (x)` from `App(App(T, term_by), x)`,
  /// so we walk the return-type AST to detect it.
  ({List<String>? tby, SExpr realRet}) _extractTerminationBy(
    SExpr returnType,
  ) {
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
