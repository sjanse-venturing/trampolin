/** Opciones: pantalla y sonido. */
import type { Settings } from '../../shared/ipc.js';
import { api, call } from '../api.js';
import { h } from '../dom.js';
import { app, getAudio } from '../state.js';
import { customDialog, showError } from './modal.js';

export function showOptions(): void {
  const s: Settings = { ...app.library!.settings };
  const radio = (value: Settings['scale'], label: string, hint: string) =>
    h('label', { class: 'opt' },
      h('input', { type: 'radio', name: 'scale', checked: s.scale === value, onchange: () => { s.scale = value; } }),
      h('div', null, h('b', null, label), h('div', { class: 'meta' }, hint)));
  const slider = (key: 'musicVolume' | 'soundVolume', label: string) =>
    h('label', { class: 'opt' }, h('span', { style: { width: '140px' } }, label),
      h('input', { type: 'range', min: '0', max: '100', value: String(Math.round(s[key] * 100)), oninput: (e: Event) => { s[key] = Number((e.target as HTMLInputElement).value) / 100; } }));
  const d = customDialog(h('div', null,
    h('h2', null, 'Opciones'),
    h('h3', null, 'Pantalla'),
    radio('fit', 'Ajustar a la ventana', 'Ocupa todo el espacio disponible manteniendo la proporción 4:3.'),
    radio('integer', 'Escala entera', 'Píxeles perfectamente nítidos (2×, 3×…), con bordes.'),
    radio('original', 'Tamaño original', '640×480 como en 1997.'),
    h('label', { class: 'opt' }, h('input', { type: 'checkbox', checked: s.smooth, onchange: (e: Event) => { s.smooth = (e.target as HTMLInputElement).checked; } }),
      h('div', null, h('b', null, 'Suavizar la imagen'), h('div', { class: 'meta' }, 'Desactivado: estilo pixel art fiel al original.'))),
    h('h3', null, 'Sonido'),
    slider('musicVolume', 'Música'),
    slider('soundVolume', 'Voces y efectos'),
    h('div', { class: 'actions' },
      h('button', { class: 'btn', onclick: () => d.close() }, 'Cancelar'),
      h('button', { class: 'btn primary', onclick: async () => {
        try {
          app.library!.settings = await call(api().updateSettings(s));
          getAudio().setVolumes(s.musicVolume, s.soundVolume);
          d.close();
        } catch (e) { void showError(e); }
      } }, 'Guardar'),
    ),
  ));
}
