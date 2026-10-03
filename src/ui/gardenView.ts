import { stateOf, type PlotState } from '../gameplay/gardeningRules';

/**
 * A plot's state on the server's clock. The snapshot's own `state` was true when it was fetched; a growing plot becomes ready while
 * the panel stays open, so the panel derives the state from `readyAt` instead of trusting the stale label.
 */
export function plotStateAt(p: { seedId: string | null; readyAt: number; state: PlotState }, now: number): PlotState {
  return p.seedId ? stateOf({ plot: '', seedId: p.seedId, plantedAt: 0, readyAt: p.readyAt, composted: false }, now) : 'empty';
}

/** Bone meal is used only when it is ticked AND still in the bag: the tick outlives the last meal, and the checkbox is hidden at none. */
export const useCompost = (ticked: boolean, meal: number) => ticked && meal > 0;
