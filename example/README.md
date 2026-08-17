# Doxa example

[`proofs.doxa`](proofs.doxa) is a compact tour of the language. It imports
the natural-number, list, and vector definitions from the standard library
and proves several small theorems about them.

Check it with the CLI:

```sh
doxa_tooling/build/doxa check example/proofs.doxa
```

Expected output:

```
OK: 59 declarations checked
```

What the example demonstrates:

- Constructor type arguments are inferred in expressions such as
  `cons one nil`, `nil`, and reflexivity proofs.
- `Eq` is available from the ambient prelude, so the example uses it
  without redeclaring it.
- `plus zero n` reduces to `n`, so its equality proof is a bare `refl`.
- `plus n zero` requires induction because `n` is the recursion variable;
  the proof uses the generated dependent eliminator `Nat.ind`.
- `succ_ne_zero` derives `False`, the empty type, from the impossible
  equality `succ n = zero`.
- `vlength_index` uses `Vec.ind` to prove that the runtime length of a
  `Vec A n` equals its index `n`.
