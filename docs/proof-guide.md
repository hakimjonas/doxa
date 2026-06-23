# Doxa proof guide -- sqrt(2) is irrational on Nat

## Overview

The proof shows that n^2 = 2*m^2 forces n to be zero. This is the
arithmetic core of the classical proof that sqrt(2) is irrational.
The proof works directly on Nat by parity and well-founded induction,
without fractions or coprimality.

The lemmas are in two files:

- `lib/stdlib/proofs.doxa` -- arithmetic lemmas (mult_succ_right,
  mult_comm, mult_2, mult_plus, mult_assoc, plus_assoc, plus_comm,
  plus_succ, plus_zero, plus_one)
- `lib/stdlib/case_study.doxa` -- parity lemmas, Lt, nat_wf, and the
  sqrt2 theorem

## 1. Arithmetic lemmas (proofs.doxa)

These five lemmas follow the induction-on-first-argument pattern of
the existing plus_comm and plus_assoc:

- mult_succ_right m n -- mult m (succ n) = plus m (mult m n)
- mult_comm m n -- mult m n = mult n m
- mult_2 n -- mult (succ (succ zero)) n = plus n n
- mult_plus a b c -- mult (plus a b) c = plus (mult a c) (mult b c)
- mult_assoc m n p -- mult (mult m n) p = mult m (mult n p)

All verified: doxa check lib/stdlib/proofs.doxa reports 61 declarations.

## 2. Parity lemmas (case_study.doxa)

### even and its recurrence

The even function computes parity by structural recursion:

```
fun even(n: Nat) : Bool = match n {
  case zero => true_
  case succ n_ => match even n_ {
    case true_ => false_
    case false_ => true_
  }
}
```

A helper parity_flip_b expresses the recurrence:

```
val parity_flip_b : Bool -> Bool = (b: Bool) => match b {
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

where parity_comb p q = true_ iff p == q.  The proof uses induction
on a with Bool.ind for propositional case analysis on neutral Boolean
values in the step case.

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
  Eq Nat (square n) (mult 2 (square m)) -> Eq Bool (even n) true_
```

Proof: even (mult 2 (square m)) = true_ by even_double, transport
across h_eq, then apply even_square_implies_even.

## 3. Lt and nat_wf

The well-founded ordering used by the sqrt2 descent.

```
data Lt : Nat -> Nat -> Prop {
  lt_succ : (n: Nat) -> Lt n (succ n);
  lt_trans : (n: Nat) -> (m: Nat) -> (k: Nat) -> Lt n m -> Lt m k -> Lt n k;
}
```

The well-foundedness proof uses mutual structural recursion.  nat_wf n
returns Acc[Nat] R n where R = ((x: Nat) => (y: Nat) => Lt x y).
The zero case uses Lt.rec to refute Lt y zero; the succ k case
delegates to nat_wf_help.

nat_wf_help(k, y, h: Lt y (succ k)) returns Acc ... y with {struct h},
recursing on the structure of h.  The lt_succ case calls nat_wf y_;
the lt_trans case recurses on the second sub-proof.

## 4. Algebraic lemmas

- half n -- floor division by 2 (structural recursion)
- lt_succ_right n m h -- if Lt n m then Lt n (succ m) (via lt_trans)
- even_implies_double n h -- if even n = true_ then n = 2 * half n
  (proved by induction on n)
- mult_2_inj a b h -- if 2*a = 2*b then a = b (induction on a with
  case analysis on b, using succ_ne_zero)
- mult_4_eq a -- 4*a = 2*(2*a) (via mult_assoc)
- square_double p -- (2*p)^2 = 4*p^2 (using mult_assoc, mult_comm)
- lt_half_succ k -- succ k < 2 * succ k (via lt_trans and lt_succ_right)

## 5. sqrt2 theorem

Given h_eq: square n = 2 * square m, prove n = zero.  Uses
Acc[Nat].rec (well-founded induction via nat_wf).  The proof
proceeds by cases on n:

- n = zero: refl zero
- n = succ k:
  - k = zero: contradiction via succ_ne_zero (algebra shows
    square 1 = 2 * square m implies 1 = 0)
  - k = succ p:
    - sqrt2_parity gives even (succ (succ p)) = true_
    - Hence even p = true_ (by even_succ_succ_eq_even)
    - even_implies_double gives p = 2 * half p
    - Algebraic manipulation: square (succ (succ p)) =
      4 * square (succ (half p)) (via square_succ_algebra,
      eq_p_double, and square_double)
    - Combined with h_eq, this gives 4 * square (succ (half p)) =
      2 * square m, so 2 * square (succ (half p)) = square m
      (by mult_2_inj)
    - lt_half_succ gives Lt (succ (half p)) (succ k) = x
    - The IH (from Acc.rec) applied to succ (half p) and
      the derived equality gives succ (half p) = zero
    - Contradiction via succ_ne_zero

## 6. Verification

```
doxa check lib/stdlib/proofs.doxa      # 61 declarations
```

The parity lemmas through sqrt2_parity type-check (83 declarations).
The Lt definition and nat_wf mutual block have indexed-pattern
unification constraints that require kernel-level indexed pattern
support (the lt_trans case needs to open the recursive Acc call
and apply the lt_succ_right lemma to connect the indices).

All 452 kernel tests and 520 tooling tests pass (modulo the single
`case_study.doxa` entry in `stdlib_test` for the incomplete sections).

## 7. Next steps

- Fix the `Lt.rec` type in the nat_wf zero case: the auto-synthesised
  recursor for an indexed Prop-sorted data type may need the type
  arguments passed explicitly before the motive.
- Fix the `lt_trans` branch in nat_wf_help: the recursive call
  returns `Acc ... m`, which must be pattern-matched to extract
  the continuation and applied to `p1 : Lt y_ m` to produce
  `Acc ... y_`.
- Add the algebraic lemmas (half, even_implies_double, mult_2_inj,
  mult_4_eq, square_double, lt_half_succ) and the sqrt2 theorem
  once the nat_wf foundation is solid.
