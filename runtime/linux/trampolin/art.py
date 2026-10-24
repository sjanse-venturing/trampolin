# art.py — artwork de Steam (portada, cabecera, fondo y logo) de cada juego, generado en la instalación.
# Mismas medidas y composición que New-TrArtImages (src/Core/Trampolin.Steam.psm1), solo con la biblioteca
# estándar de Python: lee el ícono del .exe y la imagen del disco (BMP, también RLE8), escala y escribe PNG.

import os
import struct

from . import core, icons
from .errors import log


class Image:
    """Imagen RGBA en memoria (bytearray de ancho*alto*4)."""

    def __init__(self, w, h, data=None):
        self.w, self.h = w, h
        self.data = data if data is not None else bytearray(w * h * 4)

    def crop(self, x, y, w, h):
        out = Image(w, h)
        for r in range(h):
            s = ((y + r) * self.w + x) * 4
            out.data[r * w * 4:(r + 1) * w * 4] = self.data[s:s + w * 4]
        return out

    def rows(self):
        return [self.data[r * self.w * 4:(r + 1) * self.w * 4] for r in range(self.h)]

    def pixel(self, x, y):
        i = (y * self.w + x) * 4
        return self.data[i], self.data[i + 1], self.data[i + 2], self.data[i + 3]


def _rle8(data, off, w, h):
    """Descomprime un BMP RLE8 a filas de índices de 8 bits, de abajo arriba."""
    stride = (w + 3) & ~3
    out = bytearray(stride * h)
    x = y = 0
    i = off
    while i + 1 < len(data) and y < h:
        n, v = data[i], data[i + 1]
        i += 2
        if n:                                   # n repeticiones del índice v
            for _ in range(n):
                if x < w:
                    out[y * stride + x] = v
                x += 1
        elif v == 0:                            # fin de línea
            x, y = 0, y + 1
        elif v == 1:                            # fin de la imagen
            break
        elif v == 2:                            # salto
            x += data[i]
            y += data[i + 1]
            i += 2
        else:                                   # v índices literales (con relleno a 16 bits)
            for k in range(v):
                if x < w:
                    out[y * stride + x] = data[i + k]
                x += 1
            i += v + (v & 1)
    return out


