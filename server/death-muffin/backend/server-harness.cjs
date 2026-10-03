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
  const uses = [];
  const noop = () => {};
  const stubs = {
    dotenv: { config: noop },
    bcrypt: { hash: async () => 'hash', compare: async () => true },
    jsonwebtoken: {
      // Like the real library, an `expiresIn: undefined` option is an error, not "no expiry".
      sign: (claims, _secret, opts = {}) => {
        if ('expiresIn' in opts && !(Number.isInteger(opts.expiresIn) || (typeof opts.expiresIn === 'string' && opts.expiresIn))) throw new Error('"expiresIn" should be a number of seconds or string representing a timespan');
        return JSON.stringify(claims);
      },
      verify: (token) => {
        try { return JSON.parse(token); } catch { throw new Error('bad token'); }
      },
    },
    'mysql2/promise': { createPool: () => pool },
    'express-rate-limit': () => (_req, _res, next) => next(),
    express: Object.assign(
      () => {
        const add = (method) => (route, ...chain) => routes.set(`${method} ${route}`, chain);
        return { use: (...fns) => uses.push(...fns), set: noop, listen: noop, get: add('GET'), post: add('POST'), patch: add('PATCH'), put: add('PUT'), delete: add('DELETE') };
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

  /** Run the error-handling middleware registered with app.use(err, req, res, next) for `err`; returns { status, json, passedOn }. */
  function fail(err) {
    const out = { status: 200, json: undefined, passedOn: false };
    const res = { headersSent: false, status(code) { out.status = code; return this; }, json(j) { out.json = j; this.headersSent = true; return this; } };
    const req = { method: 'POST', path: '/x', originalUrl: '/x', headers: {} };
    for (const fn of uses.filter((f) => f.length === 4)) {
      let next = false;
      fn(err, req, res, () => { next = true; });
      if (!next) return out;
    }
    out.passedOn = true;
    return out;
  }

  /** Run the app.use(req, res, next) middleware in front of every route on a fake response; returns the response so a test can call res.json(...). */
  function wrap(reqInit = {}) {
    const out = { status: 200, json: undefined };
    const res = { statusCode: 200, status(code) { out.status = code; this.statusCode = code; return this; }, json(j) { out.json = j; return this; } };
    const req = { method: 'POST', originalUrl: '/api/vault/deposit', url: '/api/vault/deposit', headers: {}, ...reqInit };
    for (const fn of uses.filter((f) => f.length === 3)) fn(req, res, () => {});
    return { res, out };
  }

  return { routes, call, fail, wrap };
}

module.exports = { loadServer };
