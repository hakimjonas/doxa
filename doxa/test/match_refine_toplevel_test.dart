/// Regression: a dependent `match` on a non-indexed type must refine the
/// expected type per arm even when that expected type mentions a
/// top-level recursive function.
///
/// `substNVar` used to return a substituted application as a frozen
/// `VFun`: substituting `n := zero` in `plus n zero` rewrites the spine,
/// but the resulting application already satisfies the fix-reduction
/// guard (saturated, decreasing argument canonical) and is never
/// unfolded. `conv` treats a stuck `VFun` as opaque, so the refined arm
/// type stayed `Eq Nat (plus zero zero) ...` while a correct arm body
/// inferred `Eq Nat zero ...`, and the kernel re-check rejected the
/// declaration.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate and declaration-check [src] the way the CLI does, starting
/// from the prelude so `Eq` is available.
TopEnv _elabAndCheck(String src) {
  final prelude = loadPrelude();
  final program = _parse(src);
  var bindings = <TopBinding>[...prelude.bindings];
  var dataDecls = <DataDecl>[...prelude.dataDecls];
  var classRegistry = <String, ClassInfo>{};
  var namespaceBindings = <String, Set<String>>{...prelude.namespaceBindings};
  for (final decl in program.decls) {
    final produced = elabDecl(
      TopEnv(bindings, dataDecls, classRegistry, namespaceBindings),
      decl,
    );
    dataDecls = <DataDecl>[...dataDecls, ...produced.dataDecls];
    bindings = <TopBinding>[
      ...bindings,
      ...checkDeclResult(
        TopEnv(bindings, dataDecls, classRegistry, namespaceBindings),
        produced,
      ),
    ];
    classRegistry = <String, ClassInfo>{
      ...classRegistry,
      ...produced.classRegistry,
    };
    namespaceBindings = mergeNamespace(
      namespaceBindings,
      produced.namespaceBindings,
    );
  }
  return TopEnv(bindings, dataDecls, classRegistry, namespaceBindings);
}

TopBinding _binding(TopEnv env, String name) =>
    env.bindings.firstWhere((b) => b.name == name);

/// The shared prefix: `Nat` plus the recursive top-level function whose
/// application the per-arm expected type mentions.
const _natAndPlus = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ k => succ (plus k n)
}
''';

void main() {
  group('non-indexed match refinement with a top-level function', () {
    test('a refined Nat arm reduces an application whose scrutinee became '
        'canonical', () {
      // Before the fix the zero arm's expected type stayed
      // `Eq Nat (plus zero zero) (plus zero zero)`: the kernel re-check
      // compared a stuck VFun with zero and rejected the declaration.
      final env = _elabAndCheck('''
$_natAndPlus
val plus_refl : (n: Nat) -> Eq Nat (plus n zero) (plus n zero) =
  (n: Nat) => match n returning Eq Nat (plus n zero) (plus n zero) {
    case zero => refl (plus zero zero)
    case succ k => refl (plus (succ k) zero)
  }
''');
      expect(_binding(env, 'plus_refl').name, 'plus_refl');
    });

    test('the same goal without a returning clause refines from the '
        'expected type', () {
      // No explicit motive: `_elabMatch` receives the expected type and
      // refines it per arm. Bare `refl` then picks its type and index
      // from that refined arm type.
      final env = _elabAndCheck('''
$_natAndPlus
val plus_refl_nomotive : (n: Nat) -> Eq Nat (plus n zero) (plus n zero) =
  (n: Nat) => match n {
    case zero => refl
    case succ k => refl
  }
''');
      expect(_binding(env, 'plus_refl_nomotive').name, 'plus_refl_nomotive');
    });

    test('a match whose expected type has no top-level function still '
        'refines', () {
      final env = _elabAndCheck('''
$_natAndPlus
val id_refl : (n: Nat) -> Eq Nat n n =
  (n: Nat) => match n returning Eq Nat n n {
    case zero => refl zero
    case succ k => refl (succ k)
  }
''');
      expect(_binding(env, 'id_refl').name, 'id_refl');
    });

    test('a stuck application whose decreasing argument stays neutral is '
        'not disturbed', () {
      // `plus m n` with `m` a neutral parameter cannot reduce. Refining
      // `n` must keep the application stuck and still check both arms.
      final env = _elabAndCheck('''
$_natAndPlus
val plus_refl_stuck : (m: Nat) -> (n: Nat) ->
    Eq Nat (plus m n) (plus m n) =
  (m: Nat) => (n: Nat) =>
    match n returning Eq Nat (plus m n) (plus m n) {
      case zero => refl (plus m zero)
      case succ k => refl (plus m (succ k))
    }
''');
      expect(_binding(env, 'plus_refl_stuck').name, 'plus_refl_stuck');
    });
  });
}
