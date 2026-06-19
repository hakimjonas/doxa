/// Pretty-printer: kernel [Term] to surface-like source.
///
/// The pretty-printer is diagnostic-grade, not round-trip-grade. It
/// renders kernel terms in a form that matches the surface syntax and
/// uses the user's original binder names where available (via the
/// `TLam.name` / `TPi.name` hints carried through the kernel, see SPEC
/// §3.2). Where a hint is null (non-dependent arrows, synthesized
/// binders), it falls back to synthesized names `_a`, `_b`, ….
///
/// The printer never re-parses its output. In particular:
///
///   * An `SExpr` parsed from `prettyTerm(t)` is not guaranteed to
///     equal `t` (names may have been adjusted for shadowing).
///   * The output is meant for human consumption in error messages
///     and normal-form display.
///
/// Precedence handling: the printer parenthesizes aggressively when in
/// doubt. A free-standing `Type` atom is never parenthesized; `A -> B`
/// in argument position is; `f x` in argument position is.
library;

import 'term.dart';

/// Pretty-print [term] in surface-like syntax.
///
/// If the term references bound variables at indices 0..[outerDepth]-1
/// (i.e., the term was quoted at [outerDepth] and expects that many
/// enclosing binders), the printer pre-populates its scope.
///
/// [outerNames] provides names for those outer binders (outermost-first).
/// Any entry that is null falls back to a synthesized placeholder. If
/// the list is shorter than [outerDepth], the remaining outer binders
/// get synthesized names too.
///
/// See the library docstring for caveats.
String prettyTerm(
  Term term, {
  int outerDepth = 0,
  List<String?> outerNames = const <String?>[],
}) {
  final printer = _Printer();
  for (var i = 0; i < outerDepth; i++) {
    final hint = i < outerNames.length ? outerNames[i] : null;
    final name =
        (hint != null && !printer.scope.contains(hint))
            ? hint
            : '?${printer._letterName(i)}';
    printer.scope.add(name);
  }
  return printer.term(term, _precTop);
}

// Precedence levels. Higher = binds tighter. Used to decide when to
// wrap a sub-expression in parentheses.
const int _precTop = 0; // top-level (no wrapping needed)
const int _precAppFn = 2; // function position of an application
const int _precAppArg = 3; // argument position of an application

class _Printer {
  /// Names currently in scope, innermost-last. `scope[n - 1 - i]` is the
  /// name of `TBound(i)` where `n == scope.length`.
  final List<String> scope = <String>[];

  /// Counter for synthesized names when a binder has no hint.
  int synthCounter = 0;

  /// Pretty-print a [Level] as a `Type` expression.
  String _prettyLevel(Level l) => switch (l) {
    LLevel(level: 0) => 'Type',
    LLevel(:final level) => 'Type $level',
    LVar(:final name) => 'Type $name',
    LSucc(:final of) => 'Type (succ ${_prettyLevel(of)})',
    LMax(:final lhs, :final rhs) =>
      'Type (max ${_prettyLevel(lhs)} ${_prettyLevel(rhs)})',
    LImax(:final lhs, :final rhs) =>
      'Type (imax ${_prettyLevel(lhs)} ${_prettyLevel(rhs)})',
  };

  String term(Term t, int prec) => switch (t) {
    TType(:final level) => _prettyLevel(level),
    TProp() => 'Prop',
    TBound(:final index) => _boundName(index),
    // TFree should not appear in well-formed kernel terms after
    // elaboration, but we still render it sanely.
    TFree(:final name) => name,
    TApp(:final fn, :final arg) => _app(fn, arg, prec),
    TLam(:final name, :final domain, :final body) => _lam(
      name,
      domain,
      body,
      prec,
    ),
    TPi(:final name, :final domain, :final codomain) => _pi(
      name,
      domain,
      codomain,
      prec,
    ),
    TLet(:final name, :final domain, :final bound, :final body) => _let(
      name,
      domain,
      bound,
      body,
      prec,
    ),
    TData(:final name, :final args) => _data(name, args, prec),
    TConstr(:final dataName, :final ctorName, :final args) => _constr(
      dataName,
      ctorName,
      args,
      prec,
    ),
    TRec(:final dataName) => '$dataName.rec',
    TTop(:final name) => name,
    TMeta(:final id) => '?$id',
    TMatch(:final scrutinee, :final cases) => _match(scrutinee, cases, prec),
    TQuot(:final carrier, :final relation) =>
      'Quot(${term(carrier, _precTop)}, ${term(relation, _precTop)})',
    TQuotMk(:final arg) => 'Quot.mk(${term(arg, _precAppArg)})',
    TQuotLift(:final quot, :final fn, :final proof) =>
      'Quot.lift(${term(quot, _precAppArg)}, ${term(fn, _precAppArg)}, ${term(proof, _precAppArg)})',
  };

