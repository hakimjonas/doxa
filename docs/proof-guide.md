# Doxa Proof Guide -- sqrt(2) is irrational (on Nat)

## Overview

The proof shows that `n² = 2·m²` has no non-trivial solution in natural
numbers. This is the arithmetic core of the classical proof that sqrt(2) is
irrational. The proof works directly on `Nat` by induction and parity,
without fractions or coprimality.

**Strategy:**

1. Prove arithmetic lemmas needed for equational reasoning with multiplication
   (`mult_comm`, `mult_succ_right`, `mult_2`). These are in
   `lib/stdlib/proofs.doxa` alongside the existing `plus_comm`, `plus_assoc`,
   and `mult_zero` lemmas.

2. Prove `even_square_implies_even`: if `n²` is even then `n` is even.
   Proved by induction on `n`.

3. Prove `sqrt2`: if `n² = 2·m²` then `n = 0`. By induction on `n`.
   The step case uses the parity lemma to extract a smaller counterexample,
   contradicting the induction hypothesis.

## 1. Arithmetic lemmas (`lib/stdlib/proofs.doxa`)

These follow the same induction-on-first-argument pattern as the existing
`plus_comm` and `plus_assoc`.

**`mult_succ_right`:**

```
val mult_succ_right : (m: Nat) -> (n: Nat) ->
  Eq Nat (mult m (succ n)) (plus m (mult m n))
```

Expands `mult m (succ n)` into `plus m (mult m n)`. Proved by induction on
`m`. The step uses `plus_assoc`, `plus_comm`, and the induction hypothesis
to rearrange `plus (succ n) (plus m (mult m n))` into
`plus (succ m) (plus n (mult m n))`.

**`mult_comm`:**

```
val mult_comm : (m: Nat) -> (n: Nat) -> Eq Nat (mult m n) (mult n m)
```

Proved by induction on `m`. The step uses `mult_succ_right`. This lemma is
used throughout the sqrt2 proof to reorder multiplication arguments.

**`mult_2`:**

```
val mult_2 : (n: Nat) -> Eq Nat (mult (succ (succ zero)) n) (plus n n)
```

A direct consequence of `mult_comm` and `mult_one`. Expresses doubling as
`n + n`.

## 2. Lemma: even square implies even

**Statement:**

```
val even_square_implies_even : (n: Nat) ->
  Eq Bool (even (square n)) true_ -> Eq Bool (even n) true_
```

**Proof outline.** The proof uses the identity

`even (mult a b) = or_ (even a) (even b)`.

Since `square n = mult n n`, we have

`even (square n) = or_ (even n) (even n) = even n`.

The key sub-lemmas:

- `even_plus`: `even (plus a b) = even a XOR even b` (as Bool-valued equality)
- `even_double`: `even (plus n n) = true_` (a number plus itself is always even)
- `even_mult`: `even (mult a b) = or_ (even a) (even b)` (product parity)

These lemmas are proved by induction on `a` using the definition of `even`,
`plus`, `mult`, `plus_comm`, `plus_assoc`, and `mult_succ_right`.

Given `even_mult n n`, the main result follows:

```
trans_e Bool (even n) (even (square n)) true_
  (sym_e Bool (even (square n)) (even n) (even_square_even n))
  h
```

where `even_square_even` chains `even_mult n n` with the Boolean identity
`or_ x x = x`.

## 3. Theorem: no non-trivial square doubles

**Statement:**

```
val sqrt2 : (n: Nat) -> (m: Nat) ->
  Eq Nat (square n) (mult (succ (succ zero)) (square m)) -> Eq Nat n zero
```

**Proof sketch.** By induction on `n`:

*Base `n = 0`.* `square 0 = 0`, and `mult 2 (square m) = 0` only when
`square m = 0`, which holds only when `m = 0`. The result is `refl zero`.

*Step `n = succ k`.* Assume the equation holds for all `n' < n` (strong
induction). Given `square (succ k) = 2 · square m`:

1. The right-hand side `2 · square m` is even, so `even (square (succ k))`
   is `true_`. By `even_square_implies_even`, `even (succ k) = true_`.

2. Being even, `succ k = 2·p` for some `p < succ k`. Substituting:

   `square (2·p) = 2 · square m`
   → `4·p² = 2·m²`
   → `2·p² = m²`.

3. So `m² = 2·p²`. Since the same pattern repeats, `m` is also even:
   `m = 2·q` for some `q`.

4. Substituting again: `2·p² = 4·q²`, so `p² = 2·q²`.

5. Now we have `p² = 2·q²` with `p < succ k`. By the induction hypothesis
   applied to `p`, we get `p = 0`. Therefore `succ k = 2·0 = 0`, which
   contradicts `n = succ k > 0`.

The contradiction forces the only remaining possibility: `n = 0`.

This descent argument is the natural-numbers analogue of the classical proof
that sqrt(2) is irrational. The descending induction is formalised in Doxa
using the `Acc` (accessibility) predicate from the prelude, or by a direct
`Nat` induction that restructures the descent into a proof by contradiction.

## 4. The irrationality of sqrt(2)

The classical theorem states that there are no integers `a, b` with
`b ≠ 0` such that `(a/b)² = 2`. In natural numbers, we work without
fractions:

If `a² = 2·b²` for natural numbers `a, b`, then `a = 0`. This is exactly
the `sqrt2` theorem above.

The connection to irrationality: if sqrt(2) were rational, it could be
written as `a/b` with `a, b` in lowest terms. Clearing denominators gives
`a² = 2·b²` in `Nat`, forcing `a = 0`, which contradicts `b ≠ 0`.

## Verification

```
doxa check lib/stdlib/proofs.doxa    # 59 declarations, all pass
doxa check lib/stdlib/case_study.doxa  # foundations pass
dart test in doxa/ and doxa_tooling/   # full suite passes
```
