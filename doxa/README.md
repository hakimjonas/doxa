# Doxa

A dependently typed proof checker for the Calculus of Inductive
Constructions, with an ML-family surface syntax. Written in Dart; the
parser is built with [Rumil](https://github.com/hakimjonas/rumil-dart)
parser combinators.

Doxa is a CIC kernel: a predicative universe hierarchy with a single
impredicative `Prop`, inductive types with parametric and indexed
families and auto-derived recursors, dependent pattern matching with
structural recursion, propositional equality with proof irrelevance,
metavariables with Miller pattern unification, and implicit arguments.
Everything is checked bidirectionally over normalization by evaluation.
See [`SPEC.md`](SPEC.md) for the design.

**Version 0.8.0** — first preview release with a verified sqrt(2)
irrationality proof (127-declaration case study), 12-tactic REPL proof
mode, and LSP-powered IDE support for VS Code and JetBrains.

## Install

Requires Dart SDK 3.12 or later.

```shell
git clone https://github.com/hakimjonas/doxa.git
cd doxa
```

### CLI tools

```shell
# From the repo root:
cd doxa_tooling
dart pub get
dart run doxa check ../lib/stdlib/case_study.doxa
```

Or install globally:

```shell
cd doxa_tooling
dart pub global activate --source path .
doxa check myfile.doxa
doxa repl                # interactive proof mode
doxa lsp                 # language server
doxa fmt myfile.doxa     # format to canonical style
```

### VS Code extension

1. Open the `vscode/` directory in VS Code
2. Press F5 (Run Extension)
3. Open any `.doxa` file — syntax highlighting, diagnostics, hover,
   completion, and go-to-definition are active

Or install from the bundled `.vsix` (after you run `npm install && vsce package`
in the `vscode/` directory).

### JetBrains (IntelliJ, CLion, RustRover, etc.)

[Doxa JetBrains](https://github.com/hakimjonas/doxa-jetbrains) is a
dedicated extension providing syntax highlighting, diagnostics, hover,
completion, formatting, and code lens — all powered by `doxa lsp`.

### WASM browser demo

```shell
cd doxa_tooling
dart compile wasm web/doxa_check.dart -o web/doxa_check.wasm
# Open web/index.html in a browser
```

## Quick start

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}

val zero_plus_n : (n: Nat) -> Eq[Nat] (plus zero n) n =
  (n: Nat) => refl n
```

## Features

The kernel supports the full CIC feature set: dependent functions,
predicative cumulative `Type` hierarchy, impredicative `Prop` and
`SProp`, inductive types (parametric and indexed families, mutual
`data` blocks, strict positivity), dependent pattern matching with
structural recursion, propositional equality with proof irrelevance,
metavariables with Miller pattern unification, records with
definitional η, quotient types, and a module system with import
resolution and namespace qualification.

The standard library ([`lib/stdlib/`](lib/stdlib/)) includes:
- `nat.doxa` — natural numbers, arithmetic, `prime`, `gcd`, `mod`, `div`, `lcm`
- `proofs.doxa` — `plus_comm`, `mult_comm`, `mult_assoc`, `strong_ind`
- `case_study.doxa` — full sqrt(2) irrationality proof (127 declarations)
- `Prop/prop.doxa` — And, Or, Not, Exists connectives
- Bool, List, Vec, Option, Eq, Sigma, Int, typeclasses

The tooling stack includes:
- **CLI:** `doxa check [--json] [--watch]`, `doxa fmt [--check]`, `doxa lsp`, `doxa repl`
- **REPL:** 12 tactics with full proof mode (`:goal`, `:step`, `:undo`, `:print`, `:qed`), import support, `:browse`, `:search`
- **LSP:** diagnostics, hover, go-to-definition, completion (with types and frequency ranking), references, rename, semantic tokens, document symbols, signature help, code lens (inline declaration types), document formatting
- **Formatter:** canonical pretty-printer with fast AOT compilation
- **WASM:** browser demo with expandable per-declaration types and normal forms

## Performance invariants

- **Stack safety.** No kernel operation consumes host call stack
  proportional to input depth. A single defunctionalized driver loops
  over an explicit frame stack; see [`SPEC.md`](SPEC.md) §4.5.
- **Linear-time structural operations.** `eval`, `quote`, `conv`,
  `infer`, `check`, and `nf` are O(N) in input size N.

## Project layout

```
doxa/                          # package:doxa — kernel library
├── lib/src/                   # 19 kernel source files
└── test/                      # 456 kernel tests

doxa_tooling/                  # package:doxa_tooling — CLI + tooling
├── bin/doxa.dart              # CLI entry point
├── lib/src/
│   ├── lsp/                   # LSP server (handler, protocol, transport)
│   ├── repl.dart              # REPL session + proof mode
│   ├── format.dart            # Canonical formatter
│   ├── web_check.dart         # Pipeline driver (WASM)
│   └── tokenize.dart          # Syntax highlighting tokenizer
├── web/                       # WASM entry point + demo page
└── test/                      # 520 tooling tests

lib/stdlib/                    # Standard library (.doxa files)
├── Nat/, Bool/, List/, Vec/,  # Per-domain modules with package.doxa re-exports
│   Option/, Eq/, Int/, etc.
├── Prop/prop.doxa             # Propositional connectives
├── proofs.doxa                # Canonical proof roster
└── case_study.doxa            # sqrt(2) irrationality

vscode/                        # VS Code extension
├── extension.js               # LSP client
├── syntaxes/                  # TextMate grammar
└── icons/                     # δ file icon

contrib/                       # IDE configs (JetBrains → own repo)
tool/                          # Benchmarking and profiling tools
docs/                          # Design docs and plans
```

## License

MIT. See [`LICENSE`](LICENSE).
