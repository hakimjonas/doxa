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
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/report.dart';
import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart';

/// The result of processing one REPL input, plus the (possibly updated)
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

  /// Creates a REPL session, optionally seeded with [seedBindings]
  /// and [seedDataDecls] (e.g. the ambient prelude).
  const ReplSession({
    this.bindings = const <TopBinding>[],
    this.dataDecls = const <DataDecl>[],
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
    final topEnv = TopEnv(bindings, dataDecls);
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

  /// Process [decl] as a declaration: elaborate, check, return a new
  /// session with the declaration accumulated.
  ReplStep _processDecl(SDecl decl, String input) {
    final topEnv = TopEnv(bindings, dataDecls);
    try {
      final produced = elabDecl(topEnv, decl);
      final runningData = [...dataDecls, ...produced.dataDecls];
      final runningEnv = TopEnv(bindings, runningData);
      final finalized = checkDeclResult(runningEnv, produced);

      final newBindings = [...bindings, ...finalized];
      final newDataDecls = runningData;
      final newSession = ReplSession(
        bindings: newBindings,
        dataDecls: newDataDecls,
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
