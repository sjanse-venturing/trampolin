/**
 * "KA Sound File" (.SND) de Knowledge Adventure.
 *
 * Cabecera de 54 bytes (deducida del análisis de 7.300 archivos de las ISOs):
 *   0x00  "KA Sound File" 0x1A
 *   0x0E  u8  versión (1 o 2)
 *   0x0F  u8  codificación: 1 = PCM sin comprimir, 2 = comprimido (códec propio, pendiente de RE)
 *   0x10  u8  canales (1)
 *   0x11  u8  código de frecuencia (6 en todos los archivos analizados)
 *   0x13  u8  bits por muestra (8 = sin signo, 16 = con signo little-endian)
 *   0x18  parámetros del compresor (solo codificación 2)
 *   0x20  u32 cantidad de muestras
 *   0x36  datos
 */
import { FormatError, startsWith, u32 } from './binary.js';

export const KASND_HEADER = 0x36;

export interface KaSoundInfo {
  version: number;
  encoding: 'pcm' | 'compressed';
  channels: number;
  rateCode: number;
  /** Frecuencia supuesta (validar de oído; ver REMASTER.md §4, F5). */
  sampleRate: number;
  bits: number;
  samples: number;
}

/** Frecuencias por código: hipótesis de trabajo (el código 6 aparece en todos los archivos). */
const RATE_BY_CODE: Record<number, number> = { 4: 8000, 5: 11025, 6: 22050, 7: 44100 };

export function readKaSoundInfo(data: Uint8Array): KaSoundInfo {
  if (!startsWith(data, 'KA Sound File\x1a')) throw new FormatError('No es un "KA Sound File".');
  const encodingByte = data[0x0f];
  return {
    version: data[0x0e],
    encoding: encodingByte === 2 ? 'compressed' : 'pcm',
    channels: Math.max(1, data[0x10]),
    rateCode: data[0x11],
    sampleRate: RATE_BY_CODE[data[0x11]] ?? 22050,
    bits: data[0x13] === 16 ? 16 : 8,
    samples: u32(data, 0x20),
  };
}

/** Decodifica a muestras flotantes [-1, 1]. Lanza FormatError para el códec comprimido (aún no reimplementado). */
export function decodeKaSound(data: Uint8Array): { info: KaSoundInfo; pcm: Float32Array } {
  const info = readKaSoundInfo(data);
  if (info.encoding === 'compressed') {
    throw new FormatError('Este sonido usa el códec comprimido de Knowledge Adventure, que todavía no está reimplementado.');
  }
  const bytesPerSample = info.bits / 8;
  const available = Math.floor((data.length - KASND_HEADER) / bytesPerSample);
  const n = Math.min(info.samples * info.channels, available);
  const pcm = new Float32Array(n);
  if (info.bits === 8) {
    for (let i = 0; i < n; i++) pcm[i] = (data[KASND_HEADER + i] - 128) / 128;
  } else {
    const view = new DataView(data.buffer, data.byteOffset + KASND_HEADER, n * 2);
    for (let i = 0; i < n; i++) pcm[i] = view.getInt16(i * 2, true) / 32768;
  }
  return { info, pcm };
}
