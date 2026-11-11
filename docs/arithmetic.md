# Arithmetic in the standard library

This document specifies the arithmetic operations in `lib/stdlib/nat.doxa` and
`lib/stdlib/int_base.doxa`. The kernel definitions are authoritative; the
examples below were checked with `doxa check` and `refl`. Lemmas marked
*planned* are not proved.

## Natural numbers

`Nat` is the inductive type with constructors `zero` and `succ`. Values are
unary, so there is no largest value and no overflow.

| Operation | Definition | Behaviour |
|---|---|---|
| `plus m n` | recursion on `m` | `m + n` |
| `mult m n` | recursion on `m` | `m * n` |
| `sub m n` | recursion on `m`, then `n` | truncated subtraction: `m - n`, or `zero` when `m < n` |
| `div m n` | `div_acc` bounded by `m`; outer match on `n` | floor division: `m / n`; `div m zero = zero` |
| `mod m n` | `mod_acc` bounded by `m` | remainder: `m % n`; `mod m zero = m` |
| `gcd m n` | Euclid's algorithm through `gcd_acc` | greatest common divisor; `gcd zero n = n` and `gcd m zero = m` |
| `lcm m n` | `div (mult m n) (gcd m n)` | least common multiple; `lcm m zero = zero` |
| `coprime m n` | `leq (gcd m n) (succ zero)` | true when the gcd is at most one |
| `divides d n` | `false_` for `d = zero`, otherwise `leq (mod n d) zero` | true when `d` divides `n` |
| `prime n` | `prime_acc` | intended primality test; see the defect note below |

`leq`, `lt`, `coprime`, `divides`, and `prime` return `Bool`. The relation
`Lt` and the equality type `Eq` are `Prop`-valued and are used in theorems.

### Zero-divisor conventions

The two conventions follow Lean 4's `Nat.div` and `Nat.mod`:

- `div m zero = zero` for every `m`.
- `mod m zero = m` for every `m`.

Both are proved in `lib/stdlib/proofs.doxa`:

```
div_zero : (m: Nat) -> Eq Nat (div m zero) zero
mod_zero : (m: Nat) -> Eq Nat (mod m zero) m
```

### Positive divisors

For `n > 0`, `div m n` is floor division and `mod m n` is the corresponding
remainder:

- `mod m n < n`.
- `plus (mult (div m n) n) (mod m n) = m`, up to commutativity of `mult`.
  Lean 4 states the same identity as `Nat.div_add_mod`.

Concrete checks:

| Expression | Value |
|---|---|
| `div 5 2` | `2` |
| `mod 5 2` | `1` |
| `div 4 2` | `2` |
| `mod 4 2` | `0` |
| `div 0 2` | `0` |
| `mod 0 2` | `0` |
| `div 1 2` | `0` |
| `mod 1 2` | `1` |
| `div 5 0` | `0` |
| `mod 5 0` | `5` |

