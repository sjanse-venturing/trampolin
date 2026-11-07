# Pruebas automáticas del núcleo de Linux / Steam Deck (sin interfaz gráfica ni Proton).
# Uso:  python3 -m unittest discover -s runtime/tests -p 'test_*.py'
# Con TRAMPOLIN_ISOS=<carpeta con las .iso> se prueban también las imágenes reales.

import base64
import datetime
import hashlib
import http.server
import io
import json
import os
import re
import shutil
import socket
import struct
import sys
import tempfile
import threading
import unittest
import urllib.parse
import zipfile
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'linux'))

from trampolin import art, core, errors, proton, steam, sync, update  # noqa: E402
from trampolin.errors import TrError  # noqa: E402
from trampolin.iso import Iso  # noqa: E402

errors.load_strings(os.path.join(core.DATA_DIR, 'strings.es.json'))


def fake_install(root, ids):
    """Instalación mínima: manifiesto y el exe de cada juego, sin copiar discos."""
    m = {'version': 1, 'games': {}}
    for gid in ids:
        hd = os.path.join(root, 'games', gid)
        os.makedirs(hd, exist_ok=True)
        with open(os.path.join(hd, core.game(gid)['exe']), 'wb') as f:
            f.write(b'MZ')
        m['games'][gid] = {'id': gid, 'dataMode': 'copy', 'hd': hd, 'cd': os.path.join(root, 'cd', gid), 'isoPath': '', 'label': ''}
    core.save_manifest(root, m)


def write(path, text):
    with open(path, 'w') as f:
        f.write(text)


def read(path, mode='r'):
    with open(path, mode) as f:
        return f.read()


def zip_names(path):
    with zipfile.ZipFile(path) as z:
        return z.namelist()


class CatalogTests(unittest.TestCase):
    def test_games(self):
        c = core.catalog()
        self.assertEqual(len(c), 8)
        self.assertEqual(len({g['id'] for g in c}), 8)
        for g in c:
            for k in ('id', 'name', 'age', 'engine', 'iso', 'copy', 'exe', 'icon', 'saves'):
                self.assertIn(k, g, g['id'])

    def test_error_codes_defined(self):
        codes = set()
        for base in (os.path.join(core.APP_ROOT, 'linux'), os.path.join(core.APP_ROOT, 'src')):
            for d, _, files in os.walk(base):
                for n in files:
                    if n.endswith(('.py', '.ps1', '.psm1')):
                        with open(os.path.join(d, n), encoding='utf-8-sig') as f:
                            codes |= set(re.findall(r'TR-[A-Z]{3}-\d{3}', f.read()))
        defined = set(errors.strings()['errors'])
        self.assertFalse(codes - defined, 'faltan en strings.es.json')

    def test_error_message(self):
        info = errors.error_info(TrError('TR-DSK-001', drive='/x', need='2 GB', free='1 GB'))
        self.assertIn('2 GB', info.message)
        self.assertEqual(errors.error_info(ValueError('raro')).code, 'TR-GEN-001')


class IniTests(unittest.TestCase):
    def test_merge(self):
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, 'a.ini')
            with open(p, 'wb') as f:
                f.write(b'[Paths]\r\nHDPath=viejo\r\nOtra=1\r\n\r\n[Video]\r\nX=2\r\n')
            core.set_ini_values(p, {'Paths': {'HDPath': '{HD}\\', 'CDPath': 'R:\\'}, 'Nueva': {'K': 'Trampolín'}}, {'HD': 'C:\\J'})
            raw = read(p, 'rb')
            self.assertIn(b'HDPath=C:\\J\\\r\n', raw)
            self.assertIn(b'Otra=1', raw)
            self.assertIn(b'CDPath=R:\\', raw)
            self.assertIn(b'X=2', raw)
            self.assertIn(b'K=Trampol\xedn', raw, 'debe quedar en ANSI (cp1252)')

    def test_section_sizes(self):
        # PE mínimo con dos secciones de tamaño virtual 0 (como WSOUND32.DLL).
        b = bytearray(0x400)
        b[0:2] = b'MZ'
        struct.pack_into('<i', b, 0x3C, 0x80)
        struct.pack_into('<I', b, 0x80, 0x4550)
        struct.pack_into('<H', b, 0x86, 2)          # secciones
        struct.pack_into('<H', b, 0x94, 0xE0)       # tamaño del encabezado opcional
        struct.pack_into('<I', b, 0x98 + 56, 0x5000)
        table = 0x98 + 0xE0
        struct.pack_into('<II', b, table + 8, 0, 0x1000)
        struct.pack_into('<II', b, table + 48, 0, 0x3000)
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, 'WSOUND32.DLL')
            with open(p, 'wb') as f:
                f.write(b)
            self.assertTrue(core.repair_section_sizes(p))
            d = read(p, 'rb')
            self.assertEqual(struct.unpack_from('<I', d, table + 8)[0], 0x2000)
            self.assertEqual(struct.unpack_from('<I', d, table + 48)[0], 0x2000)
            self.assertFalse(core.repair_section_sizes(p), 'debe ser idempotente')


class SavesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_export_import_all(self):
        a = os.path.join(self.t, 'a')
        fake_install(a, ['KG', 'PRSCHOOL'])
        write(os.path.join(a, 'games', 'KG', 'PLYR0001.INI'), '[Player]\nName=Ana')
        write(os.path.join(a, 'games', 'KG', 'volumes.sav'), 'v')
        write(os.path.join(a, 'games', 'KG', 'KG.INI'), 'no es partida')
        write(os.path.join(a, 'games', 'PRSCHOOL', 'ST1.DAT'), 'alumno')
        write(os.path.join(a, 'games', 'PRSCHOOL', '~~ka.swp'), 'intercambio')
        z = core.export_all_saves(a, os.path.join(self.t, 'out'))
        self.assertTrue(os.path.basename(z).startswith('trampolin-partidas-'))
        names = set(zip_names(z))
        self.assertEqual(names, {'trampolin-saves.json', 'KG/PLYR0001.INI', 'KG/volumes.sav', 'PRSCHOOL/ST1.DAT'})

        b = os.path.join(self.t, 'b')
        fake_install(b, ['KG'])
        write(os.path.join(b, 'games', 'KG', 'plyr0001.ini'), 'vieja')     # otra capitalización: se reemplaza
        r = core.import_saves(b, z, os.path.join(self.t, 'bk'))
        self.assertEqual(sorted(r.imported['KG']), ['PLYR0001.INI', 'volumes.sav'])
        self.assertEqual(r.skipped, {'PRSCHOOL': 'no está instalado'})
        self.assertEqual(len(r.backups), 1)
        kg = sorted(os.listdir(os.path.join(b, 'games', 'KG')))
        self.assertIn('PLYR0001.INI', kg)
        self.assertNotIn('plyr0001.ini', kg)
        self.assertIn('Ana', read(os.path.join(b, 'games', 'KG', 'PLYR0001.INI')))
        self.assertIn('plyr0001.ini', zip_names(r.backups[0]))

    def test_import_windows_legacy_zip(self):
        # Como el Backup-TrSaves anterior de Windows: archivos sueltos, sin trampolin-saves.json.
        z = os.path.join(self.t, 'KG-20260101-120000.zip')
        with zipfile.ZipFile(z, 'w') as f:
            f.writestr('PLYR0002.INI', 'Beto')
            f.writestr('ka.atr', 'a')
        b = os.path.join(self.t, 'b')
        fake_install(b, ['KG'])
        r = core.import_saves(b, z, os.path.join(self.t, 'bk'))
        self.assertEqual(sorted(r.imported['KG']), ['PLYR0002.INI', 'ka.atr'])
        self.assertEqual(r.backups, [])

    def test_per_game_backup_roundtrip(self):
        a = os.path.join(self.t, 'a')
        fake_install(a, ['4G'])
        write(os.path.join(a, 'games', '4G', 'SAVE1.SAV'), 's')
        z = core.backup_saves('4G', a, os.path.join(self.t, 'out'))
        with zipfile.ZipFile(z) as f:
            meta = json.loads(f.read('trampolin-saves.json'))
        self.assertEqual(meta['games'], ['4G'])
        renamed = os.path.join(self.t, 'copia.zip')     # el ID sale del manifiesto aunque se renombre
        os.rename(z, renamed)
        b = os.path.join(self.t, 'b')
        fake_install(b, ['4G'])
        r = core.import_saves(b, renamed, os.path.join(self.t, 'bk'))
        self.assertEqual(r.imported['4G'], ['SAVE1.SAV'])

    def test_rejects_unsafe_entries(self):
        z = os.path.join(self.t, 'otro.zip')
        with zipfile.ZipFile(z, 'w') as f:
            for n in ('../evil.ini', 'KG/../../x.sav', 'KG/sub/PLYR1.INI', 'KG/KG.EXE', 'KG\\..\\y.sav'):
                f.writestr(n, 'x')
        with self.assertRaises(TrError) as c:
            core.read_saves_zip(z)
        self.assertEqual(c.exception.code, 'TR-SAV-001')

    def test_not_a_zip(self):
        p = os.path.join(self.t, 'x.zip')
        write(p, 'no soy un zip')
        with self.assertRaises(TrError) as c:
            core.read_saves_zip(p)
        self.assertEqual(c.exception.code, 'TR-SAV-001')


def set_mtime(path, iso):
    t = sync.from_iso(iso)
    os.utime(path, (t, t))


