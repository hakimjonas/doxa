# doxa_stdlib

The Doxa standard library: checked Doxa sources for the base types and
the arithmetic development.

Status: experimental; there is no current release. doxa 0.8.4 was published to
pub.dev and retracted the same day, and doxa_tooling and doxa_stdlib have never
been published. Publishing is on hold. The repository status is at
https://github.com/hakimjonas/doxa#status.

| Domain | Files |
|---|---|
| `Nat` | `nat.doxa` (`Nat`, `plus`, `multiply`, `Lt`, comparison) |
| `Bool` | `bool.doxa` |
| `Eq` | `eq.doxa` (`sym`, `trans`, `cong`, `subst`) |
| `Eqb` | `eqb.doxa` (class), `eqbInstances.doxa` (instances for `Nat`, `Bool`, `List`) |
| `Algebra` | `algebra.doxa` (`AddMonoid`, `AddCommMonoid`, `AddGroup`, `AddCommGroup`, `Monoid`, `CommMonoid`, `Ring`, `CommRing`; class-qualified projections such as `Ring.multiply` and `CommRing.addComm`; `Nat` and `List` instances; `AddMonoid[Int]`, `AddCommMonoid[Int]`, `AddGroup[Int]`, `AddCommGroup[Int]`, `Ring[Int]`, and `CommRing[Int]`; `sum`, `sumViaComm`, `double`, `negTwice`, `square`) |
| `List` | `list.doxa` |
| `Option` | `option.doxa` |
| `Vec` | `vec.doxa` (length-indexed vectors) |
| `Sigma` | `sigma.doxa` |
| `Int` | `intBase.doxa`, `int.doxa` |
| `Rational` | `rational.doxa` (`Rat` normalized pairs; `ratNorm`, `ratZero`, `ratOne`, `ratOfInt`, `ratAdd`, `ratNegate`, `ratSub`, `ratMultiply`, `ratEqb`, `ratLeq`; `Eqb[Rat]`; `ratNormZeroDenom`, `ratEqbRefl`, `ratLeqRefl`) |
| `Proofs` | `proofs.doxa` (arithmetic and equality lemmas; division, divisibility, and gcd facts) |
| `Prop` | `prop.doxa` (`And`, `Or`, `Exists`, `Not`) |
| — | `caseStudy.doxa` (parity lemmas and `sqrt2`) |

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

## Using the library from a Doxa project

A project that depends on the package imports it by URI. Declare the
dependency and fetch the configuration once:

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
```

The resolver reads the nearest `.dart_tool/package_config.json` above the
importing file and resolves `package:doxa_stdlib/<path>` under the package's
library root (`lib/`). No command-line flag is involved. A file outside a
Dart project that uses a package URI fails with a configuration error instead
of falling back to a relative path.

The domain re-exports remain available:
`import "package:doxa_stdlib/stdlib/Nat/package.doxa"` reaches the same
declarations.

`import "package:doxa_stdlib/stdlib/Eqb/package.doxa"` brings the `Eqb`
class and its `Nat`, `Bool`, and `List` instances, so `equals` resolves at
those types without a local class.

`import "package:doxa_stdlib/stdlib/Algebra/package.doxa"` brings the algebra
classes, the `Nat` and `List` monoid instances, the `Int` additive and ring
instances, and the folds:

```doxa
import "package:doxa_stdlib/stdlib/Algebra/package.doxa"

val two: Nat = sum Nat (cons (succ zero) (cons (succ zero) nil))
```
