# Doxa

Doxa is a dependently typed proof checker written in Dart. Its kernel checks a
surface language with dependent functions, inductive types, pattern matching,
implicit arguments, propositional equality, and a hierarchy of universes.

The repository contains the `doxa` kernel package, the `doxa_tooling` command
line and language-server package, the standard library, and editor extensions.

## Requirements

Doxa requires Dart 3.7 or later.

## Check a program

From a checkout:

```sh
cd doxa_tooling
dart pub get
dart run bin/doxa.dart check ../example/proofs.doxa
```

The command reports declarations checked or diagnostics with source spans. The
CLI also provides `doxa repl`, `doxa lsp`, and `doxa fmt FILE`.

```doxa
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}

val zeroPlus: (n: Nat) -> Eq[Nat] (plus zero n) n =
  (n: Nat) => refl n
```

## Documentation

- [`SPEC.md`](SPEC.md) describes implemented checker behavior.
- [`SYNTAX.md`](SYNTAX.md) lists the accepted surface forms.
- [`docs/tutorial.md`](docs/tutorial.md) introduces the language through checked examples.
- [`docs/proof-guide.md`](docs/proof-guide.md) describes the natural-number descent used by the `sqrt2` case study.
- [`example/README.md`](example/README.md) describes the small checked example.

## Editors

The VS Code extension is in [`editors/vscode/`](editors/vscode/). Build and
package it with the commands in that directory's `package.json`.

The JetBrains plugin is in [`editors/jetbrains/`](editors/jetbrains/). Build it
with `./gradlew buildPlugin` using JDK 21 or later. The plugin is developed and
tested against IntelliJ IDEA Community Edition and other IDEs built on
IntelliJ Platform 2025.1; commercial IDEs work as-is but are untested. Generic
editor-client configuration is in [`contrib/README.md`](contrib/README.md).

## Layout

```
doxa/              kernel library package
doxa_tooling/      CLI, formatter, REPL, LSP, and browser entry point
lib/stdlib/        checked Doxa standard-library sources
editors/           VS Code and JetBrains extensions
contrib/           generic-editor client configurations
example/           small checked Doxa program
```

## License

Doxa is licensed under the GNU General Public License, version 3 or later. See
[`LICENSE`](LICENSE).
