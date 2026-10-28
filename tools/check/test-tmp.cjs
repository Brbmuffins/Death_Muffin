'use strict';
// Preload for node test runs on the VPS (`node --require ./tools/check/test-tmp.cjs --test ...`; npm run test:server and test:agent use it):
// each test process gets its own temp folder (TMPDIR, which os.tmpdir(), git and mktemp all use) and removes it on exit, so the
// folders the tests make never pile up in /tmp. node --test passes the preload on to every test file's process. Found 2026-10-28:
// 27,000 test worlds (41 GB) left by runs of the Discord agent's suite.
const fs = require('fs'), os = require('os'), path = require('path');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-test-'));
process.env.TMPDIR = root;
process.on('exit', () => { try { fs.rmSync(root, { recursive: true, force: true }); } catch {} });
