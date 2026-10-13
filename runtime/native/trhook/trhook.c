/*
 * trhook.dll — capa de compatibilidad de Trampolín Runtime (Nivel 3).
 *
 * La inyecta trlaunch.exe en el proceso del juego antes de que arranque.
 * Parchea la IAT del ejecutable principal (y de las DLLs del juego que se
 * cargan luego) para:
 *   - Evitar cambios globales del sistema: resolución (ChangeDisplaySettings),
 *     colores del escritorio (SetSysColors), paleta del sistema
 *     (SetSystemPaletteUse), ocultar la barra de tareas (SHAppBarMessage).
 *   - Redirigir KA.INI (que los juegos buscan en C:\WINDOWS) a la carpeta
 *     de instalación.
 *   - Simular la unidad de CD-ROM (tipo de unidad y etiqueta de volumen)
 *     cuando los datos se copiaron al disco.
 *   - Presentar la imagen escalada y centrada en pantalla (TrPresent, la
 *     llama WING32.DLL) y traducir las coordenadas del mouse.
 *   - Registrar (opcional) INIs, archivos y diálogos para diagnóstico.
 *
 * La configuración llega por variables de entorno (las hereda del lanzador):
 *   TRAMPOLIN_LOG        archivo de log (vacío = sin log)
 *   TRAMPOLIN_KAINI      ruta completa del KA.INI a usar
 *   TRAMPOLIN_CDDRIVE    letra de la unidad virtual de CD (p. ej. "T")
 *   TRAMPOLIN_CDLABEL    etiqueta de volumen a reportar para esa unidad
 *   TRAMPOLIN_SCALE      0 = ajustar a pantalla (por defecto), 1..4 = escala entera
 *   TRAMPOLIN_TRACE      1 = registrar cada llamada a INI/archivo
 */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Configuración y log                                                  */
/* ------------------------------------------------------------------ */

static CRITICAL_SECTION g_logLock;
static FILE *g_log;
static int g_trace;
static char g_kaIni[MAX_PATH];
static char g_cdDrive;            /* 'T' o 0 */
static char g_cdLabel[64];
static int g_scale;               /* 0 = ajustar */
static int g_viewW, g_viewH;      /* TRAMPOLIN_VIEW: tamaño fijo de la vista (diagnóstico) */
static char g_swapDir[MAX_PATH];  /* carpeta para ~~ka.swp de ACES */
static HMODULE g_self;

static void tlog(const char *fmt, ...) {
    va_list ap;
    if (!g_log) return;
    EnterCriticalSection(&g_logLock);
    fprintf(g_log, "[%8lu] ", GetTickCount());
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
    LeaveCriticalSection(&g_logLock);
}

static void read_env(const char *name, char *buf, DWORD size) {
    DWORD n = GetEnvironmentVariableA(name, buf, size);
    if (n == 0 || n >= size) buf[0] = 0;
}

static void load_config(void) {
    char tmp[MAX_PATH];
    read_env("TRAMPOLIN_LOG", tmp, sizeof tmp);
    if (tmp[0]) g_log = fopen(tmp, "a");
    read_env("TRAMPOLIN_TRACE", tmp, sizeof tmp);
    g_trace = tmp[0] == '1';
    read_env("TRAMPOLIN_KAINI", g_kaIni, sizeof g_kaIni);
    read_env("TRAMPOLIN_CDDRIVE", tmp, sizeof tmp);
    g_cdDrive = (char)(tmp[0] ? (tmp[0] & ~0x20) : 0);
    read_env("TRAMPOLIN_CDLABEL", g_cdLabel, sizeof g_cdLabel);
    read_env("TRAMPOLIN_SCALE", tmp, sizeof tmp);
    g_scale = tmp[0] ? atoi(tmp) : 0;
    read_env("TRAMPOLIN_VIEW", tmp, sizeof tmp);
    if (sscanf(tmp, "%dx%d", &g_viewW, &g_viewH) != 2) g_viewW = g_viewH = 0;
    read_env("TRAMPOLIN_SWAPDIR", g_swapDir, sizeof g_swapDir);
    if (!g_swapDir[0]) {
        char *slash;
        GetModuleFileNameA(NULL, g_swapDir, sizeof g_swapDir);
        slash = strrchr(g_swapDir, '\\');
        if (slash) *slash = 0;
    }
}

/* ------------------------------------------------------------------ */
/* Registro de fallos                                                   */
/* ------------------------------------------------------------------ */

/*
 * Si el juego se cae (violación de acceso, etc.), deja en el log el módulo y
 * el desplazamiento donde ocurrió, los registros y la pila. Se registra
 * siempre (sin traza): el lanzador copia este bloque al informe de error.
 * Si el juego instala su propio filtro, lo llamamos después del nuestro.
 */
static LPTOP_LEVEL_EXCEPTION_FILTER g_gameFilter;

static void describe_address(DWORD addr, char *out, size_t size) {
    HMODULE m = NULL;
    char path[MAX_PATH];
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)(ULONG_PTR)addr, &m) && m && GetModuleFileNameA(m, path, sizeof path)) {
        const char *b = strrchr(path, '\\');
        _snprintf(out, size, "%s+0x%lX", b ? b + 1 : path, addr - (DWORD)(ULONG_PTR)m);
    } else {
        _snprintf(out, size, "?");
    }
    out[size - 1] = 0;
}

static LONG WINAPI crash_filter(EXCEPTION_POINTERS *ep) {
    static volatile LONG once;
    if (ep && ep->ExceptionRecord && InterlockedExchange(&once, 1) == 0) {
        EXCEPTION_RECORD *er = ep->ExceptionRecord;
        DWORD eip = (DWORD)(ULONG_PTR)er->ExceptionAddress;
        char where[MAX_PATH + 32];
        describe_address(eip, where, sizeof where);
        tlog("FALLO excepción 0x%08lX en 0x%08lX (%s), hilo %lu", er->ExceptionCode, eip, where, GetCurrentThreadId());
        if (er->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && er->NumberParameters >= 2)
            tlog("FALLO acceso de %s a la dirección 0x%08lX",
                 er->ExceptionInformation[0] == 0 ? "lectura" : er->ExceptionInformation[0] == 1 ? "escritura" : "ejecución",
                 (DWORD)er->ExceptionInformation[1]);
#ifdef _M_IX86
        if (ep->ContextRecord) {
            CONTEXT *c = ep->ContextRecord;
            DWORD *sp = (DWORD *)(ULONG_PTR)c->Esp;
            int i;
            tlog("FALLO EAX=%08lX EBX=%08lX ECX=%08lX EDX=%08lX ESI=%08lX EDI=%08lX EBP=%08lX ESP=%08lX",
                 c->Eax, c->Ebx, c->Ecx, c->Edx, c->Esi, c->Edi, c->Ebp, c->Esp);
            /* Valores de la pila que apuntan a código: la cadena de llamadas aproximada. */
            for (i = 0; i < 64; i++) {
                DWORD v;
                if (IsBadReadPtr(sp + i, sizeof v)) break;
                v = sp[i];
                describe_address(v, where, sizeof where);
                if (where[0] != '?') tlog("FALLO pila[%02d] %08lX %s", i, v, where);
            }
        }
#endif
    }
    return g_gameFilter ? g_gameFilter(ep) : EXCEPTION_CONTINUE_SEARCH;
}

typedef LPTOP_LEVEL_EXCEPTION_FILTER(WINAPI *SUEF_t)(LPTOP_LEVEL_EXCEPTION_FILTER);
static SUEF_t real_SetUnhandledExceptionFilter;
static LPTOP_LEVEL_EXCEPTION_FILTER WINAPI hk_SetUnhandledExceptionFilter(LPTOP_LEVEL_EXCEPTION_FILTER f) {
    LPTOP_LEVEL_EXCEPTION_FILTER prev = g_gameFilter;
    g_gameFilter = f;
    return prev;
}

/* ------------------------------------------------------------------ */
/* Presentación escalada                                                */
/* ------------------------------------------------------------------ */

#define LOGICAL_W 640
#define LOGICAL_H 480

/*
 * Los tres motores dibujan un área lógica de 640x480, de dos formas:
 *
 *  - Modo ESCENARIO (KA-MFC: FG, 2G, KG, 3G): una ventana hija de 640x480
 *    dentro de una ventana a pantalla completa. La agrandamos y la centramos.
 *  - Modo LIENZO (PEEWEE, ACES): una ventana a pantalla completa en la que el
 *    juego dibuja el área de 640x480 centrada. Dejamos la ventana como está y
 *    transformamos cada copia a pantalla.
 *
 * En los dos casos, el "destino" (g_target) es la ventana donde se presenta, y
 * un punto lógico L (en coordenadas de cliente que el juego cree) corresponde
 * al punto real  V + (L - O) * escala , donde O es el origen lógico del área
 * de 640x480 en esa ventana y V el origen real de la vista escalada.
 */