  /// Render a `match` expression in surface form (no separator between
  /// arms; `}` terminates). Omits the motive in pretty output, the
  /// surface syntax allows `returning P` but the common case is the
  /// inferred motive, which readers don't want echoed back. If needed,
  /// a `returning P` variant of the printer can be added later.
  String _match(Term scrutinee, List<TMatchCase> cases, int prec) {
    final sb = StringBuffer();
    sb.write('match ');
    sb.write(term(scrutinee, _precAppArg));
    sb.write(' {');
    for (final arm in cases) {
      sb.write(' case ');
      // Allocate display names for the arm's binders. We push them
      // onto `scope` before rendering the body so TBound resolves
      // correctly; use the literal "_" for underscore hints.
      final pushed = <String>[];
      for (var i = 0; i < arm.nBinders; i++) {
        final hint = arm.binderNames[i];
        final name = hint == '_' ? '_' : _freshBinder(hint);
        scope.add(name);
        pushed.add(name);
      }
      if (arm.isWildcard) {
        sb.write('_');
      } else {
        sb.write(arm.ctorName);
        for (var i = 0; i < arm.nBinders; i++) {
          sb.write(' ');
          sb.write(pushed[i]);
        }
      }
      sb.write(' => ');
      sb.write(term(arm.body, _precTop));
      for (var i = 0; i < pushed.length; i++) {
        scope.removeLast();
      }
    }
    sb.write(' }');
    return prec > _precTop ? '(${sb.toString()})' : sb.toString();
  }

  String _boundName(int index) {
    if (index < 0 || index >= scope.length) {
      // Invariant violation, should never happen for well-formed
      // kernel terms, but don't crash in a diagnostic printer.
      return '?$index';
    }
    return scope[scope.length - 1 - index];
  }

  /// Allocate a name for a new binder. Prefer the hint if it doesn't
  /// shadow an existing name; otherwise synthesize a fresh one.
  String _freshBinder(String? hint) {
    if (hint != null && !scope.contains(hint)) return hint;
    // Synthesize `_a`, `_b`, … avoiding collisions. Start from the
    // current hint (if any) for better readability: `a` becomes `a_1`
    // if `a` is taken.
    if (hint != null) {
      var i = 1;
      while (scope.contains('${hint}_$i')) {
        i += 1;
      }
      return '${hint}_$i';
    }
    while (true) {
      final name = '_${_letterName(synthCounter)}';
      synthCounter += 1;
      if (!scope.contains(name)) return name;
    }
  }

  /// `0 -> "a"`, `1 -> "b"`, …, `25 -> "z"`, `26 -> "a1"`, `27 -> "b1"`, …
  String _letterName(int n) {
    final letter = String.fromCharCode('a'.codeUnitAt(0) + (n % 26));
    final round = n ~/ 26;
    return round == 0 ? letter : '$letter$round';
  }

  String _app(Term fn, Term arg, int prec) {
    final fnStr = term(fn, _precAppFn);
    final argStr = term(arg, _precAppArg);
    final s = '$fnStr $argStr';
    return prec >= _precAppArg ? '($s)' : s;
  }

  String _lam(String? hint, Term domain, Term body, int prec) {
    final name = _freshBinder(hint);
    final domStr = term(domain, _precTop);
    scope.add(name);
    // Lambdas are right-extended: the body goes at _precTop so a nested
    // lambda doesn't wrap.
    final bodyStr = term(body, _precTop);
    scope.removeLast();
    final s = '($name: $domStr) => $bodyStr';
    // Lambda and arrow share the same syntactic "right-biased" shape.
    // Wrap only when appearing in application-argument position.
    return prec >= _precAppFn ? '($s)' : s;
  }

