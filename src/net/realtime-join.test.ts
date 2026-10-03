// @vitest-environment node
import { createRequire } from 'node:module';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ base: '' }));
vi.mock('./config', () => ({
  get WS_BASE() { return state.base; },
  WS_PATH: '',
  API_BASE: '',
  MAX_PARTY_SIZE: 10,
}));

const require = createRequire(import.meta.url);
const { Server } = require('../../server/realtime/node_modules/socket.io');

describe('RealtimeClient.connect', () => {
  let io: { close(): void; on(ev: string, fn: (s: any) => void): void };
  let http: import('node:http').Server;
  beforeAll(async () => {
    http = require('node:http').createServer();
    io = new Server(http);
    // A service that accepts the socket and then goes away before it answers the join (a restart in the middle of a rejoin).
    io.on('connection', (s: any) => s.on('world:join', () => s.disconnect(true)));
    await new Promise<void>((r) => http.listen(0, '127.0.0.1', r));
    state.base = `http://127.0.0.1:${(http.address() as { port: number }).port}`;
  });
  afterAll(() => {
    io.close();
    http.close();
  });

  it('rejects (retryably) when the link drops before the join is answered, instead of pending forever', async () => {
    const { setToken } = await import('./api');
    const { RealtimeClient } = await import('./realtime');
    const { isRetryableError } = await import('./reconnect');
    setToken('test-token');
    const client = new RealtimeClient();
    const noop = () => undefined;
    const handlers = { onPlayerJoin: noop, onPlayerLeave: noop, onPlayerMove: noop, onChat: noop, onDisconnect: noop, onIntent: noop, onSnapshot: noop, onEvents: noop, onHostChange: noop };
    const result = await Promise.race([
      client.connect({ instance: undefined, characterId: 1, classIndex: 1, level: 1, x: 0, z: 0, facing: 0, gear: {} } as never, handlers as never).then(() => 'joined', (e: Error) => e),
      new Promise<string>((r) => setTimeout(() => r('hung'), 3000)),
    ]);
    expect(result).not.toBe('hung');
    expect(result).toBeInstanceOf(Error);
    expect(isRetryableError(result, 'rejoin')).toBe(true);
    client.disconnect();
  });
});
