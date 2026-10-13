/**
 * Lector de archivos MIDI estándar (SMF tipo 0 y 1).
 * Las músicas .MID (KA-MFC) y .WGM (ACES, "Windows General MIDI") son SMF.
 */
import { FormatError, startsWith } from './binary.js';

export interface MidiEvent {
  /** Segundos desde el inicio. */
  time: number;
  /** Bytes de estado + datos (sin delta). Los meta-eventos no se incluyen. */
  status: number;
  data1: number;
  data2: number;
}

export interface MidiSong {
  format: number;
  tracks: number;
  ticksPerQuarter: number;
  duration: number;
  events: MidiEvent[];
}

export function parseMidi(data: Uint8Array): MidiSong {
  if (!startsWith(data, 'MThd')) throw new FormatError('No es un archivo MIDI.');
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const format = view.getUint16(8);
  const ntracks = view.getUint16(10);
  const division = view.getUint16(12);
  if (division & 0x8000) throw new FormatError('MIDI con división SMPTE no soportado.');

  type Raw = { tick: number; order: number; status: number; d1: number; d2: number; tempo?: number };
  const raw: Raw[] = [];
  let pos = 8 + view.getUint32(4);
  let order = 0;
  for (let t = 0; t < ntracks && pos + 8 <= data.length; t++) {
    if (!startsWith(data, 'MTrk', pos)) throw new FormatError(`Pista MIDI ${t} inválida.`);
    const len = view.getUint32(pos + 4);
    let p = pos + 8;
    const end = Math.min(data.length, p + len);
    let tick = 0;
    let running = 0;
    const vlq = () => {
      let v = 0;
      for (let i = 0; i < 4 && p < end; i++) {
        const b = data[p++];
        v = (v << 7) | (b & 0x7f);
        if (!(b & 0x80)) break;
      }
      return v;
    };
    while (p < end) {
      tick += vlq();
      let status = data[p];
      if (status & 0x80) p++;
      else status = running;
      if (status === 0xff) {
        const type = data[p++];
        const l = vlq();
        if (type === 0x51 && l === 3) raw.push({ tick, order: order++, status: 0xff, d1: 0, d2: 0, tempo: (data[p] << 16) | (data[p + 1] << 8) | data[p + 2] });
        if (type === 0x2f) break;
        p += l;
      } else if (status === 0xf0 || status === 0xf7) {
        p += vlq();
      } else {
        running = status;
        const hi = status & 0xf0;
        const d1 = data[p++];
        const d2 = hi === 0xc0 || hi === 0xd0 ? 0 : data[p++];
        raw.push({ tick, order: order++, status, d1, d2 });
      }
    }
    pos += 8 + len;
  }
  raw.sort((a, b) => a.tick - b.tick || a.order - b.order);

  let tempo = 500000; // µs por negra
  let lastTick = 0;
  let time = 0;
  const events: MidiEvent[] = [];
  for (const r of raw) {
    time += ((r.tick - lastTick) * tempo) / (division * 1e6);
    lastTick = r.tick;
    if (r.status === 0xff) {
      tempo = r.tempo ?? tempo;
      continue;
    }
    events.push({ time, status: r.status, data1: r.d1, data2: r.d2 });
  }
  return { format, tracks: ntracks, ticksPerQuarter: division, duration: time, events };
}
