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
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/report.dart';
import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/tactic.dart'
    show
        TacticState,
        TacticOk,
        TacticFail,
        intro,
        exact,
        refl,
        tacticApply,
        trivial,
        rewrite,
        induction,
        simpl,
        tacticConstructor,
        tacticCases;
import 'package:doxa/src/term.dart' show TPi, TBound, TData, Term, Icit;
import 'package:doxa/src/value.dart';

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

// ---------------------------------------------------------------------------
// Interactive proof state
// ---------------------------------------------------------------------------

/// A snapshot of proof state for undo.
final class _ProofSnapshot {
  final MetaSnapshot metaSnapshot;
  final int currentGoalMeta;
  final Ctx ctx;
  final List<String> binderNames;

  const _ProofSnapshot(
    this.metaSnapshot,
    this.currentGoalMeta,
    this.ctx,
    this.binderNames,
  );
}

/// Mutable proof session state, active between `:goal` and `:qed`/`:abort`.
final class _ProofSession {
  final MetaContext metas;
  final List<_ProofSnapshot> undoStack;
  final int rootGoalMetaId;
  int currentGoalMeta;
  Ctx ctx;
  List<String> binderNames;
  final TopEnv topEnv;
  final String theoremName;
  final Term theoremType;

  _ProofSession({
    required this.metas,
    required this.rootGoalMetaId,
    required this.currentGoalMeta,
    required this.ctx,
    required this.binderNames,
    required this.topEnv,
    required this.theoremName,
    required this.theoremType,
  }) : undoStack = [];

  Value get goalType =>
      metas.lookup(currentGoalMeta).isSolved
          ? (metas.lookup(currentGoalMeta) as TermMetaSolved).typeExpected
          : (metas.lookup(currentGoalMeta) as TermMetaUnsolved).typeExpected;
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

  /// Active proof session, or null when not in proof mode.
  final _ProofSession? proofState;

  /// Creates a REPL session, optionally seeded with [seedBindings]
  /// and [seedDataDecls] (e.g. the ambient prelude).
  const ReplSession({
    this.bindings = const <TopBinding>[],
    this.dataDecls = const <DataDecl>[],
    this.namespaceBindings = const {},
    _ProofSession? proofState,
  }) : this.proofState = proofState;

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

