/** Salida de audio: mezclador con volúmenes separados para música y efectos/voces. */
export class AudioOut {
  readonly ctx = new AudioContext();
  readonly music: GainNode;
  readonly sfx: GainNode;
  private readonly voices = new Set<AudioBufferSourceNode>();

  constructor(musicVolume = 0.7, soundVolume = 1) {
    this.music = this.ctx.createGain();
    this.sfx = this.ctx.createGain();
    this.music.connect(this.ctx.destination);
    this.sfx.connect(this.ctx.destination);
    this.setVolumes(musicVolume, soundVolume);
  }

  setVolumes(music: number, sound: number): void {
    this.music.gain.value = music;
    this.sfx.gain.value = sound;
  }

  async resume(): Promise<void> {
    if (this.ctx.state !== 'running') await this.ctx.resume();
  }

  /** Reproduce PCM (flotante, mono) a la frecuencia indicada. */
  playPcm(pcm: Float32Array, sampleRate: number, onEnd?: () => void): AudioBufferSourceNode {
    const buf = this.ctx.createBuffer(1, Math.max(1, pcm.length), sampleRate);
    buf.copyToChannel(pcm as Float32Array<ArrayBuffer>, 0);
    const src = this.ctx.createBufferSource();
    src.buffer = buf;
    src.connect(this.sfx);
    src.onended = () => { this.voices.delete(src); onEnd?.(); };
    this.voices.add(src);
    src.start();
    return src;
  }

  stopSounds(): void {
    for (const v of this.voices) { try { v.stop(); } catch { /* ya terminó */ } }
    this.voices.clear();
  }

  async close(): Promise<void> {
    this.stopSounds();
    await this.ctx.close();
  }
}
