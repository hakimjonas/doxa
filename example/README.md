# Doxa example

[`proofs.doxa`](proofs.doxa) is a self-contained tour of the language: it
defines the naturals and polymorphic lists, then proves a few small
theorems about them.

Check it with the CLI:

```sh
dart run bin/doxa.dart check example/proofs.doxa
```

Expected output:

```
OK: 26 declarations checked
```

What the example demonstrates:

- **Inferred constructor type arguments.** `cons one nil`, `nil`, and
  `refl x` never spell out their type parameter; it is inferred from
  context.
- **The ambient `Eq`.** Propositional equality comes from the prelude;
  programs use it directly without redeclaring or importing it.
- **Definitional proofs.** When two sides are equal by computation
  (`plus zero n` reduces to `n`), the proof is a bare `refl`.
- **Induction.** When the goal mentions a recursion variable that does
  not reduce (`plus n zero`), the proof uses the auto-generated
  dependent eliminator `Nat.ind` / `List.ind`.
- **Refutation.** `succ_ne_zero` derives `False` (the empty type) from
  the impossible equality `succ n = zero`, so the logic can say "no",
  not only prove things equal.
- **Indexed families.** `vlength_index` proves a theorem whose statement
  depends on a type-level index: a `Vec[A] n`'s runtime length equals the
  index `n` its type carries, by induction with `Vec.ind`.
