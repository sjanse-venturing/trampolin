/**
 * Presentación: una superficie lógica de 640x480 en 8 bits indexados (como el
 * original) que se convierte a color con la paleta vigente y se muestra
 * escalada. Trabajar en 8 bits permite reproducir fundidos y animaciones de
 * paleta exactamente igual que en 1997.
 */
import type { IndexedImage } from '../../formats/bmp.js';
import type { Settings } from '../../shared/ipc.js';

export const LOGICAL_W = 640;
export const LOGICAL_H = 480;

export class Presenter {
  readonly canvas: HTMLCanvasElement;
  private readonly ctx: CanvasRenderingContext2D;
  private readonly back: HTMLCanvasElement;
  private readonly backCtx: CanvasRenderingContext2D;
  private readonly frame: ImageData;
  private readonly pixels = new Uint8Array(LOGICAL_W * LOGICAL_H);
  private palette = new Uint8Array(768);
  private brightness = 1;
  private readonly onResize = () => this.layout();

  constructor(private readonly host: HTMLElement, private settings: Pick<Settings, 'scale' | 'smooth'>) {
    this.canvas = document.createElement('canvas');
    this.ctx = this.canvas.getContext('2d')!;
    this.back = document.createElement('canvas');
    this.back.width = LOGICAL_W;
    this.back.height = LOGICAL_H;
    this.backCtx = this.back.getContext('2d')!;
    this.frame = this.backCtx.createImageData(LOGICAL_W, LOGICAL_H);
    host.append(this.canvas);
    window.addEventListener('resize', this.onResize);
    this.layout();
  }

  dispose(): void {
    window.removeEventListener('resize', this.onResize);
    this.canvas.remove();
  }

  setSettings(s: Pick<Settings, 'scale' | 'smooth'>): void {
    this.settings = s;
    this.layout();
  }

  /** Calcula el tamaño en pantalla según la opción de escala (ajustar / entera / original). */
  private layout(): void {
    const aw = this.host.clientWidth || window.innerWidth;
    const ah = this.host.clientHeight || window.innerHeight;
    let scale = Math.min(aw / LOGICAL_W, ah / LOGICAL_H);
    if (this.settings.scale === 'integer') scale = Math.max(1, Math.floor(scale));
    if (this.settings.scale === 'original') scale = 1;
    const cssW = Math.round(LOGICAL_W * scale);
    const cssH = Math.round(LOGICAL_H * scale);
    const dpr = window.devicePixelRatio || 1;
    this.canvas.style.width = `${cssW}px`;
    this.canvas.style.height = `${cssH}px`;
    this.canvas.width = Math.round(cssW * dpr);
    this.canvas.height = Math.round(cssH * dpr);
    this.blit();
  }

  /** Dibuja una imagen indexada en la superficie (centrada si es más chica). */
  drawImage(img: IndexedImage, x = Math.floor((LOGICAL_W - img.width) / 2), y = Math.floor((LOGICAL_H - img.height) / 2)): void {
    for (let row = 0; row < img.height; row++) {
      const ty = y + row;
      if (ty < 0 || ty >= LOGICAL_H) continue;
      const srcStart = row * img.width;
      for (let col = 0; col < img.width; col++) {
        const tx = x + col;
        if (tx >= 0 && tx < LOGICAL_W) this.pixels[ty * LOGICAL_W + tx] = img.pixels[srcStart + col];
      }
    }
  }

  clear(index = 0): void {
    this.pixels.fill(index);
  }

  setPalette(pal: Uint8Array): void {
    this.palette = pal.slice();
  }

  /** 0 = negro, 1 = colores normales (fundidos por paleta, como el original). */
  setBrightness(b: number): void {
    this.brightness = Math.max(0, Math.min(1, b));
  }

  /** Convierte índices a color con la paleta vigente y presenta escalado. */
  present(): void {
    const d = this.frame.data;
    const pal = this.palette;
    const k = this.brightness;
    for (let i = 0; i < this.pixels.length; i++) {
      const c = this.pixels[i] * 3;
      d[i * 4] = pal[c] * k;
      d[i * 4 + 1] = pal[c + 1] * k;
      d[i * 4 + 2] = pal[c + 2] * k;
      d[i * 4 + 3] = 255;
    }
    this.backCtx.putImageData(this.frame, 0, 0);
    this.blit();
  }

  private blit(): void {
    this.ctx.imageSmoothingEnabled = this.settings.smooth;
    this.ctx.imageSmoothingQuality = 'high';
    this.ctx.drawImage(this.back, 0, 0, this.canvas.width, this.canvas.height);
  }

  /** Coordenadas lógicas (640x480) de un evento de mouse. */
  toLogical(e: MouseEvent): { x: number; y: number } {
    const r = this.canvas.getBoundingClientRect();
    return { x: Math.floor(((e.clientX - r.left) * LOGICAL_W) / r.width), y: Math.floor(((e.clientY - r.top) * LOGICAL_H) / r.height) };
  }
}
