# Doxa — JetBrains IDE Support

Doxa uses [LSP4IJ](https://plugins.jetbrains.com/plugin/23257-lsp4ij)
for JetBrains IDE integration.  LSP4IJ is the community-standard LSP
bridge for IntelliJ-based editors.  A dedicated Doxa plugin that
bundles LSP support directly is planned once the
`com.intellij.platform.lsp` module ships in Community Edition
(currently unavailable as of IntelliJ 2024.3 CE).

## Setup

1. Install the **LSP4IJ** plugin from the JetBrains Marketplace
   (`Settings → Plugins → Marketplace → search "LSP4IJ"`).

2. Create `~/.config/lsp4ij/servers/doxa.json`:

```json
{
  "serverId": "doxa",
  "commandLine": {
    "command": "doxa",
    "arguments": ["lsp"]
  },
  "fileType": {
    "extension": "doxa"
  }
}
```

3. Restart your IDE.

4. Open any `.doxa` file.  You get diagnostics, hover,
   completion (with types and frequency ranking), go-to-definition,
   formatting, code lens, and signature help — all via the Doxa
   language server.

Alternatively, configure via the GUI:
`Settings → Languages & Frameworks → Language Servers → Raw Command`.

| Field | Value |
|-------|-------|
| Server ID | `doxa` |
| Extension | `doxa` |
| Command | `doxa lsp` |

## Troubleshooting

- Ensure `doxa` is on your `PATH`.  Verify with `doxa --help`.
- Check LSP4IJ logs: `Help → Show Log in Finder/Explorer → lsp4ij.log`.
- Test the server manually: `doxa lsp` blocks waiting for stdin.