The bounds `mod m n < n` and `div_add_mod` are *planned*, not proved. Their
proof shapes are described under [Open lemmas](#open-lemmas).

### The fuel-based implementation

`mod` and `div` are total because both loops are structurally recursive on a
`Nat` fuel argument, not on the dividend directly:

```
fun mod_acc(k: Nat, m: Nat, n: Nat): Nat
fun div_acc(k: Nat, m: Nat, n: Nat): Nat
```

`mod m n` calls `mod_acc m m n`, and `div m n` calls `div_acc m m n` for a
positive `n`. The fuel is the original dividend `m`.

For `n > 0`, each iteration of the `false_` branch replaces `m` by
`sub m n`, which is strictly smaller than `m` when `m >= n`. Writing
`m = q * n + r` with `0 <= r < n`, the loop reaches `r` after `q` iterations
and then takes the `true_` branch. Since `q <= m` for `n >= 1`, the fuel `m`
is sufficient for every positive divisor.

For `n = zero`, `div` returns `zero` in its outer match and never calls
`div_acc`. `mod` calls `mod_acc m m zero`; the `false_` branch subtracts
`zero`, so the value stays `m`, the fuel runs out after `m` iterations, and
the `zero` case of `mod_acc` returns `m`. The fuel bound therefore also
terminates the zero-divisor case.

### Arbitrary precision

`Nat` and `Int` are inductive types, so their values have no fixed width.
Arithmetic on them cannot overflow. The trade-off is that evaluation cost
grows with the numeric value: `Nat` is unary, and `mod`/`div` use iterated
subtraction, so a computation that would be constant-time on a machine word
takes time proportional to the quotient or remainder.

### Defect in `prime`

`prime` is intended to return `true_` exactly for `n >= 2` with no divisor
`d` in `2 <= d < n`. The implementation does not do that. `prime n` calls
`prime_acc n n`, and the first test in `prime_acc k n` is
`lt (succ (succ k_)) n` with `k_` one below `k`, which is already above `n`
when `k = n`. The function therefore returns `true_` before testing any
divisor. Every `n >= 2` returns `true_`: `prime 4`, `prime 6`, `prime 8`,
`prime 9`, and `prime 15` all check by `refl`. Fixing `prime` is outside this
document's scope.

### Boundary case in `coprime`

`coprime` is the `leq` test on `gcd`, not a statement that both arguments are
nonzero. Since `gcd zero zero = zero`, `coprime zero zero = true_`. For every
other pair the gcd is at least one, so `coprime` matches the usual relation
on nonzero arguments. The single zero pair is the only exception.

## Integers

`Int` is the inductive type

```
data Int: Type {
  pos: Nat -> Int;
  neg: Nat -> Int;
}
```

`pos n` represents `n`, `neg n` represents `-(n + 1)`, and zero is `pos zero`.
The `neg` encoding avoids a second representation of zero. The operations in
`int_base.doxa` are `intPlus`, `intNeg`, `intSub`, `intMult`, `intLeq`,
`intAbs` (returning a `Nat`), and `intSign`. There is no integer division or
modulo.

### Proposed division convention

The recommendation for the future implementation is Euclidean division,
matching Lean 4's `Int.ediv` and `Int.emod`. For a divisor `b` with
`b != 0`:

- `0 <= r < |b|`, where `|b|` is `intAbs b`.
- `a = b * q + r`.

For `b = 0`, the recommendation is `q = 0` and `r = a`, which matches Lean's
`Int.ediv`/`Int.emod` and the `Nat` conventions above.

The main alternative is truncated division, rounding toward zero. Its
remainder has the sign of the dividend and satisfies `|r| < |b|`. Coq's
`Z.quot` and `Z.rem`, Lean's `Int.tdiv` and `Int.tmod`, and the division
operators of C, Java, and Rust use this convention. Coq's `Z.div` and
`Z.modulo` use floor division instead, with the remainder taking the sign of
the divisor; that convention coincides with Euclidean division only for a
positive divisor.

The choice belongs to the Int implementation charter. This document records
the recommendation and does not fix it.

## Open lemmas

Two general theorems are not in `lib/stdlib/proofs.doxa`:

- `mod_lt`: for `n > 0`, `Lt (mod m n) n`. A proof generalises the fuel
  induction over `mod_acc` and shows that the `false_` branch decreases the
  value until it falls below `n`. It needs interaction lemmas relating `sub`,
  `lt`, and `leq` that the library does not have.
- `div_add_mod`: for `n > 0`,
  `Eq Nat (plus (mult (div m n) n) (mod m n)) m`. A proof can carry the
  invariant `m = n * q + r` through the `div_acc` loop, or relate `div_acc`
  and `mod_acc` in one induction. It needs the bound from `mod_lt` and the
  distributivity and associativity lemmas for `plus` and `mult`.

Each is estimated at one to two sessions after the missing `sub`/`lt`
interaction lemmas are added.

## References

- Lean 4 reference, [Natural Numbers](https://lean-lang.org/doc/reference/latest/Basic-Types/Natural-Numbers/):
  `Nat.div` is floor division and `Nat.div 5 0 = 0`; `Nat.mod 5 0 = 5`.
- Lean 4 API, [Init.Data.Int.DivMod.Basic](https://lean-lang.org/doc/api/Init/Data/Int/DivMod/Basic.html):
  `Int.ediv` and `Int.emod` use Euclidean division with
  `0 <= Int.emod x y < Int.natAbs y` for `y != 0`. The same module defines
  `Int.tdiv` and `Int.tmod` for truncation toward zero.
- Coq standard library, [Coq.ZArith.BinIntDef](https://rocq-prover.org/doc/v8.9/stdlib/Coq.ZArith.BinIntDef.html):
  `Z.div` and `Z.modulo` are floor division; `Z.quot` and `Z.rem` are
  truncated toward zero.
