# Example

`proofs.doxa` imports `package:doxa_stdlib/stdlib/nat.doxa` and
`package:doxa_stdlib/stdlib/proofs.doxa` and proves that `plus two zero` is
`two`.

The package configuration is the one in this directory's parent, so fetch it
once from `doxa_stdlib/`:

```sh
cd doxa_stdlib
dart pub get
```

Check the example from the repository root:

```sh
dart run doxa_tooling/bin/doxa.dart check doxa_stdlib/example/proofs.doxa
```

A consumer project declares `doxa_stdlib` as a dependency and runs
`dart pub get`; the import form in the example is the same.
