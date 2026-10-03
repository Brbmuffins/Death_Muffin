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
