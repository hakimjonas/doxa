/// Doxa benchmarking harness.
///
/// Measures checker throughput on real and synthetic workloads, reporting
/// parse time, elaboration time, check time, and full-pipeline time.
/// Supports AOT, JIT, and WASM runtimes. Outputs tables suitable for
/// `docs/BENCHMARKS.md`.
///
/// Usage:
///   dart run tool/benchmark.dart                        # all workloads
///   dart run tool/benchmark.dart --only=nat              # filter by name
///   dart run tool/benchmark.dart --repeat=5 --warmup=2   # repetition + warmup
///   dart run tool/benchmark.dart --output=json           # machine-readable
///   dart run tool/benchmark.dart --depth=1000,10000      # Church nat depth ladder
///
/// After each kernel-hardening phase, re-run this harness to update
/// `docs/BENCHMARKS.md` with the new column.

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';

// ---------------------------------------------------------------------------
// Prelude
// ---------------------------------------------------------------------------

const String _preludeSource = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}
''';

// We can't import the cached prelude from web_check.dart (it's in
// doxa_tooling, not doxa), so we inline a local prelude load.
({List<TopBinding> bindings, List<DataDecl> dataDecls})? _preludeCache;

({List<TopBinding> bindings, List<DataDecl> dataDecls}) _loadPrelude() {
  final cached = _preludeCache;
  if (cached != null) return cached;
  final r = parseProgram(_preludeSource);
  final prog = switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() =>
      throw StateError('prelude parse failed'),
  };
  var bindings = const <TopBinding>[];
  var dataDecls = const <DataDecl>[];
  for (final decl in prog.decls) {
    final produced = elabDecl(TopEnv(bindings, dataDecls), decl);
    final runningData = [...dataDecls, ...produced.dataDecls];
    final finalized = checkDeclResult(TopEnv(bindings, runningData), produced);
    bindings = [...bindings, ...finalized];
    dataDecls = runningData;
  }
  final result = (bindings: bindings, dataDecls: dataDecls);
  _preludeCache = result;
  return result;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

void main(List<String> args) {
  var filter = '';
  var repeat = 3;
  var warmup = 1;
  var output = 'table'; // table | json
  final depths = <int>[100, 500]; // depth 1000+ overflows the elaborator stack (known)
  final workloads = <Workload>[];

  for (final a in args) {
    if (a.startsWith('--only=')) {
      filter = a.substring('--only='.length);
    } else if (a.startsWith('--repeat=')) {
      repeat = int.tryParse(a.substring('--repeat='.length)) ?? repeat;
    } else if (a.startsWith('--warmup=')) {
      warmup = int.tryParse(a.substring('--warmup='.length)) ?? warmup;
    } else if (a.startsWith('--output=')) {
      output = a.substring('--output='.length);
    } else if (a.startsWith('--depth=')) {
      depths.clear();
      depths.addAll(
        a.substring('--depth='.length).split(',').map(int.parse),
      );
    } else if (!a.startsWith('--')) {
      depths.clear();
      depths.addAll(args.where((a) => !a.startsWith('--')).map(int.parse));
      break;
    }
  }

  // ---- Real workloads ----
  final stdlibDir = Directory('lib/stdlib');
  if (stdlibDir.existsSync()) {
    for (final f in stdlibDir.listSync().whereType<File>().toList()..sort(
      (a, b) => a.path.compareTo(b.path),
    )) {
      if (!f.path.endsWith('.doxa')) continue;
      // The prelude is already seeded — re-checking it duplicates Eq.
      if (f.path.endsWith('prelude.doxa')) continue;
      final name = f.uri.pathSegments.last.replaceAll('.doxa', '');
      workloads.add(Workload('stdlib/$name', _read(f), 'stdlib file'));
    }
  } else {
    // Sub-package layout — try relative to doxa_tooling.
    final alt = Directory('../lib/stdlib');
    if (alt.existsSync()) {
      for (final f in alt.listSync().whereType<File>().toList()..sort(
        (a, b) => a.path.compareTo(b.path),
      )) {
        if (!f.path.endsWith('.doxa')) continue;
        final name = f.uri.pathSegments.last.replaceAll('.doxa', '');
        workloads.add(Workload('stdlib/$name', _readFull(f.path), 'stdlib file'));
      }
    }
  }

  // example/proofs.doxa
  final example = File('example/proofs.doxa');
  if (example.existsSync()) {
    workloads.add(Workload('example/proofs', _read(example), 'example file'));
  }

  // ---- Scaled stdlib (synthetic) ----
  // Each stdlib/proofs.doxa file redefines Nat/Bool/List/etc.
  // Duplicating the content produces DuplicateDeclaration errors.
  // Scaling tests would need a deduplicated version of the file.
  // Deferred until a module/import system allows self-contained units.

  // ---- Church-encoded Nat depth ladder ----
  // Build a file that computes 2^2^2... (exponential) at varying depth
  // to stress β-reduction.
  //
  // The file defines Church naturals and computes `two(two)(two)` etc.
  // which produces a β-reduction chain proportional to the depth.
  for (final depth in depths) {
    final program = _churchDepthProgram(depth);
    workloads.add(Workload('church_depth_$depth', program, 'β-reduction stress'));
  }

  // ---- Filter ----
  if (filter.isNotEmpty) {
    workloads.removeWhere((w) =>
        !w.name.toLowerCase().contains(filter.toLowerCase()));
  }

  if (workloads.isEmpty) {
    stderr.writeln('no workloads matched (filter="$filter")');
    exit(1);
  }

  // ---- Warmup ----
  for (var i = 0; i < warmup; i++) {
    for (final w in workloads) {
      _time(w, silent: true);
    }
  }

  // ---- Measure ----
  final results = <BenchResult>[];
  for (final w in workloads) {
    var bestTotal = double.infinity;
    var best = const BenchTiming(0, 0, 0);

    for (var i = 0; i < repeat; i++) {
      final (timing, total) = _time(w);
      if (total < bestTotal) {
        bestTotal = total;
        best = timing;
      }
    }

    results.add(BenchResult(w, best, bestTotal));
  }

  // ---- Output ----
  switch (output) {
    case 'json':
      stdout.writeln(jsonEncode([
        for (final r in results) r.toJson(),
      ]));
    case 'table':
      _printTable(results);
  }
}

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

final class Workload {
  final String name;
  final String source;
  final String category;

  const Workload(this.name, this.source, this.category);
}

final class BenchTiming {
  final int parseUs;
  final int elabUs;
  final int checkUs;

  const BenchTiming(this.parseUs, this.elabUs, this.checkUs);

  int get totalUs => parseUs + elabUs + checkUs;
  double get totalMs => totalUs / 1000.0;
}

final class BenchResult {
  final Workload workload;
  final BenchTiming timing;
  final double totalMs;

  const BenchResult(this.workload, this.timing, this.totalMs);

  Map<String, dynamic> toJson() => {
    'name': workload.name,
    'category': workload.category,
    'source_bytes': workload.source.length,
    'parse_us': timing.parseUs,
    'elab_us': timing.elabUs,
    'check_us': timing.checkUs,
    'total_us': timing.totalUs,
    'total_ms': timing.totalMs,
  };
}

// ---------------------------------------------------------------------------
// Timer
// ---------------------------------------------------------------------------

(BenchTiming, double) _time(Workload w, {bool silent = false}) {
  final sw = Stopwatch();

  // Parse
  sw.start();
  final parseResult = parseProgram(w.source);
  final program = switch (parseResult) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() => null,
  };
  sw.stop();
  final parseUs = sw.elapsedMicroseconds;
  if (program == null) {
    final srcPreview = w.source.length > 100
        ? '${w.source.substring(0, 100)}...'
        : w.source;
    if (!silent) stderr.writeln('  ${w.name}: PARSE ERROR. source(len=${w.source.length}): $srcPreview');
    return (const BenchTiming(-1, -1, -1), -1.0);
  }

  // Elaborate + check (declaration by declaration)
  sw.reset();
  sw.start();

  // Seed the prelude so user declarations can reference Eq/refl.
  final prelude = _loadPrelude();
  var bindings = prelude.bindings;
  var dataDecls = prelude.dataDecls;

  for (final decl in program.decls) {
    try {
      final produced = elabDecl(TopEnv(bindings, dataDecls), decl);
      final runningData = [...dataDecls, ...produced.dataDecls];
      final finalized = checkDeclResult(TopEnv(bindings, runningData), produced);
      bindings = [...bindings, ...finalized];
      dataDecls = runningData;
    } on StackOverflowError {
      if (!silent) stderr.writeln('  ${w.name}: STACK OVERFLOW (elaborator recursion, known limitation)');
      return (const BenchTiming(-3, -3, -3), -3.0);
    } on Exception catch (e) {
      if (!silent) stderr.writeln('  ${w.name}: CHECK ERROR: $e');
      return (const BenchTiming(-2, -2, -2), -2.0);
    }
  }
  final elabPlusCheckUs = sw.elapsedMicroseconds;
  sw.stop();
  // elab and check aren't separable without instrumenting elab.dart,
  // so we report parse and elab+check as the primary breakdown.
  final totalUs = parseUs + elabPlusCheckUs;
  final totalMs = totalUs / 1000.0;

  if (!silent) {
    stderr.writeln(
      '  ${w.name}  parse=${parseUs}us  elab+check=${elabPlusCheckUs}us  total=${totalMs.toStringAsFixed(2)}ms',
    );
  }

  return (BenchTiming(parseUs, elabPlusCheckUs, 0), totalMs);
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

void _printTable(List<BenchResult> results) {
  // Group by category
  final byCategory = <String, List<BenchResult>>{};
  for (final r in results) {
    byCategory.putIfAbsent(r.workload.category, () => []).add(r);
  }

  stdout.writeln('| Workload | Source | Parse (us) | Elab+Check (us) | Total (ms) |');
  stdout.writeln('|----------|--------|------------|------------------|------------|');

  for (final entry in byCategory.entries) {
    final cat = entry.key;

    for (final r in entry.value) {
      final bytes = r.workload.source.length;
      final srcCol = bytes >= 1024
          ? '${(bytes / 1024).toStringAsFixed(1)} KB'
          : '$bytes B';
      stdout.writeln(
        '| ${r.workload.name} | $srcCol | ${r.timing.parseUs} | ${r.timing.elabUs} | ${r.totalMs.toStringAsFixed(3)} |',
      );
    }
  }

  // Summary
  final allOk = results.where((r) => r.totalMs >= 0);
  if (allOk.isNotEmpty) {
    final avgMs = allOk.map((r) => r.totalMs).reduce((a, b) => a + b) / allOk.length;
    final totalBytes = results.map((r) => r.workload.source.length).reduce((a, b) => a + b);
    stdout.writeln();
    stdout.writeln('| **Total (all workloads)** | ${(totalBytes / 1024).toStringAsFixed(1)} KB | — | — | **${avgMs.toStringAsFixed(2)}** |');
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a Doxa source program that stress-tests β-reduction at [depth].
/// Declares a `Nat` type and identity function, then applies identity
/// to `zero` `depth` times: `id(id(id(...(zero)...)))`.
String _churchDepthProgram(int depth) {
  final buf = StringBuffer();
  buf.writeln('// β-reduction stress test: $depth identity applications');
  buf.writeln('data Nat : Type { zero : Nat; succ : Nat -> Nat; }');
  buf.writeln('val id : Nat -> Nat = (x: Nat) => x');
  buf.write('val chain : Nat = ');
  for (var i = 0; i < depth; i++) {
    buf.write('id(');
  }
  buf.write('zero');
  for (var i = 0; i < depth; i++) {
    buf.write(')');
  }
  return buf.toString();
}

String _read(File f) => f.readAsStringSync();

String _readFull(String path) => File(path).readAsStringSync();

String? _findFile(List<String> candidates) {
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
