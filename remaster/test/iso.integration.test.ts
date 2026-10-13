/**
 * Pruebas de integración contra las ISOs reales del usuario.
 * Se ejecutan solo si TRAMPOLIN_ISOS apunta a la carpeta con los .iso:
 *   set TRAMPOLIN_ISOS=C:\ruta\a\las\isos && npm test
 */
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { decodeBmp } from '../src/formats/bmp.js';
import { IsoImage } from '../src/formats/iso9660.js';
import { decodeKaSound } from '../src/formats/kasnd.js';
import { parseMidi } from '../src/formats/midi.js';
import { GameVfs } from '../src/formats/vfs.js';
import { FileSource } from '../src/main/filesource.js';
import { GAMES } from '../src/shared/catalog.js';

const folder = process.env.TRAMPOLIN_ISOS;
const isoFor = (file: string) => (folder ? readdirSync(folder).find((f) => f.normalize() === file.normalize()) : undefined);

describe.skipIf(!folder)('ISOs reales', () => {
  for (const g of GAMES) {
    it(`${g.id}: abre la ISO y encuentra el archivo clave`, async () => {
      const name = isoFor(g.isoFile);
      if (!name) return;
      const src = await FileSource.open(join(folder!, name));
      try {
        const iso = await IsoImage.open(src);
        expect(iso.volumeLabel.length).toBeGreaterThan(0);
        expect(await iso.find(g.keyFile)).not.toBeNull();
      } finally { await src.close(); }
    });
  }

  it('FG: lee un BMP de un .RSC, un sonido de SOUND.BAL y un MIDI', async () => {
    const name = isoFor('Trampolin - 1° Ciclo.iso');
    if (!name) return;
    const src = await FileSource.open(join(folder!, name));
    try {
      const vfs = new GameVfs(await IsoImage.open(src));
      const rsc = await vfs.list('FG/32BIT/BA001.RSC');
      const bmp = rsc.find((n) => n.name === 'BA001.BMP')!;
      const img = decodeBmp(await vfs.readAll(bmp.path));
      expect([img.width, img.height]).toEqual([640, 480]);

      const dirs = await vfs.list('FG/SOUND.BAL');
      expect(dirs.length).toBeGreaterThan(10);
      const ba = await vfs.list(dirs.find((d) => d.name === 'BA')!.path);
      const snd = decodeKaSound(await vfs.readAll(ba.find((s) => s.name === 'BA005B.SND')!.path));
      expect(snd.pcm.length).toBe(1102);

      const song = parseMidi(await vfs.readAll('SUPPORT/CMN/MU001.MID'));
      expect(song.events.length).toBeGreaterThan(100);
    } finally { await src.close(); }
  });

  it('PRSCHOOL: navega el paquete ACES (KAFS)', async () => {
    const name = isoFor('Trampolín Educación Infantil - 1° Ciclo.iso');
    if (!name) return;
    const src = await FileSource.open(join(folder!, name));
    try {
      const vfs = new GameVfs(await IsoImage.open(src));
      const root = await vfs.list('PRSCHOOL');
      expect(root.some((n) => n.name === 'COMMON' && n.kind === 'dir')).toBe(true);
      const common = await vfs.list(root.find((n) => n.name === 'COMMON')!.path);
      expect(common.some((n) => n.name === 'FNT')).toBe(true);
    } finally { await src.close(); }
  });
});