  String _pi(String? hint, Term domain, Term codomain, int prec) {
    // Non-dependent arrow detection: hint is null AND the codomain
    // never references TBound(0). This is the syntactic shortcut
    // `A -> B` rather than `(_: A) -> B`.
    if (hint == null && !_referencesBound0(codomain)) {
      final domStr = term(domain, _precAppFn);
      scope.add('_'); // placeholder for index accounting
      // Right-associative: the codomain accepts another arrow without
      // parens. Use _precTop to allow that.
      final codStr = term(codomain, _precTop);
      scope.removeLast();
      final s = '$domStr -> $codStr';
      return prec >= _precAppFn ? '($s)' : s;
    }
    final name = _freshBinder(hint);
    final domStr = term(domain, _precTop);
    scope.add(name);
    final codStr = term(codomain, _precTop);
    scope.removeLast();
    final s = '($name: $domStr) -> $codStr';
    return prec >= _precAppFn ? '($s)' : s;
  }

  String _let(String? hint, Term domain, Term bound, Term body, int prec) {
    final name = _freshBinder(hint);
    final domStr = term(domain, _precTop);
    final boundStr = term(bound, _precTop);
    scope.add(name);
    final bodyStr = term(body, _precTop);
    scope.removeLast();
    // Value-block form: a `val` binding (terminated by `;`) then the
    // body as the block's value (implicit, no `in` keyword). A let-chain
    // nests blocks, which is faithful if verbose. A block is brace-
    // delimited and self-bracketing, so it never needs wrapping parens.
    return '{ val $name: $domStr = $boundStr; $bodyStr }';
  }

  String _data(String name, List<Term> args, int prec) {
    if (args.isEmpty) return name;
    final parts = [name, for (final a in args) term(a, _precAppArg)];
    final s = parts.join(' ');
    return prec >= _precAppArg ? '($s)' : s;
  }

  String _constr(String dataName, String ctorName, List<Term> args, int prec) {
    // Constructors are printed as `ctorName` or `ctorName a1 a2 ...`.
    // The data parameters occupy the initial positions in `args` but
    // they're usually redundant (inferred from the ctor's expected
    // type); for now we print them all for unambiguity.
    if (args.isEmpty) return ctorName;
    final parts = [ctorName, for (final a in args) term(a, _precAppArg)];
    final s = parts.join(' ');
    return prec >= _precAppArg ? '($s)' : s;
  }
}

/// True if [t] contains any reference to de Bruijn index 0 at its current
/// depth (where "current depth" means: no binders have been descended
/// into from t's perspective).
///
/// Used by the Pi printer to decide whether to render as the
/// non-dependent arrow sugar `A -> B`.
bool _referencesBound0(Term t) => _refBound(t, 0);

bool _refBound(Term t, int depth) => switch (t) {
  TType() => false,
  TProp() => false,
  TFree() => false,
  TTop() => false,
  TMeta() => false,
  TBound(:final index) => index == depth,
  TApp(:final fn, :final arg) => _refBound(fn, depth) || _refBound(arg, depth),
  TLam(:final domain, :final body) =>
    _refBound(domain, depth) || _refBound(body, depth + 1),
  TLet(:final domain, :final bound, :final body) =>
    _refBound(domain, depth) ||
        _refBound(bound, depth) ||
        _refBound(body, depth + 1),
  TPi(:final domain, :final codomain) =>
    _refBound(domain, depth) || _refBound(codomain, depth + 1),
  TData(:final args) => args.any((a) => _refBound(a, depth)),
  TConstr(:final args) => args.any((a) => _refBound(a, depth)),
  TRec() => false,
  TMatch(:final scrutinee, :final motive, :final cases) =>
    _refBound(scrutinee, depth) ||
        (motive != null && _refBound(motive, depth)) ||
        cases.any((c) => _refBound(c.body, depth + c.nBinders)),
  TQuot(:final carrier, :final relation) =>
    _refBound(carrier, depth) || _refBound(relation, depth),
  TQuotMk(:final arg) => _refBound(arg, depth),
  TQuotLift(:final quot, :final fn, :final proof) =>
    _refBound(quot, depth) || _refBound(fn, depth) || _refBound(proof, depth),
};
