/*
 * WING32.DLL de reemplazo para Trampolín Runtime.
 *
 * El WING32.DLL original (1994) se niega a funcionar si no está en
 * C:\WINDOWS\SYSTEM32 y depende del modo de 256 colores para mostrar bien
 * los colores. Esta implementación usa DIB sections de 8 bpp: al copiar una
 * DIB de 8 bpp a una pantalla de 32 bpp, GDI traduce cada índice con la
 * tabla de colores de la propia DIB, así que los colores son correctos sin
 * depender de la paleta del sistema.
 *
 * Además, WinGBitBlt/WinGStretchBlt delegan la presentación en
 * TrPresent() (trhook.dll) cuando está cargada, lo que permite escalar la
 * imagen a la ventana.
 *
 * Variables de entorno:
 *   TRAMPOLIN_WING_LOG=<archivo>  registra cada llamada (diagnóstico).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>

typedef enum { WING_DISPERSED_4x4, WING_DISPERSED_8x8, WING_CLUSTERED_4x4 } WING_DITHER_TYPE;

typedef BOOL(WINAPI *PresentFn)(HDC dst, int xd, int yd, int wd, int hd, HDC src, int xs, int ys, int ws, int hs);

static FILE *g_log;
static PresentFn g_present;
static BOOL g_presentResolved;

static void wlog(const char *fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(g_log, "[%lu] ", GetTickCount());
    vfprintf(g_log, fmt, ap);
    fputc('\n', g_log);
    fflush(g_log);
    va_end(ap);
}

static PresentFn present_fn(void) {
    if (!g_presentResolved) {
        HMODULE h = GetModuleHandleA("trhook.dll");
        if (h) g_present = (PresentFn)GetProcAddress(h, "TrPresent");
        g_presentResolved = TRUE;
        wlog("present hook %s", g_present ? "enabled" : "not available");
    }
    return g_present;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        char path[MAX_PATH];
        DWORD n = GetEnvironmentVariableA("TRAMPOLIN_WING_LOG", path, sizeof path);
        if (n > 0 && n < sizeof path) g_log = fopen(path, "a");
        wlog("WING32 (Trampolin) loaded");
    } else if (reason == DLL_PROCESS_DETACH && g_log) {
        wlog("WING32 unloaded");
        fclose(g_log);
        g_log = NULL;
    }
    return TRUE;
}

HDC WINAPI WinGCreateDC(void) {
    HDC dc = CreateCompatibleDC(NULL);
    wlog("WinGCreateDC -> %p", dc);
    return dc;
}

BOOL WINAPI WinGRecommendDIBFormat(BITMAPINFO *fmt) {
    if (!fmt) return FALSE;
    ZeroMemory(&fmt->bmiHeader, sizeof fmt->bmiHeader);
    fmt->bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    fmt->bmiHeader.biWidth = 1;
    fmt->bmiHeader.biHeight = -1; /* top-down: lo más rápido y lo que esperan los motores */
    fmt->bmiHeader.biPlanes = 1;
    fmt->bmiHeader.biBitCount = 8;
    fmt->bmiHeader.biCompression = BI_RGB;
    wlog("WinGRecommendDIBFormat -> 8bpp top-down");
    return TRUE;
}

HBITMAP WINAPI WinGCreateBitmap(HDC dc, BITMAPINFO const *hdr, void **bits) {
    void *p = NULL;
    HBITMAP bmp;
    if (!hdr) return NULL;
    bmp = CreateDIBSection(dc, hdr, DIB_RGB_COLORS, &p, NULL, 0);
    if (bits) *bits = p;
    wlog("WinGCreateBitmap dc=%p %ldx%ld bpp=%u clrUsed=%lu -> %p bits=%p",
         dc, hdr->bmiHeader.biWidth, hdr->bmiHeader.biHeight, hdr->bmiHeader.biBitCount,
         hdr->bmiHeader.biClrUsed, bmp, p);
    return bmp;
}

void *WINAPI WinGGetDIBPointer(HBITMAP bmp, BITMAPINFO *hdr) {
    DIBSECTION ds;
    if (GetObjectA(bmp, sizeof ds, &ds) != sizeof ds) return NULL;
    if (hdr) hdr->bmiHeader = ds.dsBmih;
    return ds.dsBm.bmBits;
}

