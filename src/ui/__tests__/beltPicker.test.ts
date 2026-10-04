import { describe, expect, it } from 'vitest';
import { emptyPickerText, pickerTitle } from '../BeltPicker';
import { emptyHint } from '../../gameplay/beltRules';

describe('belt picker wording', () => {
  it('names the slot and its key', () => {
    expect(pickerTitle('Elixir', 'Z')).toBe('Elixir slot · key Z');
  });
  it('says where to brew when the bag has none, with the right article', () => {
    expect(emptyPickerText('Elixir')).toMatch(/No elixirs.*brew an elixir/i);
    expect(emptyPickerText('Tonic')).toMatch(/brew a tonic/i);
  });
  it('empty belt hints tell the player the slot is clickable', () => {
    expect(emptyHint('elixir')).toMatch(/click/i);
    expect(emptyHint('tonic')).toMatch(/click/i);
  });
});