    // In proof mode, only meta-commands are accepted.
    if (proofState != null) {
      return (const ReplError('Cannot add declarations during a proof.'), this);
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
            '  :type <expr>     Elaborate and show the type\n'
            '  :norm <expr>     Elaborate and show the normal form\n'
            '  :browse          List all names in scope with their types\n'
            '  :search <str>    Filter :browse to names containing <str>\n'
            '  :goal <theorem>  Start an interactive proof\n'
            '  :step <tactic>   Execute a tactic step\n'
            '  :undo            Undo the last tactic step\n'
            '  :print           Show the current proof term\n'
            '  :qed             Finish the proof\n'
            '  :abort           Abort the current proof\n'
            '  :help            Show this help\n'
            '  :quit            Exit the REPL\n'
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
      case ':goal':
        return _handleGoal(rest);
      case ':step':
        return _handleStep(rest);
      case ':undo':
        return _handleUndo();
      case ':print':
        return _handlePrint();
      case ':qed':
        return _handleQed();
      case ':abort':
        return _handleAbort();
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

  // ---------------------------------------------------------------------------
  // Proof-mode handlers
  // ---------------------------------------------------------------------------

  /// Handle `:goal` (show current goal) or `:goal theorem NAME : TYPE` (start proof).
  ReplStep _handleGoal(String arg) {
    final text = arg.trim();
    // `:goal` with no args during proof shows the current goal.
    if (text.isEmpty) {
      final ps = proofState;
      if (ps == null) {
        return (const ReplError(':goal requires a theorem declaration.'), this);
      }
      return (
        ReplMeta(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType)),
        this,
      );
    }
    if (proofState != null) {
      return (
        const ReplMeta('Already in proof mode. Use :qed, :abort, or :undo.'),
        this,
      );
    }

    // Strip 'theorem ' prefix and ' := ' suffix.
    var rest = text;
    if (rest.startsWith('theorem ')) {
      rest = rest.substring('theorem '.length);
    } else {
      return (const ReplError(':goal expects "theorem name : type".'), this);
    }

    // Extract name (up to " : ").
    final nameEnd = rest.indexOf(' : ');
    if (nameEnd < 0) {
      return (const ReplError(':goal expects "theorem name : type".'), this);
    }
    final theoremName = rest.substring(0, nameEnd);
    var typeText = rest.substring(nameEnd + 3);

    // Strip optional trailing `:=`.
    if (typeText.endsWith(' :=')) {
      typeText = typeText.substring(0, typeText.length - 3).trim();
    } else if (typeText.endsWith(':=')) {
      typeText = typeText.substring(0, typeText.length - 2).trim();
    }

    if (typeText.isEmpty) {
      return (const ReplError(':goal theorem requires a type.'), this);
    }

    // Parse and elaborate the type.
    final typeResult = parseExpr(typeText);
    SExpr typeExpr;
    if (typeResult is Success<ParseError, SExpr>) {
      typeExpr = typeResult.value;
    } else if (typeResult is Partial<ParseError, SExpr>) {
      typeExpr = typeResult.value;
    } else {
      return (
        ReplError(
          _formatParseFailure(typeResult as Failure<ParseError, dynamic>),
        ),
        this,
      );
    }

    final topEnv = TopEnv(bindings, dataDecls, const {}, namespaceBindings);
    Term typeTerm;
    try {
      typeTerm = elabExpr(topEnv, typeExpr);
    } on DoxaCheckError catch (e) {
      return (ReplError(_formatCheckError(typeText, typeExpr.span, e)), this);
    } on ElabError catch (e) {
      return (ReplError(_formatElabError(typeText, e)), this);
    }

    // Evaluate the type to create the goal meta.
    final ctx = topEnv.toCtx();
    final metas = MetaContext();
    final ctxWithMetas = CNil.withRegistries(
      dataDecls: dataDecls,
      topBindings: ctx.env.topBindings,
      metas: metas,
    );
    final typeValue = eval(typeTerm, ctxWithMetas.env);
    final goalMetaId = metas.freshTermMeta(typeValue, ctxWithMetas);

    // Display the goal.
    final goalTypeStr = prettyTerm(
      quote(ctxWithMetas.level, typeValue),
      outerDepth: ctxWithMetas.level,
    );
    final output = StringBuffer();
    output.writeln('Goal:');
    output.writeln('  $goalTypeStr');

    final proofSession = _ProofSession(
      metas: metas,
      rootGoalMetaId: goalMetaId,
      currentGoalMeta: goalMetaId,
      ctx: ctxWithMetas,
      binderNames: const [],
      topEnv: topEnv,
      theoremName: theoremName,
      theoremType: typeTerm,
    );

    return (
      ReplMeta(output.toString().trimRight()),
      ReplSession(
        bindings: bindings,
        dataDecls: dataDecls,
        namespaceBindings: namespaceBindings,
        proofState: proofSession,
      ),
    );
  }

  /// Format context lines for display (innermost-first).
  String _formatContext(Ctx ctx, List<String> binderNames) {
    if (binderNames.isEmpty) return '';
    final lines = <String>[];
    var c = ctx;
    var i = 0;
    while (c is CCons && i < binderNames.length) {
      final name = binderNames[i];
      final typeTerm = quote(c.level, c.type);
      final typeStr = prettyTerm(typeTerm, outerDepth: c.level);
      lines.add('  $name : $typeStr');
      c = c.rest;
      i++;
    }
    return lines.join('\n');
  }

