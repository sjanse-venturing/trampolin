import type { RemasterApi, Result } from '../shared/ipc.js';
import type { ErrorInfo } from '../shared/errors.js';

declare global {
  interface Window {
    remaster: RemasterApi;
  }
}

/** Error que viene del proceso principal, ya traducido a un mensaje amigable. */
export class UiError extends Error {
  constructor(readonly info: ErrorInfo) {
    super(info.message);
    this.name = 'UiError';
  }
}

export const api = (): RemasterApi => window.remaster;

/** Desenvuelve un Result: devuelve el valor o lanza UiError. */
export async function call<T>(p: Promise<Result<T>>): Promise<T> {
  const r = await p;
  if (r.ok) return r.value;
  throw new UiError(r.error);
}
