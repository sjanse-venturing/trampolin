# Pruebas automáticas del núcleo de Linux / Steam Deck (sin interfaz gráfica ni Proton).
# Uso:  python3 -m unittest discover -s runtime/tests -p 'test_*.py'
# Con TRAMPOLIN_ISOS=<carpeta con las .iso> se prueban también las imágenes reales.

import json
import os
import re
import struct
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'linux'))

from trampolin import core, errors, proton, steam  # noqa: E402
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

    def test_appid(self):
        a = steam.shortcut_appid('"/x/trampolin.sh"', 'Trampolín - FG')
        self.assertLess(a, 0)                          # bit alto encendido, entero con signo
        self.assertEqual(a & 0xFFFFFFFF, (a + (1 << 32)) & 0xFFFFFFFF)


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


if __name__ == '__main__':
    unittest.main()
