/** Biblioteca: los 8 juegos, su estado en el Remaster y acciones. */
import { decodeBmp, indexedToRgba } from '../../formats/bmp.js';
import { ENGINE_NAMES, GAMES, GameInfo } from '../../shared/catalog.js';
import { api, call } from '../api.js';
import { clear, h, screen } from '../dom.js';
import { app, refreshState } from '../state.js';
import { showGallery } from './gallery.js';
import { confirmDialog, infoDialog, showError } from './modal.js';
import { showViewer } from './viewer.js';

const STATUS: Record<GameInfo['remaster'], { text: string; cls: string }> = {
  playable: { text: 'Jugable en el Remaster', cls: 'ok' },
  gallery: { text: 'Galería y recursos', cls: 'warn' },
  viewer: { text: 'Explorador de recursos', cls: '' },
};

const thumbCache = new Map<string, HTMLCanvasElement>();

export function showLibrary(onAddDisks: () => void): void {
  const root = screen();
  clear(root);
  const lib = app.library!;
  const registered = GAMES.filter((g) => lib.games[g.id]);
  root.append(
    h('h1', null, 'Biblioteca'),
    h('p', { class: 'lead' },
      registered.length
        ? 'Elegí un juego. La reimplementación avanza por etapas: hoy podés recorrer la galería de escenarios, explorar todos los recursos y jugar la versión original con Trampolín Runtime.'
        : 'Todavía no registraste discos.'),
  );
  if (!registered.length) {
    root.append(h('div', { class: 'card empty' }, h('p', null, 'Agregá los discos de los juegos para empezar.'), h('button', { class: 'btn primary', onclick: onAddDisks }, 'Agregar discos')));
    return;
  }
  const grid = h('div', { class: 'grid' });
  root.append(grid);
  for (const g of GAMES) grid.append(card(g, onAddDisks));
}

function card(g: GameInfo, onAddDisks: () => void): HTMLElement {
  const entry = app.library!.games[g.id];
  const thumb = h('div', { class: 'thumb' }, entry ? 'Cargando…' : 'Sin disco');
  const st = STATUS[g.remaster];
  const runtimeOk = app.runtime.installed && app.runtime.games.includes(g.id);
  const actions = h('div', { class: 'row' });
  const el = h('div', { class: 'card game-card' },
    thumb,
    h('h3', null, g.name),
    h('div', { class: 'meta' }, `${g.age} · ${ENGINE_NAMES[g.engine]}`),
    h('div', { class: 'row' }, h('span', { class: `chip ${entry ? st.cls : 'bad'}` }, entry ? st.text : 'Disco no registrado'), runtimeOk ? h('span', { class: 'chip ok' }, 'Original: listo') : null),
    actions,
  );
  if (!entry) {
    el.style.opacity = '.7';
    actions.append(h('button', { class: 'btn', onclick: onAddDisks }, 'Agregar disco…'));
    return el;
  }
  if (g.remaster !== 'viewer') actions.append(h('button', { class: 'btn primary', onclick: () => void showGallery(g.id) }, 'Galería'));
  actions.append(h('button', { class: 'btn', onclick: () => showViewer(g.id, () => showLibrary(onAddDisks)) }, 'Recursos'));
  actions.append(h('button', { class: runtimeOk ? 'btn secondary' : 'btn', onclick: () => void playOriginal(g) }, 'Jugar (original)'));
  actions.append(h('button', { class: 'btn', title: 'Más opciones', onclick: () => void more(g, onAddDisks) }, '···'));
  void loadThumb(g, thumb);
  return el;
}

async function loadThumb(g: GameInfo, box: HTMLElement): Promise<void> {
  const cached = thumbCache.get(g.id);
  if (cached) { clear(box); box.append(cached); return; }
  try {
    const imgs = await call(api().findAssets(g.id, 'image', 30));
    for (const n of imgs.filter((x) => x.size > 8000)) {
      const img = decodeBmp(await call(api().read(g.id, n.path)));
      if (img.width < 600) continue;
      const c = h('canvas', { width: img.width, height: img.height });
      c.getContext('2d')!.putImageData(new ImageData(indexedToRgba(img), img.width, img.height), 0, 0);
      thumbCache.set(g.id, c);
      clear(box);
      box.append(c);
      return;
    }
    box.textContent = 'Vista previa no disponible todavía';
  } catch (e) {
    box.textContent = 'No se pudo leer el disco';
    box.title = (e as Error).message;
  }
}

async function playOriginal(g: GameInfo): Promise<void> {
  try {
    await call(api().playOriginal(g.id));
    await infoDialog('Abriendo el juego', `«${g.name}» se abre con Trampolín Runtime (la versión original). Al salir del juego, volvé a esta ventana.`);
  } catch (e) {
    const a = await showError(e);
    if (a === 'openRuntime') await call(api().openRuntimeHelp());
  }
}

async function more(g: GameInfo, onAddDisks: () => void): Promise<void> {
  const entry = app.library!.games[g.id];
  const ok = await confirmDialog(g.name, `Disco: ${entry.isoPath}\n\n¿Querés indicar otra ubicación del disco o quitarlo de la biblioteca?`, 'Buscar el disco…', 'Quitar de la biblioteca');
  try {
    if (ok) {
      const p = await call(api().chooseIso(`Disco de ${g.name}`));
      if (p) await call(api().relocateGame(g.id, p));
    } else if (await confirmDialog('¿Quitar el juego?', `Se quitará «${g.name}» de la biblioteca. El archivo .iso no se borra.`, 'Quitar', 'Cancelar')) {
      await call(api().removeGame(g.id));
    }
    await refreshState();
    showLibrary(onAddDisks);
  } catch (e) {
    void showError(e);
  }
}
