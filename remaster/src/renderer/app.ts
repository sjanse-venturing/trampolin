/** Punto de entrada de la interfaz de Trampolín Remaster. */
import { api } from './api.js';
import { clear, h } from './dom.js';
import { app, refreshState } from './state.js';
import { showLibrary } from './ui/library.js';
import { infoDialog, showError } from './ui/modal.js';
import { showOptions } from './ui/options.js';
import { showWizard } from './ui/wizard.js';

// Cualquier error no previsto se muestra amigablemente en lugar de dejar la ventana en blanco.
window.addEventListener('error', (e) => void showError(e.error ?? new Error(e.message)));
window.addEventListener('unhandledrejection', (e) => void showError(e.reason));

function setNav(active: string): void {
  const nav = document.getElementById('nav')!;
  clear(nav);
  const item = (id: string, label: string, fn: () => void) => h('button', { class: id === active ? 'active' : '', onclick: fn }, label);
  nav.append(
    item('library', 'Biblioteca', () => goLibrary()),
    item('add', 'Agregar discos', () => goWizard()),
    item('options', 'Opciones', () => showOptions()),
    item('help', 'Ayuda', () => void help()),
  );
}

function goLibrary(): void {
  setNav('library');
  showLibrary(goWizard);
}

function goWizard(): void {
  setNav('add');
  void showWizard(goLibrary);
}

async function help(): Promise<void> {
  await infoDialog('Ayuda', h('div', null,
    h('p', null, 'Trampolín Remaster es una versión moderna en desarrollo de los juegos Trampolín. Usa tus discos (.iso) sin modificarlos.'),
    h('ul', null,
      h('li', null, h('b', null, 'Galería: '), 'recorre los escenarios del juego con su música, usando el motor nuevo.'),
      h('li', null, h('b', null, 'Recursos: '), 'explorá imágenes, voces, música y textos; podés exportarlos (PNG, WAV, MIDI).'),
      h('li', null, h('b', null, 'Jugar (original): '), 'abre el juego original con Trampolín Runtime, si está instalado.'),
    ),
    h('p', null, `Versión ${app.version}. Si algo falla, usá «Copiar informe» en el mensaje de error.`),
    h('div', { class: 'row' }, h('button', { class: 'btn', onclick: () => void api().openLogs() }, 'Abrir registros')),
  ));
}

async function start(): Promise<void> {
  try {
    await refreshState();
  } catch (e) {
    await showError(e);
    return;
  }
  const hasGames = Object.keys(app.library?.games ?? {}).length > 0;
  if (!app.library?.settings.firstRunDone || !hasGames) goWizard();
  else goLibrary();
}

void start();