def make_zip(entries, manifest=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        if manifest is not None:
            z.writestr('trampolin-saves.json', json.dumps(manifest))
        for n, body in entries.items():
            z.writestr(n, body)
    return buf.getvalue()


def manifest_for(gid, entries, updated='2026-01-01T10:00:00Z', **over):
    files = [{'name': n, 'size': len(b), 'sha256': hashlib.sha256(b).hexdigest(), 'mtime': updated} for n, b in entries.items()]
    m = {'format': 2, 'createdAt': updated, 'platform': 'windows', 'games': [gid], 'gameId': gid, 'updatedAt': updated,
         'deviceId': 'abc', 'deviceName': 'PC', 'bundleHash': sync.bundle_hash(files), 'files': files}
    m.update(over)
    return m


class SyncTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = self.tmp.name
        self.patches = [mock.patch.object(sync, 'STATE_FILE', os.path.join(self.t, 'state-a.json')),
                        mock.patch.object(core, 'saves_dir', lambda: os.path.join(self.t, 'copias'))]
        for p in self.patches:
            p.start()
        self.a = os.path.join(self.t, 'a')
        self.b = os.path.join(self.t, 'b')
        fake_install(self.a, ['FG', '4G'])
        fake_install(self.b, ['FG', '4G'])
        self.cloud = os.path.join(self.t, 'nube')
        os.makedirs(self.cloud)
        self.cfg_a = {'sync': {'mode': 'folder', 'folder': self.cloud, 'deviceId': 'a' * 32, 'deviceName': 'PC'}}
        self.cfg_b = {'sync': {'mode': 'folder', 'folder': self.cloud, 'deviceId': 'b' * 32, 'deviceName': 'Deck'}}

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def as_device(self, name):
        """Cada «equipo» tiene su propio sync-state.json."""
        sync.STATE_FILE = os.path.join(self.t, 'state-%s.json' % name)

    def save(self, root, gid, name, text, when):
        p = os.path.join(root, 'games', gid, name)
        write(p, text)
        set_mtime(p, when)
        return p


class SyncFolderTests(SyncTestBase):
    def test_roundtrip_newest_wins(self):
        self.as_device('a')
        self.save(self.a, 'FG', 'PLYR0001.INI', '[1G Player]\nName=Ana\n', '2026-01-01T10:00:00Z')
        r = sync.after_play('FG', self.a, self.cfg_a)
        self.assertEqual(r.action, 'uploaded')
        self.assertTrue(os.path.exists(os.path.join(self.cloud, 'Trampolin-sync', 'FG.zip')))
        self.assertEqual(sync.after_play('FG', self.a, self.cfg_a).action, 'same')

        self.as_device('b')
        r = sync.before_play('FG', self.b, self.cfg_b)
        self.assertEqual(r.action, 'downloaded')
        p = os.path.join(self.b, 'games', 'FG', 'PLYR0001.INI')
        self.assertIn('Ana', read(p))
        self.assertEqual(sync.to_iso(os.path.getmtime(p)), '2026-01-01T10:00:00Z')
        self.assertEqual(sync.before_play('FG', self.b, self.cfg_b).action, 'same')

        self.save(self.b, 'FG', 'PLYR0001.INI', '[1G Player]\nName=Ana\nModule00=1\n', '2026-01-02T10:00:00Z')
        self.assertEqual(sync.after_play('FG', self.b, self.cfg_b).action, 'uploaded')
        self.as_device('a')
        r = sync.before_play('FG', self.a, self.cfg_a)
        self.assertEqual(r.action, 'downloaded')
        self.assertTrue(r.backup and os.path.exists(r.backup), 'debe guardar la partida que reemplaza')
        self.assertIn('Module00', read(os.path.join(self.a, 'games', 'FG', 'PLYR0001.INI')))

    def test_local_newer_is_kept(self):
        self.as_device('b')
        self.save(self.b, 'FG', 'PLYR0001.INI', '[P]\nName=Vieja\n', '2026-01-01T10:00:00Z')
        sync.after_play('FG', self.b, self.cfg_b)
        self.as_device('a')
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\nName=Nueva\n', '2026-03-01T10:00:00Z')
        self.assertEqual(sync.before_play('FG', self.a, self.cfg_a).action, 'local-newer')
        self.assertIn('Nueva', read(os.path.join(self.a, 'games', 'FG', 'PLYR0001.INI')))
        self.assertTrue(sync.status(self.a)[0][4] or sync.status(self.a)[1][4], 'debe quedar pendiente de subir')

    def test_conflict_keeps_a_copy(self):
        self.as_device('a')
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\nName=A1\n', '2026-01-01T10:00:00Z')
        sync.after_play('FG', self.a, self.cfg_a)
        self.as_device('b')
        sync.before_play('FG', self.b, self.cfg_b)
        self.save(self.b, 'FG', 'PLYR0001.INI', '[P]\nName=B2\n', '2026-01-02T10:00:00Z')
        sync.after_play('FG', self.b, self.cfg_b)
        self.as_device('a')                     # A jugó sin red y después de B
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\nName=A3\n', '2026-01-03T10:00:00Z')
        r = sync.after_play('FG', self.a, self.cfg_a)
        self.assertEqual(r.action, 'uploaded')
        self.assertTrue(r.conflict and 'conflicto-Deck' in r.conflict)
        content, _ = core.read_saves_zip(r.conflict)      # la copia se puede importar
        self.assertIn('PLYR0001.INI', content['FG'])

    def test_remote_newer_is_not_overwritten_on_close(self):
        self.as_device('b')
        self.save(self.b, 'FG', 'PLYR0001.INI', '[P]\nName=B\n', '2026-05-01T10:00:00Z')
        sync.after_play('FG', self.b, self.cfg_b)
        self.as_device('a')
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\nName=A\n', '2026-01-01T10:00:00Z')
        self.assertEqual(sync.after_play('FG', self.a, self.cfg_a).action, 'remote-newer')

    def test_sync_exclude(self):
        self.as_device('a')
        self.save(self.a, '4G', 'SAVE1.SAV', 's', '2026-01-01T10:00:00Z')
        self.save(self.a, '4G', '4G.INI', '[Hardware]\nResourceDirectory=M:\\\n', '2026-01-01T10:00:00Z')
        sync.after_play('4G', self.a, self.cfg_a)
        names = zip_names(os.path.join(self.cloud, 'Trampolin-sync', '4G.zip'))
        self.assertEqual(sorted(names), ['SAVE1.SAV', 'trampolin-saves.json'])
        self.as_device('b')
        self.save(self.b, '4G', '4G.INI', 'propio', '2025-01-01T10:00:00Z')
        sync.before_play('4G', self.b, self.cfg_b)
        self.assertEqual(read(os.path.join(self.b, 'games', '4G', '4G.INI')), 'propio')

    def test_suggested_folder(self):
        home = os.path.join(self.t, 'home')
        os.makedirs(home)
        with mock.patch.object(os.path, 'expanduser', lambda p: p.replace('~', home)):
            self.assertEqual(sync.suggested_folder(), (core.saves_dir(), ''))     # sin programas: la carpeta de partidas
            os.makedirs(os.path.join(home, 'Sync'))
            self.assertEqual(sync.suggested_folder(), (os.path.join(home, 'Sync'), 'Syncthing'))

    def test_folder_missing(self):
        cfg = {'sync': {'mode': 'folder', 'folder': os.path.join(self.t, 'no-existe')}}
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\n', '2026-01-01T10:00:00Z')
        with self.assertRaises(TrError) as c:
            sync.after_play('FG', self.a, cfg)
        self.assertEqual(c.exception.code, 'TR-SYN-002')
        self.assertTrue([r for r in sync.status(self.a) if r[0] == 'FG'][0][4], 'debe quedar pendiente')

    def test_bad_remote_blocks_play_but_not_upload(self):
        d = os.path.join(self.cloud, 'Trampolin-sync')
        os.makedirs(d)
        entries = {'PLYR0001.INI': b'MZ' + b'\0' * 0x3A + b'\x40\0\0\0PE\0\0'}
        with open(os.path.join(d, 'FG.zip'), 'wb') as f:
            f.write(make_zip(entries, manifest_for('FG', entries)))
        with self.assertRaises(TrError) as c:
            sync.before_play('FG', self.a, self.cfg_a)
        self.assertEqual(c.exception.code, 'TR-SYN-005')
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\nName=A\n', '2026-01-01T10:00:00Z')
        self.assertEqual(sync.after_play('FG', self.a, self.cfg_a).action, 'uploaded')
        self.assertEqual(sync.before_play('FG', self.a, self.cfg_a).action, 'same')


class SyncValidationTests(unittest.TestCase):
    GOOD = {'PLYR0001.INI': b'[1G Player]\r\nName=955D,D57E\r\n', 'volumes.sav': b'\x01\x02\x03'}

    def assertRejected(self, data, gid='FG'):
        with self.assertRaises(TrError) as c:
            sync.validate_bundle(gid, data)
        self.assertEqual(c.exception.code, 'TR-SYN-005')
        return c.exception.data['reason']

    def test_good(self):
        meta, files = sync.validate_bundle('FG', make_zip(self.GOOD, manifest_for('FG', self.GOOD)))
        self.assertEqual(set(files), set(self.GOOD))

    def test_rejections(self):
        g = self.GOOD
        cases = {
            'ruta': make_zip(dict(g, **{'../x.sav': b'1'}), manifest_for('FG', g)),
            'carpeta': make_zip({'FG/PLYR0001.INI': b'[a]'}, manifest_for('FG', {'FG/PLYR0001.INI': b'[a]'})),
            'otro juego': make_zip(g, manifest_for('KG', g)),
            'no es partida': make_zip({'FG.EXE': b'x'}, manifest_for('FG', {'FG.EXE': b'x'})),
            'sin manifiesto': make_zip(g),
            'archivo extra': make_zip(dict(g, **{'ka.atr': b'1'}), manifest_for('FG', g)),
            'falta archivo': make_zip({'volumes.sav': g['volumes.sav']}, manifest_for('FG', g)),
            'hash': make_zip(dict(g, **{'volumes.sav': b'cambiado'}), manifest_for('FG', g)),
            'futuro': make_zip(g, manifest_for('FG', g, updated='2099-01-01T00:00:00Z')),
            'clave extra': make_zip(g, manifest_for('FG', g, extra=1)),
            'ejecutable': make_zip({'volumes.sav': b'MZ' + b'\0' * 0x3A + b'\x40\0\0\0PE\0\0'},
                                   manifest_for('FG', {'volumes.sav': b'MZ' + b'\0' * 0x3A + b'\x40\0\0\0PE\0\0'})),
            'zip adentro': make_zip({'volumes.sav': b'PK\x03\x04rest'}, manifest_for('FG', {'volumes.sav': b'PK\x03\x04rest'})),
            'ini binario': make_zip({'PLYR0001.INI': b'[a]\r\nk=\x00\x01'}, manifest_for('FG', {'PLYR0001.INI': b'[a]\r\nk=\x00\x01'})),
            'ini raro': make_zip({'PLYR0001.INI': b'<script>'}, manifest_for('FG', {'PLYR0001.INI': b'<script>'})),
            'bomba': make_zip({'volumes.sav': b'\0' * (2 << 20)}, manifest_for('FG', {'volumes.sav': b'\0' * (2 << 20)})),
            'no zip': b'hola',
        }
        for why, data in cases.items():
            with self.subTest(why):
                self.assertRejected(data)
        dup = io.BytesIO()
        with zipfile.ZipFile(dup, 'w') as z:
            z.writestr('trampolin-saves.json', json.dumps(manifest_for('FG', {'ka.atr': b'1'})))
            z.writestr('ka.atr', b'1')
            z.writestr('KA.ATR', b'2')
        self.assertIn('repetidos', self.assertRejected(dup.getvalue()))
        many = {'PLYR%04d.INI' % i: b'[a]' for i in range(70)}
        self.assertIn('demasiados', self.assertRejected(make_zip(many, manifest_for('FG', many))))

    def test_windows_bundle(self):
        # tests/fixtures/sync-windows-FG.zip lo genera New-TrSyncBundle (Windows); Run-Tests.ps1 valida el de Linux.
        with open(os.path.join(HERE, 'fixtures', 'sync-windows-FG.zip'), 'rb') as f:
            meta, files = sync.validate_bundle('FG', f.read())
        self.assertEqual(meta['platform'], 'windows')
        self.assertEqual(sorted(files), ['ka.atr', 'plyr8999.ini'])

    def test_mz_without_pe_is_data(self):
        e = {'volumes.sav': b'MZ\x00\x01datos de partida'}
        sync.validate_bundle('FG', make_zip(e, manifest_for('FG', e)))


class FakeGoogle(http.server.BaseHTTPRequestHandler):
    """Imita los endpoints de OAuth y Drive que usa sync.DriveBackend."""
    files = {}
    fail = []          # códigos a devolver en las próximas peticiones a Drive
    tokens_ok = True
    calls = []

    def log_message(self, *a):
        pass

    def reply(self, status, obj=None, raw=None, ctype='application/json'):
        body = raw if raw is not None else json.dumps(obj or {}).encode()
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        return self.rfile.read(int(self.headers.get('Content-Length') or 0))

    def handle_any(self):
        u = urllib.parse.urlparse(self.path)
        FakeGoogle.calls.append((self.command, u.path))
        data = self.body()
        if u.path == '/device/code':
            return self.reply(200, {'device_code': 'DEV', 'user_code': 'ABCD-EFGH', 'verification_url': 'https://www.google.com/device',
                                    'interval': 1, 'expires_in': 600})
        if u.path == '/token':
            f = urllib.parse.parse_qs(data.decode())
            if f.get('grant_type') == ['urn:ietf:params:oauth:grant-type:device_code']:
                payload = base64.urlsafe_b64encode(json.dumps({'email': 'ana@example.com'}).encode()).decode().rstrip('=')
                return self.reply(200, {'access_token': 'AT', 'refresh_token': 'RT', 'expires_in': 3600, 'id_token': 'x.%s.y' % payload})
            if not FakeGoogle.tokens_ok:
                return self.reply(400, {'error': 'invalid_grant', 'error_description': 'Token has been expired or revoked.'})
            return self.reply(200, {'access_token': 'AT', 'expires_in': 3600})
        if u.path == '/revoke':
            return self.reply(200)
        if self.headers.get('Authorization') != 'Bearer AT':
            return self.reply(401, {'error': {'message': 'Invalid Credentials'}})
        if FakeGoogle.fail:
            code = FakeGoogle.fail.pop(0)
            reason = 'storageQuotaExceeded' if code == 403 else 'backendError'
            return self.reply(code, {'error': {'message': 'falla simulada', 'errors': [{'reason': reason}]}})
        if u.path == '/drive/v3/files' and self.command == 'GET':
            return self.reply(200, {'files': [dict(id=k, **{x: v[x] for x in ('name', 'appProperties')}) for k, v in FakeGoogle.files.items()]})
        if u.path.startswith('/drive/v3/files/') and self.command == 'GET':
            f = FakeGoogle.files.get(u.path.rsplit('/', 1)[1])
            return self.reply(200, raw=f['data'], ctype='application/zip') if f else self.reply(404, {'error': {'message': 'no'}})
        if u.path.startswith('/upload/drive/v3/files'):
            boundary = self.headers['Content-Type'].split('boundary=')[1].encode()
            parts = data.split(b'--' + boundary)
            meta = json.loads(parts[1].split(b'\r\n\r\n', 1)[1].rstrip(b'\r\n'))
            content = parts[2].split(b'\r\n\r\n', 1)[1][:-2]
            fid = u.path.rsplit('/', 1)[1] if self.command == 'PATCH' else 'id%d' % (len(FakeGoogle.files) + 1)
            if self.command == 'POST':
                assert meta.get('parents') == ['appDataFolder']
            FakeGoogle.files[fid] = {'name': meta['name'], 'appProperties': meta['appProperties'], 'data': content}
            return self.reply(200, {'id': fid})
        return self.reply(404, {'error': {'message': 'ruta desconocida'}})

    do_GET = do_POST = do_PATCH = handle_any


class SyncDriveTests(SyncTestBase):
    def setUp(self):
        super().setUp()
        FakeGoogle.files, FakeGoogle.fail, FakeGoogle.tokens_ok, FakeGoogle.calls = {}, [], True, []
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeGoogle)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        base = 'http://127.0.0.1:%d' % self.server.server_port
        self.conf = dict(sync.google_settings(), clientId='cid', clientSecret='sec', authBase=base, apiBase=base, retryDelay=0.01)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        super().tearDown()

    def backend(self, name):
        return sync.DriveBackend(sync.TokenStore(os.path.join(self.t, 'token-%s.json' % name)), conf=self.conf)

    def test_link_and_roundtrip(self):
        da, db = self.backend('a'), self.backend('b')
        code = da.start_link()
        self.assertEqual(code['user_code'], 'ABCD-EFGH')
        self.assertEqual(da.poll_link(code['device_code']), 'ana@example.com')
        self.assertEqual(da.linked_email(), 'ana@example.com')
        db.poll_link('DEV')
        self.as_device('a')
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\nName=Ana\n', '2026-01-01T10:00:00Z')
        self.assertEqual(sync.after_play('FG', self.a, self.cfg_a, da).action, 'uploaded')
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\nName=Ana2\n', '2026-01-02T10:00:00Z')
        self.assertEqual(sync.after_play('FG', self.a, self.cfg_a, da).action, 'uploaded')
        self.assertEqual(len(FakeGoogle.files), 1, 'la segunda subida debe actualizar el mismo archivo')
        self.as_device('b')
        self.assertEqual(sync.before_play('FG', self.b, self.cfg_b, db).action, 'downloaded')
        self.assertIn('Ana2', read(os.path.join(self.b, 'games', 'FG', 'PLYR0001.INI')))
        db.unlink()
        self.assertIsNone(db.linked_email())

    def test_errors(self):
        d = self.backend('a')
        d.poll_link('DEV')
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\n', '2026-01-01T10:00:00Z')
        FakeGoogle.fail = [503, 500]                       # pasajero: se reintenta
        self.assertEqual(sync.after_play('FG', self.a, self.cfg_a, d).action, 'uploaded')
        FakeGoogle.fail = [500] * 10
        with self.assertRaises(TrError) as c:
            sync.before_play('FG', self.a, self.cfg_a, d)
        self.assertEqual(c.exception.code, 'TR-SYN-006')
        FakeGoogle.fail = [403]
        self.save(self.a, 'FG', 'PLYR0001.INI', '[P]\nX=1\n', '2026-01-02T10:00:00Z')
        with self.assertRaises(TrError) as c:
            sync.after_play('FG', self.a, self.cfg_a, d)
        self.assertEqual(c.exception.code, 'TR-SYN-004')
        FakeGoogle.fail = []
        d.access = None
        FakeGoogle.tokens_ok = False
        with self.assertRaises(TrError) as c:
            sync.after_play('FG', self.a, self.cfg_a, d)
        self.assertEqual(c.exception.code, 'TR-SYN-003')
        port = self.server.server_port
        self.server.shutdown()
        self.server.server_close()
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeGoogle)     # para el tearDown
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        d.conf = dict(d.conf, apiBase='http://127.0.0.1:%d' % port, authBase='http://127.0.0.1:%d' % port)
        d.access = None
        with self.assertRaises(TrError) as c:
            sync.after_play('FG', self.a, self.cfg_a, d)
        self.assertEqual(c.exception.code, 'TR-SYN-001')

    def test_client_from_ui(self):
        with mock.patch.object(sync, 'CLIENT_FILE', os.path.join(self.t, 'google-client.json')), \
                mock.patch.dict(os.environ, {'TRAMPOLIN_GOOGLE_CLIENT_ID': '', 'TRAMPOLIN_GOOGLE_CLIENT_SECRET': ''}):
            self.assertIn('googleusercontent', sync.save_google_client('no-es-un-id', 'GOCSPX-abcdefghijkl'))
            self.assertIsNotNone(sync.save_google_client('123-abc.apps.googleusercontent.com', 'corto'))
            self.assertIsNone(sync.save_google_client(' 123-abc.apps.googleusercontent.com ', 'GOCSPX-abcdefghijkl'))
            self.assertEqual(sync.google_settings()['clientId'], '123-abc.apps.googleusercontent.com')
            self.assertTrue(sync.drive_available())

    def test_not_configured(self):
        d = sync.DriveBackend(sync.TokenStore(os.path.join(self.t, 't.json')), conf=dict(self.conf, clientId=''))
        with self.assertRaises(TrError) as c:
            d.start_link()
        self.assertEqual(c.exception.code, 'TR-SYN-008')


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    """Imita la API de versiones de GitHub y la descarga de sus archivos."""
    routes = {}        # ruta → (estado, bytes)
    calls = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        FakeGitHub.calls.append(self.path)
        status, body = FakeGitHub.routes.get(self.path, (404, b'{}'))
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def make_package(version, files=None, prefix=None):
    """ZIP con la forma del de build.sh, mínimo (ver update.REQUIRED)."""
    prefix = prefix if prefix is not None else 'TrampolinRuntime-%s/' % version
    contents = {r: b'x' for r in update.REQUIRED}
    contents['VERSION'] = (version + '\n').encode()
    contents['src/data/update.json'] = b'{}'
    contents.update(files or {})
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        for name, data in contents.items():
            z.writestr(name if name.startswith('/') or '..' in name else prefix + name, data)
    return buf.getvalue()


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.root = os.path.join(self.t, 'inst')
        self.app = os.path.join(self.root, 'app')
        os.makedirs(self.app)
        with open(os.path.join(self.app, 'VERSION'), 'w') as f:
            f.write('1.2.0\n')
        fake_install(self.root, ['FG'])
        FakeGitHub.routes, FakeGitHub.calls = {}, []
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeGitHub)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = 'http://127.0.0.1:%d' % self.server.server_port
        self.patches = [mock.patch.object(update, 'STATE_FILE', os.path.join(self.t, 'update-state.json')),
                        mock.patch.object(core, 'APP_ROOT', self.app),
                        mock.patch.dict(os.environ, {'TRAMPOLIN_UPDATE_URL': self.base + '/latest'})]
        for p in self.patches:
            p.start()
        os.environ.pop('TRAMPOLIN_NO_UPDATE', None)

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.t, ignore_errors=True)

    def publish(self, version, package=None, sha=None, **extra):
        package = package if package is not None else make_package(version)
        sha = sha if sha is not None else hashlib.sha256(package).hexdigest()
        name = 'TrampolinRuntime-%s.zip' % version
        FakeGitHub.routes['/' + name] = (200, package)
        FakeGitHub.routes['/' + name + '.sha256'] = (200, ('%s  %s\n' % (sha, name)).encode())
        release = {'tag_name': 'v' + version, 'body': '### Agregado\n- Algo nuevo', 'html_url': 'https://example/r',
                   'assets': [{'name': name, 'browser_download_url': self.base + '/' + name},
                              {'name': name + '.sha256', 'browser_download_url': self.base + '/' + name + '.sha256'}]}
        release.update(extra)
        FakeGitHub.routes['/latest'] = (200, json.dumps(release).encode())

    def test_versions(self):
        self.assertEqual(update.parse_version('v1.2'), (1, 2, 0))
        self.assertEqual(update.parse_version(' 1.10.3\n'), (1, 10, 3))
        self.assertIsNone(update.parse_version('1.2.0-beta'))
        self.assertGreater(update.parse_version('1.10.0'), update.parse_version('1.9.9'))

    def test_offers_newer_release_only(self):
        self.publish('1.3.0')
        r = update.pending(self.root)
        self.assertEqual((r.version, r.notes), ('1.3.0', '### Agregado\n- Algo nuevo'))
        self.publish('1.2.0')
        self.assertEqual(update.check(force=True).version, '1.2.0')
        self.assertIsNone(update.pending(self.root))

    def test_ignores_prereleases_and_releases_without_package(self):
        self.publish('1.3.0', prerelease=True)
        self.assertIsNone(update.check(force=True))
        self.publish('1.3.0', assets=[])
        self.assertIsNone(update.check(force=True))
        FakeGitHub.routes['/latest'] = (404, b'{"message": "Not Found"}')
        self.assertIsNone(update.check(force=True))

    def test_only_the_installed_copy_checks(self):
        self.publish('1.3.0')
        with mock.patch.object(core, 'APP_ROOT', os.path.join(self.t, 'otra-copia')):
            self.assertIsNone(update.pending(self.root))
        self.assertEqual(FakeGitHub.calls, [])

    def test_checks_at_most_every_few_minutes_and_survives_offline(self):
        self.publish('1.3.0')
        now = datetime.datetime(2026, 11, 7, 12, 0, tzinfo=datetime.timezone.utc)
        self.assertEqual(update.check(now=now).version, '1.3.0')
        self.assertEqual(update.check(now=now + datetime.timedelta(minutes=5)).version, '1.3.0')
        self.assertEqual(len(FakeGitHub.calls), 1)
        with socket.socket() as closed:
            closed.bind(('127.0.0.1', 0))
            port = closed.getsockname()[1]
        with mock.patch.dict(os.environ, {'TRAMPOLIN_UPDATE_URL': 'http://127.0.0.1:%d/latest' % port}):
            later = now + datetime.timedelta(hours=1)
            self.assertEqual(update.check(now=later).version, '1.3.0')     # sin red: la última conocida

    def test_unknown_installed_version_is_offered_the_update(self):
        os.remove(os.path.join(self.app, 'VERSION'))      # instalaciones de Linux anteriores a la 1.3.0
        self.publish('1.3.0')
        self.assertEqual(update.pending(self.root).version, '1.3.0')

    def test_install_replaces_the_program_but_not_games_or_saves(self):
        self.publish('1.3.0', make_package('1.3.0', {'linux/main.py': b'# nuevo'}))
        save = os.path.join(self.root, 'games', 'FG', 'plyr0001.ini')
        with open(save, 'w') as f:
            f.write('[x]')
        steps = []
        self.assertEqual(update.install(update.check(force=True), self.root, lambda p, t='': steps.append(p)), '1.3.0')
        self.assertEqual(update.version_of(self.app), (1, 3, 0))
        with open(os.path.join(self.app, 'linux', 'main.py'), 'rb') as f:
            self.assertEqual(f.read(), b'# nuevo')
        self.assertTrue(os.access(os.path.join(self.app, 'trampolin.sh'), os.X_OK))
        self.assertTrue(os.path.exists(save))
        self.assertEqual(steps[-1], 100)

    def assert_rejected(self, package, sha=None):
        self.publish('1.3.0', package, sha)
        with self.assertRaises(TrError) as cm:
            update.install(update.check(force=True), self.root)
        self.assertEqual(cm.exception.code, 'TR-UPD-002')
        self.assertEqual(update.version_of(self.app), (1, 2, 0))
        self.assertFalse(os.path.exists(os.path.join(self.app, 'linux')))

    def test_rejects_wrong_checksum(self):
        self.assert_rejected(make_package('1.3.0'), sha='0' * 64)

    def test_rejects_paths_outside_the_package(self):
        self.assert_rejected(make_package('1.3.0', {'../../evil.sh': b'x'}))

    def test_rejects_package_of_another_version(self):
        self.assert_rejected(make_package('1.3.0', {'VERSION': b'1.1.0\n'}))

    def test_rejects_incomplete_package(self):
        p = make_package('1.3.0')
        buf = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(p)) as src, zipfile.ZipFile(buf, 'w') as z:
            for i in src.infolist():
                if not i.filename.endswith('trhook.dll'):
                    z.writestr(i, src.read(i))
        self.assert_rejected(buf.getvalue())

    def test_download_failure_is_reported(self):
        self.publish('1.3.0')
        release = update.check(force=True)
        FakeGitHub.routes.pop('/TrampolinRuntime-1.3.0.zip')
        with self.assertRaises(TrError) as cm:
            update.install(release, self.root)
        self.assertEqual(cm.exception.code, 'TR-UPD-001')

    def test_cli_installs_from_the_latest_release(self):
        """El paquete real (build.sh) pasa la validación y se instala con el lanzador."""
        import subprocess
        here = os.path.dirname(HERE)
        out = os.path.join(self.t, 'dist')
        version = '9.9.9'
        r = subprocess.run(['sh', os.path.join(here, 'build.sh'), '--skip-tests', '--version', version, '--out', out],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        zpath = os.path.join(out, 'TrampolinRuntime-%s.zip' % version)
        with open(zpath, 'rb') as f:
            data = f.read()
        with zipfile.ZipFile(io.BytesIO(data)) as z:   # build.sh pone la versión de --version en el VERSION del paquete
            self.assertEqual(z.read('TrampolinRuntime-%s/VERSION' % version).decode().strip(), version)
        self.publish(version, data)
        self.assertEqual(update.install(update.check(force=True), self.root), version)
        self.assertTrue(os.path.exists(os.path.join(self.app, 'linux', 'trampolin', 'update.py')))


class SteamTests(unittest.TestCase):
    def test_vdf_roundtrip_and_merge(self):
        other = {'appid': -123, 'AppName': 'Otro juego', 'Exe': '"/usr/bin/otro"', 'tags': {'0': 'X'}, 'LastPlayTime': 5}
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, 'shortcuts.vdf')
            with open(p, 'wb') as f:
                f.write(steam.vdf_dump({'shortcuts': {'0': other}}))
            exe = '"/home/deck/Trampolin/app/trampolin.sh"'
            wanted = [{'appid': steam.shortcut_appid(exe, 'Biblioteca Trampolín'), 'AppName': 'Biblioteca Trampolín', 'Exe': exe,
                       'LaunchOptions': '', 'tags': {'0': 'Trampolín'}, 'LastPlayTime': 0}]
            steam.update_shortcuts_file(p, [dict(w) for w in wanted])
            steam.update_shortcuts_file(p, [dict(w) for w in wanted])        # no duplica
            doc = steam.vdf_load(read(p, 'rb'))
            names = [e['AppName'] for e in doc['shortcuts'].values()]
            self.assertEqual(sorted(names), ['Biblioteca Trampolín', 'Otro juego'])
            self.assertTrue(os.path.exists(p + '.trampolin.bak'))

    def test_windows_fixture(self):
        # El mismo archivo lo lee y lo reescribe idéntico Trampolin.Steam.psm1 (Run-Tests.ps1).
        with open(os.path.join(HERE, 'fixtures', 'shortcuts-linux.vdf'), 'rb') as f:
            data = f.read()
        self.assertEqual(steam.vdf_dump(steam.vdf_load(data)), data)
        with open(os.path.join(HERE, 'fixtures', 'appid.txt')) as f:
            self.assertEqual(steam.shortcut_appid('"C:\\x\\powershell.exe"', 'Trampol\u00edn - FG'), int(f.read()))

    def test_appid(self):
        a = steam.shortcut_appid('"/x/trampolin.sh"', 'Trampolín - FG')
        self.assertLess(a, 0)                          # bit alto encendido, entero con signo
        self.assertEqual(a & 0xFFFFFFFF, (a + (1 << 32)) & 0xFFFFFFFF)


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    assert head[:8] == b'\x89PNG\r\n\x1a\n'
    return struct.unpack('>II', head[16:24])


