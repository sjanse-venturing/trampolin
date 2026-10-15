# main.py — punto de entrada de Trampolín Runtime en Linux / Steam Deck (lo invoca trampolin.sh).
#
#   main.py                 abre la biblioteca (o el asistente si no hay nada instalado)
#   main.py --install       abre el asistente de instalación
#   main.py --play <ID>     lanza un juego directamente (lo usan los accesos de Steam y del menú)
#   main.py cli ...         comandos sin interfaz gráfica (ver «cli --help»)

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from trampolin import core, errors, proton, steam  # noqa: E402
from trampolin.errors import TrError  # noqa: E402


def init(cfg):
    errors.load_strings(os.path.join(core.DATA_DIR, 'strings.es.json'))
    root = cfg.get('installRoot')
    errors.init_log(os.path.join(root, 'logs') if root else os.path.join(core.CONFIG_DIR, 'logs'))


# ---------------------------------------------------------------------------
# Comandos sin interfaz gráfica
# ---------------------------------------------------------------------------

def _root(args, cfg):
    root = args.root or cfg.get('installRoot')
    if not root:
        sys.exit('No hay una instalación. Usá «cli install --isos <carpeta>» primero.')
    return os.path.abspath(os.path.expanduser(root))


def cli(argv):
    p = argparse.ArgumentParser(prog='trampolin.sh cli', description='Trampolín Runtime (Linux) sin interfaz gráfica.')
    p.add_argument('--root', help='carpeta de instalación (por defecto, la configurada)')
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('install', help='instalar juegos desde una carpeta con las .iso')
    s.add_argument('--isos', required=True)
    s.add_argument('--games', help='IDs separados por comas (por defecto, todos los encontrados)')
    s.add_argument('--scale', type=int, choices=(0, 1, 2))
    sub.add_parser('list', help='juegos instalados y versión de Proton')
    s = sub.add_parser('play', help='jugar')
    s.add_argument('id')
    s = sub.add_parser('repair', help='volver a copiar los archivos de un juego (sin tocar las partidas)')
    s.add_argument('id')
    s = sub.add_parser('uninstall', help='desinstalar un juego (guarda antes una copia de las partidas)')
    s.add_argument('id')
    s = sub.add_parser('export-saves', help='exportar partidas (todas en un zip, o de los juegos indicados)')
    s.add_argument('ids', nargs='*')
    s.add_argument('--out', help='carpeta de destino (por defecto, Documentos/Trampolín - partidas)')
    s = sub.add_parser('import-saves', help='importar partidas desde un zip de Windows o de Linux')
    s.add_argument('zip')
    s = sub.add_parser('steam', help='agregar los juegos a Steam (cierra y vuelve a abrir Steam si hace falta)')
    s.add_argument('--no-restart', action='store_true', help='no reabrir Steam al terminar')
    sub.add_parser('menu', help='crear los accesos del menú del Modo Escritorio')
    args = p.parse_args(argv)

    cfg = core.get_config()
    if args.cmd == 'install':
        root = core.test_install_root(args.root or cfg.get('installRoot') or core.default_install_root())
        cfg['installRoot'] = root
        if args.scale is not None:
            cfg['scale'] = args.scale
        cfg['isoFolder'] = os.path.abspath(args.isos)
        core.save_config(cfg)
    init(cfg)
    try:
        return _cli_run(args, cfg)
    except TrError as e:
        info = errors.error_info(e)
        print('%s: %s\n%s' % (info.code, info.title, info.message), file=sys.stderr)
        return 1


