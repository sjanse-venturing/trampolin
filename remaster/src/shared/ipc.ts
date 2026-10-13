/** Tipos compartidos entre el proceso principal y la interfaz. */
import type { ErrorInfo } from './errors.js';
import type { VfsNode } from '../formats/vfs.js';

export interface Settings {
  scale: 'fit' | 'integer' | 'original';
  smooth: boolean;
  musicVolume: number;
  soundVolume: number;
  firstRunDone: boolean;
}

export interface LibraryGame {
  isoPath: string;
  label: string;
  addedAt: string;
}

export interface LibraryState {
  version: 1;
  isoFolder: string | null;
  games: Record<string, LibraryGame>;
  settings: Settings;
}

export interface IsoScanResult {
  path: string;
  name: string;
  size: number;
  label: string;
  gameId: string | null;
  status: 'ok' | 'invalid' | 'unknown';
  message: string;
}

export interface RuntimeInfo {
  installed: boolean;
  installRoot: string | null;
  games: string[];
}

/** Resultado de cualquier llamada IPC: nunca se lanzan excepciones entre procesos. */
export type Result<T> = { ok: true; value: T } | { ok: false; error: ErrorInfo };

export interface RemasterApi {
  getState(): Promise<Result<{ library: LibraryState; runtime: RuntimeInfo; version: string }>>;
  chooseFolder(title: string): Promise<Result<string | null>>;
  chooseIso(title: string): Promise<Result<string | null>>;
  scanFolder(folder: string): Promise<Result<IsoScanResult[]>>;
  importIsos(items: IsoScanResult[], copyTo: string | null): Promise<Result<string[]>>;
  onProgress(cb: (percent: number, message: string) => void): void;
  removeGame(id: string): Promise<Result<void>>;
  relocateGame(id: string, path: string): Promise<Result<void>>;
  updateSettings(patch: Partial<Settings>): Promise<Result<Settings>>;
  list(gameId: string, path: string): Promise<Result<VfsNode[]>>;
  read(gameId: string, path: string): Promise<Result<Uint8Array>>;
  findAssets(gameId: string, type: string, limit: number): Promise<Result<VfsNode[]>>;
  saveFile(defaultName: string, data: Uint8Array): Promise<Result<string | null>>;
  playOriginal(gameId: string): Promise<Result<void>>;
  openRuntimeHelp(): Promise<Result<void>>;
  openLogs(): Promise<Result<void>>;
  report(error: ErrorInfo | null): Promise<Result<string>>;
  logError(message: string): Promise<void>;
}