def read_bmp(path):
    """BMP de 4 u 8 bits (sin compresión o RLE8) o de 24 bits."""
    with open(path, 'rb') as f:
        b = f.read()
    if b[:2] != b'BM':
        raise ValueError('No es un BMP: %s' % path)
    off = struct.unpack_from('<I', b, 10)[0]
    hsize, w, h, planes, bpp, comp = struct.unpack_from('<IiiHHI', b, 14)
    if comp == 1 and bpp == 8 and h > 0:
        b = b[:off] + bytes(_rle8(b, off, w, h))
        comp = 0
    if comp != 0 or bpp not in (4, 8, 24):
        raise ValueError('BMP no soportado (%d bits, compresión %d)' % (bpp, comp))
    bottom_up = h > 0
    h = abs(h)
    ncolors = struct.unpack_from('<I', b, 14 + 32)[0] if hsize >= 36 else 0
    if bpp <= 8 and not ncolors:
        ncolors = 1 << bpp
    pal = [bytes((b[14 + hsize + 4 * i + 2], b[14 + hsize + 4 * i + 1], b[14 + hsize + 4 * i], 255))
           for i in range(ncolors)] if bpp <= 8 else []
    stride = ((w * bpp + 31) // 32) * 4
    img = Image(w, h)
    d = img.data
    for y in range(h):
        src = off + (h - 1 - y if bottom_up else y) * stride
        o = y * w * 4
        for x in range(w):
            if bpp == 8:
                d[o:o + 4] = pal[b[src + x]]
            elif bpp == 4:
                v = b[src + x // 2]
                d[o:o + 4] = pal[(v >> 4) if x % 2 == 0 else (v & 15)]
            else:
                bb, gg, rr = b[src + 3 * x:src + 3 * x + 3]
                d[o:o + 4] = bytes((rr, gg, bb, 255))
            o += 4
    return img


def dominant(img):
    """Color más frecuente entre los píxeles opacos (empate: el que aparece primero, de arriba abajo)."""
    count, first = {}, {}
    d = img.data
    for i in range(0, len(d), 4):
        if d[i + 3] >= 128:
            k = (d[i], d[i + 1], d[i + 2])
            if k in count:
                count[k] += 1
            else:
                count[k] = 1
                first[k] = i
    if not count:
        return 128, 128, 128
    return min(count, key=lambda k: (-count[k], first[k]))


def _axis(src, dst):
    """Índices y pesos de la interpolación bilineal en un eje."""
    out = []
    for i in range(dst):
        f = (i + 0.5) * src / dst - 0.5
        f = min(max(f, 0.0), src - 1.0)
        i0 = int(f)
        out.append((i0, min(i0 + 1, src - 1), f - i0))
    return out


def scale_opaque(img, w, h):
    """Escala una imagen opaca con interpolación bilineal, en dos pasadas (filas y después columnas)."""
    xs, ys = _axis(img.w, w), _axis(img.h, h)
    s, sw = img.data, img.w * 4
    rows = {}
    for r in sorted({i for y0, y1, _ in ys for i in (y0, y1)}):
        base = r * sw
        row = []
        for x0, x1, fx in xs:
            a, b, g = base + x0 * 4, base + x1 * 4, 1.0 - fx
            row += (s[a] * g + s[b] * fx, s[a + 1] * g + s[b + 1] * fx, s[a + 2] * g + s[b + 2] * fx)
        rows[r] = row
    out = Image(w, h)
    d = out.data
    o = 0
    for y0, y1, fy in ys:
        r0, r1, g = rows[y0], rows[y1], 1.0 - fy
        for i in range(0, w * 3, 3):
            d[o] = int(r0[i] * g + r1[i] * fy + 0.5)
            d[o + 1] = int(r0[i + 1] * g + r1[i + 1] * fy + 0.5)
            d[o + 2] = int(r0[i + 2] * g + r1[i + 2] * fy + 0.5)
            d[o + 3] = 255
            o += 4
    return out


def scale(img, w, h):
    """Escala con interpolación bilineal y alfa premultiplicado (para no oscurecer bordes transparentes)."""
    out = Image(w, h)
    xs, ys = _axis(img.w, w), _axis(img.h, h)
    s, d, sw = img.data, out.data, img.w * 4
    for y, (y0, y1, fy) in enumerate(ys):
        r0, r1 = y0 * sw, y1 * sw
        o = y * w * 4
        for x0, x1, fx in xs:
            acc = [0.0, 0.0, 0.0, 0.0]
            for base, wgt in ((r0 + x0 * 4, (1 - fx) * (1 - fy)), (r0 + x1 * 4, fx * (1 - fy)),
                              (r1 + x0 * 4, (1 - fx) * fy), (r1 + x1 * 4, fx * fy)):
                if wgt:
                    a = s[base + 3] * wgt
                    acc[0] += s[base] * a
                    acc[1] += s[base + 1] * a
                    acc[2] += s[base + 2] * a
                    acc[3] += a
            a = acc[3]
            if a > 0:
                d[o] = min(255, int(acc[0] / a + 0.5))
                d[o + 1] = min(255, int(acc[1] / a + 0.5))
                d[o + 2] = min(255, int(acc[2] / a + 0.5))
                d[o + 3] = min(255, int(a + 0.5))
            o += 4
    return out


def scale_nearest(img, w, h):
    """Escala por vecino más cercano (pixel art)."""
    out = Image(w, h)
    for y in range(h):
        sy = y * img.h // h
        for x in range(w):
            si = (sy * img.w + x * img.w // w) * 4
            out.data[(y * w + x) * 4:(y * w + x) * 4 + 4] = img.data[si:si + 4]
    return out


def fill(canvas, x, y, w, h, rgba):
    px = bytes(rgba)
    for r in range(y, y + h):
        canvas.data[(r * canvas.w + x) * 4:(r * canvas.w + x + w) * 4] = px * w


def paste(canvas, img, x, y):
    """Pega img sobre canvas en (x, y) mezclando por su alfa."""
    c, s = canvas.data, img.data
    for r in range(img.h):
        cy = y + r
        if not 0 <= cy < canvas.h:
            continue
        for col in range(img.w):
            cx = x + col
            if not 0 <= cx < canvas.w:
                continue
            si = (r * img.w + col) * 4
            a = s[si + 3]
            if not a:
                continue
            ci = (cy * canvas.w + cx) * 4
            if a == 255:
                c[ci:ci + 4] = s[si:si + 4]
                continue
            ca = c[ci + 3]
            oa = a + ca * (255 - a) // 255
            for k in range(3):
                c[ci + k] = (s[si + k] * a + c[ci + k] * ca * (255 - a) // 255) // max(1, oa)
            c[ci + 3] = oa


def cover(pic, w, h):
    """Recorte centrado de pic con la proporción w:h, escalado a w x h (cubre todo el rectángulo)."""
    s = max(w / pic.w, h / pic.h)
    sw, sh = round(w / s), round(h / s)
    return scale_opaque(pic.crop((pic.w - sw) // 2, (pic.h - sh) // 2, sw, sh), w, h)


def polygon_crossings(y, polygon):
    """Abscisas donde la recta horizontal y corta los lados de un polígono [[x, y], ...]."""
    out = []
    n = len(polygon)
    for i in range(n):
        (xi, yi), (xj, yj) = polygon[i], polygon[i - 1]
        if (yi > y) != (yj > y):
            out.append((xj - xi) * (y - yi) / (yj - yi) + xi)
    return out


def cut_logo(pic, spec):
    """Lo que queda dentro del polígono de la receta, sin el color de fondo de la caja (con tolerancia)."""
    poly = spec['polygon']
    x0, y0 = min(p[0] for p in poly), min(p[1] for p in poly)
    w, h = max(p[0] for p in poly) - x0, max(p[1] for p in poly) - y0
    key, tol = hex_rgb(spec['key']), int(spec['tolerance'])
    out = Image(w, h)
    for y in range(h):
        cross = polygon_crossings(y0 + y + 0.5, poly)
        for x in range(w):
            cx = x0 + x + 0.5
            if sum(1 for c in cross if cx < c) % 2 == 0:       # regla par-impar con el centro del píxel
                continue
            r, g, b, a = pic.pixel(x0 + x, y0 + y)
            if abs(r - key[0]) + abs(g - key[1]) + abs(b - key[2]) > tol:
                i = (y * w + x) * 4
                out.data[i:i + 4] = bytes((r, g, b, a))
    return out


def save_png(img, path):
    with open(path, 'wb') as f:
        f.write(icons._png(img.w, img.h, img.rows()))


def hex_rgb(h):
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


# Estilo común a todos los juegos: el ícono del juego ampliado como pixel art dentro de un marco blanco
# (escala entera k: marco de 34k con el ícono de 32k adentro), sobre el color principal del ícono, y una franja
# con la imagen del disco (recortada para cubrirla) si la receta «art» la tiene. Sin imagen, el marco va
# centrado. En el fondo el marco va arriba: Steam muestra abajo a la izquierda el logo (o el nombre).
# (ancho, alto, k, marco con imagen, marco sin imagen, franja de la imagen)
LAYOUTS = {
    'portrait.png': (600, 900, 12, (96, 56), (96, 246), (0, 520, 600, 380)),
    'header.png': (920, 430, 10, (45, 45), (290, 45), (430, 0, 490, 430)),
    'hero.png': (1920, 620, 10, (236, 70), (790, 70), (880, 0, 1040, 620)),
}
LOGO_SIZE = (900, 230)

# Nombres en config/grid: <appid sin signo> + sufijo.
GRID_NAMES = {'portrait.png': '%dp.png', 'header.png': '%d.png', 'hero.png': '%d_hero.png', 'logo.png': '%d_logo.png'}


def make_art(gid, root):
    """Genera las imágenes de Steam de un juego instalado en <root>/games/<ID>/art/steam: el ícono del ejecutable
    y, si la receta «art» la tiene, la imagen del disco (core.save_art_source) y el logo recortado de ella.
    Devuelve la carpeta, o None si falta el ejecutable. Se regeneran solo si cambió alguna de las fuentes."""
    g = core.game(gid)
    hd = os.path.join(root, 'games', gid)
    exe = core.local_path(hd, g['icon'])
    if not os.path.exists(exe):
        return None
    src = None
    try:
        src = core.save_art_source(gid, root)
    except Exception as e:
        log('Warn', 'No se pudo leer la imagen del disco de %s: %s' % (gid, e))
    out = os.path.join(hd, 'art', 'steam')
    hero = os.path.join(out, 'hero.png')
    if os.path.exists(hero) and all(os.path.getmtime(p) <= os.path.getmtime(hero) for p in (exe, src) if p):
        return out
    px = icons.exe_icon_rgba(exe)
    if not px:
        return None
    iw, ih, rows = px
    icon = Image(iw, ih, bytearray(b''.join(bytes(r) for r in rows)))
    pic = read_bmp(src) if src else None
    bg = dominant(icon) + (255,)
    os.makedirs(out, exist_ok=True)
    for name, (w, h, k, frame, alone, strip) in LAYOUTS.items():
        canvas = Image(w, h)
        fill(canvas, 0, 0, w, h, bg)
        at = alone
        if pic:
            sx, sy, sw, sh = strip
            paste(canvas, cover(pic, sw, sh), sx, sy)
            at = frame
        fill(canvas, at[0], at[1], 34 * k, 34 * k, (255, 255, 255, 255))
        paste(canvas, scale_nearest(icon, 32 * k, 32 * k), at[0] + k, at[1] + k)
        save_png(canvas, os.path.join(out, name))
    logo_path = os.path.join(out, 'logo.png')
    if os.path.exists(logo_path):
        os.remove(logo_path)
    spec = (g.get('art') or {}).get('logo')
    if pic and spec:
        logo = cut_logo(pic, spec)
        lw, lh = LOGO_SIZE
        s = min(lw / logo.w, lh / logo.h)
        w, h = int(logo.w * s), int(logo.h * s)
        canvas = Image(lw, lh)
        paste(canvas, scale(logo, w, h), round((lw - w) / 2), round((lh - h) / 2))
        save_png(canvas, logo_path)
    log('Info', 'Artwork de Steam generado en %s' % out)
    return out