  /// Format goal + context display.
  String _formatGoalAndCtx(Ctx ctx, List<String> binderNames, Value goalType) {
    final goalTerm = quote(ctx.level, goalType);
    final goalStr = prettyTerm(goalTerm, outerDepth: ctx.level);
    final sb = StringBuffer();
    sb.writeln('Goal:');
    sb.writeln('  $goalStr');
    if (binderNames.isNotEmpty) {
      sb.writeln('Context:');
      sb.write(_formatContext(ctx, binderNames));
    }
    return sb.toString().trimRight();
  }

  /// Handle `:step <tactic>`.
  ReplStep _handleStep(String arg) {
    final ps = proofState;
    if (ps == null) {
      return (
        const ReplMeta('No proof in progress. Use :goal to start.'),
        this,
      );
    }
    final text = arg.trim();
    if (text.isEmpty) {
      return (const ReplError(':step requires a tactic.'), this);
    }

    // Parse the tactic: `intro [name]`, `exact e`, `apply f`, `refl`, `trivial`.
    final spaceIdx = text.indexOf(' ');
    final tacticName = spaceIdx < 0 ? text : text.substring(0, spaceIdx);
    final tacticArg = spaceIdx < 0 ? '' : text.substring(spaceIdx + 1).trim();

    switch (tacticName) {
      case 'intro':
        return _stepIntro(ps, tacticArg);
      case 'exact':
        return _stepExact(ps, tacticArg);
      case 'apply':
        return _stepApply(ps, tacticArg);
      case 'refl':
        return _stepRefl(ps);
      case 'trivial':
        return _stepTrivial(ps);
      case 'rewrite':
        return _stepRewrite(ps, tacticArg);
      case 'induction':
        return _stepInduction(ps, tacticArg);
      case 'simpl':
        return _stepSimpl(ps);
      case 'constructor':
        return _stepConstructor(ps);
      case 'cases':
        return _stepCases(ps, tacticArg);
      default:
        return (ReplError('unknown tactic: $tacticName'), this);
    }
  }

