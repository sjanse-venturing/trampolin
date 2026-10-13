/**
 * Paletas de texto del motor ACES (.PAL):
 *   PAL
 *   <cantidad>
 *   R G B
 *   ...
 */
import { FormatError, cp1252 } from './binary.js';

export function decodeAcesPalette(data: Uint8Array): Uint8Array {
  const lines = cp1252(data).split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines[0] !== 'PAL') throw new FormatError('No es una paleta ACES.');
  const count = Math.min(256, parseInt(lines[1], 10) || 0);
  const pal = new Uint8Array(768);
  for (let i = 0; i < count && i + 2 < lines.length; i++) {
    const [r, g, b] = lines[i + 2].split(/\s+/).map((v) => Math.max(0, Math.min(255, parseInt(v, 10) || 0)));
    pal[i * 3] = r;
    pal[i * 3 + 1] = g;
    pal[i * 3 + 2] = b;
  }
  return pal;
}
