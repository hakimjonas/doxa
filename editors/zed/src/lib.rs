use zed_extension_api::{self as zed, Command, LanguageServerId, Result};

const SERVER_BINARY: &str = "doxa";

struct DoxaExtension;

impl zed::Extension for DoxaExtension {
    fn new() -> Self {
        DoxaExtension
    }

    /// Start the Doxa language server (`doxa lsp`) for a worktree.
    ///
    /// The server binary is resolved through the worktree's PATH. The
    /// extension does not read outside its own work directory, so the
    /// directory containing `doxa` must be on PATH. A release binary usually
    /// lives in `~/.local/bin`, and `dart pub global activate` installs into
    /// `~/.pub-cache/bin`; add the directory you use to PATH.
    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<Command> {
        let command = resolve_server_binary(worktree).ok_or_else(|| {
            format!(
                "could not find the `{SERVER_BINARY}` binary on PATH. Install the Doxa \
                 tooling and put its directory on PATH: a release binary (typically \
                 ~/.local/bin), `dart pub global activate doxa_tooling` (typically \
                 ~/.pub-cache/bin), or a source build. If you use ~/.local/bin or \
                 ~/.pub-cache/bin, add it to PATH so Zed can find it."
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
    worktree.which(SERVER_BINARY)
}

zed::register_extension!(DoxaExtension);
