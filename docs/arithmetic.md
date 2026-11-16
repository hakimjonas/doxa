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
| `gcd m n` | Euclid's algorithm through `gcd_acc`, with fuel `m + n` | greatest common divisor; `gcd zero n = n` and `gcd m zero = m` |
| `lcm m n` | `div (mult m n) (gcd m n)` | least common multiple; `lcm m zero = zero` |
| `coprime m n` | `and_ (leq (gcd m n) (succ zero)) (lt zero (gcd m n))` | true when the gcd is exactly one |
| `divides d n` | `false_` for `d = zero`, otherwise `leq (mod n d) zero` | true when `d` divides `n` |
| `prime n` | `prime_acc` | true when `n >= 2` and no `d` with `2 <= d < n` divides `n` |

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

- `mod m n < n`, proved as `mod_lt`:
  `(m: Nat) -> (n: Nat) -> Lt zero n -> Lt (mod m n) n`.
- `plus (mult (div m n) n) (mod m n) = m`, up to commutativity of `mult`,
  proved as `div_add_mod`:
  `(m: Nat) -> (n: Nat) -> Lt zero n -> Eq Nat (plus (mult (div m n) n) (mod m n)) m`.
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

The `mod_lt` proof generalises the `mod_acc` case split through `Bool.ind`
with an explicit motive carrying the decision equation
`Eq Bool (lt m (succ d)) x`. A direct `match` on `lt m n` does not refine a
goal that mentions the scrutinee, so the equation is threaded as a hypothesis
instead. `mod_step` and `mod_step_lt` implement the pattern: `mod_step` takes
the branch, and `mod_step_lt` proves the bound for an arbitrary decision `b`
by eliminating `b` with the equation in the motive.

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

`gcd` uses `gcd_acc (plus m n) m n`. Fuel `m` alone is insufficient when
`m < n`: `gcd 2 3` would return `2`. Euclid reaches a zero remainder within
`m + n` steps, so the sum is a safe bound.

### Arbitrary precision

`Nat` and `Int` are inductive types, so their values have no fixed width.
Arithmetic on them cannot overflow. The trade-off is that evaluation cost
grows with the numeric value: `Nat` is unary, and `mod`/`div` use iterated
subtraction, so a computation that would be constant-time on a machine word
takes time proportional to the quotient or remainder.

### Primality

`prime n` is `false_` for `n = zero` and `n = succ zero`. For
`n = succ (succ n__)`, it calls `prime_acc n__ n`. Each candidate is
`succ (succ k_)`, so the candidates run from `n - 1` down to `2`. The guard
`lt (succ (succ k_)) n` is true for every candidate, `divides` tests each
candidate, and the `zero` fuel case returns `true_` after the divisors run
out. The result is `true_` exactly when `n >= 2` and no `d` with
`2 <= d < n` divides `n`.

Checks by `refl`: `prime 2`, `prime 3`, `prime 5`, `prime 7`, `prime 11`,
and `prime 13` are `true_`; `prime 0`, `prime 1`, `prime 4`, `prime 6`,
`prime 8`, `prime 9`, and `prime 15` are `false_`. The case study lemmas
`prime_two`, `not_prime_zero`, and `not_prime_one` still check.

### Coprimality

`coprime m n` is `and_ (leq (gcd m n) (succ zero)) (lt zero (gcd m n))`.
The two tests require the gcd to be at most one and nonzero, so the gcd is
exactly one. `coprime zero zero` is `false_` because `gcd zero zero = zero`.
`coprime zero one`, `coprime one zero`, `coprime one one`, and
`coprime two three` are `true_`; `coprime two four` and `coprime three three`
are `false_`.

### Order and subtraction lemmas

`lib/stdlib/proofs.doxa` proves fifteen lemmas that relate the Boolean
comparisons to the `Lt` relation and bound truncated subtraction:

| Lemma | Statement | Bridges |
|---|---|---|
| `leq_refl` | `Eq Bool (leq n n) true_` | reflexivity of `leq` |
| `leq_trans` | `leq a b -> leq b c -> leq a c` | transitivity of `leq` |
| `leq_succ_right` | `leq a b -> leq a (succ b)` | monotonicity of `leq` in its right argument |
| `leq_succ_true` | `leq m k = false_ -> leq (succ k) m` | a failed `leq` gives `leq` in the opposite direction |
| `leq_self_plus` | `leq v (plus X v)` | a value is at most a sum with it on the right |
| `lt_zero_succ` | `Lt zero (succ n)` | zero is below every successor |
| `lt_succ_mono` | `Lt a b -> Lt (succ a) (succ b)` | monotonicity of `Lt` under `succ` |
| `lt_of_leq` | `leq m n -> Lt m (succ n)` | the Boolean `leq` to `Lt` |
| `lt_true_Lt` | `lt m n -> Lt m n` | the Boolean `lt` to `Lt` |
| `lt_false_leq` | `lt m n = false_ -> leq n m` | a failed `lt` gives `leq` in the opposite direction |
| `lt_leq` | `Lt m n -> leq m n` | the `Lt` relation to the Boolean `leq` |
| `leq_sub` | `leq (sub m n) m` | truncated subtraction is at most the minuend |
| `sub_add` | `leq n m -> plus (sub m n) n = m` | subtraction plus its subtrahend reconstructs the minuend |
| `sub_plus_self` | `sub (plus X w) w = X` | subtracting the addend recovers the summand |
| `plus_sub_swap` | `plus B (sub A v) = plus A (sub B v)` | swaps two bounded subtractions across a sum |

