export const OUT: string;
export const GATHER_OUT: string;
export function bundleRules(): Promise<string>;
export function bundleGatheringRules(): Promise<string>;
export function bundleRulesFor(key: string): Promise<{ out: string; text: string }>;
