import { defineConfig } from 'vitest/config';

// Unit tests for the shared server rules (server/rules: the TypeScript sources build-server-rules compiles into the backend's .cjs).
export default defineConfig({
  test: { include: ['server/rules/**/*.test.ts'] },
});
