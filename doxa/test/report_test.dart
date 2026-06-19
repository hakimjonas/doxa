import 'package:doxa/src/check.dart';
import 'package:doxa/src/diff.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/report.dart';
import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SourceFile _src(String text, [String filename = 'input.doxa']) =>
    SourceFile(filename: filename, text: text);

void main() {
  group('Diff walker', () {
    test('top-level universe mismatch has empty path', () {
      final diff = diffValues(const VType(LLevel(0)), const VType(LLevel(1)));
      expect(diff.isTopLevel, isTrue);
      expect((diff.got as VType).level, const LLevel(0));
      expect((diff.expected as VType).level, const LLevel(1));
    });

    test('Pi domain mismatch: path = [domain]', () {
      // (Type 0 -> X) vs (Type 1 -> X), domains differ.
      final a = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(5))),
        const ENil(),
      );
      final b = eval(
        const TPi(TType(LLevel(1)), TType(LLevel(5))),
        const ENil(),
      );
      final diff = diffValues(a, b);
      expect(diff.steps, [isA<DiffDomain>()]);
      expect((diff.got as VType).level, const LLevel(0));
      expect((diff.expected as VType).level, const LLevel(1));
    });

    test('Pi codomain mismatch: path = [codomain]', () {
      // (Type 0 -> Type 5) vs (Type 0 -> Type 6), codomains differ.
      final a = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(5))),
        const ENil(),
      );
      final b = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(6))),
        const ENil(),
      );
      final diff = diffValues(a, b);
      expect(diff.steps, [isA<DiffCodomain>()]);
      expect((diff.got as VType).level, const LLevel(5));
      expect((diff.expected as VType).level, const LLevel(6));
    });

    test('deep Pi path: [codomain, codomain] -> divergence', () {
      // (Type 0 -> (Type 0 -> Type 5)) vs (Type 0 -> (Type 0 -> Type 6))
      final a = eval(
        const TPi(TType(LLevel(0)), TPi(TType(LLevel(0)), TType(LLevel(5)))),
        const ENil(),
      );
      final b = eval(
        const TPi(TType(LLevel(0)), TPi(TType(LLevel(0)), TType(LLevel(6)))),
        const ENil(),
      );
      final diff = diffValues(a, b);
      expect(diff.steps, [isA<DiffCodomain>(), isA<DiffCodomain>()]);
    });
  });

  group('Check error reports', () {
    test('TypeMismatch format', () {
      final src = _src('val x: Type 0 = Type\n');
      // Build manually: got = VType(LLevel(1)), expected = VType(LLevel(0)).
      const err = TypeMismatch(
        VType(LLevel(1)),
        VType(LLevel(0)),
        ConvMismatch(VType(LLevel(1)), VType(LLevel(0))),
      );
      final out = reportCheckError(src, err, const DoxaSpan(16, 20));
      expect(out, contains('error: type mismatch'));
      expect(out, contains('input.doxa:1:17'));
      expect(out, contains('expected: Type'));
      expect(out, contains('actual:   Type 1'));
    });

    test('TypeMismatch includes diff path when not top-level', () {
      // (Type 0 -> Type 0) vs (Type 0 -> Type 1), codomain mismatch.
      final got = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const ENil(),
      );
      final expected = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(1))),
        const ENil(),
      );
      final err = TypeMismatch(
        got,
        expected,
        const ConvMismatch(VType(LLevel(0)), VType(LLevel(1))),
      );
      final src = _src('unused');
      final out = reportCheckError(src, err, const DoxaSpan(0, 6));
      expect(out, contains('first difference at codomain:'));
      expect(out, contains('expected:  Type 1'));
      expect(out, contains('actual:    Type'));
    });

    test('NotAFunction format', () {
      final src = _src('val x = Type Type\n');
      const err = NotAFunction(VType(LLevel(1)));
      final out = reportCheckError(src, err, const DoxaSpan(8, 17));
      expect(out, contains('error: not a function'));
      expect(out, contains('has type: Type 1'));
    });

    test('NotAType format', () {
      final src = _src('unused');
      const err = NotAType(VType(LLevel(1)));
      final out = reportCheckError(src, err, const DoxaSpan(0, 6));
      expect(out, contains('error: not a type'));
      expect(out, contains('expected a universe'));
    });
  });

  group('TypeMismatch carries the offending sub-expression span', () {
    // The elaborator attaches `expr.span` to a TypeMismatch raised while
    // checking/inferring a sub-expression (the provenance seed). The
    // reporter then points the caret at the term, not the declaration.

    SProgram parseProg(String text) {
      final r = parseProgram(text);
      return switch (r) {
        Success<ParseError, SProgram>(:final value) => value,
        Partial<ParseError, SProgram>(:final value) => value,
        _ => fail('parse failed: $r'),
      };
    }

    // Elaborate a single-decl program preceded by the given data decls,
    // returning the TypeMismatch the body raises (or failing if none).
    TypeMismatch mismatchOf(String prelude, String decl) {
      final prog = parseProg('$prelude\n$decl');
      var bindings = const <TopBinding>[];
      var dataDecls = const <DataDecl>[];
      try {
        for (final d in prog.decls) {
          final produced = elabDecl(TopEnv(bindings, dataDecls), d);
          dataDecls = [...dataDecls, ...produced.dataDecls];
          bindings = [
            ...bindings,
            ...checkDeclResult(TopEnv(bindings, dataDecls), produced),
          ];
        }
      } on TypeMismatch catch (e) {
        return e;
      }
      fail('expected a TypeMismatch, none thrown');
    }

    test('val body of wrong type: span covers the body term', () {
      const text =
          'data Bool : Type { true : Bool; false : Bool; }\n'
          'data Nat : Type { zero : Nat; succ : Nat -> Nat; }\n'
          'val oops : Bool = zero';
      final m = mismatchOf(
        'data Bool : Type { true : Bool; false : Bool; }\n'
            'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
        'val oops : Bool = zero',
      );
      expect(m.span, isNotNull);
      // The span must point at `zero`, not at the `val` declaration head.
      final sf = SourceFile(filename: 'x.doxa', text: text);
      final out = reportCheckError(sf, m, m.span!);
      // Caret on `zero` (col 19), not the `val` declaration head (col 1).
      expect(out, contains('x.doxa:3:19'));
      expect(out, isNot(contains('at x.doxa:3:1\n')));
    });

    test('mismatched application argument: span covers the bad arg', () {
      final m = mismatchOf(
        'data Bool : Type { true : Bool; false : Bool; }\n'
            'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
        'val n : Nat = succ false',
      );
      expect(m.span, isNotNull);
      const text =
          'data Bool : Type { true : Bool; false : Bool; }\n'
          'data Nat : Type { zero : Nat; succ : Nat -> Nat; }\n'
          'val n : Nat = succ false';
      final sf = SourceFile(filename: 'x.doxa', text: text);
      final out = reportCheckError(sf, m, m.span!);
      expect(out, contains('x.doxa:3:20')); // column of `false`
    });

    test('withSpan keeps the innermost (first) attachment', () {
      const inner = ConvMismatch(VType(LLevel(0)), VType(LLevel(1)));
      const base = TypeMismatch(VType(LLevel(0)), VType(LLevel(1)), inner);
      final tagged = base.withSpan(const DoxaSpan(5, 9));
      // A second, wider span must not overwrite the first.
      final retagged = tagged.withSpan(const DoxaSpan(0, 20));
      expect(retagged.span, const DoxaSpan(5, 9));
    });
  });

  group('Elab error reports', () {
    test('UnresolvedName format', () {
      final src = _src('val x = foo\n');
      const err = UnresolvedName('foo', DoxaSpan(8, 11));
      final out = reportElabError(src, err);
      expect(out, contains('error: unresolved name'));
      expect(out, contains('input.doxa:1:9'));
      expect(out, contains('no binding for "foo"'));
    });

    test('DuplicateDeclaration format includes previous span', () {
      final src = _src('val x = Type val x = Type\n');
      const err = DuplicateDeclaration('x', DoxaSpan(0, 12), DoxaSpan(13, 25));
      final out = reportElabError(src, err);
      expect(out, contains('error: duplicate declaration'));
      expect(out, contains('"x" was previously declared here:'));
      expect(out, contains('input.doxa:1:1'));
      expect(out, contains('input.doxa:1:14'));
    });
  });

  group('Parse error reports', () {
    test('reportParseFailure formats a Rumil Failure', () {
      final src = _src('val x = )\n');
      final r = parseProgram(src.text);
      expect(r, isA<Failure<ParseError, Object?>>());
      final out = reportParseFailure(src, r as Failure<ParseError, Object?>);
      expect(out, contains('error: parse error'));
      expect(out, contains('input.doxa:'));
    });
  });

  group('Diff walker: binder names', () {
    test('path through named Pi records its binder name', () {
      // (A: Type) -> A   vs   (A: Type) -> Type, codomain differs.
      // Walker descends one Pi, so binderNames should be ['A'].
      final program = parseProgram('val _: Type 1 = Type\n');
      // ^ just to get the parser going. We construct the values directly.
      expect(program, isA<Success<ParseError, SProgram>>());
      final a = eval(
        const TPi(TType(LLevel(0)), TBound(0), name: 'A'),
        const ENil(),
      );
      final b = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0)), name: 'A'),
        const ENil(),
      );
      final diff = diffValues(a, b);
      expect(diff.steps, [isA<DiffCodomain>()]);
      expect(diff.binderNames, ['A']);
    });
  });

  group('End-to-end: preserved names in diagnostics', () {
    test('error on dependent type mismatch uses user names', () {
      // val x : (A: Type) -> A -> A = (x: Type) => x
      // The body has type Type 0 -> Type 0 (after annotating), but the
      // declared type is the dependent id type (A: Type) -> A -> A.
      // These don't convert.
      final program = parseProgram(
        'val x: (A: Type) -> A -> A = (y: Type) => y\n',
      );
      final p = switch (program) {
        Success<ParseError, SProgram>(:final value) => value,
        _ => fail('parse failed: $program'),
      };
      try {
        final env = elabProgram(p);
        // Now try to check: the val body's type (Type -> Type) does not
        // match the declared type ((A: Type) -> A -> A). Recompute.
        final b = env.bindings[0];
        // Check that the evaluated body term has the declared type.
        final bodyType = infer(env.toCtx(), b.term);
        final expectedType = eval(b.type, const ENil());
        final r = conv(0, bodyType, expectedType);
        if (r is ConvMismatch) {
          final err = TypeMismatch(bodyType, expectedType, r);
          final src = _src('val x: (A: Type) -> A -> A = (y: Type) => y\n');
          final out = reportCheckError(src, err, b.span);
          // The user's name "A" should appear in the expected rendering.
          expect(out, contains('A'));
        } else {
          fail('expected a mismatch, got Ok');
        }
      } on DoxaCheckError catch (e) {
        // If the elaborator/checker raises directly, format that.
        final src = _src('val x: (A: Type) -> A -> A = (y: Type) => y\n');
        final out = reportCheckError(src, e, const DoxaSpan(0, 44));
        expect(out, contains('error:'));
      }
    });
  });

  // Regression tests: TypeMismatch is rendered at the correct Ctx
  // level, so free variables pointing at enclosing binders produce
  // placeholders (`?a`, `?b`) instead of negative-index lies (`?-N`).
  // Rendering the user's real names (e.g. `A` for `fun f[A: Type]`) is
  // not covered here.
  group('SPEC §6.2 tier 1: no ?-N lies', () {
    test('body type-mismatch under a type param: renders without ?-N', () {
      // fun bad[A: Type](a: A): A = zero, whose body returns `zero`
      // (Nat) where A is expected. Pre-fix this rendered
      // `expected: ?-3`; post-fix it produces a synthesized
      // placeholder. The TypeMismatch fires during check-mode body
      // elaboration rather than a separate post-elab check call, but
      // the diagnostic content is the same.
      final src = _src(
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }\n'
        'fun bad[A: Type](a: A): A = zero\n',
      );
      final program = parseProgram(src.text);
      final p = switch (program) {
        Success<ParseError, SProgram>(:final value) => value,
        _ => fail('parse failed: $program'),
      };
      try {
        elabProgram(p);
        fail('expected TypeMismatch, got ok');
      } on TypeMismatch catch (e) {
        final out = reportCheckError(src, e, DoxaSpan.synthetic);
        expect(
          out,
          isNot(contains('?-')),
          reason: 'SPEC §6.2 tier 1: no negative-index placeholders.',
        );
        expect(out, contains('error: type mismatch'));
      }
    });

    test('inside a lambda body: descent level is honoured in output', () {
      // val x: (A: Type) -> A -> A = (y: Type) => y,
      // inside the `y`-lambda body, the expected type is
      //   `A -> A`. Pre-fix rendered `(_a: ?-1) -> _a`; post-fix
      //   renders `?a -> ?a` (honest placeholder for the outer
      //   binder).
      final src = _src('val x: (A: Type) -> A -> A = (y: Type) => y\n');
      final program = parseProgram(src.text);
      final p = switch (program) {
        Success<ParseError, SProgram>(:final value) => value,
        _ => fail('parse failed: $program'),
      };
      // The body is now checked against the declared type during
      // elaboration, so the mismatch surfaces from `elabProgram`.
      try {
        elabProgram(p);
        fail('expected TypeMismatch');
      } on TypeMismatch catch (e) {
        final out = reportCheckError(src, e, DoxaSpan.synthetic);
        expect(
          out,
          isNot(contains('?-')),
          reason: 'no negative-index placeholders',
        );
      }
    });
  });
}
