import 'dart:io';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';

void main() {
  final sw = Stopwatch();
  const warmup = 5, n = 10;

  // Profile each declaration kind
  print('=== Parse cost per declaration kind (JIT, best of $n) ===');
  print('Kind                  |   us | Example');
  print('----------------------|------|--------');

  final decls = <(String, String)>[
    ('val', 'val x : Type = Type'),
    ('val w/ body', 'val x : Nat = succ (succ (succ zero))'),
    ('type alias', 'type NatC = (A: Type) -> (A -> A) -> A -> A'),
    ('fun simple', 'fun id (x: Type) : Type = x'),
    (
      'fun w/ match',
      'fun plus (m: Nat, n: Nat) : Nat = match m { case zero => n case succ k => succ (plus k n) }',
    ),
    ('data simple', 'data Nat : Type { zero : Nat; succ : Nat -> Nat; }'),
    (
      'data indexed',
      'data Vec (A : Type) : Nat -> Type { vnil : Vec A zero; vcons : (n: Nat) -> A -> Vec A n -> Vec A (succ n); }',
    ),
    (
      'val w/ proof',
      'val plus_zero : (n: Nat) -> Eq[Nat] (plus n zero) n = Nat.ind ((k: Nat) => Eq[Nat] (plus k zero) k) (refl zero) ((m: Nat) => (ih: Eq[Nat] (plus m zero) m) => cong ((k: Nat) => succ k) ih)',
    ),
  ];

  for (final (name, src) in decls) {
    for (var i = 0; i < warmup; i++) parseDecl(src);
    USList times = USList();
    for (var i = 0; i < n; i++) {
      sw.reset();
      sw.start();
      parseDecl(src);
      sw.stop();
      times.add(sw.elapsedMicroseconds);
    }
    final avg = times.avg();
    final brief =
        src.length > 40 ? '${src.substring(0, 40)}...' : src.padRight(40);
    print('${name.padRight(21)} | ${avg.toString().padLeft(4)} | $brief');
  }

  // Profile: parse-only throughput on real files (JIT and AOT comparison)
  print('');
  print('=== Parse-only throughput (best of 5 warm runs) ===');
  print('File           | Size    | JIT best | JIT avg  | Rate');
  print('---------------|---------|----------|----------|------');

  final files = [
    'lib/stdlib/nat.doxa',
    'lib/stdlib/bool.doxa',
    'lib/stdlib/option.doxa',
    'lib/stdlib/vec.doxa',
    'lib/stdlib/list.doxa',
    'lib/stdlib/eq.doxa',
    'lib/stdlib/proofs.doxa',
    'example/proofs.doxa',
  ];

  for (final path in files) {
    if (!File(path).existsSync()) continue;
    final src = File(path).readAsStringSync();
    final name = path.split('/').last.replaceAll('.doxa', '');

    for (var i = 0; i < warmup; i++) parseProgram(src);

    USList times = USList();
    for (var i = 0; i < 5; i++) {
      sw.reset();
      sw.start();
      parseProgram(src);
      sw.stop();
      times.add(sw.elapsedMicroseconds);
    }
    final best = times.min();
    final avg = times.avg();
    final sizeStr =
        src.length >= 1024
            ? '${(src.length / 1024).toStringAsFixed(1)} KB'
            : '${src.length} B';
    final rate = (src.length / (best / 1000000) / 1024 / 1024).toStringAsFixed(
      1,
    );
    print(
      '${name.padRight(15)} | ${sizeStr.padLeft(7)} | ${best.toString().padLeft(8)} | ${avg.toString().padLeft(8)} | ${rate.padLeft(5)} MB/s',
    );
  }

  // Profile expr-only (no program wrapper) to see decl-list overhead
  print('');
  print('=== parseExpr vs parseDecl overhead (best of 5) ===');
  final exprs = [
    'Type',
    'Type 0',
    'x',
    '(x: Type) => x',
    '(x: Type) -> Type',
    'f x y',
    'Nat',
    'Prop',
  ];
  print('Expr            | parseExpr | parseDecl');
  print('----------------|-----------|-----------');
  for (final e in exprs) {
    for (var i = 0; i < 5; i++) {
      parseExpr(e);
      parseDecl('val _ : Type = $e');
    }
    sw.reset();
    sw.start();
    parseExpr(e);
    sw.stop();
    final exprUs = sw.elapsedMicroseconds;
    sw.reset();
    sw.start();
    parseDecl('val _ : Type = $e');
    sw.stop();
    final declUs = sw.elapsedMicroseconds;
    print(
      '${e.padRight(16)} | ${exprUs.toString().padLeft(9)} | ${declUs.toString().padLeft(9)}',
    );
  }
}

class USList {
  final List<int> data = [];
  void add(int v) {
    data.add(v);
  }

  int min() => data.reduce((a, b) => a < b ? a : b);
  int avg() => data.reduce((a, b) => a + b) ~/ data.length;
}