enum { MODE_NONE, MODE_STAGE, MODE_CANVAS };
static int g_mode = MODE_NONE;
static HWND g_mainWnd;     /* primera ventana de nivel superior del juego */
static HWND g_target;      /* ventana donde se aplica el mapeo */
static int g_ox, g_oy;     /* origen lógico del área 640x480 en la ventana */
static int g_vx, g_vy;     /* origen real de la vista escalada */
static int g_vw = LOGICAL_W, g_vh = LOGICAL_H; /* tamaño real de la vista */
static WNDPROC g_targetProc;
static int g_gameX, g_gameY; /* modo escenario: posición (en el padre) donde el juego cree que está su ventana */

typedef BOOL(WINAPI *SWP_t)(HWND, HWND, int, int, int, int, UINT);
typedef BOOL(WINAPI *MW_t)(HWND, int, int, int, int, BOOL);
typedef BOOL(WINAPI *GCR_t)(HWND, LPRECT);
typedef BOOL(WINAPI *IR_t)(HWND, const RECT *, BOOL);
typedef BOOL(WINAPI *VR_t)(HWND, const RECT *);
typedef BOOL(WINAPI *BB_t)(HDC, int, int, int, int, HDC, int, int, DWORD);
typedef BOOL(WINAPI *SB_t)(HDC, int, int, int, int, HDC, int, int, int, int, DWORD);
typedef int(WINAPI *SDIB_t)(HDC, int, int, int, int, int, int, int, int, const VOID *, const BITMAPINFO *, UINT, DWORD);
typedef int(WINAPI *SDTD_t)(HDC, int, int, DWORD, DWORD, int, int, UINT, UINT, const VOID *, const BITMAPINFO *, UINT);
static SWP_t real_SetWindowPos;
static MW_t real_MoveWindow;
static GCR_t real_GetClientRect;
static IR_t real_InvalidateRect;
static VR_t real_ValidateRect;
static BB_t real_BitBlt;
static SB_t real_StretchBlt;
static SDIB_t real_StretchDIBits;
static SDTD_t real_SetDIBitsToDevice;

static int scaled(void) { return g_mode != MODE_NONE && (g_vw != LOGICAL_W || g_vh != LOGICAL_H); }
/* lógico -> real */
static int rx(int v) { return g_vx + MulDiv(v - g_ox, g_vw, LOGICAL_W); }
static int ry(int v) { return g_vy + MulDiv(v - g_oy, g_vh, LOGICAL_H); }
/* real -> lógico */
static int lx(int v) { return g_ox + MulDiv(v - g_vx, LOGICAL_W, g_vw); }
static int ly(int v) { return g_oy + MulDiv(v - g_vy, LOGICAL_H, g_vh); }

/* Calcula el tamaño real de la vista dentro de un área disponible aw x ah. */
static void pick_size(int aw, int ah, int *w, int *h) {
    int s;
    if (g_scale == 1 || aw < LOGICAL_W || ah < LOGICAL_H) { *w = LOGICAL_W; *h = LOGICAL_H; return; }
    /* Diagnóstico: tamaño fijo, aunque no entre en la pantalla (para reproducir otras resoluciones). */
    if (g_viewW >= LOGICAL_W && g_viewH >= LOGICAL_H) { *w = g_viewW; *h = g_viewH; return; }
    if (g_scale >= 2) {
        for (s = g_scale; s > 1 && (LOGICAL_W * s > aw || LOGICAL_H * s > ah); s--) {}
        *w = LOGICAL_W * s; *h = LOGICAL_H * s;
        return;
    }
    /* 0 = ajustar al área disponible manteniendo 4:3 */
    if ((long)aw * LOGICAL_H > (long)ah * LOGICAL_W) { *h = ah; *w = ah * LOGICAL_W / LOGICAL_H; }
    else { *w = aw; *h = aw * LOGICAL_H / LOGICAL_W; }
}

/* Traduce los mensajes de mouse de coordenadas reales a lógicas. */
static LRESULT CALLBACK target_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (scaled() && msg >= WM_MOUSEFIRST && msg <= WM_MOUSELAST && msg != WM_MOUSEWHEEL) {
        int x = (short)LOWORD(lp), y = (short)HIWORD(lp);
        lp = MAKELPARAM(lx(x), ly(y));
        if (g_trace && msg != WM_MOUSEMOVE) tlog("MOUSE msg %04x %d,%d -> %d,%d", msg, x, y, lx(x), ly(y));
    }
    if (g_trace && (msg == WM_ACTIVATEAPP || msg == WM_ACTIVATE || msg == WM_KILLFOCUS || msg == WM_SETFOCUS))
        tlog("ventana msg %04x wp=%lx", msg, (DWORD)wp);
    return CallWindowProcA(g_targetProc, hwnd, msg, wp, lp);
}

/*
 * Sombra: copia sin escalar (640x480) de lo que el juego cree que hay en la
 * ventana. Los motores guardan el fondo bajo el objeto que se arrastra
 * leyendo de la ventana (BitBlt con la ventana como origen) y luego lo
 * restauran; como la ventana real tiene la imagen escalada, esas lecturas se
 * sirven desde aquí. Coordenada de sombra = lógica - (g_ox, g_oy).
 */
static HDC g_shadowDC;
static HBITMAP g_shadowBmp;

static void create_shadow(HWND hwnd) {
    HDC wdc = GetDC(hwnd);
    if (!wdc) return;
    g_shadowDC = CreateCompatibleDC(wdc);
    g_shadowBmp = CreateCompatibleBitmap(wdc, LOGICAL_W, LOGICAL_H);
    ReleaseDC(hwnd, wdc);
    if (!g_shadowDC || !g_shadowBmp) {
        if (g_shadowDC) DeleteDC(g_shadowDC);
        if (g_shadowBmp) DeleteObject(g_shadowBmp);
        g_shadowDC = NULL; g_shadowBmp = NULL;
        return;
    }
    SelectObject(g_shadowDC, g_shadowBmp);
    PatBlt(g_shadowDC, 0, 0, LOGICAL_W, LOGICAL_H, BLACKNESS);
}

static void subclass_target(HWND hwnd) {
    g_target = hwnd;
    g_targetProc = (WNDPROC)SetWindowLongPtrA(hwnd, GWLP_WNDPROC, (LONG_PTR)target_proc);
    create_shadow(hwnd);
}

