/// REPL session: an interactive Doxa read-eval-print loop.
///
/// Accumulates top-level state across inputs, supporting both
/// expression evaluation and declaration accumulation. Each input
/// is elaborated and checked against the running environment without
/// re-checking earlier declarations.
///
/// The session is immutable: [processInput] returns a new session when
/// state changes (a declaration is added) and the same session otherwise.
library;

import 'package:rumil/rumil.dart';

import 'package:doxa/src/check.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart' show mergeNamespace;
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/report.dart';
import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart' show TPi, TBound, TData, Term, Icit;

/// Meta-command mode: which part of the expression to display.
enum _MetaMode { type, norm }

/// session state.
typedef ReplStep = (ReplResult, ReplSession);

/// The result of processing one REPL input.
sealed class ReplResult {
  /// Base constructor.
  const ReplResult();
}

/// An expression was successfully elaborated and its type inferred.
final class ReplExprResult extends ReplResult {
  /// Pretty-printed inferred type.
  final String type;

  /// Pretty-printed normal form.
  final String normalForm;

  /// Creates an expression result.
  const ReplExprResult({required this.type, required this.normalForm});
}

/// A declaration was successfully elaborated, checked, and accumulated.
final class ReplDeclResult extends ReplResult {
  /// The declared name.
  final String name;

  /// Pretty-printed type of the declaration.
  final String type;

  /// Creates a declaration result.
  const ReplDeclResult({required this.name, required this.type});
}

/// Processing the input produced an error.
final class ReplError extends ReplResult {
  /// Human-readable diagnostic message.
  final String message;

  /// Creates an error result with [message].
  const ReplError(this.message);
}

/// A meta-command was processed (e.g., `:type`, `:help`).
final class ReplMeta extends ReplResult {
  /// The output text to display.
  final String text;

  /// Creates a meta-command result.
  const ReplMeta(this.text);
}

/// Immutable REPL session holding accumulated top-level state.
///
/// Each [processInput] call is independent — the session does NOT
/// re-check earlier declarations. The accumulated [TopEnv] grows as
/// declarations are processed. When a declaration succeeds, a new
/// session is returned; for expressions and errors the same session
/// is returned.
///
/// Initialise with [bindings] and [dataDecls] to pre-load
/// the ambient prelude (e.g. `Eq`, `refl`) before accepting user
/// input.
final class ReplSession {
  /// Accumulated top-level bindings, in declaration order.
  final List<TopBinding> bindings;

  /// Accumulated inductive-type declarations.
  final List<DataDecl> dataDecls;

  /// Accumulated namespace-qualified name index.
  final Map<String, Set<String>> namespaceBindings;

  /// Creates a REPL session, optionally seeded with [seedBindings]
  /// and [seedDataDecls] (e.g. the ambient prelude).
  const ReplSession({
    this.bindings = const <TopBinding>[],
    this.dataDecls = const <DataDecl>[],
    this.namespaceBindings = const {},
  });

