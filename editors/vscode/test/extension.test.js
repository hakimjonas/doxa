const assert = require('node:assert/strict');
const Module = require('node:module');
const path = require('node:path');

const extensionPath = path.resolve(__dirname, '..', 'extension.js');

function loadExtension({ serverPath, workspaceFolders }) {
  const watchers = [];
  const clients = [];
  const vscode = {
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
    },
    RelativePattern: class RelativePattern {
      constructor(folder, glob) {
        this.folder = folder;
        this.glob = glob;
      }
    },
  };
  class LanguageClient {
    constructor(...args) {
      this.args = args;
      clients.push(this);
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
    return { extension: require(extensionPath), clients, watchers };
  } finally {
    Module._load = originalLoad;
  }
}

async function main() {
  const folders = [{ uri: 'file:///workspace' }];
  const { extension, clients, watchers } = loadExtension({
    serverPath: '/opt/doxa',
    workspaceFolders: folders,
  });
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
  assert.deepEqual(context.subscriptions, [clients[0]]);

  await extension.deactivate();
  assert.equal(clients[0].stopped, true);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
