const vscode = require('vscode');
const cp = require('child_process');
const path = require('path');

let client = null;

function activate(context) {
  const serverOptions = {
    run: {
      command: 'doxa',
      args: ['lsp'],
      options: { env: Object.assign({}, process.env) },
    },
    debug: {
      command: 'doxa',
      args: ['lsp'],
      options: { env: Object.assign({}, process.env) },
    },
  };

  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'doxa' }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.doxa'),
    },
  };

  const { LanguageClient } = require('vscode-languageclient/node');
  client = new LanguageClient(
    'doxa-lsp',
    'Doxa Language Server',
    serverOptions,
    clientOptions,
  );

  context.subscriptions.push(client.start());
}

function deactivate() {
  if (client) {
    return client.stop();
  }
}

module.exports = { activate, deactivate };