  /// Process a single line of REPL input.
  ///
  /// Tries to parse as an expression first (type + normal form). If that
  /// fails, tries to parse as a declaration and accumulate it. Returns
  /// the result and the (possibly updated) session.
  ReplStep processInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return (const ReplError(''), this);
    }

    // Meta-commands prefixed with ':'.
    if (trimmed.startsWith(':')) {
      return _processMeta(trimmed);
    }

    // Try expression first.
    final exprResult = parseExpr(trimmed);
    if (exprResult is Success<ParseError, SExpr> ||
        exprResult is Partial<ParseError, SExpr>) {
      final expr =
          exprResult is Success<ParseError, SExpr>
              ? exprResult.value
              : (exprResult as Partial<ParseError, SExpr>).value;
      return (_processExpr(expr, trimmed), this);
    }

    // Try declaration.
    final declResult = parseDecl(trimmed);
    if (declResult is Success<ParseError, SDecl> ||
        declResult is Partial<ParseError, SDecl>) {
      final decl =
          declResult is Success<ParseError, SDecl>
              ? declResult.value
              : (declResult as Partial<ParseError, SDecl>).value;
      return _processDecl(decl, trimmed);
    }

    // Both failed — report the parse error, preferring expr's message.
    if (exprResult is Failure<ParseError, dynamic>) {
      return (
        ReplError(
          _formatParseFailure(exprResult as Failure<ParseError, dynamic>),
        ),
        this,
      );
    }
    if (declResult is Failure<ParseError, dynamic>) {
      return (
        ReplError(
          _formatParseFailure(declResult as Failure<ParseError, dynamic>),
        ),
        this,
      );
    }
    return (const ReplError('parse error'), this);
  }

  /// Process [expr] as an expression: elaborate, infer, normalize.
  ReplResult _processExpr(SExpr expr, String input) {
    final topEnv = TopEnv(bindings, dataDecls, const {}, namespaceBindings);
    try {
      final term = elabExpr(topEnv, expr);
      final ctx = topEnv.toCtx();
      final inferred = infer(ctx, term);
      final typeStr = prettyTerm(
        quote(bindings.length, inferred),
        outerDepth: 0,
      );

      // Normal form: evaluate in the full accumulated env.
      final fullEnv = _buildFullEnv();
      final nfTerm = quote(0, eval(term, fullEnv));
      final nfStr = prettyTerm(nfTerm, outerDepth: 0);

      return ReplExprResult(type: typeStr, normalForm: nfStr);
    } on DoxaCheckError catch (e) {
      return ReplError(_formatCheckError(input, expr.span, e));
    } on ElabError catch (e) {
      return ReplError(_formatElabError(input, e));
    }
  }

  /// Process a meta-command (input starting with `:`).
  ReplStep _processMeta(String input) {
    final parts = input.split(' ');
    final cmd = parts[0];
    final rest = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    switch (cmd) {
      case ':help':
        return (
          const ReplMeta(
            'Meta-commands:\n'
            '  :type <expr>   Elaborate and show the type\n'
            '  :norm <expr>   Elaborate and show the normal form\n'
            '  :browse        List all names in scope with their types\n'
            '  :search <str>  Filter :browse to names containing <str>\n'
            '  :help          Show this help\n'
            '  :quit          Exit the REPL\n'
            '\n'
            'Otherwise, enter a Doxa expression or declaration.',
          ),
          this,
        );
      case ':type':
        if (rest.isEmpty) {
          return (const ReplError(':type requires an expression'), this);
        }
        return _metaExpr(rest, mode: _MetaMode.type);
      case ':norm':
        if (rest.isEmpty) {
          return (const ReplError(':norm requires an expression'), this);
        }
        return _metaExpr(rest, mode: _MetaMode.norm);
      case ':browse':
        return (ReplMeta(_browse()), this);
      case ':search':
        if (rest.isEmpty) {
          return (const ReplError(':search requires a substring'), this);
        }
        return (ReplMeta(_browse(filter: rest)), this);
      default:
        return (ReplError('unknown command: $cmd'), this);
    }
  }

  /// Process `:type` or `:norm` by elaborating [exprSrc] and showing
  /// either the type or the normal form.
  ReplStep _metaExpr(String exprSrc, {required _MetaMode mode}) {
    final exprResult = parseExpr(exprSrc);
    final SExpr expr;
    if (exprResult is Success<ParseError, SExpr>) {
      expr = exprResult.value;
    } else if (exprResult is Partial<ParseError, SExpr>) {
      expr = exprResult.value;
    } else {
      return (
        ReplError(
          _formatParseFailure(exprResult as Failure<ParseError, dynamic>),
        ),
        this,
      );
    }
    final topEnv = TopEnv(bindings, dataDecls, const {}, namespaceBindings);
    try {
      final term = elabExpr(topEnv, expr);
      final ctx = topEnv.toCtx();
      final inferred = infer(ctx, term);
      final typeStr = prettyTerm(
        quote(bindings.length, inferred),
        outerDepth: 0,
      );
      final fullEnv = _buildFullEnv();
      final nfTerm = quote(0, eval(term, fullEnv));
      final nfStr = prettyTerm(nfTerm, outerDepth: 0);

      return switch (mode) {
        _MetaMode.type => (ReplMeta(typeStr), this),
        _MetaMode.norm => (ReplMeta(nfStr), this),
      };
    } on DoxaCheckError catch (e) {
      return (ReplError(_formatCheckError(exprSrc, expr.span, e)), this);
    } on ElabError catch (e) {
      return (ReplError(_formatElabError(exprSrc, e)), this);
    }
  }

  /// Process [decl] as a declaration: elaborate, check, return a new
  /// session with the declaration accumulated.
  ReplStep _processDecl(SDecl decl, String input) {
    final topEnv = TopEnv(bindings, dataDecls, const {}, namespaceBindings);
    try {
      final produced = elabDecl(topEnv, decl);
      final runningData = [...dataDecls, ...produced.dataDecls];
      final runningEnv = TopEnv(
        bindings,
        runningData,
        const {},
        namespaceBindings,
      );
      final finalized = checkDeclResult(runningEnv, produced);

      final newBindings = [...bindings, ...finalized];
      final newDataDecls = runningData;
      final newNs = mergeNamespace(
        namespaceBindings,
        produced.namespaceBindings,
      );
      final newSession = ReplSession(
        bindings: newBindings,
        dataDecls: newDataDecls,
        namespaceBindings: newNs,
      );

      // Return the primary result: the first new binding, or the first
      // new data decl if no bindings were produced.
      if (finalized.isNotEmpty) {
        final b = finalized.first;
        return (
          ReplDeclResult(name: b.name, type: prettyTerm(b.type, outerDepth: 0)),
          newSession,
        );
      }
      if (produced.dataDecls.isNotEmpty) {
        final d = produced.dataDecls.first;
        return (
          ReplDeclResult(name: d.name, type: prettyTerm(d.sort, outerDepth: 0)),
          newSession,
        );
      }
      return (const ReplDeclResult(name: '', type: ''), newSession);
    } on DoxaCheckError catch (e) {
      return (ReplError(_formatCheckError(input, decl.span, e)), this);
    } on ElabError catch (e) {
      return (ReplError(_formatElabError(input, e)), this);
    }
  }

  /// Build an [Env] with all accumulated bindings and data decls
  /// registered, so `TTop(name)` references resolve.
  Env _buildFullEnv() {
    var acc = <String, TopBindingEntry>{};
    for (final b in bindings) {
      final env = ENil.withRegistries(dataDecls: dataDecls, topBindings: acc);
      final typeV = eval(b.type, env);
      final termV = eval(b.term, env);
      acc = {
        ...acc,
        b.name: TopBindingEntry(
          typeV,
          termV,
          recDecreasingArg: b.recDecreasingArg,
          recArity: b.recArity,
        ),
      };
    }
    return ENil.withRegistries(dataDecls: dataDecls, topBindings: acc);
  }

  /// Build the term-level signature of a data type: `(params) -> (indices) -> sort`.
  Term _dataSignatureTerm(DataDecl d) {
    Term result = d.sort;
    for (var i = d.indices.length - 1; i >= 0; i--) {
      final e = d.indices[i];
      result = TPi(e.type, result, name: e.name);
    }
    for (var i = d.params.length - 1; i >= 0; i--) {
      final e = d.params[i];
      result = TPi(e.type, result, name: e.name);
    }
    return result;
  }

  /// Build the term-level signature of a constructor.
  Term _ctorSignatureTerm(DataDecl d, CtorDecl c) {
    final paramCount = d.params.length;
    final argCount = c.args.length;
    final resultArgs = <Term>[
      for (var i = 0; i < paramCount; i++)
        TBound(argCount + (paramCount - 1 - i)),
      ...c.resultIndices,
    ];
    Term result = TData(d.name, resultArgs);
    for (var i = argCount - 1; i >= 0; i--) {
      final e = c.args[i];
      result = TPi(e.type, result, name: e.name);
    }
    for (var i = paramCount - 1; i >= 0; i--) {
      final e = d.params[i];
      result = TPi(e.type, result, name: e.name, icit: Icit.implicit);
    }
    return result;
  }

  /// Collect all names in scope with their pretty-printed type strings.
  ///
  /// If [filter] is provided, only names containing the substring
  /// (case-insensitive) are included.
  String _browse({String? filter}) {
    final lines = <(String, String)>[];

    for (final b in bindings) {
      final typeStr = prettyTerm(b.type, outerDepth: 0);
      lines.add((b.name, '${b.name} : $typeStr'));
    }

    for (final d in dataDecls) {
      final sigTerm = _dataSignatureTerm(d);
      final typeStr = prettyTerm(sigTerm, outerDepth: 0);
      final ctorCount = d.ctors.length;
      lines.add((
        d.name,
        '${d.name} : $typeStr (data, $ctorCount '
            '${ctorCount == 1 ? "ctor" : "ctors"})',
      ));

      for (final c in d.ctors) {
        final ctorSigTerm = _ctorSignatureTerm(d, c);
        final ctorTypeStr = prettyTerm(ctorSigTerm, outerDepth: 0);
        lines.add((c.name, '${c.name} : $ctorTypeStr'));
      }
    }

    // Sort alphabetically by name.
    lines.sort((a, b) => a.$1.compareTo(b.$1));

    // Apply filter if provided.
    final filterLower = filter?.toLowerCase();
    final result = StringBuffer();
    for (final entry in lines) {
      if (filterLower == null || entry.$1.toLowerCase().contains(filterLower)) {
        result.writeln(entry.$2);
      }
    }
    return result.toString().trimRight();
  }

  /// Format a Rumil parse failure for REPL display.
  String _formatParseFailure(Failure<ParseError, dynamic> failure) {
    final furthest = failure.furthest;
    final line = furthest.line;
    final column = furthest.column;
    return 'parse error at $line:$column';
  }

  /// Format a [DoxaCheckError] for REPL display, using [input] as the
  /// source text for diagnostics.
  String _formatCheckError(String input, DoxaSpan span, DoxaCheckError e) {
    final source = SourceFile(filename: '<repl>', text: input);
    final message = reportCheckError(source, e, span);
    return message.trim();
  }

  /// Format an [ElabError] for REPL display, using [input] as the
  /// source text for diagnostics.
  String _formatElabError(String input, ElabError e) {
    final source = SourceFile(filename: '<repl>', text: input);
    final message = reportElabError(source, e);
    return message.trim();
  }
}
