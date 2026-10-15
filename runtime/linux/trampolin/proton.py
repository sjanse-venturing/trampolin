# proton.py — ejecutar los juegos con Proton (Wine de Steam) en Linux / Steam Deck.
#
# Prefijo propio en <root>/proton/pfx. Dentro de él:
#   C:\Trampolin\{games,cd,logs}  -> enlaces a <root>/{games,cd,logs}  (rutas cortas y ANSI)
#   R:                            -> enlace a <root>/cd/<ID> del juego que se lanza (Proton reserva S: y T:)
# Se usan los mismos trlaunch.exe / trhook.dll / WING32.DLL que en Windows; trhook informa
# a R: como CD con la etiqueta original (TRAMPOLIN_CDDRIVE / TRAMPOLIN_CDLABEL).

import glob
import os
import re
import subprocess
import time

from . import core
from .errors import TrError, log


# ---------------------------------------------------------------------------
# Steam y versiones de Proton
# ---------------------------------------------------------------------------

def steam_roots():
    roots = []
    for c in ('~/.local/share/Steam', '~/.steam/steam', '~/.steam/root',
              '~/.var/app/com.valvesoftware.Steam/data/Steam'):
        p = os.path.realpath(os.path.expanduser(c))
        if os.path.isdir(os.path.join(p, 'steamapps')) and p not in roots:
            roots.append(p)
    return roots


def library_folders():
    libs = []
    for root in steam_roots():
        libs.append(root)
        vdf = os.path.join(root, 'steamapps', 'libraryfolders.vdf')
        try:
            with open(vdf, encoding='utf-8', errors='replace') as f:
                for m in re.finditer(r'"path"\s+"([^"]+)"', f.read()):
                    p = os.path.realpath(m.group(1).replace('\\\\', '\\'))
                    if p not in libs:
                        libs.append(p)
        except OSError:
            pass
    return libs


# Versiones probadas con los 8 juegos (2026-10-15). Con Proton 11.0 y Experimental los juegos KA-MFC
# (1° y 2° Ciclo, Infantil 2° Ciclo, 5° Curso) y 6° Curso quedan en negro: se prefiere la 10.0.
RECOMMENDED = ('Proton 10.0',)


class ProtonTool:
    def __init__(self, name, path):
        self.name = name
        self.path = path          # carpeta que contiene el script «proton»
        self.script = os.path.join(path, 'proton')

    @property
    def recommended(self):
        return self.name in RECOMMENDED

    def rank(self):
        if self.recommended:
            return (4, 0, 0)
        m = re.match(r'^Proton (\d+)\.(\d+)$', self.name)
        if m:
            return (3, int(m.group(1)), int(m.group(2)))
        if self.name == 'Proton - Experimental':
            return (2, 0, 0)
        m = re.match(r'^GE-Proton(\d+)-(\d+)$', self.name)
        if m:
            return (1, int(m.group(1)), int(m.group(2)))
        return (0, 0, 0)


def list_protons():
    found = {}
    dirs = [os.path.join(lib, 'steamapps', 'common', '*') for lib in library_folders()]
    dirs += [os.path.join(r, 'compatibilitytools.d', '*') for r in steam_roots()]
    dirs.append(os.path.expanduser('~/.steam/root/compatibilitytools.d/*'))
    for pattern in dirs:
        for d in glob.glob(pattern):
            if os.path.isfile(os.path.join(d, 'proton')) and os.path.basename(d) not in found:
                found[os.path.basename(d)] = ProtonTool(os.path.basename(d), d)
    return sorted(found.values(), key=lambda t: t.rank(), reverse=True)


def select(cfg=None):
    """La versión elegida en Opciones (nombre o ruta), la recomendada o la estable más nueva."""
    tools = list_protons()
    wanted = (cfg or {}).get('proton')
    if wanted:
        for t in tools:
            if wanted in (t.name, t.path):
                return t
        if os.path.isfile(os.path.join(wanted, 'proton')):
            return ProtonTool(os.path.basename(wanted), wanted)
    return tools[0] if tools else None


