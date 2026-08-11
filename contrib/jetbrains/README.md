# Doxa — JetBrains IDE Support

The JetBrains plugin lives in the main Doxa monorepo at
[`editors/jetbrains/`](../../editors/jetbrains/).

## Quick start

```sh
cd editors/jetbrains
./gradlew buildPlugin  # needs JDK 21+
```

The plugin artifact is at `editors/jetbrains/build/distributions/doxa-jetbrains.zip`.

Install it via **Settings → Plugins → Install Plugin from Disk**, or install
from the [JetBrains Marketplace](https://plugins.jetbrains.com/).

## Configuration

After installing, set the path to the `doxa` binary at
**Settings → Languages & Frameworks → Doxa**.

The `doxa` binary can be installed via:

```sh
dart pub global activate doxa_tooling
```

Or downloaded from the latest [GitHub Release](https://github.com/hakimjonas/doxa/releases).
