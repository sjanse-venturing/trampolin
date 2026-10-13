import { describe, expect, it } from 'vitest';
import { BufferSource, cp1252, u32 } from '../src/formats/binary.js';
import { decodeBmp, indexedToRgba } from '../src/formats/bmp.js';
import { readBwrf } from '../src/formats/bwrf.js';
import { readKafsDir, walkKafs } from '../src/formats/kafs.js';
import { decodeKaSound, readKaSoundInfo } from '../src/formats/kasnd.js';
import { decodeAcesPalette } from '../src/formats/acespal.js';
import { parseMidi } from '../src/formats/midi.js';
import { encodeWav } from '../src/formats/wav.js';
import { toErrorInfo, TrError } from '../src/shared/errors.js';

const le32 = (v: number) => [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >>> 24) & 255];
const ascii = (s: string) => Array.from(s, (c) => c.charCodeAt(0));

/** BMP 8 bits de 4x2 con RLE8. */
function makeRleBmp(): Uint8Array {
  const pal: number[] = [];
  for (let i = 0; i < 256; i++) pal.push(i, i, i, 0); // B, G, R, 0 (gris)
  // Fila inferior (y=1): 4 píxeles de color 7. Fila superior (y=0): absoluto 1,2,3 + 1 píxel 9.
  const rle = [4, 7, 0, 0, 0, 3, 1, 2, 3, 0, 1, 9, 0, 1];
  const pixelOffset = 14 + 40 + 1024;
  const header = [
    ...ascii('BM'), ...le32(pixelOffset + rle.length), 0, 0, 0, 0, ...le32(pixelOffset),
    ...le32(40), ...le32(4), ...le32(2), 1, 0, 8, 0, ...le32(1), ...le32(rle.length), ...le32(0), ...le32(0), ...le32(256), ...le32(0),
  ];
  return new Uint8Array([...header, ...pal, ...rle]);
}

describe('binary', () => {
  it('decodifica cp1252 con acentos', () => {
    expect(cp1252(new Uint8Array([0x54, 0x72, 0x61, 0x6d, 0x70, 0x6f, 0x6c, 0xed, 0x6e]))).toBe('Trampolín');
    expect(cp1252(new Uint8Array([0x80]))).toBe('€');
  });
});

describe('BMP', () => {
  it('decodifica RLE8 bottom-up con modo absoluto y alineación', () => {
    const img = decodeBmp(makeRleBmp());
    expect(img.width).toBe(4);
    expect(img.height).toBe(2);
    expect(Array.from(img.pixels)).toEqual([1, 2, 3, 9, 7, 7, 7, 7]);
    expect(img.palette[9 * 3]).toBe(9);
    const rgba = indexedToRgba(img, img.palette, 7);
    expect(rgba[4 * 4 + 3]).toBe(0); // índice 7 transparente
  });
  it('rechaza datos que no son BMP', () => {
    expect(() => decodeBmp(new Uint8Array([1, 2, 3]))).toThrow();
  });
});

describe('BWRF10', () => {
  it('lee el directorio de recursos', async () => {
    const name = (s: string) => { const a = ascii(s); while (a.length < 12) a.push(0); return a; };
    const dataA = ascii('HOLA');
    const dataB = ascii('MUNDO!');
    const off = 10 + 2 * 20;
    const bytes = new Uint8Array([
      ...ascii('BWRF10'), ...le32(2),
      ...name('A.BMP'), ...le32(off), ...le32(dataA.length),
      ...name('B.SCN'), ...le32(off + dataA.length), ...le32(dataB.length),
      ...dataA, ...dataB,
    ]);
    const e = await readBwrf(new BufferSource(bytes));
    expect(e.map((x) => x.name)).toEqual(['A.BMP', 'B.SCN']);
    expect(e[1]).toMatchObject({ offset: off + 4, size: 6 });
  });
});