def png_pixel(path, x, y):
    """Píxel RGBA de un PNG escrito por art.save_png (RGBA de 8 bits, sin entrelazar, filtro 0 en cada fila)."""
    import zlib
    data = read(path, 'rb')
    w, h = struct.unpack('>II', data[16:24])
    i, idat = 8, b''
    while i < len(data):
        n = struct.unpack('>I', data[i:i + 4])[0]
        if data[i + 4:i + 8] == b'IDAT':
            idat += data[i + 8:i + 8 + n]
        i += 12 + n
    raw = zlib.decompress(idat)
    o = y * (w * 4 + 1) + 1 + x * 4
    return tuple(raw[o:o + 4])


def bmp24(w, h, pixel):
    """BMP de 24 bits con píxeles pixel(x, y) -> (r, g, b)."""
    stride = (w * 3 + 3) & ~3
    rows = b''.join(b''.join(bytes(pixel(x, y)[::-1]) for x in range(w)) + b'\0' * (stride - w * 3) for y in range(h - 1, -1, -1))
    return (b'BM' + struct.pack('<IHHI', 54 + len(rows), 0, 0, 54) +
            struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, len(rows), 2835, 2835, 0, 0) + rows)


def fake_icon(exe_path):
    """Ícono sintético de 32x32: mayoría verde azulado (0, 128, 128), con una franja marrón."""
    rows = [bytearray(b''.join(bytes((128, 64, 0, 255)) if 10 <= x < 16 else bytes((0, 128, 128, 255)) for x in range(32)))
            for _ in range(32)]
    return 32, 32, rows


