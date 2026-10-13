'use strict';
/**
 * A value guard (authority.cjs, kills.cjs) that cannot run refuses the write instead of letting it through unchecked (fail closed,
 * owner 2026-10-13). Routes answer it as 503 with this message; the client's save queues already retry with backoff.
 */
class GuardUnavailable extends Error {
  constructor(what, cause) {
    super('The server could not check that right now, so nothing was saved yet. It will try again in a moment.');
    this.unavailable = true;
    this.status = 503;
    this.what = what;
    this.cause = cause;
  }
}

module.exports = { GuardUnavailable };
