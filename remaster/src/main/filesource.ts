import { open, FileHandle } from 'node:fs/promises';
import { RandomAccess } from '../formats/binary.js';

/** Archivo del disco como fuente de acceso aleatorio (lecturas por rango, sin cargarlo entero). */
export class FileSource implements RandomAccess {
  private constructor(private readonly fh: FileHandle, readonly size: number, readonly path: string) {}

  static async open(path: string): Promise<FileSource> {
    const fh = await open(path, 'r');
    const st = await fh.stat();
    return new FileSource(fh, st.size, path);
  }

  async read(offset: number, length: number): Promise<Uint8Array> {
    const buf = Buffer.alloc(length);
    let done = 0;
    while (done < length) {
      const { bytesRead } = await this.fh.read(buf, done, length - done, offset + done);
      if (bytesRead === 0) throw new Error(`Fin de archivo inesperado en ${this.path}`);
      done += bytesRead;
    }
    return new Uint8Array(buf.buffer, buf.byteOffset, buf.length);
  }

  close(): Promise<void> {
    return this.fh.close();
  }
}
