/** Reproductor de canciones MIDI con planificación anticipada sobre WebAudio. */
import type { MidiSong } from '../../formats/midi.js';
import { GmSynth } from './synth.js';

export class MidiPlayer {
  private synth: GmSynth;
  private song: MidiSong | null = null;
  private timer: number | null = null;
  private startTime = 0;
  private index = 0;
  private loop = false;
  onEnded: (() => void) | null = null;

  constructor(private readonly ctx: AudioContext, destination: AudioNode) {
    this.synth = new GmSynth(ctx, destination);
  }

  get playing(): boolean {
    return this.timer !== null;
  }

  play(song: MidiSong, loop = false): void {
    this.stop();
    this.song = song;
    this.loop = loop;
    this.index = 0;
    this.startTime = this.ctx.currentTime + 0.1;
    this.synth.reset();
    this.timer = window.setInterval(() => this.pump(), 25);
    this.pump();
  }

  stop(): void {
    if (this.timer !== null) window.clearInterval(this.timer);
    this.timer = null;
    this.synth.allNotesOff(this.ctx.currentTime);
  }

  /** Agenda los eventos de los próximos 150 ms. */
  private pump(): void {
    const song = this.song;
    if (!song) return;
    const horizon = this.ctx.currentTime + 0.15;
    while (this.index < song.events.length) {
      const ev = song.events[this.index];
      const t = this.startTime + ev.time;
      if (t > horizon) return;
      this.synth.event(ev.status, ev.data1, ev.data2, Math.max(t, this.ctx.currentTime));
      this.index++;
    }
    if (this.ctx.currentTime >= this.startTime + song.duration + 0.5) {
      if (this.loop && song.events.length) {
        this.index = 0;
        this.startTime = this.ctx.currentTime + 0.2;
        this.synth.reset();
      } else {
        this.stop();
        this.onEnded?.();
      }
    }
  }
}
