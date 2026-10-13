/**
 * BWRF10 — "Broadway Resource File" (archivos .RSC del motor KA-MFC).
 *
 *   0   6        "BWRF10"
 *   6   4        u32 n
 *   10  20*n     { char name[12] ASCIIZ, u32 offset, u32 size }
 *   ...          datos (BMP de Windows, escenas .SCN, actores .ATR)
 */
import { FormatError, RandomAccess, SliceSource, asciiz, startsWith, u32 } from './binary.js';

export interface BwrfEntry {
  name: string;
  offset: number;
  size: number;
}

export async function isBwrf(src: RandomAccess): Promise<boolean> {
  if (src.size < 10) return false;
  return startsWith(await src.read(0, 6), 'BWRF10');
}

export async function readBwrf(src: RandomAccess): Promise<BwrfEntry[]> {
  const head = await src.read(0, 10);
  if (!startsWith(head, 'BWRF10')) throw new FormatError('No es un archivo de recursos BWRF10.');
  const n = u32(head, 6);
  if (n > 65535 || 10 + n * 20 > src.size) throw new FormatError(`Directorio BWRF inválido (${n} entradas).`);
  const table = await src.read(10, n * 20);
  const out: BwrfEntry[] = [];
  for (let i = 0; i < n; i++) {
    const name = asciiz(table, i * 20, 12);
    const offset = u32(table, i * 20 + 12);
    const size = u32(table, i * 20 + 16);
    if (offset + size > src.size) throw new FormatError(`Recurso fuera del archivo: ${name}`);
    out.push({ name, offset, size });
  }
  return out;
}

export function openBwrfEntry(src: RandomAccess, e: BwrfEntry): RandomAccess {
  return new SliceSource(src, e.offset, e.size);
}
