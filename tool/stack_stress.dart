// Linear-time + stack-safety regression harness (on-demand).
//
// Runs one representative workload per kernel path at escalating depths
// and reports either the elapsed time or the first error. One pass
// covers: eval of deep TApp chains, β-reduction of deep Church-nat
// applications, nested-lambda eval, quote of deep VLam, conv of deep
// Pi, nested-let normalization, check/infer on deep Pi+Lam, and the
// Phase-10 deep-args TData fold.
//
// This harness is the expected enforcement point for the SPEC §4.5
// linear-time invariant. A healthy run shows every workload landing
// in the 100-300 ms band at 1,000,000 depth. Run it before any PR
// that changes the `lib/src/eval.dart` driver or the value/term
// representations it consumes. Use `--only=<substr>` to filter
// workloads, and trailing integers to override the depth ladder.
//
// See README "Performance invariants" for the full invocation
// contract, and `test/check_test.dart`'s 100,000-depth pin for the
// unit-suite counterpart (focused on the historically fragile
// `infer TLam` path).

import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';

const Ctx _emptyCtx = CNil();

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  throw StateError('parse failed: $r');
}

// Env with Nat registered (and auto-emitted Nat.rec, Nat.ind bindings).
// Built once, shared across workloads that need a recursor.
final Env _natEnv = _buildNatEnv();

