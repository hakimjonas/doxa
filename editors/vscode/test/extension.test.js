const assert = require('node:assert/strict');
const Module = require('node:module');
const path = require('node:path');

const extensionPath = path.resolve(__dirname, '..', 'extension.js');

function loadExtension({ serverPath, workspaceFolders }) {
  const watchers = [];
  const clients = [];
  const commands = [];
  const notifications = [];
  const panels = [];
  const selectionHandlers = [];
  const vscode = {
    commands: {
      registerCommand: (command, handler) => {
        commands.push({ command, handler });
        return { command, handler };
      },
    },
    window: {
      createWebviewPanel: (viewType, title, showOptions, options) => {
        const panel = {
          viewType,
          title,
          showOptions,
          options,
          html: '',
          visible: true,
          revealed: false,
          webview: {},
          onDidDispose(handler) {
            this.disposeHandler = handler;
          },
          reveal(_column, preserveFocus) {
            this.revealed = true;
            this.preserveFocus = preserveFocus;
          },
          dispose() {
            if (this.disposeHandler) this.disposeHandler();
          },
        };
        panels.push(panel);
        return panel;
      },
      onDidChangeTextEditorSelection: handler => {
        selectionHandlers.push(handler);
        return { handler };
      },
      onDidChangeActiveTextEditor: handler => ({ handler }),
    },
    workspace: {
      getConfiguration: section => {
        assert.equal(section, 'doxa');
        return { get: () => serverPath };
      },
      workspaceFolders,
      createFileSystemWatcher: pattern => {
        const watcher = { pattern };
        watchers.push(watcher);
        return watcher;
      },
      onDidCloseTextDocument: handler => ({ handler }),
      onDidChangeConfiguration: handler => ({ handler }),
    },
    RelativePattern: class RelativePattern {
      constructor(folder, glob) {
        this.folder = folder;
        this.glob = glob;
      }
    },
    ViewColumn: { Beside: 2 },
  };
  class LanguageClient {
    constructor(...args) {
      this.args = args;
      this.notificationHandlers = new Map();
      clients.push(this);
    }

    onNotification(method, handler) {
      this.notificationHandlers.set(method, handler);
      notifications.push({ method, handler });
    }

    start() {
      this.started = true;
    }

    stop() {
      this.stopped = true;
      return Promise.resolve();
    }
  }

  const originalLoad = Module._load;
  Module._load = (request, parent, isMain) => {
    if (request === 'vscode') return vscode;
    if (request === 'vscode-languageclient/node') return { LanguageClient };
    return originalLoad(request, parent, isMain);
  };
  delete require.cache[extensionPath];
  try {
    return {
      extension: require(extensionPath),
      clients,
      watchers,
      commands,
      notifications,
      panels,
      selectionHandlers,
      vscode,
    };
  } finally {
    Module._load = originalLoad;
  }
}

async function main() {
  const folders = [{ uri: 'file:///workspace' }];
  const loaded = loadExtension({
    serverPath: '/opt/doxa',
    workspaceFolders: folders,
  });
  const { extension, clients, watchers, commands, notifications, panels } =
    loaded;
  const context = { subscriptions: [] };

  extension.activate(context);

  assert.equal(clients.length, 1);
  assert.equal(clients[0].started, true);
  assert.deepEqual(clients[0].args[1], 'Doxa Language Server');
  assert.equal(clients[0].args[2].run.command, '/opt/doxa');
  assert.deepEqual(clients[0].args[2].run.args, ['lsp']);
  assert.deepEqual(clients[0].args[3].documentSelector, [
    { scheme: 'file', language: 'doxa' },
  ]);
  assert.equal(watchers.length, 1);
  assert.equal(watchers[0].pattern.folder, folders[0]);
  assert.equal(watchers[0].pattern.glob, '**/*.doxa');
  assert.equal(context.subscriptions[0], clients[0]);
  assert.equal(context.subscriptions.length, 6);

  // The proof-state panel command is registered and opens a panel.
  assert.equal(commands.length, 1);
  assert.equal(commands[0].command, 'doxa.proofState.show');
  commands[0].handler();
  assert.equal(panels.length, 1);
  assert.equal(panels[0].viewType, 'doxaProofState');
  assert.equal(panels[0].title, 'Doxa Proof State');

  // The client consumes the server's doxa/proofState notification.
  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].method, 'doxa/proofState');

  // A payload for the active document re-renders the panel with goals.
  const params = {
    uri: 'file:///workspace/proof.doxa',
    version: 3,
    blocks: [
      {
        span: {
          start: { line: 0, character: 30 },
          end: { line: 0, character: 44 },
        },
        solved: false,
        goals: [
          {
            context: [{ name: 'n', type: 'Nat' }],
            target: 'Eq Nat (plus zero n) n',
          },
        ],
      },
    ],
  };
  const fakeEditor = {
    document: { uri: { toString: () => params.uri }, languageId: 'doxa' },
    selection: { active: { line: 0, character: 35 } },
  };
  loaded.vscode.window.activeTextEditor = fakeEditor;
  notifications[0].handler(params);
  assert.match(panels[0].webview.html, /<span class="name">n<\/span>/);
  assert.match(panels[0].webview.html, / : Nat<\/span>/);
  assert.match(panels[0].webview.html, /Eq Nat \(plus zero n\) n/);

  // A cursor outside every block renders the neutral empty state.
  fakeEditor.selection.active = { line: 0, character: 5 };
  loaded.selectionHandlers[0]({ textEditor: fakeEditor });
  assert.match(panels[0].webview.html, /Place the cursor inside/);

  // HTML-escaped types cannot inject markup.
  fakeEditor.selection.active = { line: 0, character: 35 };
  notifications[0].handler({
    ...params,
    blocks: [
      {
        ...params.blocks[0],
        goals: [{ context: [], target: '<script>alert(1)</script>' }],
      },
    ],
  });
  loaded.selectionHandlers[0]({ textEditor: fakeEditor });
  assert.ok(!panels[0].webview.html.includes('<script>alert(1)'));
  assert.match(panels[0].webview.html, /&lt;script&gt;/);

  // A solved block renders the closed state.
  notifications[0].handler({
    ...params,
    blocks: [{ ...params.blocks[0], solved: true, goals: [] }],
  });
  loaded.selectionHandlers[0]({ textEditor: fakeEditor });
  assert.match(panels[0].webview.html, /No goals\./);

  await extension.deactivate();
  assert.equal(clients[0].stopped, true);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
