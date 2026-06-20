# Doxa Design Specification

Doxa is a dependently typed proof checker. It parses a surface language in the ML / Scala 3 family, type-checks it bidirectionally, and normalizes terms via Normalization by Evaluation. The name is from the ancient Greek δόξα (*doxa*), opinion or belief, as opposed to ἐπιστήμη (*epistēmē*), justified and validated knowledge: the latter is what a proof checker is built to establish.

## What is specific to Doxa

Doxa is measured against the Coq / Lean 4 / Agda bar on kernel features; where it diverges (K-freeness, no HoTT, no classical axioms in the kernel) the divergence is explicit and recorded. The kernel semantics are transcribed from the standard references; what is specific to this implementation is four choices about surface, platform, and engineering contract:

1. **ML/Scala-3-family surface syntax for CIC**: the surface is in the ML-family rather than the notation conventional to proof assistants, while retaining the semantic commitments of CIC with Prop.
2. **WasmGC-native compilation via dart2wasm**: the checker runs in the browser directly, not via extraction and retargeting.
3. **Linear-time structural-operations contract**: every kernel operation is O(N) in term size, enforced by `tool/stack_stress.dart`. Stack-safety with a super-linear path does not satisfy the contract; the harness measures both.
4. **Combinator parser on Rumil**: the surface parser is a combinator parser rather than a hand-rolled one. Application is parsed with Rumil's Pratt precedence combinator; Rumil also provides Warth seed-growth left recursion, and an equivalent left-recursive version is kept for comparison.

The rest (the CIC calculus, NbE, positivity, guardedness, pattern unification, singleton elimination, universe polymorphism, SProp) is inherited from the standard references catalogued in §9. The work is to transcribe those designs correctly into Doxa's surface, driver, and platform, not to re-derive them.

---

## 1. Scope

### 1.1 What the kernel is

Doxa is a CIC proof-checker kernel. The following are built and exercised
by the test suite:

