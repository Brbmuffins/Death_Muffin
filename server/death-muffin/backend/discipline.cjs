/** Change the active discipline without moving or replacing a character save. */
module.exports = function mountDiscipline(app, pool, { verifyJWT, formatCharacter, getGearLoadout, invalidateLeaderboard }) {
  app.post('/character/discipline', verifyJWT, async (req, res) => {
    const { class_index: index, characterId } = req.body || {};
    if (!Number.isInteger(index) || index < 1 || index > 4)
      return res.status(400).json({ error: 'Choose one of the four classes.' });
    if (!req.character) return res.status(404).json({ error: 'No character found.' });
    if (characterId !== req.character.id)
      return res.status(403).json({ error: 'That character is not your active character.' });
    try {
      const [result] = await pool.execute(
        'UPDATE characters SET discipline_index = ? WHERE id = ? AND account_id = ?',
        [index, characterId, req.user.accountId],
      );
      if (!result.affectedRows) return res.status(404).json({ error: 'No character found.' });
      const [[character]] = await pool.execute(
        'SELECT * FROM characters WHERE id = ? AND account_id = ?', [characterId, req.user.accountId],
      );
      const gear = await getGearLoadout(characterId);
      invalidateLeaderboard();
      res.json(formatCharacter(character, gear, req.gmFields));
    } catch (err) {
      console.error('Class change failed:', err.code || err.message);
      res.status(503).json({ error: 'Could not change class. Please try again.' });
    }
  });
};
