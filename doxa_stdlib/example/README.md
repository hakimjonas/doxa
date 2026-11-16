# Example

`proofs.doxa` imports `lib/stdlib/nat.doxa` and `lib/stdlib/proofs.doxa` by
relative path and proves that `plus two zero` is `two`.

Check it from the repository root:

```sh
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/example/proofs.doxa
```

The relative import is a stand-in for a packaged import. Resolving a
`package:` URI or a configured standard-library root is a separate change to
the import resolver; until then a Doxa program names the source file by path.
