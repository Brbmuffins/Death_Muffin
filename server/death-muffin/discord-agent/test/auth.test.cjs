'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig } = require('../runner/lib/config.cjs');
const { createAuth } = require('../runner/lib/auth.cjs');
const { redactText, looksSecret } = require('../runner/lib/redact.cjs');
const { scanDiffForSecrets } = require('../runner/lib/gitops.cjs');
const fs = require('fs'), os = require('os'), path = require('path');

const OWNER = '100000000000000001', HELIX = '142812688358178816', LIMITED = '300000000000000003', STRANGER = '400000000000000004';
function cfgWith(extra = {}) {
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'dmcfg-')), 'c.json');
  fs.writeFileSync(f, JSON.stringify({ ownerIds: [OWNER], projects: { deathmuffin: { requesters: [HELIX, LIMITED, 'HELIX_PLACEHOLDER', ''], approvers: { casual: [HELIX, LIMITED], gameplay: [HELIX], sensitive: [HELIX] } } }, ...extra }));
  return loadConfig(f);
}

test('unlisted users are not allowed; placeholders are inert', () => {
  const a = createAuth(cfgWith());
  assert.equal(a.roleOf(STRANGER), null); assert.equal(a.isAllowed(STRANGER), false);
  assert.equal(a.roleOf('HELIX_PLACEHOLDER'), null); assert.equal(a.roleOf(''), null); assert.equal(a.roleOf(undefined), null);
  assert.equal(a.roleOf(OWNER), 'owner'); assert.equal(a.roleOf(HELIX), 'approver');
});
test('owner always approves every tier even if not listed', () => {
  const a = createAuth(cfgWith());
  for (const t of ['casual', 'gameplay', 'sensitive']) assert.ok(a.canApprove(OWNER, t));
});
test('Helix is a full approver: all tiers, no cap, may switch model', () => {
  const a = createAuth(cfgWith());
  for (const t of ['casual', 'gameplay', 'sensitive']) assert.ok(a.canApprove(HELIX, t), t);
  assert.ok(a.isFull(HELIX)); assert.equal(a.maxTier(HELIX), 'sensitive'); assert.ok(a.canSwitchModel(HELIX));
});
test('limited approver: casual only', () => {
  const a = createAuth(cfgWith());
  assert.ok(a.canApprove(LIMITED, 'casual')); assert.ok(!a.canApprove(LIMITED, 'gameplay')); assert.ok(!a.canApprove(LIMITED, 'sensitive'));
  assert.equal(a.maxTier(LIMITED), 'casual'); assert.ok(!a.isFull(LIMITED)); assert.ok(!a.canSwitchModel(LIMITED));
});
test('requester-only members and strangers can never approve', () => {
  const c = cfgWith(); c.project.requesters.push('500000000000000005');
  const a = createAuth(c);
  assert.equal(a.roleOf('500000000000000005'), 'member');
  for (const t of ['casual', 'gameplay', 'sensitive']) { assert.ok(!a.canApprove('500000000000000005', t)); assert.ok(!a.canApprove(STRANGER, t)); }
  assert.equal(a.maxTier(STRANGER), null);
});
test('a user-supplied string cannot become a role (ids are digits only)', () => {
  const a = createAuth(cfgWith());
  assert.ok(!a.canApprove('owner', 'casual')); assert.ok(!a.canApprove(`${OWNER} `, 'casual')); assert.ok(!a.canApprove([OWNER, STRANGER], 'casual') || false);
});
test('rate limiter slides', () => {
  let t = 0; const a = createAuth(cfgWith(), () => t);
  for (let i = 0; i < 3; i++) assert.ok(a.rate('u', 3, 1000));
  assert.ok(!a.rate('u', 3, 1000)); t = 1001; assert.ok(a.rate('u', 3, 1000));
});
test('daily cap counts live ships of that approver today (UTC)', () => {
  const day = '2026-10-04T10:00:00.000Z'; const a = createAuth(cfgWith(), () => Date.parse(day));
  const ships = [{ type: 'live', approverId: LIMITED, ts: day }, { type: 'live', approverId: LIMITED, ts: '2026-10-03T23:00:00Z' }, { type: 'rollback', approverId: LIMITED, ts: day }, { type: 'live', approverId: HELIX, ts: day }];
  assert.equal(a.shipsToday(LIMITED, ships), 1);
});
test('redaction and secret scan', () => {
  assert.ok(looksSecret('token = "abcdefghijklmnop"')); assert.ok(looksSecret('ANTHROPIC sk-ant-api03-abcdefghijklmnopqrstuvwxyz')); assert.ok(looksSecret('-----BEGIN OPENSSH PRIVATE KEY-----'));
  assert.ok(looksSecret('MTU1MTMyNzM4NTU0OTI3NTEzNg.GabcDE.' + 'x'.repeat(30)));
  assert.equal(redactText('hello\npassword: hunter2hunter2\nbye'), 'hello\n[redacted line]\nbye');
  assert.ok(!looksSecret('Make the bone drop rate a bit higher'));
  const diff = 'diff --git a/src/a.ts b/src/a.ts\n+++ b/src/a.ts\n+const k = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz";\ndiff --git a/.env b/.env\n+X=1\n';
  assert.equal(scanDiffForSecrets(diff).length, 2);
  assert.equal(scanDiffForSecrets('diff --git a/src/a.ts b/src/a.ts\n+const hp = 5;\n').length, 0);
});
