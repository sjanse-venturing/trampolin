# ui.py — interfaz Tk de Trampolín Runtime en Linux / Steam Deck: asistente de instalación,
# «Biblioteca Trampolín» y diálogos. Equivale a src/UI/*.ps1 de Windows. Botones y letras grandes
# para la pantalla de 1280×800 del Steam Deck y el uso con el trackpad.

import os
import queue
import shutil
import subprocess
import threading
import tkinter as tk
import tkinter.font as tkfont
from tkinter import filedialog, ttk

from . import core, errors, proton, steam
from .errors import TrError, Cancelled

PRIMARY = '#E64832'      # rojo Trampolín
SECONDARY = '#FFC425'    # amarillo
OK = '#289646'
WARN = '#C88200'
BAD = '#C82828'
BACK = '#FAF8F4'
CARD = '#FFFFFF'
MUTED = '#6E6E6E'
BAR = '#EEEAE2'

SCALE_OPTIONS = [(0, 'Ajustar a la pantalla (recomendado)'), (2, 'Doble de tamaño (1280×960) si entra en la pantalla'),
                 (1, 'Tamaño original (640×480, más chico)')]


# ---------------------------------------------------------------------------
# Estilo y utilidades
# ---------------------------------------------------------------------------

class Theme:
    def __init__(self, root):
        family = 'Noto Sans' if 'Noto Sans' in tkfont.families(root) else 'DejaVu Sans'
        self.font = tkfont.Font(root, family=family, size=12)
        self.small = tkfont.Font(root, family=family, size=10)
        self.bold = tkfont.Font(root, family=family, size=12, weight='bold')
        self.big = tkfont.Font(root, family=family, size=15, weight='bold')
        self.title = tkfont.Font(root, family=family, size=20, weight='bold')
        root.option_add('*Font', self.font)
        root.configure(bg=BACK)
        s = ttk.Style(root)
        s.theme_use('clam')
        s.configure('.', background=BACK, font=self.font)
        s.configure('TButton', padding=(14, 8), background='white', bordercolor='#C8C8C8')
        s.map('TButton', background=[('active', '#F0F0F0'), ('disabled', '#E8E8E8')])
        s.configure('Primary.TButton', background=PRIMARY, foreground='white', font=self.bold, bordercolor=PRIMARY)
        s.map('Primary.TButton', background=[('active', '#C93A27'), ('disabled', '#E8A89E')])
        s.configure('TCheckbutton', background=BACK)
        s.configure('TRadiobutton', background=BACK)
        s.configure('Card.TFrame', background=CARD, relief='solid', borderwidth=1)
        s.configure('Treeview', rowheight=32, font=self.font)
        s.configure('Treeview.Heading', font=self.bold)
        s.configure('Horizontal.TProgressbar', thickness=22, background=PRIMARY)
        s.configure('Bar.TFrame', background=BAR)


def header(parent, theme, title, subtitle):
    f = tk.Frame(parent, bg=PRIMARY)
    tk.Label(f, text=title, bg=PRIMARY, fg='white', font=theme.title).pack(anchor='w', padx=22, pady=(10, 0))
    sub = tk.Label(f, text=subtitle, bg=PRIMARY, fg='#FFEBC8')
    sub.pack(anchor='w', padx=24, pady=(0, 10))
    tk.Frame(f, bg=SECONDARY, height=5).pack(fill='x', side='bottom')
    f.subtitle = sub
    return f


def label(parent, text='', font=None, fg=None, wrap=0, bg=None, **kw):
    return tk.Label(parent, text=text, font=font, fg=fg or 'black', bg=bg or parent.cget('bg'),
                    justify='left', anchor='w', wraplength=wrap, **kw)


