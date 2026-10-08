// Reads a JSON array of {slots, bagSize} cases on stdin and prints, per case, the first problem the LIVE server would refuse the save for
// ("" = accepted). Uses the real server/death-muffin/backend/inventory-save.cjs plus the shape rule from server.js POST /api/inventory/save.
const path = require('path');
const inventorySave = require(path.join(__dirname, '../../server/death-muffin/backend/inventory-save.cjs'));
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const out = input.map((c) => {
  if (!Array.isArray(c.slots)) return 'slots must be an array';
  const slots = c.slots.filter((s) => !(Number(s && s.slot_index) >= 100 && Number(s.slot_index) <= 134));
  const bagSize = inventorySave.saveBagSize(c.bagSize);
  if (bagSize === null) return 'bagSize invalid';
  const slotError = inventorySave.slotProblem(slots, bagSize);
  if (slotError) return slotError;
  if (slots.some((s) => typeof s.item_id !== 'string' || !s.item_id.trim() || !Number.isInteger(Number(s.quantity)) || Number(s.quantity) < 1))
    return 'each slot requires an item_id and positive integer quantity';
  return '';
});
process.stdout.write(JSON.stringify(out));