/* Modo escenario: agranda la ventana hija de 640x480 y la centra en su padre. */
static void adopt_stage(HWND hwnd, int gameX, int gameY) {
    HWND parent = GetParent(hwnd);
    RECT area;
    int w, h, x, y;
    if (g_mode != MODE_NONE || g_scale == 1 || !parent) return;
    real_GetClientRect(parent, &area);
    pick_size(area.right - area.left, area.bottom - area.top, &w, &h);
    if (w == LOGICAL_W) return;
    x = (area.right - area.left - w) / 2;
    y = (area.bottom - area.top - h) / 2;
    g_mode = MODE_STAGE;
    g_gameX = gameX;
    g_gameY = gameY;
    g_ox = g_oy = g_vx = g_vy = 0;
    g_vw = w;
    g_vh = h;
    subclass_target(hwnd);
    real_SetWindowPos(hwnd, NULL, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
    tlog("modo escenario: ventana %p, %dx%d en %d,%d (escala=%d)", hwnd, w, h, x, y, g_scale);
}

/* Modo lienzo: la ventana principal ocupa la pantalla y el juego centra 640x480 en ella. */
static void adopt_canvas(HWND hwnd) {
    RECT rc;
    int cw, ch, w, h;
    if (g_mode != MODE_NONE || g_scale == 1) return;
    real_GetClientRect(hwnd, &rc);
    cw = rc.right - rc.left;
    ch = rc.bottom - rc.top;
    if (cw <= LOGICAL_W && ch <= LOGICAL_H) return;
    pick_size(cw, ch, &w, &h);
    if (w == LOGICAL_W) return;
    g_mode = MODE_CANVAS;
    g_ox = (cw - LOGICAL_W) / 2;
    g_oy = (ch - LOGICAL_H) / 2;
    g_vx = (cw - w) / 2;
    g_vy = (ch - h) / 2;
    g_vw = w;
    g_vh = h;
    subclass_target(hwnd);
    tlog("modo lienzo: ventana %p (%dx%d), origen lógico %d,%d -> vista %dx%d en %d,%d", hwnd, cw, ch, g_ox, g_oy, w, h, g_vx, g_vy);
}

/* ¿Una copia a este DC debe transformarse? Activa el modo lienzo si corresponde. */
static int maps_dc(HDC dst) {
    HWND hwnd;
    if (g_scale == 1 || !dst) return 0;
    hwnd = WindowFromDC(dst);
    if (!hwnd) return 0;
    if (g_mode == MODE_NONE && hwnd == g_mainWnd) adopt_canvas(hwnd);
    return scaled() && hwnd == g_target;
}

/* ¿El juego lee de la ventana escalada? (sin activar ningún modo) */
static int reads_target(HDC src) {
    HWND hwnd;
    if (!src || !g_shadowDC || !scaled()) return 0;
    hwnd = WindowFromDC(src);
    if (hwnd != g_target) {
        if (g_trace && !hwnd && GetObjectType(src) == OBJ_DC) {
            static int once;
            if (!once) { once = 1; tlog("aviso: copia con origen en un DC de pantalla (%p): no se traduce", src); }
        }
        return 0;
    }
    if (g_trace) {
        static int once;
        if (!once) { once = 1; tlog("BitBlt lee de la ventana: se sirve desde la sombra de 640x480"); }
    }
    return 1;
}

/* Con DIB_PAL_COLORS los índices se resuelven con la paleta del DC: la sombra usa la misma. */
static void shadow_palette(HDC dst, UINT usage) {
    HPALETTE pal;
    if (usage != DIB_PAL_COLORS || !g_shadowDC) return;
    pal = (HPALETTE)GetCurrentObject(dst, OBJ_PAL);
    if (pal) SelectPalette(g_shadowDC, pal, TRUE);
}

/* ¿El rectángulo lógico cae entero dentro del área de 640x480 (la que cubre la sombra)? */
static int in_shadow(int x, int y, int w, int h) {
    return g_shadowDC && x >= g_ox && y >= g_oy && x + w <= g_ox + LOGICAL_W && y + h <= g_oy + LOGICAL_H;
}

/*
 * Presenta en la ventana un rectángulo lógico tomándolo de la sombra, con un
 * píxel lógico de margen. Con escalas no enteras (p. ej. 2,25x) cada copia
 * escalada redondea distinto, y al restaurar el fondo bajo un objeto que se
 * mueve quedaban restos de 1 píxel; volviendo a pintar desde la sombra con
 * margen, los bordes siempre quedan con el contenido actual.
 */
static BOOL present_shadow(HDC dst, int x, int y, int w, int h) {
    int lx0 = x - 1, ly0 = y - 1, lx1 = x + w + 1, ly1 = y + h + 1, X0, Y0;
    if (lx0 < g_ox) lx0 = g_ox;
    if (ly0 < g_oy) ly0 = g_oy;
    if (lx1 > g_ox + LOGICAL_W) lx1 = g_ox + LOGICAL_W;
    if (ly1 > g_oy + LOGICAL_H) ly1 = g_oy + LOGICAL_H;
    X0 = rx(lx0); Y0 = ry(ly0);
    SetStretchBltMode(dst, COLORONCOLOR);
    return real_StretchBlt(dst, X0, Y0, rx(lx1) - X0, ry(ly1) - Y0, g_shadowDC, lx0 - g_ox, ly0 - g_oy, lx1 - lx0, ly1 - ly0,
                           SRCCOPY);
}

static BOOL stretch_mapped(HDC dst, int xd, int yd, int wd, int hd, HDC src, int xs, int ys, int ws, int hs, DWORD rop) {
    int x0 = rx(xd), y0 = ry(yd), x1 = rx(xd + wd), y1 = ry(yd + hd);
    BOOL r;
    if (in_shadow(xd, yd, wd, hd)) {
        /* La operación se hace sin escalar en la sombra y se presenta desde ahí. */
        if (wd == ws && hd == hs) r = real_BitBlt(g_shadowDC, xd - g_ox, yd - g_oy, wd, hd, src, xs, ys, rop);
        else {
            SetStretchBltMode(g_shadowDC, COLORONCOLOR);
            r = real_StretchBlt(g_shadowDC, xd - g_ox, yd - g_oy, wd, hd, src, xs, ys, ws, hs, rop);
        }
        present_shadow(dst, xd, yd, wd, hd);
        return r;
    }
    SetStretchBltMode(dst, COLORONCOLOR);
    r = real_StretchBlt(dst, x0, y0, x1 - x0, y1 - y0, src, xs, ys, ws, hs, rop);
    if (g_shadowDC) {
        if (wd == ws && hd == hs) real_BitBlt(g_shadowDC, xd - g_ox, yd - g_oy, wd, hd, src, xs, ys, rop);
        else {
            SetStretchBltMode(g_shadowDC, COLORONCOLOR);
            real_StretchBlt(g_shadowDC, xd - g_ox, yd - g_oy, wd, hd, src, xs, ys, ws, hs, rop);
        }
    }
    return r;
}

/* Exportada: WING32.DLL la llama para cada copia a pantalla. Devuelve FALSE
 * para que WING32 haga la copia normal (sin escalar). */
BOOL WINAPI TrPresent(HDC dst, int xd, int yd, int wd, int hd, HDC src, int xs, int ys, int ws, int hs) {
    if (!real_StretchBlt || !maps_dc(dst)) return FALSE;
    return stretch_mapped(dst, xd, yd, wd, hd, src, xs, ys, ws, hs, SRCCOPY);
}

static BOOL WINAPI hk_BitBlt(HDC dst, int x, int y, int w, int h, HDC src, int xs, int ys, DWORD rop) {
    /* Lectura de la ventana (guardar el fondo bajo un objeto): desde la sombra. */
    if (reads_target(src)) { src = g_shadowDC; xs -= g_ox; ys -= g_oy; }
    if (maps_dc(dst)) {
        if (src) return stretch_mapped(dst, x, y, w, h, src, xs, ys, w, h, rop);
        /* Sin origen (relleno tipo PatBlt): se escala el rectángulo. */
        {
            int x0 = rx(x), y0 = ry(y);
            if (g_shadowDC) real_BitBlt(g_shadowDC, x - g_ox, y - g_oy, w, h, NULL, 0, 0, rop);
            if (in_shadow(x, y, w, h)) return present_shadow(dst, x, y, w, h);
            return real_BitBlt(dst, x0, y0, rx(x + w) - x0, ry(y + h) - y0, NULL, 0, 0, rop);
        }
    }
    return real_BitBlt(dst, x, y, w, h, src, xs, ys, rop);
}

static BOOL WINAPI hk_StretchBlt(HDC dst, int x, int y, int w, int h, HDC src, int xs, int ys, int ws, int hs, DWORD rop) {
    if (reads_target(src)) { src = g_shadowDC; xs -= g_ox; ys -= g_oy; }
    if (maps_dc(dst)) return stretch_mapped(dst, x, y, w, h, src, xs, ys, ws, hs, rop);
    return real_StretchBlt(dst, x, y, w, h, src, xs, ys, ws, hs, rop);
}

static int WINAPI hk_StretchDIBits(HDC dst, int x, int y, int w, int h, int xs, int ys, int ws, int hs, const VOID *bits,
                                   const BITMAPINFO *bmi, UINT usage, DWORD rop) {
    if (maps_dc(dst)) {
        int x0 = rx(x), y0 = ry(y);
        if (g_shadowDC) {
            shadow_palette(dst, usage);
            SetStretchBltMode(g_shadowDC, COLORONCOLOR);
            if (real_StretchDIBits(g_shadowDC, x - g_ox, y - g_oy, w, h, xs, ys, ws, hs, bits, bmi, usage, rop) &&
                in_shadow(x, y, w, h) && present_shadow(dst, x, y, w, h))
                return h;
        }
        SetStretchBltMode(dst, COLORONCOLOR);
        return real_StretchDIBits(dst, x0, y0, rx(x + w) - x0, ry(y + h) - y0, xs, ys, ws, hs, bits, bmi, usage, rop);
    }
    return real_StretchDIBits(dst, x, y, w, h, xs, ys, ws, hs, bits, bmi, usage, rop);
}

/*
 * SetDIBitsToDevice no escala. Para el caso habitual (todas las líneas de una
 * vez) se reemplaza por StretchDIBits. Ojo: en SetDIBitsToDevice el origen Y
 * se mide desde abajo en DIBs bottom-up, igual que en StretchDIBits.
 */
static int WINAPI hk_SetDIBitsToDevice(HDC dst, int x, int y, DWORD w, DWORD h, int xs, int ys, UINT start, UINT lines,
                                       const VOID *bits, const BITMAPINFO *bmi, UINT usage) {
    if (bmi && start == 0 && (DWORD)abs(bmi->bmiHeader.biHeight) == lines && maps_dc(dst)) {
        int x0 = rx(x), y0 = ry(y);
        if (g_shadowDC) {
            shadow_palette(dst, usage);
            SetStretchBltMode(g_shadowDC, COLORONCOLOR);
            if (real_StretchDIBits(g_shadowDC, x - g_ox, y - g_oy, (int)w, (int)h, xs, ys, (int)w, (int)h, bits, bmi, usage, SRCCOPY) &&
                in_shadow(x, (int)y, (int)w, (int)h) && present_shadow(dst, x, y, (int)w, (int)h))
                return (int)lines;
        }
        SetStretchBltMode(dst, COLORONCOLOR);
        return real_StretchDIBits(dst, x0, y0, rx(x + (int)w) - x0, ry(y + (int)h) - y0, xs, ys, (int)w, (int)h, bits, bmi,
                                  usage, SRCCOPY) ? (int)lines : 0;
    }
    return real_SetDIBitsToDevice(dst, x, y, w, h, xs, ys, start, lines, bits, bmi, usage);
}

static BOOL WINAPI hk_GetClientRect(HWND hwnd, LPRECT rc) {
    BOOL r = real_GetClientRect(hwnd, rc);
    if (r && rc && g_mode == MODE_STAGE && hwnd == g_target) { rc->left = rc->top = 0; rc->right = LOGICAL_W; rc->bottom = LOGICAL_H; }
    return r;
}

static void map_rect_to_real(const RECT *in, RECT *out) {
    out->left = rx(in->left) - 1; out->top = ry(in->top) - 1;
    out->right = rx(in->right) + 1; out->bottom = ry(in->bottom) + 1;
}

static BOOL WINAPI hk_InvalidateRect(HWND hwnd, const RECT *rc, BOOL erase) {
    RECT r2;
    if (hwnd == g_target && rc && scaled()) { map_rect_to_real(rc, &r2); rc = &r2; }
    return real_InvalidateRect(hwnd, rc, erase);
}

static BOOL WINAPI hk_ValidateRect(HWND hwnd, const RECT *rc) {
    RECT r2;
    if (hwnd == g_target && rc && scaled()) { map_rect_to_real(rc, &r2); rc = &r2; }
    return real_ValidateRect(hwnd, rc);
}

/* Si el juego reubica el escenario, mantenemos nuestra ubicación escalada. */
static BOOL WINAPI hk_SetWindowPos(HWND hwnd, HWND after, int x, int y, int w, int h, UINT flags) {
    if (g_mode == MODE_STAGE && hwnd == g_target && scaled()) {
        if (!(flags & SWP_NOMOVE)) { g_gameX = x; g_gameY = y; }
        flags |= SWP_NOMOVE | SWP_NOSIZE;
    }
    return real_SetWindowPos(hwnd, after, x, y, w, h, flags);
}

static BOOL WINAPI hk_MoveWindow(HWND hwnd, int x, int y, int w, int h, BOOL repaint) {
    if (g_mode == MODE_STAGE && hwnd == g_target && scaled()) {
        g_gameX = x;
        g_gameY = y;
        if (repaint) real_InvalidateRect(hwnd, NULL, FALSE);
        return TRUE;
    }
    return real_MoveWindow(hwnd, x, y, w, h, repaint);
}

/* ------------------------------------------------------------------ */
/* Utilidades de rutas                                                  */
/* ------------------------------------------------------------------ */

static const char *basename_of(const char *p) {
    const char *b = p, *s;
    for (s = p; *s; s++) if (*s == '\\' || *s == '/' || *s == ':') b = s + 1;
    return b;
}

/* ¿Se refiere a KA.INI en el directorio de Windows (o sin ruta)? */
static int is_ka_ini(const char *file) {
    if (!file || !g_kaIni[0]) return 0;
    if (_stricmp(basename_of(file), "KA.INI") != 0) return 0;
    if (basename_of(file) == file) return 1; /* sin ruta → %WINDIR% */
    {
        char win[MAX_PATH];
        size_t n = GetWindowsDirectoryA(win, sizeof win);
        return n && _strnicmp(file, win, n) == 0;
    }
}

static const char *redirect_ini(const char *file) {
    if (is_ka_ini(file)) return g_kaIni;
    return file;
}

/* ------------------------------------------------------------------ */
/* Hooks                                                                */
/* ------------------------------------------------------------------ */

typedef DWORD(WINAPI *GPPS_t)(LPCSTR, LPCSTR, LPCSTR, LPSTR, DWORD, LPCSTR);
typedef UINT(WINAPI *GPPI_t)(LPCSTR, LPCSTR, INT, LPCSTR);
typedef BOOL(WINAPI *WPPS_t)(LPCSTR, LPCSTR, LPCSTR, LPCSTR);
typedef DWORD(WINAPI *GPPSec_t)(LPCSTR, LPSTR, DWORD, LPCSTR);
typedef HANDLE(WINAPI *CFA_t)(LPCSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);
typedef UINT(WINAPI *GDT_t)(LPCSTR);
typedef BOOL(WINAPI *GVI_t)(LPCSTR, LPSTR, DWORD, LPDWORD, LPDWORD, LPDWORD, LPSTR, DWORD);
typedef LONG(WINAPI *CDS_t)(DEVMODEA *, DWORD);
typedef BOOL(WINAPI *SSC_t)(int, const INT *, const COLORREF *);
typedef UINT(WINAPI *SSPU_t)(HDC, UINT);
typedef UINT_PTR(WINAPI *SHABM_t)(DWORD, PAPPBARDATA);
typedef int(WINAPI *MBA_t)(HWND, LPCSTR, LPCSTR, UINT);
typedef HWND(WINAPI *CWEA_t)(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
typedef BOOL(WINAPI *GCP_t)(LPPOINT);
typedef BOOL(WINAPI *SCP_t)(int, int);
typedef HMODULE(WINAPI *LLA_t)(LPCSTR);

static GPPS_t real_GetPrivateProfileStringA;
static GPPI_t real_GetPrivateProfileIntA;
static WPPS_t real_WritePrivateProfileStringA;
static GPPSec_t real_GetPrivateProfileSectionA;
static CFA_t real_CreateFileA;
static GDT_t real_GetDriveTypeA;
static GVI_t real_GetVolumeInformationA;
static CDS_t real_ChangeDisplaySettingsA;
static SSC_t real_SetSysColors;
static SSPU_t real_SetSystemPaletteUse;
static SHABM_t real_SHAppBarMessage;
static MBA_t real_MessageBoxA;
static CWEA_t real_CreateWindowExA;
static GCP_t real_GetCursorPos;
static SCP_t real_SetCursorPos;
static LLA_t real_LoadLibraryA;

static DWORD WINAPI hk_GetPrivateProfileStringA(LPCSTR app, LPCSTR key, LPCSTR def, LPSTR out, DWORD size, LPCSTR file) {
    const char *f = redirect_ini(file);
    DWORD r = real_GetPrivateProfileStringA(app, key, def, out, size, f);
    if (g_trace) tlog("INI get [%s] %s @ %s -> \"%s\"", app ? app : "(null)", key ? key : "(null)", f ? f : "(null)",
                      (out && key) ? out : "(lista)");
    return r;
}

static UINT WINAPI hk_GetPrivateProfileIntA(LPCSTR app, LPCSTR key, INT def, LPCSTR file) {
    const char *f = redirect_ini(file);
    UINT r = real_GetPrivateProfileIntA(app, key, def, f);
    if (g_trace) tlog("INI int [%s] %s @ %s -> %u", app, key, f, r);
    return r;
}

static BOOL WINAPI hk_WritePrivateProfileStringA(LPCSTR app, LPCSTR key, LPCSTR val, LPCSTR file) {
    const char *f = redirect_ini(file);
    if (g_trace) tlog("INI set [%s] %s=%s @ %s", app, key ? key : "(null)", val ? val : "(null)", f);
    return real_WritePrivateProfileStringA(app, key, val, f);
}

static DWORD WINAPI hk_GetPrivateProfileSectionA(LPCSTR app, LPSTR out, DWORD size, LPCSTR file) {
    return real_GetPrivateProfileSectionA(app, out, size, redirect_ini(file));
}

/*
 * ACES crea su archivo de intercambio "~~ka.swp" en la raíz de una unidad
 * (C:\~~ka.swp), donde un usuario estándar puede no tener permiso de escritura.
 * Lo redirigimos a TRAMPOLIN_SWAPDIR (por defecto, la carpeta del juego).
 */
static const char *redirect_file(const char *name, char *buf, size_t size) {
    if (name && _stricmp(basename_of(name), "~~ka.swp") == 0 && g_swapDir[0]) {
        _snprintf(buf, size, "%s\\~~ka.swp", g_swapDir);
        buf[size - 1] = 0;
        return buf;
    }
    return name;
}

/*
 * ACES recorre cada carpeta de una ruta con FindFirstFileA y descarta las que
 * tienen el atributo oculto o de sistema (como el findfirst de DOS sin
 * _A_HIDDEN). La instalación predeterminada está bajo %LOCALAPPDATA%, dentro de
 * AppData (oculta), así que al guardar la ficha de un alumno la ruta resultaba
 * "badly formed" y el juego mostraba "Couldn't save data to file". Ocultamos
 * esos atributos al juego.
 */
#define TR_HIDE_ATTRS (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)
/* Sin atributos, Windows informa FILE_ATTRIBUTE_NORMAL (nunca 0). */
static DWORD visible_attrs(DWORD a) { a &= ~TR_HIDE_ATTRS; return a ? a : FILE_ATTRIBUTE_NORMAL; }
typedef HANDLE(WINAPI *FFFA_t)(LPCSTR, LPWIN32_FIND_DATAA);
typedef BOOL(WINAPI *FNFA_t)(HANDLE, LPWIN32_FIND_DATAA);
typedef DWORD(WINAPI *GFAA_t)(LPCSTR);
static FFFA_t real_FindFirstFileA;
static FNFA_t real_FindNextFileA;
static GFAA_t real_GetFileAttributesA;

static HANDLE WINAPI hk_FindFirstFileA(LPCSTR name, LPWIN32_FIND_DATAA fd) {
    HANDLE h = real_FindFirstFileA(name, fd);
    if (h != INVALID_HANDLE_VALUE && fd) fd->dwFileAttributes = visible_attrs(fd->dwFileAttributes);
    if (g_trace) tlog("FIND %s -> %s", name ? name : "(null)", h != INVALID_HANDLE_VALUE ? "ok" : "no");
    return h;
}

static BOOL WINAPI hk_FindNextFileA(HANDLE h, LPWIN32_FIND_DATAA fd) {
    BOOL r = real_FindNextFileA(h, fd);
    if (r && fd) fd->dwFileAttributes = visible_attrs(fd->dwFileAttributes);
    return r;
}

static DWORD WINAPI hk_GetFileAttributesA(LPCSTR name) {
    DWORD r = real_GetFileAttributesA(name);
    return r == INVALID_FILE_ATTRIBUTES ? r : visible_attrs(r);
}

typedef BOOL(WINAPI *DFA_t)(LPCSTR);
static DFA_t real_DeleteFileA;
static BOOL WINAPI hk_DeleteFileA(LPCSTR name) {
    char buf[MAX_PATH];
    return real_DeleteFileA(redirect_file(name, buf, sizeof buf));
}

static HANDLE WINAPI hk_CreateFileA(LPCSTR name, DWORD acc, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD disp, DWORD flags, HANDLE tmpl) {
    char buf[MAX_PATH];
    HANDLE h;
    name = redirect_file(name, buf, sizeof buf);
    h = real_CreateFileA(name, acc, share, sa, disp, flags, tmpl);
    if (g_trace || h == INVALID_HANDLE_VALUE)
        tlog("FILE %s %s -> %s (err %lu)", (acc & GENERIC_WRITE) ? "W" : "R", name ? name : "(null)",
             h == INVALID_HANDLE_VALUE ? "FAIL" : "ok", h == INVALID_HANDLE_VALUE ? GetLastError() : 0);
    return h;
}

/* APIs de archivo de Windows 3.1 (las usa PEEWEE): se registran igual que CreateFileA. */
typedef HFILE(WINAPI *OF_t)(LPCSTR, LPOFSTRUCT, UINT);
typedef HFILE(WINAPI *LO_t)(LPCSTR, int);
static OF_t real_OpenFile;
static LO_t real__lopen;
static HFILE WINAPI hk_OpenFile(LPCSTR name, LPOFSTRUCT of, UINT style) {
    HFILE h = real_OpenFile(name, of, style);
    if (g_trace || h == HFILE_ERROR)
        tlog("OPENFILE %s style=%x -> %s (err %lu)", name ? name : "(null)", style, h == HFILE_ERROR ? "FAIL" : "ok",
             h == HFILE_ERROR ? GetLastError() : 0);
    return h;
}
static HFILE WINAPI hk__lopen(LPCSTR name, int mode) {
    HFILE h = real__lopen(name, mode);
    if (g_trace || h == HFILE_ERROR)
        tlog("LOPEN %s mode=%x -> %s (err %lu)", name ? name : "(null)", mode, h == HFILE_ERROR ? "FAIL" : "ok",
             h == HFILE_ERROR ? GetLastError() : 0);
    return h;
}

/*
 * Los juegos calculan el espacio libre como clusters x sectores x bytes en 32
 * bits: con discos actuales la cuenta desborda y puede dar "sin espacio".
 * Limitamos lo informado a menos de 2 GB (como en Windows 95).
 */
typedef BOOL(WINAPI *GDFS_t)(LPCSTR, LPDWORD, LPDWORD, LPDWORD, LPDWORD);
static GDFS_t real_GetDiskFreeSpaceA;
static BOOL WINAPI hk_GetDiskFreeSpaceA(LPCSTR root, LPDWORD spc, LPDWORD bps, LPDWORD freeC, LPDWORD totalC) {
    DWORD a = 0, b = 0, f = 0, t = 0;
    BOOL r = real_GetDiskFreeSpaceA(root, &a, &b, &f, &t);
    if (r && a && b) {
        unsigned __int64 cluster = (unsigned __int64)a * b;
        DWORD maxC = (DWORD)(0x7FF00000ULL / cluster);
        if (f > maxC) f = maxC;
        if (t > maxC) t = maxC;
    }
    if (spc) *spc = a;
    if (bps) *bps = b;
    if (freeC) *freeC = f;
    if (totalC) *totalC = t;
    return r;
}

static int is_virtual_cd(LPCSTR root) {
    return g_cdDrive && root && (root[0] & ~0x20) == g_cdDrive && root[1] == ':';
}

static UINT WINAPI hk_GetDriveTypeA(LPCSTR root) {
    if (is_virtual_cd(root)) return DRIVE_CDROM;
    return real_GetDriveTypeA(root);
}

static BOOL WINAPI hk_GetVolumeInformationA(LPCSTR root, LPSTR vol, DWORD volSize, LPDWORD serial, LPDWORD maxLen,
                                            LPDWORD fsFlags, LPSTR fsName, DWORD fsSize) {
    BOOL r = real_GetVolumeInformationA(root, vol, volSize, serial, maxLen, fsFlags, fsName, fsSize);
    if (is_virtual_cd(root)) {
        if (vol && volSize) lstrcpynA(vol, g_cdLabel, volSize);
        if (fsName && fsSize) lstrcpynA(fsName, "CDFS", fsSize);
        r = TRUE;
    }
    if (g_trace) tlog("VOLUME %s -> \"%s\" (%d)", root ? root : "(null)", (vol && r) ? vol : "", r);
    return r;
}

static LONG WINAPI hk_ChangeDisplaySettingsA(DEVMODEA *dm, DWORD flags) {
    tlog("ChangeDisplaySettingsA ignorado (%lux%lux%lu, flags %lx)", dm ? dm->dmPelsWidth : 0, dm ? dm->dmPelsHeight : 0,
         dm ? dm->dmBitsPerPel : 0, flags);
    return DISP_CHANGE_SUCCESSFUL;
}

static BOOL WINAPI hk_SetSysColors(int n, const INT *el, const COLORREF *rgb) {
    (void)el; (void)rgb;
    tlog("SetSysColors(%d) ignorado", n);
    return TRUE;
}

static UINT WINAPI hk_SetSystemPaletteUse(HDC dc, UINT use) {
    (void)dc; (void)use;
    return SYSPAL_STATIC;
}

static UINT_PTR WINAPI hk_SHAppBarMessage(DWORD msg, PAPPBARDATA data) {
    if (msg == ABM_SETSTATE) {
        tlog("SHAppBarMessage(ABM_SETSTATE) ignorado");
        return 0;
    }
    return real_SHAppBarMessage(msg, data);
}

static int WINAPI hk_MessageBoxA(HWND hwnd, LPCSTR text, LPCSTR caption, UINT type) {
    tlog("MessageBox [%s] \"%s\" type=%x", caption ? caption : "", text ? text : "", type);
    return real_MessageBoxA(hwnd, text, caption, type);
}

static HWND WINAPI hk_CreateWindowExA(DWORD ex, LPCSTR cls, LPCSTR title, DWORD style, int x, int y, int w, int h,
                                      HWND parent, HMENU menu, HINSTANCE inst, LPVOID param) {
    HWND r = real_CreateWindowExA(ex, cls, title, style, x, y, w, h, parent, menu, inst, param);
    if (g_trace) tlog("CreateWindowEx class=%s title=%s style=%lx %d,%d %dx%d parent=%p -> %p",
                      ((ULONG_PTR)cls >> 16) ? cls : "(atom)", title ? title : "", style, x, y, w, h, parent, r);
    if (r && !parent && !g_mainWnd && (style & WS_CHILD) == 0) g_mainWnd = r;
    /* La ventana de 640x480 es el escenario donde el motor dibuja. */
    if (r && w == LOGICAL_W && h == LOGICAL_H && (style & WS_CHILD)) adopt_stage(r, x, y);
    return r;
}

/*
 * Mouse: el juego convierte posiciones de pantalla a cliente con el origen
 * real de la ventana destino. Dentro de esa ventana, el punto real R se ve
 * como el lógico lx(R); fuera del mapeo no se toca nada.
 */
static int target_origin(POINT *o) {
    if (!scaled()) return 0;
    o->x = o->y = 0;
    return ClientToScreen(g_target, o);
}

/* Punto de pantalla real -> el que el juego espera (ver arriba). */
/*
 * Origen en pantalla del área cliente de la ventana destino tal como lo ve el
 * juego. En modo escenario la ventana real está agrandada y recentrada, pero el
 * juego sigue creyendo que está donde la creó (p. ej. 640x480 centrada en
 * 363,144) y hace cuentas con esa posición (al arrastrar objetos resta ese
 * origen al puntero). Todas las coordenadas de pantalla que ve el juego se
 * expresan respecto de ese origen virtual. En modo lienzo coincide con el real.
 */
static void game_origin(POINT *g) {
    if (g_mode == MODE_STAGE) {
        g->x = g_gameX;
        g->y = g_gameY;
        ClientToScreen(GetParent(g_target), g);
    } else {
        g->x = g->y = 0;
        ClientToScreen(g_target, g);
    }
}

/* Punto de pantalla real -> el que espera el juego. */
static void map_screen_point(POINT *p) {
    POINT o, g;
    if (target_origin(&o)) {
        game_origin(&g);
        p->x = g.x + lx(p->x - o.x);
        p->y = g.y + ly(p->y - o.y);
    }
}

/* Punto de pantalla del juego -> real. */
static void unmap_screen_point(POINT *p) {
    POINT o, g;
    if (target_origin(&o)) {
        game_origin(&g);
        p->x = o.x + rx(p->x - g.x);
        p->y = o.y + ry(p->y - g.y);
    }
}

/* ¿Hay que presentar al juego la ventana en su posición virtual? */
static int virtual_stage(HWND h) { return h && h == g_target && g_mode == MODE_STAGE && scaled(); }

static BOOL WINAPI hk_GetCursorPos(LPPOINT p) {
    BOOL r = real_GetCursorPos(p);
    if (r && p) {
        POINT in = *p;
        map_screen_point(p);
        if (g_trace) {
            static POINT last;
            if (in.x != last.x || in.y != last.y) tlog("GetCursorPos %ld,%ld -> %ld,%ld", in.x, in.y, p->x, p->y);
            last = in;
        }
    }
    return r;
}

/*
 * MFC también lee la posición del mouse de GetMessagePos y del campo pt de
 * MSG (por ejemplo, mientras se arrastra un objeto con el mouse capturado).
 * Sin traducirlas, el objeto arrastrado se separaba del puntero en
 * proporción a la escala.
 */
typedef DWORD(WINAPI *GMP_t)(void);
typedef BOOL(WINAPI *GMA_t)(LPMSG, HWND, UINT, UINT);
typedef BOOL(WINAPI *PMA_t)(LPMSG, HWND, UINT, UINT, UINT);
static GMP_t real_GetMessagePos;
static GMA_t real_GetMessageA;
static PMA_t real_PeekMessageA;

static DWORD WINAPI hk_GetMessagePos(void) {
    DWORD r = real_GetMessagePos();
    POINT p;
    if (!scaled()) return r;
    p.x = (short)LOWORD(r);
    p.y = (short)HIWORD(r);
    map_screen_point(&p);
    if (g_trace) tlog("GetMessagePos %d,%d -> %ld,%ld", (short)LOWORD(r), (short)HIWORD(r), p.x, p.y);
    return MAKELONG((short)p.x, (short)p.y);
}

static BOOL WINAPI hk_GetMessageA(LPMSG m, HWND h, UINT a, UINT b) {
    BOOL r = real_GetMessageA(m, h, a, b);
    if (r != -1 && m) map_screen_point(&m->pt);
    return r;
}

static BOOL WINAPI hk_PeekMessageA(LPMSG m, HWND h, UINT a, UINT b, UINT rm) {
    BOOL r = real_PeekMessageA(m, h, a, b, rm);
    if (r && m) map_screen_point(&m->pt);
    return r;
}

typedef BOOL(WINAPI *CTS_t)(HWND, LPPOINT);
typedef int(WINAPI *MWP_t)(HWND, HWND, LPPOINT, UINT);
typedef BOOL(WINAPI *GWR_t)(HWND, LPRECT);
typedef HWND(WINAPI *WFP_t)(POINT);
static CTS_t real_ClientToScreen, real_ScreenToClient;
static MWP_t real_MapWindowPoints;
static GWR_t real_GetWindowRect;
static WFP_t real_WindowFromPoint;

static BOOL WINAPI hk_ClientToScreen(HWND h, LPPOINT p) {
    POINT g;
    if (!virtual_stage(h) || !p) return real_ClientToScreen(h, p);
    game_origin(&g);
    p->x += g.x; p->y += g.y;
    return TRUE;
}

static BOOL WINAPI hk_ScreenToClient(HWND h, LPPOINT p) {
    POINT g;
    if (!virtual_stage(h) || !p) return real_ScreenToClient(h, p);
    game_origin(&g);
    p->x -= g.x; p->y -= g.y;
    return TRUE;
}

static int WINAPI hk_MapWindowPoints(HWND from, HWND to, LPPOINT pts, UINT n) {
    UINT i;
    LONG dx = 0, dy = 0;
    if ((!virtual_stage(from) && !virtual_stage(to)) || !pts) return real_MapWindowPoints(from, to, pts, n);
    for (i = 0; i < n; i++) {
        POINT a = pts[i];
        if (from) hk_ClientToScreen(from, &pts[i]);
        if (to) hk_ScreenToClient(to, &pts[i]);
        if (i == 0) { dx = pts[0].x - a.x; dy = pts[0].y - a.y; }
    }
    return MAKELONG((short)dx, (short)dy);
}

static BOOL WINAPI hk_GetWindowRect(HWND h, LPRECT r) {
    POINT g;
    if (!virtual_stage(h) || !r) return real_GetWindowRect(h, r);
    game_origin(&g);
    r->left = g.x; r->top = g.y; r->right = g.x + LOGICAL_W; r->bottom = g.y + LOGICAL_H;
    return TRUE;
}

static HWND WINAPI hk_WindowFromPoint(POINT p) {
    if (g_mode == MODE_STAGE) unmap_screen_point(&p);
    return real_WindowFromPoint(p);
}

/* Diagnóstico (solo con traza): consultas al estado físico de los botones/teclas. */
typedef SHORT(WINAPI *GAKS_t)(int);
static GAKS_t real_GetAsyncKeyState;
static SHORT WINAPI hk_GetAsyncKeyState(int vk) {
    SHORT r = real_GetAsyncKeyState(vk);
    if (g_trace) {
        static int lastVk = -1;
        static SHORT lastR = 0x7fff;
        if (vk != lastVk || r != lastR) tlog("GetAsyncKeyState(%d) -> %04x", vk, (unsigned short)r);
        lastVk = vk; lastR = r;
    }
    return r;
}

static BOOL WINAPI hk_SetCursorPos(int x, int y) {
    POINT p;
    int x0 = x, y0 = y;
    p.x = x; p.y = y;
    unmap_screen_point(&p);
    x = p.x; y = p.y;
    if (g_trace) tlog("SetCursorPos %d,%d -> %d,%d", x0, y0, x, y);
    return real_SetCursorPos(x, y);
}

/* ------------------------------------------------------------------ */
/* Parcheo de IAT                                                       */
/* ------------------------------------------------------------------ */

typedef struct { const char *dll; const char *name; void *hook; void **real; } Hook;

static HMODULE WINAPI hk_LoadLibraryA(LPCSTR name);

/*
 * Audio: WSOUND32.DLL (1996) pasa el ID de dispositivo como entero de 16 bits,
 * así que WAVE_MAPPER (-1) llega como 0xFFFF. Windows 9x lo aceptaba; la pila
 * de audio actual puede quedarse bloqueada. Lo normalizamos.
 */
typedef MMRESULT(WINAPI *WOO_t)(LPHWAVEOUT, UINT, LPCWAVEFORMATEX, DWORD_PTR, DWORD_PTR, DWORD);
static WOO_t real_waveOutOpen;

/*
 * ¿El hilo actual tiene tomado el "loader lock"? (estamos dentro de un DllMain)
 * PEB (x86) +0xA0 = LoaderLock (RTL_CRITICAL_SECTION*), cuyo campo
 * OwningThread (+0x0C) es el id del hilo dueño.
 */
static int in_loader_lock(void) {
#ifdef _M_IX86
    BYTE *peb = (BYTE *)__readfsdword(0x30);
    RTL_CRITICAL_SECTION *cs = *(RTL_CRITICAL_SECTION **)(peb + 0xA0);
    return cs && (DWORD)(ULONG_PTR)cs->OwningThread == GetCurrentThreadId();
#else
    return 0;
#endif
}

static MMRESULT WINAPI hk_waveOutOpen(LPHWAVEOUT h, UINT dev, LPCWAVEFORMATEX fmt, DWORD_PTR cb, DWORD_PTR inst, DWORD flags) {
    MMRESULT r;
    DWORD t0 = GetTickCount();
    if (dev == 0xFFFF) dev = WAVE_MAPPER;
    /*
     * WSOUND32.DLL sondea el dispositivo de audio desde su DllMain. En Windows
     * moderno, abrir audio con el loader lock tomado produce un deadlock.
     * Respondemos "dispositivo ocupado" (MMSYSERR_ALLOCATED), que el motor
     * interpreta como "el formato está soportado" sin necesitar un handle.
     */
    if (in_loader_lock() && !(flags & WAVE_FORMAT_QUERY)) {
        tlog("waveOutOpen dentro de DllMain: se responde MMSYSERR_ALLOCATED para evitar el bloqueo");
        return MMSYSERR_ALLOCATED;
    }
    r = real_waveOutOpen(h, dev, fmt, cb, inst, flags);
    if (g_trace)
        tlog("waveOutOpen dev=%d fmt=%u ch=%u %luHz %ubits flags=%lx -> %u (%lu ms)", (int)dev, fmt ? fmt->wFormatTag : 0,
             fmt ? fmt->nChannels : 0, fmt ? fmt->nSamplesPerSec : 0, fmt ? fmt->wBitsPerSample : 0, flags, r,
             GetTickCount() - t0);
    return r;
}

/*
 * waveOutClose / waveOutReset pueden bloquearse para siempre si se llaman
 * desde el hilo de la interfaz sin procesar mensajes (el servicio de audio de
 * Windows necesita que ese hilo responda). Los ejecutamos en un hilo auxiliar
 * mientras el hilo del juego sigue procesando mensajes, con un tiempo máximo.
 */
typedef MMRESULT(WINAPI *WOH_t)(HWAVEOUT);
static WOH_t real_waveOutClose, real_waveOutReset;
typedef struct { WOH_t fn; HWAVEOUT h; volatile MMRESULT r; } WaveJob;

static DWORD WINAPI wave_worker(LPVOID p) {
    WaveJob *j = (WaveJob *)p;
    j->r = j->fn(j->h);
    return 0;
}

static MMRESULT run_wave_pumping(WOH_t fn, HWAVEOUT h, const char *name) {
    WaveJob *j;
    HANDLE th;
    DWORD start = GetTickCount();
    int quit = 0;
    WPARAM quitCode = 0;
    MMRESULT r;
    if (!fn) return MMSYSERR_ERROR;
    /*
     * Con el loader lock tomado (WSOUND32 cierra el audio en su DllMain al
     * terminar el proceso) la llamada real se bloquea para siempre. El proceso
     * está terminando y Windows libera el dispositivo igual: no hacemos nada.
     */
    if (in_loader_lock()) {
        tlog("%s dentro de DllMain: se omite para evitar el bloqueo al salir", name);
        return MMSYSERR_NOERROR;
    }
    j = (WaveJob *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *j);
    if (!j) return fn(h);
    j->fn = fn; j->h = h; j->r = MMSYSERR_NOERROR;
    th = CreateThread(NULL, 0, wave_worker, j, 0, NULL);
    if (!th) { HeapFree(GetProcessHeap(), 0, j); return fn(h); }
    for (;;) {
        MSG m;
        DWORD w = MsgWaitForMultipleObjects(1, &th, FALSE, 50, QS_ALLINPUT);
        if (w == WAIT_OBJECT_0) break;
        while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) {
            if (m.message == WM_QUIT) { quit = 1; quitCode = m.wParam; continue; }
            TranslateMessage(&m);
            DispatchMessageA(&m);
        }
        if (GetTickCount() - start > 4000) {
            tlog("%s no respondió en 4 s: se continúa sin esperar", name);
            CloseHandle(th);
            if (quit) PostQuitMessage((int)quitCode);
            return MMSYSERR_NOERROR; /* el hilo auxiliar conserva el bloque j */
        }
    }
    CloseHandle(th);
    r = j->r;
    HeapFree(GetProcessHeap(), 0, j);
    if (quit) PostQuitMessage((int)quitCode);
    if (g_trace) tlog("%s(%p) -> %u (%lu ms)", name, h, r, GetTickCount() - start);
    return r;
}

static MMRESULT WINAPI hk_waveOutClose(HWAVEOUT h) { return run_wave_pumping(real_waveOutClose, h, "waveOutClose"); }
static MMRESULT WINAPI hk_waveOutReset(HWAVEOUT h) { return run_wave_pumping(real_waveOutReset, h, "waveOutReset"); }

/* Diagnóstico (solo con traza): ¿el juego realmente envía audio y con qué volumen? */
typedef MMRESULT(WINAPI *WOW_t)(HWAVEOUT, LPWAVEHDR, UINT);
typedef MMRESULT(WINAPI *WOSV_t)(HWAVEOUT, DWORD);
static WOW_t real_waveOutWrite;
static WOSV_t real_waveOutSetVolume;
static MMRESULT WINAPI hk_waveOutWrite(HWAVEOUT h, LPWAVEHDR hdr, UINT size) {
    MMRESULT r = real_waveOutWrite(h, hdr, size);
    if (g_trace) {
        static LONG n;
        LONG k = InterlockedIncrement(&n);
        if (k <= 5 || (k % 50) == 0) {
            int mn = 255, mx = 0;
            DWORD i;
            if (hdr && hdr->lpData)
                for (i = 0; i < hdr->dwBufferLength; i++) {
                    int v = (BYTE)hdr->lpData[i];
                    if (v < mn) mn = v;
                    if (v > mx) mx = v;
                }
            tlog("waveOutWrite #%ld %p %lu bytes -> %u (muestras %d..%d)", k, h, hdr ? hdr->dwBufferLength : 0, r, mn, mx);
        }
    }
    return r;
}
static MMRESULT WINAPI hk_waveOutSetVolume(HWAVEOUT h, DWORD vol) {
    MMRESULT r = real_waveOutSetVolume(h, vol);
    if (g_trace) tlog("waveOutSetVolume %p %08lX -> %u", h, vol, r);
    return r;
}

static Hook g_hooks[] = {
    { "KERNEL32.DLL", "GetPrivateProfileStringA", hk_GetPrivateProfileStringA, (void **)&real_GetPrivateProfileStringA },
    { "KERNEL32.DLL", "GetPrivateProfileIntA", hk_GetPrivateProfileIntA, (void **)&real_GetPrivateProfileIntA },
    { "KERNEL32.DLL", "WritePrivateProfileStringA", hk_WritePrivateProfileStringA, (void **)&real_WritePrivateProfileStringA },
    { "KERNEL32.DLL", "GetPrivateProfileSectionA", hk_GetPrivateProfileSectionA, (void **)&real_GetPrivateProfileSectionA },
    { "KERNEL32.DLL", "CreateFileA", hk_CreateFileA, (void **)&real_CreateFileA },
    { "KERNEL32.DLL", "DeleteFileA", hk_DeleteFileA, (void **)&real_DeleteFileA },
    { "KERNEL32.DLL", "OpenFile", hk_OpenFile, (void **)&real_OpenFile },
    { "KERNEL32.DLL", "_lopen", hk__lopen, (void **)&real__lopen },
    { "KERNEL32.DLL", "GetFileAttributesA", hk_GetFileAttributesA, (void **)&real_GetFileAttributesA },
    { "KERNEL32.DLL", "FindFirstFileA", hk_FindFirstFileA, (void **)&real_FindFirstFileA },
    { "KERNEL32.DLL", "FindNextFileA", hk_FindNextFileA, (void **)&real_FindNextFileA },
    { "KERNEL32.DLL", "GetDriveTypeA", hk_GetDriveTypeA, (void **)&real_GetDriveTypeA },
    { "KERNEL32.DLL", "GetDiskFreeSpaceA", hk_GetDiskFreeSpaceA, (void **)&real_GetDiskFreeSpaceA },
    { "KERNEL32.DLL", "GetVolumeInformationA", hk_GetVolumeInformationA, (void **)&real_GetVolumeInformationA },
    { "KERNEL32.DLL", "LoadLibraryA", hk_LoadLibraryA, (void **)&real_LoadLibraryA },
    { "KERNEL32.DLL", "SetUnhandledExceptionFilter", hk_SetUnhandledExceptionFilter, (void **)&real_SetUnhandledExceptionFilter },
    { "USER32.DLL", "ChangeDisplaySettingsA", hk_ChangeDisplaySettingsA, (void **)&real_ChangeDisplaySettingsA },
    { "USER32.DLL", "SetSysColors", hk_SetSysColors, (void **)&real_SetSysColors },
    { "USER32.DLL", "MessageBoxA", hk_MessageBoxA, (void **)&real_MessageBoxA },
    { "USER32.DLL", "CreateWindowExA", hk_CreateWindowExA, (void **)&real_CreateWindowExA },
    { "USER32.DLL", "GetCursorPos", hk_GetCursorPos, (void **)&real_GetCursorPos },
    { "USER32.DLL", "SetCursorPos", hk_SetCursorPos, (void **)&real_SetCursorPos },
    { "USER32.DLL", "GetMessagePos", hk_GetMessagePos, (void **)&real_GetMessagePos },
    { "USER32.DLL", "GetAsyncKeyState", hk_GetAsyncKeyState, (void **)&real_GetAsyncKeyState },
    { "USER32.DLL", "ClientToScreen", hk_ClientToScreen, (void **)&real_ClientToScreen },
    { "USER32.DLL", "ScreenToClient", hk_ScreenToClient, (void **)&real_ScreenToClient },
    { "USER32.DLL", "MapWindowPoints", hk_MapWindowPoints, (void **)&real_MapWindowPoints },
    { "USER32.DLL", "GetWindowRect", hk_GetWindowRect, (void **)&real_GetWindowRect },
    { "USER32.DLL", "WindowFromPoint", hk_WindowFromPoint, (void **)&real_WindowFromPoint },
    { "USER32.DLL", "GetMessageA", hk_GetMessageA, (void **)&real_GetMessageA },
    { "USER32.DLL", "PeekMessageA", hk_PeekMessageA, (void **)&real_PeekMessageA },
    { "USER32.DLL", "GetClientRect", hk_GetClientRect, (void **)&real_GetClientRect },
    { "USER32.DLL", "InvalidateRect", hk_InvalidateRect, (void **)&real_InvalidateRect },
    { "USER32.DLL", "ValidateRect", hk_ValidateRect, (void **)&real_ValidateRect },
    { "USER32.DLL", "SetWindowPos", hk_SetWindowPos, (void **)&real_SetWindowPos },
    { "USER32.DLL", "MoveWindow", hk_MoveWindow, (void **)&real_MoveWindow },
    { "GDI32.DLL", "SetSystemPaletteUse", hk_SetSystemPaletteUse, (void **)&real_SetSystemPaletteUse },
    { "GDI32.DLL", "BitBlt", hk_BitBlt, (void **)&real_BitBlt },
    { "GDI32.DLL", "StretchBlt", hk_StretchBlt, (void **)&real_StretchBlt },
    { "GDI32.DLL", "StretchDIBits", hk_StretchDIBits, (void **)&real_StretchDIBits },
    { "GDI32.DLL", "SetDIBitsToDevice", hk_SetDIBitsToDevice, (void **)&real_SetDIBitsToDevice },
    { "SHELL32.DLL", "SHAppBarMessage", hk_SHAppBarMessage, (void **)&real_SHAppBarMessage },
};
#define NHOOKS (sizeof g_hooks / sizeof g_hooks[0])

static void resolve_reals(void) {
    size_t i;
    for (i = 0; i < NHOOKS; i++) {
        HMODULE m = GetModuleHandleA(g_hooks[i].dll);
        if (!m) m = LoadLibraryA(g_hooks[i].dll);
        *g_hooks[i].real = m ? (void *)GetProcAddress(m, g_hooks[i].name) : NULL;
    }
}

static int patch_module(HMODULE mod) {
    BYTE *base = (BYTE *)mod;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_IMPORT_DESCRIPTOR *imp;
    int patched = 0;
    if (!mod || dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir->VirtualAddress) return 0;
    for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir->VirtualAddress); imp->Name; imp++) {
        const char *dll = (const char *)(base + imp->Name);
        IMAGE_THUNK_DATA *names, *addrs;
        size_t i;
        int relevant = 0;
        for (i = 0; i < NHOOKS; i++) if (_stricmp(dll, g_hooks[i].dll) == 0) relevant = 1;
        if (!relevant) continue;
        names = (IMAGE_THUNK_DATA *)(base + (imp->OriginalFirstThunk ? imp->OriginalFirstThunk : imp->FirstThunk));
        addrs = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, addrs++) {
            const char *fn;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            fn = (const char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name;
            for (i = 0; i < NHOOKS; i++) {
                if (_stricmp(dll, g_hooks[i].dll) == 0 && strcmp(fn, g_hooks[i].name) == 0 && *g_hooks[i].real) {
                    DWORD old;
                    if (VirtualProtect(&addrs->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) {
                        addrs->u1.Function = (ULONG_PTR)g_hooks[i].hook;
                        VirtualProtect(&addrs->u1.Function, sizeof(void *), old, &old);
                        patched++;
                    }
                }
            }
        }
    }
    return patched;
}

