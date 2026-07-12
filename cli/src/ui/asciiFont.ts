/**
 * Tiny 5x5 block font used to render the static "Bit" style logo without a
 * runtime dependency on a big-text library. Only the glyphs the wordmark
 * needs (A, C, D, K, O, S, T, U) are defined; unknown characters render as
 * a blank 5x5 cell so the layout still lines up.
 */
const GLYPH_HEIGHT = 5;
const GLYPH_WIDTH = 5;
const BLANK_GLYPH = Array<string>(GLYPH_HEIGHT).fill('.'.repeat(GLYPH_WIDTH));

const FONT: Record<string, string[]> = {
  A: ['.###.', '#...#', '#####', '#...#', '#...#'],
  C: ['.###.', '#....', '#....', '#....', '.###.'],
  D: ['####.', '#...#', '#...#', '#...#', '####.'],
  K: ['#...#', '#..#.', '###..', '#..#.', '#...#'],
  O: ['.###.', '#...#', '#...#', '#...#', '.###.'],
  S: ['.####', '#....', '.###.', '....#', '####.'],
  T: ['#####', '..#..', '..#..', '..#..', '..#..'],
  U: ['#...#', '#...#', '#...#', '#...#', '.###.'],
};

/** Renders `text` as a block-letter ASCII banner, one string per row. */
export function renderBlockText(text: string, fillChar = '█'): string[] {
  const glyphs = text
    .toUpperCase()
    .split('')
    .map((char) => FONT[char] ?? BLANK_GLYPH);

  const rows: string[] = [];
  for (let row = 0; row < GLYPH_HEIGHT; row++) {
    rows.push(glyphs.map((glyph) => glyph[row]!.replaceAll('#', fillChar).replaceAll('.', ' ')).join(' '));
  }
  return rows;
}
