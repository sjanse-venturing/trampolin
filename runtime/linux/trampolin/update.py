# update.py — actualizaciones automáticas desde las versiones publicadas en GitHub.
# Refleja src/Core/Trampolin.Update.psm1: mismas reglas (src/data/update.json), mismo paquete
# (el ZIP de build.sh / build.ps1) y misma verificación (el SHA-256 publicado junto al ZIP).
#
#   Consulta:  GET latestUrl (la última versión publicada; GitHub no incluye borradores ni versiones
#              de prueba). Se anota en update-state.json y no se repite antes de minCheckMinutes.
#   Instalar:  descarga el ZIP y su .sha256, los verifica, descomprime en una carpeta temporal y copia
#              el programa en <instalación>/app. Los juegos y las partidas no se tocan.
#
# Solo se actualiza la copia instalada (<instalación>/app, la que abren Steam y los accesos directos):
# una copia descomprimida o el repositorio no consultan nada.

import datetime
import hashlib
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

from . import core
from .errors import TrError, Cancelled, log

STATE_FILE = os.path.join(core.CONFIG_DIR, 'update-state.json')
USER_AGENT = 'TrampolinRuntime'
# Lo mínimo que tiene que traer un paquete para poder reemplazar la instalación.
REQUIRED = ('VERSION', 'trampolin.sh', 'Trampolin.cmd', 'linux/main.py', 'src/Trampolin.ps1', 'src/data/games.json',
            'native/bin/trlaunch.exe', 'native/bin/trhook.dll', 'native/bin/WING32.DLL')

_settings = None


def settings():
    global _settings
    if _settings is None:
        with open(os.path.join(core.DATA_DIR, 'update.json'), encoding='utf-8-sig') as f:
            _settings = json.load(f)
    return _settings


def latest_url():
    s = settings()
    return os.environ.get('TRAMPOLIN_UPDATE_URL') or s['latestUrl'].replace('{repo}', s['repo'])


def parse_version(text):
    """'1.2.0' o 'v1.2' → (1, 2, 0); None si no es una versión."""
    m = re.match(r'^\s*v?(\d+)\.(\d+)(?:\.(\d+))?\s*$', text or '')
    return tuple(int(x or 0) for x in m.groups()) if m else None


def format_version(v):
    return '.'.join(str(x) for x in v)


def version_of(app_root):
    """Versión de una copia del programa (su archivo VERSION); None si no se conoce."""
    try:
        with open(os.path.join(app_root, 'VERSION'), encoding='utf-8-sig') as f:
            return parse_version(f.readline())
    except OSError:
        return None


def is_installed_copy(root):
    return bool(root) and os.path.realpath(core.APP_ROOT) == os.path.realpath(os.path.join(root, 'app'))


class Release:
    def __init__(self, version, notes, zip_url, sha_url, page):
        self.version, self.notes, self.zip_url, self.sha_url, self.page = version, notes, zip_url, sha_url, page

    def to_dict(self):
        return {'version': self.version, 'notes': self.notes, 'zipUrl': self.zip_url, 'shaUrl': self.sha_url, 'page': self.page}

    @classmethod
    def from_dict(cls, d):
        if not isinstance(d, dict) or not parse_version(d.get('version')) or not d.get('zipUrl') or not d.get('shaUrl'):
            return None
        return cls(d['version'], str(d.get('notes') or ''), d['zipUrl'], d['shaUrl'], str(d.get('page') or ''))


def _get(url, timeout, limit):
    req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT, 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError('respuesta de más de %d bytes' % limit)
    return data


