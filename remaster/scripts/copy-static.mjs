// Copia los archivos no-TypeScript (HTML, CSS, preload) a dist/ después de compilar.
import { cpSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const copies = [
  ['src/renderer/index.html', 'dist/renderer/index.html'],
  ['src/renderer/styles.css', 'dist/renderer/styles.css'],
  ['src/preload/preload.cjs', 'dist/preload/preload.cjs'],
];
for (const [from, to] of copies) {
  mkdirSync(dirname(join(root, to)), { recursive: true });
  cpSync(join(root, from), join(root, to));
}
console.log('Archivos estáticos copiados.');
