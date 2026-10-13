/**
 * Sistema de archivos virtual: ISO → archivos → contenedores (BWRF, KAFS) → recursos.
 *
 * Una ruta virtual es una lista de segmentos: el primero es la ruta dentro de
 * la ISO; los siguientes, rutas dentro de contenedores anidados. Se serializa
 * como "FG/32BIT/BA001.RSC|BA001.BMP".
 */
import { RandomAccess } from './binary.js';
import { isBwrf, openBwrfEntry, readBwrf } from './bwrf.js';
import { IsoImage } from './iso9660.js';
import { isKafs, openKafsFile, readKafsDir, KafsEntry } from './kafs.js';

export type AssetType = 'image' | 'sound' | 'music' | 'palette' | 'text' | 'scene' | 'actor' | 'video' | 'binary';

export interface VfsNode {
  name: string;
  /** Ruta virtual serializada. */
  path: string;
  kind: 'dir' | 'container' | 'file';
  size: number;
  type: AssetType;
}

const TYPE_BY_EXT: Record<string, AssetType> = {
  BMP: 'image', SND: 'sound', MID: 'music', WGM: 'music', PAL: 'palette',
  TXT: 'text', INI: 'text', ACE: 'text', ARG: 'text', MSG: 'text', LST: 'text', INF: 'text', BAT: 'text',
  SCN: 'scene', ATR: 'actor', SMK: 'video', MVI: 'video', MOV: 'video',
};

export function assetTypeOf(name: string): AssetType {
  const dot = name.lastIndexOf('.');
  return dot < 0 ? 'binary' : TYPE_BY_EXT[name.substring(dot + 1).toUpperCase()] ?? 'binary';
}

export function splitPath(path: string): string[] {
  return path.split('|');
}
export function joinPath(segments: string[]): string {
  return segments.join('|');
}

type Container =
  | { kind: 'bwrf'; src: RandomAccess }
  | { kind: 'kafs'; src: RandomAccess };

export class GameVfs {
  private readonly containerCache = new Map<string, Container | null>();
  constructor(readonly iso: IsoImage) {}

  /** ¿El archivo es un contenedor navegable? Detección por extensión y firma. */
  private async containerOf(segments: string[], src: RandomAccess): Promise<Container | null> {
    const key = joinPath(segments);
    if (this.containerCache.has(key)) return this.containerCache.get(key)!;
    const name = segments[segments.length - 1].split('/').pop()!.toUpperCase();
    let c: Container | null = null;
    if (name.endsWith('.RSC') && (await isBwrf(src))) c = { kind: 'bwrf', src };
    else if ((name.endsWith('.BAL') || !name.includes('.')) && src.size > 64 && (await isKafs(src))) c = { kind: 'kafs', src };
    this.containerCache.set(key, c);
    return c;
  }

  /** Abre un nodo de archivo (no carpeta). */
  async open(path: string): Promise<RandomAccess> {
    const segments = splitPath(path);
    const entry = await this.iso.find(segments[0]);
    if (!entry || entry.isDirectory) throw new Error(`No existe: ${segments[0]}`);
    let src = this.iso.open(entry);
    for (let i = 1; i < segments.length; i++) {
      const c = await this.containerOf(segments.slice(0, i), src);
      if (!c) throw new Error(`${segments.slice(0, i).join('|')} no es un contenedor`);
      if (c.kind === 'bwrf') {
        const e = (await readBwrf(c.src)).find((x) => x.name.toUpperCase() === segments[i].toUpperCase());
        if (!e) throw new Error(`No existe ${segments[i]}`);
        src = openBwrfEntry(c.src, e);
      } else {
        const e = await this.findKafs(c.src, segments[i]);
        if (!e || e.isDirectory) throw new Error(`No existe ${segments[i]}`);
        src = openKafsFile(c.src, e);
      }
    }
    return src;
  }

  private async findKafs(src: RandomAccess, inner: string): Promise<KafsEntry | null> {
    const parts = inner.split('/').filter(Boolean);
    let offset = 0;
    let found: KafsEntry | null = null;
    let prefix = '';
    for (const part of parts) {
      const entries = await readKafsDir(src, offset, prefix);
      found = entries.find((e) => e.name.toUpperCase() === part.toUpperCase()) ?? null;
      if (!found) return null;
      offset = found.offset;
      prefix = found.path;
    }
    return found;
  }

  /** Lista los hijos de una carpeta o contenedor. "" = raíz de la ISO. */
  async list(path: string): Promise<VfsNode[]> {
    if (path === '') return this.listIsoDir(this.iso.rootEntry);
    const segments = splitPath(path);
    if (segments.length === 1) {
      const entry = await this.iso.find(segments[0]);
      if (!entry) throw new Error(`No existe: ${segments[0]}`);
      if (entry.isDirectory) return this.listIsoDir(entry);
      return this.listContainer(segments, 0, '');
    }
    // ¿Es una subcarpeta dentro de un contenedor KAFS? ("SOUND.BAL|BA")
    const parentSegs = segments.slice(0, -1);
    const inner = segments[segments.length - 1];
    const parent = await this.containerOf(parentSegs, await this.open(joinPath(parentSegs)));
    if (parent?.kind === 'kafs') {
      const d = await this.findKafs(parent.src, inner);
      if (d?.isDirectory) return this.listContainer(parentSegs, d.offset, d.path);
    }
    // Si no, es un archivo que a su vez es un contenedor.
    return this.listContainer(segments, 0, '');
  }

  private async listIsoDir(dir: { path: string; isDirectory: boolean; lba: number; size: number; name: string }): Promise<VfsNode[]> {
    const out: VfsNode[] = [];
    for (const e of await this.iso.readDir(dir)) {
      if (e.isDirectory) { out.push({ name: e.name, path: e.path, kind: 'dir', size: 0, type: 'binary' }); continue; }
      const isContainer = !!(await this.containerOf([e.path], this.iso.open(e)));
      out.push({ name: e.name, path: e.path, kind: isContainer ? 'container' : 'file', size: e.size, type: assetTypeOf(e.name) });
    }
    return sortNodes(out);
  }

  /** Lista un contenedor (o una subcarpeta KAFS dentro de él, en `offset`). */
  private async listContainer(segments: string[], offset: number, innerPrefix: string): Promise<VfsNode[]> {
    const base = joinPath(segments);
    const c = await this.containerOf(segments, await this.open(base));
    if (!c) throw new Error(`${base} no es un contenedor`);
    if (c.kind === 'bwrf') {
      return sortNodes((await readBwrf(c.src)).map((e) => ({ name: e.name, path: `${base}|${e.name}`, kind: 'file' as const, size: e.size, type: assetTypeOf(e.name) })));
    }
    const entries = await readKafsDir(c.src, offset, innerPrefix);
    return sortNodes(entries.map((e) => ({
      name: e.name,
      path: `${base}|${e.path}`,
      kind: e.isDirectory ? ('dir' as const) : ('file' as const),
      size: e.size,
      type: e.isDirectory ? ('binary' as const) : assetTypeOf(e.name),
    })));
  }

  async readAll(path: string): Promise<Uint8Array> {
    const src = await this.open(path);
    if (src.size > 64 * 1024 * 1024) throw new Error('Archivo demasiado grande para abrirlo entero.');
    return (await src.read(0, src.size)).slice();
  }
}

function sortNodes(nodes: VfsNode[]): VfsNode[] {
  const rank = (n: VfsNode) => (n.kind === 'dir' ? 0 : n.kind === 'container' ? 1 : 2);
  return nodes.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name, 'es'));
}
