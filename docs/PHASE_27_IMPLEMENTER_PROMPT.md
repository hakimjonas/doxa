# Phase 27 — Documentation & Case Study Completion

## Situation

Phase 25.5 (complete sqrt2 proof) was deferred. `lib/stdlib/case_study.doxa` has
`even`, `twice`, `square`, and base-case parity facts (lines 1–43), but no
inductive lemmas and no main theorem. Phase 27 is the documentation phase. The
proof guide (`docs/proof-guide.md`) is meant to walk through the completed
proof. So Phase 27 bundles the 25.5 gap.

Phase 26 is done — the interactive REPL has `:goal`/`:step`/`:undo`/`:print`/
`:qed`/`:abort`. The tutorial needs a section on this.

**You must load the `domain-writing` skill before writing any documentation
prose.** The proof guide and tutorial are technical prose; the skill enforces
the project's prose conventions.

## Scope

1. Add arithmetic lemmas to `lib/stdlib/proofs.doxa`
2. Complete the sqrt2 proof in `lib/stdlib/case_study.doxa`
3. Write `docs/proof-guide.md`
4. Update `docs/tutorial.md`

## Part 1 — Arithmetic lemmas (`lib/stdlib/proofs.doxa`)

The sqrt2 proof needs properties of `mult` that do not exist yet. Add these
after the existing `plus_assoc` lemma (line 57). Each follows the same
induction-on-first-argument pattern as the existing proofs.

**1a. `mult_succ_right`** — expanding `mult m (succ n)`:

```
val mult_succ_right : (m: Nat) -> (n: Nat) ->
  Eq Nat (mult m (succ n)) (plus m (mult m n))
```

By induction on `m`. Uses `plus_comm`, `plus_assoc`, `refl`. Base `m = zero`:
both sides are `zero`. Step: `mult (succ m') (succ n) = plus (succ n) (mult m'
(succ n))`. By IH `mult m' (succ n) = plus m' (mult m' n)`. So LHS becomes
`plus (succ n) (plus m' (mult m' n))`. The RHS is `plus (succ m') (mult (succ
m') n) = plus (succ m') (plus n (mult m' n))`. Use `plus_comm` and `plus_assoc`
to match these forms. The explicit `sym_e`/`trans_e`/`cong_e` combinators are
available from proofs.doxa.

**1b. `mult_comm`** — commutativity:

```
val mult_comm : (m: Nat) -> (n: Nat) -> Eq Nat (mult m n) (mult n m)
```

By induction on `m`. Base: both sides `zero` (use `mult_zero` for the
RHS `mult n zero = zero`). Step: `mult (succ m') n = plus n (mult m' n)`.
By IH `mult m' n = mult n m'`. RHS `mult n (succ m') = plus n (mult n m')`
by `mult_succ_right`. Need `plus n (mult n m') = plus n (mult m' n)` via IH.
Then `plus n (mult m' n)` matches LHS.

**1c. `mult_assoc`** — associativity:

```
val mult_assoc : (m: Nat) -> (n: Nat) -> (p: Nat) ->
  Eq Nat (mult (mult m n) p) (mult m (mult n p))
```

By induction on `m`.

**1d. `mult_2`** — doubling:

```
val mult_2 : (n: Nat) -> Eq Nat (mult 2 n) (plus n n)
```

Where `2` is `succ (succ zero)`. Expand: `mult 2 n = plus n (mult 1 n) =
plus n n`. Direct via `mult_succ_right` and definitional unfolding. If
`mult_succ_right` is not yet available at this point (cyclic dependency),
prove directly with two `refl`/`trans_e` steps unfolding the definition of
`mult`.

Verify after each addition: `doxa check lib/stdlib/proofs.doxa` passes.

## Part 2 — sqrt2 proof (`lib/stdlib/case_study.doxa`)

Keep the existing lines 1–43. Append the proof after line 52 (after the
last comment block).

### 2a. Parity lemma — `even_square_implies_even`

Statement:

```
val even_square_implies_even : (n: Nat) ->
  Eq Bool (even (square n)) true_ -> Eq Bool (even n) true_
```

Prove the contrapositive: if `even n = false_` then `even (square n) = false_`.
This is structurally cleaner — induction on `n` with case analysis on the
`even` function's recursion pattern.

Approach:

Define a helper that encodes "odd":

```
fun odd(n: Nat) : Prop = Eq Bool (even n) false_
```