  ReplStep _stepIntro(_ProofSession ps, String nameArg) {
    final goalType = ps.goalType;
    if (goalType is! VPi) {
      return (const ReplMeta('intro: goal is not a function type'), this);
    }
    final pi = goalType;
    final name = nameArg.isNotEmpty ? nameArg : null;
    final freshName = name ?? pi.name ?? 'h';

    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );

    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = intro(tstate, name: name);
    return switch (result) {
      TacticOk(:final term, :final subMeta) => () {
        ps.metas.solve(ps.currentGoalMeta, term);
        ps.undoStack.add(snap);
        if (subMeta != null) {
          ps.currentGoalMeta = subMeta;
        }
        ps.ctx = ps.ctx.extend(pi.domain);
        ps.binderNames = [freshName, ...ps.binderNames];
        final output = StringBuffer();
        output.writeln('Introduced $freshName.');
        output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        if (subMeta == null) {
          output.writeln();
          output.write('Goal solved. Use :qed to commit.');
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  ReplStep _stepExact(_ProofSession ps, String arg) {
    if (arg.isEmpty) {
      return (const ReplError(':step exact requires an expression.'), this);
    }

    // Parse and elaborate the expression.
    final exprResult = parseExpr(arg);
    SExpr expr;
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

    Term term;
    try {
      term = elabExprInScope(ps.topEnv, ps.binderNames, expr, metas: ps.metas);
    } catch (_) {
      // Fallback: simple identifier → TBound.
      if (expr.kind case SIdentKind(:final name)) {
        final idx = ps.binderNames.indexOf(name);
        if (idx >= 0) {
          term = TBound(idx);
        } else {
          return (ReplMeta('exact: unresolved name "$name"'), this);
        }
      } else {
        return (ReplMeta('exact: could not elaborate expression'), this);
      }
    }

    // Take snapshot.
    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );

    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = exact(term)(tstate);
    return switch (result) {
      TacticOk() => () {
        ps.undoStack.add(snap);
        final output = StringBuffer();
        final allSolved = () {
          for (var i = 0; i < ps.metas.length; i++) {
            if (!ps.metas.isSolved(i)) return false;
          }
          return true;
        }();
        if (allSolved) {
          output.writeln('Goal solved. Use :qed to commit.');
        } else {
          output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  ReplStep _stepApply(_ProofSession ps, String arg) {
    if (arg.isEmpty) {
      return (const ReplError(':step apply requires an expression.'), this);
    }

    final exprResult = parseExpr(arg);
    SExpr expr;
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

    Term term;
    try {
      term = elabExprInScope(ps.topEnv, ps.binderNames, expr, metas: ps.metas);
    } catch (_) {
      if (expr.kind case SIdentKind(:final name)) {
        final idx = ps.binderNames.indexOf(name);
        if (idx >= 0) {
          term = TBound(idx);
        } else {
          return (ReplMeta('apply: unresolved name "$name"'), this);
        }
      } else {
        return (ReplMeta('apply: could not elaborate expression'), this);
      }
    }

    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );

    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = tacticApply(term)(tstate);
    return switch (result) {
      TacticOk() => () {
        ps.undoStack.add(snap);
        final output = StringBuffer();
        output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  ReplStep _stepRefl(_ProofSession ps) {
    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );
    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = refl(tstate);
    return switch (result) {
      TacticOk() => () {
        ps.undoStack.add(snap);
        final output = StringBuffer();
        final allSolved = () {
          for (var i = 0; i < ps.metas.length; i++) {
            if (!ps.metas.isSolved(i)) return false;
          }
          return true;
        }();
        if (allSolved) {
          output.writeln('Goal solved. Use :qed to commit.');
        } else {
          output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  ReplStep _stepTrivial(_ProofSession ps) {
    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );
    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = trivial(tstate);
    return switch (result) {
      TacticOk() => () {
        ps.undoStack.add(snap);
        final output = StringBuffer();
        final allSolved = () {
          for (var i = 0; i < ps.metas.length; i++) {
            if (!ps.metas.isSolved(i)) return false;
          }
          return true;
        }();
        if (allSolved) {
          output.writeln('Goal solved. Use :qed to commit.');
        } else {
          output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  /// Handle `:step simpl`.
  ///
  /// Normalises the goal type, replacing it with its normal form.
  ReplStep _stepSimpl(_ProofSession ps) {
    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );
    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = simpl(tstate);
    return switch (result) {
      TacticOk(:final subMeta) => () {
        ps.undoStack.add(snap);
        ps.metas.solve(ps.currentGoalMeta, result.term);
        if (subMeta != null) {
          ps.currentGoalMeta = subMeta;
        }
        final output = StringBuffer();
        if (subMeta == null) {
          output.writeln('Goal solved (already in normal form).');
        } else {
          output.writeln('Simplified.');
          output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  /// Handle `:step constructor`.
  ///
  /// Applies the first matching constructor of the goal's type.
  ReplStep _stepConstructor(_ProofSession ps) {
    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );
    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = tacticConstructor(tstate);
    return switch (result) {
      TacticOk(:final subMeta) => () {
        ps.undoStack.add(snap);
        ps.metas.solve(ps.currentGoalMeta, result.term);
        if (subMeta != null) {
          ps.currentGoalMeta = subMeta;
        }
        final output = StringBuffer();
        output.writeln('Constructor applied.');
        if (subMeta == null) {
          output.writeln('Goal solved. Use :qed to commit.');
        } else {
          output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  /// Handle `:step cases <var>`.
  ///
  /// Performs case analysis on the named variable.
  ReplStep _stepCases(_ProofSession ps, String arg) {
    if (arg.isEmpty) {
      return (const ReplError(':step cases requires a variable name.'), this);
    }
    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );
    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final resultFn = tacticCases(arg);
    final result = resultFn(tstate);
    return switch (result) {
      TacticOk(:final subMeta) => () {
        ps.undoStack.add(snap);
        ps.metas.solve(ps.currentGoalMeta, result.term);
        if (subMeta != null) {
          ps.currentGoalMeta = subMeta;
        }
        final output = StringBuffer();
        output.writeln('Case analysis applied.');
        if (subMeta == null) {
          output.writeln('Goal solved. Use :qed to commit.');
        } else {
          output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  /// Handle `:step rewrite <proof>`.
  ///
  /// Parses and elaborates the argument as an equality proof term,
  /// then applies the rewrite tactic.
  ReplStep _stepRewrite(_ProofSession ps, String arg) {
    if (arg.isEmpty) {
      return (const ReplError(':step rewrite requires an expression.'), this);
    }

    // Parse and elaborate the expression (must be an equality proof).
    final exprResult = parseExpr(arg);
    SExpr expr;
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

    Term proofTerm;
    try {
      proofTerm = elabExprInScope(
        ps.topEnv,
        ps.binderNames,
        expr,
        metas: ps.metas,
      );
    } catch (_) {
      if (expr.kind case SIdentKind(:final name)) {
        final idx = ps.binderNames.indexOf(name);
        if (idx >= 0) {
          proofTerm = TBound(idx);
        } else {
          return (ReplMeta('rewrite: unresolved name "$name"'), this);
        }
      } else {
        return (ReplMeta('rewrite: could not elaborate expression'), this);
      }
    }

    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );

    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = rewrite(proofTerm)(tstate);
    return switch (result) {
      TacticOk(:final subMeta) => () {
        ps.undoStack.add(snap);
        ps.metas.solve(ps.currentGoalMeta, result.term);
        if (subMeta != null) {
          ps.currentGoalMeta = subMeta;
        }
        final output = StringBuffer();
        if (subMeta == null) {
          output.writeln('Goal solved. Use :qed to commit.');
        } else {
          output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  /// Handle `:step induction <var>`.
  ///
  /// Performs induction on the named variable in the context.
  ReplStep _stepInduction(_ProofSession ps, String arg) {
    if (arg.isEmpty) {
      return (
        const ReplError(':step induction requires a variable name.'),
        this,
      );
    }

    final snap = _ProofSnapshot(
      ps.metas.snapshot(),
      ps.currentGoalMeta,
      ps.ctx,
      List.unmodifiable(ps.binderNames),
    );

    final tstate = TacticState(
      ps.metas,
      ps.ctx,
      ps.currentGoalMeta,
      ps.binderNames,
    );
    final result = induction(arg)(tstate);
    return switch (result) {
      TacticOk(:final subMeta) => () {
        ps.undoStack.add(snap);
        ps.metas.solve(ps.currentGoalMeta, result.term);
        if (subMeta != null) {
          ps.currentGoalMeta = subMeta;
        }
        final output = StringBuffer();
        output.writeln('Induction applied.');
        if (subMeta == null) {
          output.writeln('Goal solved. Use :qed to commit.');
        } else {
          output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));
        }
        return (ReplMeta(output.toString().trimRight()), this);
      }(),
      TacticFail(:final message) => (ReplMeta('step failed: $message'), this),
    };
  }

  /// Handle `:undo`.
  ReplStep _handleUndo() {
    final ps = proofState;
    if (ps == null) {
      return (const ReplMeta('No proof in progress.'), this);
    }
    if (ps.undoStack.isEmpty) {
      return (const ReplMeta('Nothing to undo.'), this);
    }

    final snap = ps.undoStack.removeLast();
    ps.metas.restore(snap.metaSnapshot);
    ps.currentGoalMeta = snap.currentGoalMeta;
    ps.ctx = snap.ctx;
    ps.binderNames = snap.binderNames;

    final output = StringBuffer();
    output.writeln('Undone.');
    output.write(_formatGoalAndCtx(ps.ctx, ps.binderNames, ps.goalType));

    return (ReplMeta(output.toString().trimRight()), this);
  }

  /// Handle `:print` — show the proof term built so far.
  ReplStep _handlePrint() {
    final ps = proofState;
    if (ps == null) {
      return (const ReplMeta('No proof in progress.'), this);
    }
    if (!ps.metas.isSolved(ps.rootGoalMetaId)) {
      return (ReplMeta('No steps taken yet.'), this);
    }

    final rootTerm = ps.metas.solutionOf(ps.rootGoalMetaId);
    final inlined = inlineSolvedMetas(rootTerm, ps.metas);
    final termStr = prettyTerm(inlined, outerDepth: 0);
    return (ReplMeta(termStr), this);
  }

  /// Handle `:qed` — finish the proof and add the theorem binding.
  ReplStep _handleQed() {
    final ps = proofState;
    if (ps == null) {
      return (
        const ReplMeta('No proof in progress. Use :goal to start.'),
        this,
      );
    }

    // Check for unsolved metas.
    final unsolved = <int>[];
    for (var i = 0; i < ps.metas.length; i++) {
      if (!ps.metas.isSolved(i)) {
        unsolved.add(i);
      }
    }
    if (unsolved.isNotEmpty) {
      return (
        ReplMeta('Proof incomplete: ${unsolved.length} subgoal(s) remain.'),
        this,
      );
    }

    // Get the final proof term.
    final rootTerm = ps.metas.solutionOf(ps.rootGoalMetaId);
    final finalTerm = inlineSolvedMetas(rootTerm, ps.metas);

    // Type-check the final term.
    final checkCtx = ps.topEnv.toCtx();
    try {
      final inferred = infer(checkCtx, finalTerm);
      final typeValue = eval(ps.theoremType, checkCtx.env);
      // Use lightweight conversion check.
      final quotedInferred = quote(checkCtx.level, inferred);
      final quotedExpected = quote(checkCtx.level, typeValue);
      if (quotedInferred != quotedExpected) {
        return (ReplMeta('QED failed: type mismatch'), this);
      }
    } on Object {
      return (ReplMeta('QED failed: type-checking error'), this);
    }

    // Create the TopBinding.
    final binding = TopBinding(
      name: ps.theoremName,
      type: ps.theoremType,
      term: finalTerm,
      span: DoxaSpan.synthetic,
    );

    final newBindings = [...bindings, binding];
    return (
      ReplMeta(
        '${ps.theoremName} : ${prettyTerm(ps.theoremType, outerDepth: 0)}',
      ),
      ReplSession(
        bindings: newBindings,
        dataDecls: dataDecls,
        namespaceBindings: namespaceBindings,
      ),
    );
  }

  /// Handle `:abort` — cancel the current proof.
  ReplStep _handleAbort() {
    if (proofState == null) {
      return (const ReplMeta('No proof in progress.'), this);
    }
    return (
      const ReplMeta('Proof aborted.'),
      ReplSession(
        bindings: bindings,
        dataDecls: dataDecls,
        namespaceBindings: namespaceBindings,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Build an [Env] with all accumulated bindings and data decls
  /// registered, so `TTop(name)` references resolve.
  Env _buildFullEnv() {
    var acc = <String, TopBindingEntry>{};
    for (final b in bindings) {
      // Pre-seed with a stub so recursive self-references resolve
      // (same pattern as checkDeclResult for corecursive groups).
      final stubAcc = {
        ...acc,
        b.name: TopBindingEntry(
          VNeutral(NVar(0)), // placeholder
          VNeutral(NTop(b.name)),
          isOpaque: b.isOpaque,
          recDecreasingArg: b.recDecreasingArg,
          recArity: b.recArity,
        ),
      };
      final env = ENil.withRegistries(
        dataDecls: dataDecls,
        topBindings: stubAcc,
      );
      final typeV = eval(b.type, env);
      final termV = eval(b.term, env);
      acc = {
        ...acc,
        b.name: TopBindingEntry(
          typeV,
          termV,
          isOpaque: b.isOpaque,
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
