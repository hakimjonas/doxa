# Phase 27g — Write `nat_wf` and `sqrt2` into `case_study.doxa`

## Situation

Two kernel fixes are in place (from 27e and 27f):

1. **Enriched teleenv** (elab.dart:2854-2900) — in `_elabMatch`, constructor arg types
   use actual scrutinee index values for index-corresponding args, letting `R a m`
   β-reduce to `Lt a m` when computing `f`'s type inside match arms.

2. **Reversed-spine `_tryUnify`** (eval.dart:5142-5192) — accepts reversed canonical
   spine from `_insertImplicits`, allowing `acc_intro`'s implicit `A` to unify with
   `Nat` even when `Lt.rec` appears in the third argument.

With both fixes, `nat_wf` + `nat_wf_help` (mutual block with `{struct h}`) and the
`sqrt2` descent using `Acc[Nat].rec` compile.

The parity lemmas in `case_study.doxa` are verified (88 declarations):
`even_double`, `even_plus_parity`, `even_square_eq`, `even_square_implies_even`,
`succ_inj`, `sqrt2_parity`.

## Deliverables

1. Add `Lt`, `nat_wf`, `nat_wf_help` to `case_study.doxa`
2. Add algebraic lemmas: `half`, `even_implies_double`, `mult_2_inj`, `square_double`,
   `mult_4_eq`, `lt_succ_right`, `lt_half`
3. Add `sqrt2` using `Acc[Nat].rec` with `nat_wf`
4. Update `docs/proof-guide.md`
5. Verify: `doxa check`, full test suite, `dart analyze`

## 1. `Lt` and `nat_wf`

Add after the `succ_inj` lemma (existing line ~270). The relation uses the
**val-based inline lambda** `((x: Nat) => (y: Nat) => Lt x y)` — a `val` lambda
β-reduces immediately, avoiding the `VFun` stuck-on-neutral issue that `fun lt_rel`
has. The `Acc` implicit argument is passed via `Acc[Nat]` with square brackets.

```doxa
// ---- Well-founded ordering on Nat ----

data Lt : Nat -> Nat -> Prop {
  lt_succ : (n: Nat) -> Lt n (succ n);
  lt_trans : (n: Nat) -> (m: Nat) -> (k: Nat) -> Lt n m -> Lt m k -> Lt n k;
}

// ---- Well-foundedness: every Nat is accessible under Lt ----

fun nat_wf(n: Nat) : Acc[Nat] ((x: Nat) => (y: Nat) => Lt x y) n = match n {
  case zero => acc_intro ((x: Nat) => (y: Nat) => Lt x y) zero
    ((y: Nat) => (h: Lt y zero) =>
      Lt.rec
        ((a: Nat) => (b: Nat) => (_: Lt a b) =>
          Eq Nat b zero -> Acc[Nat] ((x: Nat) => (y: Nat) => Lt x y) a)
        ((w: Nat) => (eq: Eq Nat (succ w) zero) =>
          False.rec ((_: False) => Acc[Nat] ((x: Nat) => (y: Nat) => Lt x y) w)
            (succ_ne_zero w eq))
        ((a: Nat) => (m: Nat) => (k: Nat) =>
          (p1: Lt a m) => (p2: Lt m k) =>
          (ih1: Eq Nat m zero -> Acc[Nat] ((x: Nat) => (y: Nat) => Lt x y) a) =>
          (ih2: Eq Nat k zero -> Acc[Nat] ((x: Nat) => (y: Nat) => Lt x y) m) =>
          (eq: Eq Nat k zero) =>
            match ih2 eq {
              case acc_intro _ _ f => f a p1
            })
        y zero h (refl zero))
  case succ k => acc_intro ((x: Nat) => (y: Nat) => Lt x y) (succ k)
    ((y: Nat) => (h: Lt y (succ k)) => nat_wf_help k y h)
} and nat_wf_help(k: Nat, y: Nat, h: Lt y (succ k)) : Acc[Nat] ((x: Nat) => (y: Nat) => Lt x y) y {struct h} =
  match h {
    case lt_succ y_ => nat_wf y_
    case lt_trans y_ m c p1 p2 => nat_wf_help k m p2
  }
```

