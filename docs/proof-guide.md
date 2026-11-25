# Doxa proof guide: the Nat descent for sqrt(2)

## Overview

The theorem `sqrt2` proves that `square n = 2 * square m` implies
`n = zero` for natural numbers `n` and `m`. This is the descent lemma
used in the standard irrationality proof for sqrt(2). The development
uses parity and induction on `Nat`, without fractions or coprimality.

The relevant declarations are in three files:

- `doxa_stdlib/lib/stdlib/proofs.doxa` contains the arithmetic and equality lemmas,
  the accessibility proof `natWf` / `natWfHelp`, and `strongInd`.
- `doxa_stdlib/lib/stdlib/caseStudy.doxa` contains the parity lemmas and `sqrt2`.
- `doxa_stdlib/lib/stdlib/nat.doxa` defines `Lt`.

## 1. Arithmetic lemmas (proofs.doxa)

These five lemmas extend the existing `plusComm` and `plusAssoc`
proofs:

- multiplySuccRight m n -- multiply m (succ n) = plus m (multiply m n)
- multiplyComm m n -- multiply m n = multiply n m
- multiply2 n -- multiply (succ (succ zero)) n = plus n n
- multiplyPlus a b c -- multiply (plus a b) c = plus (multiply a c) (multiply b c)
- multiplyAssoc m n p -- multiply (multiply m n) p = multiply m (multiply n p)

`proofs.doxa` also contains list, vector, refutation, and strong-induction
lemmas.

## 2. Parity lemmas (caseStudy.doxa)

### even and its recurrence

The even function computes parity by structural recursion:

<!-- doxa: fragment -->
```doxa
fun even(n: Nat): Bool = match n {
  case zero => true_
  case succ n_ => match even n_ {
    case true_ => false_
    case false_ => true_
  }
}
```

A helper parityFlipB expresses the recurrence:

<!-- doxa: fragment -->
```doxa
fun parityFlipB(b: Bool): Bool = match b {
  case true_ => false_
  case false_ => true_
}
```

The identity even (succ (succ n)) = even n is proved by induction
using parityFlipInvol (double negation is an involution on Bool).

### evenDouble

plus n n is always even.  Proof by induction on n using
evenSuccSuccEqEven and plusSucc.

### evenPlusParity

The parity of a sum is determined by the parities of the summands:

<!-- doxa: fragment -->
```doxa
val evenPlusParity : (a: Nat) -> (b: Nat) ->
  Eq Bool (even (plus a b)) (parityComb (even a) (even b))
```

`parityComb p q` is `true_` when `p` and `q` have the same value. The
proof uses induction on `a` and `Bool.ind` in the Boolean helper lemma.

### evenSquareEq

square n has the same parity as n.  The step case uses an algebraic
helper squareSuccAlgebra to expand square (succ k) into
succ (plus (plus k k) (square k)), then applies evenPlusParity,
evenDouble, and the induction hypothesis.

### Corollaries

- evenSquareEven n: if even n = true_ then even (square n) = true_
- evenSquareImpliesEven n: if even (square n) = true_ then even n = true_

### sqrt2Parity

If n^2 = 2*m^2 then n is even:

<!-- doxa: fragment -->
```doxa
val sqrt2Parity : (n: Nat) -> (m: Nat) ->
  Eq Nat (square n) (multiply two (square m)) -> Eq Bool (even n) true_
```

The proof rewrites `multiply two (square m)` to `plus (square m) (square m)`,
uses `evenDouble`, transports along the equality hypothesis, and applies
`evenSquareImpliesEven`.

## 3. Lt and induction

`Lt` is the strict ordering used by the accessibility proof and the
strong-induction principle:

<!-- doxa: fragment -->
```doxa
data Lt : Nat -> Nat -> Prop {
  ltSucc : (n: Nat) -> Lt n (succ n);
  ltTrans : (n: Nat) -> (m: Nat) -> (k: Nat) -> Lt n m -> Lt m k -> Lt n k;
}
```

The `natWf` and `natWfHelp` definitions in `proofs.doxa` use
mutual structural recursion. `natWf n` returns `Acc Nat ltRel n`,
where `ltRel a b = Lt a b`; the relation is a data parameter, and
`accIntro` takes the value and the accessibility function. Its zero
case eliminates `Lt y zero`; its successor case delegates to
`natWfHelp`.

`natWfHelp k y h` recurses structurally on `h`. In the `ltSucc` case
it calls `natWf`; in the `ltTrans` case it extracts the accessibility
continuation from the recursive result and applies it to the first
ordering proof.

The final theorem uses `strongInd` from `proofs.doxa`.
`strongIndImpl` is a direct `Acc.rec` application to `natWf`. Its
induction step receives a proof of the theorem at every strictly smaller
natural number.

## 4. Algebraic lemmas

- half n -- floor division by 2 (structural recursion)
- ltSuccRight n m h -- if Lt n m then Lt n (succ m) (via ltTrans)
- multiply4Eq a -- 4*a = 2*(2*a) (via multiplyAssoc)
- multiplyTwoSucc n -- 2*(succ n) = succ (succ (2*n))
- multiply2Inj a b h -- if 2*a = 2*b then a = b
- squareDouble p -- (2*p)^2 = 4*p^2 (using multiplyAssoc, multiplyComm)
- ltSuccMono a b h -- if Lt a b then Lt (succ a) (succ b)
- evenImpliesDouble n h -- if even n = true_ then n = 2 * half n
- ltSuccTMultiplyTwoT t -- succ t < 2 * succ t
- ltTSuccK t k h -- if succ k = 2*t then t < succ k

## 5. sqrt2 theorem

Given `hEq: Eq Nat (square n) (multiply two (square m))`, the theorem proves
`Eq Nat n zero`. It applies `strongInd` to `n` and first obtains
`Eq Nat n (multiply two (half n))` from `sqrt2Parity`. Writing `t = half n`
and `u = half m`, algebraic rewriting and `multiply2Inj` derive
`Eq Nat (square t) (multiply two (square u))`.

The final case analysis is on `t`:

- If `t = zero`, `Eq Nat n (multiply two t)` yields `Eq Nat n zero`.
- If `t = succ v`, `ltTSuccK` and the equation for `n` establish
  `Lt (succ v) n`. The induction hypothesis applied to the displayed
  equality gives `Eq Nat (succ v) zero`, which `succNeZero` refutes.

## 6. Verification

```sh
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/lib/stdlib/proofs.doxa      # 115 declarations
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/lib/stdlib/caseStudy.doxa  # 158 declarations
```

Both files type-check with the current CLI.