/*
 * Parchea en la IAT de `mod` la importación `fn` (de cualquier DLL) y devuelve
 * en *orig el destino original. Se usa sobre winmm.dll, cuyas funciones
 * exportadas son stubs que saltan por su propia IAT: así se intercepta a todos
 * los llamadores del proceso, incluso a DLLs que todavía están en su DllMain.
 */
static int patch_import_any(HMODULE mod, const char *fn, void *hook, void **orig) {
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_IMPORT_DESCRIPTOR *imp;
    if (!mod) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir->VirtualAddress) return 0;
    for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir->VirtualAddress); imp->Name; imp++) {
        IMAGE_THUNK_DATA *names, *addrs;
        if (!imp->OriginalFirstThunk) continue;
        names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
        addrs = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, addrs++) {
            DWORD old;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            if (strcmp((const char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, fn) != 0) continue;
            if (!VirtualProtect(&addrs->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) return 0;
            *orig = (void *)addrs->u1.Function;
            addrs->u1.Function = (ULONG_PTR)hook;
            VirtualProtect(&addrs->u1.Function, sizeof(void *), old, &old);
            return 1;
        }
    }
    return 0;
}

/* Igual que patch_import_any, pero sobre la tabla de importaciones diferidas (delay-load). */
static int patch_delay_import_any(HMODULE mod, const char *fn, void *hook) {
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_DELAYLOAD_DESCRIPTOR *d;
    if (!mod) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
    if (!dir->VirtualAddress) return 0;
    for (d = (IMAGE_DELAYLOAD_DESCRIPTOR *)(base + dir->VirtualAddress); d->DllNameRVA; d++) {
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + d->ImportNameTableRVA);
        IMAGE_THUNK_DATA *addrs = (IMAGE_THUNK_DATA *)(base + d->ImportAddressTableRVA);
        for (; names->u1.AddressOfData; names++, addrs++) {
            DWORD old;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            if (strcmp((const char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, fn) != 0) continue;
            if (!VirtualProtect(&addrs->u1.Function, sizeof(void *), PAGE_READWRITE, &old)) return 0;
            addrs->u1.Function = (ULONG_PTR)hook;
            VirtualProtect(&addrs->u1.Function, sizeof(void *), old, &old);
            return 1;
        }
    }
    return 0;
}