class ArtTests(unittest.TestCase):
    def setUp(self):
        p = mock.patch.object(art.icons, 'exe_icon_rgba', fake_icon)
        p.start()
        self.addCleanup(p.stop)

    def test_icon_only(self):
        with tempfile.TemporaryDirectory() as t:
            fake_install(t, ['PRE_K'])
            out = art.make_art('PRE_K', t)
            sizes = {n: png_size(os.path.join(out, n)) for n in os.listdir(out)}
            self.assertEqual(sizes, {'portrait.png': (600, 900), 'header.png': (920, 430), 'hero.png': (1920, 620)})
            self.assertEqual(png_pixel(os.path.join(out, 'portrait.png'), 5, 5), (0, 128, 128, 255))      # color del ícono
            self.assertEqual(png_pixel(os.path.join(out, 'portrait.png'), 96, 246), (255, 255, 255, 255))  # marco centrado
            self.assertEqual(png_pixel(os.path.join(out, 'portrait.png'), 96 + 12 + 12 * 12, 300), (128, 64, 0, 255))
            mtime = os.path.getmtime(os.path.join(out, 'hero.png'))
            os.utime(os.path.join(out, 'hero.png'), (mtime + 10, mtime + 10))
            art.make_art('PRE_K', t)                    # sin cambios en las fuentes: no regenera
            self.assertEqual(os.path.getmtime(os.path.join(out, 'hero.png')), mtime + 10)

    def test_picture_logo_and_grid(self):
        # Caja sintética como la de 5° Curso: fondo rojo, «lápiz» azul dentro del polígono de la receta.
        def px(x, y):
            if y < 200:
                return 0, 128, 0
            return (0, 0, 255) if 50 <= x < 270 and 235 <= y < 305 else (255, 0, 0)
        with tempfile.TemporaryDirectory() as t:
            fake_install(t, ['3G'])
            src = os.path.join(t, 'cd', '3G', 'SUPPORT', 'AUTORUN', 'SUPPORT', '3g.bmp')     # en minúsculas, como en el disco
            os.makedirs(os.path.dirname(src))
            with open(src, 'wb') as f:
                f.write(bmp24(363, 360, px))
            out = art.make_art('3G', t)
            self.assertTrue(os.path.exists(os.path.join(t, 'games', '3G', 'art', 'picture.bmp')))
            self.assertEqual(png_size(os.path.join(out, 'logo.png')), (900, 230))
            self.assertEqual(png_pixel(os.path.join(out, 'logo.png'), 2, 2)[3], 0)            # sin el rojo de la caja
            r, g, b, a = png_pixel(os.path.join(out, 'logo.png'), 300, 115)
            self.assertTrue(a == 255 and b > 200 and r < 50)
            self.assertGreater(png_pixel(os.path.join(out, 'portrait.png'), 300, 530)[1], 100)    # franja con la imagen
            cfgdir = os.path.join(t, 'steam', 'userdata', '42', 'config')
            os.makedirs(cfgdir)
            with mock.patch.object(steam, 'user_config_dirs', lambda: [cfgdir]):
                wanted = steam.wanted_shortcuts(t)
                steam.install_art(t, wanted)
            u = wanted[1]['appid'] & 0xFFFFFFFF
            self.assertEqual(sorted(os.listdir(os.path.join(cfgdir, 'grid'))),
                             sorted(['%dp.png' % u, '%d.png' % u, '%d_hero.png' % u, '%d_logo.png' % u]))

    def test_dib_inside_resource_file(self):
        pic = core.game('KG')['art']['picture']
        w, h = 640, 480
        dib = (struct.pack('<IiiHHIIiiII', 40, w, h, 1, 8, 0, 0, 0, 0, 0, 0) +
               b''.join(bytes((i, i, i, 0)) for i in range(256)) + bytes([200]) * (w * h))
        with tempfile.TemporaryDirectory() as t:
            fake_install(t, ['KG'])
            rsc = core.local_path(os.path.join(t, 'cd', 'KG'), pic['file'])
            os.makedirs(os.path.dirname(rsc))
            with open(rsc, 'wb') as f:
                f.write(bytes(pic['offset']) + dib + bytes(100))
            img = art.read_bmp(core.save_art_source('KG', t))
            self.assertEqual((img.w, img.h, img.pixel(10, 10)), (640, 480, (200, 200, 200, 255)))
        with tempfile.TemporaryDirectory() as t:
            fake_install(t, ['KG'])
            rsc = core.local_path(os.path.join(t, 'cd', 'KG'), pic['file'])
            os.makedirs(os.path.dirname(rsc))
            with open(rsc, 'wb') as f:
                f.write(bytes(pic['offset'] + 2000))
            with self.assertRaises(ValueError):
                core.save_art_source('KG', t)
            self.assertFalse(os.path.exists(os.path.join(t, 'games', 'KG', 'art', 'picture.bmp')))

    def test_rle8(self):
        # 4x2: fila de abajo «1 x índice 1, literal [1, 2, 3]» (los literales son de 3 o más), arriba «4 x índice 3».
        pal = b''.join(bytes((i * 10, i * 20, i * 30, 0)) for i in range(4))     # B, G, R
        body = bytes([1, 1, 0, 3, 1, 2, 3, 0, 0, 0, 4, 3, 0, 1])
        data = (b'BM' + struct.pack('<IHHI', 54 + 16 + len(body), 0, 0, 54 + 16) +
                struct.pack('<IiiHHIIiiII', 40, 4, 2, 1, 8, 1, len(body), 0, 0, 4, 0) + pal + body)
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, 'x.bmp')
            with open(p, 'wb') as f:
                f.write(data)
            img = art.read_bmp(p)
        self.assertEqual([img.pixel(x, 1)[0] for x in range(4)], [30, 30, 60, 90])
        self.assertEqual([img.pixel(x, 0)[2] for x in range(4)], [30, 30, 30, 30])


