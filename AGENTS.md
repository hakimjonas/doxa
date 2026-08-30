# AGENTS.md — Doxa project conventions for automated agents

## Tool usage rules

### Diagnosing .doxa parse errors or type errors

Use `doxa check <file>` or `doxa lsp`. The diagnostic output gives line and
column information. Do NOT use `head`, `tail`, `sed`, `awk`, or manual
paren-counting to triage syntax errors in `.doxa` files.

### Testing a single declaration

Comment out the rest of the file with `//` line prefixes. Do NOT truncate
the file with `head`/`tail`. Commenting keeps line numbers stable so
diagnostics remain accurate; truncation destroys context that the parser
and other declarations depend on.

### Running tests

```sh
dart test                     # kernel tests (working dir: doxa/)
dart test                     # tooling tests (working dir: doxa_tooling/)
dart run doxa_tooling/bin/doxa.dart check <file>    # check a single .doxa file
dart analyze                  # static analysis (either package)
```

### Eldarator eliminators — reference

`Bool.ind` takes 4 positional arguments: `motive, trueCase, falseCase, scrutinee`.
`Nat.ind` takes 3 positional arguments: `motive, zeroCase, succCase, scrutinee`.
Do not guess eliminator arity — check the prelude or existing proofs in `lib/stdlib/proofs.doxa`.

## Project structure

| Directory | Purpose |
|---|---|
| `doxa/` | Kernel library (check, elab, eval, parse, surface, etc.) |
| `doxa_tooling/` | CLI, REPL, LSP, WASM, formatter, structured output |
| `lib/stdlib/` | Standard library `.doxa` files |
| `editors/vscode/` | VS Code extension (TypeScript-free JS + TextMate grammar) |
| `editors/jetbrains/` | JetBrains plugin (Kotlin, builds with Gradle) |
| `docs/` | Plans, specs, handovers |
| `tool/` | Benchmarking and profiling harnesses |

### Version

The canonical version lives in `VERSION` at the repository root. All packages
and editor extensions read from it:

| Location | How version is set |
|---|---|
| `doxa/pubspec.yaml` | `version: <VERSION>` |
| `doxa_tooling/pubspec.yaml` | `version: <VERSION>` |
| `editors/vscode/package.json` | `"version": "<VERSION>"` |
| `editors/jetbrains/gradle.properties` | `pluginVersion = <VERSION>` |
| `doxa_tooling/lib/src/lsp/handler.dart` | `serverInfo.version` |
| `editors/zed/extension.toml` | `version = "<VERSION>"` |
| `editors/zed/Cargo.toml` | `version = "<VERSION>"` |

When bumping the version, update `VERSION` and all of the above. CI verifies
they stay in sync.

## Prose and documentation

Load the `domain-writing` skill before writing documentation, proof guides,
tutorials, specs, or comments. No AI-language tells, no em dashes, no
set-piece constructions. All claims must be precise and verifiable against
the kernel's actual behaviour.

## Dart conventions and pana score

- `dart format --set-exit-if-changed` on both packages and the root.
- Before publishing to pub.dev: `pana .` **must score 150/160**.
- After publishing: the target is **160/160**.
- Do not introduce new lints or warnings. Every `dart analyze` issue is a
  blocker.

## Pre-commit checklist

Before staging or committing any change, run ALL of these from the
repository root.  Do NOT commit if any check fails.

```sh
# 1. Dart static analysis (both packages)
dart analyze  && (dart analyze)

# 2. Dart formatter (both packages)
dart format --set-exit-if-changed .  && (dart format --set-exit-if-changed .)

# 3. Doxa checker on key stdlib files
dart run doxa_tooling/bin/doxa.dart check lib/stdlib/nat.doxa
dart run doxa_tooling/bin/doxa.dart check lib/stdlib/proofs.doxa
dart run doxa_tooling/bin/doxa.dart check lib/stdlib/case_study.doxa

# 4. Doxa formatter on ALL stdlib .doxa files
find lib/stdlib -name '*.doxa' -exec dart run doxa_tooling/bin/doxa.dart fmt --check {} \;

# 5. Kernel tests
dart test

# 6. Tooling tests
dart test

# Kernel and tooling directories shown before working-directory prefix.
# --- doxa/ directory ---
# --- doxa_tooling/ directory ---
```

## Editor extensions

### Manual-test findings

Manual testing is expected to uncover further editor and LSP defects. Treat
each finding as evidence of an invariant failure: reproduce it with the
reported file and position, identify the underlying cause across the relevant
layers, fix that cause at its source, and add a regression test. Do not patch
individual symptoms or add special cases merely to make one manual test pass.
The goal is a publishable editor experience whose behavior follows from sound
shared abstractions.

### VS Code (`editors/vscode/`)

```sh
cd editors/vscode
npm ci                 # install dependencies
npm run esbuild        # bundle extension
npx @vscode/vsce package  # produce .vsix
```

### JetBrains (`editors/jetbrains/`)

```sh
cd editors/jetbrains
./gradlew buildPlugin  # produce .zip artifact (needs JDK 21+)
```
