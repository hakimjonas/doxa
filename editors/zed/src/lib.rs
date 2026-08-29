use std::path::PathBuf;

use zed_extension_api::{self as zed, Command, LanguageServerId, Result};

const SERVER_BINARY: &str = "doxa";

struct DoxaExtension;

impl zed::Extension for DoxaExtension {
    fn new() -> Self {
        DoxaExtension
    }

    /// Start the Doxa language server (`doxa lsp`) for a worktree.
    ///
    /// The server binary is resolved from the worktree's PATH first, then
    /// from `~/.local/bin` and `~/.pub-cache/bin` (the locations used by
    /// release binaries and `dart pub global activate`). This mirrors the
    /// VS Code extension's default configuration.
    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<Command> {
        let command = resolve_server_binary(worktree).ok_or_else(|| {
            format!(
                "could not find the `{SERVER_BINARY}` binary on PATH, in \
                 `~/.local/bin`, or in `~/.pub-cache/bin`. Install Doxa's \
                 tooling with one of: a release binary from \
                 https://github.com/hakimjonas/doxa/releases; \
                 `dart pub global activate doxa_tooling`; or building from \
                 source with `dart compile exe`."
            )
        })?;

        Ok(Command {
            command,
            args: vec!["lsp".into()],
            env: Default::default(),
        })
    }
}

fn resolve_server_binary(worktree: &zed::Worktree) -> Option<String> {
    // Zed resolves extension language-server commands relative to the
    // extension work directory, so a bare name would never reach the
    // user's PATH: ask the worktree for the absolute path instead.
    if let Some(path) = worktree.which(SERVER_BINARY) {
        return Some(path);
    }

    // `std::env::var` is unavailable inside a WASM extension, so read
    // HOME from the shell environment Zed exposes to extensions.
    let home = worktree
        .shell_env()
        .into_iter()
        .find(|(key, _)| key == "HOME")
        .map(|(_, value)| value)?;

    let candidates = [
        PathBuf::from(&home).join(".local/bin").join(SERVER_BINARY),
        PathBuf::from(&home).join(".pub-cache/bin").join(SERVER_BINARY),
    ];

    candidates
        .into_iter()
        .find(|path| std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file()))
        .map(|path| path.to_string_lossy().into_owned())
}

zed::register_extension!(DoxaExtension);