Then prove:

```
val odd_square_odd : (n: Nat) -> odd n -> odd (square n)
```

By induction on `n`:

- `n = zero`: `odd zero = Eq Bool (even zero) false_ = Eq Bool true_ false_`
  which is false. But we assume it as a hypothesis, so the implication
  vacuously holds? No — we need to derive `odd (square zero)`, which is
  `Eq Bool (even zero) false_` = `Eq Bool true_ false_`. From the hypothesis
  `odd zero` we get `Eq Bool true_ false_`. Using `true_ne_false` (from
  proofs.doxa:102) we derive `False`, then `odd (square zero)` by ex falso.

- `n = succ k`: Need `odd (succ k) -> odd (square (succ k))`. Expand:
  `even (succ k) = match even k { true_ => false_, false_ => true_ }`.
  If `odd (succ k)` means `even (succ k) = false_`, then from the match we
  get `even k = true_`. So `even k = true_`. Then `square (succ k) = mult
  (succ k) (succ k)`. We need `even (mult (succ k) (succ k)) = false_`.

  At this point we need a lemma about parity of products: if `a` is even and
  `a+1` is whatever, etc. The algebra here is:

  - `mult (succ k) (succ k) = plus (succ k) (mult k (succ k))`
  - `= succ (plus k (mult k (succ k)))`
  - So `even (succ (plus k (mult k (succ k)))) =` flips parity of the inner.

  This needs the arithmetic lemmas from Part 1.

Simplify: use a more direct induction that avoids heavy algebra.

Strategy: Induction on `n` with pattern matching on `even n`:

- **Case 1**: `even n = true_` (n even). Then `n = twice k` for some `k`.
  Square: `square (twice k) = mult (twice k) (twice k) = mult 4 (mult k k)`.
  `mult 4 (mult k k)` is even (divisible by 2). Done.

  Wait, this needs the lemma that `even n = true_` implies `n = twice k`.
  That is another lemma to prove.

- **Case 2**: `even n = false_` (n odd). Then `n = succ (twice k)` for some
  `k`. Square: `square (succ (twice k)) = plus (twice k) (succ (twice k)) + ...
  is odd. Done.

The "twice representation" approach needs lemmas about `twice`. Since
`twice(n) = plus n n`, and `mult 2 n = plus n n` (by `mult_2`), we have
`twice = mult 2`. So `even n = true_` means `n` is a multiple of 2.

**Simpler approach**: Direct induction on `n` with case analysis using the
`even` function's structure. The `even` function alternates:

```
fun even(n: Nat) : Bool = match n {
  case zero => true_
  case succ n_ => match even n_ {
    case true_ => false_
    case false_ => true_
  }
}
```

So:
- `even zero = true_`
- `even (succ zero) = false_`
- `even (succ (succ n)) = even n`

The key observation: `even (succ (succ n)) = even n`. This is definitional
(just unfold `even` twice). This gives the induction step for free.

So the induction for `odd_square_odd`:

- Base `n = 0`: `odd 0` is `even 0 = false_` = `true_ = false_`. From this
  assumption we derive `False` via a simple lemma `true_is_not_false` (or
  inline `true_ne_false (refl true_)`). Then anything follows.

  Actually, simpler: `odd 0` is `Eq Bool (even zero) false_`. But `even zero`
  reduces to `true_` definitionally. So `odd 0 = Eq Bool true_ false_`. We
  have `true_ne_false : Eq Bool true_ false_ -> False` from proofs.doxa.
  So from `odd 0` we get `False`, and from `False` we get `odd (square 0)`.

- Step `n = succ k`: Assume `odd (succ k) -> odd (square (succ k))`. The IH
  gives us `odd k -> odd (square k)`. Now `odd (succ k)` means `even (succ k)
  = false_`. By unfolding `even (succ k)`, this means `match even k {
  true_ => false_; false_ => true_ } = false_`. So the match arm must be
  `false_`, meaning `even k = true_`. So `even k = true_`, i.e., `odd k` is
  false.

  Now `square (succ k) = plus (succ k) (mult k (succ k))` (definition of
  `mult`). To compute `even` of this, we need the parity of the result. The
  direct computation:

  `even (square (succ k)) = even (mult (succ k) (succ k))`

  where `mult (succ k) (succ k) = plus (succ k) (mult k (succ k))`
  = `succ (plus k (mult k (succ k)))`. So:

  `even (succ (plus k (mult k (succ k)))) = not (even (plus k (mult k
  (succ k))))`.

  This is getting deep into arithmetic. The cleanest exit: state a small
  lemma `even_succ : (n: Nat) -> Eq Bool (even (succ n)) (not (even n))`,
  where `not` flips `true_`/`false_`. Then the parity of `succ k` is the
  negation of `even k`, etc.

Actually, the `even` function definition already encodes this alternation.
We should work WITH the definitional behavior of `even` rather than against
it.

**Revised approach — three small lemmas**:

```
// even (succ (succ n)) = even n  (definitional)
val even_succ_succ : (n: Nat) -> Eq Bool (even (succ (succ n))) (even n) = refl (even n)

