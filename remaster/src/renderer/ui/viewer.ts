/** Visor de recursos: navega la ISO, sus contenedores y muestra/exporta cada recurso. */
import { decodeAcesPalette } from '../../formats/acespal.js';
import { cp1252 } from '../../formats/binary.js';
import { decodeBmp, indexedToRgba } from '../../formats/bmp.js';
import { decodeKaSound } from '../../formats/kasnd.js';
import { parseMidi } from '../../formats/midi.js';
import type { VfsNode } from '../../formats/vfs.js';
import { encodeWav } from '../../formats/wav.js';
import { gameById } from '../../shared/catalog.js';
import { api, call } from '../api.js';
import { clear, formatSize, h, screen } from '../dom.js';
import { MidiPlayer } from '../engine/midiplayer.js';
import { getAudio } from '../state.js';
import { showError } from './modal.js';

const ICONS: Record<string, string> = { dir: '📁', container: '📦', image: '🖼️', sound: '🔊', music: '🎵', palette: '🎨', text: '📄', scene: '🎬', actor: '🧸', video: '🎞️', binary: '▫️' };

let midi: MidiPlayer | null = null;

export function showViewer(gameId: string, back: () => void): void {
  const game = gameById(gameId)!;
  const root = screen();
  clear(root);
  const tree = h('div', { class: 'card tree' });
  const preview = h('div', { class: 'card preview' }, h('p', { class: 'lead' }, 'Elegí un recurso a la izquierda para verlo, escucharlo o exportarlo.'));
  root.append(
    h('div', { class: 'row', style: { marginBottom: '12px' } },
      h('button', { class: 'btn', onclick: () => { stopAll(); back(); } }, '< Biblioteca'),
      h('h1', { style: { margin: '0 0 0 8px', fontSize: '20px' } }, `Recursos de ${game.name}`),
    ),
    h('div', { class: 'viewer' }, tree, preview),
  );

  let selected: HTMLElement | null = null;

  const renderLevel = async (path: string, into: HTMLElement) => {
    const ul = h('ul');
    into.append(ul);
    ul.append(h('li', null, h('div', { class: 'meta' }, 'Cargando…')));
    let nodes: VfsNode[];
    try {
      nodes = await call(api().list(gameId, path));
    } catch (e) {
      clear(ul);
      ul.append(h('li', null, h('div', { class: 'meta' }, 'No se pudo abrir esta carpeta.')));
      void showError(e);
      return;
    }
    clear(ul);
    for (const n of nodes) {
      const label = h('div', { title: n.path },
        `${ICONS[n.kind === 'file' ? n.type : n.kind] ?? '▫️'} ${n.name}`,
        n.kind !== 'dir' ? h('span', { class: 'size' }, formatSize(n.size)) : null,
      );
      const li = h('li', null, label);
      let expanded = false;
      label.addEventListener('click', async () => {
        if (n.kind === 'file') {
          selected?.classList.remove('selected');
          label.classList.add('selected');
          selected = label;
          await showAsset(gameId, n, preview);
          return;
        }
        if (expanded) { li.querySelector('ul')?.remove(); expanded = false; return; }
        expanded = true;
        await renderLevel(n.path, li);
      });
      ul.append(li);
    }
    if (!nodes.length) ul.append(h('li', null, h('div', { class: 'meta' }, '(vacío)')));
  };
  void renderLevel('', tree);
}

function stopAll(): void {
  midi?.stop();
  try { getAudio().stopSounds(); } catch { /* sin audio */ }
}

async function save(name: string, data: Uint8Array): Promise<void> {
  try { await call(api().saveFile(name, data)); } catch (e) { void showError(e); }
}

function hexDump(data: Uint8Array, max = 1024): string {
  const lines: string[] = [];
  for (let i = 0; i < Math.min(data.length, max); i += 16) {
    const bytes = Array.from(data.subarray(i, i + 16));
    lines.push(`${i.toString(16).padStart(6, '0')}  ${bytes.map((b) => b.toString(16).padStart(2, '0')).join(' ').padEnd(48)}  ${bytes.map((b) => (b >= 32 && b < 127 ? String.fromCharCode(b) : '.')).join('')}`);
  }
  return lines.join('\n');
}

function swatches(pal: Uint8Array): HTMLElement {
  const box = h('div', { class: 'swatches', title: 'Paleta de 256 colores' });
  for (let i = 0; i < 256; i++) {
    const s = h('i', { title: `${i}: ${pal[i * 3]},${pal[i * 3 + 1]},${pal[i * 3 + 2]}` });
    s.style.background = `rgb(${pal[i * 3]},${pal[i * 3 + 1]},${pal[i * 3 + 2]})`;
    box.append(s);
  }
  return box;
}

