# Doxa Implementation Plan

Phased plan targeting a single feature-complete Doxa release (see SPEC.md §1.1). Each phase has a concrete exit criterion — something you can test or demo — so progress is visible without guessing.

**Release model.** Doxa ships ONCE. Phases are purely internal sequencing markers — they do not correspond to public versions. Nothing goes out until the full feature set is in, stabilised, and polished.

**Ordering discipline.** Early phases (0–7) establish the kernel architecture on hand-built terms before the parser exists — parser bugs masquerading as checker bugs are the single biggest time sink in implementations of this kind. Middle phases (9–14) build CIC features incrementally, each one a testable exit. Later phases (15+) add universe polymorphism, SProp, records, modules, tactics, typeclasses — the features that complete the full modern CIC feature set Doxa commits to in §1.1.

**Prior-work grounding.** Doxa's contributions are surface syntax + WasmGC platform + linear-time invariant + Rumil parser (SPEC §1.2). Kernel semantics are inherited from the standard references in SPEC §10. Every non-trivial kernel decision from Phase 13 onward starts with a prior-work review and cites which reference design we follow.

---

## Phase 0 — Bootstrap

**Goal:** Empty but well-formed Dart package.

- Create `doxa/` as a Dart package with `pubspec.yaml`.
- Add dependency on local `rumil` via `path:` (matching the pattern already used in `rumil_parsers`, etc.).
- Configure `analysis_options.yaml` with strict-mode lints consistent with the Rumil packages.
- Empty `lib/doxa.dart` that exports nothing yet.
- `test/` directory wired to `dart test`.
- CI skeleton (`dart analyze`, `dart test`) — mirror whatever the other Rumil packages use.

**Exit:** `dart analyze` clean, `dart test` runs (zero tests), `dart pub get` resolves.

---

## Phase 1 — Kernel Term ADT

**Goal:** The kernel syntax, with the locally-nameless primitives working correctly.

- `lib/src/term.dart`: sealed `Term` with `TType(level)`, `TBound(index)`, `TFree(name)`, `TApp`, `TLam`, `TPi`.
- `open(Term, String) → Term` and `close(Term, String) → Term` operating over de Bruijn indices under binders.
- No evaluation, no equality beyond structural — this phase is pure data and two traversals.

**Tests:**
- `close(open(t, x), x) == t` for a hand-built collection of terms, including nested binders.
- `open` on a term with no `Bound 0` is a no-op.
- Deeply nested binders (≥ 10) maintain correct indices after open/close cycles.

**Exit:** open/close round-trip property holds on a dozen representative terms.

---

## Phase 2 — Semantic values and defunctionalized NbE

**Goal:** Evaluate closed terms to normal form via NbE, with no use of the host call stack for semantic recursion.

- `lib/src/env.dart`: sealed `Env` (`ENil`, `ECons(head, tail)`) as an immutable cons-list. `lookup(env, index)` is O(index) and total for well-scoped inputs.
- `lib/src/value.dart`: sealed `Value` (`VType`, `VLam`, `VPi`, `VNeutral`), `Closure { Env env, Term body }`, sealed `Neutral` (`NVar(level)`, `NApp(fn, arg)`).
- `lib/src/eval.dart`: **defunctionalized interpreter** implementing §4 of SPEC.
  - Sealed `Frame` ADT — one case per continuation shape the direct-recursive pseudocode would push on the call stack.
  - Single `while (true)` dispatch loop over a `List<Frame>` control stack.
  - Public entry points `eval(Term, Env) → Value`, `apply(Value, Value) → Value`, `quote(int level, Value) → Term`, `nf(Term) → Term`. Internally, all four route through the same loop; none calls itself transitively.
- Frame shapes will include at minimum: `AppFn(argTerm, env)` (finish evaluating an App when we have the function), `AppArg(fnValue)` (finish evaluating an App when we have the argument), `PiDom(bodyTerm, env)`, `QuoteApp(level)`, `QuoteNeutral(level)`. The final list is determined during implementation, not pinned here.

**Tests:**
- `(λx. x) y` normalizes to `y` on hand-built kernel terms.
- `(λx. λy. x) a b` normalizes to `a`.
- Under-applied lambdas stay as `VLam` until quoted.
- Closed Church-numeral arithmetic: `plus(two, three)` normalizes to the same term as `five`, by hand-built terms.
- **Stack-safety stress test:** `succ` applied 10,000 times to `zero`, then checked against a reference Church numeral built by folding `succ` at the meta level. If the interpreter used the host stack, this would throw `StackOverflowError`. This test is the guarantee that Phase 2 actually delivers on SPEC §4.5.

**Exit:** Church-Nat arithmetic normalizes correctly, 10,000-deep applications do not blow the stack, no parser yet.

---

## Phase 3 — Conversion

**Goal:** Definitional equality on values, with α, β, and η. Strict on universe levels — Doxa v1 is non-cumulative per SPEC §4.3.

- Conv lives in `eval.dart` (same file, same driver): adds `_Conv(va, vb, level)` steps and a small family of conv-specific frames to the unified interpreter. This keeps the "no host-stack recursion" invariant — conv must not spawn its own loop.
- η handling via "apply both to a fresh neutral and compare bodies," reusing `_Apply` steps.
- Result is a `ConvResult`: success or a `ConvMismatch` carrying the two values that failed to convert and an optional path describing where in the outer comparison the mismatch sits. This is the error-trace information Phase 6 formats.
- Lambda domain types are *not* compared (SPEC §4.3). Only the bodies are compared after both sides are applied to a fresh neutral.

**Tests:**
- α-equivalent lambdas convert: `(λx. x) ≡ (λy. y)` (both are `TLam(_, TBound(0))` after elaboration).
- β: `(λx. x) y ≡ y` after evaluation.
- η: `(λx. f(x)) ≡ f` when `f` is a neutral.
- Unequal universe levels do NOT convert: `Type 0 ≢ Type 1`.
- Equal universe levels convert.
- Negative: `(λx. x) ≢ (λx. f(x))` with `f` free.
- Negative: deep Pi mismatch reports first difference at the right subterm.
- Neutral spines compare arg-by-arg and report first differing arg.
- Cross-shape mismatches (Pi vs Lam, Type vs Pi) report cleanly.

**Exit:** conv returns correct verdicts on a curated suite of ~20 positive and negative cases; the mismatch trace points at the first real difference; no host-stack recursion (verified by composing conv with the existing stack-safety tests).

---

## Phase 4 — Bidirectional checker

**Goal:** Type-check kernel terms, end-to-end, without any parser.

- `lib/src/check.dart`:
  - `infer(Ctx, Term) → Value` for `TType`, `TFree` (looks up ctx), `TPi` (infers the Type level), `TApp` (infers function, checks argument against domain, applies codomain closure).
  - `check(Ctx, Term, Value) → Unit` specialises on `TLam` vs `VPi`, falls through to `infer` + `conv` otherwise.
  - Errors raise a structured `DoxaError` with kind + the two `Value`s involved.
  - `TLam` without an annotated domain in `infer` mode raises `LambdaNeedsAnnotation`.

**Tests (all kernel-level, hand-built):**
- Identity `(A: Type) -> (x: A) -> A` — `(A) => (x) => x` checks.
- Church Nat: `zero`, `succ`, `one`, `two` all check against `Nat`.
- `(A: Type 0) -> A` has type `Type 1` exactly (Pi: max(0, 0) for the domain part + 1 for quantifying over `Type 0`). Fails to check against `Type 0` and against `Type 2` — strict universe discipline, not cumulative.
- Application with wrong argument type fails with `TypeMismatch`.
- Variable out of scope fails with `UndefinedName`.
- Applying a non-function fails with `NotAFunction`.

**Exit:** Every example in SPEC §5.3 type-checks when constructed as kernel terms. The full Church-Nat vocabulary (including `plus`, `mult`) checks.

---

## Phase 5 — Surface parser and elaborator

**Goal:** Source text → kernel `Term`.

- `lib/src/parse.dart`: Rumil-based parser producing a surface AST separate from the kernel. The surface AST carries source spans on every node.
  - Atoms, application (left-recursive via `rule()`), arrow, Pi, lambda, `val`/`fun`/`type` declarations.
  - Line + block comments, nested block comments.
- `lib/src/surface.dart`: surface AST (sealed classes mirroring the BNF).
- `lib/src/elab.dart`:
  - `elabExpr(Scope, SurfaceExpr) → Term` — resolves names, inserts `close` at binder sites, desugars multi-arg application `f(a, b)` to `App(App(f, a), b)`.
  - `elabDecl(SurfaceDecl) → (name, type, term)` — desugars `fun` to `val` + lambda + Pi.

**Tests:**
- Every example in SPEC §5.3 parses and elaborates to a kernel `Term` that round-trips equal to the hand-built version from Phase 4.
- Parse errors have correct spans.
- A deliberately misaligned `A -> B -> C` parses right-associatively.
- Application `f(a)(b)` and `f(a, b)` elaborate identically.

**Exit:** `parse(source) |> elab |> infer` works end-to-end on all SPEC §5.3 examples.

---

## Phase 6 — Error reporting

**Goal:** Every error matches the SPEC §6 contract.

- `lib/src/error.dart`: sealed `DoxaError` hierarchy — `TypeMismatch`, `UndefinedName`, `NotAFunction`, `UniverseInconsistency`, `LambdaNeedsAnnotation`, `ParseError` (wrapping Rumil).
- Every error carries a `SourceSpan`. Spans propagate: the elaborator attaches surface spans to kernel terms (via a side table keyed by term identity, or a wrapper node — decide at implementation time).
- `TypeMismatch` carries both `Value`s (expected, actual) and the conversion trace from Phase 3.
- `lib/src/pretty.dart`: `Term → String` and `Value → String` (via `quote`) using surface syntax. Used by error formatting and by the CLI.
- Error formatter produces the exact shape shown in SPEC §6.

**Tests:**
- Golden test for each error kind: invalid program in, formatted error out. Check that span, expected type, actual type, and first-difference location are all correct.
- Formatter output matches SPEC §6 example verbatim (given the same input).

**Exit:** Every error kind has a golden test with a formatted message matching the SPEC contract.

---

## Phase 7 — CLI and program test suite (right-sized)

**Goal:** Shippable `doxa check FILE` plus a focused set of end-to-end program tests.

**Scope note (2026-04-21):** Earlier drafts proposed exhaustive golden-output tests for every error kind. That's deferred. The v1 target is: a working CLI and enough programs to prove the language is usable, not a comprehensive diagnostic regression suite.

- `bin/doxa.dart`: parses one file, elaborates, checks every `val`/`fun`/`type` declaration in order, propagates earlier declarations into the context, prints errors or "OK".
- `test/programs/`: a small, curated directory of `.doxa` files. Each paired with an expected outcome (type-checks, or fails with specific error).

  Positive programs (what a user might actually write):
  - Dependent identity `id : (A: Type) -> A -> A`.
  - K combinator.
  - S combinator.
  - Church-Nat vocabulary (zero, succ, plus — with `plus(two, three)` normalizing to `five`).
  - Church-Bool `if`.
  - The SPEC §5.3 examples.

  Negative programs (one minimal example per error kind, not exhaustive):
  - TypeMismatch.
  - NotAFunction.
  - NotAType.
  - UnresolvedName.
  - DuplicateDeclaration.
  - Universe mismatch.

- README update: usage example, link to `test/programs/` as the user's entry point.

**Exit:** `doxa check` works on every `test/programs/*.doxa` with the expected outcome. A reader can clone the repo, run `dart run bin/doxa.dart test/programs/id.doxa`, and see it type-check.

**Deliberately out of scope for v1:** verbatim golden-output matching for every error kind, exhaustive diagnostic regression tests, benchmark scaffolding. Those belong with the v2 inductive-types release, when error messages will be richer anyway.

---

## Phase 8 — dart2wasm deployment (moved to the final polish phase)

Original placement here was the "browser demo" deliverable. It has been moved to the final polish phase (see further below) because:

- Nothing in the CoC-kernel-only stage needs a browser; the CLI is the natural interface at this stage.
- A WasmGC artifact is a release deliverable, not a feature-correctness deliverable — it belongs with the tutorial, the diagnostic polish, and the release prep.
- dart2wasm improves continuously; building the Wasm harness earlier would likely be redone by release time.

When the browser demo lands (final polish phase) the work is roughly:

- `dart compile wasm` build producing a WasmGC module.
- Minimal browser harness (static HTML + JS glue) that accepts pasted source, runs `check`, displays the result.
- Verify WasmGC performance against the AOT baseline on the stdlib test suite.

---

# CIC feature phases

The kernel features specified in SPEC §8 are built incrementally in the phases below. Each phase lands a testable subset of the calculus; the language remains runnable after every one. No phase corresponds to a public release — they are internal sequencing markers.

## Phase 9 — CoC + Prop + cumulativity + mutual recursion foundations

**Goal:** Strengthen the v1 foundations without introducing new constructs that themselves need v2's later machinery. Every change here is load-bearing for v2.1+.

- **Let-bindings.** `TLet(name, domain, bound, body)` as a kernel primitive. Preserved through elaboration, evaluated by β-reducing the bound expression lazily or eagerly (decide at implementation time; NbE closures make both viable). Pretty-printed as `let x = e` in diagnostics.
- **Cumulativity.** Introduce `subtype(Level, Value, Value) → SubtypeResult` alongside `conv`. `subtype` calls `conv` except at universe positions, where `Type n ≤ Type m` iff `n ≤ m`. The checker uses `subtype` at the Conv rule and at argument-against-domain checks. Universe levels become first-class values (not hard-coded ints) to support future polymorphism.
- **Prop sort.** New universe `Prop`, impredicative: `(X: Prop) -> P X : Prop` (not `Type 1`). Standard PTS Pi rule for the Prop/Type combinations. `Prop : Type 1`.
- **Mutual recursion syntax.** Parser: `fun f(...) = ... and g(...) = ...` as a mutual block. Elaborator: two-pass name registration within the block so all names are visible during each body's elaboration. Does NOT enable actual recursive references — those remain rejected with a `RecursionNotYetSupported` diagnostic pointing at Phase 11 (the termination/guardedness check). This is a soundness requirement: without termination checking, recursive functions can diverge and the kernel could normalize forever. v2.0 lays the parsing/elaboration groundwork so v2.1 (inductive types) and v2.2 (guardedness) can plug in without further surface-syntax changes.

