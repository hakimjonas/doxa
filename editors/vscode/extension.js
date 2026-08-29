const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client = null;
let panel = null;

// Latest doxa/proofState payload per document uri. The server sends a
// full replacement after every check, so a payload is never patched.
const proofStateByUri = new Map();

function getServerCommand() {
  const config = vscode.workspace.getConfiguration('doxa');
  return config.get('server.path', 'doxa');
}

function createServerOptions(command) {
  return {
    run: {
      command,
      args: ['lsp'],
      options: { env: Object.assign({}, process.env) },
    },
    debug: {
      command,
      args: ['lsp'],
      options: { env: Object.assign({}, process.env) },
    },
  };
}

// True when position lies within span (inclusive of both ends so the
// cursor resting just after the block still shows its goals).
function spanContains(span, position) {
  const start = span.start;
  const end = span.end;
  if (position.line < start.line || position.line > end.line) {
    return false;
  }
  if (position.line === start.line && position.character < start.character) {
    return false;
  }
  if (position.line === end.line && position.character > end.character) {
    return false;
  }
  return true;
}

function spanSize(span) {
  return (span.end.line - span.start.line) * 100000 +
    (span.end.character - span.start.character);
}

// Innermost proof-state block containing the cursor, or null.
function blockAtPosition(payload, position) {
  let best = null;
  let bestSize = 0;
  for (const block of payload.blocks || []) {
    if (!spanContains(block.span, position)) {
      continue;
    }
    const size = spanSize(block.span);
    if (best === null || size < bestSize) {
      best = block;
      bestSize = size;
    }
  }
  return best;
}

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function goalHtml(goal, index) {
  const parts = [];
  const title = (goal.context || []).length > 0 && (goal.context || []).length;
  if (title !== null && title > 1) {
    parts.push(`<div class="goal-heading">goal ${index}</div>`);
  }
  for (const binder of goal.context || []) {
    parts.push(
      `<div class="binder">` +
        `<span class="name">${escapeHtml(binder.name)}</span>` +
        `<span class="type"> : ${escapeHtml(binder.type)}</span>` +
      `</div>`,
    );
  }
  parts.push('<div class="separator">&#8866;</div>');
  parts.push(`<div class="target">${escapeHtml(goal.target)}</div>`);
  return parts.join('\n');
}

function bodyHtml() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'doxa') {
    return '<p class="empty">Open a .doxa file to see its proof state.</p>';
  }
  const payload = proofStateByUri.get(editor.document.uri.toString());
  if (!payload) {
    return '<p class="empty">Waiting for the language server to check this document.</p>';
  }
  const block = blockAtPosition(payload, editor.selection.active);
  if (!block) {
    return '<p class="empty">Place the cursor inside a <code>by { ... }</code> block to see its goals.</p>';
  }
  const goals = block.goals || [];
  if (block.solved || goals.length === 0) {
    return '<p class="solved">No goals.</p>';
  }
  const heading =
    goals.length === 1
      ? '<div class="goal-heading">1 goal</div>'
      : `<div class="goal-heading">${goals.length} goals</div>`;
  return (
    heading +
    goals
      .map((goal, index) =>
        `<div class="goal">${goalHtml(goal, index + 1)}</div>`)
      .join('\n')
  );
}

function renderPanel() {
  if (!panel) {
    return;
  }
  panel.webview.html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body {
    font-family: var(--vscode-editor-font-family, monospace);
    font-size: var(--vscode-editor-font-size, 13px);
    color: var(--vscode-editor-foreground);
    background: var(--vscode-editor-background);
    padding: 8px 12px;
  }
  .empty, .solved { color: var(--vscode-descriptionForeground); }
  .solved { color: var(--vscode-testing-iconPassed, #73c991); }
  .goal-heading {
    color: var(--vscode-descriptionForeground);
    font-family: var(--vscode-font-family, sans-serif);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    margin: 8px 0 4px 0;
  }
  .goal { margin-bottom: 12px; }
  .binder .name { color: var(--vscode-symbolIcon-variableForeground); }
  .binder .type { color: var(--vscode-descriptionForeground); }
  .separator {
    color: var(--vscode-descriptionForeground);
    margin: 2px 0;
  }
  .target { white-space: pre-wrap; }
  code {
    font-family: var(--vscode-editor-font-family, monospace);
    color: var(--vscode-editor-foreground);
  }
</style>
</head>
<body>
${bodyHtml()}
</body>
</html>`;
}

function showPanel() {
  if (panel) {
    panel.reveal(undefined, true);
    renderPanel();
    return;
  }
  panel = vscode.window.createWebviewPanel(
    'doxaProofState',
    'Doxa Proof State',
    { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
    { enableScripts: false, localResourceRoots: [] },
  );
  panel.onDidDispose(() => {
    panel = null;
  });
  renderPanel();
}

function activate(context) {
  const serverCommand = getServerCommand();

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
    createServerOptions(serverCommand),
    clientOptions,
  );

  // Server-pushed proof state: one payload per document, replaced in
  // full after every check. No server round-trip happens on cursor
  // movement; the panel picks the block under the cursor locally.
  client.onNotification('doxa/proofState', params => {
    if (params && typeof params.uri === 'string') {
      proofStateByUri.set(params.uri, params);
      renderPanel();
    }
  });

  context.subscriptions.push(
    client,
    vscode.commands.registerCommand('doxa.proofState.show', showPanel),
    vscode.window.onDidChangeTextEditorSelection(event => {
      if (panel && event.textEditor.document.languageId === 'doxa') {
        renderPanel();
      }
    }),
    vscode.window.onDidChangeActiveTextEditor(() => renderPanel()),
    vscode.workspace.onDidCloseTextDocument(document => {
      proofStateByUri.delete(document.uri.toString());
    }),
    vscode.workspace.onDidChangeConfiguration(event => {
      if (event.affectsConfiguration('doxa.server.path')) {
        vscode.window.showInformationMessage(
          'Restart the language server for the new Doxa server path to take effect.',
        );
      }
    }),
  );
  client.start();
}

function deactivate() {
  proofStateByUri.clear();
  if (client) {
    return client.stop();
  }
}

module.exports = { activate, deactivate };