- A **proof checker** for the Calculus of Inductive Constructions with predicative cumulative universes plus impredicative Prop (with definitional proof irrelevance).
- **Bidirectional** type inference / checking.
- **Normalization by Evaluation** with β, η, ι, and δ equivalence.
- **Stack safety and linear-time structural operations** under arbitrary evaluation depth, via a defunctionalized interpreter (§4.5). Every kernel path is O(N) in term size; stack safety without linear time is not enough, and the invariant is enforced by `tool/stack_stress.dart`.
- **Inductive types** with parameters, indices, strict positivity, structural recursion, and auto-synthesised recursors. Mutual `data` and mutual `fun` blocks.
- **Primitive pattern matching** with coverage + exhaustiveness checking, index-refinement-based unreachable-arm omission.
- **Metavariables + pattern unification** (Miller's decidable fragment) + implicit arguments.
- **Propositional equality** as an ordinary inductive, with auto-`refl` synthesis. K-free; intensional.
- A **standard library** (`Nat`, `Bool`, `List`, `Option`, `Vec`, `Eq` + derived lemmas) and a pinned set of canonical proofs, including `plus_comm`, list lemmas such as `map_compose`, refutation lemmas, and a theorem about an indexed family.
- **Error messages** that cite source locations, show the two terms that failed to convert with their user-written binder names (no placeholders), and locate the innermost difference.
- **Surface syntax in the ML / Scala 3 family**, free of proof-assistant-specific notational baggage.
- A **small, auditable** implementation: the kernel is under a reviewer's budget to read end-to-end.
- **dart2wasm compilation** producing a WasmGC artifact plus a browser harness.

### 1.1a Built extensions

The following features, originally listed as future directions in earlier
editions of this document, are now built and exercised by the test suite:

- **Universe polymorphism** (Lean 4-style per-declaration level variables,
  `LLevel`/`LVar`/`LMax`/`LSucc`/`LImax`). Library code is written once
  over any universe level.
- An additional **strict-propositions sort `SProp`** (Gilbert et al. 2019).
- **Records** as kernel primitives with definitional η (Lean 4 / Coq model).
- **Modules and imports** for multi-file programs.
- **Tactics**: a minimal engine (`intro`, `exact`, `apply`, `rewrite`,
  `induction`, `refl`, `trivial`) following the Agda reflection model.
- **Typeclass / instance search** on top of the metavariable unifier
  (Idris 2-style elaboration with Agda-style resolution).
- A **written tutorial** (`docs/tutorial.md`) aimed at an ML-family
  programmer with no prior proof-assistant experience.

### 1.1b Future directions

The kernel's architecture is shaped to admit these without a rewrite. They are
recorded as possible directions, not as commitments or a timeline.

- **Well-founded recursion** (termination metrics beyond structural
  recursion). Tactics can synthesize `Acc.rec` proof terms; a
  `termination_by` annotation and desugaring pass would make Euclid's
  algorithm and Ackermann writeable. No kernel changes needed.
- **Namespace-qualified modules** (`Nat.plus`, `Int.plus`). Currently
  imports use a flat namespace; qualification would remove collision risk
  as the stdlib expands.

### 1.2 Standard

Doxa is held to the standard of a full CIC implementation. Architectural decisions are made against the Coq / Lean 4 bar; no choice is accepted on the grounds that a smaller thing would be quicker to ship. When a decision has a principled answer that Lean or Coq validates, Doxa takes that answer and cites it (§9); when it diverges, the divergence is stated in the relevant section.

Where the work specific to Doxa sits:

- **Platform and surface**: the Wasm target, the ML-family syntax, and building the parser on Rumil.
- **Linear-time contract**: O(N) structural ops as a hard contract, enforced by a stress harness.
- **Kernel semantics**: inherited from the standard references (Coquand & Huet, Paulin-Mohring, Abel, Kovács, Miller, Gilbert et al.). See §9 for the full citation list and the mapping of design decisions to sources.

### 1.3 Permanent non-goals

Excluded from Doxa by design, not by sequencing:

- **Mutable state, effects, IO** in the object language. Doxa is total and pure.
- **Homotopy Type Theory, Cubical Type Theory, univalence.** Different kernel, different project.
- **Full higher-order unification.** Pattern fragment only, matching every production PA.
- **Classical axioms in the kernel** (LEM, choice, extensionality). Users may postulate these; the kernel stays axiom-free so constructivity is preserved.
- **Extraction to functional programming languages.** Coq's extraction is a separate phase from the kernel; if extraction is ever built, it lives elsewhere.

### 1.4 Branding

Doxa is a **proof checker**. The project name carries the philosophical gesture; no tagline beyond that.

---

## 2. Philosophy (as constraints)

Each principle forbids something concrete.

- **Transparency.** No phase of the pipeline may read input the user did not write (no implicit arguments, no auto-inserted coercions, no tactic scripts). What is checked is exactly what appears in the source.
- **Small kernel.** Every concept in the kernel must appear in this spec. A feature that requires new vocabulary not introduced here does not belong in the kernel: escalate to a spec revision.
- **Honest errors.** Every type error must cite (a) a source span, (b) the inferred type, (c) the expected type, (d) the step at which conversion failed. No error may say only "type mismatch."
- **Surface-aligned with the ML family.** Any surface-syntax decision must pick the familiar ML-family option unless there is a type-theoretic reason not to. A divergence is a bug report against this spec.

---

## 3. Core Calculus

Doxa's kernel is the **Calculus of Constructions** with a predicative cumulative universe hierarchy `Type 0 : Type 1 : Type 2 : ...`. Self-typed universes (`Type : Type`) are rejected because they admit Girard's paradox (Hurkens 1995).

### 3.1 The five core forms

The abstract kernel has exactly five term shapes. These are an *implementation* vocabulary; the surface syntax uses familiar names for each (§5). The mapping is:

| Kernel form | Surface spelling | Role |
|-------------|------------------|------|
| `Type n` | `Type` (level inferred) or `Type 0`, `Type 1` | Universe |
| `Var i` / `Free x` | identifier | Variable reference |
| `App f a` | `f(a)` | Application |
| `Lam (A) b` | `(x: A) => b` | Abstraction |
| `Pi (A) B` | `(x: A) -> B` | Dependent function type |

A non-dependent arrow `A -> B` is sugar for `(_: A) -> B` where `_` does not occur in `B`.

### 3.2 Variable representation: locally nameless

Bound variables use **De Bruijn indices**. Free variables retain their source names. This is the *locally nameless* style (Charguéraud 2012; the practical discipline goes back to McBride & McKinna 2004): it gives capture-free substitution mechanically while preserving names at binder sites for display and diagnostics.

Every binder (`Lam`, `Pi`) additionally carries an optional **name hint**: the source name the user wrote, preserved from parsing through elaboration, evaluation, and quoting. Name hints are purely diagnostic: they do not affect equality, conversion, or any semantic judgment. Their sole purpose is to render error messages and normal forms in the user's vocabulary rather than synthesized placeholders.

```
Term ::= Type of Nat
       | Bound of Nat                     -- de Bruijn index (bound occurrences)
       | Free  of String                  -- source name (free occurrences)
       | App   of Term * Term
       | Lam   of (String?) * Term * Term -- (name hint, domain, body)
       | Pi    of (String?) * Term * Term -- (name hint, domain, codomain)
```

The name hint is `null` when a binder has no source-level name: for example, the desugared non-dependent arrow `A -> B` carries no user-visible binder name. Pretty-printing falls back to synthesized names (`_a`, `_b`, …) only in these cases.

Two operations work over this:

- `open(t, x)`: replace `Bound 0` in `t` with `Free x`, decrementing deeper indices. Used when descending under a binder during checking.
- `close(t, x)`: replace `Free x` in `t` with `Bound 0`, incrementing deeper indices. Used when constructing a binder.

Evaluation never substitutes directly into syntax: see §4.

**Why do this up front?** Retrofitting names onto the kernel later is an API-breaking change affecting every `Lam`/`Pi` construction site, including tests and downstream tools. Users writing proofs with named binders expect error messages to reference those names. Seeing `a0 -> a1` where they wrote `A -> B` violates the SPEC §2 "honest errors" constraint in spirit, even when it satisfies the letter. Adding the hint field now is a small static cost with a large correctness and ergonomic payoff, and it removes a predictable future retrofit.

### 3.3 Typing rules

Contexts are ordered lists of `(x : A)`. Judgment: `Γ ⊢ t : A`.

```
                                                   (Ax_n)
                       Γ ⊢ Type n : Type (n+1)


           (x : A) ∈ Γ
           ───────────   (Var)
           Γ ⊢ x : A


      Γ ⊢ A : Type n       Γ, x:A ⊢ B : Type m
      ─────────────────────────────────────────  (Pi)
            Γ ⊢ (x : A) -> B : Type (max n m)


      Γ, x:A ⊢ b : B       Γ ⊢ (x:A) -> B : Type n
      ────────────────────────────────────────────  (Lam)
              Γ ⊢ (x : A) => b : (x : A) -> B


      Γ ⊢ f : (x : A) -> B       Γ ⊢ a : A
      ───────────────────────────────────────  (App)
              Γ ⊢ f(a) : B[x ↦ a]


           Γ ⊢ t : A         A ≡ B         Γ ⊢ B : Type n
           ──────────────────────────────────────────────   (Conv)
                            Γ ⊢ t : B
```

`≡` is definitional equality: α-, β-, and η-equivalence, strict on universe levels (`Type n ≡ Type m` iff `n = m`). See §4.3.

Definitional equality `≡` is strict on universe levels, but the Conv rule admits **cumulative subtyping**: `Type n ≤ Type (n+1)`, so a term in a lower universe is accepted where a higher one is expected. Subtyping is layered on top of `≡` rather than folded into it (see §8.3 for the full rule, including its covariant/contravariant behaviour under Pi).

### 3.4 The bidirectional algorithm

`check : Γ × Term × Value → Unit   (throws on failure)`
`infer : Γ × Term → Value`

- **check**: descend into `Lam` against a `Pi` expected type; for any other term, `infer` it and compare types via conversion.
- **infer**: handle `Type`, `Var`, `Pi`, `App`; lambdas without annotation cannot be inferred and are a type error.
- Every application checks its argument against the domain value, then computes the result value by applying the codomain closure.

The checker never does implicit conversion; the only conversion is the `Conv` rule and it uses `A ≡ B` exactly.

---

## 4. Evaluation: Normalization by Evaluation

Doxa uses **NbE**, not substitution-based reduction. `Term`s are *evaluated* into `Value`s against an environment; `Value`s are *quoted* back to `Term`s when syntactic form is needed (e.g., for error display or printing normal forms); `Value`s are *compared* directly for definitional equality.

### 4.1 Semantic values

```
Value ::= VType of Nat
        | VPi   of (String?) * Value * Closure  -- name hint, domain value, body closure
        | VLam  of (String?) * Value * Closure  -- name hint, domain value, body closure
        | VNeutral of Neutral                    -- stuck computation

Neutral ::= NVar of Level                 -- free variable by de Bruijn LEVEL
          | NApp of Neutral * Value       -- stuck application

Closure = { env : Env, body : Term }

Env     ::= ENil
          | ECons of Value * Env          -- head = de Bruijn index 0
```

`VLam` and `VPi` carry the **name hint** from the corresponding `TLam` / `TPi` through evaluation. The hint is purely diagnostic: it never affects `conv`, `apply`, or any semantic judgment. Quoting propagates the hint back to the `Term` representation, so pretty-printed output uses source names consistently.

`Env` is a persistent cons-list, not a `List<Value>`. Closures capture environments by reference and are shared across the evaluator; any representation that mutates or copy-extends on binding would either corrupt captured closures or take O(n) per β-reduction. A cons-list gives O(1) extension and O(index) lookup, shared structurally across every closure built from the same prefix. This is a correctness-relevant choice: the `Closure.env` field is immutable, and closures are safe to retain indefinitely.

Two things make NbE small:

1. **Closures carry environments**, so applying `VLam` is just `eval(body, arg :: env)`. No substitution into the body's syntax is ever performed.
2. **Neutrals** represent stuck computations: applications whose head is a free variable. Any time evaluation hits a free variable under an elimination form, it builds a `Neutral` and keeps going around it.

### 4.2 eval, apply, quote

```
eval : Term × Env → Value
  eval(Type n, _)              = VType n
  eval(Bound i, env)            = env[i]
  eval(Free x, _)               = VNeutral(NVar(levelOf x))
  eval(Lam(name, a, b), env)    = VLam(name, eval(a, env), {env, body: b})
  eval(Pi(name, a, b), env)     = VPi(name, eval(a, env), {env, body: b})
  eval(App(f, a), env)          = apply(eval(f, env), eval(a, env))

apply : Value × Value → Value
  apply(VLam(_, _, c), v) = eval(c.body, v :: c.env)
  apply(VNeutral n, v)     = VNeutral(NApp(n, v))
  apply(_, _)              = ERROR: ill-typed, unreachable post-checking

quote : Level × Value → Term        -- Level = depth of context, for fresh names
  quote(l, VType n)                      = Type n
  quote(l, VPi(name, a, c))              = Pi(name, quote(l, a),
                                              quote(l+1, apply(VLam(name, a, c), varAt l)))
  quote(l, VLam(name, a, c))             = Lam(name, quote(l, a),
                                              quote(l+1, apply(VLam(name, a, c), varAt l)))
  quote(l, VNeutral n)                   = quoteNeutral(l, n)

  where varAt(l) = VNeutral(NVar(l))
```

The `Level`-indexed `quote` uses **de Bruijn levels** (count from the root) for fresh variable generation, which is what keeps quoted terms capture-free without any gensym state. Name hints from `VLam` / `VPi` propagate into the produced `TLam` / `TPi`, so pretty-printing recovers the user's identifiers.

### 4.3 Conversion (definitional equality)

Definitional equality is **α-, β-, and η-equivalence**, strict on universe levels. Implemented directly on values:

```
conv : Level × Value × Value → Bool
  conv(l, VType n, VType m)                     = (n = m)
  conv(l, VPi(_, a1, c1), VPi(_, a2, c2))       = conv(l, a1, a2) ∧
                                                   conv(l+1, apply(VLam(_, a1, c1), varAt l),
                                                             apply(VLam(_, a2, c2), varAt l))
  conv(l, VLam(_, _, c1), VLam(_, _, c2))       = conv(l+1, apply(VLam(_, _, c1), varAt l),
                                                             apply(VLam(_, _, c2), varAt l))
  conv(l, VLam(_, _, c), v)                     = conv(l+1, apply(VLam(_, _, c), varAt l),
                                                             apply(v,                  varAt l))   -- η
  conv(l, v, VLam(_, _, c))                     = symmetric η
  conv(l, VNeutral n1, VNeutral n2)             = convNeutral(l, n1, n2)
  otherwise                                     = false
```

The η clauses handle `(x) => f(x) ≡ f` by applying both sides to a fresh variable and comparing bodies. Because evaluation has already done all the β-reduction possible, conversion at this point is structural up to η.

**Neither lambda domain types nor name hints are compared.** `VLam` carries its domain only so `quote` can reconstruct the surface form; the calculus itself determines a lambda's type from its enclosing Pi via the bidirectional check rule, not from the annotation. Comparing domains inside `conv` would reject η-equivalent lambdas with differently-written-but-equal annotations, which violates α-equivalence. The same reasoning applies to name hints: α-equivalence means `(x) => x ≡ (y) => y`, so the hint must not participate.

### 4.4 Why NbE over substitution

- **No substitution function**, hence no index-lifting bugs, historically the single most common class of bug in small CoC implementations.
- **Hot path is short-lived closure allocation**, which Rumil's benchmarks show WasmGC favoring ~2× over AOT native.
- **Established technique**: Agda and Idris 2 normalise via NbE-style eval/quote. (Lean 4 and Coq instead use lazy weak-head reduction with a definitional-equality check; Coq additionally offers a compiled NbE-style conversion.) Reading the Agda/Idris evaluators is direct skill transfer.
- **No bigger than substitution-based approaches**: the `Value` ADT pays for itself by removing substitution entirely.

The conceptual cost (two representations, syntax and semantics) is real but small and well-documented in the literature (Abel 2013; Kovács, elaboration-zoo).

### 4.5 Defunctionalized interpreter and stack safety

The pseudocode in §4.2 and §4.3 is written as direct recursion for clarity, but the kernel implements `eval`, `apply`, `conv`, and `quote` as a **defunctionalized interpreter**: a single loop that dispatches over the current term/value and an explicit control-stack of **frames** (sealed ADT). This is the same architecture Rumil uses for its parser interpreter, and for the same reason: arbitrarily deep β-reduction chains must not consume host stack.

Why this is a correctness issue, not an optimization:

- Church-encoded `Nat` exponentials (`two(two)(two)` etc.) produce β-reduction spines that are naturally hundreds to thousands deep. Doxa has no native `Nat`, so these encodings are the *normal* way to express numbers.
- The dart2wasm deployment target (§7.2) runs in browser tabs with smaller stacks than native.
- SPEC §6 requires every error to produce a structured diagnostic. A raw Dart `StackOverflowError` has no source span and no expected/actual types: it would violate that contract.

The direct-recursive pseudocode elsewhere in §4 is authoritative for *semantics*. The implementation realizes those semantics in a loop whose transitions are in one-to-one correspondence with the pseudocode rules. Concretely:

- `Frame` sealed ADT describes each "what to do next" continuation: finish an `App`, resume a `conv` on a `VPi` codomain, etc.
- A single mutable `List<Frame>` carries the control stack; evaluation is a `while (true) { ... }` loop.
- All recursion in `eval`, `apply`, `conv`, and `quote` goes through the frame stack. No method in the kernel calls itself transitively.

**Amplifying-iteration discipline.** Internal calls to the public API (`eval`, `quote`, `infer`, `apply`, `conv`) ARE permitted from inside the driver loop, but ONLY when the call's depth is bounded by the data-declaration shape (ctor arity, index count, etc.): not by user-program structural depth. A call that iterates over a user-program-depth-dependent structure (e.g. match arms × nested-match depth, recursor IHs × scrutinee depth) is forbidden: it grows the host stack linearly with that depth. Such sites must be rewritten using driver frames to keep host depth constant. Enforced at review time and by the stack-stress workloads. Two such violations (VMatch quote, recursor ι-reduction) were fixed by an audit and must not be reintroduced.

This means no fixed-size call stack imposes a limit on Doxa's semantics; the bounds are memory and time.

**Linear-time invariant.** Every structural operation on a term or value of size N runs in O(N) time, modulo the inherent non-linearity of β-reduction output (a reduction step may produce a result of size greater than N, and that cost is not pretended away). Concretely: `eval`, `quote`, `conv`, `infer`, `check`, and `nf` on an input of syntactic size N are bounded by c·N for some constant c. This is a stronger claim than stack safety alone: a stack-safe but time-quadratic kernel still hangs on inputs a linear-time one handles. The invariant covers structural operations, not the cost of β-reduction output noted above.

The invariant is enforced by the harness at `tool/stack_stress.dart`, which exercises every kernel path at depths up to 1,000,000 and is expected to land every workload in the 100-300 ms band. Any new super-linear behavior surfaces there before it reaches users. Focused regression pins at 10,000-100,000 depth live in the unit suite (`test/check_test.dart` "Stack safety of the checker" group): nested TLam infer, nested VMatch quote, and recursor ι-reduction on deep canonical scrutinees.

---

## 5. Surface Syntax

Designed to read like a small ML-family language. A programmer fluent in that family should be able to read Doxa immediately; the only new idea is that types can mention values.

### 5.1 Grammar (BNF)

```
program    ::= decl*

decl       ::= 'val' ident (':' type)? '=' expr
             | 'type' ident '=' type
             | 'fun' ident typeparams? '(' params ')' ':' type '=' expr
             | 'data' ident typeparams? ':' type '{' ctor (';' ctor)* ';'? '}'

ctor       ::= ident ':' type

typeparams ::= '[' ident (':' type)? (',' ident (':' type)?)* ']'
typeargs   ::= '[' expr (',' expr)* ']'
params     ::= (ident ':' type (',' ident ':' type)*)?

type       ::= expr                               -- types and terms share syntax

expr       ::= lambda
             | piType
             | app

lambda     ::= '(' ident ':' type ')' '=>' expr
             | '(' ident ')' '=>' expr            -- only in check mode

piType     ::= '(' ident ':' type ')' '->' expr
             | atom '->' expr                     -- non-dependent sugar

app        ::= atom atom*                         -- left-associative application

atom       ::= ident typeargs?                    -- ident optionally applied to type args
             | 'Type' nat?
             | '(' expr ')'

ident      ::= [a-zA-Z_][a-zA-Z0-9_]*
nat        ::= [0-9]+

comment    ::= '//' .* newline
             | '/*' .* '*/'                       -- nestable
```

The `typeargs` production introduces **type-level application at use sites**: `List[A]`, `Vec[A, n]`, `Eq[A] x y`. The brackets appear at atom position, attached to an identifier (the type being applied). Value-level application remains juxtaposition: `Vec[A] zero` is `(Vec applied to type A) applied to value zero`. The two layers are visually distinct so the reader can separate type-parameter positions from value-argument positions: an ergonomic aid that becomes load-bearing once inductive families like `Vec[A] (succ n)` appear.

### 5.2 Mapping to the kernel

| Surface | Kernel |
|---------|--------|
| `Type` | `Type n` with `n` solved by checker; defaults to level 0 |
| `Type k` | `Type k` |
| `x` | `Free x` or bound variable resolved by scope |
| `f x` | `App f x` |
| `f x y` | `App (App f x) y`, juxtaposition is left-associative |
| `List[A]` | `App List A`, type-level application at use sites |
| `Vec[A] n` | `App (App Vec A) n`, type-arg then value-arg |
| `(x: A) => b` | `Lam (A) (close b x)` |
| `(x: A) -> B` | `Pi (A) (close B x)` |
| `A -> B` | `Pi A (lift B)` where `B` does not mention `x` |
| `fun f[A: Type](x: A): A = x` | `val f: (A: Type) -> (x: A) -> A = (A) => (x) => x` |
| `data Nat : Type { zero : Nat; succ : Nat -> Nat; }` | registers `Nat` in the inductive-type registry; introduces `Nat`, `zero`, `succ` as top-level names (see §8.4) |

`fun` is pure sugar for `val` with a lambda on the right and a Pi on the left. Every surface program elaborates to a list of `val name : type = term` declarations.

### 5.3 Examples

```doxa
// Identity
fun id[A: Type](x: A): A = x

// Function composition
fun compose[A: Type, B: Type, C: Type](f: B -> C, g: A -> B): A -> C =
  (x) => f(g(x))

// Church-encoded Nat
type Nat = (A: Type) -> (A -> A) -> A -> A

val zero: Nat = (A) => (s) => (z) => z
val succ: Nat -> Nat = (n) => (A) => (s) => (z) => s(n(A)(s)(z))

val one:   Nat = succ(zero)
val two:   Nat = succ(one)
val three: Nat = succ(two)

// Church Bool
type Bool = (A: Type) -> A -> A -> A
val true_:  Bool = (A) => (t) => (f) => t
val false_: Bool = (A) => (t) => (f) => f
```

These are not library code; they are what the user writes. The whole standard vocabulary of pure CoC is available this way, and the limits of pure CoC (no induction principle, no structural recursion) are visible directly, which is the point.

### 5.4 Everyday Language: documentation only

The original "Everyday Language" story (Given / Every / Use) survives as **documentation prose** introducing CoC to newcomers:

> In Doxa, `(x: A) => b` is called a *given*: it says "given an `x` of type `A`, here is `b`." A type of the form `(x: A) -> B` is called an *every*: it says "for every `x` of type `A`, the result has type `B`." A function call `f(a)` is a *use* of `f` on `a`.

This keeps the pedagogical payoff without introducing new surface keywords. Users write `fun`, `=>`, `->` like any ML-family programmer; the prose reveals the Curry-Howard mapping underneath.

---

## 6. Error Reporting

Every error produces:

1. **Source span**: line and column of the offending term, derived from the byte-offset `DoxaSpan` carried on every surface AST node (see §5) or from Rumil's `ParseError` for parse failures.
2. **Kind**: one of the sealed error classes below.
3. **Expected vs actual**: for `TypeMismatch`, both types quoted back to surface syntax via `quote` and pretty-printed using the binder name hints preserved from the source (see §3.2).
4. **Conversion path and innermost mismatch**: for `TypeMismatch`, the structural path (e.g. "in the codomain of a Pi", "at the first argument of a neutral spine") from the outer expected/actual types to the innermost diverging sub-values.

### 6.1 Error kinds

**Parse errors:**
- `ParseError`: wrapped Rumil parse failure. Unexpected character / end of input / syntax error, with source location from Rumil.

**Elaboration errors** (after parse, before type checking):
- `UnresolvedName(name, span)`: an identifier does not name any binder or earlier top-level declaration.
- `DuplicateDeclaration(name, previousSpan, span)`: a top-level name was declared more than once.

**Check errors** (during type checking):
- `TypeMismatch(got, expected, innerMismatch)`: a term's inferred type does not convert with (and is not a subtype of) the expected type. Carries both values plus the `ConvMismatch` pointing at the innermost diverging pair. Universe-level discrepancies that even cumulative subtyping cannot bridge (e.g. a higher universe where a lower one is required) surface as this kind, with the inner mismatch being the two `VType` values.
- `NotAFunction(actualType)`: a term appears in function position but does not have a `Pi` type.
- `NotAType(actualType)`: a term appears in a type position (Pi domain, lambda annotation) but does not have a universe type.
- `UnexpectedFree(name)`: a `TFree` reached the checker or evaluator. This indicates an elaborator bug, not a user error; surfaced as a fatal internal error rather than a diagnostic.

### 6.2 Example output

```
error: type mismatch
  at input.doxa:4:17
  expected: (A: Type) -> A -> A
  actual:   (A: Type) -> A -> A -> A
  first difference at codomain:
    expected:  A -> A
    actual:    A -> A -> A
```

The user's binder names (`A` here) survive from source through elaboration, evaluation, and quote back to the diagnostic. Synthesized names (`_a`, `_b`, …) are used only where the source had no name: e.g., non-dependent arrow domains.

### 6.3 Implementation notes

The conversion path is computed by **walking the two values in parallel** from their common outer shape until they diverge. `conv` itself does not record the path: it returns only the innermost diverging pair (via `ConvMismatch`). A separate `diff` function takes the outer types and the inner mismatch and reconstructs the path. This keeps `conv` focused on the boolean judgment with short-circuit behavior, while diagnostic generation pays its cost only when an error is actually reported.

Pretty-printing of `Term` uses the name hints from §3.2. A synthesized-name generator is used as a fallback (for null hints or to avoid shadowing in unusual nested-binder cases).

---

## 7. Architecture

A single Dart package `doxa` on top of the `rumil` core. Not a subpackage of `rumil_expressions`, which is an unrelated arithmetic evaluator.

```
doxa/
  lib/
    src/
      term.dart        -- sealed Term ADT, open/close
      value.dart       -- sealed Value ADT, Closure, Neutral
      eval.dart        -- eval, apply, quote
      conv.dart        -- definitional equality on values
      check.dart       -- bidirectional check / infer
      parse.dart       -- surface parser built on rumil
      elab.dart        -- surface AST → kernel Term (desugars fun, ->, multi-arg calls)
      pretty.dart      -- Term → surface syntax (uses quote for values)
      error.dart       -- DoxaError sealed hierarchy with spans
    doxa.dart          -- public API
  bin/
    doxa.dart          -- CLI: doxa check FILE
  test/
    ...
```

### 7.1 Parser notes

Rumil's Pratt precedence combinator handles `app ::= atom atom*` (juxtaposition as a left-associative operator); Rumil's Warth seed-growth left recursion handles the same grammar directly and is kept for comparison. Pi-type parsing is right-recursive and handled straightforwardly. The parser produces a small surface AST distinct from the kernel `Term`; `elab.dart` performs the surface-to-kernel translation (including the `close` operation for binders, and multi-arg call desugaring).

### 7.2 Platform

- **Language:** Dart 3, sealed classes, exhaustive switch expressions for both `Term` and `Value` ADTs.
- **Primary deployment:** WebAssembly via dart2wasm. Doxa's allocation pattern (short-lived immutable nodes during parsing and short-lived closures during evaluation) matches the profile Rumil's benchmarks document as getting a consistent ~2× speedup on WasmGC.
- **Secondary deployment:** Native AOT for CLI use.

---

## 8. CIC kernel semantics

This section specifies the kernel semantics. The semantics here are the ones
the implementation realizes. Where design choices have standard reference
implementations (Coq, Lean 4, Agda), §9 cites them and the sub-sections here
explicitly note which source each decision follows.

### 8.1 Design constraints

Every feature below was evaluated against three constraints:

1. **No decision that paints us into a corner.** Sort representation, meta-context shape, binder discipline all have to compose with features added in later phases.
2. **Inherit kernel semantics from the standard references.** The CIC type theory is a solved problem at the level of Coq + Lean + Agda; the work is to transcribe correctly, not reinvent. Divergences are explicit and cited.
3. **Match the Doxa architectural invariants.** Linear-time structural ops (§4.5), defunctionalized driver, no host-stack recursion, ML-family surface syntax.

### 8.2 Core calculus: CIC with Prop

The kernel is the **Calculus of Inductive Constructions** with the standard impredicative `Prop` sort alongside the predicative `Type` hierarchy.

- `Prop` is a sort at universe level 0, **impredicative**: `(X: Prop) -> P X` has type `Prop`, not a higher universe. This matches Coq, Rocq, Lean 4, and the conventional CIC presentation.
- The `Type n` hierarchy is predicative and cumulative (§8.3).
- A Pi-type's sort follows the usual PTS rule: domain in Prop or Type, codomain in Prop → Prop; codomain in Type → Type (max of levels).
- **Prop is definitionally proof-irrelevant.** Two values whose types are in `Prop` convert unconditionally under `conv`, matching Lean 4's default. Rationale: composable proof terms want proof equality to hold by reflexivity, which removes a class of proof-obligation friction that Coq users (pre-SProp) routinely hit when working with propositional-equality-indexed data. In the implementation `conv` gains one dispatch arm: when both sides have a type in Prop, return success. The commitment is load-bearing: the stdlib proofs rely on it.
- **Prop-elimination restriction** (enforced by the match-checker, SPEC §8.5). Matching on a Prop-sorted scrutinee to produce a Type-sorted result is rejected by default; combined with definitional proof irrelevance this would be a direct path to inconsistency. The kernel accepts the **singleton-elimination exception**: Prop → Type elimination is admitted when the scrutinee's inductive has **at most one constructor AND that constructor has no informative args** (every non-parameter arg is either Prop-sorted or is an index, which doesn't carry informational content). The rule is stated generally and not specialised to any named inductive: it falls out for `Eq` (one `refl` ctor, zero informative args) but admits any inductive of the same shape uniformly. Matches the Lean 4 `inductive.cpp:elim_only_at_universe_zero` discipline.
- **Propositional extensionality (`funext`, `propext`) is not a kernel axiom.** Users who want it assume it as a postulate. Doxa remains conservatively axiom-free; extensionality is a user decision with user-visible provenance.

