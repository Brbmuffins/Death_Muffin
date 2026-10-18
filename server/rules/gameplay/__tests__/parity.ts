import * as fs from 'node:fs';
import * as path from 'node:path';
import { expect } from 'vitest';

/**
 * Client / server parity fixtures. A rule module with a GDScript port builds a table of {fn, in, out} cases from the TypeScript rules;
 * the Godot suite named by `suite` replays each case through the port and must get `out` back (floats within 1e-9).
 * The committed file is what Godot reads: the test fails when it no longer matches the TypeScript, and
 * `UPDATE_<NAME>_PARITY=1 npx vitest run <this test>` rewrites it after a deliberate change made on both sides.
 */
export interface ParityCase {
  fn: string;
  in: unknown;
  out: unknown;
}

const ROOT = path.resolve(__dirname, '../../../../client/tests');

/** `call(fn, input, run)` records one case; the output is what JSON round-trips to, which is what Godot will read. */
export function recorder() {
  const cases: ParityCase[] = [];
  return {
    cases,
    add(fn: string, input: unknown, run: () => unknown) {
      cases.push({ fn, in: input, out: run() ?? null });
    },
  };
}

/** Writes (UPDATE_<ENV>_PARITY=1) or checks client/tests/<suite>/fixtures/<name>_parity.json against `cases`. */
export function checkParity(suite: string, name: string, env: string, cases: ParityCase[]) {
  const file = path.join(ROOT, suite, 'fixtures', `${name}_parity.json`);
  const text = `${JSON.stringify({ cases })}\n`;
  if (process.env[`UPDATE_${env}_PARITY`]) fs.writeFileSync(file, text);
  const committed = JSON.parse(fs.readFileSync(file, 'utf8'));
  expect(committed).toEqual(JSON.parse(text));
}
