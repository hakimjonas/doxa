/// Unreachability detection for indexed-family matches.
library;

import 'package:doxa/src/check.dart' show IndexedMatchNotExhaustive;
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

void _elabAndCheck(String src) {
  // Drive the same `elabDecl` + `checkDeclResult` path as the CLI so
  // solved metavariables are inlined into the finalized terms before
  // checking (a raw `elabProgram` + `check` would leave `TMeta` nodes
  // that a metas-free `check` ctx rejects).
  final prog = _parse(src);
  var bindings = const <TopBinding>[];
  var dataDecls = const <DataDecl>[];
  for (final decl in prog.decls) {
    final env = TopEnv(bindings, dataDecls);
    final produced = elabDecl(env, decl);
    final runningData = [...dataDecls, ...produced.dataDecls];
    final finalized = checkDeclResult(TopEnv(bindings, runningData), produced);
    bindings = [...bindings, ...finalized];
    dataDecls = runningData;
  }
}

const _vecPrelude = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''';

void main() {
  group('unreachable ctor detection (first-order clash)', () {
    test('vhead on Vec[A] (succ n): vnil arm can be omitted', () {
      // Scrutinee index `succ n`; vnil's result index is `zero`.
      // `succ _` vs `zero` is a ctor-head clash → vnil unreachable.
      _elabAndCheck('''
$_vecPrelude
fun vhead[A: Type](n: Nat, v: Vec[A] (succ n)): A = match v {
  case vcons m x xs => x
}
''');
    });

    test('vhead on Vec[A] (succ zero): vnil omittable, vcons required', () {
      _elabAndCheck('''
$_vecPrelude
fun vhead1[A: Type](v: Vec[A] (succ zero)): A = match v {
  case vcons m x xs => x
}
''');
    });

    test('Vec[A] zero: vcons is unreachable, only vnil required', () {
      // Scrutinee index `zero`; vcons's result index is `succ _`.
      // → vcons unreachable. The arm body is a bare nullary `vnil`: its
      // implicit type parameter is solved by check-mode propagation of
      // the per-arm refined expected type (`Vec[A] zero`), so no explicit
      // type argument is needed.
      _elabAndCheck('''
$_vecPrelude
fun vEmptyId[A: Type](v: Vec[A] zero): Vec[A] zero = match v {
  case vnil => vnil
}
''');
    });

    test('match with both arms always accepted (no unreachability needed)', () {
      _elabAndCheck('''
$_vecPrelude
fun vhead[A: Type](def: A, n: Nat, v: Vec[A] n): A = match v {
  case vnil => def
  case vcons m x xs => x
}
''');
    });

    test('wildcard covers all uncovered ctors regardless of reachability', () {
      _elabAndCheck('''
$_vecPrelude
fun anything[A: Type](def: A, n: Nat, v: Vec[A] n): A = match v {
  case vnil => def
  case _ => def
}
''');
    });

    test('bare nullary ctor in indexed arm checks against refined index', () {
      // Identity on a length-indexed vector. The scrutinee index `n` is
      // a neutral free variable, so the raw expected at the vnil arm is
      // `Vec[A] n`. Only AFTER per-arm refinement (n := zero in the vnil
      // arm) does the bare `vnil : Vec[A] zero` check. If the elaborator
      // checked the body against raw `expected` it would mismatch, and
      // an infer-mode body could not solve vnil's implicit A. This
      // exercises the elab-time first-order index refinement.
      _elabAndCheck('''
$_vecPrelude
fun vid[A: Type](n: Nat, v: Vec[A] n): Vec[A] n = match v {
  case vnil => vnil
  case vcons k x xs => vcons k x xs
}
''');
    });
  });

  group('coverage failure (uncovered reachable ctor)', () {
    test('Vec[A] n: must cover both vnil and vcons', () {
      // Scrutinee index is free `n`; both vnil (index zero) and
      // vcons (index succ _) unify with `n`. Both reachable.
      // Missing vcons → coverage failure.
      expect(
        () => _elabAndCheck('''
$_vecPrelude
fun bad[A: Type](def: A, n: Nat, v: Vec[A] n): A = match v {
  case vnil => def
}
'''),
        throwsA(
          isA<IndexedMatchNotExhaustive>()
              .having((e) => e.dataName, 'dataName', 'Vec')
              .having((e) => e.missingReachableCtors, 'missingReachableCtors', [
                'vcons',
              ]),
        ),
      );
    });

    test('Vec[A] n: missing vnil alone → only vnil reported', () {
      expect(
        () => _elabAndCheck('''
$_vecPrelude
fun bad[A: Type](n: Nat, v: Vec[A] n): A = match v {
  case vcons m x xs => x
}
'''),
        throwsA(
          isA<IndexedMatchNotExhaustive>().having(
            (e) => e.missingReachableCtors,
            'missingReachableCtors',
            ['vnil'],
          ),
        ),
      );
    });

    test('completely empty match (with explicit motive) → both ctors '
        'reported missing', () {
      // Empty match without a ctor arm needs an explicit motive so
      // the elaborator can determine the scrutinee's data type.
      // (A bare `match v { }` with no arms and no `returning`
      // clause hits MatchIndeterminateType at elab-time instead
      // earlier in the pipeline than this test.)
      expect(
        () => _elabAndCheck('''
$_vecPrelude
fun bad[A: Type](def: A, n: Nat, v: Vec[A] n): A =
  match v returning A { }
'''),
        throwsA(
          isA<IndexedMatchNotExhaustive>().having(
            (e) => e.missingReachableCtors,
            'missingReachableCtors',
            ['vnil', 'vcons'],
          ),
        ),
      );
    });
  });

  group('non-indexed coverage unchanged', () {
    test(
      'Nat missing succ: still elab-rejects (NonExhaustiveMatch, not Indexed)',
      () {
        // Non-indexed data: coverage still runs at elab time.
        expect(
          () => _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
fun bad(n: Nat): Nat = match n {
  case zero => zero
}
'''),
          throwsA(isA<NonExhaustiveMatch>()),
        );
      },
    );

    test('Bool both arms required (unchanged behaviour)', () {
      _elabAndCheck('''
data Bool : Type { true_ : Bool; false_ : Bool; }
fun not_(b: Bool): Bool = match b {
  case true_  => false_
  case false_ => true_
}
''');
    });
  });

  group('refinement-needing cases (first-order index refinement)', () {
    test('vtail: arm body uses first-order kernel-side index refinement', () {
      // vcons arm body: xs : Vec[A] m, expected: Vec[A] n.
      // First-order refinement: scrutinee's `succ n` vs vcons's `succ m`
      // yields n == m; expected Vec[A] n refines to Vec[A] m, matching
      // the body's inferred type.
      _elabAndCheck('''
$_vecPrelude
fun vtail[A: Type](n: Nat, v: Vec[A] (succ n)): Vec[A] n =
  match v returning Vec[A] n {
    case vcons m x xs => xs
  }
''');
    });
  });
}