Why Prop is in the kernel despite adding complexity:
- It's the sort where the verification story lives. F*/Dafny/Liquid-Haskell-style refinements, extraction that strips proof baggage, and any Z3-like oracle tooling all assume a Prop/Type separation.
- Retrofitting Prop would touch every conversion rule and every elaboration decision; building it in from the start costs less than adding it once a stdlib exists.

### 8.3 Cumulativity

`Type n ≤ Type (n+1)` as a subtyping relation. Conversion under Pi covariantly in the codomain, contravariantly in the domain (standard).

- Definitional equality stays strict (`n = m`).
- Subtyping is used at the Conv rule and at application argument-against-domain checks.
- Universe levels are first-class values in the implementation (Level ADT with `LLevel`, `LVar`, `LSucc`, `LMax`, `LImax`), so the universe hierarchy is polymorphic. Library code is written once over any level.

Cumulativity is what makes the universe tower usable: without it, any Church-encoded program that wants to use its own type as a value forces the user to track explicit level annotations (see the `plus` note in `test/programs/positive/church_nat.doxa`).

### 8.4 Inductive types

New top-level declaration form:

```doxa
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
```

Each `data` introduces a type constructor (with parameters and optional indices), data constructors with declared types, and a derived dependent eliminator (the induction principle). Mutual `data` blocks are supported.

