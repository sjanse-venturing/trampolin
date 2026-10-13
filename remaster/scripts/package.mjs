// Genera la versión portable de Trampolín Remaster (carpeta + .zip) en release/.
// Uso: npm run package
import { packager } from '@electron/packager';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'release');
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

const [appDir] = await packager({
  dir: root,
  out,
  name: 'Trampolin Remaster',
  executableName: 'Trampolin Remaster',
  platform: 'win32',
  arch: 'x64',
  overwrite: true,
  prune: true,
  asar: true,
  appVersion: pkg.version,
  win32metadata: { ProductName: 'Trampolín Remaster', FileDescription: 'Trampolín Remaster', CompanyName: 'Trampolín Remaster' },
  ignore: [/^\/(src|test|scripts|release|logs)(\/|$)/, /\.map$/, /^\/tsconfig\.json$/],
});

const zip = join(out, `TrampolinRemaster-${pkg.version}-portable.zip`);
if (existsSync(zip)) rmSync(zip);
execFileSync('powershell.exe', ['-NoProfile', '-Command', `Compress-Archive -Path '${appDir}\\*' -DestinationPath '${zip}'`], { stdio: 'inherit' });
console.log(`Listo: ${zip}`);