def parse_release(data):
    """Respuesta de la API de GitHub → Release, o None si no es una versión utilizable."""
    try:
        d = json.loads(data.decode('utf-8'))
    except ValueError:
        return None
    if not isinstance(d, dict) or d.get('draft') or d.get('prerelease'):
        return None
    v = parse_version(d.get('tag_name'))
    if not v:
        return None
    s, vs = settings(), format_version(v)
    assets = {a.get('name'): a.get('browser_download_url') for a in d.get('assets') or [] if isinstance(a, dict)}
    zip_url = assets.get(s['asset'].replace('{version}', vs))
    sha_url = assets.get(s['checksum'].replace('{version}', vs))
    if not zip_url or not sha_url:
        return None     # versión sin paquete (o todavía subiéndose)
    return Release(vs, str(d.get('body') or '')[:20000], zip_url, sha_url, str(d.get('html_url') or ''))


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def check(force=False, now=None):
    """Última versión publicada. Consulta GitHub como mucho cada minCheckMinutes; sin red, devuelve la
    última conocida. None si no hay ninguna (o están desactivadas)."""
    if os.environ.get('TRAMPOLIN_NO_UPDATE'):
        return None
    s = settings()
    now = now or _now()
    st = core.read_json(STATE_FILE) or {}
    cached = Release.from_dict(st.get('latest'))
    try:
        last = datetime.datetime.strptime(st.get('checkedAt') or '', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        last = None
    if not force and last and datetime.timedelta(0) <= now - last < datetime.timedelta(minutes=s['minCheckMinutes']):
        return cached
    try:
        rel = parse_release(_get(latest_url(), s['timeoutSeconds'], 1024 * 1024))
    except urllib.error.HTTPError as e:
        e.close()
        if e.code != 404:       # 404: todavía no hay versiones publicadas
            log('Warn', 'No se pudo consultar si hay actualizaciones: HTTP %s' % e.code)
            return cached
        rel = None
    except (urllib.error.URLError, socket.timeout, OSError, ValueError) as e:
        log('Info', 'No se pudo consultar si hay actualizaciones: %s' % getattr(e, 'reason', e))
        return cached
    try:
        core.write_json(STATE_FILE, {'checkedAt': now.strftime('%Y-%m-%dT%H:%M:%SZ'), 'latest': rel.to_dict() if rel else None})
    except OSError as e:
        log('Warn', 'No se pudo guardar update-state.json: %s' % e)
    return rel


def pending(root):
    """La versión publicada, si esta copia es la instalada y la publicada es más nueva; si no, None."""
    if not is_installed_copy(root):
        return None
    rel = check()
    if rel is None:
        return None
    current = version_of(core.APP_ROOT)
    return rel if current is None or parse_version(rel.version) > current else None


def _download(url, path, s, progress, cancel):
    req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    limit = s['maxZipBytes']
    with urllib.request.urlopen(req, timeout=s['downloadTimeoutSeconds']) as r, open(path, 'wb') as out:
        total = int(r.headers.get('Content-Length') or 0)
        done = 0
        while True:
            if cancel is not None and cancel.is_set():
                raise Cancelled()
            chunk = r.read(65536)
            if not chunk:
                break
            done += len(chunk)
            if done > limit:
                raise ValueError('el paquete pesa más de %d bytes' % limit)
            out.write(chunk)
            if total:
                progress(min(85, int(done * 85 / total)), 'Descargando… %s de %s' % (core.format_size(done), core.format_size(total)))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def extract(zip_path, version, dest):
    """Valida el paquete (carpeta TrampolinRuntime-<versión>/, sin rutas raras, con los archivos necesarios
    y la versión correcta) y lo descomprime en dest. Devuelve la carpeta del programa."""
    prefix = 'TrampolinRuntime-%s/' % version

    def bad(reason):
        return TrError('TR-UPD-002', version=version, reason=reason)

    try:
        z = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, OSError):
        raise bad('no es un ZIP válido')
    with z:
        names, total = set(), 0
        for i in z.infolist():
            n = i.filename
            if not n.startswith(prefix):
                raise bad('tiene archivos fuera de la carpeta del programa')
            rel = n[len(prefix):]
            if rel and ('\\' in n or ':' in rel or any(p in ('', '.', '..') for p in rel.rstrip('/').split('/'))):
                raise bad('tiene rutas no permitidas')
            if (i.external_attr >> 16) & 0o170000 == 0o120000:
                raise bad('tiene enlaces simbólicos')
            total += i.file_size
            if not i.is_dir():
                names.add(rel)
        if total > 4 * settings()['maxZipBytes']:
            raise bad('es demasiado grande')
        missing = [r for r in REQUIRED if r not in names]
        if missing:
            raise bad('le faltan archivos: %s' % ', '.join(missing))
        text = z.read(prefix + 'VERSION').decode('utf-8-sig', 'replace').strip()
        if parse_version(text) != parse_version(version):
            raise bad('la versión del paquete no coincide')
        z.extractall(dest)
    return os.path.join(dest, prefix.rstrip('/'))


def install(release, root, progress=None, cancel=None):
    """Descarga, verifica e instala una versión en <root>/app. Devuelve la versión instalada."""
    s, v = settings(), release.version
    progress = progress or (lambda p, text='': None)
    work = tempfile.mkdtemp(prefix='trampolin-update-')
    try:
        progress(None, 'Descargando Trampolín %s…' % v)
        zip_path = os.path.join(work, 'paquete.zip')
        try:
            sha_text = _get(release.sha_url, s['timeoutSeconds'], 4096).decode('ascii', 'replace')
            _download(release.zip_url, zip_path, s, progress, cancel)
        except (urllib.error.URLError, socket.timeout, OSError, ValueError) as e:
            raise TrError('TR-UPD-001', e, version=v, detail=str(getattr(e, 'reason', e)))
        progress(88, 'Verificando…')
        m = re.match(r'^\s*([0-9a-fA-F]{64})\b', sha_text)
        if not m:
            raise TrError('TR-UPD-002', version=v, reason='no se publicó la suma de verificación')
        if sha256_file(zip_path) != m.group(1).lower():
            raise TrError('TR-UPD-002', version=v, reason='la suma de verificación no coincide')
        src = extract(zip_path, v, os.path.join(work, 'x'))
        if cancel is not None and cancel.is_set():
            raise Cancelled()
        progress(94, 'Instalando…')
        app = os.path.join(root, 'app')
        try:
            core.install_runtime_files(root, src)
        except OSError as e:
            raise TrError('TR-UPD-003', e, version=v, path=app, detail=str(e))
        log('Info', 'Trampolín actualizado a %s en %s' % (v, app))
        progress(100, 'Listo')
        return v
    finally:
        shutil.rmtree(work, ignore_errors=True)


def relaunch(root, argv):
    """Reemplaza este proceso por la versión instalada, con los mismos argumentos (no vuelve)."""
    main = os.path.join(root, 'app', 'linux', 'main.py')
    os.execv(sys.executable, [sys.executable, '-I', main] + list(argv))
