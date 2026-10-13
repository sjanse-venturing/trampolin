/**
 * Sintetizador General MIDI liviano (sin bancos de sonido externos).
 * Agrupa los 128 programas GM en familias con un timbre y envolvente propios.
 * Es suficiente para escuchar y validar las músicas; la Fase M5 prevé usar
 * un SoundFont para calidad de remaster.
 */
type Family = { wave: OscillatorType; attack: number; decay: number; sustain: number; release: number; detune?: number; filter?: number; gain: number };

const FAMILIES: Family[] = [
  { wave: 'triangle', attack: 0.005, decay: 0.6, sustain: 0.25, release: 0.3, gain: 0.5 },          // 0 pianos
  { wave: 'sine', attack: 0.002, decay: 0.4, sustain: 0.0, release: 0.4, gain: 0.6 },               // 8 percusión cromática
  { wave: 'square', attack: 0.01, decay: 0.1, sustain: 0.8, release: 0.08, filter: 2500, gain: 0.25 }, // 16 órganos
  { wave: 'triangle', attack: 0.004, decay: 0.5, sustain: 0.3, release: 0.25, gain: 0.5 },          // 24 guitarras
  { wave: 'triangle', attack: 0.004, decay: 0.3, sustain: 0.6, release: 0.1, gain: 0.7 },           // 32 bajos
  { wave: 'sawtooth', attack: 0.12, decay: 0.2, sustain: 0.8, release: 0.3, filter: 3000, detune: 6, gain: 0.25 }, // 40 cuerdas
  { wave: 'sawtooth', attack: 0.15, decay: 0.2, sustain: 0.8, release: 0.4, filter: 2500, detune: 8, gain: 0.22 }, // 48 ensambles
  { wave: 'sawtooth', attack: 0.03, decay: 0.1, sustain: 0.8, release: 0.12, filter: 3500, gain: 0.25 }, // 56 bronces
  { wave: 'square', attack: 0.03, decay: 0.1, sustain: 0.8, release: 0.12, filter: 2800, gain: 0.22 },   // 64 lengüetas
  { wave: 'sine', attack: 0.04, decay: 0.1, sustain: 0.85, release: 0.15, gain: 0.55 },             // 72 vientos/flautas
  { wave: 'square', attack: 0.01, decay: 0.1, sustain: 0.8, release: 0.1, filter: 4000, gain: 0.2 },     // 80 lead
  { wave: 'sawtooth', attack: 0.3, decay: 0.3, sustain: 0.7, release: 0.6, filter: 1800, detune: 10, gain: 0.2 }, // 88 pad
  { wave: 'triangle', attack: 0.05, decay: 0.3, sustain: 0.5, release: 0.4, gain: 0.35 },           // 96 efectos
  { wave: 'triangle', attack: 0.005, decay: 0.4, sustain: 0.3, release: 0.2, gain: 0.45 },          // 104 étnicos
  { wave: 'square', attack: 0.001, decay: 0.15, sustain: 0.0, release: 0.05, filter: 2000, gain: 0.35 }, // 112 percusivos
  { wave: 'sine', attack: 0.05, decay: 0.3, sustain: 0.3, release: 0.3, gain: 0.3 },                // 120 efectos de sonido
];

interface Voice { stop: (t: number) => void; channel: number; note: number }

export class GmSynth {
  private readonly out: GainNode;
  private readonly program = new Uint8Array(16);
  private readonly volume = new Float32Array(16).fill(100 / 127);
  private readonly expression = new Float32Array(16).fill(1);
  private readonly pan = new Float32Array(16).fill(0);
  private readonly bend = new Float32Array(16);
  private readonly active: Voice[] = [];
  private noise: AudioBuffer | null = null;

  constructor(private readonly ctx: AudioContext, destination: AudioNode) {
    this.out = ctx.createGain();
    this.out.gain.value = 0.5;
    this.out.connect(destination);
  }

  reset(): void {
    this.allNotesOff(this.ctx.currentTime);
    this.program.fill(0);
    this.volume.fill(100 / 127);
    this.expression.fill(1);
    this.pan.fill(0);
    this.bend.fill(0);
  }

  allNotesOff(t: number): void {
    for (const v of this.active.splice(0)) v.stop(t);
  }