// If even n = true_, then even (square n) = true_
val even_sq_even : (n: Nat) -> Eq Bool (even n) true_ -> Eq Bool (even (square n)) true_
  = Nat.ind (n => Eq Bool (even n) true_ -> Eq Bool (even (square n)) true_)
            (h => h)  // base: n=0, even(0)=true_, square(0)=0, even(0)=true_
            (k => ih => (h: Eq Bool (even (succ k)) true_) =>
              // even(succ k)=true_ means even k = false_ (from "alternating")
              // ...
            )
```

Hmm, this is getting involved. Let me step back and consider what is
actually provable with the current kernel and what is reasonable for 1 session.

**Practical plan for the sqrt2 proof**:

The implementer should judge what is feasible. The minimum deliverable is:
1. The `even_square_implies_even` lemma (or its contrapositive) by induction
2. The `sqrt2` theorem by induction on `n`

If the parity algebra proves too heavy, the implementer may add helper lemmas
to proofs.doxa as needed (`even_succ_succ`, helper about `plus` parity, etc.)
and import them in case_study.doxa.

The key constraint: `doxa check lib/stdlib/case_study.doxa` must pass.

### 2b. Main theorem — `sqrt2`

```
val sqrt2 : (n: Nat) -> (m: Nat) ->
  Eq Nat (square n) (mult 2 (square m)) -> Eq Nat n zero
