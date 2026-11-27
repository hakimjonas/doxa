# SPEC coverage audit

Every testable clause in `SPEC.md` is mapped to at least one test. The table
below records the mapping by SPEC section. Where a clause has no direct test,
the reason is noted in the gaps section.

## Coverage table

| SPEC section | Clause | Test file | Test name(s) | Covers? |
|---|---|---|---|---|
| Pipeline | `doxa check` loads the prelude, resolves imports, parses, elaborates, and checks | `doxa_tooling/test/programs_test.dart` | "Positive programs (must type-check)", "Negative programs (must fail with matching diagnostic)" | Yes |
| Pipeline | The prelude declares `Eq` and `Acc` | `doxa_tooling/test/prelude_sync_test.dart` | "embedded prelude matches doxa_stdlib/lib/stdlib/prelude.doxa" | Yes |
| Pipeline | Relative, selective, and aliased imports | `doxa_tooling/test/import_test.dart` | "import \"stdlib/nat.doxa\" makes Nat, plus, etc. available", "import paths resolve relative to importing file", "transitive import works (list imports nat which imports bool)" | Yes |
| Pipeline | `package:` imports resolve through the nearest package configuration and never fall back | `doxa_tooling/test/package_import_test.dart` | "checkSource resolves the library through the configuration", "reports a missing configuration instead of falling back" | Yes |
| Pipeline | A missing, undeclared, or malformed package specifier is an error | `doxa_tooling/test/package_import_test.dart` | "names a package missing from the configuration", "reports a malformed package specifier" | Yes |
| Pipeline | Dotted names are accepted where a name is expected | `doxa/test/dotted_name_test.dart` | "Nat.rec parses as SDotKind", "Nat.rec elaborates to TTop referring to the Nat.rec binding" | Yes |
| Terms and sorts | One expression grammar; de Bruijn locals and named top-level references | `doxa/test/elab_test.dart` | "(x: Type) => x elaborates to TLam(Type 0, TBound(0))", "fun id[A: Type](x: A): A = x" | Yes |
| Terms and sorts | Inference and checking modes; an unannotated lambda needs an expected Pi type | `doxa/test/check_test.dart` | "check mode", "infer: Lam (Pi synthesis)" | Yes |
| Terms and sorts | Evaluation, quotation, and conversion; transparent definitions unfold | `doxa/test/eval_test.dart`, `doxa/test/conv_test.dart` | "eval: β-reduction", "β-equivalence", "η-equivalence" | Yes |
| Terms and sorts | An opaque declaration stays opaque to conversion | `doxa/test/opaque_test.dart` | "opaque x does NOT unfold when compared to its body", "opaque fun applied stays stuck as NApp(NTop(...), ...)" | Yes |
| Terms and sorts | Comments nest; identifiers and dotted names have the stated lexical form | `doxa/test/parse_test.dart` | "identifier", "nested block comment" | Yes |
| Terms and sorts | Application associates left; brackets are a postfix form | `doxa/test/parse_test.dart`, `doxa_tooling/test/inductive_parse_test.dart` | "f x y is left-associative: ((f x) y)", "Vec[A] n: bracket app then juxtaposed value arg" | Yes |
| Terms and sorts | Four infix operators expand to `multiply`, `plus`, `leq`, and `equals`; `*` binds tighter than `+`, both tighter than the comparisons, arithmetic associates left, comparisons do not associate, and the expansion is a single name resolved by the bare-name rule at the use site | `doxa/test/infix_test.dart`, `doxa_tooling/test/infix_test.dart`, `doxa_tooling/test/format_test.dart` | "a + b * c groups as a + (b * c)", "a + b + c groups as (a + b) + c", "a <= b <= c is rejected, naming <=", "a missing plus is reported at the operator, not the expression", "a CLI program using all four operators type-checks", "prefix plus formats to infix" | Yes |
| Terms and sorts | Lambda and Pi forms, implicit binders, right association | `doxa/test/parse_test.dart` | "non-dependent arrow A -> B", "right-associative: A -> B -> C", "dependent Pi (A: Type) -> A", "lambda (x: Type) => x", "unannotated lambda (x) => x" | Yes |
| Terms and sorts | `calc` chains: non-empty `;`-separated steps inside `calc(...)`, the first endpoint fixes the carrier, later endpoints are checked against it, each proof inhabits `Eq A lhs rhs`, a step meets the previous right endpoint, the carrier is a `Type`, and the chain elaborates to transitivity | `doxa/test/have_calc_test.dart`, `doxa_tooling/test/have_calc_test.dart` | "a two-step chain composes the two proofs", "a one-step chain is its proof", "a chain works inside exact", "a chain works as an application argument", "a chain over a Prop carrier is rejected as not a type", "steps that do not meet are rejected"; the CLI fixture `test/fixtures/have_calc_proofs.doxa` (three-step arithmetic chain) | Yes |
| Terms and sorts | `Type` accepts a level; `Prop` and `SProp` do not | `doxa/test/parse_test.dart`, `doxa/test/prop_test.dart`, `doxa/test/sprop_test.dart` | "Type 3", "Prop is reserved", "SProp is reserved" | Yes |
| Terms and sorts | `Prop` is impredicative | `doxa/test/prop_test.dart` | "(A: Prop) -> A  is in Prop (impredicative)" | Yes |
| Terms and sorts | Universes are cumulative and Pi types vary by position | `doxa/test/subtype_test.dart` | "Type 0 checks against Type 1 (upward)", "covariant codomain: lambda into Type 0 fits codomain Type 2", "contravariant domain: got accepts broader, expected narrower, OK" | Yes |
| Terms and sorts | Cumulativity does not cross sorts; conversion stays strict on levels | `doxa/test/subtype_test.dart`, `doxa/test/conv_test.dart` | "Prop does NOT check against Type 0", "Type 0 does NOT check against Prop", "Type 0 does NOT convert with Type 1" | Yes |
| Terms and sorts | SProp field restriction; Prop-elimination restriction | `doxa/test/sprop_test.dart`, `prop_elim_into_type.doxa`, `prop_elim_informative_arg.doxa` | "SProp data declarations", "SProp data field restrictions"; negative programs | Yes |
| Declarations | Top-level declaration kinds; the theorem marker may be `:=` or `=` | `doxa/test/parse_test.dart`, `doxa/test/tactic_test.dart` | "val x = y", "type alias", "theorem with = works (no :=)", "theorem with := works" | Yes |
| Declarations | `val`, `opaque val`, `type`, and `theorem` forms | `doxa/test/elab_test.dart`, `doxa/test/opaque_test.dart` | "val x: Type 1 = Type produces a TopBinding", "val without type annotation infers Type", "opaque x conv x is ConvOk (name identity)" | Yes |
| Declarations | The fourteen `by` steps | `doxa/test/tactic_test.dart`, `doxa/test/simp_test.dart`, `doxa/test/revert_test.dart`, `doxa/test/tactic_surface_test.dart`, `doxa/test/have_calc_test.dart` | "intro and exact prove (A: Type) -> A -> A", "closes a definitional equality by normalisation and refl", "id_revert round-trips through the tactic and checks", "walks both arms of Nat", "leaves one reachable goal per argument", "closes a goal from a hypothesis", "closes with plusZero in scope", "a fact without a proof is a subgoal closed first" | Yes |
| Declarations | Semicolons sequence steps; `|` separates alternatives | `doxa/test/tactic_test.dart` | "by { intro x; exact x } parses", "by { refl | trivial } parses (alternatives)" | Yes |
| Declarations | Explicit and implicit parameter groups; `&`-separated constraints | `doxa/test/parse_test.dart`, `doxa/test/typeclass_elab_test.dart` | "fun mixing explicit and implicit type params", "a constrained parameter resolves for Nat and Bool" | Yes |
| Declarations | `{struct name}` and `decreases` annotations | `doxa_tooling/test/structural_recursion_walker_test.dart`, `doxa_tooling/test/wf_recursion_test.dart` | "{struct} on a later param is accepted", "Ackermann checks and computes under a lexicographic measure" | Yes |
| Declarations | Mutual `fun` and mutual `data` blocks | `doxa_tooling/test/mutual_test.dart`, `doxa_tooling/test/mutual_data_test.dart` | "fun + and parses to SFunBlockKind", "two data decls chained with `and data` parse as SDataBlockKind", "Even/Odd: both DataDecls registered with cross-references" | Yes |
| Declarations — Structural recursion | The designated argument and the strict sub-term rule | `doxa_tooling/test/structural_recursion_walker_test.dart`, `non_structural_recursion.doxa`, `mutual_no_decrease.doxa` | "plus on Nat: recursion on designated first arg", "self-call with the designated arg itself fails" | Yes |
| Declarations — Structural recursion | Explicit type arguments offset the designated value position | `doxa_tooling/test/structural_recursion_walker_test.dart`, `doxa/test/elab_test.dart` | "the designated position is offset by the type argument", "lenExplicit A t is accepted, checked, and reduces", "implicit type parameters do not shift the value position" | Yes |
| Declarations — Structural recursion | An unapplied recursive reference is rejected | `doxa_tooling/test/structural_recursion_walker_test.dart` | "unapplied reference (passing function as value) rejected" | Yes |
| Inductive types and matching | `data` signatures give indices then the target sort; constructor separators | `doxa_tooling/test/inductive_parse_test.dart` | "data Nat with zero and succ", "trailing semicolon after last ctor is accepted", "data Vec[A: Type] : Nat -> Type" | Yes |
| Inductive types and matching | Constructor result shapes and positivity | `doxa_tooling/test/positivity_test.dart`, `positivity_violation.doxa` | "Nat", "Vec[A] : Nat -> Type", "the canonical Bad: (Bad -> Bad) -> Bad", negative program | Yes |
| Inductive types and matching | Product-form declarations desugar to one `mk` constructor; every field projects with dotted syntax | `doxa/test/record_surface_test.dart`, `doxa/test/record_test.dart` | "Point with two fields constructs and projects both", "a parameterised record projects both fields at Pair Nat", "a third field projects", "a dependent field type mentions the first projection", "a nested record projects through"; "TProj projects \"fst\" from VConstr(Pair, mk)" | Yes |
| Inductive types and matching | Match arms, constructor binders, wildcard, and `returning` | `doxa_tooling/test/match_parse_test.dart` | "two arms: no separator between them", "ctor with multiple binders", "explicit motive attaches" | Yes |
| Inductive types and matching | Duplicate arms and coverage | `non_exhaustive_match.doxa`, `doxa_tooling/test/match_step5_unreachability_test.dart` | "Vec[A] n: must cover both vnil and vcons", "duplicate_case.doxa" negative program | Yes |
| Inductive types and matching | Indexed-family motive and reachability checks | `doxa/test/indexed_induction_test.dart`, `doxa_tooling/test/vmatch_roundtrip_test.dart` | "a Vec induction uses the refined length index and the IH", "a wrong compound-index arm still fails" | Yes |
| Local bindings and quotients | Block bindings, `val rec`, optional local types, parenthesized argument position | `doxa/test/let_test.dart` | "block with one annotated binding parses to SLetKind", "elab infers an unannotated binding from the bound expr", "block checked against expected type (success)" | Yes |
| Local bindings and quotients | `Quot(A, R)` formation checks the relation against `(x: A) -> (y: A) -> Prop`; `mk`, `lift`, and `Quot.sound` are check-mode rules; the elimination computes by ι; the equality `Quot.sound` gives is propositional; the carrier and a lift result are `Type 0`; no `Quot.ind` | `doxa/test/quotient_test.dart`, `doxa_tooling/test/quotient_surface_test.dart` | "TQuotMk checks against a quotient type", "TQuotLift checks against a function from a quotient", "TQuotSound checks against an equality of injections", "lift applies to an injection by ι-reduction", "a lift function that does not respect the relation is rejected", "infer TQuot rejects a relation that is not a relation", "VQuotMk equal args compare structurally, not by identity", "the acceptance module checks through the CLI" | Yes |
| Typeclasses | A class elaborates to a dictionary and a projection | `doxa/test/typeclass_elab_test.dart` | "elaborates to a dictionary type and a projection" | Yes |
| Typeclasses | A class may declare more than one method | `doxa/test/typeclass_elab_test.dart` | "a two-method class elaborates both projections and reduces", "method types mention the class parameter" | Yes |
| Typeclasses | An `impl` registers a dictionary and a call reduces through it | `doxa/test/typeclass_elab_test.dart`, `doxa_tooling/test/typeclass_surface_test.dart` | "impl registers an instance and a call reduces through it", "impl declaration is accepted for a declared class" | Yes |
| Typeclasses | Constrained explicit parameters place the dictionary after value parameters | `doxa/test/typeclass_elab_test.dart` | "a constrained parameter resolves for Nat and Bool" | Yes |
| Typeclasses | A call supplies the type argument explicitly; the dictionary is searched | `doxa/test/typeclass_elab_test.dart` | "a missing explicit type argument fails at the first value" | Yes |
| Typeclasses | Depth-bounded search and nested-constraint discharge | `doxa/test/parameterised_instance_test.dart` | "a missing element instance names the inner class and type", "a chain deeper than the bound reports the depth diagnostic" | Yes |
| Typeclasses | Parameterised instances with explicit type arguments | `doxa/test/parameterised_instance_test.dart`, `doxa_tooling/test/package_import_test.dart` | "a List instance is a binding with explicit parameters and reduces at List Nat", "the Eqb domain package re-exports the class and its instances" | Yes |
| Typeclasses | Instance-target validation rejects unsupported shapes | `doxa/test/parameterised_instance_test.dart` | "invalid target shapes are rejected with their reasons" | Yes |
| Typeclasses | Overlapping instances are rejected | `doxa/test/parameterised_instance_test.dart`, `doxa/test/typeclass_elab_test.dart` | "a second List instance is rejected as overlapping", "a second instance for the same class and head is rejected" | Yes |
| Typeclasses | Instance bodies do not see the instance being defined | `doxa/test/parameterised_instance_test.dart` | "a bare instance body cannot resolve its own instance", "a parameterised instance body cannot resolve its own instance" | Yes |
| Typeclasses | Projections are named `Class.method`; two classes may declare the same field name | `doxa/test/typeclass_elab_test.dart`, `doxa/test/typeclass_namespace_test.dart` | "two classes may share a method name", "two classes declare the same method and keep both projections" | Yes |
| Typeclasses | A qualified projection works in a term and a type and inherits from a parent | `doxa/test/typeclass_namespace_test.dart` | "Class.method resolves a projection in a term and a type", "a subclass-qualified name resolves to the parent projection" | Yes |
| Typeclasses | A bare method name resolves through the current class or a local dictionary's class, then a top-level binding, then a unique class; otherwise `AmbiguousClassMethod` | `doxa/test/typeclass_namespace_test.dart`, `doxa_tooling/test/typeclass_surface_test.dart` | "a constrained parameter selects its class projection", "a local dictionary selects its class projection", "a unique declaring class resolves without a local dictionary", "an ambiguous bare name names the candidate classes", "an ambiguous bare method name reports the diagnostic", "a unique class does not override a top-level function", "a local dictionary selects the class method over the top level", "the Nat multiply and the class multiply keep their own uses", "a top-level function wins over the class projections", "a local dictionary selects its class addComm", "the bare addComm is ambiguous across the declaring classes", "the class-qualified addComm and multiplyComm resolve" | Yes |
| Typeclasses | A class's law fields read the current class first, then its parents | `doxa/test/typeclass_namespace_test.dart`, `doxa/test/typeclass_laws_test.dart` | "a law reads its own method, then a parent method", "a law field names an operation declared earlier", "a law that references a later method is rejected", "the commutative laws name the parent operations", "the instance fields reduce through the dictionaries" | Yes |
| Typeclasses | `Ring`, `AddCommMonoid`, `AddCommGroup`, and `CommRing` with the `Int` instances and the `square` exercise | `doxa_stdlib/lib/stdlib/algebra.doxa`, `doxa_tooling/test/typeclass_surface_test.dart`, `doxa_tooling/test/fixtures/comm_ring_int.doxa` | "a ring checks the square and the qualified projections", "a commutative ring checks the commutative reductions" | Yes |
| Typeclasses | Unsupported class forms report their named diagnostics | `doxa/test/typeclass_elab_test.dart`, `doxa_tooling/test/typeclass_surface_test.dart` | "superclasses are rejected with the class and parent names", "a partial instance is rejected naming the missing method", "an unknown method is rejected", "an unknown class is rejected" | Yes |
| Documentation blocks | Every unmarked `doxa` block in `SPEC.md` and `README.md` is a checked program | `doxa_tooling/test/doc_blocks_test.dart` | "doxa blocks in the normative documents check" | Yes |

