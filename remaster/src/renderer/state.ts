/** Estado compartido de la interfaz. */
import type { LibraryState, RuntimeInfo } from '../shared/ipc.js';
import { api, call } from './api.js';
import { AudioOut } from './engine/audio.js';

export const app = {
  library: null as LibraryState | null,
  runtime: { installed: false, installRoot: null, games: [] } as RuntimeInfo,
  version: '',
};

export async function refreshState(): Promise<void> {
  const s = await call(api().getState());
  app.library = s.library;
  app.runtime = s.runtime;
  app.version = s.version;
}

let audio: AudioOut | null = null;

/** Salida de audio compartida (se crea al primer uso, tras una interacción del usuario). */
export function getAudio(): AudioOut {
  const st = app.library?.settings;
  if (!audio) audio = new AudioOut(st?.musicVolume ?? 0.7, st?.soundVolume ?? 1);
  else if (st) audio.setVolumes(st.musicVolume, st.soundVolume);
  void audio.resume();
  return audio;
}
