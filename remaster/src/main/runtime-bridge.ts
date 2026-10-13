/**
 * Puente con Trampolín Runtime (camino 1): mientras un juego no está
 * reimplementado en el Remaster, se puede jugar la versión original con el
 * runtime, si está instalado (plan B de REMASTER.md §11.3).
 */
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { TrError } from '../shared/errors.js';
import type { RuntimeInfo } from '../shared/ipc.js';
import { log } from './log.js';

function readJson(path: string): any {
  try { return JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, '')); } catch { return null; }
}

export function detectRuntime(): RuntimeInfo {
  const cfg = readJson(join(process.env.LOCALAPPDATA ?? '', 'Trampolin', 'config.json'));
  const root: string | null = cfg?.installRoot ?? null;
  if (!root || !existsSync(join(root, 'app', 'src', 'Trampolin.ps1'))) return { installed: false, installRoot: null, games: [] };
  const manifest = readJson(join(root, 'manifest.json'));
  return { installed: true, installRoot: root, games: Object.keys(manifest?.games ?? {}) };
}

export function playWithRuntime(gameId: string): void {
  const rt = detectRuntime();
  if (!rt.installed || !rt.games.includes(gameId)) throw new TrError('E_RUNTIME_MISSING');
  const script = join(rt.installRoot!, 'app', 'src', 'Trampolin.ps1');
  const ps = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  log('info', `Lanzando con Trampolín Runtime: ${gameId}`);
  const child = spawn(ps, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', script, '--play', gameId], {
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
  });
  child.unref();
}