**Key points:**
- `Acc[Nat]` with square brackets, not `Acc Nat`.
- `((x: Nat) => (y: Nat) => Lt x y)` is a `val`-style lambda, not a `fun`.
  This β-reduces immediately to `VData("Lt", ...)`, avoiding the `VFun`
  stuck-on-neutral issue.
- `{struct h}` goes after the return type, before `=`.
- `and nat_wf_help(...)` — no `fun` keyword before `and` members.
- `Lt.rec` without an extra `Nat` argument; the motive is the first argument.
- `match ih2 eq { case acc_intro _ _ f => f a p1 }` — the `f a p1` call
  works because the enriched teleenv provides actual `R`/`x` values to `f`'s
  type computation.

## 2. Algebraic lemmas

Add after `nat_wf_help`.

### `half` and `even_implies_double`

```doxa
fun half(n: Nat) : Nat = match n {
  case zero => zero
  case succ zero => zero
  case succ (succ n_) => succ (half n_)
}

// If n is even, then n = 2 · (half n).
// Proved by induction on n.
val even_implies_double : (n: Nat) -> Eq Bool (even n) true_ ->
  Eq Nat n (mult (succ (succ zero)) (half n))
```

**Proof sketch**: induction on `n`.
- `n = 0`: both sides `0`, `refl zero`.
- `n = succ k`: `even (succ k) = true_` means `even k = false_`. So `k ≠ 0`
  and `k = succ p`. Then `n = succ (succ p)`, `half n = succ (half p)`.
  `mult 2 (succ (half p)) = succ (succ (mult 2 (half p)))` (by def of `mult 2`).
  Need `even p = true_` and by IH `p = mult 2 (half p)`. Then the equality
  follows.

- `n = succ 0`: `even 1 = false_ ≠ true_`, so premise is `False`.
  From `False`, the goal follows via `False.rec`.

### `mult_2_inj`

```doxa
// mult 2 is injective on Nat:  2a = 2b  →  a = b.
// Proved by induction on a, using mult_2, succ_inj, and IH.
val mult_2_inj : (a: Nat) -> (b: Nat) ->
  Eq Nat (mult (succ (succ zero)) a) (mult (succ (succ zero)) b) -> Eq Nat a b
```

**Proof sketch**: induction on `a`.
- `a = 0`: `0 = mult 2 b`. If `b = 0`, `refl zero`. If `b = succ b'`,
  `mult 2 (succ b') = succ(succ(plus b' b')) ≠ 0` → contradiction via
  `succ_ne_zero`.
- `a = succ k`: `mult 2 (succ k) = succ(succ(plus k k))`. By case on `b`:
  - `b = 0`: `succ(succ(plus k k)) = 0` → contradiction.
  - `b = succ l`: both sides `succ(succ(plus ...))`. By `succ_inj` twice:
    `plus k k = plus l l`. But `plus k k = mult 2 k` and `plus l l = mult 2 l`
    by `mult_2`. So `mult 2 k = mult 2 l`. By IH: `k = l`. So `succ k = succ l = b`.

### `mult_4_eq`

```doxa
// 4·a = 2·(2·a)
// Uses mult_2, plus_assoc, plus_comm.
val mult_4_eq : (a: Nat) ->
  Eq Nat (mult (succ (succ (succ (succ zero)))) a)
         (mult (succ (succ zero)) (mult (succ (succ zero)) a))
```

**Proof sketch**: expand both sides to `plus (plus a a) (plus a a)`.
- LHS: `mult 4 a = plus a (mult 3 a) = plus a (plus a (mult 2 a))`
  `= plus a (plus a (plus a a))`. By `plus_assoc`: `plus (plus a a) (plus a a)`.
- RHS: `mult 2 (mult 2 a) = plus (mult 2 a) (mult 2 a) = plus (plus a a) (plus a a)`.
  Both sides equal the same expression.

### `square_double`

```doxa
// square (2·p) = 4·(square p)
// Uses mult_assoc, mult_comm, mult_4_eq.
val square_double : (p: Nat) ->
  Eq Nat (square (mult (succ (succ zero)) p))
         (mult (succ (succ (succ (succ zero)))) (square p))
```

**Proof sketch**: 
`square (mult 2 p) = mult (mult 2 p) (mult 2 p)`
`= mult 2 (mult p (mult 2 p))`                    [mult_assoc]
`= mult 2 (mult (mult p 2) p)`                    [mult_comm p (mult 2 p)? no]
`= mult 2 (mult 2 (mult p p))`                     [mult_comm p 2]
`= mult 4 (square p)`                              [mult_4_eq]

