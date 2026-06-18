# Doxa Package Split Plan

Split the single `doxa` package into two sibling packages in a monorepo:
`doxa` (kernel) and `doxa_tooling` (tooling + CLI + WASM).

## Research baseline

Modern languages consistently separate kernel from tooling:

| Language | Kernel | LSP / Tooling | Split |
|---|---|---|---|
| Dart | `analyzer` | `analysis_server` | Two packages, same `pkg/` monorepo |
| Rust | `rustc` (own repo) | `rust-analyzer` (own repo) | Separate repositories |
| Go | `golang/go` | `golang/tools/gopls` | Separate repositories |
| Lean 4 | `Lean.Elab` | `Lean.Server` | One binary, internal modules |
| Rumil | `rumil` | `rumil_tokens`, `rumil_parsers` | Sub-packages, same monorepo |

The Dart SDK pattern is the closest analogue: `analyzer` is the core engine,
`analysis_server` is the LSP server that consumes it. Both are sibling
packages under `pkg/` in the same monorepo. Doxa follows the same pattern.

## Target structure

```
doxa/                                  # git repo root (monorepo)
│
├── doxa/                              # package:doxa — kernel library
│   ├── lib/
│   │   ├── doxa.dart                  # barrel exports
│   │   └── src/
│   │       ├── term.dart
│   │       ├── value.dart
│   │       ├── env.dart
│   │       ├── ctx.dart
│   │       ├── meta.dart
│   │       ├── registry.dart
│   │       ├── eval.dart
│   │       ├── check.dart
│   │       ├── elab.dart
│   │       ├── parse.dart
│   │       ├── surface.dart
│   │       ├── pretty.dart
│   │       ├── diff.dart
│   │       ├── report.dart
│   │       └── source.dart
│   ├── test/
│   │   ├── term_test.dart
│   │   ├── eval_test.dart
│   │   ├── conv_test.dart
│   │   ├── check_test.dart
│   │   ├── elab_test.dart
│   │   ├── parse_test.dart
│   │   ├── meta_test.dart
│   │   ├── meta_unify_test.dart
│   │   ├── subtype_test.dart
│   │   ├── pretty_test.dart
│   │   ├── report_test.dart
│   │   ├── source_test.dart
│   │   ├── smoke_test.dart
│   │   ├── prop_test.dart
│   │   ├── dotted_name_test.dart
│   │   └── let_test.dart
│   ├── pubspec.yaml
│   └── analysis_options.yaml
│
├── doxa_tooling/                      # package:doxa_tooling — tooling + CLI + WASM
│   ├── lib/
│   │   ├── doxa_tooling.dart          # barrel exports
│   │   └── src/
│   │       ├── tokenize.dart          # Phase 0
│   │       ├── highlight.dart         # Phase 0
│   │       ├── syntax.dart            # Phase 1
│   │       ├── parse_tree.dart        # Phase 1
│   │       ├── cst.dart               # Phase 1
│   │       ├── output.dart            # Phase 2
│   │       ├── sem_info.dart          # Phase 3a
│   │       ├── web_check.dart         # Phase 2+3a pipeline driver
│   │       ├── repl.dart              # Phase 3b
│   │       └── lsp/                   # Phase 3c
│   │           ├── transport.dart
│   │           ├── protocol.dart
│   │           └── handler.dart
│   ├── bin/
│   │   └── doxa.dart                  # CLI: check, check --json, repl, lsp
│   ├── web/
│   │   └── doxa_check.dart            # WASM entry
│   ├── test/
│   │   ├── programs_test.dart
│   │   ├── stdlib_test.dart
│   │   ├── wasm_entry_test.dart
│   │   ├── parse_tree_test.dart
│   │   ├── inductive_elab_test.dart
│   │   ├── inductive_infer_test.dart
│   │   ├── inductive_kernel_test.dart
│   │   ├── inductive_parse_test.dart
│   │   ├── inductive_registry_test.dart
│   │   ├── inductive_audit_test.dart
│   │   ├── match_elab_test.dart
│   │   ├── match_kernel_test.dart
│   │   ├── match_parse_test.dart
│   │   ├── match_reduction_audit_test.dart
│   │   ├── match_step5_unreachability_test.dart
│   │   ├── vmatch_roundtrip_test.dart
│   │   ├── recursor_test.dart
│   │   ├── recursor_programs_test.dart
│   │   ├── mutual_test.dart
│   │   ├── mutual_data_test.dart
│   │   ├── positivity_test.dart
│   │   ├── structural_recursion_walker_test.dart
│   │   └── test/programs/            # .doxa test fixtures (move entire dir)
│   ├── pubspec.yaml
│   └── analysis_options.yaml
│
├── lib/stdlib/                        # .doxa stdlib files (shared test data)
│   ├── prelude.doxa
│   ├── nat.doxa
│   ├── bool.doxa
│   ├── list.doxa
│   ├── option.doxa
│   ├── vec.doxa
│   ├── eq.doxa
│   └── proofs.doxa
│
├── example/
│   ├── proofs.doxa
│   └── README.md
│
├── docs/
│   ├── TOOLING_PLAN.md
│   └── PACKAGE_SPLIT_PLAN.md
│
├── tool/
│   ├── stack_stress.dart
│   ├── parse_bench.dart
│   └── dump_recursor.dart
│
├── .gitignore
├── CHANGELOG.md
├── LICENSE
├── README.md
├── SPEC.md
└── SYNTAX.md
```