def _cli_run(args, cfg):
    if args.cmd == 'install':
        root = cfg['installRoot']
        isos, _ = core.find_isos(args.isos)
        ok = {i.game_id: i for i in isos if i.status == 'ok'}
        for i in isos:
            if i.status != 'ok':
                print('  ✗ %s: %s' % (i.name, i.message))
        ids = [x.strip() for x in args.games.split(',')] if args.games else [g['id'] for g in core.catalog() if g['id'] in ok]
        core.test_install_root(root, core.required_bytes(ids))
        core.install_runtime_files(root)
        for gid in ids:
            if gid not in ok:
                print('  ✗ %s: no se encontró su disco' % gid)
                continue
            last = [-1]

            def prog(pct, text, gid=gid):
                if pct // 10 != last[0]:
                    last[0] = pct // 10
                    print('  %s %3d%% %s' % (gid, pct, text[:70]), flush=True)
            core.install_game(gid, ok[gid].path, root, prog)
        proton.ensure_prefix(root, proton.select(cfg), print)
        print('Listo: %d juegos en %s' % (len(core.installed_games(root)), root))
        return 0
    root = _root(args, cfg)
    if args.cmd == 'list':
        t = proton.select(cfg)
        print('Instalación: %s\nProton: %s' % (root, t.name + ' (' + t.path + ')' if t else 'no encontrado'))
        for ig in core.installed_games(root):
            print('  %-9s %s %s' % (ig.id, '✓' if ig.healthy else '✗', ig.name))
        return 0
    if args.cmd == 'play':
        s = proton.start_game(args.id, root, cfg, print)
        diag = proton.complete_game(s)
        if diag:
            raise diag
        return 0
    if args.cmd == 'repair':
        entry = core.get_manifest(root)['games'].get(args.id)
        if not entry:
            raise TrError('TR-RUN-006', game=args.id)
        core.install_game(args.id, entry['isoPath'], root, repair=True)
        print('Reparado.')
        return 0
    if args.cmd == 'uninstall':
        b = core.uninstall_game(args.id, root)
        steam.remove_desktop_entry(args.id)
        print('Desinstalado.' + (' Partidas guardadas en %s' % b if b else ''))
        return 0
    if args.cmd == 'export-saves':
        if args.ids:
            for gid in args.ids:
                z = core.backup_saves(gid, root, args.out)
                print('%s: %s' % (gid, z or 'no tiene partidas'))
        else:
            z = core.export_all_saves(root, args.out)
            print(z or 'No hay partidas para exportar.')
        return 0
    if args.cmd == 'import-saves':
        r = core.import_saves(root, args.zip)
        for gid, files in r.imported.items():
            print('  ✓ %s: %s' % (gid, ', '.join(files)))
        for gid, why in r.skipped.items():
            print('  – %s: %s' % (gid, why))
        if r.ignored:
            print('  (se ignoraron: %s)' % ', '.join(r.ignored))
        for b in r.backups:
            print('  Copia de las partidas anteriores: %s' % b)
        return 0
    if args.cmd == 'steam':
        if steam.in_gaming_mode():
            print('Hacelo desde el Modo Escritorio: hay que cerrar Steam para agregar los juegos.')
            return 1
        was_running = steam.steam_running()
        if was_running:
            print('Cerrando Steam…', flush=True)
            if not steam.shutdown_steam():
                print('Steam no se cerró. Cerralo y volvé a intentar.')
                return 1
        files = steam.add_to_steam(root)
        print('Accesos agregados en: %s' % (', '.join(files) or 'ningún usuario de Steam'))
        if was_running and not args.no_restart:
            steam.start_steam()
        return 0
    if args.cmd == 'menu':
        steam.write_desktop_entries(root)
        print('Accesos creados en %s' % steam.desktop_dir())
        return 0
    return 1


# ---------------------------------------------------------------------------
# Interfaz gráfica
# ---------------------------------------------------------------------------

def gui(argv):
    mode, play_id = 'auto', None
    i = 0
    while i < len(argv):
        if argv[i] in ('--play', '-play') and i + 1 < len(argv):
            mode, play_id = 'play', argv[i + 1]
            i += 1
        elif argv[i] in ('--install', '-install'):
            mode = 'install'
        i += 1
    cfg = core.get_config()
    init(cfg)
    from trampolin import ui
    if mode == 'play':
        return ui.play(play_id)
    return ui.main(mode)


if __name__ == '__main__':
    argv = sys.argv[1:]
    if argv and argv[0] == 'cli':
        sys.exit(cli(argv[1:]))
    try:
        sys.exit(gui(argv))
    except SystemExit:
        raise
    except BaseException as e:   # último recurso: cualquier error no previsto se muestra amigablemente
        import traceback
        errors.log('Error', 'Error no controlado: %s\n%s' % (e, traceback.format_exc()))
        try:
            from trampolin import ui
            ui.show_error_standalone(e)
        except Exception:
            traceback.print_exc()
        sys.exit(1)
