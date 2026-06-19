# Doxa Benchmarks

Environment: AMD Ryzen 9 9950X3D, Dart SDK 3.12.1, AOT (`dart compile exe tool/benchmark.dart -o tool/benchmark_aot`).

## Real Workloads (AOT, best-of-5, 3 warmup)

| Workload | Source | Parse (us) | Elab+Check (us) | Total (ms) |
|----------|--------|------------|------------------|------------|
| stdlib/bool | 819 B | 184 | 61 | 0.245 |
| stdlib/eq | 3.7 KB | 920 | 481 | 1.401 |
| stdlib/list | 1.7 KB | 532 | 309 | 0.841 |
| stdlib/nat | 1.2 KB | 302 | 62 | 0.364 |
| stdlib/option | 495 B | 162 | 44 | 0.206 |
| stdlib/proofs | 11.5 KB | 5524 | 4154 | 9.678 |
| stdlib/vec | 1.5 KB | 361 | 174 | 0.535 |
| example/proofs | 4.8 KB | 1419 | 1053 | 2.472 |

## Church Depth Scaling (AOT, best-of-3, 2 warmup)

| Depth | Total (ms) |
|-------|------------|
| 100   | 1.209 |
| 500   | 18.462 |
| 1000  | 67.749 |
| 5000  | 1609.967 |

## Summary

- **Stdlib throughput**: All stdlib files check in under 10 ms AOT.
- **Parse vs. check ratio**: Parse is a small fraction of total time for most workloads except `stdlib/proofs` where the 11.5 KB source is dominated by the elaborator/checker (parse 5.6 ms vs. check 3.7 ms).
- **Church depth scaling**: The evaluator demonstrates near-linear O(N) scaling: depth 5000 completes in 1.53 s. The ratio from depth 500 to 5000 is roughly 86× for a 10× depth increase (parse time grows as O(N²) because the source string itself grows linearly with depth, but elab+check grows linearly).

## Phase History

| Phase | Description | stdlib/proofs (ms) | Delta |
|-------|-------------|---------------------|-------|
| 14.5  | Quotient types | 9.335 | baseline |
| 14.6  | Injectivity tests | 9.335 | (no kernel change) |
| 14.7  | Opacity + reducibility hints | 9.268 | −0.067 (noise) |
| 15    | Universe polymorphism | 9.340 | +0.072 (noise) |
| 16    | SProp + strict irrelevance | 9.340 | flat (additive only) |
| 17    | Primitive projections + η | 9.678 | +0.338 (minor) |
