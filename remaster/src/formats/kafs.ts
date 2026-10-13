/**
 * KAFS: sistema de archivos de Knowledge Adventure.
 * Lo usan los archivos de sonido del motor KA-MFC (SOUND.BAL, SOUND2.BAL) y el
 * paquete completo del motor ACES (archivos TODDLER y PRSCHOOL del CD).
 *
 * Directorio (la raíz está en el offset 0):
 *   u32 n
 *   n × { u32 nameOffset, i32 dataOffset (absoluto), u32 size, u32 flags, u32 reservado }
 *        flags & 0x8000 → subdirectorio (dataOffset apunta a otro directorio)
 *        siempre hay entradas "." y ".."
 *   u32 namesLength
 *   char names[namesLength]   (ASCIIZ concatenados)
 */
import { FormatError, RandomAccess, SliceSource, cp1252, i32, u32 } from './binary.js';

export interface KafsEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  offset: number;
  size: number;
}

const MAX_ENTRIES = 100000;

export async function readKafsDir(src: RandomAccess, offset = 0, parentPath = ''): Promise<KafsEntry[]> {
  if (offset + 4 > src.size) throw new FormatError('directorio KAFS fuera del archivo');
  const n = u32(await src.read(offset, 4), 0);
  if (n === 0 || n > MAX_ENTRIES) throw new FormatError(`directorio KAFS inválido (${n} entradas)`);
  const table = await src.read(offset + 4, n * 20 + 4);
  const namesLen = u32(table, n * 20);
  if (namesLen > 1 << 20) throw new FormatError('tabla de nombres KAFS inválida');
  const names = await src.read(offset + 8 + n * 20, namesLen);
  const out: KafsEntry[] = [];
  for (let i = 0; i < n; i++) {
    const nameOff = u32(table, i * 20);
    const dataOff = i32(table, i * 20 + 4);
    const size = u32(table, i * 20 + 8);
    const flags = u32(table, i * 20 + 12);
    let end = nameOff;
    while (end < names.length && names[end] !== 0) end++;
    const name = cp1252(names, nameOff, end);
    if (name === '.' || name === '..') continue;
    const isDirectory = (flags & 0x8000) !== 0;
    if (dataOff < 0 || dataOff + (isDirectory ? 4 : size) > src.size) throw new FormatError(`entrada KAFS fuera del archivo: ${name}`);
    out.push({ name, path: parentPath ? `${parentPath}/${name}` : name, isDirectory, offset: dataOff, size });
  }
  return out;
}

/** ¿Parece un contenedor KAFS? (raíz con "." y ".." válidos) */
export async function isKafs(src: RandomAccess): Promise<boolean> {
  try {
    if (src.size < 64) return false;
    const head = await src.read(0, 4);
    const n = u32(head, 0);
    if (n < 2 || n > MAX_ENTRIES) return false;
    const entries = await readKafsDir(src, 0);
    return entries.length > 0;
  } catch {
    return false;
  }
}

export function openKafsFile(src: RandomAccess, e: KafsEntry): RandomAccess {
  if (e.isDirectory) throw new FormatError(`${e.path} es una carpeta`);
  return new SliceSource(src, e.offset, e.size);
}

export async function walkKafs(src: RandomAccess): Promise<KafsEntry[]> {
  const out: KafsEntry[] = [];
  const stack: { offset: number; path: string }[] = [{ offset: 0, path: '' }];
  while (stack.length) {
    const d = stack.pop()!;
    for (const e of await readKafsDir(src, d.offset, d.path)) {
      out.push(e);
      if (e.isDirectory) stack.push({ offset: e.offset, path: e.path });
    }
  }
  return out;
}