  /** Procesa un evento MIDI de canal en el instante t (segundos de AudioContext). */
  event(status: number, d1: number, d2: number, t: number): void {
    const ch = status & 0x0f;
    let type = status & 0xf0;
    if (type === 0x90 && d2 === 0) type = 0x80; // note on con velocidad 0 = note off
    switch (type) {
      case 0x90: this.noteOn(ch, d1, d2, t); break;
      case 0x80: this.noteOff(ch, d1, t); break;
      case 0xc0: this.program[ch] = d1; break;
      case 0xb0:
        if (d1 === 7) this.volume[ch] = d2 / 127;
        else if (d1 === 11) this.expression[ch] = d2 / 127;
        else if (d1 === 10) this.pan[ch] = (d2 - 64) / 64;
        else if (d1 === 120 || d1 === 123) for (const v of this.active.filter((x) => x.channel === ch)) { v.stop(t); this.active.splice(this.active.indexOf(v), 1); }
        break;
      case 0xe0: this.bend[ch] = ((d2 << 7 | d1) - 8192) / 8192 * 2; break; // ±2 semitonos
    }
  }

  private noteOff(ch: number, note: number, t: number): void {
    const i = this.active.findIndex((v) => v.channel === ch && v.note === note);
    if (i >= 0) this.active.splice(i, 1)[0].stop(t);
  }

  private noteOn(ch: number, note: number, vel: number, t: number): void {
    if (this.active.length > 48) this.active.shift()!.stop(t);
    const level = (vel / 127) * this.volume[ch] * this.expression[ch];
    const panner = this.ctx.createStereoPanner();
    panner.pan.value = this.pan[ch];
    panner.connect(this.out);
    if (ch === 9) { this.drum(note, level, t, panner); return; }
    const fam = FAMILIES[this.program[ch] >> 3];
    const freq = 440 * Math.pow(2, (note - 69 + this.bend[ch]) / 12);
    const env = this.ctx.createGain();
    env.gain.setValueAtTime(0, t);
    env.gain.linearRampToValueAtTime(level * fam.gain, t + fam.attack);
    env.gain.setTargetAtTime(level * fam.gain * fam.sustain, t + fam.attack, fam.decay / 3 + 0.001);
    let node: AudioNode = env;
    if (fam.filter) {
      const f = this.ctx.createBiquadFilter();
      f.type = 'lowpass';
      f.frequency.value = fam.filter;
      env.connect(f);
      node = f;
    }
    node.connect(panner);
    const oscs: OscillatorNode[] = [];
    for (const det of fam.detune ? [-fam.detune, fam.detune] : [0]) {
      const o = this.ctx.createOscillator();
      o.type = fam.wave;
      o.frequency.value = freq;
      o.detune.value = det;
      o.connect(env);
      o.start(t);
      oscs.push(o);
    }
    this.active.push({
      channel: ch,
      note,
      stop: (when) => {
        const at = Math.max(when, t + 0.01);
        env.gain.cancelScheduledValues(at);
        env.gain.setTargetAtTime(0, at, fam.release / 3 + 0.001);
        for (const o of oscs) o.stop(at + fam.release + 0.1);
      },
    });
  }

  /** Percusión GM (canal 10) aproximada con ruido y osciladores. */
  private drum(note: number, level: number, t: number, dest: AudioNode): void {
    const g = this.ctx.createGain();
    g.connect(dest);
    if (note === 35 || note === 36) {
      const o = this.ctx.createOscillator();
      o.frequency.setValueAtTime(140, t);
      o.frequency.exponentialRampToValueAtTime(45, t + 0.15);
      g.gain.setValueAtTime(level, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.25);
      o.connect(g);
      o.start(t);
      o.stop(t + 0.3);
      return;
    }
    if (!this.noise) {
      this.noise = this.ctx.createBuffer(1, this.ctx.sampleRate, this.ctx.sampleRate);
      const d = this.noise.getChannelData(0);
      for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    }
    const src = this.ctx.createBufferSource();
    src.buffer = this.noise;
    const f = this.ctx.createBiquadFilter();
    const hat = note === 42 || note === 44 || note === 46 || note >= 49;
    f.type = hat ? 'highpass' : 'bandpass';
    f.frequency.value = hat ? 7000 : 1800;
    const len = note === 46 || note === 49 || note === 57 ? 0.35 : hat ? 0.06 : 0.18;
    g.gain.setValueAtTime(level * 0.6, t);
    g.gain.exponentialRampToValueAtTime(0.001, t + len);
    src.connect(f);
    f.connect(g);
    src.start(t);
    src.stop(t + len + 0.05);
  }
}
