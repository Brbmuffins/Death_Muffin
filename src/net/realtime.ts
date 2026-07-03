import { io, Socket } from 'socket.io-client';
import { WS_BASE, WS_PATH } from './config';
import { getToken } from './api';

export interface RemotePlayer {
  id: string;
  characterId: number;
  name: string;
  classIndex: number;
  x: number;
  y: number;
  z: number;
  orientation: number;
}

export interface ChatMessage {
  id: string;
  name: string;
  text: string;
}

export interface RealtimeHandlers {
  onPlayerJoin(player: RemotePlayer): void;
  onPlayerLeave(id: string): void;
  onPlayerMove(update: { id: string; x: number; y: number; z: number; orientation: number }): void;
  onChat(message: ChatMessage): void;
  onDisconnect(): void;
  /** Arena relay from another client (enemy state from host, hit requests to host). */
  onArenaEvent?(event: any): void;
  onHostChange?(hostId: string): void;
}

export interface JoinInfo {
  room: string;
  characterId: number;
  classIndex: number;
  x: number;
  y: number;
  z: number;
  orientation: number;
}

/**
 * Socket.io client for the Phase 3 realtime layer. Connect on hub mount,
 * disconnect on unmount. Join failures (e.g. "Party full") reject with the
 * server's player-readable error string.
 */
export class RealtimeClient {
  private socket: Socket | null = null;
  private hostId: string | null = null;

  get connected() {
    return this.socket?.connected ?? false;
  }

  get selfId() {
    return this.socket?.id ?? null;
  }

  get isHost() {
    return this.connected && this.hostId === this.socket!.id;
  }

  connect(info: JoinInfo, handlers: RealtimeHandlers): Promise<RemotePlayer[]> {
    if (!WS_BASE) return Promise.reject(new Error('Realtime service not configured'));
    const token = getToken();
    if (!token) return Promise.reject(new Error('Not authenticated'));

    return new Promise((resolve, reject) => {
      const socket = io(WS_BASE, {
        auth: { token },
        reconnectionAttempts: 3,
        timeout: 8000,
        // Omit path locally (library default); production sets it for Nginx routing.
        ...(WS_PATH ? { path: WS_PATH } : {}),
      });
      this.socket = socket;

      socket.on('connect_error', (err) => {
        reject(new Error(err.message === 'xhr poll error' ? 'Realtime service unreachable' : err.message));
        socket.disconnect();
      });

      socket.on('connect', () => {
        socket.emit('room:join', info, (res: any) => {
          if (!res?.success) {
            reject(new Error(res?.error ?? 'Could not join room'));
            socket.disconnect();
            return;
          }
          socket.on('player:join', handlers.onPlayerJoin);
          socket.on('player:leave', ({ id }: { id: string }) => handlers.onPlayerLeave(id));
          socket.on('player:move', handlers.onPlayerMove);
          socket.on('chat:message', handlers.onChat);
          socket.on('disconnect', () => handlers.onDisconnect());
          socket.on('arena:event', (ev: any) => handlers.onArenaEvent?.(ev));
          socket.on('room:host', ({ hostId }: { hostId: string }) => {
            this.hostId = hostId;
            handlers.onHostChange?.(hostId);
          });
          this.hostId = res.data.hostId ?? socket.id;
          const others = (res.data.players as RemotePlayer[]).filter((p) => p.id !== socket.id);
          resolve(others);
        });
      });
    });
  }

  sendMove(pos: { x: number; y: number; z: number; orientation: number }) {
    this.socket?.volatile.emit('player:move', pos);
  }

  sendChat(text: string) {
    this.socket?.emit('chat:send', text);
  }

  sendArenaEvent(payload: Record<string, unknown>) {
    this.socket?.volatile.emit('arena:event', payload);
  }

  disconnect() {
    this.socket?.disconnect();
    this.socket = null;
    this.hostId = null;
  }
}