async function showAsset(gameId: string, node: VfsNode, preview: HTMLElement): Promise<void> {
  stopAll();
  clear(preview);
  preview.append(h('p', { class: 'lead' }, 'Leyendo…'));
  let data: Uint8Array;
  try {
    data = await call(api().read(gameId, node.path));
  } catch (e) {
    clear(preview);
    preview.append(h('p', { class: 'lead' }, 'No se pudo leer este recurso.'));
    void showError(e);
    return;
  }
  clear(preview);
  const baseName = node.name.replace(/[\\/:*?"<>|]/g, '_');
  const header = h('div', { class: 'row' },
    h('h2', { style: { margin: 0 } }, node.name),
    h('span', { class: 'chip' }, formatSize(node.size)),
    h('span', { class: 'spacer' }),
    h('button', { class: 'btn', onclick: () => void save(baseName, data) }, 'Guardar original…'),
  );
  preview.append(header);

  try {
    switch (node.type) {
      case 'image': renderImage(data, baseName, header, preview); break;
      case 'sound': renderSound(data, baseName, header, preview); break;
      case 'music': renderMusic(data, preview); break;
      case 'palette': renderPalette(data, preview); break;
      case 'text': preview.append(h('pre', null, cp1252(data, 0, Math.min(data.length, 65536)))); break;
      default: renderBinary(node, data, preview);
    }
  } catch (e) {
    preview.append(h('div', { class: 'notice' }, `No se pudo interpretar este recurso: ${(e as Error).message}`));
    renderBinary(node, data, preview);
  }
}

function renderImage(data: Uint8Array, name: string, header: HTMLElement, preview: HTMLElement): void {
  const img = decodeBmp(data);
  const canvas = h('canvas', { width: img.width, height: img.height });
  const ctx = canvas.getContext('2d')!;
  ctx.putImageData(new ImageData(indexedToRgba(img), img.width, img.height), 0, 0);
  canvas.style.width = `${img.width * (img.width <= 320 ? 2 : 1)}px`;
  header.append(h('button', { class: 'btn secondary', onclick: () => canvas.toBlob(async (b) => b && void save(name.replace(/\.\w+$/, '.png'), new Uint8Array(await b.arrayBuffer()))) }, 'Exportar PNG…'));
  preview.append(h('p', { class: 'meta' }, `${img.width} × ${img.height}, 8 bits con paleta`), canvas, h('h2', null, 'Paleta'), swatches(img.palette));
}

function renderSound(data: Uint8Array, name: string, header: HTMLElement, preview: HTMLElement): void {
  const { info, pcm } = decodeKaSound(data);
  let rate = info.sampleRate;
  const rateSel = h('select', { onchange: (e: Event) => { rate = Number((e.target as HTMLSelectElement).value); } },
    ...[11025, 22050, 44100].map((r) => h('option', { value: String(r), selected: r === rate }, `${r} Hz`)));
  header.append(h('button', { class: 'btn secondary', onclick: () => void save(name.replace(/\.\w+$/, '.wav'), encodeWav(pcm, rate)) }, 'Exportar WAV…'));
  preview.append(
    h('p', { class: 'meta' }, `${info.samples} muestras · ${info.bits} bits · ${(info.samples / info.sampleRate).toFixed(2)} s (a ${info.sampleRate} Hz)`),
    h('div', { class: 'row' },
      h('button', { class: 'btn primary', onclick: () => { stopAll(); getAudio().playPcm(pcm, rate); } }, '▶ Reproducir'),
      h('button', { class: 'btn', onclick: () => stopAll() }, '■ Detener'),
      h('label', null, 'Frecuencia: ', rateSel),
    ),
    h('p', { class: 'meta' }, 'Si la voz suena acelerada o lenta, probá otra frecuencia: ayuda a validar el formato (REMASTER.md §4, F5).'),
  );
}

function renderMusic(data: Uint8Array, preview: HTMLElement): void {
  const song = parseMidi(data);
  preview.append(
    h('p', { class: 'meta' }, `MIDI tipo ${song.format} · ${song.tracks} pistas · ${song.events.length} eventos · ${Math.round(song.duration)} s`),
    h('div', { class: 'row' },
      h('button', { class: 'btn primary', onclick: () => { const a = getAudio(); midi ??= new MidiPlayer(a.ctx, a.music); midi.play(song); } }, '▶ Reproducir'),
      h('button', { class: 'btn', onclick: () => midi?.stop() }, '■ Detener'),
    ),
    h('p', { class: 'meta' }, 'Se reproduce con el sintetizador General MIDI integrado.'),
  );
}

function renderPalette(data: Uint8Array, preview: HTMLElement): void {
  preview.append(swatches(decodeAcesPalette(data)));
}

function renderBinary(node: VfsNode, data: Uint8Array, preview: HTMLElement): void {
  const notes: Record<string, string> = {
    scene: 'Escena del motor KA-MFC (.SCN): fondo, objetos y rutas. Formato en investigación (REMASTER.md §4, F7).',
    actor: 'Actor/animación (.ATR): cuadros con un códec propio. Formato en investigación (REMASTER.md §4, F6).',
    video: 'Video (Smacker / LzH3). Decodificador pendiente (REMASTER.md §4, F12/F15).',
  };
  if (notes[node.type]) preview.append(h('div', { class: 'notice' }, notes[node.type]));
  const strings = (cp1252(data, 0, Math.min(data.length, 65536)).match(/[\x20-\x7e\xc0-\xff]{5,}/g) ?? []).slice(0, 60);
  if (strings.length) preview.append(h('h2', null, 'Textos encontrados'), h('pre', null, strings.join('\n')));
  preview.append(h('h2', null, 'Contenido (hexadecimal)'), h('pre', null, hexDump(data)));
}
