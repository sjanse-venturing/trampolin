/**
 * Lector de imágenes ISO 9660 con extensión Joliet (nombres largos en UCS-2).
 * Lee directo de la imagen del usuario: no hace falta montarla ni extraerla.
 */
import { FormatError, RandomAccess, SliceSource, u32, ucs2be } from './binary.js';

const SECTOR = 2048;

export interface IsoEntry {
  /** Ruta con '/' relativa a la raíz, sin barra inicial. */
  path: string;
  name: string;
  isDirectory: boolean;
  lba: number;
  size: number;
}

export class IsoImage {
  private constructor(
    private readonly src: RandomAccess,
    private readonly joliet: boolean,
    private readonly root: IsoEntry,
    readonly volumeLabel: string,
  ) {}

  static async open(src: RandomAccess): Promise<IsoImage> {
    let pvd: Uint8Array | null = null;
    let svd: Uint8Array | null = null;
    for (let i = 16; i < 64; i++) {
      if ((i + 1) * SECTOR > src.size) break;
      const d = await src.read(i * SECTOR, SECTOR);
      if (d[1] !== 0x43 || d[2] !== 0x44 || d[3] !== 0x30 || d[4] !== 0x30 || d[5] !== 0x31) {
        throw new FormatError('No es una imagen ISO 9660 válida.');
      }
      if (d[0] === 1 && !pvd) pvd = d.slice();
      else if (d[0] === 2 && d[88] === 0x25 && d[89] === 0x2f && [0x40, 0x43, 0x45].includes(d[90])) svd = d.slice();
      else if (d[0] === 255) break;
    }
    if (!pvd) throw new FormatError('La imagen no tiene descriptor de volumen primario.');
    const vd = svd ?? pvd;
    const joliet = svd !== null;
    const label = (joliet ? ucs2be(vd, 40, 32) : String.fromCharCode(...vd.subarray(40, 72))).replace(/[\s\0]+$/, '');
    const root: IsoEntry = { path: '', name: '', isDirectory: true, lba: u32(vd, 158), size: u32(vd, 166) };
    return new IsoImage(src, joliet, root, label);
  }

  async readDir(dir: IsoEntry): Promise<IsoEntry[]> {
    if (!dir.isDirectory) throw new FormatError(`${dir.path} no es una carpeta`);
    const data = await this.src.read(dir.lba * SECTOR, Math.ceil(dir.size / SECTOR) * SECTOR);
    const out: IsoEntry[] = [];
    let pos = 0;
    while (pos < dir.size) {
      const len = data[pos];
      if (len === 0) {
        pos = (Math.floor(pos / SECTOR) + 1) * SECTOR;
        continue;
      }
      const nameLen = data[pos + 32];
      const isDirectory = (data[pos + 25] & 2) !== 0;
      if (nameLen === 1 && (data[pos + 33] === 0 || data[pos + 33] === 1)) {
        pos += len;
        continue;
      }
      let name = this.joliet ? ucs2be(data, pos + 33, nameLen) : String.fromCharCode(...data.subarray(pos + 33, pos + 33 + nameLen));
      const semi = name.indexOf(';');
      if (semi >= 0) name = name.substring(0, semi);
      if (!isDirectory && name.endsWith('.')) name = name.slice(0, -1);
      out.push({
        path: dir.path ? `${dir.path}/${name}` : name,
        name,
        isDirectory,
        lba: u32(data, pos + 2),
        size: u32(data, pos + 10),
      });
      pos += len;
    }
    return out;
  }

  get rootEntry(): IsoEntry {
    return this.root;
  }

  /** Busca una ruta sin distinguir mayúsculas ('/' o '\'). Devuelve null si no existe. */
  async find(path: string): Promise<IsoEntry | null> {
    const parts = path.replace(/\\/g, '/').split('/').filter(Boolean);
    let cur: IsoEntry = this.root;
    for (const part of parts) {
      if (!cur.isDirectory) return null;
      const next: IsoEntry | undefined = (await this.readDir(cur)).find((e) => e.name.toLowerCase() === part.toLowerCase());
      if (!next) return null;
      cur = next;
    }
    return cur;
  }

  /** Contenido de un archivo como fuente de acceso aleatorio (sin leerlo entero). */
  open(entry: IsoEntry): RandomAccess {
    if (entry.isDirectory) throw new FormatError(`${entry.path} es una carpeta`);
    return new SliceSource(this.src, entry.lba * SECTOR, entry.size);
  }

  /** Recorre todo el árbol. */
  async walk(start: IsoEntry = this.root): Promise<IsoEntry[]> {
    const out: IsoEntry[] = [];
    const stack = [start];
    while (stack.length) {
      const d = stack.pop()!;
      for (const e of await this.readDir(d)) {
        out.push(e);
        if (e.isDirectory) stack.push(e);
      }
    }
    return out;
  }
}
