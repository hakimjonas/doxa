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
dart test                     # stdlib package tests (working dir: doxa_stdlib/)
dart run doxa_tooling/bin/doxa.dart check <file>    # check a single .doxa file
dart analyze                  # static analysis (the package you are in)
```

### Eldarator eliminators — reference

`Bool.ind` takes 4 positional arguments: `motive, trueCase, falseCase, scrutinee`.
`Nat.ind` takes 3 positional arguments: `motive, zeroCase, succCase, scrutinee`.
Do not guess eliminator arity — check the prelude or existing proofs in `doxa_stdlib/lib/stdlib/proofs.doxa`.

## Project structure

| Directory | Purpose |
|---|---|
| `doxa/` | Kernel library (check, elab, eval, parse, surface, etc.) |
| `doxa_tooling/` | CLI, REPL, LSP, WASM, formatter, structured output |
| `doxa_stdlib/` | Standard-library package: Doxa sources, locator library, example, tests |
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
| `doxa_stdlib/pubspec.yaml` | `version: <VERSION>` |
| `editors/vscode/package.json` | `"version": "<VERSION>"` |
| `editors/jetbrains/gradle.properties` | `pluginVersion = <VERSION>` |
| `doxa_tooling/lib/src/lsp/handler.dart` | `serverInfo.version` |
| `editors/zed/extension.toml` | `version = "<VERSION>"` |
| `editors/zed/Cargo.toml` | `version = "<VERSION>"` |

When bumping the version, update `VERSION` and all of the above. CI verifies
they stay in sync. `doxa_tooling` depends on `doxa` at the same version; local
development uses a gitignored `doxa_tooling/pubspec_overrides.yaml` with a path
override, which CI and the release binary build generate before `dart pub get`.
The published pubspec carries no override. `version_sync_test.dart` checks the
mirrors, the dependency constraint, and the absence of a published override.

## Prose and documentation

Load the `domain-writing` skill before writing documentation, proof guides,
tutorials, specs, or comments. No AI-language tells, no em dashes, no
set-piece constructions. All claims must be precise and verifiable against
the kernel's actual behaviour.

### Documentation code blocks

`doxa_tooling/test/doc_blocks_test.dart` checks every `doxa` fenced block in
`SPEC.md` and `README.md` as a standalone program. A block that cannot stand
alone (it uses metavariables, needs an expected type, or needs surrounding
context) carries `<!-- doxa: fragment -->` on the line before its opening
fence. Extend the test's file list when another document starts carrying
checked examples.

## Dart conventions and pana score

- `dart format --set-exit-if-changed` on every package and the root.
- Before publishing to pub.dev: `pana .` **must score 150/160**.
- After publishing: the target is **160/160**.
- Do not introduce new lints or warnings. Every `dart analyze` issue is a
  blocker.

## Release principle

The bar a release must meet is [`docs/RELEASEWORTHY.md`](docs/RELEASEWORTHY.md).
It is a property of the artifact (correct, capable, useful, and usable by
someone else), not of its packaging. Distribution work (pana, metadata,
versioning, trusted publishers, and packaging) may proceed, but it is not
evidence for the bar and must not be used to argue for a release. The
publishing hold in the next section stands.

## Publishing

Publication is on hold. pub.dev and the two editor marketplaces are external,
irreversible actions, and doxa is not releaseworthy yet. There are three
pub.dev targets: `doxa`, `doxa_tooling`, and `doxa_stdlib`. Do not publish, and do
not write a plan whose last step is a publish, until the user lifts the hold.

Version bumps, tags, and pushes to GitHub need the user's explicit go-ahead.
Version bumps additionally update every mirror listed above.

- `.github/workflows/release.yml` runs on a version tag. It checks that
  `VERSION` matches the tag, builds the five binaries, writes
  `checksums.txt`, and creates the GitHub release. It must not publish to
  pub.dev or either marketplace. `release_workflows_test.dart` enforces this.
- `.github/workflows/publish.yml` is `workflow_dispatch` only. It requires the
  `tag` input, a typed `PUBLISH` confirmation, and at least one target
  checkbox. The pub.dev job publishes three packages (`doxa`, `doxa_tooling`,
  `doxa_stdlib`) and requires `ALLOW_PUB_DEV_PUBLISH=true`; the marketplace
  jobs also require `ALLOW_MARKETPLACE_PUBLISH=true`. Unset means false, so a
  fresh repository cannot publish.
- Status: `doxa` 0.8.4 was published to pub.dev on 2026-11-12 and retracted
  the same day. `doxa_tooling` and `doxa_stdlib` have never been published.
  The 0.8.4 JetBrains plugin was published from the pre-fix commit and
  remains on the marketplace.
- The distribution gate when the hold is lifted is the one used for the other
  Dart projects: `pana` 150/160 or better before the publish, 160/160 after,
  and every gate in the pre-commit checklist green. This gate covers
  packaging; the release bar is in
  [`docs/RELEASEWORTHY.md`](docs/RELEASEWORTHY.md).

## Pre-commit checklist

Before staging or committing any change, run ALL of these from the
repository root.  Do NOT commit if any check fails.

```sh
# 1. Dart static analysis (all packages)
(cd doxa && dart analyze)  && (cd doxa_tooling && dart analyze)  && (cd doxa_stdlib && dart analyze)

# 2. Dart formatter (all packages and the root)
dart format --set-exit-if-changed .

# 3. Doxa checker on key stdlib files
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/lib/stdlib/nat.doxa
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/lib/stdlib/proofs.doxa
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/lib/stdlib/case_study.doxa
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/lib/stdlib/int.doxa
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/lib/stdlib/eqb_instances.doxa

# 4. Doxa formatter on ALL stdlib .doxa files
find doxa_stdlib/lib/stdlib -name '*.doxa' -exec dart run doxa_tooling/bin/doxa.dart fmt --check {} \;

# 5. Kernel tests
(cd doxa && dart test)

# 6. Tooling tests
(cd doxa_tooling && dart test)

# 7. Standard-library package tests
(cd doxa_stdlib && dart test)
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
./gradlew buildPlugin  # produce .zip artifact (works with JDK 21 and 25)
```
