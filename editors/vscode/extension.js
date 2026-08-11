const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client = null;

function getServerCommand() {
  const config = vscode.workspace.getConfiguration('doxa');
  return config.get('server.path', 'doxa');
}

function activate(context) {
  const serverCommand = getServerCommand();

  const serverOptions = {
    run: {
      command: serverCommand,
      args: ['lsp'],
      options: { env: Object.assign({}, process.env) },
    },
    debug: {
      command: serverCommand,
      args: ['lsp'],
      options: { env: Object.assign({}, process.env) },
    },
  };

  const workspaceFolders = vscode.workspace.workspaceFolders;
  const fileEvents = workspaceFolders
    ? workspaceFolders.map(f =>
        vscode.workspace.createFileSystemWatcher(
          new vscode.RelativePattern(f, '**/*.doxa'),
        ))
    : [];

  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'doxa' }],
    synchronize: { fileEvents },
  };

  client = new LanguageClient(
    'doxa-lsp',
    'Doxa Language Server',
    serverOptions,
    clientOptions,
  );

  context.subscriptions.push(client);
  client.start();
}

function deactivate() {
  if (client) {
    return client.stop();
  }
}

module.exports = { activate, deactivate };
