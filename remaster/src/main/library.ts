/**
 * Biblioteca: discos registrados por el usuario, configuración y acceso a sus datos.
 * Se guarda en %APPDATA%\Trampolín Remaster\library.json.
 */
import { mkdir, readdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { GAMES, gameById } from '../shared/catalog.js';
import { TrError } from '../shared/errors.js';
import type { IsoScanResult, LibraryState, Settings } from '../shared/ipc.js';
import { IsoImage } from '../formats/iso9660.js';
import { GameVfs } from '../formats/vfs.js';
import { FileSource } from './filesource.js';
import { log } from './log.js';

const DEFAULT_SETTINGS: Settings = { scale: 'fit', smooth: false, musicVolume: 0.7, soundVolume: 1, firstRunDone: false };

export class Library {
  private state: LibraryState = { version: 1, isoFolder: null, games: {}, settings: { ...DEFAULT_SETTINGS } };
  private readonly open = new Map<string, { src: FileSource; vfs: GameVfs }>();

  constructor(private readonly file: string) {}

  async load(): Promise<void> {
    try {
      const raw = JSON.parse(await readFile(this.file, 'utf8')) as Partial<LibraryState>;
      this.state = {
        version: 1,
        isoFolder: raw.isoFolder ?? null,
        games: raw.games ?? {},
        settings: { ...DEFAULT_SETTINGS, ...(raw.settings ?? {}) },
      };
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'ENOENT') log('warn', `library.json ilegible, se empieza de cero: ${e}`);
    }
  }

  private async save(): Promise<void> {
    await mkdir(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    await writeFile(tmp, JSON.stringify(this.state, null, 2), 'utf8');
    await rename(tmp, this.file);
  }

  get snapshot(): LibraryState {
    return JSON.parse(JSON.stringify(this.state));
  }

  async updateSettings(patch: Partial<Settings>): Promise<Settings> {
    this.state.settings = { ...this.state.settings, ...patch };
    await this.save();
    return this.state.settings;
  }

  /** Busca imágenes de los juegos en una carpeta (y un nivel de subcarpetas). */
  async scanFolder(folder: string): Promise<IsoScanResult[]> {
    let names: string[];
    try { names = await readdir(folder); } catch { throw new TrError('E_ISO_NOT_FOUND', { path: folder }); }
    const candidates: string[] = [];
    for (const n of names) {
      const full = join(folder, n);
      if (n.toLowerCase().endsWith('.iso')) candidates.push(full);
      else {
        try {
          if ((await stat(full)).isDirectory()) for (const m of await readdir(full)) if (m.toLowerCase().endsWith('.iso')) candidates.push(join(full, m));
        } catch { /* ignorar */ }
      }
    }
    const results: IsoScanResult[] = [];
    for (const path of candidates) results.push(await this.inspectIso(path));
    this.state.isoFolder = folder;
    await this.save();
    return results;
  }

  async inspectIso(path: string): Promise<IsoScanResult> {
    const r: IsoScanResult = { path, name: basename(path), size: 0, label: '', gameId: null, status: 'unknown', message: '' };
    let src: FileSource | null = null;
    try {
      src = await FileSource.open(path);
      r.size = src.size;
      const iso = await IsoImage.open(src);
      r.label = iso.volumeLabel;
      const bySize = GAMES.find((g) => g.isoSize === src!.size);
      const order = bySize ? [bySize, ...GAMES.filter((g) => g !== bySize)] : GAMES;
      for (const g of order) {
        if (await iso.find(g.keyFile)) {
          r.gameId = g.id;
          r.status = 'ok';
          if (g.isoSize !== src.size) r.message = 'Edición distinta de la probada; probablemente funcione.';
          break;
        }
      }
      if (!r.gameId) r.message = 'No corresponde a ningún juego Trampolín conocido.';
    } catch (e) {
      r.status = 'invalid';
      r.message = `No se pudo leer: ${(e as Error).message}`;
    } finally {
      await src?.close();
    }
    return r;
  }

  /**
   * Registra discos en la biblioteca. Si `copyTo` está definido, primero copia las
   * imágenes a esa carpeta (para no depender de su ubicación original).
   */
  async importIsos(items: IsoScanResult[], copyTo: string | null, onProgress: (percent: number, message: string) => void): Promise<string[]> {
    const imported: string[] = [];
    const total = items.reduce((s, i) => s + (copyTo ? i.size : 1), 0) || 1;
    let done = 0;
    for (const item of items) {
      if (!item.gameId || item.status !== 'ok') continue;
      const game = gameById(item.gameId)!;
      let finalPath = item.path;
      if (copyTo) {
        await mkdir(copyTo, { recursive: true });
        finalPath = join(copyTo, item.name);
        if (finalPath.toLowerCase() !== item.path.toLowerCase()) {
          onProgress(Math.round((100 * done) / total), `Copiando ${game.name}…`);
          await copyWithProgress(item.path, finalPath, (n) => {
            done += n;
            onProgress(Math.round((100 * done) / total), `Copiando ${game.name}…`);
          });
        } else done += item.size;
      } else done += 1;
      this.state.games[item.gameId] = { isoPath: finalPath, label: item.label, addedAt: new Date().toISOString() };
      await this.closeGame(item.gameId);
      imported.push(item.gameId);
      log('info', `Disco registrado: ${item.gameId} → ${finalPath}`);
      onProgress(Math.round((100 * done) / total), `${game.name}: listo`);
    }
    this.state.settings.firstRunDone = true;
    await this.save();
    return imported;
  }

  async removeGame(id: string): Promise<void> {
    await this.closeGame(id);
    delete this.state.games[id];
    await this.save();
  }

  async relocate(id: string, newPath: string): Promise<IsoScanResult> {
    const r = await this.inspectIso(newPath);
    if (r.status !== 'ok' || r.gameId !== id) throw new TrError('E_ISO_INVALID', { file: basename(newPath) });
    await this.closeGame(id);
    this.state.games[id] = { isoPath: newPath, label: r.label, addedAt: new Date().toISOString() };
    await this.save();
    return r;
  }

  /** VFS del juego (abre la ISO la primera vez). */
  async vfs(id: string): Promise<GameVfs> {
    const cached = this.open.get(id);
    if (cached) return cached.vfs;
    const entry = this.state.games[id];
    const game = gameById(id);
    if (!entry || !game) throw new TrError('E_GAME_UNSUPPORTED', { game: id });
    let src: FileSource;
    try { src = await FileSource.open(entry.isoPath); } catch (e) { throw new TrError('E_ISO_MOVED', { game: game.name, path: entry.isoPath }, e); }
    try {
      const vfs = new GameVfs(await IsoImage.open(src));
      this.open.set(id, { src, vfs });
      return vfs;
    } catch (e) {
      await src.close();
      throw new TrError('E_ISO_INVALID', { file: basename(entry.isoPath) }, e);
    }
  }

  async closeGame(id: string): Promise<void> {
    const o = this.open.get(id);
    if (o) { this.open.delete(id); await o.src.close(); }
  }

  async closeAll(): Promise<void> {
    for (const id of [...this.open.keys()]) await this.closeGame(id);
  }
}

async function copyWithProgress(from: string, to: string, onBytes: (n: number) => void): Promise<void> {
  const tmp = `${to}.part`;
  await new Promise<void>((resolve, reject) => {
    const rs = createReadStream(from, { highWaterMark: 1 << 20 });
    const ws = createWriteStream(tmp);
    rs.on('data', (chunk) => onBytes((chunk as Buffer).length));
    rs.on('error', reject);
    ws.on('error', (e: NodeJS.ErrnoException) => reject(e.code === 'ENOSPC' ? new TrError('E_DISK_FULL', { drive: dirname(to) }, e) : e));
    ws.on('finish', () => resolve());
    rs.pipe(ws);
  });
  await rename(tmp, to);
}
