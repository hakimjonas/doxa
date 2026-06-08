/// Pure `String -> String` driver for the full Doxa pipeline.
///
/// This is the I/O-free core used by the WasmGC browser entry
/// (`web/doxa_check.dart`) and by native harnesses/tests that want to
/// exercise the whole parse -> elaborate -> check pipeline without
/// spawning a subprocess or wiring up [IOSink]s.
///
/// It mirrors `bin/doxa.dart`'s `checkSource`, but instead of writing
/// diagnostics to sinks and returning an exit code, it returns the
/// formatted result string directly:
///   * on success: `OK: N declarations checked`
///   * on failure: the formatted parse / elab / check diagnostic.
///
/// The prelude is embedded as a const string so the artifact is
/// self-contained (no runtime file resolution). The canonical source
/// lives at `lib/stdlib/prelude.doxa`; keep the two in sync.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/report.dart';
import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';

const String _preludeSource = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}
''';

/// Elaborated prelude, cached after the first call. The prelude is a
/// fixed program; there's no reason to re-elaborate it per call.
({List<TopBinding> bindings, List<DataDecl> dataDecls})? _preludeCache;

({List<TopBinding> bindings, List<DataDecl> dataDecls}) _loadPrelude() {
  final cached = _preludeCache;
  if (cached != null) return cached;
  final r = parseProgram(_preludeSource);
  final prog = switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() =>
      throw StateError(
        'prelude failed to parse, this is a kernel bug, '
        'lib/stdlib/prelude.doxa must stay in sync',
      ),
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

/// Run the full parse -> elaborate -> type-check pipeline on [src]
/// and return a human-readable result string.
///
/// [filename] is used only for diagnostic location formatting.
String checkSourceString(String src, {String filename = 'playground.doxa'}) {
  final source = SourceFile(filename: filename, text: src);
  final parseResult = parseProgram(source.text);
  final program = switch (parseResult) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() => null,
  };
  if (program == null) {
    return reportParseFailure(
      source,
      parseResult as Failure<ParseError, Object?>,
    );
  }

  final prelude = _loadPrelude();
  final preludeDeclCount = prelude.bindings.length + prelude.dataDecls.length;
  var bindings = prelude.bindings;
  var dataDecls = prelude.dataDecls;
  for (final decl in program.decls) {
    try {
      final produced = elabDecl(TopEnv(bindings, dataDecls), decl);
      final runningData = [...dataDecls, ...produced.dataDecls];
      final finalized = checkDeclResult(
        TopEnv(bindings, runningData),
        produced,
      );
      bindings = [...bindings, ...finalized];
      dataDecls = runningData;
    } on DoxaCheckError catch (e) {
      final reportSpan = switch (e) {
        // A type mismatch caught during elaboration carries the offending
        // sub-expression's span; prefer it over the enclosing decl so the
        // caret lands on the term, not column 1.
        TypeMismatch(:final span) when span != null => span,
        ScrutineeTypeMismatchesArm(:final armSpan) when armSpan != null =>
          armSpan,
        _ => decl.span,
      };
      return reportCheckError(source, e, reportSpan);
    } on ElabError catch (e) {
      return reportElabError(source, e);
    }
  }

  final n = bindings.length + dataDecls.length - preludeDeclCount;
  return 'OK: $n ${n == 1 ? "declaration" : "declarations"} checked';
}
