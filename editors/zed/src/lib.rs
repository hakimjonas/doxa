use zed_extension_api::{self as zed, Command, LanguageServerId, Result};

struct DoxaExtension;

impl zed::Extension for DoxaExtension {
    fn new() -> Self {
        DoxaExtension
    }

    /// Start the Doxa language server (`doxa lsp`) for a worktree.
    ///
    /// The server binary is expected on the user's PATH: install a
    /// release binary from the doxa GitHub releases, or run
    /// `dart pub global activate doxa_tooling`. This mirrors the VS
    /// Code extension's default configuration.
    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        _worktree: &zed::Worktree,
    ) -> Result<Command> {
        Ok(Command {
            command: "doxa".into(),
            args: vec!["lsp".into()],
            env: Default::default(),
        })
    }
}

zed::register_extension!(DoxaExtension);
