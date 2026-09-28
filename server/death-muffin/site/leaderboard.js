const leaderboardStatus = document.querySelector('#leaderboard-status');
const rows = document.querySelector('#leaderboard-rows');
// Indexed by COALESCE(discipline_index, class_index) from /leaderboard.
// The source flag disambiguates legacy class_index 5 from Grave Warden's discipline_index 5.
const disciplines = ['Engineer', 'Ossuary', 'Gravecaller', 'Mourner', 'Rotweaver', 'Grave Warden', 'Bell Monk', 'Carrion Witch', 'Hollow Knight', 'Veilwalker'];
const legacy = ['Engineer', 'Guardian', 'Shadowblade', 'Cleric', 'Arcanist', 'Necromancer'];
async function refreshLeaderboard() {
  try {
    const response = await fetch('api/leaderboard');
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'Could not load the leaderboard.');
    const fragment = document.createDocumentFragment();
    for (const player of data.players) {
      const row = document.createElement('tr');
      const className = player.hasDiscipline ? disciplines[player.classIndex] : legacy[player.classIndex];
      for (const value of [player.rank, player.username, className || 'Necromancer', player.level, player.ascension, player.bossKills, player.totalKills]) {
        const cell = document.createElement('td');
        cell.textContent = typeof value === 'number' ? value.toLocaleString() : value;
        row.appendChild(cell);
      }
      fragment.appendChild(row);
    }
    rows.replaceChildren(fragment);
    leaderboardStatus.textContent = data.players.length ? `Last updated ${new Date(data.updatedAt).toLocaleTimeString()}. Refreshes every minute.` : 'The covenant awaits its first character. Enter the world to claim your place.';
  } catch (error) {
    leaderboardStatus.textContent = error instanceof Error ? error.message : 'Could not load the leaderboard.';
  }
}
void refreshLeaderboard();
setInterval(() => { if (!document.hidden) void refreshLeaderboard(); }, 60000);