## Dependency graph

```
rumil ──────────────────┐
                        ├── doxa (kernel)
                        │
rumil_tokens ───────────┤
                        │
                        ├── doxa_tooling (everything else)
                        │
doxa (path: ../doxa) ───┘
```

- `doxa` depends on: `rumil: ^0.10.0`
- `doxa_tooling` depends on: `doxa: ^0.1.0` (path `../doxa` during dev), `rumil_tokens: ^0.10.0`, `rumil: ^0.10.0`

`doxa_tooling` also has a transitive dependency on `rumil` through `doxa`, but
lists it explicitly because `bin/doxa.dart` imports `rumil` directly (for
`parseResult` type matching).

## Step-by-step migration

### Step 1 — Create the `doxa` sub-package

Move kernel files into `doxa/lib/src/`:

```
lib/src/term.dart        → doxa/lib/src/term.dart
lib/src/value.dart       → doxa/lib/src/value.dart
lib/src/env.dart         → doxa/lib/src/env.dart
lib/src/ctx.dart         → doxa/lib/src/ctx.dart
lib/src/meta.dart        → doxa/lib/src/meta.dart
lib/src/registry.dart    → doxa/lib/src/registry.dart
lib/src/eval.dart        → doxa/lib/src/eval.dart
lib/src/check.dart       → doxa/lib/src/check.dart
lib/src/elab.dart        → doxa/lib/src/elab.dart
lib/src/parse.dart       → doxa/lib/src/parse.dart
lib/src/surface.dart     → doxa/lib/src/surface.dart
lib/src/pretty.dart      → doxa/lib/src/pretty.dart
lib/src/diff.dart        → doxa/lib/src/diff.dart
lib/src/report.dart      → doxa/lib/src/report.dart
lib/src/source.dart      → doxa/lib/src/source.dart
```

Create `doxa/lib/doxa.dart` (barrel):

```dart
/// Doxa kernel: a dependently typed proof checker for the Calculus of
/// Inductive Constructions.
///
/// See `SPEC.md` for the design.
library;

export 'src/term.dart';
export 'src/value.dart';
export 'src/env.dart';
export 'src/ctx.dart';
export 'src/meta.dart';
export 'src/registry.dart';
export 'src/eval.dart' show eval, apply, quote, nf, conv, ConvResult, ConvOk, ConvMismatch, infer, check;
export 'src/check.dart';
export 'src/elab.dart' show elabDecl, checkDeclResult, elabExpr, TopBinding, TopEnv, CorecursiveGroup, ElabError, UnresolvedName, DuplicateDeclaration, NonStructuralRecursion, LambdaRequiresAnnotation, DataSortNotASort, MutualHeaderCycle, CtorResultShapeMismatch, PositivityViolation, MatchIndeterminateType, UnknownCtorInMatch, CtorMismatchInMatch, MatchArmArityMismatch, DuplicateMatchCase, NonExhaustiveMatch;
export 'src/parse.dart';
export 'src/surface.dart';
export 'src/pretty.dart';
export 'src/report.dart';
export 'src/source.dart';
```

