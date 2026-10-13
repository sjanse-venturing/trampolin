/**
 * Mapas de bits de Windows (BMP). Los recursos de los juegos son de 8 bits
 * con paleta, a menudo comprimidos con RLE8. Se decodifican a una imagen
 * indexada (índices + paleta), que es lo que necesita el motor para
 * reproducir fundidos y animaciones de paleta igual que el original.
 */
import { FormatError, i32, startsWith, u16, u32 } from './binary.js';

export interface IndexedImage {
  width: number;
  height: number;
  /** Índices de color, fila 0 arriba. */
  pixels: Uint8Array;
  /** 256 entradas RGB (768 bytes). */
  palette: Uint8Array;
}

const BI_RGB = 0;
const BI_RLE8 = 1;

export function decodeBmp(data: Uint8Array): IndexedImage {
  if (!startsWith(data, 'BM')) throw new FormatError('No es un BMP.');
  const pixelOffset = u32(data, 10);
  const hdrSize = u32(data, 14);
  if (hdrSize < 40) throw new FormatError('Cabecera BMP no soportada (OS/2).');
  const width = i32(data, 18);
  const rawHeight = i32(data, 22);
  const bpp = u16(data, 28);
  const compression = u32(data, 30);
  let colors = u32(data, 46);
  if (width <= 0 || width > 8192 || rawHeight === 0 || Math.abs(rawHeight) > 8192) throw new FormatError('Dimensiones BMP inválidas.');
  if (bpp !== 8 && bpp !== 4) throw new FormatError(`BMP de ${bpp} bits no soportado.`);
  if (colors === 0) colors = 1 << bpp;
  const height = Math.abs(rawHeight);
  const topDown = rawHeight < 0;

  const palette = new Uint8Array(768);
  const palStart = 14 + hdrSize;
  for (let i = 0; i < Math.min(colors, 256); i++) {
    palette[i * 3] = data[palStart + i * 4 + 2];
    palette[i * 3 + 1] = data[palStart + i * 4 + 1];
    palette[i * 3 + 2] = data[palStart + i * 4];
  }

  const pixels = new Uint8Array(width * height);
  const rowIndex = (y: number) => (topDown ? y : height - 1 - y);

  if (compression === BI_RGB) {
    const stride = (((width * bpp + 31) >> 5) << 2);
    for (let y = 0; y < height; y++) {
      const src = pixelOffset + y * stride;
      const dst = rowIndex(y) * width;
      if (bpp === 8) pixels.set(data.subarray(src, src + width), dst);
      else for (let x = 0; x < width; x++) pixels[dst + x] = (data[src + (x >> 1)] >> (x & 1 ? 0 : 4)) & 15;
    }
  } else if (compression === BI_RLE8 && bpp === 8) {
    decodeRle8(data, pixelOffset, width, height, (x, y, v) => {
      if (x < width && y < height) pixels[rowIndex(y) * width + x] = v;
    });
  } else {
    throw new FormatError(`Compresión BMP ${compression} no soportada.`);
  }
  return { width, height, pixels, palette };
}

/** RLE8 de Windows: pares (n, color) o escapes 0 (fin de línea), 1 (fin), 2 (delta), n≥3 (absoluto). */
function decodeRle8(data: Uint8Array, start: number, width: number, height: number, put: (x: number, y: number, v: number) => void): void {
  let p = start;
  let x = 0;
  let y = 0; // línea en orden del archivo (0 = primera almacenada)
  while (p + 1 < data.length && y < height) {
    const count = data[p++];
    const value = data[p++];
    if (count > 0) {
      for (let i = 0; i < count; i++) put(x++, y, value);
    } else if (value === 0) {
      x = 0;
      y++;
    } else if (value === 1) {
      return;
    } else if (value === 2) {
      x += data[p++];
      y += data[p++];
    } else {
      for (let i = 0; i < value; i++) put(x++, y, data[p++]);
      if (value & 1) p++; // alineación a 16 bits
    }
  }
}

/** Convierte una imagen indexada a RGBA. `transparent` (opcional) deja ese índice transparente. */
export function indexedToRgba(img: IndexedImage, palette = img.palette, transparent = -1): Uint8ClampedArray<ArrayBuffer> {
  const out = new Uint8ClampedArray(img.width * img.height * 4);
  for (let i = 0; i < img.pixels.length; i++) {
    const c = img.pixels[i];
    out[i * 4] = palette[c * 3];
    out[i * 4 + 1] = palette[c * 3 + 1];
    out[i * 4 + 2] = palette[c * 3 + 2];
    out[i * 4 + 3] = c === transparent ? 0 : 255;
  }
  return out;
}
