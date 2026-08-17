const esbuild = require('esbuild');

esbuild.build({
  entryPoints: ['extension.js'],
  bundle: true,
  platform: 'node',
  target: 'node18',
  outfile: 'out/extension.js',
  external: ['vscode'],
  minify: true,
  sourcemap: true,
}).catch(() => process.exit(1));