**Syntax notes.**

- **Type-level application uses `[...]` at use sites.** A parameterised inductive type is referenced as `List[A]`, `Vec[A] n`, `Eq[A] x y`: the brackets mark the type-parameter slots, following the same visual convention as the declaration site `data List[A: Type]`. This is the one place Doxa surface syntax diverges from pure juxtaposition: it layers the parameter position visually so the reader can distinguish "this is the type instantiated at A" from "this is the type applied to a value." Value-level application remains juxtaposition throughout: `Vec[A] n` reads as "the type `Vec[A]` applied to index `n`."
- **Constructor declarations are `;`-separated.** Each constructor is a name and a declared type; the `;` terminator keeps the grammar unambiguous without making newlines significant (matching §5.1's keyword-delimited discipline).
- **Constructor types are ordinary kernel types**: Pi-binders, arrows, and the inductive type being declared. No special syntax.

**Positivity check.** The kernel rejects any constructor whose argument types mention the inductive type being defined in a strictly-negative position. Standard CIC check, with nested-positivity support: each registered inductive carries a `paramsCovariant: List<bool>` tracking which parameters are strictly-positive in every ctor-arg type, and a ctor arg of shape `S[X]` (with `S` another inductive, covariant in its param) is accepted when `X` itself is strictly positive. Canonical examples (`data Tree { node : List[Tree] -> Tree }`, `data RoseTree[A] { node : A -> List[RoseTree[A]] -> RoseTree[A] }`) are admitted. Non-covariant slots (`NonCov[T]` where `NonCov` takes its param negatively) still reject the enclosing occurrence.

**Kernel terms.** New variants: `TData`, `TConstr`, `TMatch`. Values: `VData`, `VConstr`. Canonical `VConstr` reduces under `match`; neutral `VNeutral` inside a match keeps the match stuck.

**Known limitations.** Three gaps are documented and deliberately deferred rather than resolved:

1. **Header independence in mutual data blocks.** In `data A : B -> Type and data B : Type { ... }`, the header of `A` cannot reference the sibling `B`: pass-1 header elaboration runs against the outer `TopEnv` before sibling partials are registered, so `B` is `UnresolvedName` at that point. Interleaved header/signature elaboration (pass the header of `B` first when needed, or fix an order by strongly-connected-component analysis) resolves this. Deferred because (a) it is orthogonal to positivity and recursor synthesis, and (b) the right trigger is meta-variables, where signature interleaving becomes natural.

2. **Mutual-recursor reductions.** Each mutual `data` block member gets its own monomorphic `T.rec` binding, and cross-recursor calls (`A.rec` invoking `B.rec` on a sub-structure) are not wired as ι-reductions. Instead, `match` + structural recursion across mutual `fun` blocks lets users write cross-recursive programs directly as `fun f ... and fun g ...` calling each other via `match`. The block-wide StrictSubTerm relation (SPEC §8.6) admits calls from one member to another at strict sub-terms of the caller's designated argument. Cross-recursor ι-reductions on the mechanically-synthesised `T.rec` bindings remain unimplemented: they are not needed because `match` subsumes the use case.

### 8.5 Pattern matching (primitive)

`match` is a kernel primitive, not desugared to raw recursors. Rationale: dependent pattern matching (refinement of index values from constructor shape, e.g., matching `vnil` refines `n` to `zero` in the case body) is substantially harder to express via recursors, and every modern CIC system (Coq, Agda, Idris, Lean) has `match` primitive.

```doxa
fun plus(m: Nat, n: Nat): Nat =
  match m {
    case zero     => n
    case succ m_  => succ (plus m_ n)
  }
```

**Separator discipline.** Match arms take no separator. The `case` keyword is reserved, so it unambiguously terminates the previous arm; the `}` closes the block. `data` ctor lists use `;` because ctor signatures are type expressions that would otherwise run into one another; that grammatical need does not apply here.

**Optional motive annotation.** `match scrutinee returning P { ... }` lets the user write the motive explicitly. When omitted, the checker infers the motive from the expected type via a bounded form (the non-indexed constant motive, and indexed families whose motive is determined by first-order refinement of the scrutinee's indices). Unreachable cases inferred from index refinement (see below) are always allowed to be omitted regardless of whether the motive is explicit.

**Coverage.** Every constructor of the scrutinee's type must be handled (or a wildcard present). Missing cases → error. Extra cases → error. For indexed families, unreachable cases inferred from index refinement are allowed to be omitted.

**Dependent motive.** When the expected type of a match expression depends on the scrutinee, the motive is inferred from context via unification (see §8.8). For **indexed families** this is implemented: each arm refines the motive by first-order index unification (`vnil` refines `n := zero`, etc.). For **non-indexed** scrutinees (`Nat`, `List`) the dependent-motive case, where the goal type mentions the scrutinee value itself, as in induction proofs, is not yet inferred; such proofs are written with the auto-generated dependent eliminator `T.ind`/`T.rec`, which is logically complete (it is the full CIC induction principle, synthesized for every inductive). Closing the non-indexed dependent-`match` surface is a planned ergonomic extension; it is sugar that elaborates down to the eliminator and adds no trust to the kernel.

### 8.6 Structural recursion

Any recursive function must have a designated argument that structurally decreases on every recursive call: a syntactic sub-term of a pattern-bound variable. No termination hints; no user-facing "just trust me" flags. This is the CIC soundness requirement and the kernel enforces it.

- The guardedness check runs on elaborated kernel terms after type checking.
- For mutual recursion, a single argument per function in the block must decrease on mutual calls.
- Failure produces a `NonStructuralRecursion` diagnostic citing the offending call.

### 8.7 Let-bindings and mutual recursion

Local bindings use a block expression: a brace-delimited sequence of
`val` bindings (each terminated by `;`) ending in a result expression
that is the block's value:

```doxa
fun f(x: A): B = {
  val y: T = complicated x;
  val z: U = more y;
  finish z
}
```

The `val` keyword matches the sibling ML-family language's value-block
form; the result is implicit (no `in`/`return`), and a block must end
in an expression. A block desugars to a right-nested chain of the
kernel's `TLet` primitive. `TLet` is a real kernel node (not erased),
so definitional equality can unfold memoized local definitions without
re-evaluation, keeping the conversion check cheap.

Mutual recursion: `fun f(...) = ... and g(...) = ...` parses as a mutual block; both names are in scope in both bodies. Mutual `data` likewise.

### 8.8 Implicit arguments

`{A: Type}` (curly braces, to distinguish from explicit `[A: Type]`) introduces an implicit parameter. Call sites omit it; the checker solves for it via pattern unification.

```doxa
fun id{A: Type}(x: A): A = x

val sanity : Nat = id three   // A inferred to Nat
```

**Unification is pattern unification only**: a decidable fragment of higher-order unification that handles the cases that arise in practice. Full higher-order unification is undecidable; Doxa does not attempt it. When pattern unification cannot solve, Doxa emits an error (`AmbiguousMetavariable` or similar) asking the user for an explicit argument. Doxa never silently guesses.

**Meta-variables** are a first-class kernel concept: a term can contain unsolved metas, checking proceeds by accumulating constraints, and elaboration ends with all metas solved or a diagnostic. This infrastructure also powers the tactic engine (Phase 20).

### 8.9 Propositional equality

`Eq` is an **ordinary indexed inductive** in the standard library, declared in a prelude file loaded before user code:

```doxa
data Eq[A: Type] (x: A) : A -> Prop {
  refl : Eq[A] x x;
}
```

The kernel knows nothing specific about `Eq`. Its recursor `Eq.rec` is mechanically synthesized by the same §8.4 machinery that synthesizes `Nat.rec`, `List.rec`, `Vec.rec`. Its elimination into Type falls out of §8.2's general singleton-elimination rule (one constructor, zero informative args). This approach mirrors Lean 4's `Init/Prelude.lean:Eq` and Coq's `Init/Logic.eq`: neither kernel primitively knows about equality; both bootstrap it via a prelude.

**Why inductive rather than primitive.** An earlier draft proposed `TEq` / `TRefl` as primitive kernel term forms. An earlier review established that the primitive approach adds term forms, conversion cases, and walker branches without delivering anything the inductive path cannot. The inductive path is strictly smaller kernel surface and exercises infrastructure that is already hardened.

**Intensional, K-free, not HoTT.** Doxa's `Eq` is the standard Martin-Löf propositional equality: intensional (two equalities of the same type are not definitionally equal), K-free (Uniqueness of Identity Proofs is not derivable), non-cubical. Matches Agda's default and Lean 4's `Eq`; diverges from Coq's historical axiomatic K. The UIP-not-derivable property is a kernel guarantee. Homotopy Type Theory and Cubical variants are permanently out of scope (§8.12).

**Auto-`refl` synthesis (elaborator rule).** When check mode sees an expected type whose head is `Eq[A] x y` and `conv(A, x, y)` succeeds, the elaborator synthesizes `refl` as the term without requiring the user to write any argument plumbing. This is a pure elaboration rule, not a kernel rule: it resolves `Eq` by name at elaboration time, exactly as Lean's `mkEqRefl` / `Rfl` tactic resolves it. The kernel stays uniform over inductives; only the elaborator carries the hardcoded name.

**Eq at Prop sort.** Because `Eq`'s target sort is `Prop`, two proofs of the same equality (`p q : Eq[A] x y`) convert by the §8.2 Prop-irrelevance rule. `refl` synthesis is therefore automatic whenever the two sides are definitionally equal at A. This is load-bearing for the stdlib proofs over propositional predicates.

**Eq is universe-polymorphic.** The prelude declaration `data Eq[A: Type] (x: A) : A -> Prop` takes `A` at any universe level (the bare `Type` resolves to a fresh level variable). This means `Eq[SomeProp] p q` type-checks when `SomeProp : Prop`. UIP is **statable but not derivable** (matching Lean/Agda's K-free guarantee).

**`Eq.rec` and the J rule.** The synthesized recursor has shape:

```
Eq.rec : (A: Type) -> (x: A) -> (P: (y: A) -> Eq[A] x y -> Sort) ->
         P x (refl A x) -> (y: A) -> (p: Eq[A] x y) -> P y p
```

where `Sort` is `Prop` (general rule) or `Type n` (via singleton elimination). This is the full J rule restricted to non-indexed motives. The library's `subst`, `sym`, `trans`, `cong` are derived from `Eq.rec`, written in implicit style.

### 8.10 Standard library

A stdlib written as Doxa source, under `lib/stdlib/`. Not optional: a proof checker with no library cannot prove anything non-trivial.

- `Nat` with `plus`, `mult`, `pow`, `leq`.
- `Bool` with `and`, `or`, `not`, `if`.
- `List[A]` with `map`, `fold`, `filter`, `length`, `append`, `reverse`.
- `Option[A]` with `map`, `getOrElse`.
- `Eq` operators: `refl` (built in), `sym`, `trans`, `cong`, `subst`.
- Canonical proofs: `plus_zero`, `plus_succ`, `plus_comm`, `plus_assoc`, `mult_zero`, `append_nil`, `append_assoc`, `length_append`, `map_compose`; the refutation lemmas `succ_ne_zero` and `true_ne_false` (deriving `False` from an impossible equality); and `vlength_index`, a theorem about the indexed family `Vec` whose statement depends on the length index.

The stdlib is also the regression suite for the elaborator and checker: every file under `lib/stdlib/` must type-check on every commit.

### 8.11 Diagnostics for elaboration features

Each new feature adds a focused diagnostic:

- `PositivityViolation(dataName, ctorName, pos)`: constructor uses its own type non-strictly-positively.
- `NonExhaustiveMatch(missingConstructors)`: a case is missing.
- `RedundantMatchCase(ctor)`: a case is unreachable (for indexed families).
- `NonStructuralRecursion(fnName, callSite)`: recursive call not on a structural sub-term.
- `UnsolvedMetavariable(span)`: can't infer this implicit; please provide it.
- `AmbiguousUniverse(span)`: cumulativity has no unique solution.
- `MutualRecursionSortMismatch(block)`: mutual definitions don't all agree on sort.
- `PropEliminationIntoType(dataName, resultSort)`: match on a Prop-sorted inductive produced a Type-sorted result, and the inductive doesn't qualify for singleton elimination (§8.2: ≤ 1 ctor AND zero informative args). Combined with definitional proof irrelevance, admitting this shape is a soundness leak. Examples that qualify for singleton elim and DO NOT fire this diagnostic: `Eq`, `True`, `And` (conjunction of Props). Examples that fire: `Or` (two ctors), any `Prop`-level data with a Type-sorted arg.

All formatted through the reporter with the same span/diff/path treatment as the core diagnostics.

### 8.12 Permanent non-goals

See §1.3 for the project-level list. The items below are repeated here for convenience because they bear directly on kernel semantics:

- **Homotopy Type Theory, Cubical Type Theory, univalence.** Doxa's `Eq` is intensional and K-free (§8.9), not cubical. These are different kernels.
- **Full higher-order unification.** Pattern unification only (§8.8). Undecidable in general; no production proof assistant ships full HOU.
- **Classical axioms in the kernel.** Users may postulate LEM, choice, extensionality; the kernel does not bake them in.
- **Effects, IO, mutability in the object language.** Doxa is total and pure.

### 8.13 Documentation

A runnable, self-contained introduction lives in [`example/proofs.doxa`](example/proofs.doxa) (with `example/README.md`): declarations, inductive types, pattern matching, the ambient `Eq`, and proofs by computation and by induction. A longer prose tutorial (`docs/tutorial.md`) aimed at an ML-family programmer with no prior proof-assistant experience covers the full language, including tactics and typeclasses; every code block is verified against the checker.

---

## 9. Prior art acknowledged

Doxa's kernel semantics are inherited from the standard references listed here. Each feature is transcribed from a specific source, cited where the relevant section introduces it.

**Calculus, type theory, meta-theory:**
- Coquand & Huet 1988: the Calculus of Constructions. *Information and Computation* 76(2/3):95–120. [doi:10.1016/0890-5401(88)90005-3](https://doi.org/10.1016/0890-5401%2888%2990005-3)
- Coquand 1996: a type-checking algorithm for dependent types based on comparing normal forms. *Science of Computer Programming* 26(1–3):167–177. [doi:10.1016/0167-6423(95)00021-6](https://doi.org/10.1016/0167-6423%2895%2900021-6)
- Pierce & Turner 1998: local type inference, which popularised the synthesis-vs-checking (bidirectional) propagation discipline. POPL 1998:252–265. [doi:10.1145/268946.268967](https://doi.org/10.1145/268946.268967). Survey: Dunfield & Krishnaswami 2021, "Bidirectional Typing," *ACM Comput. Surv.* [doi:10.1145/3450952](https://doi.org/10.1145/3450952)
- Hurkens 1995: a simplification of Girard's paradox, the standard argument against a self-typed top sort. TLCA 1995:266–278. [doi:10.1007/BFb0014058](https://doi.org/10.1007/BFb0014058)
- Barendregt 1992: "Lambda Calculi with Types" (the lambda-cube and the sort-matrix typing rules), *Handbook of Logic in Computer Science* vol. 2, OUP. (Pure Type Systems: Berardi 1988, Terlouw 1989.)
- Paulin-Mohring 1993: inductive definitions and their elimination rules in Coq / CIC. TLCA 1993:328–345. [doi:10.1007/BFb0037116](https://doi.org/10.1007/BFb0037116)
- Coquand & Paulin 1990: inductively defined types over the Calculus of Constructions (the seed of CIC). COLOG-88, LNCS 417:50–66. [doi:10.1007/3-540-52335-9_47](https://doi.org/10.1007/3-540-52335-9_47)
- Sozeau & Tabareau 2014: universe polymorphism in Coq. ITP 2014. [doi:10.1007/978-3-319-08970-6_32](https://doi.org/10.1007/978-3-319-08970-6_32)
- Gilbert, Cockx, Sozeau & Tabareau 2019: definitional proof-irrelevance without K (the SProp sort). POPL 2019, PACMPL 3(POPL). [doi:10.1145/3290316](https://doi.org/10.1145/3290316)
- Cockx, Devriese & Piessens 2014: pattern matching without K. ICFP 2014. [doi:10.1145/2628136.2628139](https://doi.org/10.1145/2628136.2628139)

**Locally nameless + NbE architecture:**
- Charguéraud 2012: "The Locally Nameless Representation." *Journal of Automated Reasoning* 49(3):363–408. [doi:10.1007/s10817-011-9225-2](https://doi.org/10.1007/s10817-011-9225-2). Precursor: McBride & McKinna 2004, "Functional pearl: I am not a number — I am a free variable," Haskell Workshop 2004. [doi:10.1145/1017472.1017477](https://doi.org/10.1145/1017472.1017477)
- Abel 2013: "Normalization by Evaluation: Dependent Types and Impredicativity," habilitation thesis, LMU München. [PDF](https://www.cse.chalmers.se/~abela/habil.pdf)
- Kovács, elaboration-zoo: Haskell implementations of elaboration for dependently typed languages; the closest match for Doxa's defunctionalized driver. [github.com/AndrasKovacs/elaboration-zoo](https://github.com/AndrasKovacs/elaboration-zoo)

**Unification, metavariables, elaboration:**
- Miller 1991: the Lλ pattern-unification fragment. *Journal of Logic and Computation* 1(4):497–536. [doi:10.1093/logcom/1.4.497](https://doi.org/10.1093/logcom/1.4.497)
- Abel & Pientka 2011: higher-order dynamic pattern unification for dependent types and records. TLCA 2011:10–26. [doi:10.1007/978-3-642-21691-6_5](https://doi.org/10.1007/978-3-642-21691-6_5)

**Reference implementations studied:**
- Lean 4 kernel + elaborator (`src/kernel/`, `Lean/Elab/`, `Lean/Meta/`): the closest production CIC our kernel mirrors architecturally.
- Coq kernel (`kernel/univ.ml`, `kernel/inductive.ml`, `kernel/typing.ml`): reference for universe polymorphism, recursor synthesis, and conv strategies.
- Agda's termination checker and conversion algorithm: reference for structural recursion and NbE-style conversion.

**Parser substrate:**
- Rumil: parser combinators with a Pratt precedence combinator and Warth seed-growth left recursion, WasmGC-favourable.