def center(win, w, h):
    win.update_idletasks()
    sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
    w, h = min(w, sw), min(h, sh - 40)
    win.geometry('%dx%d+%d+%d' % (w, h, max(0, (sw - w) // 2), max(0, (sh - h) // 3)))


def open_path(path):
    try:
        subprocess.Popen(['xdg-open', path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def _native_dialog(args):
    """Diálogo nativo de KDE (kdialog) o GNOME (zenity) en el Modo Escritorio; None si no hay."""
    if steam.in_gaming_mode():
        return None
    for tool, a in (('kdialog', args[0]), ('zenity', args[1])):
        if shutil.which(tool):
            try:
                r = subprocess.run([tool] + a, capture_output=True, text=True)
                return r.stdout.strip() if r.returncode == 0 else ''
            except OSError:
                pass
    return None


def ask_directory(owner, title, initial):
    r = _native_dialog((['--title', title, '--getexistingdirectory', initial or os.path.expanduser('~')],
                        ['--file-selection', '--directory', '--title', title, '--filename', (initial or '~') + '/']))
    if r is None:
        r = filedialog.askdirectory(parent=owner, title=title, initialdir=initial or os.path.expanduser('~'))
    return r or None


def ask_open_zip(owner, title, initial):
    r = _native_dialog((['--title', title, '--getopenfilename', initial, 'Copias de partidas (*.zip)'],
                        ['--file-selection', '--title', title, '--filename', initial + '/', '--file-filter=*.zip']))
    if r is None:
        r = filedialog.askopenfilename(parent=owner, title=title, initialdir=initial, filetypes=[('Copias de partidas', '*.zip')])
    return r or None


def ask_open_iso(owner, title, initial):
    r = _native_dialog((['--title', title, '--getopenfilename', initial, 'Imagen de disco (*.iso)'],
                        ['--file-selection', '--title', title, '--filename', initial + '/', '--file-filter=*.iso']))
    if r is None:
        r = filedialog.askopenfilename(parent=owner, title=title, initialdir=initial, filetypes=[('Imagen de disco', '*.iso')])
    return r or None


# ---------------------------------------------------------------------------
# Diálogos
# ---------------------------------------------------------------------------

class Dialog(tk.Toplevel):
    def __init__(self, owner, theme, width=620, height=260):
        super().__init__(owner)
        self.theme = theme
        self.title('Trampolín')
        self.configure(bg=BACK)
        self.result = None
        if owner is not None and owner.winfo_viewable():
            self.transient(owner)
        self.protocol('WM_DELETE_WINDOW', self.close)
        self.size = (width, height)

    def close(self, result=None):
        self.result = result if result is not None else self.result
        self.destroy()

    def run(self):
        center(self, *self.size)
        self.lift()
        self.wait_visibility()
        self.grab_set()
        self.focus_force()
        self.wait_window()
        return self.result


def show_error(owner, theme, exc):
    """Error en lenguaje simple, con detalles técnicos plegados y botones de acción. Devuelve la acción."""
    info = exc if isinstance(exc, errors.ErrorInfo) else errors.error_info(exc)
    errors.log('Error', 'Se mostró al usuario %s: %s' % (info.code, info.message))
    d = Dialog(owner, theme, 680, 280)
    d.result = 'close'
    top = tk.Frame(d, bg=BACK)
    top.pack(fill='x', padx=20, pady=(18, 6))
    label(top, '⚠', font=theme.title, fg=WARN).pack(side='left', anchor='n', padx=(0, 14))
    box = tk.Frame(top, bg=BACK)
    box.pack(side='left', fill='x', expand=True)
    label(box, info.title, font=theme.big, wrap=560).pack(anchor='w')
    label(box, info.message, wrap=560).pack(anchor='w', pady=(6, 0))
    buttons = tk.Frame(d, bg=BACK)
    buttons.pack(fill='x', padx=20, pady=10)
    details = tk.Text(d, height=10, font=('monospace', 9), wrap='word')
    details.insert('1.0', info.details)
    details.configure(state='disabled')

    def toggle():
        if details.winfo_ismapped():
            details.pack_forget()
            center(d, 680, 280)
        else:
            details.pack(fill='both', expand=True, padx=20, pady=(0, 16))
            center(d, 680, 520)

    def copy(btn):
        d.clipboard_clear()
        d.clipboard_append(errors.report(info))
        btn.configure(text='Copiado ✓')

    ttk.Button(buttons, text='Cerrar', style='Primary.TButton', command=lambda: d.close('close')).pack(side='right')
    for a in info.actions:
        if a == 'close':
            continue
        if a == 'details':
            ttk.Button(buttons, text=errors.action_label(a), command=toggle).pack(side='right', padx=(0, 8))
        elif a == 'copy':
            b = ttk.Button(buttons, text=errors.action_label(a))
            b.configure(command=lambda b=b: copy(b))
            b.pack(side='right', padx=(0, 8))
        else:
            ttk.Button(buttons, text=errors.action_label(a), command=lambda a=a: d.close(a)).pack(side='right', padx=(0, 8))
    if 'copy' not in info.actions:
        b = ttk.Button(buttons, text='Copiar informe')
        b.configure(command=lambda: copy(b))
        b.pack(side='left')
    return d.run()


def show_info(owner, theme, title, message):
    d = Dialog(owner, theme, 620, 240)
    label(d, title, font=theme.big, wrap=570).pack(anchor='w', padx=22, pady=(20, 6))
    label(d, message, wrap=570).pack(anchor='w', padx=22)
    ttk.Button(d, text='Aceptar', style='Primary.TButton', command=d.close).pack(side='bottom', anchor='e', padx=22, pady=16)
    d.bind('<Return>', lambda e: d.close())
    d.run()


def confirm(owner, theme, title, message, yes='Sí', no='No'):
    d = Dialog(owner, theme, 620, 250)
    d.result = False
    label(d, title, font=theme.big, wrap=570).pack(anchor='w', padx=22, pady=(20, 6))
    label(d, message, wrap=570).pack(anchor='w', padx=22)
    b = tk.Frame(d, bg=BACK)
    b.pack(side='bottom', fill='x', padx=22, pady=16)
    ttk.Button(b, text=yes, style='Primary.TButton', command=lambda: d.close(True)).pack(side='right')
    ttk.Button(b, text=no, command=lambda: d.close(False)).pack(side='right', padx=8)
    return d.run()


def run_with_progress(owner, theme, title, work, cancellable=False):
    """Ejecuta work(progress, cancel) en un hilo con una ventanita de progreso. Devuelve (resultado, excepción)."""
    d = Dialog(owner, theme, 560, 180)
    d.protocol('WM_DELETE_WINDOW', lambda: None)
    label(d, title, font=theme.bold, wrap=510).pack(anchor='w', padx=22, pady=(20, 8))
    bar = ttk.Progressbar(d, maximum=100)
    bar.pack(fill='x', padx=22)
    sub = label(d, '', font=theme.small, fg=MUTED, wrap=510)
    sub.pack(anchor='w', padx=22, pady=6)
    q = queue.Queue()
    cancel = threading.Event()
    out = {}
    if cancellable:
        ttk.Button(d, text='Cancelar', command=cancel.set).pack(anchor='e', padx=22)

    def progress(p, text=''):
        q.put((p, text))

    def target():
        try:
            out['result'] = work(progress, cancel)
        except BaseException as e:
            out['error'] = e
        q.put(None)

    def poll():
        try:
            while True:
                item = q.get_nowait()
                if item is None:
                    d.close()
                    return
                p, text = item
                if p is not None:
                    bar.configure(mode='determinate', value=max(0, min(100, p)))
                else:
                    bar.configure(mode='indeterminate')
                    bar.start(15)
                sub.configure(text=text)
        except queue.Empty:
            pass
        d.after(120, poll)

    threading.Thread(target=target, daemon=True).start()
    d.after(120, poll)
    d.run()
    return out.get('result'), out.get('error')


# ---------------------------------------------------------------------------
# Steam
# ---------------------------------------------------------------------------

def add_to_steam(owner, theme, root):
    """Agrega la biblioteca y los juegos a Steam (con Steam cerrado) y crea los accesos del menú."""
    try:
        steam.write_desktop_entries(root)
    except OSError as e:
        errors.log('Warn', 'No se pudieron crear los accesos del menú: %s' % e)
    if not steam.user_config_dirs():
        show_info(owner, theme, 'No encontramos Steam',
                  'Iniciá sesión en Steam al menos una vez y volvé a intentar. Igual podés jugar desde el menú de aplicaciones.')
        return False
    if steam.in_gaming_mode():
        show_info(owner, theme, 'Hacelo desde el Modo Escritorio',
                  'Para agregar los juegos a Steam hay que cerrar Steam un momento. Pasá al Modo Escritorio, abrí '
                  'la Biblioteca Trampolín y usá «Agregar a Steam».')
        return False
    running = steam.steam_running()
    if running and not confirm(owner, theme, '¿Cerrar Steam un momento?',
                               'Para agregar los juegos a Steam hay que cerrarlo. Lo volvemos a abrir enseguida.',
                               'Cerrar Steam y agregar', 'Cancelar'):
        return False

    def work(progress, cancel):
        if running:
            progress(None, 'Cerrando Steam…')
            if not steam.shutdown_steam():
                raise TrError('TR-GEN-001', Exception('Steam no se cerró a tiempo'))
        progress(None, 'Agregando los juegos…')
        files = steam.add_to_steam(root)
        if running:
            progress(None, 'Abriendo Steam…')
            steam.start_steam()
        return files

    files, err = run_with_progress(owner, theme, 'Agregando los juegos a Steam…', work)
    if err:
        show_error(owner, theme, err)
        return False
    show_info(owner, theme, 'Listo', 'Los juegos aparecen en Steam, en la colección «Trampolín» y en «No de Steam». '
              'En el Modo Juego, buscalos en la Biblioteca → No de Steam.')
    return True


# ---------------------------------------------------------------------------
# Asistente de instalación
# ---------------------------------------------------------------------------

class Wizard:
    PAGES = 8

    def __init__(self, master, theme, cfg, preselect=()):
        self.master, self.theme, self.cfg = master, theme, cfg
        self.preselect = list(preselect)
        self.installed = False
        self.found = []
        self.zips = []
        self.page = 0
        self.cancel = threading.Event()
        self.busy = False
        self.win = tk.Toplevel(master)
        self.win.title('Instalar Trampolín')
        self.win.configure(bg=BACK)
        self.win.protocol('WM_DELETE_WINDOW', self.on_cancel)
        header(self.win, theme, 'Trampolín', 'Instalación de los juegos clásicos en Linux y Steam Deck').pack(fill='x')
        self.body = tk.Frame(self.win, bg=BACK)
        self.body.pack(fill='both', expand=True, padx=26, pady=14)
        bar = ttk.Frame(self.win, style='Bar.TFrame')
        bar.pack(fill='x', side='bottom')
        self.btn_cancel = ttk.Button(bar, text='Cancelar', command=self.on_cancel)
        self.btn_cancel.pack(side='right', padx=(6, 16), pady=10)
        self.btn_next = ttk.Button(bar, text='Siguiente >', style='Primary.TButton', command=self.on_next)
        self.btn_next.pack(side='right', padx=6, pady=10)
        self.btn_back = ttk.Button(bar, text='< Atrás', command=self.on_back)
        self.btn_back.pack(side='right', padx=6, pady=10)
        self.iso_var = tk.StringVar(value=cfg.get('isoFolder') or core.default_iso_folder())
        self.root_var = tk.StringVar(value=cfg.get('installRoot') or core.default_install_root())
        self.scale_var = tk.IntVar(value=int(cfg.get('scale') or 0))
        self.steam_var = tk.BooleanVar(value=bool(cfg.get('steamShortcuts', True)))
        self.checks = {}
        center(self.win, 960, 700)
        self.show(0)

    def run(self):
        self.win.grab_set()
        self.master.wait_window(self.win)
        return self.installed

    def clear(self):
        for w in self.body.winfo_children():
            w.destroy()

    def selected(self):
        return [g['id'] for g in core.catalog() if self.checks.get(g['id']) and self.checks[g['id']][0].get()]

    def iso_for(self, gid):
        return next((i for i in self.found if i.game_id == gid and i.status == 'ok'), None)

    # ---- páginas ------------------------------------------------------------

    def show(self, n):
        self.page = n
        self.clear()
        self.btn_back.configure(state='normal' if 0 < n < 6 else 'disabled')
        self.btn_next.configure(text={5: 'Instalar', 7: 'Abrir la biblioteca'}.get(n, 'Siguiente >'), state='normal')
        if n == 7:
            self.btn_back.pack_forget()
            self.btn_cancel.pack_forget()
        getattr(self, 'page%d' % n)()

    def page0(self):
        label(self.body, '¡Hola! Este asistente instala los juegos Trampolín para que funcionen en esta computadora '
              'o Steam Deck, sin máquinas virtuales.', wrap=880).pack(anchor='w')
        label(self.body, 'Revisamos que todo esté listo:', font=self.theme.bold).pack(anchor='w', pady=(16, 6))
        blocking = False
        for c in core.prerequisites(self.cfg):
            row = tk.Frame(self.body, bg=BACK)
            row.pack(fill='x', pady=2)
            mark, color = ('✔', OK) if c.ok else (('✖', BAD) if c.blocking else ('⚠', WARN))
            label(row, mark, fg=color, font=self.theme.bold, width=2).pack(side='left')
            label(row, c.name, width=30).pack(side='left')
            label(row, c.detail, fg=MUTED, wrap=520).pack(side='left')
            blocking |= (not c.ok and c.blocking)
        label(self.body, 'Hay un requisito que no se cumple. Revisá el detalle y volvé a abrir el instalador.' if blocking
              else 'Todo en orden. Presioná «Siguiente».', fg=BAD if blocking else OK, wrap=880).pack(anchor='w', pady=14)
        label(self.body, 'Vas a necesitar los archivos de los discos (.iso) o el archivo trampolin_anaya.zip.',
              fg=MUTED, wrap=880).pack(anchor='w')
        if blocking:
            self.btn_next.configure(state='disabled')

    def page1(self):
        label(self.body, '¿Dónde están los discos de los juegos?', font=self.theme.big).pack(anchor='w')
        label(self.body, 'Elegí la carpeta que contiene los archivos .iso (o el .zip con todos los discos).',
              wrap=880).pack(anchor='w', pady=(4, 10))
        row = tk.Frame(self.body, bg=BACK)
        row.pack(fill='x')
        ttk.Entry(row, textvariable=self.iso_var).pack(side='left', fill='x', expand=True, ipady=4)
        ttk.Button(row, text='Examinar…', command=self.browse_iso).pack(side='left', padx=6)
        ttk.Button(row, text='Buscar', command=self.scan).pack(side='left')
        self.tree = ttk.Treeview(self.body, columns=('game', 'status', 'file'), show='headings', height=8)
        for c, t, w in (('game', 'Juego', 340), ('status', 'Estado', 130), ('file', 'Archivo', 400)):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w)
        self.tree.pack(fill='both', expand=True, pady=10)
        bottom = tk.Frame(self.body, bg=BACK)
        bottom.pack(fill='x')
        self.lbl_iso = label(bottom, '', wrap=640)
        self.lbl_iso.pack(side='left', fill='x', expand=True)
        self.btn_zip = ttk.Button(bottom, text='Extraer el ZIP…', command=self.extract_zip)
        if self.found or self.iso_var.get():
            self.scan()

    def browse_iso(self):
        d = ask_directory(self.win, 'Carpeta con los discos', self.iso_var.get())
        if d:
            self.iso_var.set(d)
            self.scan()

    def scan(self):
        self.tree.delete(*self.tree.get_children())
        self.btn_zip.pack_forget()
        self.win.configure(cursor='watch')
        self.win.update()
        try:
            self.found, self.zips = core.find_isos(self.iso_var.get())
            for i in self.found:
                name = core.game(i.game_id)['name'] if i.game_id else '(desconocido)'
                status = {'ok': 'Listo ✓', 'invalid': 'Dañado ✗'}.get(i.status, 'No reconocido')
                self.tree.insert('', 'end', values=(name, status, i.name))
            ok = len([i for i in self.found if i.status == 'ok'])
            text = 'Encontramos %d de %d juegos.' % (ok, len(core.catalog()))
            if self.zips and ok < len(core.catalog()):
                text += ' También hay un archivo .zip (%s) que puede contener los discos.' % os.path.basename(self.zips[0])
                self.btn_zip.pack(side='right')
            self.lbl_iso.configure(text=text, fg=OK if ok else BAD)
        except Exception as e:
            self.found = []
            self.lbl_iso.configure(text=errors.error_info(e).message, fg=BAD)
        finally:
            self.win.configure(cursor='')

    def extract_zip(self):
        z = self.zips[0]
        dest = os.path.join(os.path.dirname(z), 'trampolin_isos')
        _, err = run_with_progress(self.win, self.theme, 'Extrayendo los discos de %s…' % os.path.basename(z),
                                   lambda p, c: core.expand_zip_isos(z, dest, p, c), cancellable=True)
        if err and not isinstance(err, Cancelled):
            show_error(self.win, self.theme, err)
        self.iso_var.set(dest)
        self.scan()

    def page2(self):
        label(self.body, 'Elegí los juegos a instalar', font=self.theme.big).pack(anchor='w', pady=(0, 8))
        old = {k: v[0].get() for k, v in self.checks.items()}
        self.checks = {}
        installed = {ig.id for ig in core.installed_games(self.cfg.get('installRoot'))}
        for g in core.catalog():
            iso = self.iso_for(g['id'])
            default = bool(iso) and (not self.preselect or g['id'] in self.preselect)
            var = tk.BooleanVar(value=old.get(g['id'], default) and bool(iso))
            row = tk.Frame(self.body, bg=BACK)
            row.pack(fill='x', pady=2)
            cb = ttk.Checkbutton(row, variable=var, text='%s  (%s)' % (g['name'], g['age']))
            cb.pack(side='left')
            note = 'ya instalado: se reinstala' if g['id'] in installed else ''
            label(row, (iso.name if iso else 'No se encontró el disco') + ('   — ' + note if note else ''),
                  fg=MUTED, font=self.theme.small).pack(side='right')
            if not iso:
                cb.state(['disabled'])
            self.checks[g['id']] = (var, iso)
        row = tk.Frame(self.body, bg=BACK)
        row.pack(fill='x', pady=12)
        ttk.Button(row, text='Todos', command=lambda: [v.set(bool(i)) for v, i in self.checks.values()]).pack(side='left')
        ttk.Button(row, text='Ninguno', command=lambda: [v.set(False) for v, _ in self.checks.values()]).pack(side='left', padx=8)
        label(row, 'Los juegos en gris no tienen su disco en la carpeta elegida.', fg=MUTED).pack(side='left', padx=10)

    def page3(self):
        label(self.body, '¿Dónde querés instalar los juegos?', font=self.theme.big).pack(anchor='w')
        row = tk.Frame(self.body, bg=BACK)
        row.pack(fill='x', pady=10)
        ttk.Entry(row, textvariable=self.root_var).pack(side='left', fill='x', expand=True, ipady=4)
        ttk.Button(row, text='Examinar…', command=self.browse_root).pack(side='left', padx=6)
        label(self.body, 'Se copian los juegos completos (no hace falta conservar los .iso). Si usás una tarjeta SD, '
              'tiene que estar formateada por el Steam Deck (ext4).', fg=MUTED, wrap=880).pack(anchor='w')
        self.lbl_space = label(self.body, '', font=self.theme.bold)
        self.lbl_space.pack(anchor='w', pady=16)
        self.root_var.trace_add('write', lambda *a: self.refresh_space())
        self.refresh_space()

    def browse_root(self):
        d = ask_directory(self.win, 'Carpeta de instalación', os.path.dirname(self.root_var.get()))
        if d:
            self.root_var.set(d if os.path.basename(d).lower().startswith('trampolin') else os.path.join(d, 'Trampolin'))

    def refresh_space(self):
        if not self.lbl_space.winfo_exists():
            return
        need = core.required_bytes(self.selected())
        p = os.path.abspath(os.path.expanduser(self.root_var.get() or '~'))
        while p and not os.path.exists(p):
            p = os.path.dirname(p)
        try:
            free = shutil.disk_usage(p).free
        except OSError:
            free = None
        self.lbl_space.configure(text='Espacio necesario: %s%s' % (core.format_size(need), '   —   Libre: %s' % core.format_size(free) if free is not None else ''),
                                 fg=BAD if free is not None and free < need else OK)

    def page4(self):
        label(self.body, '¿Cómo se ven los juegos?', font=self.theme.big).pack(anchor='w')
        label(self.body, 'Los juegos se diseñaron para 640×480. Podés agrandarlos para que ocupen tu pantalla.',
              wrap=880).pack(anchor='w', pady=(4, 10))
        for v, t in SCALE_OPTIONS:
            ttk.Radiobutton(self.body, text=t, value=v, variable=self.scale_var).pack(anchor='w', pady=3)
        label(self.body, 'Steam', font=self.theme.bold).pack(anchor='w', pady=(20, 4))
        ttk.Checkbutton(self.body, variable=self.steam_var,
                        text='Agregar los juegos a Steam para jugar desde el Modo Juego (cierra Steam un momento)').pack(anchor='w')
        label(self.body, 'Siempre se agregan al menú de aplicaciones, en «Juegos».', fg=MUTED).pack(anchor='w', pady=4)

    def page5(self):
        label(self.body, 'Todo listo para instalar', font=self.theme.big).pack(anchor='w', pady=(0, 8))
        sel = self.selected()
        lines = ['Juegos a instalar (%d):' % len(sel)] + ['   • ' + core.game(i)['name'] for i in sel] + [
            '', 'Carpeta de instalación:  ' + self.root,
            'Pantalla:  ' + dict(SCALE_OPTIONS)[self.scale_var.get()],
            'Agregar a Steam:  ' + ('Sí' if self.steam_var.get() else 'No'),
            'Capa de compatibilidad:  ' + ((proton.select(self.cfg).name) if proton.select(self.cfg) else '—'),
            '', 'Espacio necesario aproximado:  ' + core.format_size(core.required_bytes(sel))]
        t = tk.Text(self.body, height=16, relief='solid', borderwidth=1, wrap='word')
        t.insert('1.0', '\n'.join(lines))
        t.configure(state='disabled')
        t.pack(fill='both', expand=True)

    def page6(self):
        self.btn_next.configure(state='disabled')
        self.btn_back.configure(state='disabled')
        label(self.body, 'Instalando…', font=self.theme.big).pack(anchor='w')
        self.bar = ttk.Progressbar(self.body, maximum=100)
        self.bar.pack(fill='x', pady=12)
        self.lbl_inst = label(self.body, '', wrap=880)
        self.lbl_inst.pack(anchor='w')
        self.lst = tk.Listbox(self.body, height=10, font=self.theme.small)
        self.lst.pack(fill='both', expand=True, pady=10)
        self.results = []
        q = queue.Queue()
        ids = self.selected()
        root = self.root
        isos = {gid: self.iso_for(gid).path for gid in ids}

        def work():
            try:
                q.put(('msg', 0, 'Copiando el programa…'))
                core.install_runtime_files(root)
                for n, gid in enumerate(ids):
                    try:
                        core.install_game(gid, isos[gid], root,
                                          lambda p, t, n=n: q.put(('msg', int((n + p / 100) * 90 / len(ids)), t)), self.cancel)
                        q.put(('result', gid, True, 'Instalado'))
                    except Cancelled:
                        q.put(('result', gid, False, 'Cancelado'))
                        break
                    except Exception as e:
                        q.put(('result', gid, False, errors.error_info(e).message))
                q.put(('msg', 92, 'Preparando la capa de compatibilidad (Proton). La primera vez tarda un poco…'))
                try:
                    proton.ensure_prefix(root, proton.select(self.cfg))
                except Exception as e:
                    q.put(('log', 'Proton: ' + errors.error_info(e).message))
                q.put(('msg', 97, 'Creando los accesos…'))
                try:
                    steam.write_desktop_entries(root)
                except Exception as e:
                    errors.log('Warn', 'Accesos del menú: %s' % e)
            finally:
                q.put(('done',))

        def poll():
            try:
                while True:
                    item = q.get_nowait()
                    if item[0] == 'msg':
                        self.bar.configure(value=item[1])
                        self.lbl_inst.configure(text=item[2])
                    elif item[0] == 'log':
                        self.lst.insert('end', item[1])
                    elif item[0] == 'result':
                        self.results.append(item[1:])
                        self.lst.insert('end', ('✔ ' if item[2] else '✖ ') + core.game(item[1])['name'] + ': ' + item[3])
                    elif item[0] == 'done':
                        self.busy = False
                        self.finish()
                        return
            except queue.Empty:
                pass
            self.win.after(150, poll)

        self.busy = True
        self.cfg.update({'installRoot': root, 'isoFolder': self.iso_var.get(), 'scale': self.scale_var.get(),
                         'steamShortcuts': self.steam_var.get()})
        core.save_config(self.cfg)
        errors.init_log(os.path.join(root, 'logs'))
        threading.Thread(target=work, daemon=True).start()
        self.win.after(150, poll)

    def finish(self):
        self.installed = any(ok for _, ok, _ in self.results)
        if self.installed and self.steam_var.get():
            add_to_steam(self.win, self.theme, self.root)
        self.show(7)

    def page7(self):
        ok = [r for r in self.results if r[1]]
        label(self.body, '¡Listo!' if ok and len(ok) == len(self.results) else 'Instalación terminada',
              font=self.theme.big).pack(anchor='w', pady=(0, 10))
        for gid, good, msg in self.results:
            label(self.body, ('✔  ' if good else '✖  ') + core.game(gid)['name'] + ' — ' + msg,
                  fg=OK if good else BAD, wrap=880).pack(anchor='w', pady=2)
        label(self.body, 'Podés jugar desde la «Biblioteca Trampolín», desde el menú de aplicaciones o, si los agregaste, '
              'desde Steam (también en el Modo Juego).', wrap=880).pack(anchor='w', pady=16)

    # ---- navegación ---------------------------------------------------------

    def validate(self):
        if self.page == 1 and not [i for i in self.found if i.status == 'ok']:
            show_error(self.win, self.theme, TrError('TR-ISO-001', path=self.iso_var.get()))
            return False
        if self.page == 2 and not self.selected():
            show_info(self.win, self.theme, 'Elegí al menos un juego', 'Marcá la casilla de los juegos que querés instalar.')
            return False
        if self.page == 3:
            try:
                self.root = core.test_install_root(self.root_var.get(), core.required_bytes(self.selected()))
                self.root_var.set(self.root)
            except Exception as e:
                show_error(self.win, self.theme, e)
                return False
        return True

    def on_next(self):
        if self.page == 7:
            self.win.destroy()
            return
        if self.validate():
            self.show(self.page + 1)

    def on_back(self):
        if self.page > 0:
            self.show(self.page - 1)

    def on_cancel(self):
        if self.busy:
            if confirm(self.win, self.theme, '¿Cancelar la instalación?',
                       'Se deshace solo el juego que se está copiando. Los que ya terminaron quedan instalados.',
                       'Cancelar la instalación', 'Seguir'):
                self.cancel.set()
            return
        self.win.destroy()


# ---------------------------------------------------------------------------
# Biblioteca
# ---------------------------------------------------------------------------

class Library:
    def __init__(self, master, theme, cfg):
        self.master, self.theme, self.cfg = master, theme, cfg
        self.root = cfg['installRoot']
        self.result = 'exit'
        self.session = None
        self.images = {}
        self.win = master
        self.win.title('Biblioteca Trampolín')
        for w in self.win.winfo_children():
            w.destroy()
        self.header = header(self.win, theme, 'Biblioteca Trampolín', 'Elegí un juego y presioná «Jugar»')
        self.header.pack(fill='x')
        bar = ttk.Frame(self.win, style='Bar.TFrame')
        bar.pack(fill='x', side='bottom')
        ttk.Button(bar, text='Agregar juegos…', command=self.add_games).pack(side='left', padx=(16, 6), pady=10)
        self.btn_saves = ttk.Button(bar, text='Partidas ▾', command=self.saves_menu)
        self.btn_saves.pack(side='left', padx=6)
        ttk.Button(bar, text='Agregar a Steam', command=lambda: add_to_steam(self.win, theme, self.root)).pack(side='left', padx=6)
        ttk.Button(bar, text='Opciones…', command=self.options).pack(side='left', padx=6)
        ttk.Button(bar, text='Ayuda', command=self.help).pack(side='left', padx=6)
        ttk.Button(bar, text='Ver registro', command=self.show_log).pack(side='left', padx=6)
        self.lbl_status = label(bar, '', fg=MUTED, bg=BAR)
        self.lbl_status.pack(side='right', padx=16)
        outer = tk.Frame(self.win, bg=BACK)
        outer.pack(fill='both', expand=True)
        self.canvas = tk.Canvas(outer, bg=BACK, highlightthickness=0)
        sb = ttk.Scrollbar(outer, orient='vertical', command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y')
        self.canvas.pack(side='left', fill='both', expand=True)
        self.grid = tk.Frame(self.canvas, bg=BACK)
        self.canvas.create_window((0, 0), window=self.grid, anchor='nw')
        self.grid.bind('<Configure>', lambda e: self.canvas.configure(scrollregion=self.canvas.bbox('all')))
        self.canvas.bind('<Configure>', lambda e: self.layout())
        for seq in ('<Button-4>', '<Button-5>', '<MouseWheel>'):
            self.canvas.bind_all(seq, self.on_wheel)
        self.win.protocol('WM_DELETE_WINDOW', self.on_close)
        center(self.win, 1180, 760)
        self.refresh()

    def on_wheel(self, e):
        delta = -1 if getattr(e, 'num', 0) == 4 or getattr(e, 'delta', 0) > 0 else 1
        self.canvas.yview_scroll(delta, 'units')

    def icon(self, ig):
        if ig.id not in self.images:
            img = None
            try:
                png = steam.icon_for(self.root, ig.id)
                if png:
                    img = tk.PhotoImage(file=png)
                    if img.width() < 64:
                        img = img.zoom(max(1, 64 // max(1, img.width())))
            except (tk.TclError, OSError):
                img = None
            self.images[ig.id] = img
        return self.images[ig.id]

    def refresh(self):
        for w in self.grid.winfo_children():
            w.destroy()
        self.cards = []
        games = core.installed_games(self.root)
        if not games:
            f = tk.Frame(self.grid, bg=BACK)
            label(f, 'Todavía no hay juegos instalados.', font=self.theme.big).pack(anchor='w', pady=20)
            ttk.Button(f, text='Instalar juegos', style='Primary.TButton', command=self.add_games).pack(anchor='w')
            self.cards.append(f)
        for ig in games:
            card = tk.Frame(self.grid, bg=CARD, highlightbackground='#D0D0D0', highlightthickness=1, width=330, height=210)
            card.pack_propagate(False)
            top = tk.Frame(card, bg=CARD)
            top.pack(fill='x', padx=14, pady=(14, 0))
            img = self.icon(ig)
            if img:
                tk.Label(top, image=img, bg=CARD).pack(side='left', anchor='n', padx=(0, 10))
            names = tk.Frame(top, bg=CARD)
            names.pack(side='left', fill='x', expand=True)
            label(names, ig.name, font=self.theme.bold, wrap=230, bg=CARD).pack(anchor='w')
            label(names, ig.age, fg=MUTED, bg=CARD).pack(anchor='w')
            label(card, 'Instalado en este equipo' if ig.healthy else 'Instalación incompleta: usá «Reparar»',
                  font=self.theme.small, fg=MUTED if ig.healthy else BAD, bg=CARD).pack(anchor='w', padx=14, pady=6)
            row = tk.Frame(card, bg=CARD)
            row.pack(fill='x', side='bottom', padx=14, pady=14)
            ttk.Button(row, text='▶  Jugar', style='Primary.TButton', command=lambda i=ig.id: self.play(i)).pack(side='left', fill='x', expand=True)
            more = ttk.Button(row, text='···', width=4)
            more.configure(command=lambda i=ig.id, b=more: self.game_menu(i, b))
            more.pack(side='left', padx=(8, 0))
            self.cards.append(card)
        self.lbl_status.configure(text='Instalados: %d de %d' % (len(games), len(core.catalog())))
        self.layout()

    def layout(self):
        width = max(self.canvas.winfo_width(), 360)
        cols = max(1, width // 350)
        for n, c in enumerate(self.cards):
            c.grid(row=n // cols, column=n % cols, padx=10, pady=10, sticky='nw')
        self.grid.grid_columnconfigure(tuple(range(cols)), weight=0)

    # ---- acciones -------------------------------------------------------------

    def game_menu(self, gid, button):
        m = tk.Menu(self.win, tearoff=0, font=self.theme.font)
        m.add_command(label='Reparar', command=lambda: self.repair(gid))
        m.add_command(label='Copia de seguridad de las partidas', command=lambda: self.backup(gid))
        m.add_command(label='Importar partidas…', command=self.import_saves)
        m.add_command(label='Abrir la carpeta del juego', command=lambda: open_path(os.path.join(self.root, 'games', gid)))
        m.add_separator()
        m.add_command(label='Desinstalar…', command=lambda: self.uninstall(gid))
        m.tk_popup(button.winfo_rootx(), button.winfo_rooty() + button.winfo_height())

    def saves_menu(self):
        m = tk.Menu(self.win, tearoff=0, font=self.theme.font)
        m.add_command(label='Exportar todas las partidas…', command=self.export_all)
        m.add_command(label='Importar partidas…', command=self.import_saves)
        m.add_separator()
        m.add_command(label='Abrir la carpeta de copias', command=self.open_saves_dir)
        b = self.btn_saves
        m.tk_popup(b.winfo_rootx(), b.winfo_rooty() - 4 - 3 * 36)

    def open_saves_dir(self):
        os.makedirs(core.saves_dir(), exist_ok=True)
        open_path(core.saves_dir())

    def play(self, gid):
        if self.session:
            show_error(self.win, self.theme, TrError('TR-RUN-001'))
            return
        for _ in range(3):
            session, err = start_with_progress(self.win, self.theme, gid, self.root, self.cfg)
            if not err:
                break
            action = show_error(self.win, self.theme, err)
            if action == 'locate' and self.locate_iso(gid):
                continue
            if action == 'repair':
                self.repair(gid)
            if action != 'retry':
                return
        else:
            return
        self.session = session
        self.lbl_status.configure(text='Jugando: %s…' % core.game(gid)['name'])
        self.win.iconify()
        q = queue.Queue()
        threading.Thread(target=lambda: q.put(proton.complete_game(session)), daemon=True).start()

        def poll():
            try:
                diag = q.get_nowait()
            except queue.Empty:
                self.win.after(500, poll)
                return
            self.session = None
            self.win.deiconify()
            self.win.lift()
            self.refresh()
            if diag:
                if show_error(self.win, self.theme, diag) == 'repair':
                    self.repair(gid)

        self.win.after(500, poll)

    def locate_iso(self, gid):
        path = ask_open_iso(self.win, 'Buscá el disco de «%s»' % core.game(gid)['name'], self.cfg.get('isoFolder') or os.path.expanduser('~'))
        if not path:
            return False
        found, _ = core.find_isos(os.path.dirname(path))
        if not [i for i in found if i.path == path and i.game_id == gid and i.status == 'ok']:
            show_error(self.win, self.theme, TrError('TR-ISO-002', file=os.path.basename(path)))
            return False
        m = core.get_manifest(self.root)
        m['games'][gid]['isoPath'] = path
        core.save_manifest(self.root, m)
        return True

    def repair(self, gid):
        entry = core.get_manifest(self.root)['games'].get(gid)
        if not entry:
            return
        name = core.game(gid)['name']
        if not os.path.exists(entry.get('isoPath') or ''):
            show_info(self.win, self.theme, 'Necesitamos el disco',
                      'Para reparar «%s» necesitamos su archivo .iso. Indicanos dónde está.' % name)
            if not self.locate_iso(gid):
                return
            entry = core.get_manifest(self.root)['games'][gid]
        _, err = run_with_progress(self.win, self.theme, 'Reparando «%s»…' % name,
                                   lambda p, c: core.install_game(gid, entry['isoPath'], self.root, p, c, repair=True))
        if err:
            show_error(self.win, self.theme, err)
        else:
            show_info(self.win, self.theme, 'Reparación terminada', 'El juego se reparó correctamente. Tus partidas no se modificaron.')
        self.refresh()

    def backup(self, gid):
        try:
            z = core.backup_saves(gid, self.root)
            if z:
                show_info(self.win, self.theme, 'Copia de seguridad lista', 'Las partidas se guardaron en:\n' + z)
            else:
                show_info(self.win, self.theme, 'No hay partidas', 'Este juego todavía no tiene partidas guardadas.')
        except Exception as e:
            show_error(self.win, self.theme, e)

    def export_all(self):
        dest = ask_directory(self.win, '¿Dónde guardar las partidas?', core.saves_dir() if os.path.isdir(core.saves_dir()) else os.path.expanduser('~'))
        if not dest:
            return
        try:
            z = core.export_all_saves(self.root, dest)
            if z:
                show_info(self.win, self.theme, 'Partidas exportadas',
                          'Todas las partidas quedaron en:\n%s\n\nCopiá ese archivo a la otra computadora y usá «Importar partidas…».' % z)
            else:
                show_info(self.win, self.theme, 'No hay partidas', 'Ninguno de los juegos instalados tiene partidas guardadas.')
        except Exception as e:
            show_error(self.win, self.theme, e)

    def import_saves(self):
        start = core.saves_dir() if os.path.isdir(core.saves_dir()) else os.path.expanduser('~')
        z = ask_open_zip(self.win, 'Elegí la copia de partidas (.zip)', start)
        if not z:
            return
        try:
            content, _ = core.read_saves_zip(z)
        except Exception as e:
            show_error(self.win, self.theme, e)
            return
        names = ', '.join(core.game(g)['name'] for g in [c['id'] for c in core.catalog()] if g in content)
        if not confirm(self.win, self.theme, '¿Importar estas partidas?',
                       'Juegos: %s.\n\nLas partidas que tengas ahora de esos juegos se reemplazan (antes guardamos una copia '
                       'en «Trampolín - partidas»).' % names, 'Importar', 'Cancelar'):
            return
        try:
            r = core.import_saves(self.root, z)
        except Exception as e:
            show_error(self.win, self.theme, e)
            return
        lines = ['✔ %s: %d archivo(s)' % (core.game(g)['name'], len(f)) for g, f in r.imported.items()]
        lines += ['–  %s: %s' % (core.game(g)['name'], why) for g, why in r.skipped.items()]
        if r.backups:
            lines += ['', 'Las partidas anteriores quedaron en «%s».' % os.path.dirname(r.backups[0])]
        show_info(self.win, self.theme, 'Partidas importadas' if r.imported else 'No se importó nada', '\n'.join(lines))

    def uninstall(self, gid):
        name = core.game(gid)['name']
        if not confirm(self.win, self.theme, '¿Desinstalar «%s»?' % name,
                       'Se borrarán los archivos del juego de este equipo. Antes guardaremos una copia de las partidas en Documentos.',
                       'Desinstalar', 'Cancelar'):
            return
        try:
            z = core.uninstall_game(gid, self.root)
            steam.remove_desktop_entry(gid)
            show_info(self.win, self.theme, 'Juego desinstalado',
                      'Las partidas quedaron guardadas en:\n' + z if z else 'No había partidas para guardar.')
        except Exception as e:
            show_error(self.win, self.theme, e)
        self.refresh()

    def add_games(self):
        self.result = 'wizard'
        self.win.quit()

    def options(self):
        d = Dialog(self.win, self.theme, 640, 400)
        label(d, 'Tamaño de los juegos en pantalla', font=self.theme.bold).pack(anchor='w', padx=22, pady=(18, 6))
        scale = tk.IntVar(value=int(self.cfg.get('scale') or 0))
        for v, t in SCALE_OPTIONS:
            ttk.Radiobutton(d, text=t, value=v, variable=scale).pack(anchor='w', padx=28, pady=2)
        label(d, 'Versión de Proton', font=self.theme.bold).pack(anchor='w', padx=22, pady=(16, 6))
        tools = proton.list_protons()
        names = ['Automática (%s)' % (tools[0].name if tools else 'no hay')] + [t.name for t in tools]
        pv = tk.StringVar(value=self.cfg.get('proton') or names[0])
        ttk.Combobox(d, textvariable=pv, values=names, state='readonly', width=40).pack(anchor='w', padx=28)

        def save():
            self.cfg['scale'] = scale.get()
            self.cfg['proton'] = None if pv.get().startswith('Automática') else pv.get()
            core.save_config(self.cfg)
            d.close()

        ttk.Button(d, text='Guardar', style='Primary.TButton', command=save).pack(side='bottom', anchor='e', padx=22, pady=16)
        d.run()

    def help(self):
        for p in (os.path.join(self.root, 'LEEME-RUNTIME.md'), os.path.join(core.APP_ROOT, 'LEEME-RUNTIME.md')):
            if os.path.exists(p):
                open_path(p)
                return

    def show_log(self):
        if errors.log_file() and os.path.exists(errors.log_file()):
            open_path(errors.log_file())

    def on_close(self):
        if self.session:
            show_info(self.win, self.theme, 'Hay un juego abierto', 'Cerrá el juego antes de salir de la biblioteca.')
            return
        self.result = 'exit'
        self.win.quit()

    def run(self):
        self.win.deiconify()
        self.win.mainloop()
        return self.result


def start_with_progress(owner, theme, gid, root, cfg):
    """Lanza el juego; si hay que crear el prefijo de Proton muestra una ventanita de espera."""
    if os.path.isfile(os.path.join(proton.prefix_dir(root), 'system.reg')):
        try:
            return proton.start_game(gid, root, cfg), None
        except Exception as e:
            return None, e
    return run_with_progress(owner, theme, 'Abriendo «%s»…' % core.game(gid)['name'],
                             lambda p, c: proton.start_game(gid, root, cfg, lambda t: p(None, t)))


# ---------------------------------------------------------------------------
# Puntos de entrada
# ---------------------------------------------------------------------------

def _tk_root():
    root = tk.Tk(className='trampolin')
    root.title('Trampolín')
    theme = Theme(root)
    return root, theme


def main(mode='auto'):
    root, theme = _tk_root()
    root.withdraw()
    open_wizard = mode == 'install'
    while True:
        cfg = core.get_config()
        has_games = bool(core.installed_games(cfg.get('installRoot')))
        if open_wizard or not has_games:
            Wizard(root, theme, cfg).run()
            open_wizard = False
            cfg = core.get_config()
            if not core.installed_games(cfg.get('installRoot')):
                break
        lib = Library(root, theme, cfg)
        if lib.run() != 'wizard':
            break
        root.withdraw()
        open_wizard = True
    root.destroy()
    return 0


def play(gid):
    """Lo usan los accesos de Steam y del menú: juega sin abrir la biblioteca; muestra los errores."""
    cfg = core.get_config()
    root_dir = cfg.get('installRoot')
    tkroot, theme = _tk_root()
    tkroot.withdraw()
    try:
        if not root_dir:
            raise TrError('TR-RUN-006', game=gid)
        if core.find_game_id(gid) is None:
            raise TrError('TR-RUN-006', game=gid)
        gid = core.find_game_id(gid)
        session, err = start_with_progress(tkroot, theme, gid, root_dir, cfg)
        if err:
            raise err
        diag = proton.complete_game(session)
        if diag:
            raise diag
    except Exception as e:
        show_error(tkroot, theme, e)
        tkroot.destroy()
        return 1
    tkroot.destroy()
    return 0


def show_error_standalone(exc):
    root, theme = _tk_root()
    root.withdraw()
    show_error(root, theme, exc)
    root.destroy()
