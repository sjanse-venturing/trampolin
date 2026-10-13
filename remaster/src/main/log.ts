import { appendFileSync, mkdirSync, readdirSync, readFileSync, unlinkSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import os from 'node:os';

let logFile: string | null = null;

export function initLog(dir: string, version: string): string {
  mkdirSync(dir, { recursive: true });
  const day = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  logFile = join(dir, `remaster-${day}.log`);
  // Rotación: se conservan 7 días.
  const files = readdirSync(dir).filter((f) => /^remaster-\d{8}\.log$/.test(f)).sort().reverse();
  for (const old of files.slice(7)) {
    try { unlinkSync(join(dir, old)); } catch { /* sin importancia */ }
  }
  log('info', `=== Trampolín Remaster ${version} — ${os.type()} ${os.release()} — Node ${process.versions.node} — Electron ${process.versions.electron}`);
  return logFile;
}

export function log(level: 'info' | 'warn' | 'error', message: string): void {
  const line = `${new Date().toISOString()} [${level.toUpperCase()}] ${message}\n`;
  if (level === 'error') console.error(line.trimEnd());
  if (!logFile) return;
  try { appendFileSync(logFile, line, 'utf8'); } catch { /* no bloquear la app por el log */ }
}

export function logPath(): string | null {
  return logFile;
}

export function tailLog(lines = 200): string {
  if (!logFile || !existsSync(logFile)) return '';
  return readFileSync(logFile, 'utf8').split('\n').slice(-lines).join('\n');
}
