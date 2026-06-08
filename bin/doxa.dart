/// Doxa CLI: `doxa check FILE`.
///
/// Parses a Doxa source file, elaborates each top-level declaration,
/// and type-checks each declaration's body against its declared type.
/// Reports errors via the diagnostic formatter. Exits with status 0
/// on success and 1 on any error.
library;

import 'dart:io';

import 'package:doxa/src/check.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/report.dart';
import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';

void main(List<String> args) {
  if (args.length != 2 || args[0] != 'check') {
    _usage();
    exit(2);
  }
  final path = args[1];
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('doxa: file not found: $path');
    exit(2);
  }
  final text = file.readAsStringSync();
  final source = SourceFile(filename: path, text: text);
  exit(checkSource(source));
}

void _usage() {
  stderr.writeln('Usage: doxa check FILE');
  stderr.writeln('');
  stderr.writeln('  Parse, elaborate, and type-check a Doxa source file.');
  stderr.writeln('  Exits 0 on success, 1 on type or parse errors, 2 on');
  stderr.writeln('  usage errors.');
}

/// The Doxa prelude, ambient declarations loaded before user code.
///
/// Holds `Eq` (SPEC §8.9). Users never import the prelude; its names
/// are in scope ambiently, matching Lean 4's prelude discipline.
///
/// The prelude source text is embedded as a const string so the
/// CLI binary is self-contained (no runtime file resolution for
/// the bootstrap). The canonical source lives at
/// `lib/stdlib/prelude.doxa`; keep the two in sync.
const String _preludeSource = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}
''';

/// Elaborated prelude, cached after the first call. The prelude is a
/// fixed program; there's no reason to re-elaborate it per user file.
({List<TopBinding> bindings, List<DataDecl> dataDecls})? _preludeCache;

({List<TopBinding> bindings, List<DataDecl> dataDecls}) _loadPrelude() {
  final cached = _preludeCache;
  if (cached != null) return cached;
  final r = parseProgram(_preludeSource);
  final prog = switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    _ =>
      throw StateError(
        'prelude failed to parse; this is a kernel bug, '
        'lib/stdlib/prelude.doxa must stay in sync',
      ),
  };
  // Elaborate + check decl-by-decl with the same discipline as
  // checkSource. A broken prelude throws here and fails fast with
  // a kernel-invariant violation, the prelude is a fixed trusted
  // source, so any failure is our bug, not the user's.
  var bindings = const <TopBinding>[];
  var dataDecls = const <DataDecl>[];
  for (final decl in prog.decls) {
    final env = TopEnv(bindings, dataDecls);
    final produced = elabDecl(env, decl);
    final runningData = [...dataDecls, ...produced.dataDecls];
    final runningEnv = TopEnv(bindings, runningData);
    final finalized = checkDeclResult(runningEnv, produced);
    bindings = [...bindings, ...finalized];
    dataDecls = runningData;
  }
  final result = (bindings: bindings, dataDecls: dataDecls);
  _preludeCache = result;
  return result;
}

/// Type-check [source] and print diagnostics.
///
/// Returns the exit code: 0 on success, 1 on parse/elab/check errors.
/// Exposed as a library function so tests can drive the whole pipeline
/// without spawning a subprocess.
int checkSource(SourceFile source, {IOSink? out, IOSink? err}) {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;

  // Parse.
  final parseResult = parseProgram(source.text);
  final program = switch (parseResult) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() => null,
  };
  if (program == null) {
    stderrSink.write(
      reportParseFailure(source, parseResult as Failure<ParseError, Object?>),
    );
    return 1;
  }

  // Seed bindings + dataDecls from the prelude so user code can
  // reference `Eq` and any other ambient names without redeclaring
  // them. The prelude has already been type-checked in _loadPrelude;
  // we trust its contents at this point.
  final prelude = _loadPrelude();
  final preludeDeclCount = prelude.bindings.length + prelude.dataDecls.length;
  var bindings = prelude.bindings;
  var dataDecls = prelude.dataDecls;
  for (final decl in program.decls) {
    final env = TopEnv(bindings, dataDecls);
    try {
      final produced = elabDecl(env, decl);
      // For recursive/mutual `fun` paths, `checkDeclResult` pre-scopes
      // all group members in Ctx with self-neutral values before
      // checking any body, the classical CIC fixpoint discipline
      // (SPEC §8.6).
      final runningData = [...dataDecls, ...produced.dataDecls];
      final runningEnv = TopEnv(bindings, runningData);
      final finalized = checkDeclResult(runningEnv, produced);
      bindings = [...bindings, ...finalized];
      dataDecls = runningData;
    } on DoxaCheckError catch (e) {
      // Prefer a more precise span if the error carries one: a type
      // mismatch caught during elaboration carries the offending
      // sub-expression's span, and ScrutineeTypeMismatchesArm carries the
      // arm span. Fall back to the enclosing decl's span otherwise.
      final reportSpan = switch (e) {
        TypeMismatch(:final span) when span != null => span,
        ScrutineeTypeMismatchesArm(:final armSpan) when armSpan != null =>
          armSpan,
        _ => decl.span,
      };
      stderrSink.write(reportCheckError(source, e, reportSpan));
      return 1;
    } on ElabError catch (e) {
      stderrSink.write(reportElabError(source, e));
      return 1;
    }
  }

  // Report only the USER decl count (subtract the prelude). An empty
  // user file with a working prelude reports "OK: 0 declarations
  // checked" rather than leaking the prelude count into the output.
  final n = bindings.length + dataDecls.length - preludeDeclCount;
  stdoutSink.writeln(
    'OK: $n ${n == 1 ? "declaration" : "declarations"} checked',
  );
  return 0;
}
