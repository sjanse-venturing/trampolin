# core.py — lógica de Trampolín Runtime para Linux / Steam Deck (sin interfaz gráfica).
# Refleja src/Core/Trampolin.Core.psm1: mismas recetas (games.json), mismo manifiesto y
# mismo formato de copias de partidas, para poder pasarlas entre Windows y Linux.

import datetime
import fnmatch
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import zipfile

from . import errors
from .errors import TrError, Cancelled, log
from .iso import Iso

# runtime/ (repositorio) o <instalación>/app (instalado): contiene src/data, native/bin y linux/.
APP_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA_DIR = os.path.join(APP_ROOT, 'src', 'data')
CONFIG_DIR = os.path.join(os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share'), 'trampolin')
CONFIG_FILE = os.path.join(CONFIG_DIR, 'config.json')

# Dentro del prefijo de Wine los juegos ven la instalación como C:\Trampolin (ruta corta y ANSI,
# como pide el motor KA-MFC) y el disco como la unidad R: (Proton reserva S: y T: y borra esos enlaces).
WIN_ROOT = 'C:\\Trampolin'
CD_LETTER = 'R'

SAVES_MANIFEST = 'trampolin-saves.json'
SAVES_FORMAT = 1
NEVER_SAVE = {'~~ka.swp'}

_catalog = None


# ---------------------------------------------------------------------------
# Rutas y configuración
# ---------------------------------------------------------------------------

def native_bin():
    for c in (os.path.join(APP_ROOT, 'native', 'bin'), os.path.join(APP_ROOT, 'bin')):
        if os.path.exists(os.path.join(c, 'trlaunch.exe')):
            return c
    return os.path.join(APP_ROOT, 'native', 'bin')


def catalog():
    global _catalog
    if _catalog is None:
        with open(os.path.join(DATA_DIR, 'games.json'), encoding='utf-8-sig') as f:
            _catalog = sorted(json.load(f)['games'], key=lambda g: g['order'])
    return _catalog


def game(gid):
    for g in catalog():
        if g['id'] == gid:
            return g
    raise KeyError('Juego desconocido: %s' % gid)


def find_game_id(text):
    """ID del catálogo sin distinguir mayúsculas (o None)."""
    for g in catalog():
        if g['id'].lower() == text.lower():
            return g['id']
    return None


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        log('Warn', 'JSON ilegible (%s): %s' % (path, e))
        return default


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def get_config():
    cfg = read_json(CONFIG_FILE) or {}
    defaults = {'installRoot': None, 'isoFolder': None, 'dataMode': 'copy', 'scale': 0, 'proton': None,
                'steamShortcuts': True, 'menuShortcuts': True}
    for k, v in defaults.items():
        if cfg.get(k) is None:
            cfg[k] = v
    return cfg


def save_config(cfg):
    write_json(CONFIG_FILE, cfg)


def default_install_root():
    return os.path.expanduser('~/Trampolin')


def default_iso_folder():
    for c in (xdg_dir('DOWNLOAD', '~/Downloads'), os.path.expanduser('~')):
        if os.path.isdir(c):
            return c
    return os.path.expanduser('~')


def xdg_dir(kind, fallback):
    try:
        out = subprocess.run(['xdg-user-dir', kind], capture_output=True, text=True, timeout=5).stdout.strip()
        if out and out != os.path.expanduser('~'):
            return out
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.expanduser(fallback)


def saves_dir():
    """Carpeta de copias de partidas (como Documentos\\Trampolín - partidas en Windows)."""
    return os.path.join(xdg_dir('DOCUMENTS', '~/Documents'), 'Trampolín - partidas')


def get_manifest(root):
    m = read_json(os.path.join(root, 'manifest.json')) or {'version': 1, 'games': {}}
    if not m.get('games'):
        m['games'] = {}
    return m


def save_manifest(root, m):
    write_json(os.path.join(root, 'manifest.json'), m)


def format_size(n):
    if n >= 1 << 30:
        return ('%.1f GB' % (n / (1 << 30))).replace('.', ',')
    return '%d MB' % -(-n // (1 << 20))


# ---------------------------------------------------------------------------
# Requisitos previos
# ---------------------------------------------------------------------------

class Check:
    def __init__(self, name, ok, blocking, detail):
        self.name, self.ok, self.blocking, self.detail = name, ok, blocking, detail


def prerequisites(cfg=None):
    from . import proton
    items = [Check('Python 3.9 o superior', sys.version_info >= (3, 9), True, 'Python %d.%d' % sys.version_info[:2])]
    b = native_bin()
    missing = [f for f in ('trlaunch.exe', 'trhook.dll', 'WING32.DLL') if not os.path.exists(os.path.join(b, f))]
    items.append(Check('Componentes de compatibilidad', not missing, True, 'Faltan: ' + ', '.join(missing) if missing else b))
    p = proton.select(cfg)
    items.append(Check('Proton (Steam)', p is not None, True,
                       p.name if p else 'No se encontró Proton. Instalá «Proton 10.0» desde la biblioteca de Steam (Herramientas).'))
    if p is not None and not p.recommended:
        items.append(Check('Proton recomendado (%s)' % ', '.join(proton.RECOMMENDED), False, False,
                           'Instalalo desde Steam (Biblioteca → Herramientas): con %s algunos juegos pueden quedar en negro.' % p.name))
    items.append(Check('Steam', bool(proton.steam_roots()), False,
                       'Instalado' if proton.steam_roots() else 'No se encontró: no se podrán agregar accesos a Steam'))
    return items


# ---------------------------------------------------------------------------
# Discos (ISO)
# ---------------------------------------------------------------------------

class FoundIso:
    def __init__(self, path):
        self.game_id = None
        self.path = path
        self.name = os.path.basename(path)
        self.size = os.path.getsize(path)
        self.label = None
        self.status = 'unknown'
        self.message = ''


def find_isos(folder):
    """Busca imágenes de los juegos en una carpeta (y un nivel de subcarpetas). Devuelve (isos, zips)."""
    if not folder or not os.path.isdir(folder):
        raise TrError('TR-ISO-001', path=folder)
    files, zips = [], []
    for name in sorted(os.listdir(folder)):
        p = os.path.join(folder, name)
        if os.path.isfile(p) and name.lower().endswith('.iso'):
            files.append(p)
        elif os.path.isfile(p) and name.lower().endswith('.zip'):
            zips.append(p)
        elif os.path.isdir(p):
            try:
                files += [os.path.join(p, n) for n in sorted(os.listdir(p))
                          if n.lower().endswith('.iso') and os.path.isfile(os.path.join(p, n))]
            except OSError:
                pass
    result = []
    for path in files:
        e = FoundIso(path)
        g = next((g for g in catalog() if g['iso']['size'] == e.size), None) or \
            next((g for g in catalog() if g['iso']['file'] == e.name), None)
        try:
            with Iso(path) as iso:
                e.label = iso.volume_label
                if g is None:
                    g = next((c for c in catalog() if iso.find(c['iso']['keyFile'])), None)
                if g is not None:
                    e.game_id = g['id']
                    if iso.find(g['iso']['keyFile']):
                        e.status = 'ok'
                        if e.size != g['iso']['size']:
                            e.message = 'Edición distinta de la probada; probablemente funcione.'
                    else:
                        e.status, e.message = 'invalid', 'Falta un archivo clave del juego.'
                else:
                    e.message = 'No corresponde a ningún juego Trampolín conocido.'
        except Exception as ex:
            e.status, e.message = 'invalid', 'No se pudo leer: %s' % ex
        result.append(e)
    return result, zips


def expand_zip_isos(zip_path, destination, on_progress=None, cancel=None):
    """Extrae las imágenes .iso de un ZIP (por ejemplo trampolin_anaya.zip)."""
    os.makedirs(destination, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        entries = [i for i in z.infolist() if i.filename.lower().endswith('.iso')]
        total = sum(i.file_size for i in entries) or 1
        done = 0
        for i in entries:
            target = os.path.join(destination, os.path.basename(i.filename.replace('\\', '/')))
            if os.path.exists(target) and os.path.getsize(target) == i.file_size:
                done += i.file_size
                continue
            with z.open(i) as src, open(target, 'wb') as out:
                while True:
                    if cancel is not None and cancel.is_set():
                        raise Cancelled()
                    buf = src.read(1 << 20)
                    if not buf:
                        break
                    out.write(buf)
                    done += len(buf)
                    if on_progress:
                        on_progress(int(100 * done / total), 'Extrayendo %s…' % os.path.basename(target))


# ---------------------------------------------------------------------------
# Carpeta de instalación
# ---------------------------------------------------------------------------

def required_bytes(game_ids):
    """Espacio necesario aproximado (en Linux siempre se copia el disco completo)."""
    return sum(15 * (1 << 20) + game(i)['iso']['size'] for i in game_ids) + 300 * (1 << 20)   # + prefijo de Proton


def test_install_root(path, required=0):
    """Lanza un error del catálogo si la carpeta no sirve. Devuelve la ruta normalizada.
    En Linux los juegos ven siempre C:\\Trampolin, así que no hay límites de longitud ni de caracteres."""
    full = os.path.abspath(os.path.expanduser(path)).rstrip('/') or '/'
    try:
        os.makedirs(full, exist_ok=True)
        probe = os.path.join(full, '.trampolin-probe.tmp')
        with open(probe, 'w') as f:
            f.write('ok')
        os.remove(probe)
        link = os.path.join(full, '.trampolin-link.tmp')
        os.symlink('.', link)
        os.remove(link)
    except OSError as e:
        raise TrError('TR-DSK-002', e, path=full)
    if required > 0:
        free = shutil.disk_usage(full).free
        if free < required:
            raise TrError('TR-DSK-001', drive=full, need=format_size(required), free=format_size(free))
    return full


# ---------------------------------------------------------------------------
# INI (en ANSI, como los leen los juegos)
# ---------------------------------------------------------------------------

def expand_template(text, variables):
    if text is None:
        return text
    for k, v in variables.items():
        text = text.replace('{' + k + '}', str(v))
    return text


def set_ini_values(path, values, variables=None):
    """Fusiona secciones/claves en un INI conservando el resto del contenido (cp1252, CRLF)."""
    variables = variables or {}
    lines = []
    if os.path.exists(path):
        with open(path, 'rb') as f:
            lines = f.read().decode('cp1252', 'replace').splitlines()
        make_writable(path)
    for section, kv in values.items():
        start = next((i for i, l in enumerate(lines) if l.strip().lower() == '[%s]' % section.lower()), -1)
        if start < 0:
            if lines and lines[-1].strip():
                lines.append('')
            lines.append('[%s]' % section)
            start = len(lines) - 1
        for key, value in kv.items():
            value = expand_template(str(value), variables)
            end = next((i for i in range(start + 1, len(lines)) if lines[i].strip().startswith('[')), len(lines))
            for i in range(start + 1, end):
                eq = lines[i].find('=')
                if eq > 0 and lines[i][:eq].strip().lower() == key.lower():
                    lines[i] = '%s=%s' % (key, value)
                    break
            else:
                insert = end
                while insert > start + 1 and not lines[insert - 1].strip():
                    insert -= 1
                lines.insert(insert, '%s=%s' % (key, value))
    with open(path, 'wb') as f:
        f.write(''.join(l + '\r\n' for l in lines).encode('cp1252', 'replace'))


def make_writable(path):
    try:
        os.chmod(path, os.stat(path).st_mode | stat.S_IWUSR)
    except OSError:
        pass


def repair_section_sizes(path):
    """WSOUND32.DLL (Watcom) declara secciones con tamaño virtual 0; Windows 95 las mapeaba hasta la
    sección siguiente y la DLL usa esa memoria. Se completa el tamaño de cada sección (ver la versión de
    Windows, Repair-TrSectionSizes). Devuelve True si modificó el archivo."""
    with open(path, 'rb') as f:
        b = bytearray(f.read())
    if len(b) < 0x40 or b[0:2] != b'MZ':
        return False
    pe = struct.unpack_from('<i', b, 0x3C)[0]
    if pe <= 0 or pe + 24 > len(b) or struct.unpack_from('<I', b, pe)[0] != 0x4550:
        return False
    count = struct.unpack_from('<H', b, pe + 6)[0]
    table = pe + 24 + struct.unpack_from('<H', b, pe + 20)[0]
    size_of_image = struct.unpack_from('<I', b, pe + 24 + 56)[0]
    changed = False
    for i in range(count):
        h = table + 40 * i
        if struct.unpack_from('<I', b, h + 8)[0] != 0:
            continue
        va = struct.unpack_from('<I', b, h + 12)[0]
        nxt = struct.unpack_from('<I', b, h + 40 + 12)[0] if i + 1 < count else size_of_image
        if nxt <= va:
            continue
        struct.pack_into('<I', b, h + 8, nxt - va)
        changed = True
    if changed:
        make_writable(path)
        with open(path, 'wb') as f:
            f.write(b)
    return changed


def win_hd(gid):
    return '%s\\games\\%s' % (WIN_ROOT, gid)


def game_vars(gid, label):
    return {'HD': win_hd(gid), 'CD': CD_LETTER + ':', 'LABEL': label or ''}


def write_game_config(g, root, variables):
    """Escribe el INI propio del juego y su sección de KA.INI con las rutas que ve el juego."""
    hd = os.path.join(root, 'games', g['id'])
    for file, values in (g.get('ini') or {}).items():
        set_ini_values(os.path.join(hd, find_case(hd, file)), values, variables)
    if g.get('kaIni'):
        set_ini_values(os.path.join(root, 'games', 'KA.INI'), g['kaIni'], variables)
    wsound = os.path.join(hd, find_case(hd, 'WSOUND32.DLL'))
    if os.path.exists(wsound) and repair_section_sizes(wsound):
        log('Info', 'WSOUND32.DLL de %s: secciones completadas como en Windows 95' % g['id'])


def find_case(folder, name):
    """Nombre real de un archivo en la carpeta sin distinguir mayúsculas (o el mismo nombre si no existe)."""
    try:
        for n in os.listdir(folder):
            if n.lower() == name.lower():
                return n
    except OSError:
        pass
    return name


# ---------------------------------------------------------------------------
# Copia de archivos desde la ISO
# ---------------------------------------------------------------------------

def _excluded(rel, exclude):
    p = '\\' + rel.lower() + '\\'
    return any(('\\' + x.lower() + '\\') in p for x in exclude)


def copy_from_iso(iso_path, destination, sources=(), exclude=(), on_bytes=None, cancel=None):
    """Copia desde la ISO: cada carpeta de sources se copia «aplanada» en destination.
    Con sources vacío copia el disco entero."""
    copied = 0
    with Iso(iso_path) as iso:
        jobs = []
        if not sources:
            jobs = [(e, e.path) for e in iso.list('')]
        else:
            for src in sources:
                prefix = src.strip('\\') + '\\'
                jobs += [(e, e.path[len(prefix):]) for e in iso.list(src)]
        for e, rel in jobs:
            if _excluded(rel, exclude):
                continue
            if cancel is not None and cancel.is_set():
                raise Cancelled()
            target = os.path.join(destination, *rel.split('\\'))
            if e.is_dir:
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.exists(target) and os.path.getsize(target) == e.size:
                copied += e.size
            else:
                if os.path.exists(target):
                    make_writable(target)
                try:
                    copied += iso.extract(e, target, cancel)
                except PermissionError as ex:
                    raise TrError('TR-CPY-002', ex, file=rel)
                except (OSError, EOFError) as ex:
                    raise TrError('TR-CPY-001', ex, game=os.path.basename(iso_path), file=rel)
            if on_bytes:
                on_bytes(e.size, rel)
    return copied


def copy_size(iso_path, sources=()):
    with Iso(iso_path) as iso:
        if not sources:
            return sum(e.size for e in iso.list(''))
        return sum(e.size for s in sources for e in iso.list(s))


# ---------------------------------------------------------------------------
# Instalación del runtime y de los juegos
# ---------------------------------------------------------------------------

def install_runtime_files(root):
    """Copia el programa a <root>/app para que la instalación no dependa de la carpeta de descarga."""
    app = os.path.join(root, 'app')
    if os.path.realpath(APP_ROOT) == os.path.realpath(app):
        return app
    ignore = shutil.ignore_patterns('__pycache__', '*.pyc')
    for sub in ('src', 'linux'):
        shutil.copytree(os.path.join(APP_ROOT, sub), os.path.join(app, sub), dirs_exist_ok=True, ignore=ignore)
    os.makedirs(os.path.join(app, 'native', 'bin'), exist_ok=True)
    for f in ('trlaunch.exe', 'trhook.dll', 'WING32.DLL'):
        shutil.copy2(os.path.join(native_bin(), f), os.path.join(app, 'native', 'bin', f))
    for f in ('trampolin.sh', 'Trampolin.cmd', 'LEEME-RUNTIME.md'):
        p = os.path.join(APP_ROOT, f)
        if os.path.exists(p):
            shutil.copy2(p, os.path.join(app, f))
    sh = os.path.join(app, 'trampolin.sh')
    if os.path.exists(sh):
        os.chmod(sh, 0o755)
    doc = os.path.join(APP_ROOT, 'LEEME-RUNTIME.md')
    if os.path.exists(doc):
        shutil.copy2(doc, os.path.join(root, 'LEEME-RUNTIME.md'))
    return app


def launcher_script(root):
    """Script que usan los accesos directos: el instalado si existe, si no el de esta copia del programa."""
    p = os.path.join(root, 'app', 'trampolin.sh')
    return p if os.path.exists(p) else os.path.join(APP_ROOT, 'trampolin.sh')


def install_game(gid, iso_path, root, on_progress=None, cancel=None, repair=False):
    """Instala (o repara) un juego. on_progress recibe (porcentaje, texto).
    En Linux siempre se copia el disco completo a <root>/cd/<ID> (montar una ISO requiere root)."""
    g = game(gid)
    hd = os.path.join(root, 'games', gid)
    cd = os.path.join(root, 'cd', gid)
    existed = os.path.exists(hd)
    progress = on_progress or (lambda p, t: None)

    def rollback():
        if not existed and not repair:
            shutil.rmtree(hd, ignore_errors=True)
            shutil.rmtree(cd, ignore_errors=True)

    def action():
        progress(0, 'Preparando %s…' % g['name'])
        with Iso(iso_path) as iso:
            label = iso.volume_label
            if not iso.find(g['iso']['keyFile']):
                raise TrError('TR-ISO-002', file=os.path.basename(iso_path))
        sources = list(g['copy'])
        total = max(1, copy_size(iso_path, sources) + copy_size(iso_path))
        counter = [0]

        def on_bytes(n, rel):
            counter[0] += n
            progress(int(95 * counter[0] / total), 'Copiando %s: %s' % (g['name'], rel))

        os.makedirs(hd, exist_ok=True)
        copy_from_iso(iso_path, hd, sources, g.get('exclude') or [], on_bytes, cancel)
        os.makedirs(cd, exist_ok=True)
        copy_from_iso(iso_path, cd, (), (), on_bytes, cancel)
        progress(96, 'Aplicando la capa de compatibilidad…')
        dst = os.path.join(hd, find_case(hd, 'WING32.DLL'))
        if os.path.exists(dst):
            make_writable(dst)
        shutil.copyfile(os.path.join(native_bin(), 'WING32.DLL'), dst)
        for base, dirs, files in os.walk(hd):
            for n in files:
                make_writable(os.path.join(base, n))
        m = get_manifest(root)
        m['games'][gid] = {'id': gid, 'name': g['name'], 'dataMode': 'copy', 'isoPath': iso_path, 'label': label,
                           'hd': hd, 'cd': cd, 'installedAt': datetime.datetime.now().isoformat(timespec='seconds')}
        save_manifest(root, m)
        progress(100, '%s: listo.' % g['name'])

    errors.step('Instalar ' + gid, action, 'TR-CPY-001', rollback, game=g['name'], file='')


class InstalledGame:
    def __init__(self, g, entry):
        self.id, self.name, self.age, self.engine = g['id'], g['name'], g['age'], g['engine']
        self.entry = entry
        self.healthy = os.path.exists(os.path.join(entry['hd'], find_case(entry['hd'], g['exe'])))
        self.icon_exe = os.path.join(entry['hd'], find_case(entry['hd'], g['icon']))


def installed_games(root):
    if not root:
        return []
    m = get_manifest(root)
    return [InstalledGame(g, m['games'][g['id']]) for g in catalog() if g['id'] in m['games']]


def uninstall_game(gid, root, keep_saves=True):
    g = game(gid)

    def action():
        backup = backup_saves(gid, root) if keep_saves else None
        shutil.rmtree(os.path.join(root, 'games', gid))
        shutil.rmtree(os.path.join(root, 'cd', gid), ignore_errors=True)
        m = get_manifest(root)
        m['games'].pop(gid, None)
        save_manifest(root, m)
        return backup

    return errors.step('Desinstalar ' + gid, action, 'TR-CFG-001', game=g['name'])


# ---------------------------------------------------------------------------
# Partidas: copia de seguridad, exportación e importación
# (mismo formato que Backup-TrSaves / Export-TrAllSaves / Import-TrSaves de Windows)
# ---------------------------------------------------------------------------

def is_save_name(g, name):
    """¿Es un nombre de archivo de partida de este juego? Solo nombres simples, sin rutas."""
    if not name or name in ('.', '..') or '/' in name or '\\' in name or ':' in name:
        return False
    low = name.lower()
    if low in NEVER_SAVE:
        return False
    return any(fnmatch.fnmatchcase(low, p.lower()) for p in g.get('saves') or [])


def save_files(gid, root):
    """Archivos de partidas de un juego instalado (rutas completas)."""
    g = game(gid)
    hd = os.path.join(root, 'games', gid)
    try:
        names = os.listdir(hd)
    except OSError:
        return []
    return sorted(os.path.join(hd, n) for n in names if is_save_name(g, n) and os.path.isfile(os.path.join(hd, n)))


def _saves_manifest(game_ids):
    return json.dumps({'format': SAVES_FORMAT, 'createdAt': datetime.datetime.now().isoformat(timespec='seconds'),
                       'platform': 'linux', 'games': game_ids}, ensure_ascii=False, indent=2)


def _timestamp():
    return datetime.datetime.now().strftime('%Y%m%d-%H%M%S')


def _unique(path):
    base, ext = os.path.splitext(path)
    n = 2
    while os.path.exists(path):
        path = '%s-%d%s' % (base, n, ext)
        n += 1
    return path


def backup_saves(gid, root, destination=None):
    """Comprime las partidas de un juego (archivos sueltos, como en Windows). Devuelve la ruta del zip o None."""
    files = save_files(gid, root)
    if not files:
        return None
    dest = destination or saves_dir()
    os.makedirs(dest, exist_ok=True)
    path = _unique(os.path.join(dest, '%s-%s.zip' % (gid, _timestamp())))
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr(SAVES_MANIFEST, _saves_manifest([gid]))
        for f in files:
            z.write(f, os.path.basename(f))
    log('Info', 'Copia de partidas de %s: %s' % (gid, path))
    return path


def export_all_saves(root, destination=None):
    """Un solo zip con una carpeta por juego (<ID>/<archivo>). Devuelve la ruta o None si no hay partidas."""
    per_game = [(ig.id, save_files(ig.id, root)) for ig in installed_games(root)]
    per_game = [(gid, files) for gid, files in per_game if files]
    if not per_game:
        return None
    dest = destination or saves_dir()
    os.makedirs(dest, exist_ok=True)
    path = _unique(os.path.join(dest, 'trampolin-partidas-%s.zip' % _timestamp()))
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr(SAVES_MANIFEST, _saves_manifest([gid for gid, _ in per_game]))
        for gid, files in per_game:
            for f in files:
                z.write(f, '%s/%s' % (gid, os.path.basename(f)))
    log('Info', 'Exportación de todas las partidas: %s' % path)
    return path


def read_saves_zip(zip_path):
    """Analiza un zip de partidas. Devuelve {ID: {nombre: ZipInfo}} y la lista de entradas ignoradas.
    Acepta el formato «todas» (<ID>/<archivo>) y el de un juego (archivos sueltos; el ID sale del
    trampolin-saves.json o del nombre del zip, <ID>-AAAAMMDD-HHMMSS.zip)."""
    try:
        z = zipfile.ZipFile(zip_path)
    except (OSError, zipfile.BadZipFile) as e:
        raise TrError('TR-SAV-001', e, file=os.path.basename(zip_path))
    with z:
        meta = {}
        names = {i.filename.replace('\\', '/'): i for i in z.infolist() if not i.is_dir()}
        if SAVES_MANIFEST in names:
            try:
                meta = json.loads(z.read(names.pop(SAVES_MANIFEST)).decode('utf-8-sig'))
            except ValueError:
                meta = {}
        flat_id = None
        meta_games = [find_game_id(x) for x in meta.get('games') or [] if find_game_id(x)]
        if len(meta_games) == 1:
            flat_id = meta_games[0]
        else:
            m = re.match(r'^(.+?)-\d{8}-\d{6}(-\d+)?\.zip$', os.path.basename(zip_path), re.I)
            if m:
                flat_id = find_game_id(m.group(1))
        result, ignored = {}, []
        for name, info in names.items():
            parts = name.split('/')
            if len(parts) == 1:
                gid, fname = flat_id, parts[0]
            elif len(parts) == 2:
                gid, fname = find_game_id(parts[0]), parts[1]
            else:
                gid, fname = None, name
            if gid is None or not is_save_name(game(gid), fname):
                ignored.append(name)
                continue
            result.setdefault(gid, {})
            if fname.lower() in (n.lower() for n in result[gid]):
                ignored.append(name)
                continue
            result[gid][fname] = info
    if not result:
        raise TrError('TR-SAV-001', file=os.path.basename(zip_path))
    return result, ignored


class ImportResult:
    def __init__(self):
        self.imported = {}   # ID -> [archivos]
        self.skipped = {}    # ID -> motivo
        self.backups = []    # zips con las partidas que había antes
        self.ignored = []    # entradas del zip que no son partidas


def running_game(root):
    """PID de un juego de Trampolín en ejecución (busca su ejecutable en la línea de comandos), o None."""
    needle = ('%s\\games\\' % WIN_ROOT).lower().encode()
    needle2 = os.path.join(root, 'games', '').lower().encode() if root else None
    for pid in os.listdir('/proc'):
        if not pid.isdigit():
            continue
        try:
            with open('/proc/%s/cmdline' % pid, 'rb') as f:
                cmd = f.read().lower()
        except OSError:
            continue
        if needle in cmd or (needle2 and needle2 in cmd and b'.exe' in cmd):
            return int(pid)
    return None


def import_saves(root, zip_path, backup_destination=None):
    """Importa partidas desde un zip (de Windows o Linux). Antes guarda una copia de las partidas actuales
    de cada juego afectado, y reemplaza sus archivos de partidas por los del zip."""
    content, ignored = read_saves_zip(zip_path)
    if running_game(root):
        raise TrError('TR-RUN-001')
    res = ImportResult()
    res.ignored = ignored
    installed = {ig.id for ig in installed_games(root) if ig.healthy}

    def action():
        with zipfile.ZipFile(zip_path) as z:
            for gid in [g['id'] for g in catalog() if g['id'] in content]:
                if gid not in installed:
                    res.skipped[gid] = 'no está instalado'
                    continue
                hd = os.path.join(root, 'games', gid)
                b = backup_saves(gid, root, backup_destination)
                if b:
                    res.backups.append(b)
                for f in save_files(gid, root):
                    make_writable(f)
                    os.remove(f)
                for fname, info in content[gid].items():
                    tmp = os.path.join(hd, '.%s.tmp' % fname)
                    with z.open(info) as src, open(tmp, 'wb') as out:
                        shutil.copyfileobj(src, out)
                    t = datetime.datetime(*info.date_time).timestamp()
                    os.utime(tmp, (t, t))
                    os.replace(tmp, os.path.join(hd, fname))
                res.imported[gid] = sorted(content[gid])
                log('Info', 'Partidas importadas en %s: %s' % (gid, ', '.join(res.imported[gid])))
        return res

    return errors.step('Importar partidas ' + os.path.basename(zip_path), action, 'TR-SAV-002',
                       file=os.path.basename(zip_path))
