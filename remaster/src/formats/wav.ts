/** Codifica muestras flotantes a WAV PCM de 16 bits (para exportar sonidos). */
export function encodeWav(pcm: Float32Array, sampleRate: number, channels = 1): Uint8Array {
  const dataLen = pcm.length * 2;
  const buf = new Uint8Array(44 + dataLen);
  const v = new DataView(buf.buffer);
  const str = (o: number, s: string) => { for (let i = 0; i < s.length; i++) buf[o + i] = s.charCodeAt(i); };
  str(0, 'RIFF'); v.setUint32(4, 36 + dataLen, true); str(8, 'WAVE');
  str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, channels, true);
  v.setUint32(24, sampleRate, true); v.setUint32(28, sampleRate * channels * 2, true); v.setUint16(32, channels * 2, true); v.setUint16(34, 16, true);
  str(36, 'data'); v.setUint32(40, dataLen, true);
  for (let i = 0; i < pcm.length; i++) v.setInt16(44 + i * 2, Math.max(-32768, Math.min(32767, Math.round(pcm[i] * 32767))), true);
  return buf;
}
