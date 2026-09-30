import { io, type Socket } from 'socket.io-client';
import { WS_BASE, WS_PATH } from './config';
import { getToken } from './api';
import type {
  ChatMessage,
  EventBatch,
  IntentEnvelope,
  JoinRequest,
  JoinResult,
  PlayerMove,
  RemotePlayer,
  WorldSnapshot,
} from './contracts';
import type { Intent } from '../gameplay/sim/types';

export interface RealtimeHandlers {
  onPlayerJoin(p: RemotePlayer): void;
  onPlayerLeave(id: string): void;
  onPlayerMove(u: PlayerMove & { id: string }): void;
  onPlayerGear?(u: { id: string; gear: Record<string, string> }): void;
  onChat(m: ChatMessage): void;
  onDisconnect(): void;
  onIntent(env: IntentEnvelope): void;
  onSnapshot(s: WorldSnapshot): void;
  onEvents(batch: EventBatch): void;
  onHostChange(hostId: string, snapshot: WorldSnapshot | null): void;
}

/**
 * Socket.io client for the co-op world. Solo play never depends on it: if
 * the service is down, connect() rejects and the scene keeps simulating
 * locally. Join failures reject with the server's player-readable error.
 */
export class RealtimeClient {
  private socket: Socket | null = null;
  private hostId: string | null = null;
  instance: string | null = null;
  /** Message counters for QA / the debug overlay. */
  readonly stats = { snapIn: 0, snapOut: 0, evIn: 0, evOut: 0, intentIn: 0, intentOut: 0, moveIn: 0 };

  get connected() {
    return this.socket?.connected ?? false;
  }

  get selfId() {
    return this.socket?.id ?? null;
  }

  get isHost() {
    return this.connected && this.hostId === this.socket!.id;
  }

  connect(req: JoinRequest, h: RealtimeHandlers): Promise<JoinResult> {
    if (!WS_BASE) return Promise.reject(new Error('Realtime service not configured'));
    const token = getToken();
    if (!token) return Promise.reject(new Error('Not authenticated'));

    return new Promise((resolve, reject) => {
      const socket = io(WS_BASE, {
        auth: { token },
        reconnection: false,
        timeout: 6000,
        ...(WS_PATH ? { path: WS_PATH } : {}),
      });
      this.socket = socket;
      socket.on('connect_error', (err) => {
        reject(new Error(err.message === 'xhr poll error' ? 'Co-op service unreachable — playing solo' : err.message));
        socket.disconnect();
      });
      socket.on('connect', () => {
        socket.emit('world:join', req, (res: { success: boolean; data?: JoinResult; error?: string }) => {
          if (!res?.success || !res.data) {
            reject(new Error(res?.error ?? 'Could not join the world'));
            socket.disconnect();
            return;
          }
          socket.on('player:join', h.onPlayerJoin);
          socket.on('player:leave', ({ id }: { id: string }) => h.onPlayerLeave(id));
          socket.on('player:move', (u: PlayerMove & { id: string }) => {
            this.stats.moveIn++;
            h.onPlayerMove(u);
          });
          socket.on('player:gear', (u: { id: string; gear: Record<string, string> }) => h.onPlayerGear?.(u));
          socket.on('chat:message', h.onChat);
          socket.on('world:intent', (env: IntentEnvelope) => {
            this.stats.intentIn++;
            h.onIntent(env);
          });
          socket.on('world:snapshot', (s: WorldSnapshot) => {
            this.stats.snapIn++;
            h.onSnapshot(s);
          });
          socket.on('world:events', (b: EventBatch) => {
            this.stats.evIn++;
            h.onEvents(b);
          });
          socket.on('room:host', ({ hostId, snapshot }: { hostId: string; snapshot: WorldSnapshot | null }) => {
            this.hostId = hostId;
            h.onHostChange(hostId, snapshot);
          });
          socket.on('disconnect', () => h.onDisconnect());
          this.hostId = res.data.hostId;
          this.instance = res.data.instance;
          resolve(res.data);
        });
      });
    });
  }

  sendGear(gear: Record<string, string>) {
    this.socket?.emit('player:gear', gear);
  }

  sendMove(m: PlayerMove) {
    this.socket?.volatile.emit('player:move', m);
  }

  sendIntent(intent: Intent) {
    this.stats.intentOut++;
    this.socket?.emit('world:intent', intent);
  }

  sendSnapshot(s: WorldSnapshot) {
    this.stats.snapOut++;
    this.socket?.volatile.emit('world:snapshot', s);
  }

  sendEvents(batch: EventBatch) {
    if (!batch.length) return;
    this.stats.evOut++;
    this.socket?.emit('world:events', batch);
  }

  sendChat(text: string) {
    this.socket?.emit('chat:send', text);
  }

  disconnect() {
    this.socket?.removeAllListeners();
    this.socket?.disconnect();
    this.socket = null;
    this.hostId = null;
  }
}
