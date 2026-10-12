import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';

describe('armor set copies', () => {
  it('the client data, icons and item migrations match the armor rules (tools/generate-armor-assets.mjs --check)', () => {
    expect(() => execFileSync('node', ['tools/generate-armor-assets.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });
});
