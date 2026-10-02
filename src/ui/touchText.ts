/** Phones and tablets, decided at the moment a card is shown (a player may switch devices). */
export function touchNow(): boolean {
  try {
    return document.body.classList.contains('touch') || window.matchMedia('(pointer: coarse)').matches;
  } catch {
    return false;
  }
}
