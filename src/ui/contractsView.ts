/** The daily board is stale once the server's reset time has passed: delivering then fills the NEW day's slot while the panel shows yesterday's order. */
export const boardExpired = (resetsAt: string, now: number): boolean => {
  const t = Date.parse(resetsAt);
  return Number.isFinite(t) && now >= t;
};