The implication arrows abbreviate the full theorem types; a `leq` or `lt`
premise is the corresponding `Eq Bool ... true_` hypothesis. `lt_succ_mono`
and `lt_leq` are declared as `fun`s with structural recursion on the `Lt`
proof; the other thirteen are `val` bindings built from `Nat.ind`.

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
`intAbs` (returning a `Nat`), and `intSign`; `int_base.doxa` stays
operations-only for `Rational`. `int.doxa` adds `intDiv` and `intMod`.

### Division convention

The implementation uses Euclidean division, matching Lean 4's `Int.ediv` and
`Int.emod`. For a divisor `b` with `b != 0`:

- `0 <= r < |b|`, where `|b|` is `intAbs b`.
- `a = b * q + r`.

`intDiv a b` and `intMod a b` reduce to `Nat.div` and `Nat.mod` on the
magnitudes and adjust the quotient when the remainder is nonzero. For
`b = 0`, `intDiv a 0 = pos zero` and `intMod a 0 = a`, which matches Lean's
`Int.ediv`/`Int.emod` and the `Nat` conventions above.

The main alternative is truncated division, rounding toward zero. Its
remainder has the sign of the dividend and satisfies `|r| < |b|`. Coq's
`Z.quot` and `Z.rem`, Lean's `Int.tdiv` and `Int.tmod`, and the division
operators of C, Java, and Rust use this convention. Coq's `Z.div` and
`Z.modulo` use floor division instead, with the remainder taking the sign of
the divisor; that convention coincides with Euclidean division only for a
positive divisor.

Concrete checks, with `v = n` written `pos n` and `v = -(n + 1)` written
`neg n`, so -7 is `neg 6`:

| `a` | `b` | `intDiv a b` | `intMod a b` |
|---|---|---|---|
| 7 | 2 | 3 | 1 |
| -7 | 2 | -4 | 1 |
| -6 | 2 | -3 | 0 |
| -5 | 2 | -3 | 1 |
| 7 | -2 | -3 | 1 |
| 7 | -3 | -2 | 1 |
| -7 | -2 | 4 | 1 |
| -6 | -2 | 3 | 0 |
| -5 | -2 | 3 | 1 |
| 6 | 3 | 2 | 0 |
| -6 | 3 | -2 | 0 |
| 6 | -3 | -2 | 0 |
| -6 | -3 | 2 | 0 |
| 5 | 0 | 0 | 5 |
| -5 | 0 | 0 | -5 |
| 0 | 2 | 0 | 0 |
| 0 | -2 | 0 | 0 |
| 2 | 2 | 1 | 0 |
| -2 | -2 | 1 | 0 |

All rows check by `refl`.

## Open lemmas

Both `mod_lt` and `div_add_mod` are proved in `lib/stdlib/proofs.doxa`. No
general theorem about the `Nat` arithmetic operations remains open.

For `Int`, the Euclidean identity and bound are proved for all `a` and
`b != 0`:

- `intDivMod`: `intPlus (intMult b (intDiv a b)) (intMod a b) = a`.
- `intMod_nonneg`: `intLeq (pos zero) (intMod a b)` is `true_`.
- `intMod_lt`:
  `intLeq (intPlus (intMod a b) (pos (succ zero))) (pos (intAbs b))` is
  `true_`.

The two bound theorems take the nonzero condition as the hypothesis
`(Eq Int b (pos zero) -> False)`. `intDivMod` also covers `b = 0`:
`intDiv a 0 = pos zero` and `intMod a 0 = a`.

The proofs use `intMult_pos_intNeg`, `intMult_neg_pos`,
`intPlusHelp_plus`, `intDivNeg_shift`, `intPlus_one`, and
`intModNegR_bound`, together with the Nat helpers `leq_self_plus`,
`lt_leq`, `sub_plus_self`, `plus_sub_swap`, `leq_succ_succ`,
`lt_succ_leq`, and `sub_lt_succ`. The nonnegative-dividend half also uses
`intMult_neg_intNeg` and `intNeg_pos_zero`.

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
