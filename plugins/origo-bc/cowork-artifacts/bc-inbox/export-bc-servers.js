#!/usr/bin/env node
// export-bc-servers.js
// Les bc-* servers ur Claude Desktop config og vistar i bc-servers.json
// Keyra thegar nyrri tengingu er baett vid Cowork
//
// Windows:  node export-bc-servers.js
// Mac/Linux: node export-bc-servers.js

const fs   = require('fs');
const path = require('path');
const os   = require('os');

function getConfigPath() {
  switch (os.platform()) {
    case 'win32':
      return path.join(process.env.APPDATA || '', 'Claude', 'claude_desktop_config.json');
    case 'darwin':
      return path.join(os.homedir(), 'Library', 'Application Support', 'Claude', 'claude_desktop_config.json');
    default:
      return path.join(os.homedir(), '.config', 'Claude', 'claude_desktop_config.json');
  }
}

const configPath = getConfigPath();
const outputPath = path.join(__dirname, 'bc-servers.json');

if (!fs.existsSync(configPath)) {
  console.error('Config skra finnst ekki:', configPath);
  process.exit(1);
}

const config    = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const servers   = config.mcpServers || {};
const bcServers = Object.keys(servers)
  .filter(k => k.startsWith('bc-'))
  .map(k => ({ server: k }));

fs.writeFileSync(outputPath, JSON.stringify(bcServers, null, 2), 'utf8');
console.log(`Vistad ${bcServers.length} bc-* umhverfi i: ${outputPath}`);
bcServers.forEach(s => console.log('  -', s.server));
