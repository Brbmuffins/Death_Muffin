'use strict';
// Friend lists for presence (README "Friends"). The lobby has no DB: it asks the auth backend's GET /api/friends with the player's OWN token
// (the one the socket authenticated with), so it only ever learns that account's accepted friends. null = could not tell (the lobby keeps the
// last list it had). Tests use createFileFriendsSource instead: a JSON file {"<accountId>": [friend ids]}, read on every lookup.
const fs = require('fs');

function createFriendsSource({ backendUrl, fetchImpl = globalThis.fetch, timeoutMs = 3000 }) {
  return async function friendsOf(token) {
    try {
      const r = await fetchImpl(`${backendUrl}/api/friends`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(timeoutMs) });
      const j = r.ok ? await r.json() : null;
      const list = j && j.success && j.data && Array.isArray(j.data.friends) ? j.data.friends : null;
      return list ? list.map((f) => f && f.accountId).filter(Number.isSafeInteger) : null;
    } catch { return null; }
  };
}

function createFileFriendsSource(file) {
  return async function friendsOf(_token, accountId) {
    try {
      const all = JSON.parse(fs.readFileSync(file, 'utf8'));
      const list = all[String(accountId)];
      return Array.isArray(list) ? list.filter(Number.isSafeInteger) : [];
    } catch { return null; }
  };
}

module.exports = { createFriendsSource, createFileFriendsSource };
