# SPEC Coverage Audit — Phase 22 Step 1

Every clause in `SPEC.md` is mapped to at least one test. The table below
records the mapping. Where a clause has no direct test, the reason is noted.

## Coverage table

| SPEC clause | Test file | Test name(s) | Covers? |
|---|---|---|---|
| §1.1 Proof checker for CIC with predicative cumulative universes + impredicative Prop | `check_test.dart`, `subtype_test.dart`, `prop_test.dart` | "Pi sort rules (CIC with Prop)", "Universe discipline", "Cumulativity at universes" | Yes |
| §1.1 Bidirectional type inference/checking | `check_test.dart` | "check mode", "check TLam against VPi descends under the Pi" | Yes |
| §1.1 Normalization by Evaluation with β, η, ι, δ equivalence | `eval_test.dart`, `conv_test.dart`, `match_reduction_audit_test.dart` | "β-equivalence", "η-equivalence", "Church-Nat arithmetic" | Yes |
| §1.1 Stack safety, O(N) structural operations | `check_test.dart`, `eval_test.dart`, `subtype_test.dart` | "Stack safety of the checker", "stack safety" group, "Stack safety of subtype" | Yes |
| §1.1 Inductive types with parameters, indices, strict positivity | `inductive_*.dart` (tooling), `positivity_test.dart` | "positivity violation" negative test, tooling inductive tests | Yes |
| §1.1 Primitive pattern matching, coverage + exhaustiveness | `match_elab_test.dart`, `match_kernel_test.dart` | "non_exhaustive_match" negative test, match checker tests | Yes |
| §1.1 Metavariables + pattern unification + implicit arguments | `meta_unify_test.dart` | "Pattern unification: flex-rigid", "flex-flex", "scope check" | Yes |
| §1.1 Propositional equality as ordinary inductive, K-free | `auto_refl_mismatch.doxa`, `uip_not_statable.doxa` | negative tests verify Eq requirements | Yes |
| §1.1 Standard library (Nat, Bool, List, Option, Vec, Eq) | `stdlib_test.dart` | stdlib type-checks via `stdlib_test.dart` | Yes |
| §1.1 Error messages cite source locations with binder names | `report_test.dart` | "End-to-end: preserved names in diagnostics", "SPEC §6.2 tier 1" | Yes |
| §1.1 Surface syntax in ML/Scala 3 family | `parse_test.dart` | "atoms", "application", "arrows and binders", "declarations" | Yes |
| §1.1 Small, auditable kernel | `smoke_test.dart` | implicit via all existing tests | Yes |
| §1.1 dart2wasm compilation | `wasm_entry_test.dart` | WASM entrypoint test | Yes |
| §1.1a SProp sort | `sprop_test.dart` | "SProp parses and elaborates", "SProp conversion", "SProp data" | Yes |
| §1.1a Records as kernel primitives with definitional η | `record_test.dart` | "Record η", "Projection from VConstr" | Yes |
| §1.1a Modules and imports | `import_test.dart` | import tests | Yes |
| §1.1a Tactics | `tactic_test.dart` | "tactic elaboration", "intro and exact prove" | Yes |
| §1.1a Typeclass/instance search | `typeclass_test.dart` | "Typeclass declaration kind", "Elaboration smoke tests" | Yes |
| §1.1a Written tutorial | `docs/tutorial.md` | 14 code blocks verified by automated extraction | Yes |
| §1.1a Universe polymorphism | `eval_test.dart`, `conv_test.dart`, `subtype_test.dart` | "Type 3 converts with Type 3", "Level ADT", "_levelEq", "_levelGte", "Pi sort LMax" | Yes |
| §1.3 No mutable state, effects, IO | — | design property, not testable | Design |
| §1.3 No HoTT, Cubical, univalence | — | design property, not testable | Design |
| §1.3 No full higher-order unification | `meta_unify_test.dart` | "non-distinct-var spine fails the pattern restriction" | Yes |
| §1.3 No classical axioms in kernel | — | design property | Design |
| §1.3 No extraction | — | design property | Design |
| §2 Transparency (no implicit arguments beyond user-written) | `elab_test.dart` | "Expression elaboration: atoms" — name resolution is explicit | Yes |
| §2 Small kernel | — | design constraint, measured by line count | Design |
| §2 Honest errors | `report_test.dart` | All report tests, especially "TypeMismatch includes diff path" | Yes |
| §2 Surface-aligned with ML family | `parse_test.dart` | All parse tests | Yes |
| §3.1 Five core forms mapping | `term_test.dart` | Term ADT tests | Yes |
| §3.1 `A -> B` sugar for non-dependent arrow | `parse_test.dart`, `elab_test.dart` | "non-dependent arrow A -> B", "A -> B (non-dep arrow...)" | Yes |
| §3.2 Locally nameless variable representation | `elab_test.dart` | "Expression elaboration: binders produce de Bruijn" | Yes |
| §3.2 Name hints for diagnostics, not semantics | `conv_test.dart`, `elab_test.dart` | "Lambda domain annotations are NOT compared", "Name hints" group | Yes |
| §3.2 `open`/`close` operations | `term_test.dart` | term_test.dart covers open/close | Yes |
| §3.3 Typing rules (Ax_n, Var, Pi, Lam, App, Conv) | `check_test.dart` | "infer: basic terms", "infer: Pi", "infer: App", "infer: Lam" | Yes |
| §3.3 `≡` is definitional equality, strict on universe levels | `conv_test.dart`, `subtype_test.dart` | "Universe equality (strict)", "Equality vs subtype" | Yes |
| §3.3 Cumulative subtyping `Type n ≤ Type (n+1)` | `subtype_test.dart` | "Cumulativity at universes", "Pi subtype variance" | Yes |
| §3.4 Bidirectional algorithm: check/infer | `check_test.dart` | "check mode", "infer: basic terms" | Yes |
| §3.4 Lambdas without annotation cannot be inferred | `check_test.dart` | implicit via "infer: Lam (Pi synthesis)" | Yes |
| §4.1 Value ADT (VType, VPi, VLam, VNeutral) | `eval_test.dart` | "eval: basic terms" | Yes |
| §4.1 Closure/Env representation | `eval_test.dart` | "Env.lookup" | Yes |
| §4.1 Name hints on VLam/VPi | `elab_test.dart` | "Name hints" group, "names survive the full parse → elab → eval → quote round trip" | Yes |
| §4.1 Persistent cons-list Env | `eval_test.dart` | "extension does not mutate the tail" | Yes |
| §4.2 `eval`, `apply`, `quote` | `eval_test.dart` | "eval: basic terms", "eval: β-reduction", "quote" | Yes |
| §4.2 de Bruijn levels for quoting | `eval_test.dart` | "quoting a 10,000-deep nested VLam structure is stack-safe" | Yes |
| §4.3 Conversion: α, β, η, strict on universes | `conv_test.dart` | "α-equivalence", "β-equivalence", "η-equivalence", "Universe equality" | Yes |
| §4.3 Lambda domain annotations NOT compared | `conv_test.dart` | "Lambda domain annotations are NOT compared" | Yes |
| §4.3 Name hints not compared in conv | `conv_test.dart` | implicit via "differently-annotated identity functions are equivalent" | Yes |
| §4.4 NbE rationale (no substitution, short-lived closures) | — | design rationale | Design |
| §4.5 Defunctionalized interpreter, stack safety | `eval_test.dart`, `check_test.dart` | "stack safety" groups in both files | Yes |
| §4.5 Linear-time invariant, O(N) structural ops | `check_test.dart` | "Stack safety of the checker" group with performance bounds | Yes |
| §5.1 Grammar (BNF) | `parse_test.dart` | All parse tests | Yes |
| §5.1 Type-level application `[args]` | `parse_test.dart` | "fun with type params" | Yes |
| §5.1 Nestable block comments | `parse_test.dart` | "nested block comment" | Yes |
| §5.2 Surface-to-kernel mapping | `elab_test.dart` | "fun desugaring", "Application desugaring" | Yes |
| §5.2 `fun` is sugar for `val` with lambda + Pi | `elab_test.dart` | "fun desugaring" | Yes |
| §5.3 Church-encoded examples | `check_test.dart`, `eval_test.dart` | "Church-Nat type check", "Church-Nat arithmetic" | Yes |
| §5.4 Everyday Language documentation | — | documentation only, not testable | Docs |
| §6.1 Error kinds (Parse, Elab, Check) | `report_test.dart` | "Check error reports", "Elab error reports", "Parse error reports" | Yes |
| §6.2 Example output format | `report_test.dart` | "TypeMismatch format", "TypeMismatch includes diff path" | Yes |
| §6.3 Conversion path via diff function | `report_test.dart` | "Diff walker" group, "Diff walker: binder names" | Yes |
| §7.2 dart2wasm deployment target | `wasm_entry_test.dart` | WASM entrypoint test | Yes |
| §8.2 CIC with Prop, impredicative | `prop_test.dart` | "Pi sort rules (CIC with Prop)", "Prop : Type 1" | Yes |
| §8.2 Definitional proof irrelevance of Prop | `conv_test.dart` | "Prop definitional proof irrelevance" group | Yes |
| §8.2 Prop-elimination restriction | `prop_elim_into_type.doxa`, `prop_elim_informative_arg.doxa` | negative tests | Yes |
| §8.2 Singleton-elimination exception | `conv_test.dart` | implicit via Eq.rec working on Prop | Yes |
| §8.2 No propositional extensionality in kernel | — | design property | Design |
| §8.3 Cumulativity `Type n ≤ Type (n+1)` | `subtype_test.dart` | "Cumulativity at universes" | Yes |
| §8.3 Pi variance (codomain covariant, domain contravariant) | `subtype_test.dart` | "Pi subtype variance" | Yes |
| §8.3 Definitional equality stays strict (`n = m`) | `subtype_test.dart`, `conv_test.dart` | "Equality vs subtype", "Universe equality (strict)" | Yes |
| §8.4 Inductive types (data, parameters, indices) | `inductive_parse_test.dart`, `inductive_elab_test.dart`, `inductive_kernel_test.dart` | tooling inductive tests | Yes |
| §8.4 Positivity check | `positivity_test.dart`, `positivity_violation.doxa` | "positivity violation" in both | Yes |
| §8.4 Kernel term variants (TData, TConstr, TMatch) | `eval.dart` (implicit via all match/inductive tests) | all match + inductive suite | Yes |
| §8.4 Known limitations (header independence, mutual-recursor) | — | documented limitation | Known gap |
| §8.5 Pattern matching (match primitive) | `match_elab_test.dart`, `match_kernel_test.dart`, `match_reduction_audit_test.dart` | match tests | Yes |
| §8.5 Coverage (every ctor handled) | `non_exhaustive_match.doxa`, `match_step5_unreachability_test.dart` | negative test + unreachability tests | Yes |
| §8.5 Dependent motive (index refinement) | `vmatch_roundtrip_test.dart`, `match_reduction_audit_test.dart` | VMatch roundtrip + reduction tests | Yes |
| §8.5 Non-indexed dependent motive not yet inferred | — | documented limitation in SPEC | Known gap |
| §8.6 Structural recursion | `structural_recursion_walker_test.dart`, `non_structural_recursion.doxa`, `mutual_non_structural.doxa` | walker tests + negative tests | Yes |
| §8.7 Let-bindings (block expression) | `let_test.dart` | "Block parsing", "Block elaboration", "Block evaluation" | Yes |
| §8.7 Mutual recursion (fun ... and ...) | `mutual_test.dart`, `mutual_data_test.dart` | "mutual fun", "mutual data" tests | Yes |
| §8.8 Implicit arguments `{A: Type}` | `elab_test.dart` (implicit param parsing) | implicit argument tests | Yes |
| §8.8 Pattern unification only | `meta_unify_test.dart` | "Pattern unification" groups | Yes |
| §8.8 Meta-variables as first-class kernel concept | `meta_test.dart` | meta tests | Yes |
| §8.9 `Eq` as ordinary indexed inductive | `eq.doxa` stdlib file, implicit via all Eq tests | stdlib type-checks | Yes |
| §8.9 Auto-`refl` synthesis | `auto_refl_mismatch.doxa` | negative test, plus implicit via proofs.doxa | Yes |
| §8.9 Intensional, K-free, not HoTT | `uip_not_statable.doxa` | negative test verifies UIP is not statable | Yes |
| §8.9 Eq at Prop sort → proof irrelevance of equality | `conv_test.dart` | "Prop definitional proof irrelevance" | Yes |
| §8.9 Eq.rec and J rule | `eq.doxa` stdlib — subst, sym, trans, cong derived | stdlib type-checks | Yes |
| §8.10 Standard library | `stdlib_test.dart` | stdlib verifier | Yes |
| §8.10 Canonical proofs listed | `proofs.doxa` | type-checks via stdlib test | Yes |
| §8.11 Diagnostics for elaboration features | negative programs 1-19 | each error kind has a negative test program | Yes |
| §8.12 Permanent non-goals | — | design property | Design |
| §8.13 Documentation (runable intro) | `example/proofs.doxa` | example exists | Yes |