/*
 * Intercepta waveOutOpen para todo el proceso. En Windows 10 winmm.dll exporta
 * un stub que salta (vía import normal o diferida) a winmmbase.dll.
 */
static void hook_winmm_fn(HMODULE winmm, HMODULE base, const char *name, void *hook, void **real) {
    void *orig = NULL;
    *real = base ? (void *)GetProcAddress(base, name) : NULL;
    if (patch_import_any(winmm, name, hook, &orig)) {
        if (!*real) *real = orig;
    } else if (!*real || !patch_delay_import_any(winmm, name, hook)) {
        tlog("aviso: no se pudo interceptar %s en winmm.dll", name);
        *real = (void *)GetProcAddress(winmm, name);
    }
}

static void hook_winmm(void) {
    HMODULE winmm = GetModuleHandleA("winmm.dll");
    HMODULE base = GetModuleHandleA("winmmbase.dll");
    if (!winmm) winmm = LoadLibraryA("winmm.dll");
    if (!base) base = LoadLibraryA("winmmbase.dll");
    hook_winmm_fn(winmm, base, "waveOutOpen", hk_waveOutOpen, (void **)&real_waveOutOpen);
    hook_winmm_fn(winmm, base, "waveOutClose", hk_waveOutClose, (void **)&real_waveOutClose);
    hook_winmm_fn(winmm, base, "waveOutReset", hk_waveOutReset, (void **)&real_waveOutReset);
    hook_winmm_fn(winmm, base, "waveOutWrite", hk_waveOutWrite, (void **)&real_waveOutWrite);
    hook_winmm_fn(winmm, base, "waveOutSetVolume", hk_waveOutSetVolume, (void **)&real_waveOutSetVolume);
}

