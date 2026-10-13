/** Errores con código, mensaje amigable y acción sugerida. */

export type ErrorCode =
  | 'E_ISO_NOT_FOUND'
  | 'E_ISO_INVALID'
  | 'E_ISO_UNKNOWN'
  | 'E_ISO_MOVED'
  | 'E_DISK_FULL'
  | 'E_NOT_WRITABLE'
  | 'E_ASSET_DECODE'
  | 'E_GAME_UNSUPPORTED'
  | 'E_RUNTIME_MISSING'
  | 'E_ENGINE_CRASH'
  | 'E_UNEXPECTED';

export type ErrorAction = 'chooseFolder' | 'locateIso' | 'retry' | 'openRuntime' | 'copyReport' | 'openLogs' | 'close';

export interface ErrorInfo {
  code: ErrorCode;
  title: string;
  message: string;
  actions: ErrorAction[];
  details?: string;
}

const CATALOG: Record<ErrorCode, { title: string; message: string; actions: ErrorAction[] }> = {
  E_ISO_NOT_FOUND: { title: 'No encontramos los discos', message: 'No encontramos discos de Trampolín en «{path}». Elegí la carpeta donde están los archivos .iso.', actions: ['chooseFolder'] },
  E_ISO_INVALID: { title: 'Disco no válido', message: '«{file}» no es una imagen de disco válida o está dañada.', actions: ['chooseFolder'] },
  E_ISO_UNKNOWN: { title: 'Disco desconocido', message: '«{file}» no corresponde a ningún juego Trampolín conocido.', actions: ['chooseFolder'] },
  E_ISO_MOVED: { title: 'Falta el disco', message: 'No encontramos el disco de «{game}» en {path}. ¿Lo moviste?', actions: ['locateIso'] },
  E_DISK_FULL: { title: 'Sin espacio', message: 'No hay espacio suficiente en {drive}.', actions: ['chooseFolder'] },
  E_NOT_WRITABLE: { title: 'Carpeta no disponible', message: 'No se puede escribir en «{path}».', actions: ['chooseFolder'] },
  E_ASSET_DECODE: { title: 'Recurso ilegible', message: 'Un recurso del juego no se pudo leer ({asset}). {reason}', actions: ['copyReport'] },
  E_GAME_UNSUPPORTED: { title: 'Todavía no disponible', message: '«{game}» todavía no se puede jugar en el Remaster. Podés explorar sus recursos o jugarlo con Trampolín Runtime.', actions: ['openRuntime'] },
  E_RUNTIME_MISSING: { title: 'Falta Trampolín Runtime', message: 'Para jugar la versión original instalá Trampolín Runtime (carpeta runtime del proyecto) y volvé a intentar.', actions: ['openRuntime'] },
  E_ENGINE_CRASH: { title: 'El juego se detuvo', message: 'El juego tuvo un problema y se detuvo. Tu progreso hasta el último guardado está a salvo.', actions: ['copyReport'] },
  E_UNEXPECTED: { title: 'Ocurrió un error inesperado', message: 'Ocurrió un error inesperado. No es tu culpa: copiá el informe y envialo a quien te ayude con la computadora.', actions: ['copyReport', 'openLogs'] },
};

export class TrError extends Error {
  constructor(readonly code: ErrorCode, readonly data: Record<string, string | number> = {}, readonly causeError?: unknown) {
    super(code);
    this.name = 'TrError';
  }
}

export function toErrorInfo(err: unknown): ErrorInfo {
  const tr = err instanceof TrError ? err : null;
  const code: ErrorCode = tr?.code ?? 'E_UNEXPECTED';
  const entry = CATALOG[code];
  let message = entry.message;
  for (const [k, v] of Object.entries(tr?.data ?? {})) message = message.split(`{${k}}`).join(String(v));
  const inner = tr?.causeError ?? err;
  const details = [`Código: ${code}`, inner instanceof Error ? `${inner.name}: ${inner.message}\n${inner.stack ?? ''}` : String(inner)].join('\n');
  return { code, title: entry.title, message, actions: entry.actions, details };
}

export const ACTION_LABELS: Record<ErrorAction, string> = {
  chooseFolder: 'Elegir otra carpeta…',
  locateIso: 'Buscar el archivo…',
  retry: 'Reintentar',
  openRuntime: 'Abrir Trampolín Runtime',
  copyReport: 'Copiar informe',
  openLogs: 'Abrir registros',
  close: 'Cerrar',
};
