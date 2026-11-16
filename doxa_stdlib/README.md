# doxa_stdlib

The Doxa standard library: checked Doxa sources for the base types and
the arithmetic development.

| Domain | Files |
|---|---|
| `Nat` | `nat.doxa` (`Nat`, `plus`, `mult`, `Lt`, comparison) |
| `Bool` | `bool.doxa` |
| `Eq` | `eq.doxa` (`sym`, `trans`, `cong`, `subst`) |
| `List` | `list.doxa` |
| `Option` | `option.doxa` |
| `Vec` | `vec.doxa` (length-indexed vectors) |
| `Sigma` | `sigma.doxa` |
| `Int` | `int_base.doxa`, `int.doxa` |
| `Rational` | `rational.doxa` |
| `Proofs` | `proofs.doxa` (arithmetic and equality lemmas) |
| `Prop` | `prop.doxa` (`And`, `Or`, `Exists`, `Not`) |
| — | `case_study.doxa` (parity lemmas and `sqrt2`) |

`prelude.doxa` is the ambient prelude source (`Eq` and `Acc`). The Doxa
kernel embeds a copy and loads it before user code, so ordinary files do not
import it.

## Layout

The canonical sources are the flat `lib/stdlib/*.doxa` files. Every domain
directory holds a `package.doxa` that re-exports its canonical file, so
`import "…/Nat/package.doxa"` reaches `Nat` without duplicating the source.
There are no symlinks and no per-domain copies.

## Locating the library from Dart

```dart
import 'package:doxa_stdlib/doxa_stdlib.dart';

void main() {
  print(stdlibRootPath); // …/doxa_stdlib/lib/stdlib
}
```

`stdlibRoot` resolves through the ambient package configuration. The
package has no runtime dependencies.

## Checking the library

From a checkout of the repository, the Doxa CLI checks the sources
directly:

```sh
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/lib/stdlib/nat.doxa
```

A Doxa program imports the sources by path:

```doxa
import "../lib/stdlib/nat.doxa"

val two: Nat = succ (succ zero)
```

Import resolution for a packaged dependency is not implemented yet; the
example in `example/` uses a relative path for that reason.
