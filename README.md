# Doxa

Doxa is a dependently typed proof assistant written in Dart. The repository
contains the `doxa` kernel with the surface parser, elaborator, and tactic
engine; the `doxa_tooling` command-line and language-server package; the
`doxa_stdlib` standard-library package; and editor integrations for VS Code,
Zed, and JetBrains.

## Status

Doxa is experimental and has no release. `doxa` 0.8.4 was published to pub.dev
on 2026-11-12 and retracted the same day. `doxa_tooling` and `doxa_stdlib`
have never been published. Publishing is on hold until the project is ready.
The bar a release must meet is
[`docs/RELEASEWORTHY.md`](docs/RELEASEWORTHY.md).

## Requirements

Doxa requires Dart 3.7 or later.

## Features

- Dependent functions and a bidirectional checker.
- Universes with cumulativity, plus the impredicative `Prop` sort and `SProp`.
- Indexed inductive types with dependent elimination and derived eliminators.
- The fourteen `by` steps: `intro`, `exact`, `apply`, `refl`, `rewrite`,
  `induction`, `cases`, `revert`, `trivial`, `simp`, `auto`, `omega`,
  `constructor`, and `have`, plus `calc` chains for equality proofs.
- Infix `*`, `+`, `<=`, and `==` for `mult`, `plus`, `leq`, and `eqb`, with
  `*` tighter than `+`, both tighter than the comparisons, left-associative
  arithmetic, and non-associative comparisons. The operators are monomorphic
  to those four functions and resolve like any other name.
- Typeclasses with single-parameter classes, instance search, explicit type
  arguments, parameterised instances, superclasses with the derived parent
  dictionary, local dictionaries, and multi-parameter classes. Default
  method bodies are not supported; see [`SPEC.md`](SPEC.md#typeclasses).
- The standard-library package, with `Nat`, `Bool`, `List`, `Option`, `Vec`,
  `Sigma`, `Int`, `Rational`, equality, the `Eqb` class and its instances,
  the algebra monoids (`AddMonoid`, `AddCommMonoid`, `Monoid`,
  `CommMonoid`) with `Nat` and `List` instances, and arithmetic lemmas.
  Programs reach it through `package:` imports.

## Quick start

From a checkout, check the bundled example:

```sh
cd doxa_tooling
dart pub get
dart run bin/doxa.dart check ../example/proofs.doxa
```

The command prints `OK: 59 declarations checked`. Errors identify the source
span and, for type mismatches, the expected and found types. The CLI also
provides `doxa repl`, `doxa lsp`, and `doxa fmt FILE`.

A standalone program:

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

### Use the standard library

Declare a path dependency on `doxa_stdlib` and fetch the package
configuration once:

```yaml
dev_dependencies:
  doxa_stdlib:
    path: ../doxa_stdlib
```

```sh
dart pub get
```

Then import the library by package URI:

```doxa
import "package:doxa_stdlib/stdlib/nat.doxa"

val two: Nat = succ (succ zero)
val four: Nat = plus two two
```

The resolver reads the nearest `.dart_tool/package_config.json` above the
importing file and resolves `package:doxa_stdlib/<path>` under the package's
library root. A file outside a Dart project that uses a package URI fails with
a configuration error instead of falling back to a relative path.

## Documentation

- [`SPEC.md`](SPEC.md) is the normative description of the surface syntax and
  the implemented typing rules.
- [`docs/tutorial.md`](docs/tutorial.md) introduces the language through
  checked examples.
- [`docs/proof-guide.md`](docs/proof-guide.md) describes the natural-number
  descent used by the `sqrt2` case study.
- [`docs/arithmetic.md`](docs/arithmetic.md) documents the arithmetic
  development.
- [`docs/KERNEL_INVARIANTS.md`](docs/KERNEL_INVARIANTS.md) records the
  metavariable rules the kernel enforces.
- [`doxa_stdlib/README.md`](doxa_stdlib/README.md) describes the standard
  library and its package layout.

Every `doxa` block in this README is a complete program checked by
`doxa_tooling/test/doc_blocks_test.dart`. A block that needs surrounding
context carries `<!-- doxa: fragment -->` on the line before its fence.

## Layout

```
doxa/              kernel library package
doxa_tooling/      CLI, formatter, REPL, LSP, and browser entry point
doxa_stdlib/       Doxa standard-library package with the checked sources
editors/           VS Code, Zed, and JetBrains extensions
tool/grammar/      declarative grammar IR and tree-sitter generator script
contrib/           generic-editor client configurations
example/           small checked Doxa program
```

## Editors

The VS Code extension is in [`editors/vscode/`](editors/vscode/). Build and
package it with the commands in that directory's `package.json`.

The Zed extension is in [`editors/zed/`](editors/zed/). It uses the
tree-sitter grammar generated from the declarative IR in
[`tool/grammar/`](tool/grammar/) (see
[tree-sitter-doxa](https://github.com/hakimjonas/tree-sitter-doxa)) and
starts the language server from PATH.

The JetBrains plugin is in [`editors/jetbrains/`](editors/jetbrains/). Build it
with `./gradlew buildPlugin` using JDK 21 or later. The plugin is developed and
tested against IntelliJ IDEA Community Edition and other IDEs built on
IntelliJ Platform 2025.1; commercial IDEs work as-is but are untested. Generic
editor-client configuration is in [`contrib/README.md`](contrib/README.md).

## License

Doxa is licensed under the GNU General Public License, version 3 or later. See
[`LICENSE`](LICENSE).
