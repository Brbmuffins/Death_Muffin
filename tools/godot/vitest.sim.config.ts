import { defineConfig } from 'vitest/config';

// Runs the fixture generators that need vitest's module mocking (the real AbilitySystem / Effects in node): npx vitest run --config tools/godot/vitest.sim.config.ts
export default defineConfig({ test: { include: ['tools/godot/**/*.fixture.ts'], environment: 'node', testTimeout: 600000 } });
