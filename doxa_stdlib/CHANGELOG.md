# Changelog

## 0.8.4

- First release of the standard library as its own package. The sources
  moved here from the repository `lib/stdlib/`, which no longer exists.
- The canonical files stay flat under `lib/stdlib/`; each domain directory
  holds only a `package.doxa` re-export. The per-domain symlinks are gone.
- `lib/doxa_stdlib.dart` exposes the packaged standard-library root
  (`stdlibRoot`, `stdlibRootPath`) without a dependency on the kernel or
  the tooling.
- `example/proofs.doxa` shows a proof that imports the library by package
  URI (`package:doxa_stdlib/stdlib/nat.doxa`).