# ---------------------------------------------------------------------------
# Prefijo
# ---------------------------------------------------------------------------

def compat_dir(root):
    return os.path.join(root, 'proton')


def prefix_dir(root):
    return os.path.join(compat_dir(root), 'pfx')


def base_env(root, tool):
    env = dict(os.environ)
    env['STEAM_COMPAT_DATA_PATH'] = compat_dir(root)
    roots = steam_roots()
    env['STEAM_COMPAT_CLIENT_INSTALL_PATH'] = roots[0] if roots else os.path.expanduser('~/.local/share/Steam')
    env.setdefault('WINEDEBUG', '-all')
    overrides = [o for o in env.get('WINEDLLOVERRIDES', '').split(';') if o and not o.lower().startswith('wing32=')]
    # Diagnóstico: TRAMPOLIN_WING32=builtin usa la WinG de Wine en lugar de la propia.
    wing = 'b' if os.environ.get('TRAMPOLIN_WING32') == 'builtin' else 'n,b'
    env['WINEDLLOVERRIDES'] = ';'.join(['wing32=' + wing] + overrides)
    return env


def _relink(link, target):
    if os.path.islink(link):
        if os.readlink(link) == target:
            return
        os.remove(link)
    elif os.path.exists(link):
        raise OSError('%s existe y no es un enlace' % link)
    os.symlink(target, link)


def ensure_prefix(root, tool, on_progress=None):
    """Crea el prefijo de Proton la primera vez y arma C:\\Trampolin."""
    pfx = prefix_dir(root)
    if not os.path.isfile(os.path.join(pfx, 'system.reg')):
        if tool is None:
            raise TrError('TR-ENV-004')
        if on_progress:
            on_progress('Preparando la capa de compatibilidad (Proton). La primera vez tarda un poco…')
        os.makedirs(compat_dir(root), exist_ok=True)
        log('Info', 'Creando prefijo de Proton con %s en %s' % (tool.name, pfx))
        # Proton arma el prefijo antes de ejecutar el comando; basta uno que termine enseguida.
        r = subprocess.run([tool.script, 'run', 'reg.exe', 'query', 'HKCU\\Software\\Wine'], env=base_env(root, tool),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=600)
        log('Info', 'Prefijo creado (código %d): %s' % (r.returncode, r.stdout.decode('utf-8', 'replace')[-2000:]))
        if not os.path.isfile(os.path.join(pfx, 'system.reg')):
            raise TrError('TR-ENV-004')
    tr = os.path.join(pfx, 'drive_c', 'Trampolin')
    os.makedirs(tr, exist_ok=True)
    for sub in ('games', 'cd', 'logs'):
        os.makedirs(os.path.join(root, sub), exist_ok=True)
        _relink(os.path.join(tr, sub), os.path.join(root, sub))
    return pfx


# ---------------------------------------------------------------------------
# Lanzamiento
# ---------------------------------------------------------------------------

class Session:
    def __init__(self, gid, g, root):
        self.id, self.game, self.root = gid, g, root
        self.process = None
        self.started = None
        self.exit_code = None
        self.cd_link = None


