# Doxa proof guide: the Nat descent for sqrt(2)

## Overview

The theorem `sqrt2` proves that `square n = 2 * square m` implies
`n = zero` for natural numbers `n` and `m`. This is the descent lemma
used in the standard irrationality proof for sqrt(2). The development
uses parity and induction on `Nat`, without fractions or coprimality.

The relevant declarations are in three files:

- `lib/stdlib/proofs.doxa` contains the arithmetic and equality lemmas,
  plus `strong_ind`.
- `lib/stdlib/case_study.doxa` contains the parity lemmas, the
  accessibility proof `nat_wf`, and `sqrt2`.
- `lib/stdlib/nat.doxa` defines `Lt`.

## 1. Arithmetic lemmas (proofs.doxa)

These five lemmas extend the existing `plus_comm` and `plus_assoc`
proofs:

- mult_succ_right m n -- mult m (succ n) = plus m (mult m n)
- mult_comm m n -- mult m n = mult n m
- mult_2 n -- mult (succ (succ zero)) n = plus n n
- mult_plus a b c -- mult (plus a b) c = plus (mult a c) (mult b c)
- mult_assoc m n p -- mult (mult m n) p = mult m (mult n p)

`proofs.doxa` also contains list, vector, refutation, and strong-induction
lemmas.

## 2. Parity lemmas (case_study.doxa)

### even and its recurrence

The even function computes parity by structural recursion:

```
fun even(n: Nat): Bool = match n {
  case zero => true_
  case succ n_ => match even n_ {
    case true_ => false_
    case false_ => true_
  }
}
```

A helper parity_flip_b expresses the recurrence:

```
fun parity_flip_b(b: Bool): Bool = match b {
  case true_ => false_
  case false_ => true_
}
```

The identity even (succ (succ n)) = even n is proved by induction
using parity_flip_invol (double negation is an involution on Bool).

### even_double

plus n n is always even.  Proof by induction on n using
even_succ_succ_eq_even and plus_succ.

### even_plus_parity

The parity of a sum is determined by the parities of the summands:

```
val even_plus_parity : (a: Nat) -> (b: Nat) ->
  Eq Bool (even (plus a b)) (parity_comb (even a) (even b))
```

`parity_comb p q` is `true_` when `p` and `q` have the same value. The
proof uses induction on `a` and `Bool.ind` in the Boolean helper lemma.

### even_square_eq

square n has the same parity as n.  The step case uses an algebraic
helper square_succ_algebra to expand square (succ k) into
succ (plus (plus k k) (square k)), then applies even_plus_parity,
even_double, and the induction hypothesis.

### Corollaries

- even_square_even n: if even n = true_ then even (square n) = true_
- even_square_implies_even n: if even (square n) = true_ then even n = true_

### sqrt2_parity

If n^2 = 2*m^2 then n is even:

```
val sqrt2_parity : (n: Nat) -> (m: Nat) ->
  Eq Nat (square n) (mult two (square m)) -> Eq Bool (even n) true_
```

The proof rewrites `mult two (square m)` to `plus (square m) (square m)`,
uses `even_double`, transports along the equality hypothesis, and applies
`even_square_implies_even`.

## 3. Lt and induction

`Lt` is the strict ordering used by the accessibility proof and the
strong-induction principle:

```
data Lt : Nat -> Nat -> Prop {
  lt_succ : (n: Nat) -> Lt n (succ n);
  lt_trans : (n: Nat) -> (m: Nat) -> (k: Nat) -> Lt n m -> Lt m k -> Lt n k;
}
```

The `nat_wf` and `nat_wf_help` definitions in `case_study.doxa` use
mutual structural recursion. `nat_wf n` returns
`Acc Nat ((x: Nat) => (y: Nat) => Lt x y) n`. Its zero case eliminates
`Lt y zero`; its successor case delegates to `nat_wf_help`.

`nat_wf_help k y h` recurses structurally on `h`. In the `lt_succ` case
it calls `nat_wf`; in the `lt_trans` case it extracts the accessibility
continuation from the recursive result and applies it to the first
ordering proof.

The final theorem uses `strong_ind` from `proofs.doxa`. Its induction
step receives a proof of the theorem at every strictly smaller natural
number.

## 4. Algebraic lemmas

- half n -- floor division by 2 (structural recursion)
- lt_succ_right n m h -- if Lt n m then Lt n (succ m) (via lt_trans)
- mult_4_eq a -- 4*a = 2*(2*a) (via mult_assoc)
- mult_two_succ n -- 2*(succ n) = succ (succ (2*n))
- mult_2_inj a b h -- if 2*a = 2*b then a = b
- square_double p -- (2*p)^2 = 4*p^2 (using mult_assoc, mult_comm)
- lt_succ_mono a b h -- if Lt a b then Lt (succ a) (succ b)
- even_implies_double n h -- if even n = true_ then n = 2 * half n
- lt_succ_t_mult_two_t t -- succ t < 2 * succ t
- lt_t_succ_k t k h -- if succ k = 2*t then t < succ k

## 5. sqrt2 theorem

Given `h_eq: Eq Nat (square n) (mult two (square m))`, the theorem proves
`Eq Nat n zero`. It applies `strong_ind` to `n` and first obtains
`Eq Nat n (mult two (half n))` from `sqrt2_parity`. Writing `t = half n`
and `u = half m`, algebraic rewriting and `mult_2_inj` derive
`Eq Nat (square t) (mult two (square u))`.

The final case analysis is on `t`:

- If `t = zero`, `Eq Nat n (mult two t)` yields `Eq Nat n zero`.
- If `t = succ v`, `lt_t_succ_k` and the equation for `n` establish
  `Lt (succ v) n`. The induction hypothesis applied to the displayed
  equality gives `Eq Nat (succ v) zero`, which `succ_ne_zero` refutes.

## 6. Verification

```
doxa_tooling/build/doxa check lib/stdlib/proofs.doxa      # 82 declarations
doxa_tooling/build/doxa check lib/stdlib/case_study.doxa  # 128 declarations
```

Both files type-check with the current CLI.
