/** Asistente de primera ejecución: registrar los discos del usuario. */
import { GAMES, gameById } from '../../shared/catalog.js';
import type { IsoScanResult } from '../../shared/ipc.js';
import { api, call } from '../api.js';
import { clear, formatSize, h, screen } from '../dom.js';
import { app, refreshState } from '../state.js';
import { showError } from './modal.js';

export async function showWizard(done: () => void): Promise<void> {
  let step = 0;
  let folder = app.library?.isoFolder ?? '';
  let found: IsoScanResult[] = [];
  let scannedFolder = '';
  let copyTo: string | null = null;
  const selected = new Set<string>();

  const render = () => {
    const root = screen();
    clear(root);
    const steps = h('div', { class: 'steps' }, ...[0, 1, 2, 3].map((i) => h('span', { class: i < step ? 'done' : i === step ? 'current' : '' })));
    const card = h('div', { class: 'card', style: { maxWidth: '860px', margin: '0 auto' } }, steps);
    root.append(card);
    [welcome, disks, storage, importing][step](card);
  };

  const nav = (back: boolean, nextLabel: string, onNext: () => void | Promise<void>, nextEnabled = true) =>
    h('div', { class: 'row', style: { marginTop: '22px' } },
      back ? h('button', { class: 'btn', onclick: () => { step--; render(); } }, '< Atrás') : null,
      h('span', { class: 'spacer' }),
      h('button', { class: 'btn primary', disabled: !nextEnabled, onclick: () => void onNext() }, nextLabel),
    );

  function welcome(card: HTMLElement) {
    card.append(
      h('h1', null, '¡Bienvenido a Trampolín Remaster!'),
      h('p', { class: 'lead' }, 'Una versión moderna de los juegos Trampolín que usa tus propios discos. Primero, indicanos dónde están.'),
      h('ul', null,
        h('li', null, 'Necesitás los discos como archivos .iso (por ejemplo, los de trampolin_anaya.zip descomprimidos).'),
        h('li', null, 'Nada se envía por internet y los discos no se modifican.'),
        h('li', null, 'Mientras un juego no esté reimplementado, podés explorar sus recursos y jugar la versión original con Trampolín Runtime.'),
      ),
      nav(false, 'Empezar', () => { step = 1; render(); }),
    );
  }

  function disks(card: HTMLElement) {
    const input = h('input', { value: folder, style: { flex: '1', padding: '9px', borderRadius: '8px', border: '1px solid var(--line)' }, readOnly: true });
    const table = h('table', { class: 'list' });
    const status = h('p', { class: 'lead' });
    const fill = () => {
      clear(table);
      table.append(h('tr', null, h('th', null, ''), h('th', null, 'Juego'), h('th', null, 'Archivo'), h('th', null, 'Estado')));
      for (const r of found) {
        const game = r.gameId ? gameById(r.gameId) : undefined;
        const ok = r.status === 'ok';
        const cb = h('input', { type: 'checkbox', checked: ok && selected.has(r.path), disabled: !ok, onchange: (e: Event) => {
          if ((e.target as HTMLInputElement).checked) selected.add(r.path); else selected.delete(r.path);
        } });
        table.append(h('tr', null,
          h('td', null, cb),
          h('td', null, game?.name ?? '(desconocido)'),
          h('td', null, r.name, h('div', { class: 'meta', style: { color: 'var(--muted)', fontSize: '12px' } }, r.message)),
          h('td', null, h('span', { class: `chip ${ok ? 'ok' : 'bad'}` }, ok ? 'Listo' : r.status === 'invalid' ? 'Dañado' : 'No reconocido')),
        ));
      }
      const okCount = found.filter((r) => r.status === 'ok').length;
      status.textContent = found.length ? `Encontramos ${okCount} de ${GAMES.length} juegos.` : 'Elegí la carpeta con los archivos .iso.';
    };
    const scan = async () => {
      if (!folder) return;
      scannedFolder = folder;
      status.textContent = 'Buscando discos…';
      try {
        found = await call(api().scanFolder(folder));
        selected.clear();
        for (const r of found) if (r.status === 'ok') selected.add(r.path);
      } catch (e) {
        found = [];
        const a = await showError(e);
        if (a === 'chooseFolder') await choose();
      }
      fill();
      render();
    };
    const choose = async () => {
      const f = await call(api().chooseFolder('Elegí la carpeta con los discos de Trampolín'));
      if (f) { folder = f; await scan(); }
    };
    card.append(
      h('h1', null, '¿Dónde están los discos?'),
      h('div', { class: 'row' }, input, h('button', { class: 'btn', onclick: () => void choose() }, 'Elegir carpeta…'), h('button', { class: 'btn', onclick: () => void scan() }, 'Volver a buscar')),
      status,
      table,
      nav(true, 'Siguiente >', () => { step = 2; render(); }, selected.size > 0),
    );
    fill();
    if (folder && folder !== scannedFolder) void scan();
  }

  function storage(card: HTMLElement) {
    const total = found.filter((r) => selected.has(r.path)).reduce((s, r) => s + r.size, 0);
    const inPlace = h('input', { type: 'radio', name: 'store', checked: copyTo === null, onchange: () => { copyTo = null; } });
    const copy = h('input', { type: 'radio', name: 'store', checked: copyTo !== null, onchange: async () => {
      const f = await call(api().chooseFolder('Elegí dónde guardar una copia de los discos'));
      if (f) copyTo = f; else { inPlace.checked = true; copyTo = null; }
      render();
    } });
    card.append(
      h('h1', null, '¿Cómo usamos los discos?'),
      h('label', { class: 'opt' }, inPlace, h('div', null, h('b', null, 'Usarlos desde donde están (recomendado)'), h('div', { class: 'meta' }, 'No ocupa espacio extra. No muevas ni borres los .iso después.'))),
      h('label', { class: 'opt' }, copy, h('div', null, h('b', null, 'Copiarlos a otra carpeta'), h('div', { class: 'meta' }, `Ocupa ${formatSize(total)}. ${copyTo ? `Destino: ${copyTo}` : ''}`))),
      nav(true, 'Registrar discos', async () => { step = 3; render(); }),
    );
  }

  function importing(card: HTMLElement) {
    const bar = h('div');
    const msg = h('p', { class: 'lead' }, 'Preparando…');
    card.append(h('h1', null, 'Registrando los discos…'), h('div', { class: 'progress' }, bar), msg);
    api().onProgress((p, m) => { bar.style.width = `${p}%`; msg.textContent = m; });
    const items = found.filter((r) => selected.has(r.path));
    void (async () => {
      try {
        const ids = await call(api().importIsos(items, copyTo));
        await refreshState();
        bar.style.width = '100%';
        clear(card);
        card.append(
          h('h1', null, '¡Listo!'),
          h('p', { class: 'lead' }, `Se registraron ${ids.length} juegos. Ya podés explorarlos desde la biblioteca.`),
          h('div', { class: 'row' }, h('span', { class: 'spacer' }), h('button', { class: 'btn primary', onclick: () => done() }, 'Ir a la biblioteca')),
        );
      } catch (e) {
        await showError(e);
        step = 2;
        render();
      }
    })();
  }

  render();
}