/*
 * DPI: con el escalado de Windows (p. ej. 125 %), a un programa antiguo
 * Windows le "virtualiza" las coordenadas (pantalla de 1536x864 en lugar de
 * 1920x1080), pero no todas las API de mouse lo hacen igual: al arrastrar, el
 * puntero del juego avanzaba ~80 % de lo que avanzaba el mouse real. Declaramos
 * el proceso consciente de DPI antes de que cree ventanas: todas las API hablan
 * en píxeles físicos y nosotros ya escalamos la imagen.
 * TRAMPOLIN_DPIAWARE=0 lo desactiva (diagnóstico).
 */
static void make_dpi_aware(void) {
    typedef BOOL(WINAPI *SPDAC_t)(HANDLE);
    typedef BOOL(WINAPI *SPDA_t)(void);
    char v[8];
    HMODULE u = GetModuleHandleA("user32.dll");
    SPDAC_t ctx;
    read_env("TRAMPOLIN_DPIAWARE", v, sizeof v);
    if (v[0] == '0' || !u) return;
    ctx = (SPDAC_t)GetProcAddress(u, "SetProcessDpiAwarenessContext");
    if (ctx && ctx((HANDLE)-4 /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 */)) { tlog("DPI: proceso consciente de DPI (por monitor v2)"); return; }
    {
        SPDA_t old = (SPDA_t)GetProcAddress(u, "SetProcessDPIAware");
        if (old && old()) tlog("DPI: proceso consciente de DPI (sistema)");
        else tlog("aviso: no se pudo declarar el proceso consciente de DPI (err %lu)", GetLastError());
    }
}