Create `doxa/pubspec.yaml`:

```yaml
name: doxa
description: >-
  A dependently typed proof checker for the Calculus of Inductive
  Constructions, with an ML-family surface syntax and a stack-safe
  normalization-by-evaluation kernel.
version: 0.1.0
publish_to: none
repository: https://github.com/hakimjonas/doxa
homepage: https://github.com/hakimjonas/doxa

environment:
  sdk: ^3.7.0

dependencies:
  rumil: ^0.10.0

dev_dependencies:
  test: ^1.31.0
  lints: ^6.0.0
```

Copy `analysis_options.yaml` from repo root into `doxa/`.

Move kernel tests into `doxa/test/`:

```
test/term_test.dart
test/eval_test.dart
test/conv_test.dart
test/check_test.dart
test/elab_test.dart
test/parse_test.dart
test/meta_test.dart
test/meta_unify_test.dart
test/subtype_test.dart
test/pretty_test.dart
test/report_test.dart
test/source_test.dart
test/smoke_test.dart
test/prop_test.dart
test/dotted_name_test.dart
test/let_test.dart
```

### Step 2 — Create the `doxa_tooling` sub-package

Move tooling files into `doxa_tooling/lib/src/`:

```
lib/src/tokenize.dart         → doxa_tooling/lib/src/tokenize.dart
lib/src/highlight.dart        → doxa_tooling/lib/src/highlight.dart
lib/src/syntax.dart           → doxa_tooling/lib/src/syntax.dart
lib/src/parse_tree.dart       → doxa_tooling/lib/src/parse_tree.dart
lib/src/cst.dart              → doxa_tooling/lib/src/cst.dart
lib/src/output.dart           → doxa_tooling/lib/src/output.dart
lib/src/sem_info.dart         → doxa_tooling/lib/src/sem_info.dart
lib/src/web_check.dart        → doxa_tooling/lib/src/web_check.dart
lib/src/repl.dart             → doxa_tooling/lib/src/repl.dart
lib/src/lsp/transport.dart    → doxa_tooling/lib/src/lsp/transport.dart
lib/src/lsp/protocol.dart     → doxa_tooling/lib/src/lsp/protocol.dart
lib/src/lsp/handler.dart      → doxa_tooling/lib/src/lsp/handler.dart
```

Move binaries:

```
bin/doxa.dart                 → doxa_tooling/bin/doxa.dart
web/doxa_check.dart           → doxa_tooling/web/doxa_check.dart
```

Create `doxa_tooling/lib/doxa_tooling.dart` (barrel):

```dart
/// Doxa tooling: tokenizer, CST, structured output, semantic metadata,
/// REPL, and LSP server. Built on the Doxa kernel.
library;

export 'src/tokenize.dart';
export 'src/highlight.dart';
export 'src/syntax.dart';
export 'src/parse_tree.dart';
export 'src/cst.dart';
export 'src/output.dart';
export 'src/sem_info.dart';
export 'src/web_check.dart';
export 'src/repl.dart';
```

Create `doxa_tooling/pubspec.yaml`:

```yaml
name: doxa_tooling
description: >-
  Tooling infrastructure for the Doxa proof checker: tokenizer, concrete
  syntax tree, structured check output, semantic metadata, REPL, and
  LSP language server.
version: 0.1.0
publish_to: none
repository: https://github.com/hakimjonas/doxa
homepage: https://github.com/hakimjonas/doxa

environment:
  sdk: ^3.7.0

dependencies:
  doxa: ^0.1.0
  rumil: ^0.10.0
  rumil_tokens: ^0.10.0

dev_dependencies:
  test: ^1.31.0
  lints: ^6.0.0

dependency_overrides:
  doxa:
    path: ../doxa
```

The `dependency_overrides` section lets `dart pub get` resolve `doxa` from
the sibling directory during development, while `doxa: ^0.1.0` in
`dependencies` keeps the published version constraint correct.

Move tooling tests into `doxa_tooling/test/`:

```
test/programs_test.dart
test/stdlib_test.dart
test/wasm_entry_test.dart
test/parse_tree_test.dart
test/inductive_elab_test.dart
test/inductive_infer_test.dart
test/inductive_kernel_test.dart
test/inductive_parse_test.dart
test/inductive_registry_test.dart
test/inductive_audit_test.dart
test/match_elab_test.dart
test/match_kernel_test.dart
test/match_parse_test.dart
test/match_reduction_audit_test.dart
test/match_step5_unreachability_test.dart
test/vmatch_roundtrip_test.dart
test/recursor_test.dart
test/recursor_programs_test.dart
test/mutual_test.dart
test/mutual_data_test.dart
test/positivity_test.dart
test/structural_recursion_walker_test.dart
```

Move the `.doxa` fixture directory:

```
test/programs/               → doxa_tooling/test/programs/
```

### Step 3 — Update imports

Every moved file must have its imports updated. The rule is:

**In `doxa/lib/src/` files:** imports that reference other kernel files stay
as relative imports within the same package (`import 'term.dart';`). No change
needed since all kernel files move together.

**In `doxa_tooling/lib/src/` files:** imports that previously referenced
kernel files must now import from `package:doxa/...`. Imports that reference
other tooling files stay as relative imports.

For each file in `doxa_tooling/lib/src/`, change:

| Old import | New import |
|---|---|
| `import '../check.dart'` | `import 'package:doxa/src/check.dart'` |
| `import '../elab.dart'` | `import 'package:doxa/src/elab.dart'` |
| `import '../eval.dart'` | `import 'package:doxa/src/eval.dart'` |
| `import '../env.dart'` | `import 'package:doxa/src/env.dart'` |
| `import '../meta.dart'` | `import 'package:doxa/src/meta.dart'` |
| `import '../parse.dart'` | `import 'package:doxa/src/parse.dart'` |
| `import '../pretty.dart'` | `import 'package:doxa/src/pretty.dart'` |
| `import '../report.dart'` | `import 'package:doxa/src/report.dart'` |
| `import '../source.dart'` | `import 'package:doxa/src/source.dart'` |
| `import '../surface.dart'` | `import 'package:doxa/src/surface.dart'` |
| `import '../value.dart'` | `import 'package:doxa/src/value.dart'` |
| `import '../registry.dart'` | `import 'package:doxa/src/registry.dart'` |
| `import '../ctx.dart'` | `import 'package:doxa/src/ctx.dart'` |
| `import '../term.dart'` | `import 'package:doxa/src/term.dart'` |

Files that need import changes (they import kernel code):

- `doxa_tooling/lib/src/tokenize.dart` — imports rumil, rumil_tokens (unchanged)
- `doxa_tooling/lib/src/highlight.dart` — imports tokenize.dart (relative, unchanged)
- `doxa_tooling/lib/src/syntax.dart` — imports rumil, tokenize.dart → **add**: `import 'package:doxa/...'` if any kernel imports needed
- `doxa_tooling/lib/src/parse_tree.dart` — imports surface.dart, term.dart, etc. → **change to package:doxa**
- `doxa_tooling/lib/src/cst.dart` — imports parse_tree.dart, tokenize.dart → **change kernel imports to package:doxa**
- `doxa_tooling/lib/src/output.dart` — imports surface.dart → **change to package:doxa**
- `doxa_tooling/lib/src/sem_info.dart` — imports surface.dart → **change to package:doxa**
- `doxa_tooling/lib/src/web_check.dart` — imports many kernel files → **change all to package:doxa**
- `doxa_tooling/lib/src/repl.dart` — imports check, elab, env, eval, parse, pretty, report, source, surface → **change all to package:doxa**
- `doxa_tooling/lib/src/lsp/handler.dart` — imports output, sem_info, source, surface, web_check → **change kernel imports to package:doxa** (output, sem_info, web_check stay relative within doxa_tooling)
- `doxa_tooling/bin/doxa.dart` — imports web_check, check, elab, report, source, surface, repl, lsp → **change kernel imports to package:doxa**
- `doxa_tooling/web/doxa_check.dart` — imports web_check → relative within doxa_tooling (unchanged)

Test files in `doxa_tooling/test/` that import kernel code:

| Old import | New import |
|---|---|
| `import 'package:doxa/src/...'` | `import 'package:doxa/src/...'` (unchanged — already uses package:) |

Most test files already use `package:doxa/src/...` style imports, so they
should work as-is after the split. Verify and fix any that use relative
imports to kernel code.

### Step 4 — Clean up repo root

After the split, the repo root should contain only:

- `.gitignore`
- `CHANGELOG.md`
- `LICENSE`
- `README.md`
- `SPEC.md`
- `SYNTAX.md`
- `analysis_options.yaml` (shared lint config, or remove if sub-packages have their own)
- `doxa/` (sub-package)
- `doxa_tooling/` (sub-package)
- `docs/`
- `example/`
- `lib/stdlib/` (shared test data)
- `tool/`

The old top-level `lib/`, `bin/`, `web/`, and `test/` directories should be
empty (only the sub-package directories remain). Remove the old top-level
`pubspec.yaml` if it exists, or update it to reference both sub-packages.

### Step 5 — Verify

After migration, run from the repo root:

```shell
cd doxa           && dart pub get && dart analyze lib/ test/ && dart test
cd doxa_tooling   && dart pub get && dart analyze lib/ bin/ test/ && dart test
```

Both sub-packages must:
- `dart pub get` without errors
- `dart analyze` with 0 issues
- `dart test` with all tests passing (same count as before the split)
- `dart format lib/ bin/ test/` with no unformatted files

### Step 6 — Update CI

Update CI configuration to run tests on both sub-packages separately. In a
GitHub Actions matrix or equivalent:

```yaml
strategy:
  matrix:
    package: [doxa, doxa_tooling]
steps:
  - run: cd ${{ matrix.package }} && dart pub get
  - run: cd ${{ matrix.package }} && dart analyze lib/
  - run: cd ${{ matrix.package }} && dart test
```

### Step 7 — Update arda-web

The arda-web project currently depends on `doxa` via a path dependency:

```yaml
dependencies:
  doxa:
    path: /home/hakim/google/doxa
```

After the split, arda-web needs the tooling (not the kernel alone — it uses
`web_check.dart`, `output.dart`, `sem_info.dart`, `tokenize.dart`,
`highlight.dart`). Update its `pubspec.yaml`:

```yaml
dependencies:
  doxa_tooling:
    path: /home/hakim/google/doxa/doxa_tooling
  doxa:                          # transitive, only if directly imported
    path: /home/hakim/google/doxa/doxa
```

Or just depend on `doxa_tooling` alone if arda-web doesn't directly import
kernel types.

Update imports in arda-web's Dart files:
- `import 'package:doxa/...'` for kernel types → `import 'package:doxa/...'` (unchanged, same package name on pub)
- `import 'package:doxa/src/...'` for tooling → `import 'package:doxa_tooling/...'`

Rebuild the WASM:

```shell
cd doxa_tooling
dart compile wasm web/doxa_check.dart -o web/doxa_check.wasm
```

Copy the output to arda-web's `static/wasm/` directory.

## What stays shared at repo root

| Path | Why shared |
|---|---|
| `example/` | Example .doxa files consumed by the CLI and the README |
| `lib/stdlib/` | Standard library .doxa files, test fixtures for both packages |
| `docs/` | Design docs, planning docs, not package code |
| `tool/` | Stress harness and benchmarks, import from `doxa_tooling` if needed |
| `README.md`, `SPEC.md`, `SYNTAX.md` | Project documentation, not package-specific |
| `.gitignore`, `LICENSE`, `CHANGELOG.md` | Repo-level files |

## Timeline

| Step | What | Estimated effort |
|---|---|---|
| 1 | Create `doxa` sub-package, move kernel files, write pubspec | 15 min |
| 2 | Create `doxa_tooling` sub-package, move tooling files, write pubspec | 15 min |
| 3 | Update all imports in tooling files to use `package:doxa/...` | 30 min |
| 4 | Move test files to correct sub-packages | 10 min |
| 5 | Run analyze + tests on both sub-packages, fix any issues | 30 min |
| 6 | Clean up repo root (remove stale top-level files) | 5 min |
| 7 | Update arda-web dependency and rebuild WASM | 10 min |
| **Total** | | **~2 hours** |