/*
 * Animación de paleta. Con una paleta de hardware (modo de 256 colores),
 * cambiar los colores recoloreaba al instante lo que ya estaba en pantalla, y
 * los juegos lo usan para fundidos: dibujan con la paleta en negro y después
 * solo cambian la paleta. En color verdadero la imagen ya copiada no cambia,
 * así que tras cada cambio de tabla de colores volvemos a presentar el cuadro
 * completo en la última ventana donde se mostró ese bitmap.
 */
typedef struct { HDC dc; HWND wnd; int offX, offY; } Presented;
static Presented g_presented[8];

static void remember_present(HDC src, HDC dst, int xd, int yd, int xs, int ys) {
    HWND wnd = WindowFromDC(dst);
    int i, free = -1;
    if (!wnd) return;
    for (i = 0; i < 8; i++) {
        if (g_presented[i].dc == src) { free = i; break; }
        if (!g_presented[i].dc && free < 0) free = i;
    }
    if (free < 0) free = 0;
    g_presented[free].dc = src;
    g_presented[free].wnd = wnd;
    g_presented[free].offX = xd - xs;
    g_presented[free].offY = yd - ys;
}

BOOL WINAPI WinGBitBlt(HDC dst, int xd, int yd, int w, int h, HDC src, int xs, int ys);

static void represent(HDC src) {
    int i;
    for (i = 0; i < 8; i++) {
        if (g_presented[i].dc == src && IsWindow(g_presented[i].wnd)) {
            BITMAP bm;
            HBITMAP hbm = (HBITMAP)GetCurrentObject(src, OBJ_BITMAP);
            HDC wdc;
            if (!hbm || GetObjectA(hbm, sizeof bm, &bm) != sizeof bm) return;
            wdc = GetDC(g_presented[i].wnd);
            if (!wdc) return;
            WinGBitBlt(wdc, g_presented[i].offX, g_presented[i].offY, bm.bmWidth, bm.bmHeight, src, 0, 0);
            ReleaseDC(g_presented[i].wnd, wdc);
            return;
        }
    }
}

UINT WINAPI WinGSetDIBColorTable(HDC dc, UINT start, UINT count, RGBQUAD const *colors) {
    UINT r = SetDIBColorTable(dc, start, count, colors);
    wlog("WinGSetDIBColorTable dc=%p start=%u n=%u -> %u", dc, start, count, r);
    if (r) represent(dc);
    return r;
}

UINT WINAPI WinGGetDIBColorTable(HDC dc, UINT start, UINT count, RGBQUAD *colors) {
    return GetDIBColorTable(dc, start, count, colors);
}

HPALETTE WINAPI WinGCreateHalftonePalette(void) {
    HDC screen = GetDC(NULL);
    HPALETTE pal = CreateHalftonePalette(screen);
    ReleaseDC(NULL, screen);
    wlog("WinGCreateHalftonePalette -> %p", pal);
    return pal;
}

HBRUSH WINAPI WinGCreateHalftoneBrush(HDC dc, COLORREF color, WING_DITHER_TYPE type) {
    (void)dc; (void)type;
    /* En color verdadero el tramado no aporta nada: un pincel sólido es equivalente. */
    return CreateSolidBrush(color);
}

BOOL WINAPI WinGStretchBlt(HDC dst, int xd, int yd, int wd, int hd, HDC src, int xs, int ys, int ws, int hs) {
    PresentFn pf = present_fn();
    if (wd == ws && hd == hs) remember_present(src, dst, xd, yd, xs, ys);
    if (pf && pf(dst, xd, yd, wd, hd, src, xs, ys, ws, hs)) return TRUE;
    SetStretchBltMode(dst, COLORONCOLOR);
    return StretchBlt(dst, xd, yd, wd, hd, src, xs, ys, ws, hs, SRCCOPY);
}

BOOL WINAPI WinGBitBlt(HDC dst, int xd, int yd, int w, int h, HDC src, int xs, int ys) {
    PresentFn pf = present_fn();
    remember_present(src, dst, xd, yd, xs, ys);
    if (pf && pf(dst, xd, yd, w, h, src, xs, ys, w, h)) return TRUE;
    return BitBlt(dst, xd, yd, w, h, src, xs, ys, SRCCOPY);
}
