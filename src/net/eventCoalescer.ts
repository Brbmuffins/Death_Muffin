import type { EventBatch } from './contracts';

/**
 * Keeps the host's event batches under the relay's per-socket budget (60/s; it silently drops what exceeds it, and
 * `death`, `exhumed` and `hurt` are reliable events). A batch goes out the frame it happens unless one went out less than
 * 1000 / perSec ms ago; then it waits for the next frame past that gap and travels with whatever else queued, oldest
 * first and in order. So a calm fight adds no latency, and a sustained one (a full legion, or a 144 Hz host) sends an even
 * `perSec` batches a second with every event at most one gap late. Chunked so a batch never exceeds the relay's 400-event cap.
 */
export class EventCoalescer {
  private held: EventBatch = [];
  private lastSend = -Infinity;
  private readonly gapMs: number;

  constructor(
    private readonly send: (batch: EventBatch) => void,
    perSec = 40,
    private readonly maxBatch = 200,
  ) {
    this.gapMs = 1000 / perSec;
  }

  /** Call once per frame (with an empty list when nothing happened) so held events get their turn. */
  push(events: EventBatch, nowMs: number) {
    if (events.length) this.held.push(...events);
    if (!this.held.length || nowMs - this.lastSend < this.gapMs) return;
    this.lastSend = nowMs;
    this.send(this.held.splice(0, this.maxBatch));
  }

  /** Drop what is waiting (the link went away; a reconnect resyncs from a snapshot). */
  clear() {
    this.held = [];
    this.lastSend = -Infinity;
  }

  get waiting() {
    return this.held.length;
  }
}
