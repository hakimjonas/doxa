# Doxa — JetBrains IDE Support

Doxa supports any LSP-compatible editor.  JetBrains IDEs
(IntelliJ IDEA, CLion, PyCharm, etc.) connect via the
[LSP4IJ](https://plugins.jetbrains.com/plugin/23257-lsp4ij) plugin.

## Setup

1. Install the **LSP4IJ** plugin from the JetBrains Marketplace
   (`Settings → Plugins → Marketplace → search "LSP4IJ"`).

2. Open `Settings → Languages & Frameworks → Language Servers`.

3. Add a new **Raw Command** server definition:

   | Field | Value |
   |-------|-------|
   | **Server ID** | `doxa` |
   | **Extension** | `doxa` |
   | **Command** | `doxa lsp` |

4. Associate `.doxa` files: check that `.doxa` is registered
   under the **File type** mapping for the Doxa language.

## Features

Once connected, you get diagnostics (error squiggles), hover
(type display), go-to-definition, completion (with types
and frequency ranking), document symbols, code lens (inline
declaration types), and format-on-save — all via standard LSP.

## Manual configuration file

If the UI path doesn't work or you prefer file-based config,
create `~/.config/lsp4ij/servers/doxa.json` with:

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

Restart the IDE after adding this file.

## Troubleshooting

- Make sure `doxa` is on your `PATH`.
- Check LSP4IJ logs: `Help → Show Log in Finder/Explorer → lsp4ij.log`.
- Verify the server starts: run `doxa lsp` manually in a terminal
  (it should block waiting for stdin — press Ctrl+D to exit).
