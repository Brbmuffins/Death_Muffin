/**
 * embed-realtime.mjs — refresh the copies of server.js / package.json that
 * server/realtime/deploy-realtime.sh embeds (the VPS one-shot deploy script),
 * so the script always deploys what's in the repo. Run after editing the
 * realtime service: node tools/embed-realtime.mjs
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'server', 'realtime');
const scriptPath = join(dir, 'deploy-realtime.sh');
let script = readFileSync(scriptPath, 'utf8').replace(/\r\n/g, '\n');

function embed(marker, file) {
  const body = readFileSync(join(dir, file), 'utf8').replace(/\r\n/g, '\n').replace(/\n$/, '');
  if (body.includes(marker)) throw new Error(`${file} contains the heredoc marker ${marker}`);
  const re = new RegExp(`(<<'${marker}'\\n)[\\s\\S]*?(\\n${marker}\\n)`);
  if (!re.test(script)) throw new Error(`marker ${marker} not found`);
  script = script.replace(re, (_m, open, close) => `${open}${body}${close}`);
}

embed('CWEOF_SERVER', 'server.js');
embed('CWEOF_PKG', 'package.json');
writeFileSync(scriptPath, script);
console.log('deploy-realtime.sh refreshed (server.js + package.json embedded)');
