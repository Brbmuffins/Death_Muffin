'use strict';
/**
 * DROPS_MODE (server-decided drops, DECISIONS B20): `enforce` (the default since 2026-10-14) refuses a drop claim that breaks a bound and
 * keeps drop items a bag save tries to add without a claim out of the bag; `audit` only logs both. Read on every call.
 */
const dropsMode = (env = process.env) => (String(env.DROPS_MODE || '').trim().toLowerCase() === 'audit' ? 'audit' : 'enforce');

module.exports = { dropsMode };
