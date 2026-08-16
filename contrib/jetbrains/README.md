# Doxa JetBrains IDE support

The JetBrains plugin is in the main Doxa repository at
[`editors/jetbrains/`](../../editors/jetbrains/).

## Quick start

```sh
cd editors/jetbrains
./gradlew buildPlugin  # requires JDK 21 or later
```

The plugin artifact is at `editors/jetbrains/build/distributions/doxa-jetbrains.zip`.

Install it with **Settings > Plugins > Install Plugin from Disk**. The plugin
targets IntelliJ Platform 2025.1-compatible IDEs.

## Configuration

After installing, set the path to the `doxa` binary at
**Settings → Languages & Frameworks → Doxa**.

The `doxa` binary can be installed via:

```sh
dart pub global activate doxa_tooling
```

Or downloaded from the latest [GitHub Release](https://github.com/hakimjonas/doxa/releases).
