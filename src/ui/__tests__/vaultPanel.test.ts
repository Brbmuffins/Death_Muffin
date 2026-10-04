import { describe, expect, it, vi } from 'vitest';

const api = vi.hoisted(() => ({ getVault: vi.fn(), vaultDeposit: vi.fn(), vaultDepositAll: vi.fn(), vaultSort: vi.fn(), vaultWithdraw: vi.fn() }));
vi.mock('../../net/api', () => api);

import { VaultPanel } from '../VaultPanel';

describe('VaultPanel before the vault has loaded', () => {
  it('ignores moves while "Opening the Vault…" is showing (they would overlap the load)', async () => {
    const exclusive = vi.fn(async (fn: () => Promise<unknown>) => fn());
    const inventory = { all: [], exclusive, replace: vi.fn(), onChange: () => () => {} };
    const panel = new VaultPanel({} as HTMLElement, 1, inventory as never, { slotsOf: () => [], isLocked: () => false, onChange: () => () => {} } as never);
    await (panel as unknown as { depositAll(k: 'all'): Promise<void> }).depositAll('all');
    expect(api.vaultDepositAll).not.toHaveBeenCalled();
    expect(exclusive).not.toHaveBeenCalled();
  });
});

describe('VaultPanel take buttons', () => {
  const row = (slot_index: number, item_type: string) => ({ slot_index, item_type, item_id: `i${slot_index}`, name: 'x', quantity: 1 });
  const make = () => {
    const exclusive = vi.fn(async (fn: () => Promise<unknown>) => fn());
    const inventory = { all: [], exclusive, replace: vi.fn(), onChange: () => () => {} };
    const panel = new VaultPanel({} as HTMLElement, 7, inventory as never, { slotsOf: () => [], isLocked: () => false, onChange: () => () => {} } as never);
    return panel as unknown as { state: unknown; withdrawAll(k: 'materials' | 'all'): Promise<void> };
  };

  it('Take materials withdraws only material-like stacks, from every tab', async () => {
    api.vaultWithdraw.mockReset();
    api.vaultWithdraw.mockResolvedValue({ bag: [], vault: [] });
    const p = make();
    p.state = { bag: [], vault: [row(3, 'material'), row(5, 'weapon'), row(45, 'consumable'), row(90, 'rune')] };
    await p.withdrawAll('materials');
    expect(api.vaultWithdraw.mock.calls.map((c) => c[1])).toEqual([3, 45, 90]);
  });

  it('Take all stops at the first stack that does not fit and keeps what moved', async () => {
    api.vaultWithdraw.mockReset();
    api.vaultWithdraw.mockResolvedValueOnce({ bag: [], vault: [] }).mockRejectedValueOnce(new Error('Your Reliquary has no room for that. Make space first.'));
    const p = make();
    p.state = { bag: [], vault: [row(1, 'weapon'), row(2, 'weapon'), row(3, 'weapon')] };
    await p.withdrawAll('all');
    expect(api.vaultWithdraw).toHaveBeenCalledTimes(2);
  });
});