```

By induction on `n`:

- `n = zero`: `refl zero`.

- `n = succ k`: assume `square (succ k) = mult 2 (square m)`.
  Need to derive `succ k = zero`. From `succ_ne_zero` we know
  `succ k = zero -> False`. So we need to derive `False` from the
  assumption.

  From `square (succ k) = mult 2 (square m)`:
  - RHS `mult 2 (square m)` is even (it equals `plus (square m) (square m)`
    by `mult_2`, and `even (plus x x) = true_` for all `x` — another lemma
    or direct reasoning).
  - So `even (square (succ k)) = true_`.
  - By `even_square_implies_even`, `even (succ k) = true_`.
  - Since `even (succ k) = true_`, we have `even k = false_` (by the
    alternating definition of `even`).
  - Now `succ k` is even, so `succ k = twice k'` for some `k'`. Actually:
    `succ k = succ (succ k')` for some `k'`, so `k = succ k'`.
  - Substituting: `square (succ k) = mult (succ (succ k')) (succ (succ k'))`.
  - With the algebra lemmas: `mult (succ (succ k')) (succ (succ k')) =
    mult 4 (mult (succ k') (succ k'))`.
  - So `mult 4 (mult (succ k') (succ k')) = mult 2 (square m)`.
  - Cancel factor 2: `mult 2 (mult (succ k') (succ k')) = square m`.
    That is, `square (succ k') = mult 2 (square m)` with `k' < succ k`?
    No — `k'` might not be smaller.

Wait, the descending induction needs `k' < succ k`. If `succ k = succ (succ
k')`, then `k = succ k'`, so `k' < k < succ k`. Yes, `k' < succ k`. Then
by the induction hypothesis on `k'`, we get `k' = zero`. But `k' = zero`
implies `succ k = succ (succ zero)`, which is not contradictory on its own.

The contradiction comes from an infinite descent: the assumption that
`a² = 2·b²` for some non-zero `a` would produce an infinite decreasing
sequence `a > a1 > a2 > ...`, which is impossible in `Nat`.

In Doxa, this is expressed using the `Acc` accessibility predicate (available
from the prelude). The statement becomes:

```
// For all n: Acc (λ a b => plus a (succ b) = n) (some measure)
```

This is complex. The simpler "Option A" suggested in the roadmap was:

> show that `∀ a b, a² ≠ 2·b²` by induction on `a`. This avoids
> Int, gcd, and rationals entirely. The proof is: if `a² = 2·b²`,
> then `a` is even, so `a = 2k`, so `4k² = 2b²` → `2k² = b²`,
> so `b` is even, so `a = 2a'` and `b = 2b'`, then descending
> induction on `a` yields contradiction.

This description uses subtraction-like reasoning (`4k² = 2b² → 2k² = b²`),
which needs integer arithmetic or `Nat` with careful case analysis.

**Simplest possible proof** (for the implementer to attempt):

Prove by regular induction on `a`:

```
val no_solution : (a: Nat) -> (b: Nat) ->
  Eq Nat (mult a a) (mult 2 (mult b b)) -> Eq Nat a zero
```

Induction on `a`:
- `a = 0`: trivial.
- `a = succ a'`: assume `mult (succ a') (succ a') = mult 2 (mult b b)`.
  - If `b = 0`: RHS = 0. LHS = `succ` of something (since `mult` with
    `succ a'` always produces `succ ...` when the second arg is `succ a'`
    and `succ a' > 0`). So `Eq Nat (succ ...) zero`, contradicting
    `succ_ne_zero`. So `a = 0`.
  - If `b = succ b'`: both sides are `succ ...`, we can "cancel succ"
    somehow? No — `mult` doesn't have that property.

This approach fails because `Nat` lacks a cancellation-by-succ lemma.

**Revised practical plan**: The implementer should aim for a proof that
works within Doxa's current capability. If the full descending-induction
proof is too involved, the fallback is:

1. Prove the parity lemma `even_square_implies_even`.
2. Use it to show: if `n² = mult 2 (m²)`, then `n` is even. Write `n = twice k`.
3. Substitute: `square (twice k) = mult 2 (square m)`.
4. With `square (twice k) = mult 4 (square k)`, we get `mult 4 (square k) =
   mult 2 (square m)` → `mult 2 (square k) = square m`.
5. Now `square m = mult 2 (square k)`, so `m` is also even: `m = twice l`.
6. Substitute: `square (twice l) = mult 4 (square l)`, so `mult 2 (square k)
   = mult 4 (square l)` → `square k = mult 2 (square l)`.
7. This gives us `k² = 2·l²` with `k < n` (since `n = 2k` and `n > 0`).
8. By induction hypothesis on `n`, this forces `k = 0`, so `n = 0`.
   Contradiction with `n = succ ...`.

This requires the lemma `square (twice n) = mult 4 (square n)`, and
careful inequality reasoning about `k < n` when `n = twice k` and `n > 0`.

The implementer has discretion to navigate the proof as they see fit, as long
as `doxa check lib/stdlib/case_study.doxa` passes and the proof is explained
in the proof guide.

## Part 3 — Proof guide (`docs/proof-guide.md`)

Write a new file. The content must be written under the `domain-writing` skill
(no AI-language tells, precise notation, em-dash-free). Structure:

```markdown
# Doxa Proof Guide — sqrt(2) is irrational (on Nat)

## Overview

The proof shows that `n² = 2·m²` has no non-trivial solution in natural
numbers. This is the arithmetic core of the classical proof that √2 is
irrational. The proof works directly on `Nat` by induction and parity,
without fractions or coprimality.

**Strategy:**

1. Prove arithmetic lemmas needed for equational reasoning with multiplication
   (`mult_comm`, `mult_assoc`, `mult_succ_right`, `mult_2`).

2. Prove `even_square_implies_even`: if `n²` is even then `n` is even.
   Proved by induction on `n`.

3. Prove `sqrt2`: if `n² = 2·m²` then `n = 0`. By induction on `n`.
   The step case uses lemma 2 to extract a smaller counterexample,
   contradicting the induction hypothesis.

## 1. Arithmetic lemmas

[Statement and brief explanation of each lemma from Part 1.
Reference `lib/stdlib/proofs.doxa`.]

## 2. Lemma: even square implies even

**Statement:**
```
val even_square_implies_even : (n: Nat) ->
  Eq Bool (even (square n)) true_ -> Eq Bool (even n) true_
```

**Proof.** [Step-by-step walkthrough. Explain the induction motive,
the base case, and the step case. Show how `even`'s alternating
definition drives the induction.]

## 3. Theorem: no non-trivial square doubles

**Statement:**
```
val sqrt2 : (n: Nat) -> (m: Nat) ->
  Eq Nat (square n) (mult 2 (square m)) -> Eq Nat n zero
```

**Proof.** [Step-by-step. Explain the descent argument, the use of
`even_square_implies_even` to extract evenness, and how the induction
hypothesis closes the descending chain.]

## 4. The irrationality of √2

[Explain how the Nat theorem maps to the classical proof: if √2 = a/b
in lowest terms, then a² = 2b² on Nat, forcing a = 0, contradiction.]

## Verification

`doxa check lib/stdlib/case_study.doxa` type-checks every lemma and
the main theorem.
```

The proof guide must:
- Match the actual code exactly. Do not describe fictional syntax or
  capabilities.
- Use the file-based `Nat.ind` / `Eq.rec` style throughout, since
  `induction` and `rewrite` tactics are not yet available.
- Every code block must appear verbatim in `case_study.doxa` (or reference
  the proofs.doxa lemmas by import).

## Part 4 — Update `docs/tutorial.md`

Make three changes to the existing tutorial. Preserve all existing content.

### 4a. Section 1 (Getting started), around line 23

After the existing `dart run doxa check myfile.doxa` line, add:

```
dart run doxa repl       # interactive proof mode
```

### 4b. New section: "9b. Interactive proof mode"

Insert after the existing section 9 (Tactics, ends at line ~252). Use
the `domain-writing` skill for prose.

```markdown
## 9b. Interactive proof mode

The REPL (`doxa repl`) supports step-by-step proof construction.
Start a proof, apply tactics one at a time, inspect the goal, undo
mistakes, and commit the result.

### Starting a proof

```
> :goal theorem idProof : (A: Type) -> A -> A
Goal:
  (A: Type) -> A -> A
```

### Applying tactics

```
> :step intro A
Introduced A.
Goal:
  A -> A
Context:
  A : Type

> :step intro x
Introduced x.
Goal:
  A
Context:
  x : A
  A : Type

> :step exact x
Goal solved. Use :qed to commit.
```

### Inspecting and undoing

```
> :print
λ A : Type. λ x : A. x

> :undo
Undone.
Goal:
  A
Context:
  x : A
  A : Type
```

### Finishing

```
> :qed
idProof : (A: Type) -> A -> A
```

### Commands

| Command | Action |
|---------|--------|
| `:goal theorem n : T` | Start an interactive proof |
| `:goal` (in proof)    | Show current goal and context |
| `:step intro [name]`  | Introduce a Pi binder |
| `:step exact e`       | Provide an explicit proof term |
| `:step apply f`       | Apply a lemma (conclusion must match exactly) |
| `:step refl`          | Close `Eq[A] x x` goals |
| `:step trivial`       | Try refl, then context lookup |
| `:undo`               | Revert the last step |
| `:print`              | Show the proof term so far |
| `:abort`              | Abandon the proof |
| `:qed`                | Commit the proof and add it to scope |

The file-based syntax `by { intro x; exact x }` is always available.
For induction proofs and rewriting, use the file-based `Nat.ind` /
`Eq.rec` style (see the [proof guide](proof-guide.md)).
```

### 4c. Section 16 (Next steps), around line 409

Add two items to the bullet list, after the existing items:

```
- The [proof guide](proof-guide.md) walks through a complete proof that
  √2 is irrational, using induction on natural numbers.
- The [interactive proof mode](#9b-interactive-proof-mode) lets you
  construct proofs step by step in the REPL.
```

## Verification

After implementation, verify:

1. `doxa check lib/stdlib/proofs.doxa` — passes (existing 42 declarations
   plus new arithmetic lemmas).
2. `doxa check lib/stdlib/case_study.doxa` — passes (foundations plus
   new lemmas and theorem).
3. `dart test` in `doxa/` and in `doxa_tooling/` — full suite passes.
4. `dart analyze` — clean on all changed files.
5. Proof guide code blocks match `case_study.doxa` exactly.
6. Tutorial code blocks type-check (all are self-contained programs).

## Invariants

- The proof guide never claims interactive steps that the current REPL
  cannot handle. No `:step induction`, no `:step rewrite`.
- The tutorial's existing 16 sections keep their numbering and content.
  New material goes in as a subsection.
- No kernel or tooling code changes. This is documentation and stdlib only.
- `domain-writing` skill is used for all new prose.
