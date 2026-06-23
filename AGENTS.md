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
| `doxa/` | Kernel library (18 source files) |
| `doxa_tooling/` | CLI, REPL, LSP, WASM, formatter |
| `lib/stdlib/` | Standard library `.doxa` files |
| `docs/` | Plans, specs, implementer prompts |

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

## Invariants

- `dart analyze` clean in both packages before completing work
- `dart format --set-exit-if-changed` clean in both packages
- `dart test` all pass in both packages before completing work
- `doxa check lib/stdlib/proofs.doxa` passes
- `doxa check lib/stdlib/case_study.doxa` passes (when relevant)
- No kernel or tooling code changes unless explicitly tasked