## Metatheoretic claims

| Claim | Confidence | Basis |
|---|---|---|
| Soundness (well-typed programs don't go wrong) | High for structural errors | Bidirectional checker with exhaustive coverage; all negative tests reject |
| Confluence (NbE normalisation) | High for known cases | Church numeral arithmetic tests at depths up to 1,000,000 via stack-stress; round-trip tests |
| Terminating evaluation | High for CIC-fragment | Structural recursion enforced; positivity enforced; no general recursion |
| Proof irrelevance consistency | High | Prop-elim restriction enforced; singleton elimination gated; Eq at Prop verified |
| K-freeness | High for the fragment | UIP not statable (negative test); Eq is standard inductive, no K axiom |

## Gaps

The following limitations are implemented behavior that the SPEC records
without a direct test. None prevents the test suite from passing.

1. **Inductive types and matching — mutual-data header independence** — a
   data declaration's header cannot refer to a sibling member of the same
   mutual block; such a reference fails with `UnresolvedName`.
2. **Inductive types and matching — cross-recursor ι-reductions** — a mutual
   `data` block produces one recursor per member; a call from one member's
   recursor to a sibling's is not wired as an ι-reduction. A `mutual fun`
   block with `match` covers the same use case.
3. **Inductive types and matching — non-indexed dependent-motive inference** —
   `match` infers the motive for indexed arms. For a non-indexed dependent
   motive, users write `T.ind` or `T.rec`.
4. **Inductive types and matching — one product-form record per module** —
   every product-form declaration desugars to `mk`; a second one in the same
   module reports `duplicate declaration "mk"`. Named constructor arguments
   are the workaround.

## Closed gaps

The multi-field projection and multi-method class gaps are closed.
`doxa/test/record_surface_test.dart` checks construction and projection for a
two-field record, a parameterised record, a third field, a dependent field, and
a nested record. `doxa/test/typeclass_elab_test.dart` checks a two-method class
whose methods reduce and a class whose method types mention the parameter.
`doxa/test/typeclass_namespace_test.dart` checks class-qualified projections,
bare-name resolution, the superclass chain, and law-field resolution, and the
ring fixture checks `Ring[Int]` and `square` through the CLI. The commutative
fixture checks `AddCommMonoid[Int]`, `AddCommGroup[Int]`, and `CommRing[Int]`,
their derived parents, and the `addComm`/`multiplyComm` reductions through the
CLI.
