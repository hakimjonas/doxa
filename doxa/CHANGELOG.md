# Changelog

## 0.8.4

- Specified `Nat` division and modulo in `docs/arithmetic.md` and proved
  `sub_zero`, `mod_acc_zero`, `mod_zero`, and `div_zero`.
- Fixed `prime` to test divisors from `n - 1` down to `2`, `gcd` to use
  `m + n` fuel, and `coprime` to require a nonzero gcd.
- Recursor type synthesis and iota reduction for dependent Pi constructor
  arguments and function-typed recursive arguments.
- Constructor data parameters are solved from the expected type in check
  mode before the explicit arguments are checked.
- Match-arm telescopes use the data parameter order.
- `Acc` is parameterized by its relation, and `strong_ind` is defined via
  `Acc.rec` over `nat_wf`.
- Rejected the `typeclass`, `impl`, `termination_by`, and quotient `mk` /
  `lift` surfaces until their soundness checks exist.

## 0.8.2

- Synchronized the package version with the repository release.

## 0.8.0

- Published the first preview of the Doxa kernel package.
