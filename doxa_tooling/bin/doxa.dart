/// Doxa CLI: `doxa check [--json] FILE`, `doxa repl`, or `doxa lsp`.
///
/// Parses a Doxa source file, elaborates each top-level declaration,
/// and type-checks each declaration's body against its declared type.
/// Reports errors via the diagnostic formatter. Exits with status 0
/// on success and 1 on any error.
///
/// When `--json` is passed, the output is structured JSON (same exit
/// code discipline).
///
/// The `repl` subcommand starts an interactive read-eval-print loop.
///
/// The `lsp` subcommand starts the Doxa language server over stdio.
library;

import 'dart:io';

import 'package:doxa/src/check.dart';
import 'package:doxa/src/prelude.dart' show loadPrelude, PreludeData;
import 'package:doxa/src/source.dart' show SourceFile, AnsiColor;
import 'package:doxa/src/elab.dart'
    show
        currentImportPath,
        importedPaths,
        elabDecl,
        checkDeclResult,
        ElabError,
        TopEnv,
        TopBinding,
        DataDecl,
        mergeNamespace;
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/report.dart';
import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart' show SProgram, SImportKind;
import 'package:doxa_tooling/src/lsp/handler.dart';
import 'package:doxa_tooling/src/lsp/transport.dart';
import 'package:doxa_tooling/src/repl.dart'
    show ReplSession, ReplResult, ReplDeclResult, ReplExprResult, ReplError, ReplMeta;
import 'package:doxa_tooling/src/web_check.dart';
import 'package:rumil/rumil.dart';

void main(List<String> args) {
  if (args.isNotEmpty && args[0] == 'lsp') {
    _runLsp();
    return;
  }
  if (args.isNotEmpty && args[0] == 'repl') {
    _runRepl();
    return;
  }

  var jsonFlag = false;
  var watchFlag = false;
  String path;

  if (args.length >= 3 && args[0] == 'check' && args[1] == '--json') {
    jsonFlag = true;
    path = args[2];
    watchFlag = args.length >= 4 && args[3] == '--watch';
  } else if (args.length >= 2 && args[0] == 'check') {
    path = args[1];
    watchFlag = args.length >= 3 && args[2] == '--watch';
  } else {
    _usage();
    exit(2);
  }

  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('doxa: file not found: $path');
    exit(2);
  }

  if (jsonFlag) {
    if (watchFlag) {
      _watch(file, json: true);
      return;
    }
    final text = file.readAsStringSync();
    stdout.writeln(checkSourceJson(text, filename: path));
    exit(0);
  }

  if (watchFlag) {
    _watch(file);
    return;
  }

  final text = file.readAsStringSync();
  final source = SourceFile(filename: path, text: text);
  exit(checkSource(source));
}

void _usage() {
  stderr.writeln('Usage: doxa check [--json] [--watch] FILE');
  stderr.writeln('');
  stderr.writeln('  Parse, elaborate, and type-check a Doxa source file.');
  stderr.writeln('  Exits 0 on success, 1 on type or parse errors, 2 on');
  stderr.writeln('  usage errors.');
  stderr.writeln('');
  stderr.writeln(
    '  --json    Output structured JSON instead of human-readable text.',
  );
  stderr.writeln('');
  stderr.writeln(
    '  --watch   Watch the file for changes and re-check on save.',
  );
  stderr.writeln('');
  stderr.writeln('  doxa repl');
  stderr.writeln('');
  stderr.writeln('  Start an interactive REPL session.');
  stderr.writeln('');
  stderr.writeln('  doxa lsp');
  stderr.writeln('');
  stderr.writeln('  Start the LSP language server over stdio.');
}

/// Watch [file] for changes and re-check on every modification.
/// Prints a clear-screen marker and the new result each time.
void _watch(File file, {bool json = false}) {
  stderr.writeln('Watching ${file.path} for changes...');
  stderr.writeln('');

  // Initial check.
  _checkFile(file, json: json);

  // Watch for modifications. Dart's File.watch() uses inotify/FSEvents
  // under the hood and fires on write + close (i.e., editor save).
  final watcher = file.watch();
  watcher.listen((event) {
    if (event.type == FileSystemEvent.modify) {
      _checkFile(file, json: json);
    }
  });

  // Keep the process alive.
  stdin.listen((_) {}); // drain stdin, don't exit on EOF
}

/// Re-read [file] and run the check pipeline, printing the result.
void _checkFile(File file, {bool json = false}) {
  // Read current content. If the file was deleted (rare race), skip.
  if (!file.existsSync()) {
    stderr.writeln('[file deleted]');
    return;
  }
  final text = file.readAsStringSync();
  final source = SourceFile(filename: file.path, text: text);

  // Clear screen for a clean re-display.
  stdout.write('\x1b[2J\x1b[H');
  stdout.writeln('=== ${file.path} ===');
  stdout.writeln('');

  if (json) {
    stdout.writeln(checkSourceJson(text, filename: file.path));
  } else {
    final code = checkSource(source);
    if (code == 0) {
      stdout.writeln('OK');
    }
  }
  stdout.writeln('');
}