Env _buildNatEnv() {
  final env = elabProgram(
    _parse('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
'''),
  );
  return env.toCtx().env;
}

typedef Workload = void Function(int depth);

// Build a 'depth'-deep TApp chain: ((f Type) Type) Type ..., where f is
// a neutral bound at index 0 in the evaluation env. Mirrors the eval_test
// 'deep TApp chain' workload.
Term appChain(int depth) {
  Term t = const TBound(0);
  for (var i = 0; i < depth; i++) {
    t = TApp(t, const TType(0));
  }
  return t;
}

Env appChainEnv() => const ENil().extend(const VNeutral(NVar(0)));

// λx1. λx2. ... λxN. Type, depth-deep.
Term nestedLams(int depth) {
  Term t = const TType(0);
  for (var i = 0; i < depth; i++) {
    t = TLam(const TType(0), t);
  }
  return t;
}

// (x0: T) -> (x1: T) -> ... -> (xN: T) -> Type, depth-deep.
Term nestedPis(int depth) {
  Term t = const TType(0);
  for (var i = 0; i < depth; i++) {
    t = TPi(const TType(0), t);
  }
  return t;
}

// let x0 = Type in let x1 = Type in ... Type, depth-deep.
Term nestedLets(int depth) {
  Term t = const TType(0);
  for (var i = 0; i < depth; i++) {
    t = TLet(const TType(1), const TType(0), t);
  }
  return t;
}

// depth-deep β-reduction chain: ((λx.x) ((λx.x) ((λx.x) ... Type))).
// Mirrors the eval_test 'deep β-reduction' workload.
Term deepBetaReduce(int depth) {
  const idLam = TLam(TType(0), TBound(0));
  Term t = const TType(0);
  for (var i = 0; i < depth; i++) {
    t = TApp(idLam, t);
  }
  return t;
}

// Phase-10 deep-args TData fold.
Term deepData(int depth) {
  final args = List<Term>.generate(depth, (_) => const TType(0));
  return TData('Vec', args);
}

// Build a depth-nested Term-level chain of stuck matches. Each
// level's arm body is another match stuck on the same (neutral)
// scrutinee. Eval produces a chain of VMatch values; quoting must
// walk the chain without growing the Dart stack per level.
//
// Phase 12 interlude regression pin: before the driver-native arm
// iteration landed, quote(VMatch) re-entered _drive via eval/quote
// per arm, which recursed into nested VMatch values. Depth was
// bounded by Dart stack; plus_comm-style proofs blew at ~5k.
Term nestedMatchTerm(int depth) {
  // Innermost body: just TType(0). At each wrap, build a match
  // with a single wildcard arm whose body is the prior term.
  // Scrutinee is TBound(0) which we provide as a fresh neutral in
  // the eval env. Every match is stuck on the same neutral.
  Term t = const TType(0);
  for (var i = 0; i < depth; i++) {
    t = TMatch(const TBound(0), null, [
      TMatchCase('', 0, t, const <String?>[]),
    ]);
  }
  return t;
}

Env nestedMatchEnv() => const ENil().extend(const VNeutral(NVar(0)));

// Phase 12 interlude regression pin: recursor ι-reduction over a
// deep canonical scrutinee. Before the driver-native fix, each
// recursive IH was computed via an inlined `apply(VRec, subArg)`
// call that re-entered _drive. For a succ-tower of depth D, the
// ι-reduction cascade produced D nested Dart frames.
//
// We exercise this by building a TLet env binding `Nat.rec` +
// a succ-tower + invoking the recursor. Programmatic approach:
// build the TRec application term with args (motive, zeroCase,
// succCase, succChain), evaluate under an env holding a registered
// Nat DataDecl, and measure.
Term succChainTerm(int depth) {
  Term t = const TConstr('Nat', 'zero', <Term>[]);
  for (var i = 0; i < depth; i++) {
    t = TConstr('Nat', 'succ', <Term>[t]);
  }
  return t;
}

Term natRecOverSuccChain(int depth) {
  // Nat.rec ((_: Nat) => Nat) zero ((_: Nat) => (rec: Nat) => succ rec) chain
  const motive = TLam(TData('Nat', <Term>[]), TData('Nat', <Term>[]));
  const zeroCase = TConstr('Nat', 'zero', <Term>[]);
  const succCase = TLam(
    TData('Nat', <Term>[]),
    TLam(TData('Nat', <Term>[]), TConstr('Nat', 'succ', <Term>[TBound(0)])),
  );
  return TApp(
    const TApp(TApp(TApp(TRec('Nat'), motive), zeroCase), succCase),
    succChainTerm(depth),
  );
}

// ---------------------------------------------------------------------------
// Runner: try a workload at depth N, catch StackOverflow and other errors.
// ---------------------------------------------------------------------------

enum Outcome { ok, stackOverflow, otherError }

class Result {
  final Outcome outcome;
  final Duration elapsed;
  final String? detail;
  const Result(this.outcome, this.elapsed, [this.detail]);
}

Result run(String name, int depth, void Function() body) {
  final sw = Stopwatch()..start();
  try {
    body();
    sw.stop();
    return Result(Outcome.ok, sw.elapsed);
  } on StackOverflowError catch (e) {
    sw.stop();
    return Result(Outcome.stackOverflow, sw.elapsed, '$e');
  } on Error catch (e) {
    sw.stop();
    return Result(Outcome.otherError, sw.elapsed, '$e');
  } catch (e) {
    sw.stop();
    return Result(Outcome.otherError, sw.elapsed, '$e');
  }
}

final Map<String, void Function(int)> workloads = {
  'eval TApp chain': (d) => eval(appChain(d), appChainEnv()),
  'eval nested lambdas': (d) => eval(nestedLams(d), const ENil()),
  'eval nested Pis': (d) => eval(nestedPis(d), const ENil()),
  'eval nested lets': (d) => eval(nestedLets(d), const ENil()),
  'eval deep β-reduction': (d) => eval(deepBetaReduce(d), const ENil()),
  'quote deep VLam': (d) {
    final v = eval(nestedLams(d), const ENil());
    quote(0, v);
  },
  'eval deep match chain': (d) => eval(nestedMatchTerm(d), nestedMatchEnv()),
  'quote deep VMatch chain': (d) {
    final v = eval(nestedMatchTerm(d), nestedMatchEnv());
    quote(1, v);
  },
  'eval deep Nat.rec ι-reduce': (d) => eval(natRecOverSuccChain(d), _natEnv),
  'conv deep Pi × Pi': (d) {
    final v = eval(nestedPis(d), const ENil());
    conv(0, v, v);
  },
  'infer deep Pi': (d) => infer(_emptyCtx, nestedPis(d)),
  'infer deep Lam': (d) => infer(_emptyCtx, nestedLams(d)),
  'check deep Pi ≤ Type 1': (d) {
    final t = nestedPis(d);
    check(_emptyCtx, t, const VType(1));
  },
  'eval deep TData': (d) => eval(deepData(d), const ENil()),
  'nf deep let': (d) => nf(nestedLets(d)),
};

void main(List<String> argv) {
  // Args: integers become depths; --only=substring filters workloads
  // (matched case-insensitively against the workload name).
  final depths = <int>[];
  final filters = <String>[];
  for (final a in argv) {
    if (a.startsWith('--only=')) {
      filters.add(a.substring('--only='.length).toLowerCase());
    } else {
      depths.add(int.parse(a));
    }
  }
  if (depths.isEmpty) {
    depths.addAll(const [10000, 50000, 100000, 250000, 500000, 1000000]);
  }
  final selected =
      filters.isEmpty
          ? workloads
          : {
            for (final e in workloads.entries)
              if (filters.any((f) => e.key.toLowerCase().contains(f)))
                e.key: e.value,
          };
  if (selected.isEmpty) {
    // ignore: avoid_print
    print(
      'no workloads matched filters: ${filters.join(', ')}\n'
      'available: ${workloads.keys.join(', ')}',
    );
    return;
  }
  // Longest workload name for alignment.
  final w = selected.keys.map((k) => k.length).reduce((a, b) => a > b ? a : b);

  for (final entry in selected.entries) {
    final name = entry.key;
    final fn = entry.value;
    // ignore: avoid_print
    print('\n=== ${name.padRight(w)} ===');
    for (final d in depths) {
      final r = run(name, d, () => fn(d));
      final tag = switch (r.outcome) {
        Outcome.ok => 'OK',
        Outcome.stackOverflow => 'STACK OVERFLOW',
        Outcome.otherError => 'ERROR',
      };
      final line =
          '  ${d.toString().padLeft(8)}  '
          '${tag.padRight(16)}'
          '${r.elapsed.inMilliseconds.toString().padLeft(6)} ms';
      // ignore: avoid_print
      print(line);
      if (r.outcome != Outcome.ok) {
        // ignore: avoid_print
        print('    ${r.detail}');
        break; // stop escalating on this workload.
      }
    }
  }
}