describe('KAFS', () => {
  /** Construye: raíz {., .., SUB/, X.SND}, SUB {., .., Y.SND} */
  function makeKafs(): Uint8Array {
    const names = ascii('.\0..\0SUB\0X.SND\0');
    const rootSize = 4 + 4 * 20 + 4 + names.length;
    const subNames = ascii('.\0..\0Y.SND\0');
    const subOff = 256;
    const subSize = 4 + 3 * 20 + 4 + subNames.length;
    const xOff = 512, yOff = 520;
    const buf = new Uint8Array(600);
    const put = (o: number, arr: number[]) => buf.set(arr, o);
    put(0, [...le32(4),
      ...le32(0), ...le32(0), ...le32(rootSize), ...le32(0x8000), ...le32(0),
      ...le32(2), ...le32(0xffffffff), ...le32(0), ...le32(0x8000), ...le32(0),
      ...le32(5), ...le32(subOff), ...le32(subSize), ...le32(0x8000), ...le32(0),
      ...le32(9), ...le32(xOff), ...le32(8), ...le32(0), ...le32(0),
      ...le32(names.length), ...names]);
    put(subOff, [...le32(3),
      ...le32(0), ...le32(subOff), ...le32(subSize), ...le32(0x8000), ...le32(0),
      ...le32(2), ...le32(0), ...le32(rootSize), ...le32(0x8000), ...le32(0),
      ...le32(5), ...le32(yOff), ...le32(4), ...le32(0), ...le32(0),
      ...le32(subNames.length), ...subNames]);
    return buf;
  }
  it('lista la raíz ignorando . y ..', async () => {
    const e = await readKafsDir(new BufferSource(makeKafs()));
    expect(e.map((x) => `${x.name}:${x.isDirectory}`)).toEqual(['SUB:true', 'X.SND:false']);
  });
  it('recorre subcarpetas', async () => {
    const all = await walkKafs(new BufferSource(makeKafs()));
    expect(all.map((x) => x.path).sort()).toEqual(['SUB', 'SUB/Y.SND', 'X.SND']);
  });
});

describe('KA Sound File', () => {
  const header = (encoding: number, bits: number, samples: number) => {
    const h = new Uint8Array(0x36);
    h.set(ascii('KA Sound File\x1a'), 0);
    h[0x0e] = 2; h[0x0f] = encoding; h[0x10] = 1; h[0x11] = 6; h[0x12] = 8; h[0x13] = bits;
    h.set(le32(samples), 0x20);
    return h;
  };
  it('decodifica PCM de 8 bits sin signo', () => {
    const d = new Uint8Array([...header(1, 8, 3), 0x80, 0xff, 0x00]);
    const { info, pcm } = decodeKaSound(d);
    expect(info).toMatchObject({ encoding: 'pcm', bits: 8, samples: 3, sampleRate: 22050 });
    expect(Array.from(pcm)).toEqual([0, 127 / 128, -1]);
  });
  it('decodifica PCM de 16 bits con signo', () => {
    const d = new Uint8Array([...header(1, 16, 2), 0x00, 0x40, 0x00, 0xc0]);
    expect(Array.from(decodeKaSound(d).pcm)).toEqual([0.5, -0.5]);
  });
  it('identifica el códec comprimido y avisa', () => {
    const d = new Uint8Array([...header(2, 16, 10), 1, 2, 3]);
    expect(readKaSoundInfo(d).encoding).toBe('compressed');
    expect(() => decodeKaSound(d)).toThrow(/códec comprimido/);
  });
});

describe('Paleta ACES', () => {
  it('lee la paleta de texto', () => {
    const pal = decodeAcesPalette(new Uint8Array(ascii('PAL\r\n2\r\n10 20 30\r\n255 0 128\r\n')));
    expect(Array.from(pal.subarray(0, 6))).toEqual([10, 20, 30, 255, 0, 128]);
  });
});

describe('MIDI', () => {
  it('convierte ticks a segundos con cambios de tempo', () => {
    const track = [
      0x00, 0xff, 0x51, 0x03, 0x07, 0xa1, 0x20, // tempo 500000 (120 bpm)
      0x00, 0x90, 60, 100,
      0x60, 0x80, 60, 0, // 96 ticks después (= 1 negra = 0,5 s)
      0x00, 0xff, 0x2f, 0x00,
    ];
    const smf = new Uint8Array([...ascii('MThd'), 0, 0, 0, 6, 0, 0, 0, 1, 0, 96, ...ascii('MTrk'), 0, 0, 0, track.length, ...track]);
    const song = parseMidi(smf);
    expect(song.events).toHaveLength(2);
    expect(song.events[1].time).toBeCloseTo(0.5);
    expect(song.duration).toBeCloseTo(0.5);
  });
});

describe('WAV', () => {
  it('escribe una cabecera RIFF válida', () => {
    const w = encodeWav(new Float32Array([0, 1, -1]), 22050);
    expect(cp1252(w, 0, 4)).toBe('RIFF');
    expect(u32(w, 24)).toBe(22050);
    expect(w.length).toBe(44 + 6);
  });
});

describe('Errores', () => {
  it('traduce códigos a mensajes amigables con variables', () => {
    const i = toErrorInfo(new TrError('E_ISO_MOVED', { game: 'FG', path: 'C:\\x.iso' }));
    expect(i.message).toContain('FG');
    expect(i.message).toContain('C:\\x.iso');
    expect(i.actions).toContain('locateIso');
  });
  it('los errores desconocidos son E_UNEXPECTED', () => {
    expect(toErrorInfo(new Error('boom')).code).toBe('E_UNEXPECTED');
  });
});