/// Run the LSP server.
///
/// Reads LSP messages from stdin and sends responses to stdout.
/// Exits cleanly on `shutdown`/`exit`.
void _runLsp() {
  final handler = LspHandler();
  while (true) {
    final message = readLspMessage();
    if (message == null) break; // EOF
    final response = handler.handle(message);
    if (response != null) {
      final method = message['method'] as String?;
      if (method == 'exit') break;
      sendLspMessage(response);
    }
  }
}

/// Run the REPL.
///
/// In piped mode (stdin is not a terminal), reads all lines and processes
/// each one, printing only results. In interactive mode, shows a prompt
/// and banner.
void _runRepl() {
  final prelude = loadPrelude();
  var session = ReplSession(
    bindings: prelude.bindings,
    dataDecls: prelude.dataDecls,
    namespaceBindings: prelude.namespaceBindings,
  );
  final isInteractive = stdin.hasTerminal;

  if (isInteractive) {
    stderr.writeln('Doxa REPL');
    stderr.writeln('Type :help  for help, :quit to exit.');
    stderr.writeln('');
  }

  while (true) {
    if (isInteractive) {
      stderr.write('> ');
    }

    final line = stdin.readLineSync();
    if (line == null) break; // EOF

    // Interactive commands.
    final trimmed = line.trim();
    if (trimmed == ':quit') break;

    final (result, nextSession) = session.processInput(trimmed);
    session = nextSession;
    if (result is ReplExprResult) {
      stdout.writeln(': ${result.type}');
      stdout.writeln('= ${result.normalForm}');
    } else if (result is ReplDeclResult) {
      stdout.writeln('${result.name} : ${result.type}');
    } else if (result is ReplMeta) {
      stdout.writeln(result.text);
    } else if (result is ReplError) {
      if (result.message.isNotEmpty) {
        stderr.writeln(result.message);
      }
    }
  }
}

/// Type-check [source] and print diagnostics.
///
/// Returns the exit code: 0 on success, 1 on parse/elab/check errors.
/// Exposed as a library function so tests can drive the whole pipeline
/// without spawning a subprocess.
int checkSource(SourceFile source, {IOSink? out, IOSink? err}) {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final color = AnsiColor(stderrSink == stderr && stderr.hasTerminal);

  // Parse.
  final parseResult = parseProgram(source.text);
  final program = switch (parseResult) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    Failure<ParseError, SProgram>() => null,
  };
  if (program == null) {
    stderrSink.write(
      reportParseFailure(source,
          parseResult as Failure<ParseError, Object?>, color: color),
    );
    return 1;
  }

  // Seed bindings + dataDecls from the prelude so user code can
  // reference `Eq`, `Acc`, and any other ambient names without
  // redeclaring them.
  final prelude = loadPrelude();
  final preludeDeclCount = prelude.bindings.length + prelude.dataDecls.length;
  var bindings = prelude.bindings;
  var dataDecls = prelude.dataDecls;
  var namespaceBindings = prelude.namespaceBindings;

  // Set the current file path so imports can resolve relative paths.
  currentImportPath = source.filename;
  importedPaths.clear();

  for (final decl in program.decls) {
    final env = TopEnv(bindings, dataDecls, const {}, namespaceBindings);
    try {
      final produced = elabDecl(env, decl);
      // For recursive/mutual `fun` paths, `checkDeclResult` pre-scopes
      // all group members in Ctx with self-neutral values before
      // checking any body, the classical CIC fixpoint discipline
      // (SPEC §8.6).
      final runningData = [...dataDecls, ...produced.dataDecls];
      // For import decls, expand the env to include the import's own
      // bindings so checkDeclResult can verify cross-references within
      // the imported module.
      final checkBindings =
          decl.kind is SImportKind
              ? [...bindings, ...produced.bindings]
              : bindings;
      final runningEnv = TopEnv(
        checkBindings,
        runningData,
        const {},
        namespaceBindings,
      );
      final finalized = checkDeclResult(runningEnv, produced);
      bindings = [...bindings, ...finalized];
      dataDecls = runningData;
      namespaceBindings = mergeNamespace(
        namespaceBindings,
        produced.namespaceBindings,
      );
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
      stderrSink.write(reportCheckError(source, e, reportSpan, color: color));
      return 1;
    } on ElabError catch (e) {
      stderrSink.write(reportElabError(source, e, color: color));
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