class ProtonTests(unittest.TestCase):
    def test_prefers_recommended(self):
        tools = [proton.ProtonTool(n, '/x/' + n) for n in ('Proton 11.0', 'Proton - Experimental', 'Proton 10.0', 'Proton 9.0 (Beta)')]
        self.assertEqual(sorted(tools, key=lambda t: t.rank(), reverse=True)[0].name, 'Proton 10.0')
        tools = [proton.ProtonTool(n, '/x/' + n) for n in ('Proton 8.0', 'Proton 11.0', 'Proton - Experimental')]
        self.assertEqual(sorted(tools, key=lambda t: t.rank(), reverse=True)[0].name, 'Proton 11.0')


@unittest.skipUnless(os.environ.get('TRAMPOLIN_ISOS'), 'definí TRAMPOLIN_ISOS para probar las imágenes reales')
class IsoTests(unittest.TestCase):
    def test_find_isos(self):
        isos, _ = core.find_isos(os.environ['TRAMPOLIN_ISOS'])
        ok = [i for i in isos if i.status == 'ok']
        self.assertTrue(ok)
        for i in ok:
            with Iso(i.path) as iso:
                self.assertTrue(iso.find(core.game(i.game_id)['iso']['keyFile']))
                self.assertTrue(iso.volume_label)

    def test_art_sources(self):
        # La imagen del artwork de cada juego se lee de su disco (sin copiar el disco).
        isos, _ = core.find_isos(os.environ['TRAMPOLIN_ISOS'])
        ok = [i for i in isos if i.status == 'ok' and core.game(i.game_id).get('art')]
        expected = {'KG': (640, 480), 'FG': (640, 480), '2G': (640, 480), '3G': (363, 360), '4G': (357, 360)}
        with tempfile.TemporaryDirectory() as t:
            fake_install(t, [i.game_id for i in ok])
            m = core.get_manifest(t)
            for i in ok:
                m['games'][i.game_id]['isoPath'] = i.path
            core.save_manifest(t, m)
            for i in ok:
                img = art.read_bmp(core.save_art_source(i.game_id, t))
                self.assertEqual((img.w, img.h), expected[i.game_id], i.game_id)


if __name__ == '__main__':
    unittest.main()