The detailed algebra: `mult (mult 2 p) (mult 2 p)`
`= mult (mult 2 p) (mult 2 p)` 
= by `mult_comm (mult 2 p) 2`: wait, no.

Use `mult_assoc 2 p (mult 2 p)`:
`mult (mult 2 p) (mult 2 p) = mult 2 (mult p (mult 2 p))`.
Then `mult p (mult 2 p) = mult (mult p 2) q?` Hmm.

Actually: `mult p (mult 2 p) = mult p (mult 2 p)`.
By `mult_comm p 2`: `mult 2 p = mult p 2`. So `mult p (mult p 2)` = `mult (mult p p) 2` by `mult_assoc p p 2`.
Then `mult 2 (mult (mult p p) 2) = mult 2 (mult 2 (mult p p))` by `mult_comm ...`.

Simplify: `mult 2 (mult 2 (square p)) = mult 4 (square p)` by `mult_4_eq (square p)`.

### `lt_succ_right`

```doxa
// If n < m then n < succ m.
val lt_succ_right : (n: Nat) -> (m: Nat) -> Lt n m -> Lt n (succ m) =
  (n: Nat) => (m: Nat) => (h: Lt n m) =>
    lt_trans n m (succ m) h (lt_succ m)
```

### `lt_half`

```doxa
// If h > 0, then Lt h (mult 2 h).
// Proved by case analysis on h.
val lt_half : (h: Nat) -> Eq Bool (even h) true_ -> Eq Nat h zero -> Lt h (mult 2 h) =
  (h: Nat) => (eh: Eq Bool (even h) true_) => (nz: Eq Nat h zero) =>
    False.rec ((_: False) => Lt h (mult 2 h))
      (true_ne_false
        (trans_e Bool (even h) (even zero) true_
          eh
          (sym_e Bool true_ (even zero) (refl true_))))
```

The `lt_half` lemma above is wrong. The implementer should instead prove
`Lt (succ k) (mult 2 (succ k))` for any `k` — this is the actual needed
inequality for the descent when `h > 0`. Construct:

```
val lt_half_succ : (k: Nat) -> Lt (succ k) (mult 2 (succ k))
```

By constructing `mult 2 (succ k) = succ (succ (mult 2 k))`:
`lt_succ (succ k) : Lt (succ k) (succ (succ k))`
`lt_trans` with repeated `lt_succ` builds `Lt (succ k) (mult 2 (succ k))`.

## 3. `sqrt2`

Add after the algebraic lemmas:

```doxa
// ---- Theorem: n² = 2·m²  -->  n = 0 ----
//
// Proved by well-founded induction on n using nat_wf (Acc[Nat].rec).
// From n² = 2·m², sqrt2_parity gives even n = true_.
// If n = 0, done. Otherwise n = succ (succ p) with even p = true_.
// By even_implies_double: p = mult 2 h.
// Algebra:
//   square n = square (mult 2 h) = mult 4 (square h)         [square_double]
//            = mult 2 (mult 2 (square h))                    [mult_4_eq]
// Since square n = mult 2 (square m):
//   mult 2 (mult 2 (square h)) = mult 2 (square m)
//   mult 2 (square h) = square m                             [mult_2_inj]
//   even m = true_                                           [sqrt2_parity m (square h)]
//   m = mult 2 h'                                            [even_implies_double]
//   mult 2 (square h) = square (mult 2 h')                   [m = mult 2 h']
//                      = mult 4 (square h')                  [square_double]
//                      = mult 2 (mult 2 (square h'))          [mult_4_eq]
//   square h = mult 2 (square h')                            [mult_2_inj]
// Since h < n (by lt_half), IH gives h = 0, hence n = 0.

val sqrt2 : (n: Nat) -> (m: Nat) ->
  Eq Nat (square n) (mult (succ (succ zero)) (square m)) -> Eq Nat n zero =
  (n: Nat) => (m: Nat) =>
  (h_eq: Eq Nat (square n) (mult (succ (succ zero)) (square m))) =>
    Acc[Nat].rec ((x: Nat) => (y: Nat) => Lt x y)
      ((x: Nat) => (m: Nat) ->
        Eq Nat (square x) (mult (succ (succ zero)) (square m)) -> Eq Nat x zero)
      ((x: Nat) =>
        (f_acc: (y: Nat) -> ((x: Nat) => (y: Nat) => Lt x y) y x ->
          Acc[Nat] ((x: Nat) => (y: Nat) => Lt x y) y) =>
        (ih: (y: Nat) -> ((x: Nat) => (y: Nat) => Lt x y) y x -> (m: Nat) ->
          Eq Nat (square y) (mult (succ (succ zero)) (square m)) -> Eq Nat y zero) =>
        (m: Nat) =>
        (hx: Eq Nat (square x) (mult (succ (succ zero)) (square m))) =>
          match x {
            case zero => refl zero
            case succ k =>
              // even x = true_  by sqrt2_parity
              let ev_x : Eq Bool (even (succ k)) true_ =
                sqrt2_parity (succ k) m hx
              in
              // even k = false_
              // so k ≠ 0, hence k = succ p
              // then x = succ (succ p), even p = true_
              // p = mult 2 h  by even_implies_double
              //
              // ... descent algebra as sketched above ...
              //
              refl zero
          })
      n (nat_wf n) m h_eq
```