static int is_system_module(HMODULE m) {
    char path[MAX_PATH], win[MAX_PATH];
    UINT n = GetWindowsDirectoryA(win, sizeof win);
    if (!GetModuleFileNameA(m, path, sizeof path)) return 1;
    return n && _strnicmp(path, win, n) == 0;
}

/* Las DLLs del propio juego (WSOUND32, SMACKW32...) se cargan luego: también se parchean. */
static HMODULE WINAPI hk_LoadLibraryA(LPCSTR name) {
    HMODULE m = real_LoadLibraryA(name);
    int n = -1;
    if (m && m != g_self && !is_system_module(m)) n = patch_module(m);
    if (g_trace || n > 0) tlog("LoadLibrary %s -> %p (%d hooks)", name ? name : "(null)", m, n);
    return m;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        char exe[MAX_PATH];
        int n;
        g_self = inst;
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&g_logLock);
        load_config();
        resolve_reals();
        SetUnhandledExceptionFilter(crash_filter);
        make_dpi_aware();
        n = patch_module(GetModuleHandleA(NULL));
        hook_winmm();
        GetModuleFileNameA(NULL, exe, sizeof exe);
        tlog("trhook cargado en %s: %d funciones interceptadas; KA.INI=%s CD=%c: \"%s\" escala=%d", exe, n,
             g_kaIni[0] ? g_kaIni : "(sistema)", g_cdDrive ? g_cdDrive : '-', g_cdLabel, g_scale);
    } else if (reason == DLL_PROCESS_DETACH) {
        tlog("trhook descargado");
        if (g_log) fclose(g_log);
        g_log = NULL;
    }
    return TRUE;
}