**Tests:**
- Let semantics: `let x = e1 in e2` converts with `e2[x := e1]`.
- Cumulativity: `(A: Type 0) -> A -> A` type-checks as a value of `Type 1` (unchanged) but now also as a value of `Type 2` under subtype — verify both.
- Strict equality still rejects the wrong universe when used through `conv`, not `subtype`.
- Prop: `(A: Prop) -> A -> A` is in `Prop`; quantifying over Type does not escape to Type.
- Mutual parsing: `fun even and fun odd` — the block parses and each name is in scope for the other's elaboration (name resolution succeeds).
- Recursive reference rejection: any actual self- or mutual-reference raises `RecursionNotYetSupported`.
- Non-recursive mutual blocks (functions that happen to be declared together but don't call each other) type-check normally.

**Exit:** All prior v1 tests still pass. Cumulativity works. `Prop` parses, elaborates, participates in the PTS Pi rule. Check-mode TLam-against-VPi is contravariantly correct under cumulativity. Let-bindings work as kernel primitives. Mutual `fun` blocks parse and register their names two-pass, but recursive references are explicitly rejected with a diagnostic pointing to Phase 11.

**Note about Church-Nat `plus`.** An earlier draft of this plan claimed v2.0 would unblock Church-Nat `plus` via cumulativity. That was wrong: `plus` requires applying `m : (A: Type 0) -> ...` to `Nat : Type 1`, i.e., `Type 1 ≤ Type 0`, which is cumulativity going the wrong direction. Church-Nat `plus` requires universe polymorphism (v3) or native inductive `Nat` (v2.1). The church_nat.doxa program stops at `three` with a comment explaining the limitation.

---

## Phase 10 — v2.1 inductive types and the derived recursor

**Goal:** `data` declarations with parameters, indices, and positivity checking. No pattern matching yet — users call the derived recursor directly. Usable but painful; the next phase makes it ergonomic.

- `SData(name, params, indices, ctors)` in surface AST.
- Kernel terms: `TData(name, args)`, `TConstr(dataName, ctorName, args)`, `TRec(dataName, motive, methods, scrutinee)`.
- Positivity check: scan each constructor's argument types; reject strictly-negative occurrences of the data type.
- Recursor derivation: mechanical from the data declaration. Produces a dependent eliminator of the correct type.
- Values: `VData`, `VConstr`. `TRec` on a canonical `VConstr` reduces to the corresponding method applied to the constructor's args (plus recursive calls on sub-data). On a neutral scrutinee, `TRec` is stuck.

**Tests:**
- `data Nat` declares and its recursor has the expected type.
- `data List[A]` parametric case.
- `data Vec[A] : Nat -> Type` indexed case.
- Mutual `data` (via Phase 9 machinery).
- Positivity violation: `data Bad { bad : (Bad -> Bad) -> Bad }` rejected.
- Using `Nat.rec` by hand to define `plus` (painful but working).

**Exit:** `plus`, `mult` on native `Nat` defined via direct recursor calls, type-check and normalize. stdlib not yet populated.

**Correctness-coverage audit (performed at the end of step 7d, before proceeding to step 8):** walked SPEC §3 and §8 rule-by-rule and mapped each to tests. Three gaps surfaced and were closed:

- **Missing VRec × VRec convertibility case** (SPEC §4.3 + §8.4). Two stuck recursors with structurally equal spines now convert via a dedicated case in `_Conv`, mirroring the VData/VConstr pointwise-arg pattern. Previously fell through to the "any other shape" mismatch — a subtle soundness hole where syntactically equal stuck-recursor types would be deemed unequal.
- **Missing TConstr arg-type mismatch coverage.** Arity errors were tested but not argument-type mismatches (e.g. `cons Bool zero (nil Bool)` where `zero : Nat`). Added explicit TypeMismatch-firing tests.
- **Missing Prop-sorted recursor tests.** `data P : Prop { ... }` emits `P.rec` and synthesizes its type via `synthRecursorType`; tests verify the binding exists, its type is well-formed, and it type-checks. The recursor type for a Prop-sorted data lives in Prop (via impredicativity), which is a subtle but correct CIC property now explicitly anchored.

21 new tests added in `test/phase10_audit_test.dart` with explicit SPEC-clause anchors on each test group. Full suite 476/476 green after audit close.

**Step 8 mutual-data follow-ups:** After shipping `data A and data B` blocks, a closing audit surfaced four carry-forward items. Two are resolved inside Phase 10, two are deliberately carried into later phases.

*Resolved in Phase 10:*

- **Per-member source spans (step 8 follow-up; commit c0f3de4).** Each block member now has its own `SDataBlockMember(data, span)` wrapper so positivity / duplicate diagnostics cite the specific `data ... { ... }` region, not the whole block. Mirrors the pre-existing `SCtorDecl` wrapper pattern; the "kind has no span, wrapper does" invariant in `surface.dart` is preserved.
- **Nested positivity via per-parameter covariance (step 8 follow-up; this commit).** `DataDecl.paramsCovariant: List<bool>` records which of an inductive's parameters are strictly-positive in every ctor-arg type. The positivity check admits a ctor arg of shape `S[X]` when `S` is covariant in the relevant slot and `X` itself is strictly positive. Concrete unlocks: `data Tree { node : List[Tree] -> Tree }` and `data RoseTree[A] { node : A -> List[RoseTree[A]] -> RoseTree[A] }`. Non-covariant slots (`NonCov[T]` with `NonCov` taking its param negatively) are still rejected. Two previously-pinned "conservative rejection" tests flipped to acceptance; regression tests added for the non-covariant guard.

*Carried forward (documented in SPEC §8.4 under "Known v2.1 limitations"):*

- **Header independence in mutual data blocks → resolve at Phase 13.** `data A : B -> Type and data B : Type` fails with `UnresolvedName('B')` because pass-1 header elaboration sees the outer `TopEnv` only, before sibling partials are registered. Fix requires interleaved header/signature elaboration (or SCC ordering). Deferred because it is orthogonal to positivity/recursor work and naturally interacts with Phase 13's meta-variables (signature elaboration under unknowns). Pinned by `mutual_data_test.dart: "A header referencing sibling B is rejected with UnresolvedName"`.
- **Mutual-recursor ι-reductions → subsumed by Phase 11 `match`.** Each block member gets its own monomorphic `T.rec`; cross-recursor calls must be written via explicit lambdas. Extending `rec` synthesis to handle cross-calls would duplicate work that Phase 11's structural-recursion + `match` (SPEC §8.5, §8.6) subsumes cleanly. Phase 11 delivers this as a side-effect of supporting mutual structural recursion.

**Step 9 — curated `.doxa` programs (end-to-end through the CLI).** Added eight new positive programs and two new negative programs to `test/programs/`, covering the Phase 10 feature matrix:

- Positive: `nat`, `nat_mult`, `list_length`, `vec`, `mutual_even_odd`, `rose_tree`, `bool`, `prop_true`.
- Negative: `positivity_violation`, `ctor_arg_mismatch`.

Each runs through `bin/doxa.dart check` via `programs_test.dart` with asserted outcome (OK for positives, matching diagnostic substring for negatives). `rose_tree.doxa` specifically exercises the nested-positivity path landed in limitation 1, so the step-8 follow-up has a CLI-level regression. `vec.doxa` exercises indexed families; `mutual_even_odd.doxa` exercises the step-8 block syntax. `prop_true.doxa` anchors the Prop-sorted recursor path that the step 7 audit flagged.

---

## Phase 11 — v2.2 pattern matching and structural recursion

**Prelude — linear-time kernel invariant (COMPLETE, commit 1fae126).** The investigation surfaced at Phase 10 step 1's stack-stress exercise closed out before Phase 11 began.

- The unified driver holds stack depth constant to at least 1,000,000-deep structures across all kernel paths. That meets SPEC §4.5's stack-safety promise with six orders of magnitude of headroom.
- Twelve of thirteen workloads already scaled linearly. One — `infer` on deeply nested `TLam` — scaled super-linearly (4.3s at 10k → 139s at 50k, ~32× slower for 5× input): stack-safe but O(N²), invisible at the 10k test anchor.
- Root cause (confirmed): `_InferLamHaveBodyType` quoted the growing VPi codomain tower at every enclosing binder. The quoted term was immediately placed into a new closure whose `_Quote(VPi)` would run the open/eval/quote round-trip back — identity on an already-normal term, and O(N) per level, O(N²) overall.
- Fix: `Closure.bodyIsNormal: bool` marks closures whose body is already normal in scope `env.extend(fresh)`. Set at the one construction site where the invariant is locally true (`_InferLamHaveBodyTerm`). `_Quote(VPi)` short-circuits via a new `_QPiBuildNormal` frame when the flag is set and `closure.env.depth == level` (the latter checked in O(1) via a new `Env.depth` cache). After the fix: 10k 7s → 30ms, 40k 70s → 16ms, 1M extrapolated ~780s → 500ms. Matches `infer TPi` band.
- Regression pin: `test/check_test.dart` exercises 100k-deep TLam with a 5s budget. Pre-fix would take ~700s; any reintroduction blows the budget immediately.
- Invariant promoted in SPEC §4.5: "The kernel guarantees O(N)-time complexity for all structural operations on terms and values of size N, modulo the inherent non-linearity of β-reduction output size." Plus a §1.1 bullet (`"Stack-safe but quadratic" is explicitly rejected as a Potemkin guarantee`) and a README "Performance invariants" section pointing at `tool/stack_stress.dart` as the on-demand regression channel.

**Goal:** The language becomes writable. Direct `match` as a kernel primitive (per SPEC §8.5, *not* desugared to recursors), exhaustiveness + coverage for indexed families, and the structural-recursion / guardedness check that lifts Phase 9's `RecursionNotYetSupported` gate.

**The step-5 boundary (the single most important decision in this phase).** Dependent motive inference is the hinge between Phase 11 and Phase 13. A fully general implementation requires pattern unification, which is Phase 13's work. Phase 11 draws a deliberate, honest line: it handles the two motive shapes that arise in every non-pathological program (non-indexed constant motives, and indexed families where the motive is determined by unifying the expected type against each case's refined scrutinee type), and rejects anything else with a diagnostic pointing at Phase 13. We do *not* guess, and we do *not* pull full unification forward into Phase 11. This boundary is legibly described at step 5 and in SPEC §8.5.

### Step 1 — Surface syntax + parser for `match`

- `SMatchKind(scrutinee, cases)` with `SCase(ctor, binders, body, span)`; wildcard as `SWildcardCase(body, span)`.
- Optional motive annotation: `match scrutinee returning P { ... }` parses `P` as an `SExpr` and attaches it to the kind. Omitted motive is the common case; step 5 handles both.
- Grammar extension in SPEC §5.1 updated alongside.
- Tests: parse round-trips only, no elaboration. Exhaustively test binder syntax including parenthesised names and underscores.

### Step 2 — Kernel `TMatch` term form

- Primitive, per SPEC §8.5 (not desugared to `TRec`).
- `TMatch(scrutinee: Term, motive: Term, cases: List<(String ctor, int nBinders, Term body)>)`. Case bodies use de Bruijn indices over the pattern-bound variables; no named pattern binders inside the kernel.
- `VMatch(scrutineeV: Value, motiveV: Value, cases: List<(ctor, nBinders, Closure)>)` as the value-level stuck form. Mirrors `VRec`'s precedent: a dedicated first-class Value (not a Neutral), so a stuck match can sit anywhere a Value sits without needing the scrutinee to be strictly neutral (it may also be a stuck `VRec`, another `VMatch`, etc.). When the scrutinee later reduces to a canonical `VConstr`, ι-reduction fires (step 4).
- Pretty-printer round-trip tests; conversion uses structural equality of case bodies modulo alpha.

### Step 3 — Elaboration + coverage check

- Resolve ctor names in scope, verify binder arity matches the registered ctor's arg count.
- **Coverage:** every constructor of the scrutinee's type must be handled or a wildcard is present. Missing → `NonExhaustiveMatch(missingCtors)`. Extra (a ctor not in the data decl) → `UnknownCtor`. Duplicate case → `DuplicateCase`.
- For v2.1-style non-indexed match, accept an *explicit* motive from the surface or infer the trivial constant motive from the expected type. Dependent motive for indexed families deferred to step 5.

### Step 4 — ι-reduction for `TMatch`

- On canonical `VConstr`, dispatch to the matching case body with constructor args substituted via the existing closure machinery. Mirrors the VRec ι-rule already in eval.dart.
- Wildcard cases fire last, and only when no ctor case matched.
- Stuck on neutrals: `TMatch` enters the neutral spine and stays stuck, exactly like the recursor.
- Conversion: `TMatch` × `TMatch` on structurally equal (scrutinee, motive, cases) converts; distinct-head matches participate in the neutral-spine diff.

### Step 5 — Dependent motive inference (bounded form — the honest line)

Two motive shapes handled without full metas:

- **Constant motive:** expected type does not depend on scrutinee → motive is `_ => expected`. Covers virtually every non-proof program.
- **Indexed-family motive from expected type:** expected type is `T[params] index_0 ... index_k` and at least one `index_j` is a sub-term of the scrutinee. Motive is synthesized by abstracting over each dependent index position. For example, `Vec[A] (succ n) → A` in a `head` function: the expected type is `A`, the scrutinee is the `Vec`, and the motive is `(n: Nat) => Vec[A] n => A` matching the `vcons` refinement `n = succ n_`.

All other shapes raise `MotiveInferenceRequiresUnification` with a message pointing at Phase 13 (implicit meta resolution) and inviting the user to annotate `returning P` explicitly as a workaround.

**Hard rule:** Phase 11 does not introduce `TMeta` or a constraint solver. If step 5 feels like it's growing one, stop and reassess — that's Phase 13's work sneaking in.

### Step 6 — Structural-recursion / guardedness check; lift `RecursionNotYetSupported`

- Designate a "decreasing argument" per recursive function. v2 default: the first explicit argument; later phases can add annotations.
- Maintain a `StrictSubTerm` relation at elaboration time: pattern-bound variables introduced by a `match` on the designated argument are strict sub-terms of that argument. Recursive calls must pass a strict sub-term at the designated position.
- Non-structural call → `NonStructuralRecursion(callSite)` citing the offending argument.
- This step is the one that lifts Phase 9's `RecursionNotYetSupported` gate. The order matters: do not lift the gate until the guardedness check actually works, otherwise we've opened the door to divergence.

### Step 6 completion notes (audit pass — commits 08ce21d / e889aad / e60150f / c9487fa)

A mid-step correctness episode forced a larger refactor than originally scoped. Recorded here so Phase 13 inherits the architectural state, not just the feature list.

- **TTop / NTop refactor (commits 08ce21d, e889aad).** During step 6, a mixed-block bug (non-recursive member `f` co-existing with recursive `g` in the same `fun ... and ...`) surfaced TBound index drift whenever pre-registration over-extended the scratch env. Post-audit the decision was taken to stop position-indexing top-level references: `TTop(name: String)` (term) and `NTop(name: String)` (neutral value) replace TBound for all top-level refs. This matches Coq `Const`, Lean `Expr.const`, Agda `QName`. Pinned by `test/programs/positive/mixed_block.doxa` and `test/programs/positive/mixed_block_cross_call.doxa`. The mixed-block class of index-drift bugs is now unreachable by construction.
- **Single-`fun` path unified with block path (commit c9487fa).** An audit follow-up: `SFunKind`'s own recursive path in `_elabDecl` duplicated the structural-check / self-preregistration / CorecursiveGroup logic already in `_elabFunBlock`. Collapsed by treating a single `fun` as a 1-member block. Any future change to the step-6 discipline now lands in exactly one place.
- **`_hasRecursiveReference` gate (retained, not legacy).** Decides whether to emit a non-empty CorecursiveGroup (pre-scope stubs in Ctx) or an empty one (plain per-binding check). This is a correctness + clarity distinction, not scaffolding — non-recursive blocks do not need self-neutral stubs and should not pay the Ctx plumbing cost.
- **Structural-recursion walker: type-arg position simplification → Phase 13.** The walker flags `args[0]` as the designated-value-arg position unconditionally. For a callee with `[TypeArg]` type-params, the "real" designated position is shifted by the type-param count. Tracking per-callee type-param counts at walk time would require a second symbol-table lookup for every recursive call. Phase 13's implicit args eliminate the problem by elision — `f[Nat] x` becomes `f x` at the surface and the walker only ever sees value args. Walker-site comment (elab.dart:1566-1576) points at this resolution. No user program in the current test corpus hits this, but a pin program gets added when Phase 13 lands.

### Step 7 — Mutual recursion across a block

- Extend the `StrictSubTerm` relation to span the whole mutual block. In `fun even(n) and fun odd(n)`, a call from `even` to `odd` must pass a strict sub-term of `even`'s decreasing argument; `odd` can then recurse on *its* own sub-term when it calls back.
- Resolves Phase 10's carry-forward item #2 ("mutual-recursor ι-reductions") as a side-effect: users write mutual `even`/`odd` as recursive `fun`s calling each other via `match`, instead of trying to cross-call `Even.rec`. SPEC §8.4's "Known v2.1 limitations" note updated to point here once done.

**Step 7 completion (2026-04-23).** Step 7's mechanics were already landed by step 6: the structural-recursion walker takes a `blockMembers: Set<String>` and enforces the block-wide StrictSubTerm relation for every member by construction. No walker code change was needed. Step 7's actual deliverable was raising coverage + resolving SPEC §8.4's carry-forward item:

- *New positive pins.* `test/programs/positive/mutual_three_phase.doxa` (three-member cyclic mutual a→b→c→a — first program stressing N > 2 members) and `test/programs/positive/mutual_tree_forest.doxa` (canonical Tree/Forest mutual on a non-Nat indexed shape, layered with cross-binding to an external recursive `plus`). The tree/forest shape is the gold-standard mutual-termination test every CIC implementation uses.
- *New negative pin.* `test/programs/negative/mutual_non_structural.doxa` — a mutual block where a cross-member call passes the caller's own designated arg (not a strict sub-term) at the callee's designated position. Rejected with `NonStructuralRecursion` at elab time.
- *SPEC §8.4 limitation #2 ("Mutual-recursor reductions") marked resolved.* The original gap — cross-recursor ι-reductions between mechanically-synthesised `T.rec` bindings — is now a non-issue: users write mutual programs via `match` directly, not via cross-`rec` dispatch. The redundant path was never wired and does not need to be.
- *Known v3+ ergonomic gap.* Per-member `{struct <name>}` annotation for designating a non-first decreasing argument (Coq's `Fixpoint {struct}` shape) is not implemented. When a mutual member needs to decrease on its second value arg (e.g. `f(n: Nat, b: Bool) = match n { ... }` and `g(n: Nat, b: Bool) = match b { ... f n ... }`), the walker rejects the cross-call with `NonStructuralRecursion` even if the call is lex-order terminating. This matches Coq's historical baseline (explicit `{struct n}` required; Coq didn't auto-detect either). Lean 4 auto-solves via a termination tactic — an ergonomic lift, not a soundness gap. Tracked in v3+ competitiveness items for when Phase 13's Ctx matures enough to carry per-member termination metadata.

### Step 8 — Audit + missing-feature sweep

Mirror Phase 10 step 7's discipline: walk SPEC §8.5 and §8.6 rule-by-rule and map each to a test. Landmines to specifically guard against:

- **Prop elimination restrictions.** Matching on a `Prop`-sorted data type can only produce a `Prop`-sorted result (the eliminator's motive must target `Prop`). Getting this wrong lets you "prove" non-propositions via propositional case analysis.
- **Matches inside recursor methods.** The Phase 10 recursor + Phase 11 match must compose cleanly.
- **Unreachable cases from index refinement.** `match v : Vec[A] (succ n) { vcons n x xs => ... }` — the `vnil` case is forced unreachable by `zero ≠ succ n`. SPEC §8.5 allows omitting unreachable cases; the coverage check must treat these as satisfied, not missing.
- **Nested matches on sub-terms.** Recursion on a sub-pattern of a sub-pattern must still be recognised as structural.

**Step 8 completion notes (2026-04-23).** Audited all four landmines against the current code. Three already handled by prior step work; one was a real soundness gap and got closed in this step.

- *Landmine #1 — Prop elimination (SOUNDNESS GAP, now fixed).* The rec path enforces Prop-motive-target by construction (`_synthMotiveType` uses `d.sort`), but the match path did not check anything: a match on a Prop-sorted scrutinee could return a Type-sorted value. This is a real soundness leak — combined with Phase 12 step 0's definitional proof irrelevance, two distinct proofs of the same Prop that Prop-irrelevance declares equal would be allowed to compute to distinct Type-values. Fix: infer the sort of `expected` in `_CheckMatchScrutineeType` (quote + re-infer, once per match); if the scrutinee's data is Prop-sorted and the expected sort is not VProp, throw a new `PropEliminationIntoType` error. Pinned positive `prop_to_prop_match.doxa` (permitted direction) and negative `prop_elim_into_type.doxa` (forbidden direction). The singleton-elimination exception (≤ 1 ctor with no informative args eliminates into Type, matching Coq's `Eq.rec`) lands in Phase 12 together with `Eq` at Prop sort — rejecting here is conservative and strictly-less-accepting than the final rule, so no current accept-list program regresses when the exception is added later.
- *Landmine #2 — matches inside recursor methods.* Already composes cleanly. Pinned by `match_in_rec_method.doxa`: `Nat.rec` with a step method whose body is a `match` on the IH.
- *Landmine #3 — unreachable cases from index refinement.* Already handled by step 5's first-order ctor-head clash coverage check. Pinned by `vec_head_unreachable.doxa`: `match v : Vec[A] (succ n)` with only the `vcons` arm; the `vnil` (index `zero`) is forced unreachable and may be omitted.
- *Landmine #4 — nested matches on sub-terms.* Already handled by the walker's `subTerms` propagation through nested match arms. Pinned by `nested_match_subterm.doxa`: `sub2` recurses on `m_`, the inner match's binder whose scrutinee was `m` from the outer match — the walker must track both levels.

**Forward-compat note.** The Prop-elim fix is strictly conservative: any program that type-checks under the v2.2 rule will also type-check under the Phase 12 singleton-extended rule. No accept-list regression risk when Phase 12 relaxes the rule.

### Step 9 — Curated `.doxa` programs

Same discipline as Phase 10 step 9: end-to-end through `bin/doxa.dart check`, pinned by `test/programs_test.dart`.

- Positive: `plus_via_match.doxa`, `mult_via_match.doxa`, `list_map.doxa`, `list_fold.doxa`, `vec_head.doxa` (dependent motive), `mutual_even_odd_via_match.doxa` (replaces the Phase 10 `Even.rec` version), `tree_depth.doxa`.
- Negative: `non_exhaustive_match.doxa`, `duplicate_case.doxa`, `non_structural_recursion.doxa`, `motive_needs_unification.doxa` (the step-5-boundary case — points at Phase 13).

**Step 9 completion notes (2026-04-23).** Delivered four new positive programs (`list_map.doxa`, `list_fold.doxa`, `vec_head.doxa`, `tree_depth.doxa`) and two new negative programs (`non_exhaustive_match.doxa`, `duplicate_case.doxa`).

Step 9's audit surfaced a real kernel bug that had been latent since Phase 10 step 7b:

- **`_synthMethodType.buildIHDomain` was wrong for ctors with ≥ 2 recursive args.** The formula added `+ mOutward` (count of inner IHs) to motive / arg / param depths while building each IH's domain. The correct shift is `+ outerCount = ihCount - 1 - mOutward` (count of OUTER IHs, since those sit in the final term's context outside the IH being built; the inner IHs sit inside and don't contribute to the domain's depth). Invisible for every v2.1 inductive (Nat, List, Vec — all have at most one recursive arg per ctor, so `ihCount == 1` makes `outerCount` identically zero). Surfaced the moment any ctor had 2+ recursive args — `Tree.node : Tree -> Tree -> Tree`, `Forest.fcons`, `Pair.p`. Pinned by three new kernel-level regression tests in `test/recursor_test.dart` ("synthRecursorType: ctors with multiple recursive args") exercising `Tree`, `Forest`, and a 3-IH `Triple` data.

This is *exactly* the kind of bug step 9 was designed to surface — a soundness-adjacent invariant that no prior test stressed because every prior inductive had at most one recursive arg per ctor. `tree_depth.doxa` exercises the fix end-to-end through match + mutual-recursive `plus`.

**Deferred (for Phase 13):** The `motive_needs_unification.doxa` negative program is deferred because the dedicated `MotiveInferenceRequiresUnification` error isn't yet landed — today's motive inference falls back to constant-motive shapes and doesn't diagnose the step-5 boundary. Phase 13's pattern unification either accepts these cases directly (eliminating the need for the negative pin) or surfaces them with the dedicated error. Carried forward in the Phase 13 carry-forward list.

**Risks specific to Phase 11:**

- Step 5 boundary creep: the strongest mitigation is writing step 5's rejection-diagnostic test *before* writing the acceptance logic, so the "fails with MotiveInferenceRequiresUnification" case is locked in as the default from day one.
- Step 6 sub-term tracking: keep it syntactic (pattern-bound vs. not) rather than semantic (value-equal to a sub-term after β). Semantic sub-term tracking is undecidable in general; syntactic is what every CIC implementation actually does.
- Step 7 mutual sub-term relation: nested `match`es can confuse a naive implementation. Reference: Coq's `guard_condition` / Agda's termination checker.

**Exit:** `plus_comm`-shaped usage works end-to-end (though `plus_comm` itself needs Phase 12's `Eq`). Programs from Phase 10 rewritten using `match` as regression evidence. Mutual `even`/`odd` runs as recursive `fun`s. Phase 10's carry-forward item #2 resolved.

---

## Phase 12 — v2.3 propositional equality

**Goal:** `Eq`, `refl`, and auto-`refl` synthesis. A user can write `plus_comm` and have it check.

**Dependency note.** `Eq` elimination (`subst`, the J-rule) interacts with Phase 11's dependent-motive logic. If Phase 11 step 5 draws its boundary honestly and the `motive_needs_unification.doxa` case is pinned, Phase 12 inherits a clean foundation. If not, Phase 12 surfaces the failure first — treat Phase 12's first failing proof as a diagnostic of Phase 11, not of Phase 12.

### Step 0 — Prop definitional proof irrelevance (prerequisite, lands before Step 1)

SPEC §8.2 commits Doxa to definitional proof irrelevance in `Prop` (matching Lean 4). Phase 12 is where the commitment becomes load-bearing: once `Eq` at Prop sort is a thing, proofs of the same propositional equality must convert by reflexivity, otherwise the stdlib's `Eq`-over-`Prop` proofs won't compose.

**Design note (2026-04-23).** The straightforward phrasing — "when two values have the same Prop-sorted type, admit the conversion" — requires type information at `_Conv` call sites. Today `_Conv(a, b, level)` does not carry a `Ctx`, so it can't ask "what is the type of `a`?". Three implementation options were weighed:

1. **Thread `Ctx` into `_Conv`.** Invasive — every `_Conv` frame and every conv-adjacent frame (`_ConvThen`, `_ConvPairLeft`, `_ConvThenOpen`) would need a ctx field. Every callsite would need to pass the current ctx. Touches ~30 call sites.

2. **Thread the *expected type's sort* into `_Conv`** only where it matters — e.g., in `_CheckFallback` when `expected` is known, and when recursing into ctor args whose telescope has a known sort. Less invasive than (1) but couples conv with sort-tracking bookkeeping that's awkward for the structural cases.

3. **Infer-on-demand at conv fallback.** Before `_Conv` returns `ConvMismatch`, infer `a`'s type via a dedicated `_inferValueType(Value, level) → Value` helper that operates on values directly (not through the full checker). If the inferred type is Prop-sorted, admit. This is Lean 4's approach, adapted: the irrelevance check fires as a fallback, not eagerly, so the common successful-conv case pays nothing.

**Decision: Option 3.** It's the lightest touch, matches Lean's architecture, and preserves the invariant that conv is pure structural comparison — irrelevance is the one semantic exception, applied only when structural conv would otherwise fail.

**Implementation plan.**

1. **Where the check fires: at conv's `default:` fallback, NOT at the top.** Structural conv succeeds on the common case (e.g., `refl A x` vs `refl A x` both reduce to the same `VConstr("Eq", "refl", [A, x])` and match pointwise). Irrelevance is load-bearing only when structural conv WOULD fail — e.g., two different ctors of the same Prop, a neutral proof vs a canonical proof, stuck matches, or proofs of `And` whose inner args genuinely differ. Firing at the `default:` arm means the common path pays nothing; only would-be-mismatch calls pay an `_inferValueType` + `_isPropSorted` check each. Matches Lean 4's `isDefEq` architecture.

   Concretely: replace the existing `default: step = _YieldC(ConvMismatch(a, b));` at line ~1379 with a call to `_tryPropIrrelevance(a, b, level, dataDecls)`; if that succeeds, yield `_ok`; otherwise yield the mismatch.

   **Subtle point.** Some `_Conv` cases yield `ConvMismatch` explicitly (e.g. the length-mismatched spine case at line 1187), not through `default:`. To make irrelevance catch those uniformly, the simplest approach is a helper `_mismatchOrIrrelevance(a, b, level, dataDecls)` that all mismatch-returning arms call, rather than yielding `ConvMismatch` directly. Keeps the rule in one place.

2. **New helper `_inferValueType(Value v, int level, List<DataDecl> dataDecls) → Value?` in `eval.dart`.** Given a value, return its type as a Value, or `null` when the type cannot be classified without ctx. Cases:
   - `VType(n) → VType(n+1)`.
   - `VProp → VType(1)` (Prop : Type 1, SPEC §8.2).
   - `VPi(dom, cod) → _piSort(_inferValueType(dom, level, dataDecls), _inferValueType(apply(VLam(dom, cod), VNeutral(NVar(level))), level+1, dataDecls))` — reuse the existing PTS-rule helper. Recursive call on `dom` and opened-`cod`; terminates because they're structurally smaller. Returns `null` if either sub-infer declines.
   - `VLam → null`. The type of `λx. body` is a `VPi` whose codomain is `body`'s type — requires walking into `body` under a binder, which requires ctx. For irrelevance this is fine: raw lambdas don't appear as proof terms at conv sites in well-typed programs. A λ at a conv site is either an eta-opened comparison (handled structurally by `VLam × VLam` / `VLam × VNeutral`) or inside a larger spine.
   - `VData → VProp` or `VType(n)` — look up `dataDecl.sort` (which is a `Term`, either `TProp` or `TType(n)`) and return the corresponding Value. We do NOT need to compute the data's own param/index values for irrelevance; we only need its SORT.
   - `VConstr(dataName, _, _) → VData(dataName, _)` BUT: we only care about its sort, so we short-circuit to `dataDecl.sort`-as-Value directly. No need to reconstruct the param/index instantiation. This is a significant simplification over the original draft.
   - `VRec(dataDecl, _) → Eval(synthRecursorType(dataDecl), ENil)` — leverages the existing synthesizer. The synth type is closed under the decl's params+indices; evaluating under an empty env reifies the Pi-chain.
   - `VMatch → null`. Stuck matches at conv sites are reasoned about structurally by the `VMatch × VMatch` arm; irrelevance declining is fine.
   - `VNeutral(NVar | NTop | NStuck) → null`. Free variables and top-level stubs need ctx or topBindings; decline.

3. **New helper `_isPropSorted(Value type, int level, List<DataDecl> dataDecls) → bool`.** Answers "is this type a Prop-sorted type?" — i.e., "would a value of this type be a *proof* (in which case irrelevance fires) rather than a *proposition or data*?"
   - `VProp → false`. If `type = VProp`, then the original value was a proposition (`a : Prop`), not a proof. Irrelevance must not fire.
   - `VType(_) → false`. Value lives in Type, not Prop.
   - `VData(name, _) → dataDecl.sort == TProp`. This is the case that matters: `Eq[A] x y`, `And[A,B]`, `Conj` all live in Prop; any value of these types is a proof.
   - `VPi(dom, cod) → _isPropSorted(apply(cod, VNeutral(NVar(level))), level+1, dataDecls)`. A Pi is Prop-sorted iff its codomain is. Applying to a fresh neutral can produce a stuck value; in that case the recursive `_isPropSorted(VNeutral(...))` returns false (decline), which is conservative.
   - Everything else (VLam, VConstr, VRec, VMatch, VNeutral): false. These aren't type values — they're term values that happen to be passed where a type was expected. Conservative decline.

   **Worked example (irrelevance fires).** Two proofs `p1, p2 : And[A, B]` where `p1 = conj A B x1 y1` and `p2 = conj A B x2 y2` and `x1 ≠ x2` structurally:
   - Structural conv on `p1` vs `p2` recurses into args, fails at `x1 vs x2`.
   - Fallback fires: `_inferValueType(p1) = VData("And", _)`, `_isPropSorted(VData("And", _)) = dataDecl.sort == TProp = true`.
   - Same for `p2`. Irrelevance admits. ✓

   **Worked counterexample (irrelevance declines).** Two propositions `P1 ≠ P2 : Prop`:
   - Structural conv fails.
   - Fallback: `_inferValueType(P1) = VProp`, `_isPropSorted(VProp) = false`.
   - Irrelevance declines; mismatch returned. ✓

   **Worked counterexample (irrelevance declines across Type).** Two `Nat` values `succ zero` vs `zero`:
   - Structural conv fails (different ctors).
   - Fallback: `_inferValueType(succ zero) = VData("Nat", [])`, `_isPropSorted(VData("Nat", _)) = dataDecl.sort == TProp = false` (Nat is Type-sorted).
   - Irrelevance declines; mismatch returned. ✓

4. **Registry access — the loop-local route.** `_inferValueType` needs `List<DataDecl>` to resolve `VData.name` to its `sort`. Rather than adding a `dataDecls` field to every `_Conv` / `_ConvThen` / `_ConvPairLeft` / `_ConvThenOpen` frame (20+ call sites), we store the registry **once per `_drive` invocation** as a loop-local variable. Public API entries (`conv`, `infer`, `check`, `nf`) accept an optional `List<DataDecl>` and seed `_drive`'s local at entry. Irrelevance reads it; nothing else does. Zero per-frame overhead, zero call-site churn. Backwards-compatible: existing callers that pass no registry get the current behaviour (irrelevance declines to fire, structural conv proceeds as before). `check.dart` / `elab.dart` sites that type-check real programs already have `ctx.dataDecls` and will thread it explicitly.

5. **Termination / soundness.**
   - `_inferValueType` doesn't recurse through conv. It's a structural classifier.
   - `_isPropSorted(VPi)` calls `apply(VLam(dom, codClosure), VNeutral(NVar(level)))` to open the codomain. This re-enters `_drive` with a fresh stack — the same pattern `_ConvThenOpen` (line 1122-1129) already uses when comparing Pi codomains. Bounded per call because `_drive` runs to completion before returning. Not a stack-safety regression: the re-entry depth is bounded by the term's Pi-nesting depth, which is already bounded by linear-time kernel invariants (SPEC §4.5).
   - The irrelevance check fires only at the mismatch arm — if structural conv succeeds, irrelevance is never consulted.
   - On irrelevance decline (either type returns null from `_inferValueType`, or either sort is not Prop), the original mismatch is returned unchanged. No existing program regresses.
   - On irrelevance admission, the soundness invariant is SPEC §8.2: Prop is definitionally proof-irrelevant. Any two values whose types' sort is Prop are equal by the calculus's rule. We're not weakening conv; we're implementing a rule the calculus already commits to.

6. **What this does NOT cover.** Irrelevance when values' types are stuck at a free variable (e.g., a proof whose type mentions an unresolved local `n`). `_inferValueType` returns `null` for `VNeutral` because we don't thread ctx through conv. For Phase 12's stdlib proofs this is not a gap — proofs of `Eq[Nat] x y` etc. reduce to canonical `VConstr(Eq, refl, ...)` whose type resolves to `VData("Eq", _)` directly. If Phase 14 surfaces a proof stuck at a local binder where irrelevance should fire, we extend by plumbing ctx at that point. Logged as a known-limitation.

**Pin tests (revised for meaningful coverage).**

Each test MUST be constructed so that structural conv would fail — otherwise irrelevance isn't exercised and the test passes with or without Step 0. The phrasing below is chosen to make structural failure unavoidable.

- *Positive #1 (kernel-level, irrelevance fires on conflicting inner args).* Declare a Prop-sorted type with two ctors: `data P : Prop { p1 : P; p2 : P; }`. Build two proofs `p1` and `p2` — both of type `P`, both Prop-sorted. Structural conv fails (different ctor names). Fallback: `_inferValueType(p1) = VData("P", [])`; `_isPropSorted(VData("P", _)) = dataDecl.sort == TProp = true`. Irrelevance admits. ✓ This test is the load-bearing one; it fails without Step 0 and passes with it. The minimal shape — two ctors of a Prop — is simpler than the earlier `And`-of-`P` draft and catches the same rule.
- *Positive #1a (same scenario, composed).* Same `P` as above, then `data Wrap : Prop { w : P -> P -> Wrap; }`. Build `w p1 p1` vs `w p2 p2`. Structural conv recurses into args and mismatches at the first `p1 vs p2`; irrelevance fires at the INNER mismatch (not the outer Wrap comparison). This exercises irrelevance-during-recursive-conv, which is where it actually matters for real proof composition.
- *Positive #2 (Pi codomain irrelevance).* Two functions `λn. conj P P p1 p1` and `λn. conj P P p2 p2` at type `(n: Nat) → And[P, P]`. Eta-opens to `conj P P p1 p1` vs `conj P P p2 p2` — same situation as #1 but one Pi deep. Exercises `_isPropSorted(VPi)` walking into the codomain.
- *Negative #1 (irrelevance does NOT fire — Type sort).* Two `Nat` values `succ zero` vs `zero`. Structural conv fails at the ctor-name mismatch. Fallback: `_isPropSorted(VData("Nat", _)) = false` (Nat is Type-sorted). Mismatch returned. ✓
- *Negative #2 (irrelevance does NOT fire — converting propositions themselves).* Two different propositions: `And[P, P]` vs `And[P, Q]` (where Q is a second Prop-sorted inductive distinct from P). Structural conv fails at the VData arg comparison (`P ≡ Q` is a mismatch). Fallback: `_isPropSorted(VProp) = false`. Mismatch returned. ✓ This guards against the "level-off" bug where we'd accidentally admit proposition equality.
- *Mechanical regression:* all 656 existing tests pass unchanged. No existing program relies on irrelevance; the rule is strictly additive.

**Note on "refl vs refl" — intentionally NOT a test of irrelevance.** Two canonical `refl A x` values convert structurally (both reduce to `VConstr("Eq", "refl", [A, x])`, matching pointwise). Irrelevance doesn't fire and isn't needed. A test using this shape would pass whether or not Step 0 is implemented; it's not a meaningful pin.

**Note on Pi test body shapes.** For the Positive #2 test to genuinely exercise irrelevance, the two lambda bodies MUST be structurally different AFTER eta-opening. If they reduce to the same canonical form (e.g. both become `conj P P p1 p1`), structural conv succeeds without irrelevance. The `p1 ≠ p2` asymmetry in the bodies is what makes irrelevance load-bearing.

**Non-negotiable:** Phase 14's stdlib proof composition relies on this. If Phase 12 skips Step 0 the stdlib forces the work retroactively, with a harder kernel retrofit and worse error recovery.

### Step 0.5 — Singleton elimination (generalise the §8.2 Prop-elim rule)

The Phase 11 step 8 Prop-elim fix rejects ALL Prop → Type elimination. That's conservative and correct for Phase 11 but blocks Phase 12: `Eq.rec` over a Prop-sorted `Eq` with a Type-sorted motive is exactly the elimination the §8.2 singleton exception was reserved for.

- **Rule** (SPEC §8.2 singleton-elim clause): admit Prop → Type match when the scrutinee's inductive has **at most one constructor AND that constructor has no informative args**. "No informative args" means every non-parameter arg of the ctor is either (a) Prop-sorted or (b) an index of the inductive (and therefore determined by unification against the scrutinee's indices, not a runtime value). This is stated generally — the kernel tests the data's shape, not its name. It accepts `Eq`, `True`, `And` and any other inductive of the same shape; it rejects `Or` (two ctors), `sigma`-style propositions carrying a Type-sorted witness, etc.
- **Implementation.** Replace the current `scrutineeData.sort is TProp ⇒ reject` check in `_CheckMatchScrutineeType` with: if Prop-sorted AND (ctors.length > 1 OR any ctor has an informative arg), reject. The informative-arg test walks each ctor's arg telescope and classifies each arg as `informative | prop | index` by consulting the data registry + the ctor's resultIndices metadata.
- **Pin tests (positive admissions):** `data PT : Prop { p : PT }` eliminates into Type; `data Conj[A: Prop, B: Prop] : Prop { conj : A -> B -> Conj[A,B] }` eliminates into Type (both args Prop-sorted).
- **Pin tests (negative rejections):** `data Disj[A: Prop, B: Prop] : Prop { inl : A -> Disj; inr : B -> Disj }` — TWO ctors, rejected; `data Sigma[A: Prop] (T: Type) : Prop { pack : T -> Sigma[A, T] }` — ctor has a Type-sorted arg, rejected.
- **Non-negotiable:** the rule is stated generally without reference to `Eq` by name. Lean 4 and Coq both do it this way (`inductive.cpp:elim_only_at_universe_zero`); name-based dispatch is a smell we explicitly avoid.

### Step 1 — Declare `Eq` as an ordinary indexed inductive in the prelude

- Create `lib/stdlib/prelude.doxa` (new file) with `data Eq[A: Type] (x: A) : A -> Prop { refl : Eq[A] x x; }`.
- Wire the prelude into the CLI and test harness: `checkSource` prepends the prelude's elaborated TopEnv before user code. Users never import it — it's ambient, matching Lean 4's `Init/Prelude.lean` discipline.
- Pin: `test/programs/positive/eq_decl_visible.doxa` — references `Eq` without declaring it, expects the prelude to resolve.
- Sanity: `Eq.rec`'s synthesized type lives in Prop (general rule) and, for Type-sorted motives, type-checks through the Step 0.5 singleton-elim path. This is what makes `subst` work.

### Step 2 — Auto-`refl` elaborator rule

- Hook into the check-mode path for `SIdentKind("refl")`: when the expected type's head is `Eq[A] x y` and `conv(A-level, x, y)` succeeds, synthesize `TConstr("Eq", "refl", [A, x])`. The elaborator looks up `"Eq"` as a hardcoded name string (matches Lean's `mkEqRefl`); the kernel stays uniform.
- When the `conv` fails, raise `TypeMismatch` citing the two sides with the innermost `diff` (reuses Phase 6 machinery).
- When the expected type doesn't have `Eq` at its head, fall through — `refl` without an `Eq` context is `UnresolvedName`.
- Pin: `val p : Eq Nat (plus two three) five = refl` type-checks; `val q : Nat = refl` fails with a helpful error.

### Step 3 — Derived library in `lib/stdlib/eq.doxa`

Seeded in Phase 12; expanded in Phase 14. Each lemma is a `val` whose body is an explicit `Eq.rec` / `Eq.rect` invocation.

- `sym   : (A: Type) -> (x y: A) -> Eq[A] x y -> Eq[A] y x`.
- `trans : (A: Type) -> (x y z: A) -> Eq[A] x y -> Eq[A] y z -> Eq[A] x z`.
- `cong  : (A B: Type) -> (f: A -> B) -> (x y: A) -> Eq[A] x y -> Eq[B] (f x) (f y)`.
- `subst : (A: Type) -> (P: A -> Type) -> (x y: A) -> Eq[A] x y -> P x -> P y`.

**Multi-recursor bridge (2026-04-23 pivot).** The initial design assumed a single `Eq.rec` would serve all four lemmas. During implementation it became clear that `Eq.rec`'s motive slot is fixed to the data's declared sort (`Prop`), which works for `sym`/`trans`/`cong` (their motives return `Eq[A] _ _ : Prop`) but not for `subst` (motive returns `P a -> P b : Type`).

The principled fix — sort-polymorphic `Eq.rec` — requires universe polymorphism (v3). For v2, we take the Coq-historical approach: **auto-emit two recursors per Prop-sorted singleton inductive**. `T.rec` (default, motive target = data's sort) and `T.rect` (motive target = `Type 0`). The latter is emitted only when [admitsSingletonElim] returns true. Universe poly in v3 collapses the pair into a single sort-polymorphic recursor.

Kernel deltas:
- `TRec(dataName, motiveSort: Term?)` — optional override for the motive target sort. Default null = data's sort. Equality and reduction are name-only; the discriminator affects only `infer(TRec)`'s synthesized type.
- `synthRecursorType(d, {motiveSort: Term?})` — threads the override into `_synthMotiveType`.
- `_makeRecBindings(env, dataDecl, span)` — emits `T.rec` always; additionally emits `T.rect` with motive target `Type 0` when `admitsSingletonElim(dataDecl, ctx)` holds.
- `admitsSingletonElim` exposed as a public helper so the elab site can decide.

Phase 13 rewrites the stdlib lemmas in implicit style (`{A}`, `{x}`, etc.). Once universe poly lands, the `T.rect` variant gets folded back into `T.rec` and the multi-recursor scaffolding retires.

### Step 4 — Programs + proofs

- `plus_zero : (n: Nat) -> Eq[Nat] (plus n zero) n` — induction on `n` via `match`: base = `refl`, step = `cong succ`.
- `plus_succ : (m n: Nat) -> Eq[Nat] (plus m (succ n)) (succ (plus m n))` — induction on `m`.
- `plus_comm : (m n: Nat) -> Eq[Nat] (plus m n) (plus n m)` — the capstone, composes `plus_zero` + `plus_succ` via `trans` + `cong`.

Each shipped as a curated `.doxa` program under `test/programs/positive/` with end-to-end CLI coverage.

### Step 5 — Audit

Walk SPEC §3, §4, §8.2 singleton-elim, §8.9 Eq rule-by-rule. Landmines to guard against:

- **Prop-irrelevance across `Eq`.** Two proofs of the same `Eq[A] x y` should convert by §8.2 Prop-irrelevance. Pin a test: `p q : Eq[Nat] zero zero` with distinct surface forms (e.g. `refl` vs `sym (sym refl)`) convert.
- **Singleton-elim corner cases.** `Eq[A] x y` with `A` itself Prop-sorted: still admits singleton-elim into Type? Yes — `A`'s sort doesn't affect the ctor's informative-arg classification. Pin.
- **K-freeness.** The K axiom (UIP) must *not* be derivable. Pin a negative: any attempt to prove `(A: Type) -> (x y: A) -> (p q: Eq[A] x y) -> Eq (Eq[A] x y) p q` without assuming K fails. Current Doxa makes this fail by the motive-restriction in `Eq.rec`'s synthesised type — there's no special-case code needed, it falls out of the general eliminator rule.
- **Substitution under binders.** `subst (P := (n: Nat) => Vec[A] n) ... v` — the motive is a function whose body uses the quantified variable. Pin an end-to-end program exercising this.
- **Eq at Prop sort.** `Eq[Bool_prop] p q` where `Bool_prop : Prop`. Prop-irrelevance applies to the Eq type AND to its arguments. Pin.

**Step 5 completion notes (2026-04-23).**

Walked each landmine; results summarised below.

- *Landmine 1 — Prop-irrelevance across Eq*: covered by existing `test/conv_test.dart` "Prop definitional proof irrelevance" suite (6 pins). Two distinct refl-shapes of `Eq[Nat] zero zero` admit by irrelevance; propositions themselves don't over-admit. ✓
- *Landmine 2 — Eq at Prop sort*: **blocked by v2 Eq-param-must-be-Type restriction**. `Eq[A]` is declared with `A: Type`; `Eq[SomeProp] p q` fails at typecheck. This is a v3 universe-polymorphism item. Documented in SPEC §8.9 as a known limitation.
- *Landmine 3 — K-freeness (UIP not derivable)*: **holds in v2 via the stronger "UIP not statable" mechanism.** Pinned by `test/programs/negative/uip_not_statable.doxa`. UIP requires `Eq[Eq[A] x y]` which puts a Prop in a Type-param slot and fails at typecheck. v3 universe-poly shifts this to the standard motive-restriction mechanism (UIP statable but not derivable). Both preserve K-freeness.
- *Landmine 4 — Substitution under binders*: ✓ works. Pinned by `test/programs/positive/subst_under_binder.doxa`: `subst Nat P zero zero (refl ...) v` where `P : Nat -> Type` is the motive `(n: Nat) => Vec[Nat] n`.
- *Landmine 5 — Eq at Prop sort argument shape*: same as Landmine 2. One limitation, two faces.

Overall: Phase 12 ships with a clean internal audit. Two landmines (2 and 5) surfaced the same v3 carry-forward item; SPEC §8.9 now documents it explicitly. The other three are either pinned or provably enforced by existing structural mechanisms.

**Exit:** `plus_comm` type-checks through the CLI. `lib/stdlib/prelude.doxa` + `lib/stdlib/eq.doxa` exist and are reused by Phase 14. A handful of `Nat`/`List` proofs in `test/programs/positive/` pin real-world usage. No new kernel term forms introduced — Eq lives entirely in the registry.

---

## Phase 13 — Meta-variables, pattern unification, implicit arguments

**Goal:** The language becomes ergonomic. `id three` instead of `id Nat three`. This is one of the largest single kernel phases; everything earlier was a stepping stone.

**Carry-forward items landing here:**
- Phase 10 §8.4 limitation 1: header independence in mutual `data` blocks (`data A : B -> Type and data B : Type`). Signature elaboration under metas resolves forward references naturally.
- Phase 11 step 5: the `MotiveInferenceRequiresUnification` cases. Once pattern unification lands, these cases flip from diagnostic to acceptance.
- Phase 11 step 6: the structural-recursion walker's `args[0]` simplification (elab.dart:1566-1576). With implicits, `f[TypeArg] x` desugars to `f x` at the call site and the walker only sees value args; the per-callee type-param count plumbing never has to be built.

### Step -1 — Prior-work review

Before any design or code, read the canonical references end-to-end. Deliverable: a single design note (either as a PLAN section or `lib/src/eval.dart` doc block) citing each decision's source.

**Required reading:**
- **Miller 1991**, "A logic programming language with lambda-abstraction, function variables, and simple unification" — the original pattern-unification fragment.
- **Abel & Pientka 2011**, "Higher-order dynamic pattern unification" — the modern formulation, closer to what implementations ship.
- **Kovács's elaboration-zoo** (series of minimal implementations on GitHub) — the most directly applicable reference for our defunctionalized-driver architecture. Especially `04-implicit-args` and `06-first-class-poly`.
- **Lean 4 kernel and elaborator source** — `src/kernel/type_checker.cpp` for the conversion layer, `Lean/Elab/Term.lean` + `Lean/Meta/*` for elaboration. The "how do metas thread through a real production kernel" reference.
- **Coq kernel's `evar.ml` + `typing.ml`** — alternative design point for comparison. Coq's evar-map is similar to what we'll need.

**Deliverable (design note):**
1. Which source(s) we follow for pattern unification (our pick: Kovács + Abel & Pientka, with Lean 4 as a cross-check).
2. Where `TMeta` appears in the term ADT.
3. How the existing `_Check` / `_Infer` / `_Apply` / `_Conv` frame dispatch handles `TMeta`.
4. Meta context data structure and owner (driver vs. elaborator).
5. When solving happens — greedily vs. batched at declaration boundaries.
6. Answers to the three forward-compat requirements below.

### Step 0 — Forward-compatibility requirements

The meta infrastructure is substrate for three LATER features in this same plan. Step -1's design note must verify all three are reachable without a meta-context reshape:

1. **Level-polymorphic metas (Phase 15).** Phase 15 will generalize over universe levels. Metas whose "sort" is a universe level (not a term of a fixed type) must be representable in the same meta context. Concrete test: can the meta entry structure hold `level_meta` alongside `term_meta` without a union dance? If yes, Phase 15 lands additively; if no, Phase 15 forces a meta-context rewrite.

2. **Typeclass / instance-search hooks (Phase 21).** Typeclass resolution is pattern-unification extended with "try each candidate from a search table." The `_Conv` path that triggers unification must be extensible to "before declaring mismatch, consult a candidate list." Concrete test: does Step 0's dispatch let us hook in a pre-unification candidate source without restructuring? If yes, Phase 21 is additive; if no, it forces a second rewrite.

3. **Tactic state (Phase 20).** Tactics manipulate the meta-context by observing unsolved metas + proposing solutions. The meta-context must be snapshotable and restorable for tactic backtracking, and observable enough that a tactic engine can inspect unsolved metas and their local contexts. Concrete test: can the meta context be snapshot-and-restored cleanly around a tactic invocation? If the context entangles with non-meta state, Phase 20 forces a third rewrite.

**Additionally** — because Phase 15 and Phase 16 are close behind Phase 13 — Step -1's design note must include paper-design sketches for:
- **Phase 15's `Level` datatype and how it interacts with the meta context.** Even if the sketch is rough, it confirms Phase 13's decisions don't preclude Phase 15's choices.
- **Phase 16's SProp sort and its interaction with `_isPropSorted`.** A few sentences confirming the Prop-irrelevance classifier generalises to multi-sort.

**Rule:** no Phase 13 implementation code until Step -1's design note is written AND the five forward-compat questions are visibly answered. Universe representation + meta-context shape must be co-designed; discovering a conflict in Phase 15 would cost more than the upfront design cost.

### Step -1 design note (2026-04-24, completed)

Prior-work review pass completed. Key reference implementations consulted: Kovács's elaboration-zoo (`03-holes`, `04-implicit-args`); Lean 4 kernel + elaborator (`src/Lean/MetavarContext.lean`, `src/Lean/Meta/ExprDefEq.lean`, `src/Lean/Elab/Term.lean`, `src/Lean/Level.lean`, `src/Lean/Expr.lean`); Coq evar machinery (`engine/evd.ml`, `pretyping/evarconv.ml`, `kernel/constr.ml`). Papers: Miller 1991 (pattern fragment), Abel & Pientka 2011 (dependent pattern unif + pruning), Kovács 2020 ICFP (first-class implicit function types).

**Locked-in design decisions for Phase 13:**

1. **Pattern-unification source:** transcribe Kovács's `elaboration-zoo/03-holes/Unification.hs` directly. Miller 1991 §4 is the formal rule-level spec; Abel & Pientka 2011 §3–§4.2 covers pruning. Lean 4 is cross-check only, not the transcription target — its Haskell/C++ structure diverges from our defunctionalized-driver architecture more than Kovács does. Kovács's `unify` maps 1-to-1 to a `_Conv`-style dispatch (~150 lines in the reference) and was written against an NbE-with-closures backbone structurally identical to ours.

2. **Meta-context data structure:** elaborator-owned `List<MetaEntry>` indexed by int ID. `MetaEntry` is a sealed class; Phase 13 adds `TermMetaUnsolved(Value typeExpected, Ctx local)` and `TermMetaSolved(Term solution)`, Phase 15 adds `LevelMetaUnsolved` and `LevelMetaSolved(Level)` additively (no union dance, polymorphic dispatch same pattern as `_Step`/`_Frame`). Mutation of the meta-context stays in the elaborator layer — `_drive`'s "no Dart call to another semantic function" invariant is preserved because meta reads are local `Ctx` field accesses. Lean 4 uses a persistent hash-map (`Lean.MetavarContext.decls`); Coq uses a functional OCaml map (`Evd.evar_map`); both overkill for our scale. Kovács's mutable int-keyed array is the right shape.

3. **Term + value ADT extensions:** `TMeta(int id)` as a new `Term` variant alongside `TBound`/`TFree`/`TApp`/... `NMeta(int id)` as a new `Neutral` variant alongside `NVar`/`NApp`/`NStuck` — NOT wrapped in `NStuck(VMeta)`. Making `NMeta` a first-class `Neutral` subclass keeps the exhaustive `switch` dispatches (conv, apply, quote) finding it by type, matching the defunctionalized-driver's "new ADT case, not new driver function" discipline. Lean 4 confirms this shape: `Expr.mvar` is a first-class ctor.

4. **Dispatch touchpoints:** extending `_Eval`, `_Apply`, `_Conv`, `_Quote` with `TMeta`/`NMeta` cases. NO new `_Step` or `_Frame` types needed. The four cases are:
   - `_Eval(TMeta(id), env)`: if solved, continue with `_Eval(solution, env)`; else yield `VNeutral(NMeta(id))`.
   - `_Apply(VNeutral(NMeta(id)), arg)`: extend neutral spine via `NApp(NMeta(id), arg)` — same rule as `NVar`.
   - `_Conv(VNeutral(NMeta(id) spine), t, level)`: new case that dispatches to the unifier (the single semantic hook for Phase 13).
   - `_Quote(VNeutral(NMeta(id) spine), level)`: quote to `TMeta(id)` applied to the quoted spine.

5. **Solving strategy:** greedy. Matches all three references (Lean 4, Coq, elaboration-zoo). Backtracking wrapping is snapshot+restore from question (7b) below, deferred to Phase 20.

6. **Pattern-fragment edge cases:** transcribe Kovács verbatim.
   - **Flex-flex** `?m σ ≡ ?m' σ'`: same-meta pointwise-spine comparison; different-meta → `UnsolvedMetavariable`. Abel & Pientka 2011 §4.3 intersection-meta case cited as future extension, not a Phase 13 blocker.
   - **Pruning**: detect via `prune`/`strengthen` traversal; defer with `UnsolvedMetavariable("pruning required, not implemented")` on non-trivial cases.
   - **Occurs check** `?m ≡ f ?m`: Kovács's `occurs` traversal before commitment. O(solution size), bounded by linear-time invariant.

7. **Forward-compat answers:**
   - **(a) Phase 15 level metas.** `MetaEntry` sealed hierarchy absorbs level-meta variants additively. Lean 4 confirms: `Level.mvar` and `Expr.mvar` are distinct ctors with distinct ID namespaces. Phase 15 adds `LevelMeta*` subclasses; driver dispatch extends by one more sealed case. **No meta-context reshape needed in Phase 15.**
   - **(b) Phase 20 tactic snapshot.** Append-only log + watermark. Record `ctx.metas.length` before tactic; on failure truncate back + re-null any entries whose ID ≥ snapshot and were solved within the failed attempt (tracked via a "modified-since-watermark" auxiliary list). O(delta), matches linear-time invariant. Lean 4's `withNewMCtxDepth` / `saveState` underneath uses a structural copy; our watermark is strictly lighter.
   - **(c) Phase 21 typeclass candidate-list hook.** Hook sits at **entry to pattern unification**, not inside `_Conv`. When `_Conv` hits `VNeutral(NMeta(id))` against an expected `VData("C", args)` where `C` is a class, the unifier consults `ctx.instances[C]` before declaring unsolved. `_Conv` itself is untouched. Lean 4's `synthesizeSyntheticMVars` sits at the same architectural position.

8. **`{A}` implicit / `[A]` explicit coexistence.** No incompatibility. `[A]` is an explicit type-parameter telescope (Phase 9 design, preserved); `{A}` is an implicit parameter resolved by elaboration. Both compile to identical `TPi` + `TLam` in the kernel. Elaboration rule transcribed from Kovács `04-implicit-args/Elaboration.hs:insert`: during `_Infer` of an application `f x`, if the inferred type of `f` is `VPi(_, _, icit=Implicit)`, insert a fresh meta `?m` and continue with `f ?m x`. Repeat while the leading Pi is implicit, then resume normal explicit application.

9. **Phase 15 + Phase 16 compatibility sketches.** (Required by Step 0's cross-phase rule.)
   - **Phase 15 Level datatype:** `sealed class Level { LevelConst(int) | LevelVar(int) | LevelMax(Level, Level) | LevelSucc(Level) }` following Lean 4's algebraic-levels style (simpler than Coq's constraint graph, sufficient for stdlib purposes). `VType(Level)` replaces `VType(int)` additively; old call sites pass `LevelConst(n)`. Sort comparison extends `_piSort`/`_subtype` with a level-constraint walk. Phase 15 design note (pending) will finalize algebraic-vs-per-decl choice; Phase 13 decisions are compatible with both.
   - **Phase 16 SProp sort:** `VSProp` added to the sort hierarchy alongside `VProp`, `VType(level)`. `_isPropSorted` (currently at `lib/src/eval.dart:_isPropSorted`) generalises from "classify as Prop-sorted" to "classify into {SProp, Prop, Type}" via a `Sort` enum or sealed class. The Prop-irrelevance conv short-circuit becomes SProp-irrelevance too when applicable. Additive; no reshape of Phase 12's infrastructure.

10. **Key file references in the current kernel:**
    - `lib/src/eval.dart:1-220` — driver invariant, `_Step`/`_Frame` ADTs (the extension points).
    - `lib/src/value.dart:284-336` — Neutral hierarchy (where `NMeta` fits).
    - `lib/src/term.dart:22-400` — Term ADT (where `TMeta` fits).
    - `lib/src/env.dart:64-220` — persistent `Env` (confirms meta-context is a separate structure).
    - `lib/src/ctx.dart` — `Ctx` is the right owner for the meta-context field.

**Exit from Step -1:** design note above is concrete enough to start Step 1 implementation without re-deriving anything. All five forward-compat checks have explicit answers.

### Step 1 — Meta-context + `TMeta` kernel term

- `TMeta(int id)` kernel term alongside `TBound`/`TFree`/`TApp`/... in `lib/src/term.dart`.
- `NMeta(int id)` as a new `Neutral` subclass alongside `NVar`/`NApp`/`NStuck` in `lib/src/value.dart`. NOT wrapped in `NStuck(VMeta)` — first-class subclass keeps exhaustive-switch dispatch.
- Meta context: `List<MetaEntry>` in `Ctx` indexed by int ID. `MetaEntry` is a sealed class with `TermMetaUnsolved(Value typeExpected, Ctx local)` and `TermMetaSolved(Term solution)` subclasses. Mutation lives in the elaborator layer, not in `_drive`.
- Driver dispatch extends with four new cases (all sealed-ADT additions, no new `_Step` or `_Frame` needed):
  - `_Eval(TMeta(id), env)` — solved → continue with solution; unsolved → `_YieldV(VNeutral(NMeta(id)))`.
  - `_Apply(VNeutral(NMeta(id)), arg)` — extend spine.
  - `_Conv(VNeutral(NMeta(...) spine), t, level)` — hand off to unifier (single semantic hook).
  - `_Quote(VNeutral(NMeta(id) spine), level)` — quote back to `TMeta(id)` with quoted spine.

### Step 2 — Pattern unification (decidable fragment)

Implement Miller's pattern fragment: a unification problem `?m x₁ … xₙ ≡ t` where `x₁ … xₙ` are distinct bound variables and `t` doesn't mention any other meta. Solution: `?m := λx₁ … λxₙ. t`.

- Build on top of the existing `_Conv` driver: when conversion hits a `VMeta`-headed neutral on one side, defer to pattern-unification logic instead of declaring a mismatch.
- Flex-flex pairs (`?m args ≡ ?m' args'`): reduce to variable renaming when args align, defer otherwise.
- Pruning (a meta's solution must not mention vars that weren't in its argument list): detected and either solved restrictively or raises `UnsolvedMetavariable` with a "pruning required, not implemented in v2" diagnostic.
- Occurs check: `?m ≡ f ?m` → error.

**Reference:** Miller 1991; Abel & Pientka 2011; Kovács's elaboration-zoo for a readable reference implementation.

### Step 3 — Implicit-argument surface syntax and insertion

Step 3 runs in two parts. Part A lands the surface syntax (`{A: Type}`-delimited type-parameter groups in `fun` declarations, icity threaded through `TPi`/`TLam`/`VPi`/`VLam`). Part B rewrites the expression elaborator in bidirectional style, a prerequisite for automatic insertion and for every downstream feature that wants type-driven elaboration (coercions, literal overloading, typeclasses, tactics).

**Part A (completed 2026-04-24, commits `cf07686` + `61ad02e`):** `Icit` enum in term.dart; `icit` field on `TPi`/`TLam`/`VPi`/`VLam` participating in `==`/`hashCode`; `SFunTypeParam(name, kind, isImplicit)` in surface.dart; `_funTypeParams` parser combinator supporting `[A]` explicit + `{A}` implicit groups in any order; `_FunBinder` internal record in elab.dart feeding `_buildFunBody`/`_buildFunType` with per-binder icity. Icity is faithfully recorded in the kernel but does not yet drive any call-site behaviour.

### Step 3 part B — Bidirectional elaboration (design note, 2026-04-24)

**Strategic framing.** The unidirectional signature `Term _elabExpr(TopEnv, _LocalScope, SExpr)` that Phases 9–12 shipped with is an infer-only elaborator — every position produces a `Term` without knowing what type was expected. That is sufficient for a reference kernel but is a ceiling for any codebase written on top of Doxa. The capabilities that ride on bidirectional flow (expected-type-driven literal overloading, coercion insertion, dot-selection, return-type-driven typeclass resolution, tactic hooks at check-sites) are not Phase 13 features, but they all assume the elaborator already has an `expected: Value?` channel when they land. Deferring that channel to Phase 20/21 would force a retroactive rewrite of every expression case in `_elabExpr`, every call site, and every test. Landing it now — while the elaborator is still ~800 lines — is strictly cheaper.

The pivot's velocity argument cut the other way initially (elab-zoo-style greedy infer-only is ~3 days; bidirectional is ~2 weeks), but only under the assumption that nothing downstream consumes Doxa as a dependency. Fungal's bootstrap plan (use Doxa-in-Dart as Fungal's proof kernel until Fungal self-hosts) makes that assumption wrong: the first real consumer of this elaborator is a compiler developer writing specs in it. They would hit an ergonomic ceiling in week one.

**Reference transcription target.** Kovács's `elaboration-zoo/04-implicit-args/Elaboration.hs`. The file pairs a `check :: Raw -> VTy -> Tm` function with an `infer :: Raw -> (Tm, VTy)` function; the two dispatch on each other exactly as bidirectional type theory prescribes, and the insertion rules for implicit arguments hang off the `infer → check` transition. Lean 4's `Elab.Term.elabTerm` is the industrial-strength cross-check, but its structural shape is heavier (`Expected`/`NoExpected` monad layers, metavar context passing explicit), so Kovács is again the transcription target and Lean 4 the validation reference.

**Locked-in design decisions:**

1. **API shape.** Replace `Term _elabExpr(TopEnv, _LocalScope, SExpr)` with two mutually recursive functions:
   - `(Term, Value) _inferExpr(Ctx, SExpr)` — no expected type; returns elaborated term paired with its inferred type as a `Value`.
   - `Term _checkExpr(Ctx, SExpr, Value expected)` — returns only the elaborated term; the type is already known.

   Both take a full `Ctx` (not just `_LocalScope`) because type-checking sub-terms requires `Ctx.lookupType`, `Ctx.level`, and `Ctx.metas` — all already present as of Phase 13 Step 2. `_LocalScope` becomes redundant (it was always a subset of `Ctx` in disguise) and is deleted.

2. **Default direction per syntactic form.**
   - `SIdentKind`, `SDotKind`, `SAppKind`, `SMatchKind` — infer by default; the identifier's type comes from `Ctx`/`TopEnv`, application elaborates its head in infer mode and checks the arg against the domain.
   - `SLamKind`, `SLetKind` (unannotated form, if we ever add it) — check-preferred; a lambda with no domain annotation forces its shape from the expected type. With an annotation, infer still works.
   - `SPiKind`, `SForallKind`, `STypeKind`, `SPropKind` — infer (they're type-formers, their result sort is computed).
   - `SMatchKind` — check-preferred (the motive synthesis in Phase 11 Step 5 already wanted this; bidirectional lets that case succeed without heroics).

3. **Infer-at-a-check-site fallback.** The canonical bidirectional bridge: when `_checkExpr(ctx, expr, expected)` reaches a syntactic form that is best handled in infer mode, it calls `_inferExpr(ctx, expr)` and then unifies the inferred type against `expected` via `conv(ctx, inferred, expected)`. In Kovács this is the `infer-then-unify` arm of `check`. Our unifier (Phase 13 Step 2) is already `Ctx`-aware, so this arm is a single function call, not a rewrite.

4. **Implicit-argument insertion rule.** Transcribed from Kovács `04-implicit-args/Elaboration.hs:insert` and `insert'`:
   - After `_inferExpr` returns `(headTerm, headType)`, if `headType` is `VPi(_, _, Icit.implicit)`, immediately insert a fresh meta and apply: `(TApp(headTerm, TMeta(m)), apply(headType, VMeta(m)))`. Loop while the leading Pi is implicit.
   - At application sites specifically (`_inferExpr(SApp(f, x))`), insert implicits between the function and the explicit argument. If the user wants to pass an implicit *explicitly* at a specific position (e.g., `id {Nat} zero`), Step 3 part B does NOT yet parse that surface form — it is added in Step 3 part C, after the bidirectional machinery is in place. Bracketed explicit implicits are sufficiently rare that pinning Part B on a shippable bidirectional elaborator first, then adding the surface form, is the right sequencing.
   - `UnsolvedMetavariable` diagnostic fires at end-of-top-level-binding if any meta inserted for that binding remains unsolved after all check/infer passes.

5. **Meta insertion in check mode.** When `_checkExpr(ctx, expr, expected)` is entered and `expected` is `VPi(_, _, Icit.implicit)`, the checker does NOT insert a meta — it introduces an implicit lambda automatically. This is Kovács's `check` rule for implicit Pi: `check Γ e (Pi x {A} B) = Lam x {A} (check (Γ, x:A) e B)`. Matches Lean 4's `elabBinders` expansion and Agda's implicit-Pi rule.

6. **Ctx extension.** `Ctx` already carries `metas: MetaContext?` (Phase 13 Step 2). No further field additions are needed. `_LocalScope` → `Ctx` migration is pure plumbing.

7. **Block migration order.** Expression elaborator is rewritten in-place (no parallel "new elaborator" branch). Each syntactic form migrates one at a time, with the old `Term _elabExpr` kept as a thin `infer → discard type → return term` shim during the transition. Tests stay green at every commit. The shim is deleted when the last call site no longer needs it.

8. **What Part B does NOT do.**
   - No coercion machinery. Coercion insertion is a later phase's elaboration pass *on top of* bidirectional flow; Step 3 ships the substrate.
   - No overloaded-literal resolution. Numeric literals stay monomorphic until typeclasses land (Phase 21).
   - No dot-notation type-driven selection. Phase 18 (modules) decides dot-notation semantics.
   - No typeclass hooks. The `_inferExpr` → `_checkExpr` transition has a documented extension point where Phase 21 will plug in instance resolution, but Phase 13 does not consume it.

9. **Forward-compat check against Phases 14–21.**
   - **Phase 14 (stdlib):** implicit-style combinators (`id`, `compose`, `const`) work out of the box.
   - **Phase 15 (universe poly):** level metas slot in via the same `MetaEntry` sealed hierarchy; the bidirectional elaborator's expected-type channel carries sort info automatically.
   - **Phase 16 (SProp):** SProp-vs-Prop-vs-Type classification happens at `_inferExpr` for sort-producing forms; no Step 3 interaction.
   - **Phase 17 (records with η):** record projections elaborate in check mode preferentially (η-expansion drives from expected type).
   - **Phase 18 (modules):** dot-notation reads from expected type when checking; plugs in at the check-site fallback documented in (3).
   - **Phase 19 (ergonomic edges):** coercion insertion plugs in at the `conv(inferred, expected)` call site in (3).
   - **Phase 20 (tactics):** tactic macros run in check mode, consuming `expected` as the goal.
   - **Phase 21 (typeclasses):** instance resolution plugs in at the `_checkExpr`-meets-class-valued-`expected` site.

10. **Exit criteria for Step 3 part B.**
    - Every case of the old `_elabExpr` has been migrated to either `_inferExpr` or `_checkExpr` with the correct default direction.
    - Implicit insertion works: `fun id{A: Type}(x: A): A = x` followed by `val three: Nat = id zero ... succ zero` (or any position where the caller elides the type argument) type-checks.
    - Zero regressions in the existing 712-test suite.
    - New tests covering: call-site implicit insertion (success); implicit insertion followed by unification (e.g., `id zero` solves `?A := Nat`); unsolved-meta diagnostic when inference genuinely underdetermines (e.g., `id` used in expected-type-free position).
    - Step 3 part A's surface syntax is exercised end-to-end by at least one implicit-style stdlib combinator in the test corpus.

11. **Step 3 part C (after part B, still within Phase 13).**
    - Surface syntax for explicit implicit arguments: `id {Nat} zero` at call sites. Parses to a new `SExpr` variant carrying `{...}`-delimited args alongside explicit args.
    - Elaboration: when an explicit implicit is provided, insertion skips the auto-meta and uses the user's term.
    - Tests for interleaved `id {Nat} zero` vs auto-inserted `id zero`.

### Step 4 — Solved-in-Phase-11 cases flip

- Revisit Phase 11's `MotiveInferenceRequiresUnification` programs. With pattern unification available, the dependent motive for `Vec.head`-style programs is now solvable. Delete the Phase 11 negative program `motive_needs_unification.doxa` (or promote it to positive) and verify it type-checks.
- Revisit Phase 10's mutual-data header-independence limitation. `data A : B -> Type and data B : Type` now elaborates: the header of `A` produces a metavariable for `B`, which the sibling pass resolves.

### Step 5 — Migration of seed stdlib to implicit style

- Rewrite `lib/stdlib/eq.doxa`'s `sym`, `trans`, `cong`, `subst` using `{A: Type}` implicit. Verify byte-identical behaviour at runtime; only the surface shape changes.
- Migrate `id`, `k`, `s` from `test/programs/positive/` to implicit. Preserve the explicit versions under a `programs/explicit/` subdir as reference for early-phase regression.

### Step 6 — Audit

- Meta well-foundedness: no unsolved meta survives to a final typechecked term. Pin a test that attempts to construct one and verifies the diagnostic.
- Pattern-unification corner cases (flex-flex, occurs, pruning) each pinned.
- Elaboration order independence: `id` used before `id` is fully elaborated (inside a mutual block) still works.
- Phase 11 deferred cases all flip; Phase 10 limitation 1 closes.
- Three forward-compat requirements re-verified against actual implementation (not just design note).

**Exit:** The stdlib from Phase 14 is writable in natural style, not `id Nat three` style. The two Phase 10/11 carry-forward items close.

---

## Phase 14 — Standard library (initial, monolithic)

**Goal:** An actual working library users can depend on, exercising the full Phase 9-13 kernel simultaneously. The proofs file (`proofs.doxa`) is the real exit test because every proof in it transitively depends on every CIC feature landed so far.

**Note.** Phase 14's stdlib is flat — all files live in `lib/stdlib/` without module boundaries. Phase 18 reorganises into proper modules once import machinery lands. Phase 15 universe polymorphism then rewrites the lemmas in sort-polymorphic style. Phase 14's purpose is to exercise the Phase 13 machinery end-to-end, not to ship the final stdlib shape — each downstream phase revises.

### Step 1 — Data + combinators

- `lib/stdlib/nat.doxa`: `Nat` (already landed in Phase 10 tests; canonicalised here), `plus`, `mult`, `pow`, `leq`.
- `lib/stdlib/bool.doxa`: `Bool`, `and`, `or`, `not`, `if_`.
- `lib/stdlib/list.doxa`: `List[A]`, `map`, `fold`, `filter`, `length`, `append`, `reverse`.
- `lib/stdlib/option.doxa`: `Option[A]`, `map`, `getOrElse`.
- `lib/stdlib/vec.doxa`: `Vec[A] : Nat -> Type`, `vhead`, `vtail`, `vappend` (dependent indices throughout).

Written in natural implicit style (post-Phase-13). No explicit type passing except where implicit resolution legitimately can't see the type.

### Step 2 — Equality library

- `lib/stdlib/eq.doxa`: `sym`, `trans`, `cong`, `subst`, plus `cong2` for two-argument congruence.

### Step 3 — Proofs

- `lib/stdlib/proofs.doxa`: `plus_zero`, `plus_succ`, `plus_comm`, `plus_assoc`, `mult_zero`, `mult_one`, `append_nil`, `append_assoc`, `map_compose`, `length_append`.

### Step 4 — CI wiring

- Add a workflow step running `dart run bin/doxa.dart check lib/stdlib/*.doxa`. The stdlib files exist at a fixed location; the CI step is a single shell line plus the exit-code check.
- Add a unit test (`test/stdlib_test.dart`) that does the same thing inside the Dart test harness, so local `dart test` flags breakage too.

Each file is both a library and a regression test. No ancillary test infrastructure — the stdlib's existence + successful type check is the test.

**Exit:** `doxa check lib/stdlib/*.doxa` succeeds on all files locally and in CI. Every proof in `proofs.doxa` type-checks, confirming the `inductive + match + Eq + implicits` machinery works end-to-end.

---

## Phase 14.5 — Quotient Types

**Goal.** Add quotient types as kernel primitives: `Quot(A: Type)(R: A → A → Prop)`,
`Quot.mk(a)`, `Quot.lift(f, proof)`. Two elements of a quotient are definitionally
equal when the quotient was constructed from the same equivalence class.

**Why this phase exists.** The original plan (Phases 15-22) assumed Doxa would stay
intensional and quotient-free. The kernel is now verified through Phase 14 and the
tooling stack is complete. Quotients are the single biggest capability gap between
Doxa and Lean/Coq/Agda — they unlock real numbers, finite sets, modular arithmetic,
and any construction that needs equivalence classes. Adding them after Phase 15's
universe polymorphism would require retrofitting the Level datatype through quotient
code; adding them before Phase 15 lets quotient terms benefit from the Level upgrade
during Phase 15. They are orthogonal to Phases 15-22.

**Prior work.**
- Lean 4 `Quot` in `Init/Prelude.lean` and `kernel/quot.cpp` — the single-constructor
  quotient with `lift` + `mk` computation rule. Lean's `Quotient` typeclass is built
  on top of kernel `Quot`.
- Coq's `Setoid` infrastructure (older) + built-in `Quot` (since 8.17). Coq's
  quotient is a `Prop`-erased construction; the lifting rule uses `match`-style
  elimination.
- Agda's `Quotient` postulate (older) or built-in `Quot` with `--cubical`-free
  semantics (newer). The non-cubical `Quot` matches what Doxa needs.
- Lean 3 soundness bug (2017-2019): `Quot` + unrestricted `Prop`-elimination
  into `Type` produced an inconsistency. The fix: singleton-elimination restriction.
  Doxa already enforces this (Phase 12) — the guard rail exists.

All three systems converge on the same kernel shapes: a formation rule, an
introduction rule (`mk`), and an elimination rule (`lift` with a compatibility
proof obligation).

### Step 0 — Design note (before code)

- Read Lean 4's `kernel/quot.cpp` and `Init/Prelude.lean` (the `Quot` section).
- Read Coq 8.17+ `kernel/quotient.ml`.
- Deliverable: confirm Doxa's singleton-elim check (Phase 12 Step 0) covers `Quot`
  without modification. If the check needs extending, document the extension here.
- Confirm the chosen surface syntax: `Quot(A, R)`, `mk a`, `lift f proof` (or
  equivalent — match existing Doxa syntax conventions from SYNTAX.md).

### Step 1 — Kernel term forms (`term.dart`, `value.dart`)

- `TQuot(A: Term, R: Term)` — quotient type formation. `A` is the carrier type,
  `R` is the equivalence relation, type `A → A → Prop`.
- `TQuotMk(a: Term)` — inject an element into the quotient. `a` has type `A`.
- `TQuotLift(quot: Term, f: Term, proof: Term)` — eliminate from a quotient. `f`
  is the function being lifted (type `A → B`), `proof` is evidence that `f`
  respects the equivalence `R` (type `(x y: A) → R x y → Eq B (f x) (f y)`).
- Corresponding `Value` forms: `VQuot(A, R)`, `VQuotMk(a)`, `VQuotLift(quot, f, proof)`.
- `openTerm` / `closeTerm` handlers for the three new forms.
- Add to the `Term` / `Value` sealed hierarchies.

### Step 2 — Evaluation and conversion (`eval.dart`, `conv.dart`)

- `eval(TQuot(A, R), env)` → `VQuot(eval(A, env), eval(R, env))`.
- `eval(TQuotMk(a), env)` → `VQuotMk(eval(a, env))`.
- `eval(TQuotLift(q, f, p), env)` → apply the lift by evaluating `q`, `f`, `p`
  in `env`, then dispatching on the `q` value.
- `apply(VQuotLift(quot, f, proof), arg)` — quotients are types, not functions.
  This is a type error; unreachable post-checking.
- **The key β-like reduction:** `apply(VQuotLift(VQuotMk(a), f, proof))` where
  the lift is applied (not just a value sitting there). Actually, `Quot.lift`
  takes no argument — the elimination is `lift(quot, f, proof)` producing a `B`.
  The reduction rule is: when `quot` evaluates to `VQuotMk(a)`, `Quot.lift`
  reduces to `f(a)`. In the defunctionalized driver, this goes in `apply` or
  the `_Eval` step.

  Concretely in `eval.dart`'s apply path: when the head is `VQuotLift(VQuotMk(a), f, proof)`
  and there are zero remaining arguments to apply, reduce to `apply(VLam(..., f), a)`.
  If there are remaining arguments (unusual — quotients aren't functions), the
  lift reduces first, then the arguments apply to the result.

  This can be implemented as a new `_SubstLift` frame: push onto the stack the
  instruction "apply `f` to `a`", mirroring the existing `_Apply(VLam)` path.

- `quote(VQuot(...))` — reconstructs a `TQuot(...)` at the given level.
- `quote(VQuotMk(a))` — reconstructs `TQuotMk(quote(a))`.
- `quote(VQuotLift(q, f, proof))` — reconstructs `TQuotLift(...)`.
- `conv(VQuot(A1,R1), VQuot(A2,R2))` — compare carriers and relations pointwise.
- `conv(VQuotMk(a1), VQuotMk(a2))` — `VQuotMk` does NOT directly conv. Two
  `mk` terms with different `a` values are in different equivalence classes —
  don't compare equality pointwise. Let `conv` be strict: only `mk(a) ≡ mk(a)`
  by identity (same term pointer), otherwise fall through to mismatch. The
  `VQuotLift` reduction is what makes quotient reasoning work, not the mk
  comparison.

### Step 3 — Type inference and checking (`eval.dart` infer/check paths)

- `infer(TQuot(A, R))` → check `A : Type n`, check `R : A → A → Prop`. Result
  sort is `max(n, 0)` (conservative: quotients over any carrier type land in
  the carrier's universe).
- `infer(TQuotMk(a))` → infer `a`, resolve the quotient type `Quot(A,R)` from
  context (this constructor is never inferred alone — always in a checking
  context that provides the expected `Quot` type). If the expected type is not
  a `VQuot`, error: `NotAQuotient`.
- `infer(TQuotLift(q, f, proof))` → infer `q` to get `Quot(A,R)`. Check `f`
  has type `A → B` for some `B`. Check `proof` has type
  `(x:A)(y:A) → R x y → Eq B (f x) (f y)`. Result type is `B`.
  **Soundness-critical:** the proof obligation ensures `f` respects the
  equivalence. This must be checked — a user can't claim `lift` without
  providing the proof.

### Step 4 — Elaboration (`elab.dart`)

- Surface syntax: `Quot(A, R)`, `mk a`, `lift f proof` (or tokens that match
  the existing style — the elaborator desugars to kernel terms).
- The elaborator synthesizes the compatibility proof through the existing
  `_elabExpr` pipeline. The user writes the proof like any other proof;
  the elaborator doesn't auto-generate it.
- `parse.dart` grammar additions for the new surface tokens.

### Step 5 — Tests

- **Positive:** construct a quotient `Nat/≡2` (equivalence mod 2). Prove that
  `mk 0` and `mk 2` represent the same equivalence class (via `Quot.lift` with
  a compatibility proof). Prove basic quotient algebraic properties.
- **Negative:** `Quot` elimination into Type without singleton-elim guard
  (should be rejected — confirm existing Phase 12 guard catches this).
- **Negative:** Quotient where the carrier is `Prop` — ensure the sort
  computation is correct (Prop-sorted quotients exist, Type-sorted quotients
  exist, no cross-sort confusion).
- **Negative:** Regression test for the Lean 3 `Quot` inconsistency (even if
  Doxa's singleton-elim guard already prevents it — capture as a regression pin).
- **Stress:** `Quot` inside other quotient constructions (nested equivalence
  classes). `Quot` inside `match` patterns. `Quot` applied to an indexed
  inductive family. Each exercises a different kernel path.

### Step 6 — Exit

- `val mod2 : Type = Quot(Nat, (a b: Nat) => ...)` typechecks.
- A proof that `mk 0 = mk 2` under mod-2 equivalence typechecks.
- All existing tests (766) pass.
- The Lean 3 soundness regression pin passes.
- `dart analyze` 0 issues, `dart format` clean.

**Risk assessment.** The Lean 3 inconsistency is the main soundness risk.
Mitigation: Doxa's singleton-elim check already prevents it, and the negative
regression test confirms. The second risk is interaction with `VRec` ι-reduction:
if a recursor's motive involves a quotient, the ι-reduction must not incorrectly
apply quotient-lift reduction before the recursor fires. Test with `VRec` over
`VQuotMk` scrutinees. Risk: Medium. Mitigation: dedicated test cases in Step 5.

---

## Phase 14.6 — Definitional Constructor Injectivity

**Goal.** `VConstr(c, args1) ≡ VConstr(c, args2)` → `args1[i] ≡ args2[i]` for all `i`.
Constructor injectivity becomes definitional — the conversion check handles it
directly rather than requiring `Eq.rec` chains in the elaborator.

**Why this phase exists.** Constructor injectivity is a conservative extension of
CIC that every major system (Lean 4, Coq, Agda) has at the kernel level. It is
~30 lines of code. Without it, indexed-family reasoning generates large `Eq.rec`
proof terms that could be avoided. With it, conversion handles index refinement
directly — smaller proof terms, faster checking.

**Prior work.** Lean 4's `kernel/inductive.cpp` injectivity check. Coq's
`kernel/inductive.ml` `check_constructor_injectivity`. Agda's built-in
`noConfusion` principle. The conversion rule is the same in all three: same
constructor → compare arguments pointwise.

### Step 0 — Kernel (`conv.dart`)

- One new dispatch arm in the `_Conv` step of the defunctionalized driver:
  when both sides are `VConstr` with the same `dataName` and `ctorName`,
  push frames to compare each pair of arguments pointwise (left-to-right).
  If any pair fails to conv, return mismatch. If all pairs conv, return Ok.
- No new term forms, value forms, or surface syntax. Pure kernel change.
- `conv` for `VConstr` with *different* constructor names continues to
  return mismatch (no injectivity across constructors — that would be
  a soundness violation for disjoint unions like `Nat.zero ≠ Nat.succ`).

### Step 1 — Tests

- **Positive:** `conv` of `VConstr("Nat", "succ", [VNeutral(NVar(0))])`
  on both sides should succeed (same stuck neutral argument).
- **Negative:** `conv` of `VConstr("Nat", "zero", [])` with
  `VConstr("Nat", "succ", [])` must fail (different constructors).
- **Negative:** `conv` of `VConstr("Nat", "succ", [a])` with
  `VConstr("Nat", "succ", [b])` where `conv(a, b)` fails → mismatch.
- **Regression:** existing indexed-family proofs (`vlength_index`,
  `vec_head_unreachable`) still type-check (should be smaller/faster
  but semantically identical).
- **Regression:** `succ_ne_zero` (Phase 12 negative) still rejects —
  constructor injectivity does NOT make distinct constructors equal.
- **Regression:** `succ_injective` proof via `Nat.rec` still works
  (it's now both *provable* and *definitional* for same-constructor cases).

### Step 2 — Exit

- All 766 existing tests pass.
- New injectivity tests pass.
- No performance regression on the stdlib benchmark.
- `dart analyze` 0 issues.

**Risk assessment.** The only risk is accidentally making *different* constructors
equal. The guard is the `dataName` + `ctorName` equality check before comparing
arguments. Different constructors always mismatch. Risk: Very Low.

---

## Phase 14.7 — Reducibility Hints

**Goal.** A per-definition flag controlling whether a definition unfolds during
conversion: `transparent` (default, unfolds) or `opaque` (never unfolds). Surface
syntax: `opaque val name` or similar.

**Why this phase exists.** Three things: (1) the `plus_zero` normalization bug
(Phase 19 carry-forward) may be fixable by marking a recursive function opaque
during its own body's check; (2) postulated axioms should never unfold during
conversion; (3) large derived definitions can be hidden from the type-checker
to speed up conversion. `VFun` (guarded delta-reduction, Phase 13 Part F-II)
already implements a specialized form — 14.7 generalizes it to all definitions.

**Prior work.** Lean 4's `opaque` / `irreducible` attributes. Coq's `Qed` (opaque)
vs `Defined` (transparent). The mechanism is a boolean flag on the definition's
kernel entry.

### Step 0 — Kernel (`env.dart`, `conv.dart`, `eval.dart`)

- Add `bool isOpaque` field to `TopBindingEntry` (default `false`).
- In `conv.dart`'s `_Conv(TTop)` path: before unfolding a `TTop(name)` reference,
  check if the resolved `TopBindingEntry.isOpaque` is `true`. If so, treat the
  reference as stuck (compare identity only, don't unfold). If `false`, unfold
  as currently (evaluate the binding's body and conv the result).
- In `eval.dart`: opaque bindings still evaluate normally (for `nf`, `quote`,
  and `infer` purposes) — the restriction is ONLY in `conv`. Reasoning:
  normal forms should show the actual values; conversion is where "pretend
  this doesn't unfold" matters.
- `VFun` (guarded delta-reduction) is a separate code path — it remains
  unchanged. `VFun` controls WHEN a recursive function unfolds (on canonical
  constructors). `isOpaque` controls WHETHER any definition unfolds at all.
  An opaque recursive function that is also a `VFun` would be guarded on
  `VFun` semantics AND never unfold in `conv` — both restrictions apply.
  In practice, marking a recursive `fun` as opaque would prevent its
  unfolding entirely, which is probably what you want for a postulated
  recursive axiom.

### Step 1 — Surface syntax + elaboration (`elab.dart`, `surface.dart`)

- `SValKind` / `SFunKind` gain an optional `isOpaque` flag.
- `parse.dart`: `opaque val name : T = body` and `opaque fun name(...): ...`
  tokens.
- `_elabVal` / `_elabFun` propagate the flag to `TopBinding`.
- `checkDeclResult` installs it into `TopBindingEntry`.

### Step 2 — Tests

- **Positive:** an `opaque val x : Nat = zero` where `x` is used in a type
  annotation that expects `Nat`. Without opacity, `x` unfolds to `zero` and
  `Nat` convs with `Nat`. With opacity, `x` stays as `x` and `Nat` convs
  with `Nat` (identity on `TTop` names). Both should work.
- **Negative:** an `opaque val x : Nat = zero` used where `zero` is expected
  — the type should still check because the *types* match, not the values.
  The opacity only prevents unfolding of the *value*, not the *type*.
- **Negative:** an `opaque axiom LEM : (A: Prop) -> ... (a user-postulated
  classical axiom). Attempting to unfold LEM during conversion should fail
  (treated as stuck / identity only).
- **Regression:** existing non-opaque proofs work identically (all 766 tests
  pass).
- **`plus_zero` bug:** verify the infinite-normalization bug from
  Phase 19 carry-forward is resolved by marking the offending function opaque
  during its own check. (May require additional refinement — flag this as
  "verify, don't claim fixed." The opacity mechanism provides the tool;
  whether the bug's root cause is unfolding-at-wrong-time is TBD.)

### Step 3 — Exit

- All 766 existing tests pass.
- `opaque val` parses, elaborates, and prevents unfolding during conv.
- `dart analyze` 0 issues.
- `plus_zero` bug status documented (fixed or confirmed as separate issue).

**Risk assessment.** The main risk is accidentally making existing proofs fail
because a definition they relied on being transparent becomes opaque. Mitigation:
the default is `transparent` (isOpaque = false), so existing code behavior is
unchanged. Only explicit `opaque` annotations change behavior. Risk: Very Low.

---

## Phase 14.8 — Re-benchmark

After all three kernel-hardening phases land, re-run the benchmarking suite
(see `docs/CONSOLIDATED_PLAN.md` Phase "Benchmarking Interlude") to measure
the impact of the new conversion rules and term forms. Update `docs/BENCHMARKS.md`
with a post-14.7 column. If any phase introduced a measurable regression,
investigate before proceeding to Phase 15.

**Goal:** Lift Doxa's sort hierarchy from the sort-monomorphic v1/v2 shape to full universe polymorphism. Library code (`cong`, `subst`, and every stdlib lemma) is written once over any universe level instead of re-specialized per sort.

**Prior work.** Coq's `kernel/univ.ml` + `kernel/univsubst.ml` are the canonical reference for first-class universe terms, constraint solving over `≤`/`<`, and universe unification. Lean 4's `library/level.h` + `Meta/UnivInference.lean` show the per-declaration level-variable approach (simpler than Coq's algebraic universes, sufficient for stdlib purposes). Read both before writing the design note — decide explicitly which model we follow.

### Step -1 — Prior-work study

Before any code:
- Coq `kernel/univ.ml` — the algebraic-universe / constraint-graph design.
- Lean 4 `library/level.{h,cpp}` + `Init/Prelude.lean` universe annotations — the simpler per-declaration model.
- Sozeau & Tabareau 2014, "Universe Polymorphism in Coq" — the reference paper.
- Deliverable: a design note in this section citing chosen model + why, and demonstrating compatibility with Phase 13's meta-context (universe levels must fit alongside term metas without forcing a context reshape).

### Step 0 — Kernel representation

- `Level` datatype: either a nullable integer (Lean-style per-decl variables) or an algebraic expression (Coq-style). Pick one based on Step -1.
- `VType(Level)` replaces `VType(int)`. `TType(Level)` replaces `TType(int)` at the term level.
- Level substitution, level-variable unification, constraint graph (if algebraic).

### Step 1 — Elaboration

- Declarations gain an implicit universe-variable binding. `def id.{u} : (A: Type u) -> A -> A` or the inferred equivalent.
- Sort comparison in `conv`/`subtype` handles level variables + constraints.
- The Phase 12 multi-recursor bridge retires: `_makeRecBindings` emits a single sort-polymorphic `T.rec` instead of `T.rec` + `T.ind` + `T.rect`.

### Step 2 — Consequences

- `Eq` takes a sort-polymorphic argument. `Eq[SomeProp] p q` becomes typeable. UIP becomes STATABLE (still not derivable — the motive-restriction takes over as the K-free mechanism, matching Lean/Agda).
- Stdlib lemmas (from Phase 14) rewrite to universe-polymorphic style. The old Type-only specialisations retire.
- Step 4 in Phase 13 (solved-in-phase-11 cases flip) gets a second pass — motive inference under universe variables.

### Step 3 — Audit

- Every phase's completion notes citing "v3 universe polymorphism" get revisited. Confirm each resolution is genuine.
- UIP-not-derivable pin moves from "not statable" to "stated but not derivable" shape.

**Exit:** Sort-polymorphic `Eq.rec` exists; `Eq[Prop_val] p q` typechecks; the multi-recursor bridge is gone; stdlib compiles with universe-polymorphic lemmas.

---

## Phase 16 — SProp + strict proof irrelevance

**Goal:** Add a second propositional sort `SProp` with strict (definitional) proof irrelevance where the user wants forced computation — matching Lean 4's SProp and the Gilbert et al. 2019 design.

**Prior work.**
- Gilbert, Cockx, Sozeau & Tabareau, "Definitional Proof-Irrelevance without K" (POPL 2019) — the canonical design.
- Lean 4's SProp handling in `src/Init/Prelude.lean` and kernel conv.

### Step -1 — Prior-work study

Read the POPL 2019 paper end-to-end. Deliverable: a design note verifying that Phase 12 Step 0's Prop-irrelevance implementation generalises to SProp (one additional sort to classify, same conv short-circuit), OR documenting the reshape needed.

### Step 0 — Kernel extension

- `SProp` as a sort alongside `Prop`, `Type n`.
- Conv extends `_isPropSorted` to also admit SProp.
- Prop vs SProp singleton-elim rules: SProp is strict — any inductive in SProp has all canonical forms propositionally equal by definition.
- PTS rules extend to cover the SProp/Prop/Type combinations.

### Step 1 — Elaboration + stdlib

- Surface syntax: `SProp` keyword (following `Prop`/`Type`).
- Stdlib gains a handful of SProp inductives (e.g. `SFalse`, `SAnd`) where strict irrelevance changes behaviour meaningfully.

**Exit:** SProp inductives exist, strict irrelevance fires, Prop-irrelevance from Phase 12 is unchanged.

---

## Phase 17 — Records with definitional η

**Goal:** Records as kernel primitives with definitional η: `{ x := r.x, y := r.y } ≡ r`. Every serious proof assistant has them; the stdlib becomes substantially more ergonomic.

**Prior work.**
- Lean 4's `structure` keyword + η-expansion in conv.
- Coq's `Record` definition + primitive projections (option `-set-primitive-projections`).

### Step -1 — Prior-work study

Read Lean 4's structure elaboration and primitive-projection η handling. Deliverable: pick kernel-primitive vs. sugar-over-single-ctor-inductive. Probably kernel-primitive for η's sake.

### Step 0 — Kernel

- `TRecord(fields)`, `VRecord(field-values)`, `TProj(record, fieldName)`, `VProj(record-value, fieldName)`.
- Conv case for η: two records (or one record + one neutral projection-head) compare by projecting each field and recursing.

### Step 1 — Surface

- `struct` declaration syntax (or whatever SYNTAX.md lands on).
- Field access: `r.x` parses as projection.
- Anonymous record construction: `{ x = ..., y = ... }`.

### Step 2 — Stdlib migration

- Pairs (`Pair[A, B]`), sigma types, dependent pairs — migrate from single-ctor inductives to records where η matters.

**Exit:** Records with η work, stdlib uses them where appropriate, existing inductive-based pairs still work as before.

---

## Phase 18 — Modules + imports

**Goal:** Multi-file programs with qualified names and imports. The stdlib (currently monolithic) reorganises into per-module files.

**Prior work.**
- Coq's `Module` / `Require Import` design — rich but historically complex.
- Lean 4's `import` model — simpler, matches our needs.
- Agda's `module` declaration with explicit exports.

### Step -1 — Prior-work study

Read Lean 4's import resolution + module ordering. Deliverable: design note covering (a) qualified-name resolution in the elaborator's TTop path, (b) cyclic-import detection, (c) stdlib reorganisation plan.

### Step 0 — Elaborator

- Qualified names: `Nat.plus` resolves as `plus` defined in module `Nat`, not a dot-notation-on-`Nat`.
- `import` declaration parses and loads the referenced module.
- TTop names become potentially qualified; conflict detection across modules.

### Step 1 — File layout

- `lib/stdlib/nat.doxa`, `list.doxa`, etc. as separate modules.
- Prelude becomes a module auto-imported by the CLI.

**Exit:** Multi-file stdlib with imports; existing single-file programs still work.

---

## Phase 19 — Ergonomic edges

**Goal:** Close the Phase 11 / Phase 12 carry-forward ergonomic gaps that aren't critical path but accumulate as user friction.

### Items

- **Local `let rec`** inside expressions (v2 has top-level mutual `fun` blocks only). Reuses the Phase 11 structural-recursion check.
- **Per-member `{struct <name>}` annotation** for non-first decreasing arguments in mutual blocks (Coq's `Fixpoint {struct}` shape). v2 assumes the first explicit value arg is the decreasing one; lex-order or non-first-arg decreasing requires annotation.
- **`plus_zero` match normalization bug** (logged from Phase 12 interlude). Match-based recursive `fun` where the return type depends on the scrutinee currently enters infinite normalization. Requires either lazy TTop resolution or a reduction-strategy change. Needs investigation; distinct from stack safety.
- Other elaborator polish surfaced during Phase 13–18 that doesn't fit a single phase.

**Exit:** Phase 11/12 carry-forwards closed.

---

## Phase 20 — Tactics

**Goal:** A minimal tactic engine and library. Writes proof terms the user would otherwise write by hand.

**Prior work.**
- Lean 4's tactic framework (`Lean/Elab/Tactic/*`). The meta-context is the observable state; tactics manipulate it.
- Coq's LTac (the richer version we don't ship) and the underlying `Proofview` monad (the abstraction we transcribe).

### Step -1 — Prior-work study

Read Lean 4's `Tactic.lean` and `Proofview`-style documentation. Deliverable: a design note covering (a) the meta-context as observable protocol, (b) snapshot/restore semantics for tactic backtracking, (c) the scope of tactics shipped in Doxa vs. left for future Fungal-hosted engines.

### Step 0 — Protocol

- Meta-context gains explicit snapshot/restore operations.
- A tactic is a function from `MetaState → MetaState + term`.
- The elaborator exposes a hook that runs tactics against unsolved metas.

### Step 1 — Minimal library

- `intro` — introduces a Pi binder.
- `exact term` — provides an explicit proof.
- `apply f` — applies a lemma, producing subgoals for its arguments.
- `refl` — closes `Eq A x x` by auto-refl.
- `rewrite p` — rewrites with an equation.
- `induction x` — produces subgoals per ctor of `x`'s type.
- `trivial` — tries `refl` + trivially-true lookups.

### Step 2 — Surface

- `theorem name : T := by ...` syntax for tactic proofs.
- Tactics compose via `;` (sequence) and `<|>` (alternative).

**Exit:** User can write `plus_comm` by `induction m; refl; rewrite ih` and have it produce a valid proof term.

---

## Phase 21 — Typeclasses + instance search

**Goal:** Typeclass-style polymorphism with instance search, built on Phase 13's unifier.

**Prior work.**
- Lean 4's typeclass resolution (`Lean/Elab/Term/TypeClass.lean`).
- Agda's instance arguments (`{{...}}` syntax).

### Step -1 — Prior-work study

Read Lean 4's instance-search implementation. Deliverable: design note covering (a) instance resolution as pattern-unification with a candidate list, (b) diamond-problem handling, (c) coherence constraints (how strict?).

### Step 0 — Kernel / elaborator

- Instance arguments: `{{C: Class A}}` in signatures.
- Instance resolution at call sites: consults a per-class instance table, runs pattern unification to pick a candidate.

### Step 1 — Stdlib uses

- Derive `Eq`-decidability instances.
- `Functor`, `Monad`, `Monoid` type classes where useful.

**Exit:** Polymorphic lemmas/functions with class constraints work; stdlib uses instances where it helps.

---

## Phase 22 — Final polish + release

**Goal:** Ship Doxa. Everything that's been deferred "until the feature set is stable" happens here, in order: audit, then docs, then demo, then release.

### Step 1 — SPEC-wide correctness-coverage audit

Same discipline as Phase 10 step 7's audit, but extended to the whole specification. Walk every SPEC clause (§3, §4, §5, §8, §6) and verify each rule maps to at least one test. Gaps get closed as new tests. This is the right moment because the surface is finally stable — earlier audits would have had to be redone as features landed.

### Step 2 — Diagnostic polish

- Every error kind in SPEC §8.11 has a golden test with verbatim output matching.
- Every error message includes the three required pieces: span, expected-vs-actual (where applicable), first-difference location (where applicable).
- Manual walkthrough of the diagnostics from each `test/programs/negative/*.doxa` to check they read as helpful, not merely correct.
- **Tier-2 binder-name propagation (carried forward from Phase 11).** `TypeMismatch` now carries the Ctx level (tier 1, done during Phase 11 step 5 prelude — commit renders placeholders `?a`, `?b` instead of `?-N` lies). Tier 2 is the SPEC §6.2 promise that user-written binder names (e.g. `A` from `fun id[A: Type]...`) render in error messages rather than placeholders. That requires Ctx to carry binder-name hints alongside types + values, which in turn interacts with Phase 13's Ctx work for metavariable scoping. Reason for deferral: doing tier 2 before Phase 13's Ctx shape stabilises would mean reworking it once metavars land. Pinned by `test/report_test.dart` group "SPEC §6.2 tier 1: no ?-N lies".
- Performance audit against `tool/stack_stress.dart` — every workload lands in its expected time band; investigate any regressions.

### Step 3 — Tutorial

- `docs/tutorial.md` — ML-family-programmer-aimed, ~2500–4000 words (longer than the original estimate because it now covers tactics).
- Structure: declarations → inductive types → `match` → `Eq` → proving `plus_comm` (by-hand) → tactics → a real proof using induction + rewrite → pointer to stdlib.
- Every code block in the tutorial is a runnable `.doxa` file under `docs/tutorial_examples/`; `test/tutorial_test.dart` asserts they all type-check.

### Step 4 — Browser demo

- `dart compile wasm` of `bin/doxa.dart`.
- HTML shell with a pastable source box and a "check" button. Renders diagnostics with spans highlighted.
- Share-link support via URL fragment (base64 source in the fragment).
- Stdlib ships as a pre-loaded dropdown of examples.
- Verify WasmGC performance vs. the AOT baseline on the stdlib test suite.

### Step 5 — Release

- Release notes covering Doxa's contributions (SPEC §1.2): ML-family syntax, WasmGC platform, linear-time invariant, Rumil parser — plus the full feature list.
- Tag `v1.0.0` on the repo.
- Update memory with release state.

**Exit:** A reader can clone the repo, read the tutorial, write a real proof using tactics, get a helpful diagnostic when they make a mistake, and share a browser link that type-checks their work.

---

## Dependency graph

```
0 → 1 → 2 → 3 → 4 → 5 → 6 → 7
                                \
                                 → 9 (CoC+Prop+cumulativity+mutual)
                                   → 10 (inductives + recursor)
                                     → 11 (match + structural rec)
                                       → 12 (Eq) + interlude (stack-safety audit)
                                         → 13 (metas + implicits + pattern unif)
                                           → 14 (stdlib)
                                             ├─ 14.5 (quotients) ──┐
                                             ├─ 14.6 (injectivity)─┤  in parallel
                                             └─ 14.7 (reducibility)┘
                                                   │
                                                   ├─ 14.8 (re-benchmark)
                                                   │
                                                   └─ 15 (universe polymorphism)
                                                      → 16 (SProp)
                                                        → 17 (records + η)
                                                          → 18 (modules + imports)
                                                            → 19 (ergonomic edges)
                                                              → 20 (tactics)
                                                                → 21 (typeclasses)
                                                                  → 22 (audit + polish + release)
```

Phases 0-14 are linear (original plan). Phases 14.5-14.7 are independent
of each other — they can be built in parallel or any order. Phase 14.8
(re-benchmark) runs after 14.5-14.7 and before 15. Phases 15-22 remain
strictly linear.

---

## Permanent non-goals

Items excluded by design, not by sequencing (SPEC §1.3 canonical):

- **Mutable state, effects, IO** in the object language. Doxa is total and pure.
- **Homotopy Type Theory, Cubical Type Theory, univalence.** Different kernel, different project.
- **Full higher-order unification.** Pattern fragment only, matching every production PA.
- **Classical axioms in the kernel** (LEM, choice, extensionality). Users may postulate; the kernel stays axiom-free.
- **Extraction to other languages.** If extraction is ever wanted, it lives in a separate project.
- **Intermediate public releases.** Doxa ships once, feature-complete (SPEC §1). Development phases are internal sequencing markers.

---

## Risks and where I'd expect to get stuck

### Early phases (retained for reference)

- **Phase 2, quote's level accounting.** The off-by-one between environment length, de Bruijn index, and de Bruijn level is the classic NbE bug. Testing Phase 2 heavily with Church-Nat reductions, *before* moving to the checker, is the mitigation.
- **Phase 3, η under neutrals.** `(λx. f(x)) ≡ f` when `f` is an opaque neutral. Getting this right while not over-reducing takes care. Worth a dedicated test family.
- **Phase 5, elaboration's `close` placement.** Getting `close` calls wrong at binders produces kernel terms with broken indices that *silently* normalize to wrong values. The round-trip test against Phase 4's hand-built kernel terms is the safety net.
- **Phase 6, span propagation.** If spans are only on surface AST and the elaborator discards them, errors at check-time won't know where they are. Decide the propagation strategy at the start of Phase 5, not mid-Phase 6.

### CIC-feature phases

- **Phase 9, Prop's PTS rule.** Getting the Pi-sort computation right for the Prop/Type matrix is subtle. Test with the standard CIC rule table (see Coquand & Paulin 1990).
- **Phase 10, positivity under parameters and indices.** The positivity check must account for the data type's own parameters differently from recursive occurrences. Reference: Paulin-Mohring 1993. Easy to write a version that over-rejects or under-rejects. *(Nested positivity via per-parameter covariance shipped in commit 3657142; see Phase 10 step 8 follow-ups.)*
- **Phase 11, step-5 boundary creep.** Dependent motive inference without full unification has a narrow honest line. Temptation to sneak in more solver logic grows every time a program "almost works." Mitigation: write the `MotiveInferenceRequiresUnification` rejection test first, before the acceptance logic. If that test starts failing because the motive was inferred after all, audit whether it was inferred by the bounded form or by accidentally-reinvented unification.
- **Phase 11, dependent coverage with index refinement.** When matching `vnil`, the case body knows `n = zero`. This "forced equation" system is where implementations most often have subtle bugs. Reference: Cockx & Abel 2018 on pattern matching without K.
- **Phase 11, guardedness with mutual recursion.** The "size" relation across mutually recursive functions is not a simple structural sub-term check anymore. Keep the relation syntactic (pattern-bound-var-of-designated-arg), not semantic. Reference: Coq's `guard_condition`, Agda's termination checker.
- **Phase 12, Eq's K-freeness.** Doxa does not assume UIP. Currently holds via the "UIP not statable" coarser mechanism; Phase 15 universe polymorphism shifts to the standard motive-restriction approach. Pin a negative test through both phases.
- **Phase 13, pattern unification.** The decidable fragment has well-known edge cases (flex-flex pairs, eta-expansion in meta-solutions, pruning on meta scopes). Reference: Miller 1991; Abel & Pientka 2011; Kovács's elaboration-zoo. Budget extra time; this is one of the largest risks in the whole plan.
- **Phase 13, meta-variables through the unified driver.** Our early-phase driver dispatches over a fixed Step/Frame ADT. Meta-variables add a cross-cutting concern — any `TMeta` can appear anywhere a term can. The Step -1 / Step 0 preambles are not optional: the design has to be on paper before code touches `eval.dart`.
- **Phase 15, universe representation choice.** Algebraic universes (Coq) vs. per-declaration variables (Lean 4) is the first architectural fork. Getting it wrong means a kernel rewrite. Step -1's prior-work review picks the model; every subsequent phase inherits that choice.
- **Phase 15, sort-polymorphism interaction with Phase 13's metas.** Metas that range over universe levels vs. metas that range over terms must share a context without a union dance. If Phase 13's Step 0 forward-compat check #1 was weak, Phase 15 pays.
- **Phase 16, SProp irrelevance interaction with Phase 12's Prop-irrelevance conv path.** The `_isPropSorted` short-circuit was written for a single irrelevant sort. SProp adds a second. Check that the classifier generalises cleanly instead of needing a reshape.
- **Phase 17, records vs. kernel-primitive-vs-sugar decision.** The η-for-records commitment is incompatible with naive single-ctor-inductive sugar; kernel primitive is probably the right call. Step -1 design note must argue explicitly.
- **Phase 20, tactic protocol discoverability.** Tactics are inherently user-facing; their error messages, progress display, and failure modes determine whether proofs are pleasant or miserable. Budget real time for iteration on UX beyond the initial "it produces proof terms" correctness bar.
- **Phase 21, typeclass coherence.** Overlapping instances + diamond imports create classic typeclass-resolution pathologies. Lean 4's rules are a starting point but require adaptation. Discipline: keep coherence STRICT and relax later if needed; the reverse is much harder.
- **Phase 22, tier-2 binder names.** The Ctx reshape to carry binder-name hints alongside types+values must be compatible with every prior phase's Ctx usage. Could surface unexpected rework across phases that touched `Ctx.extend`. Audit carefully.
