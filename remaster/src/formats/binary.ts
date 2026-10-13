/**
 * Utilidades binarias comunes a todos los formatos.
 * Sin dependencias de Node ni del DOM: se usan en el proceso principal y en la interfaz.
 */

/** Fuente de bytes con acceso aleatorio (un archivo, un rango de una ISO, un buffer...). */
export interface RandomAccess {
  readonly size: number;
  read(offset: number, length: number): Promise<Uint8Array>;
}

export class BufferSource implements RandomAccess {
  constructor(private readonly data: Uint8Array) {}
  get size(): number {
    return this.data.length;
  }
  async read(offset: number, length: number): Promise<Uint8Array> {
    if (offset < 0 || offset + length > this.data.length) throw new FormatError(`lectura fuera de rango (${offset}+${length} > ${this.data.length})`);
    return this.data.subarray(offset, offset + length);
  }
}

/** Un subrango de otra fuente (p. ej. un archivo dentro de un contenedor). */
export class SliceSource implements RandomAccess {
  constructor(private readonly parent: RandomAccess, private readonly start: number, readonly size: number) {
    if (start < 0 || start + size > parent.size) throw new FormatError('el rango no entra en el contenedor');
  }
  read(offset: number, length: number): Promise<Uint8Array> {
    if (offset < 0 || offset + length > this.size) return Promise.reject(new FormatError('lectura fuera del rango del archivo'));
    return this.parent.read(this.start + offset, length);
  }
}

export class FormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FormatError';
  }
}

export function u16(b: Uint8Array, o: number): number {
  return b[o] | (b[o + 1] << 8);
}
export function u32(b: Uint8Array, o: number): number {
  return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
}
export function i32(b: Uint8Array, o: number): number {
  return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}
export function i16(b: Uint8Array, o: number): number {
  const v = u16(b, o);
  return v & 0x8000 ? v - 0x10000 : v;
}

/** Tabla Windows-1252 para los bytes 0x80-0x9F (el resto coincide con Latin-1). */
const CP1252_HIGH = [
  0x20ac, 0xfffd, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0xfffd, 0x017d, 0xfffd,
  0xfffd, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0xfffd, 0x017e, 0x0178,
];

/** Decodifica texto ANSI (Windows-1252), la codificación de los juegos. */
export function cp1252(b: Uint8Array, start = 0, end = b.length): string {
  let s = '';
  for (let i = start; i < end; i++) {
    const c = b[i];
    s += String.fromCharCode(c >= 0x80 && c < 0xa0 ? CP1252_HIGH[c - 0x80] : c);
  }
  return s;
}

/** Cadena ASCIIZ (terminada en 0) dentro de un campo de longitud fija. */
export function asciiz(b: Uint8Array, o: number, max: number): string {
  let end = o;
  while (end < o + max && end < b.length && b[end] !== 0) end++;
  return cp1252(b, o, end);
}

export function ucs2be(b: Uint8Array, o: number, len: number): string {
  let s = '';
  for (let i = 0; i + 1 < len; i += 2) s += String.fromCharCode((b[o + i] << 8) | b[o + i + 1]);
  return s;
}

export function startsWith(b: Uint8Array, magic: string, offset = 0): boolean {
  if (b.length < offset + magic.length) return false;
  for (let i = 0; i < magic.length; i++) if (b[offset + i] !== magic.charCodeAt(i)) return false;
  return true;
}