def start_game(gid, root, cfg, on_progress=None):
    """Prepara la unidad R:, escribe la configuración y lanza el juego con Proton. Devuelve una Session."""
    g = core.game(gid)
    m = core.get_manifest(root)
    if gid not in m['games']:
        raise TrError('TR-RUN-006', game=g['name'])
    entry = m['games'][gid]
    hd = os.path.join(root, 'games', gid)
    exe = core.find_case(hd, g['exe'])
    if not os.path.exists(os.path.join(hd, exe)):
        raise TrError('TR-RUN-006', game=g['name'])
    cd = os.path.join(root, 'cd', gid)
    if not os.path.isdir(cd):
        raise TrError('TR-RUN-006', game=g['name'])
    if core.running_game(root):
        raise TrError('TR-RUN-001')
    tool = select(cfg)
    if tool is None:
        raise TrError('TR-ENV-004')

    session = Session(gid, g, root)
    pfx = ensure_prefix(root, tool, on_progress)
    session.cd_link = os.path.join(pfx, 'dosdevices', core.CD_LETTER.lower() + ':')
    _relink(session.cd_link, cd)
    label = entry.get('label') or ''
    variables = core.game_vars(gid, label)
    log('Info', 'Juego %s: datos en %s: (%r), carpeta %s, %s' % (gid, core.CD_LETTER, label, hd, tool.name))
    from . import errors
    errors.step('Configurar ' + gid, lambda: core.write_game_config(g, root, variables), 'TR-CFG-001', game=g['name'])

    logs = os.path.join(root, 'logs')
    os.makedirs(logs, exist_ok=True)
    game_log = os.path.join(logs, 'juego-%s.log' % gid)
    if os.path.exists(game_log):
        open(game_log, 'w').close()
    env = base_env(root, tool)
    win_hd = core.win_hd(gid)
    env.update({
        'TRAMPOLIN_LOG': '%s\\logs\\juego-%s.log' % (core.WIN_ROOT, gid),
        'TRAMPOLIN_TRACE': '1' if os.environ.get('TRAMPOLIN_TRACE') == '1' else '0',
        'TRAMPOLIN_KAINI': '%s\\games\\KA.INI' % core.WIN_ROOT,
        'TRAMPOLIN_SCALE': str(int(cfg.get('scale') or 0)),
        'TRAMPOLIN_SWAPDIR': win_hd,
        'TRAMPOLIN_CDDRIVE': core.CD_LETTER,
        'TRAMPOLIN_CDLABEL': label,
    })
    env.pop('TRAMPOLIN_QUIET', None)
    linux = g.get('linux') or {}
    env.update({k: str(v) for k, v in (linux.get('env') or {}).items()})

    args = [a for a in core.expand_template(g.get('args') or '', variables).split(' ') if a]
    cmd = [tool.script, 'run', os.path.join(core.native_bin(), 'trlaunch.exe')]
    if linux.get('nohook') or os.environ.get('TRAMPOLIN_NOHOOK') == '1':   # diagnóstico
        cmd.append('--nohook')
    cmd += ['--wait', '--cwd', win_hd, '--', '%s\\%s' % (win_hd, exe)] + args
    log('Info', 'Lanzando: %s' % ' '.join(cmd))
    try:
        session.process = subprocess.Popen(cmd, env=env, cwd=hd, stdin=subprocess.DEVNULL)
    except OSError as e:
        raise TrError('TR-RUN-005', e, game=g['name'])
    session.started = time.time()
    return session


def complete_game(session, diagnose=True):
    """Espera a que termine el juego y devuelve None o un TrError de diagnóstico."""
    if session.process is None:
        return None
    code = session.process.wait()
    session.exit_code = code
    elapsed = time.time() - session.started
    log('Info', 'Juego %s terminó: código %d tras %.0f s' % (session.id, code, elapsed))
    if not diagnose:
        return None
    name = session.game['name']
    # En Linux el código de salida se trunca a 8 bits: 9001-9003 de trlaunch llegan como 41-43.
    if code in (9001 & 0xFF, 9002 & 0xFF, 9003 & 0xFF):
        return TrError('TR-RUN-005', game=name)
    crash = []
    game_log = os.path.join(session.root, 'logs', 'juego-%s.log' % session.id)
    try:
        with open(game_log, encoding='utf-8', errors='replace') as f:
            text = f.read()
        crash = [re.sub(r'^\[\s*\d+\] FALLO ', '', l) for l in text.splitlines() if '] FALLO ' in l]
        if 'trhook cargado' not in text and not (session.game.get('linux') or {}).get('nohook'):
            log('Warn', 'El registro del juego no muestra trhook cargado')
    except OSError:
        pass
    if crash:
        detail = 'Detalle del fallo:\n' + '\n'.join(crash)
        log('Error', 'Detalle del fallo de %s:\n%s' % (session.id, detail))
        return TrError('TR-RUN-004', Exception(detail), game=name, code='0x%08X' % (code & 0xFFFFFFFF))
    if elapsed < 5 and code != 0:
        return TrError('TR-RUN-003', game=name)
    return None
