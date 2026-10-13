/**
 * Proceso principal de Trampolín Remaster (Electron).
 * Responsable de: ventana, acceso a archivos/ISOs, biblioteca, log y errores.
 */
import { app, BrowserWindow, clipboard, dialog, ipcMain, shell } from 'electron';
import { existsSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { gameById } from '../shared/catalog.js';
import { ErrorInfo, toErrorInfo, TrError } from '../shared/errors.js';
import type { Result } from '../shared/ipc.js';
import type { VfsNode } from '../formats/vfs.js';
import { Library } from './library.js';
import { initLog, log, logPath, tailLog } from './log.js';
import { detectRuntime, playWithRuntime } from './runtime-bridge.js';

const here = dirname(fileURLToPath(import.meta.url));
app.setName('Trampolín Remaster');
const userData = app.getPath('userData');
initLog(join(userData, 'logs'), app.getVersion());
const library = new Library(join(userData, 'library.json'));
let win: BrowserWindow | null = null;

// --- Errores no controlados: se registran y se muestra un mensaje amigable ------
process.on('uncaughtException', (e) => {
  log('error', `uncaughtException: ${e.stack ?? e}`);
  dialog.showErrorBox('Trampolín Remaster', 'Ocurrió un error inesperado. La aplicación intentará seguir funcionando.\n\nEl detalle quedó guardado en el registro.');
});
process.on('unhandledRejection', (e) => log('error', `unhandledRejection: ${(e as Error)?.stack ?? e}`));

/** Envuelve un handler IPC: devuelve {ok, value} o {ok:false, error} con mensaje amigable. */
function handle<A extends unknown[], T>(channel: string, fn: (...args: A) => Promise<T> | T): void {
  ipcMain.handle(channel, async (_e, ...args: unknown[]): Promise<Result<T>> => {
    try {
      return { ok: true, value: await fn(...(args as A)) };
    } catch (e) {
      const info = toErrorInfo(e);
      log('error', `${channel} falló: ${info.details}`);
      return { ok: false, error: info };
    }
  });
}

function createWindow(): void {
  win = new BrowserWindow({
    width: 1180,
    height: 820,
    minWidth: 900,
    minHeight: 640,
    backgroundColor: '#fbf7ef',
    title: 'Trampolín Remaster',
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: join(here, '..', 'preload', 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.once('ready-to-show', () => win?.show());
  win.webContents.on('render-process-gone', (_e, d) => {
    log('error', `La interfaz se cerró inesperadamente: ${d.reason}`);
    if (d.reason !== 'clean-exit') win?.reload();
  });
  // Los enlaces externos se abren en el navegador, nunca dentro de la app.
  win.webContents.setWindowOpenHandler(({ url }) => { void shell.openExternal(url); return { action: 'deny' }; });
  void win.loadFile(join(here, '..', 'renderer', 'index.html'));
}

// --- Búsqueda de recursos de un tipo (para la galería) ------------------------
async function findAssets(gameId: string, type: string, limit: number): Promise<VfsNode[]> {
  const vfs = await library.vfs(gameId);
  const game = gameById(gameId);
  const out: VfsNode[] = [];
  const queue: string[] = [...(game?.resourceDirs ?? []), ''];
  const seen = new Set<string>();
  let visited = 0;
  while (queue.length && out.length < limit && visited < 4000) {
    const path = queue.shift()!;
    if (seen.has(path)) continue;
    seen.add(path);
    visited++;
    let nodes: VfsNode[];
    try { nodes = await vfs.list(path); } catch { continue; }
    for (const n of nodes) {
      if (n.kind === 'file' && n.type === type) { out.push(n); if (out.length >= limit) break; }
      else if (n.kind === 'dir' && !/^(SUPPORT\/(W16|UTILDISK|WIN32S|EREG|WINSYS)|EXTENSIONES)/i.test(n.path)) queue.push(n.path);
      else if (n.kind === 'container' && !(type !== 'sound' && /SOUND2?\.BAL$/i.test(n.path))) queue.push(n.path);
    }
  }
  return out;
}

// --- IPC -------------------------------------------------------------------------
handle('state', async () => ({ library: library.snapshot, runtime: detectRuntime(), version: app.getVersion() }));
handle('chooseFolder', async (title: string) => {
  const r = await dialog.showOpenDialog(win!, { title, properties: ['openDirectory'] });
  return r.canceled ? null : r.filePaths[0];
});
handle('chooseIso', async (title: string) => {
  const r = await dialog.showOpenDialog(win!, { title, properties: ['openFile'], filters: [{ name: 'Imagen de disco', extensions: ['iso'] }] });
  return r.canceled ? null : r.filePaths[0];
});
handle('scanFolder', (folder: string) => library.scanFolder(folder));
handle('importIsos', (items, copyTo: string | null) =>
  library.importIsos(items as never, copyTo, (p, m) => win?.webContents.send('progress', p, m)),
);
handle('removeGame', (id: string) => library.removeGame(id));
handle('relocateGame', async (id: string, path: string) => { await library.relocate(id, path); });
handle('updateSettings', (patch) => library.updateSettings(patch as never));
handle('list', async (gameId: string, path: string) => (await library.vfs(gameId)).list(path));
handle('read', async (gameId: string, path: string) => {
  try { return await (await library.vfs(gameId)).readAll(path); }
  catch (e) { if (e instanceof TrError) throw e; throw new TrError('E_ASSET_DECODE', { asset: path, reason: (e as Error).message }, e); }
});
handle('findAssets', (gameId: string, type: string, limit: number) => findAssets(gameId, type, limit));
handle('saveFile', async (defaultName: string, data: Uint8Array) => {
  const r = await dialog.showSaveDialog(win!, { defaultPath: join(app.getPath('documents'), defaultName) });
  if (r.canceled || !r.filePath) return null;
  await writeFile(r.filePath, data);
  return r.filePath;
});
handle('playOriginal', (gameId: string) => playWithRuntime(gameId));
handle('openRuntimeHelp', async () => {
  const candidates = [join(app.getAppPath(), '..', 'runtime'), join(app.getAppPath(), '..', '..', 'runtime')];
  const dir = candidates.find((d) => existsSync(join(d, 'Trampolin.cmd')));
  if (dir) {
    await shell.openPath(dir);
    return;
  }
  await dialog.showMessageBox(win!, {
    type: 'info',
    title: 'Trampolín Runtime',
    message: 'Para jugar la versión original de los juegos',
    detail: 'Instalá Trampolín Runtime: descomprimí TrampolinRuntime-x.y.z.zip y hacé doble clic en Trampolin.cmd. Después volvé a esta pantalla y presioná «Jugar (original)».',
  });
});
handle('openLogs', async () => { const p = logPath(); if (p) shell.showItemInFolder(p); });
handle('report', async (error: ErrorInfo | null) => {
  const text = [
    'Informe de Trampolín Remaster',
    `Versión: ${app.getVersion()}  Windows: ${os.release()}  Electron: ${process.versions.electron}`,
    error ? `Error: ${error.code} — ${error.message}\n${error.details ?? ''}` : '',
    '--- Últimas líneas del registro ---',
    tailLog(200),
  ].join('\n');
  clipboard.writeText(text);
  return text;
});
ipcMain.handle('logError', (_e, message: string) => log('error', `[interfaz] ${message}`));

app.whenReady().then(async () => {
  await library.load();
  createWindow();
});
app.on('window-all-closed', async () => {
  await library.closeAll();
  app.quit();
});