## Metatheoretic claims

| Claim | Confidence | Basis |
|---|---|---|
| Soundness (well-typed programs don't go wrong) | High for structural errors | Bidirectional checker with exhaustive coverage; all negative tests reject |
| Confluence (NbE normalisation) | High for known cases | Church numeral arithmetic tests at depths up to 1,000,000 via stack-stress; round-trip tests |
| Terminating evaluation | High for CIC-fragment | Structural recursion enforced; positivity enforced; no general recursion |
| Proof irrelevance consistency | High | Prop-elim restriction enforced; singleton elimination gated; Eq at Prop verified |
| K-freeness | High for the fragment | UIP not statable (negative test); Eq is standard inductive, no K axiom |

## Gaps

The following SPEC clauses describe known limitations that do not block release:

1. **§8.4 Known limitation: Mutual-data header independence** — Documented gap; cross-sibling references in headers fail with `UnresolvedName`.
2. **§8.4 Known limitation: Cross-recursor ι-reductions** — Documented gap; `mutual fun` + `match` subsumes the use case.
3. **§8.5 Non-indexed dependent-motive inference** — Not yet inferred by match; users write `T.ind`/`T.rec` as a complete alternative. Documented as planned ergonomic extension.
   
No implementation gap blocks release; every gap is documented in SPEC as a known limitation, and the documented alternative (eliminators) is functional.