**The descent step (to be filled in by the implementer):**

The implementer fills the `case succ k => ...` branch. The key algebraic
chain uses:
- `even_succ_flip k` to get `even k = false_` from `ev_x`
- Case analysis on `k`:
  - `k = 0`: `even 0 = true_ ≠ false_`, derive `False` via `even_0` + `true_ne_false`
  - `k = succ p`: then `x = succ (succ p)`
- `even_succ_succ_eq_even p` to get `even p = even (succ (succ p)) = even x = true_`
- `even_implies_double p` to write `p = mult 2 h`
- `square_double h` + `mult_4_eq` + `mult_2_inj` for the algebra
- `lt_half_succ h` (or `lt_succ_right`) to show `Lt h x`
- `ih h (lt ...) h' eq_h` to get `h = 0`
- Then `p = 0`, so `x = succ (succ 0) = 2`
- `square 2 = 4 = mult 2 (square m)` → `square m = 2` → impossible → `False.rec`

**If the algebra proves too time-consuming**, the implementer may add
`even_implies_double`, `mult_2_inj`, `square_double`, and `mult_4_eq`,
then write `sqrt2` to the point where the descent algebra uses these
lemmas. The exact `trans_e`/`cong_e` chains follow the same pattern as
`even_double` and `even_square_eq`. Each lemma is ~15-30 lines of
equation chaining.

## 4. Proof guide

Update `docs/proof-guide.md`:

- Add section documenting `Lt`, well-foundedness, and the `nat_wf` proof.
- Add section documenting the algebraic lemmas and the `sqrt2` descent
  argument.
- Update the verification section with the current `doxa check` output.
- Ensure all code blocks match the actual `case_study.doxa` content.

Use the `domain-writing` skill for all prose.

## 5. Verification

```
doxa check lib/stdlib/case_study.doxa    # all declarations pass
doxa check lib/stdlib/proofs.doxa        # 61 declarations pass
dart test in doxa/ and doxa_tooling/      # 452 + 520 pass
dart analyze clean on all changed files
```

## Order of implementation

1. Add `Lt`, `nat_wf`, `nat_wf_help` — test immediately
2. Add `half`, `even_implies_double` — test
3. Add `lt_succ_right`, `lt_half_succ` — test
4. Add `mult_2_inj`, `square_double`, `mult_4_eq` — test
5. Add `sqrt2` with descent — test
6. Update proof guide
7. Full test suite

## Known syntactic pitfalls

- `Acc[Nat]` with square brackets (implicit `A`), not `Acc Nat`.
- `((x: Nat) => (y: Nat) => Lt x y)` is a `val`-style inline lambda.
- `{struct h}` goes after the return type, before `=`.
- `and nat_wf_help(...)` — no `fun` keyword before `and` members.
- `Lt.rec` without an extra `Nat` argument.
- `match ... { case acc_intro _ _ f => ... }` — `acc_intro` not `Acc.acc_intro`.
- `False.rec` for `Prop`-sorted results, `False.rect` for `Type`-sorted.
- `Acc[Nat].rec` — square brackets for the implicit `A`.
