'use strict';
/**
 * Test helper: loads server.js with its heavy dependencies stubbed (express, mysql2, bcrypt, jsonwebtoken, dotenv, rate limiting,
 * the VPS-only necro-progress routes) so the routes defined in server.js itself can be called without a database or a socket.
 *
 *   const { loadServer } = require('./server-harness.cjs');
 *   const srv = loadServer({ pool });                       // pool: { execute, query, getConnection }
 *   const r = await srv.call('POST /api/craft', { body, user: { accountId: 1 } });   // -> { status, json }
 *
 * `call` runs the route's whole middleware chain (JWT check included; the stub token is the JSON of the claims), reports a thrown
 * handler error as status 500 the way Express 5 does, and never opens a port.
 */
const Module = require('module');
const path = require('path');

function loadServer({ pool, env = {} }) {
  const routes = new Map();
  const noop = () => {};
  const stubs = {
    dotenv: { config: noop },
    bcrypt: { hash: async () => 'hash', compare: async () => true },
    jsonwebtoken: {
      sign: (claims) => JSON.stringify(claims),
      verify: (token) => {
        try { return JSON.parse(token); } catch { throw new Error('bad token'); }
      },
    },
    'mysql2/promise': { createPool: () => pool },
    'express-rate-limit': () => (_req, _res, next) => next(),
    express: Object.assign(
      () => {
        const add = (method) => (route, ...chain) => routes.set(`${method} ${route}`, chain);
        return { use: noop, set: noop, listen: noop, get: add('GET'), post: add('POST'), patch: add('PATCH'), put: add('PUT'), delete: add('DELETE') };
      },
      { json: () => noop },
    ),
  };
  const originalLoad = Module._load;
  const savedEnv = {};
  const nextEnv = { JWT_SECRET: 'test', ...env };
  for (const k of Object.keys(nextEnv)) { savedEnv[k] = process.env[k]; process.env[k] = nextEnv[k]; }
  const originalInterval = global.setInterval;
  global.setInterval = (...a) => { const t = originalInterval(...a); if (t && t.unref) t.unref(); return t; };
  Module._load = function (request, parent, isMain) {
    if (Object.prototype.hasOwnProperty.call(stubs, request)) return stubs[request];
    if (/necro-progress\/(necro-progress-routes|mysql-store)\.cjs$/.test(request)) return { mountNecroProgress: noop, createMysqlStore: () => ({}) };
    return originalLoad.call(this, request, parent, isMain);
  };
  const file = path.join(__dirname, 'server.js');
  delete require.cache[file];
  try {
    require(file);
  } finally {
    Module._load = originalLoad;
    global.setInterval = originalInterval;
    for (const [k, v] of Object.entries(savedEnv)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }

  async function call(route, { body, params = {}, query = {}, user = { accountId: 1, username: 'tester' }, headers = {} } = {}) {
    const chain = routes.get(route);
    if (!chain) throw new Error(`no such route: ${route}`);
    const out = { status: 200, json: undefined, sent: false };
    const res = {
      statusCode: 200,
      headersSent: false,
      status(code) { out.status = code; this.statusCode = code; return this; },
      json(j) { out.json = j; out.sent = true; this.headersSent = true; return this; },
      set() { return this; },
    };
    const req = {
      body, params, query, method: route.split(' ')[0], path: route.split(' ')[1], originalUrl: route.split(' ')[1], user: undefined,
      headers: { authorization: `Bearer ${JSON.stringify(user)}`, ...headers },
      get(name) { return this.headers[String(name).toLowerCase()]; },
    };
    for (const fn of chain) {
      let advanced = false;
      try {
        await fn(req, res, () => { advanced = true; });
      } catch (err) {
        if (!out.sent) { out.status = 500; out.json = { error: 'internal server error', thrown: err && err.message }; }
        return out;
      }
      if (!advanced) break;
    }
    return out;
  }

  return { routes, call };
}

module.exports = { loadServer };
