/** Compare two normalized character XP positions without changing other stats. */
function mergeOfflineStats(online, offline) {
  const level = offline?.level;
  const experience = offline?.experience;
  if (!Number.isInteger(level) || level < 1 || level > 255 ||
      // Offline Progression.addXp uses level * 100 as its per-level XP range.
      !Number.isInteger(experience) || experience < 0 || experience >= level * 100) {
    throw new RangeError('Invalid offline level or XP');
  }
  const onlineLevel = Number(online.level);
  const onlineExperience = Number(online.experience);
  const improved = level > onlineLevel || (level === onlineLevel && experience > onlineExperience);
  return { level: improved ? level : onlineLevel, experience: improved ? experience : onlineExperience, improved };
}

module.exports = { mergeOfflineStats };
