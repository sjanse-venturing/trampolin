/**
 * Galería: recorre los escenarios del juego a pantalla completa con el motor
 * nuevo (superficie indexada + fundidos por paleta, como el original) y la
 * música del propio juego.
 */
import { decodeBmp, IndexedImage } from '../../formats/bmp.js';
import { parseMidi } from '../../formats/midi.js';
import type { VfsNode } from '../../formats/vfs.js';
import { gameById } from '../../shared/catalog.js';
import { api, call } from '../api.js';
import { h } from '../dom.js';
import { MidiPlayer } from '../engine/midiplayer.js';
import { Presenter } from '../engine/presenter.js';
import { app, getAudio } from '../state.js';
import { showError } from './modal.js';

export async function showGallery(gameId: string): Promise<void> {
  const game = gameById(gameId)!;
  const title = h('span', null, 'Buscando escenarios…');
  const stage = h('div', { class: 'stage', tabindex: '0' });
  const hud = h('div', { class: 'hud' });
  stage.append(hud);
  document.body.append(stage);
  stage.focus();

  const settings = app.library?.settings ?? { scale: 'fit' as const, smooth: false };
  const presenter = new Presenter(stage, settings);
  const audio = getAudio();
  const player = new MidiPlayer(audio.ctx, audio.music);
  let images: VfsNode[] = [];
  let songs: VfsNode[] = [];
  let index = 0;
  let timer: number | null = null;
  let fading = false;
  let closed = false;
  let musicOn = true;

  const close = () => {
    closed = true;
    if (timer !== null) window.clearTimeout(timer);
    player.stop();
    presenter.dispose();
    stage.remove();
  };

  hud.append(
    h('b', null, game.name), h('span', null, ' · '), title,
    h('span', { class: 'spacer' }),
    h('button', { class: 'btn', onclick: () => void go(-1) }, '◀'),
    h('button', { class: 'btn', onclick: () => void go(1) }, '▶'),
    h('button', { class: 'btn', onclick: () => { musicOn = !musicOn; if (musicOn) void playSong(); else player.stop(); } }, '♪ Música'),
    h('button', { class: 'btn', onclick: () => void (document.fullscreenElement ? document.exitFullscreen() : stage.requestFullscreen()) }, '⛶'),
    h('button', { class: 'btn', onclick: close }, '✕ Salir'),
  );
  stage.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') close();
    if (e.key === 'ArrowRight' || e.key === ' ') void go(1);
    if (e.key === 'ArrowLeft') void go(-1);
  });
  stage.addEventListener('click', (e) => { if (e.target === presenter.canvas) void go(1); });

  /** Fundido por paleta (como hacían los juegos): de la imagen actual a negro y luego a la nueva. */
  const fade = async (from: number, to: number, ms = 450) => {
    const start = performance.now();
    await new Promise<void>((resolve) => {
      const step = (now: number) => {
        if (closed) return resolve();
        const t = Math.min(1, (now - start) / ms);
        presenter.setBrightness(from + (to - from) * t);
        presenter.present();
        if (t < 1) requestAnimationFrame(step); else resolve();
      };
      requestAnimationFrame(step);
    });
  };

  const load = async (n: VfsNode): Promise<IndexedImage | null> => {
    try { return decodeBmp(await call(api().read(gameId, n.path))); } catch { return null; }
  };

  const show = async (i: number) => {
    if (!images.length || fading) return;
    fading = true;
    index = (i + images.length) % images.length;
    const img = await load(images[index]);
    if (img && !closed) {
      await fade(1, 0);
      presenter.clear(0);
      presenter.setPalette(img.palette);
      presenter.drawImage(img);
      await fade(0, 1);
      title.textContent = `${images[index].name} (${index + 1}/${images.length})`;
    }
    fading = false;
    if (timer !== null) window.clearTimeout(timer);
    if (!closed) timer = window.setTimeout(() => void show(index + 1), 7000);
  };
  const go = (d: number) => show(index + d);

  const playSong = async () => {
    if (!songs.length || !musicOn) return;
    const s = songs[Math.floor(Math.random() * songs.length)];
    try {
      player.onEnded = () => void playSong();
      player.play(parseMidi(await call(api().read(gameId, s.path))));
    } catch { /* música opcional */ }
  };

  try {
    const [imgs, mids] = await Promise.all([
      call(api().findAssets(gameId, 'image', 300)),
      call(api().findAssets(gameId, 'music', 40)),
    ]);
    // Escenarios: imágenes de pantalla completa (640x480); se descartan sprites y máscaras.
    images = imgs.filter((n) => n.size > 8000 && !/MSK|MASK/i.test(n.name));
    songs = mids;
    if (!images.length) {
      close();
      await showError(new Error('Este juego todavía no tiene imágenes legibles para la galería (sus gráficos usan un formato aún no reimplementado).'));
      return;
    }
    presenter.setBrightness(0);
    await show(0);
    void playSong();
  } catch (e) {
    close();
    void showError(e);
  }
}
