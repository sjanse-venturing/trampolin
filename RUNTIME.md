# RUNTIME — Ejecutar los Trampolín originales en Windows 10/11 x64, sin máquina virtual

> **Objetivo:** que los 8 juegos originales de la serie *Trampolín* (Anaya / Knowledge Adventure, 1995-1998) se instalen y ejecuten en Windows 10/11 de 64 bits **de forma nativa**, mediante un instalador con interfaz gráfica, sin VM, sin emulador de CPU y sin tocar el sistema más allá de lo imprescindible.
>
> **Producto final:** *Trampolín Runtime* =
> `Trampolin.cmd` (doble clic) → asistente gráfico de instalación + lanzador de juegos con UI, manejo de errores amigable, log técnico, y el documento de usuario `LEEME-RUNTIME.md`.

---

## 0. Estado de la implementación (validado el 2026-10-11)

> **Implementado y funcionando en `runtime/`.** Los **8 juegos** corren de forma nativa en Windows 10 x64, escalados a pantalla completa, con colores, sonido y mouse correctos, y salen limpiamente. Se probaron instalados con el asistente gráfico, lanzados desde la biblioteca y desde los accesos directos, en los dos modos de datos ("copiar al disco" y "usar la ISO"). Esta sección manda sobre el plan original de las secciones siguientes cuando difieren.

### 0.1 Qué se construyó

| Pieza | Archivo(s) | Función |
|---|---|---|
| Instalador + biblioteca (UI) | `runtime/Trampolin.cmd`, `runtime/src/Trampolin.ps1`, `runtime/src/UI/*.ps1` | Asistente WinForms de 8 pantallas, biblioteca de juegos, opciones, diálogos de error amigables |
| Núcleo | `runtime/src/Core/Trampolin.Core.psm1`, `Trampolin.Errors.psm1`, `TrIso.cs` | Detección/validación de ISOs (lector ISO9660/Joliet propio, sin montar), instalación, INI, lanzamiento, reparar, desinstalar, copias de partidas, log |
| Catálogo | `runtime/src/data/games.json`, `strings.es.json` | Recetas validadas por juego y catálogo de errores en español |
| `WING32.DLL` propio | `runtime/native/wing32/` | Reemplazo de WinG sobre DIB sections de 8 bpp + re-presentación al cambiar la paleta |
| `trhook.dll` | `runtime/native/trhook/` | Capa de compatibilidad por IAT (ver 0.2) |
| `trlaunch.exe` | `runtime/native/trlaunch/` | Crea el juego suspendido, inyecta `trhook.dll` y espera |
| Pruebas / empaquetado | `runtime/tests/Run-Tests.ps1`, `runtime/build.ps1` | 14 pruebas (incluye integración con las ISOs) y `dist\TrampolinRuntime-<v>.zip` |
| Documento de usuario | `runtime/LEEME-RUNTIME.md` | Instalación, uso, problemas frecuentes |

### 0.2 Causas reales encontradas y su corrección (todas en el Nivel 3)

| # | Síntoma | Causa (confirmada con desensamblado y trazas) | Corrección |
|---|---|---|---|
| 1 | "WinG Installation Error … move it to C:\WINDOWS\SYSTEM32" | El `WING32.DLL` de 1994 verifica su propia ubicación | `WING32.DLL` propio en la carpeta del juego |
| 2 | FG/2G/KG/3G quedan en negro y colgados al iniciar | `WSOUND32.DLL` llama a `waveOutOpen` **dentro de su `DllMain`**: deadlock con el loader lock en la pila de audio moderna | Hook de `waveOutOpen` en la tabla de importación (normal o *delay-load*) de `winmm.dll`. Con el loader lock tomado responde `MMSYSERR_ALLOCATED`, que el motor interpreta como "formato soportado" |
| 3 | Al salir, el juego queda colgado en negro | `WSOUND32` llama a `waveOutReset/waveOutClose` en su `DllMain` de descarga: mismo deadlock | Con el loader lock tomado se omiten (el proceso está terminando). Fuera de él se ejecutan en un hilo auxiliar mientras se bombean mensajes |
| 4 | ACES (Infantil 1° Ciclo, Primeros Pasos) muestra solo partes animadas sobre negro | Fundidos por **animación de paleta** (`WinGSetDIBColorTable`). En color verdadero lo ya dibujado no se recolorea | `WING32` vuelve a presentar el último cuadro completo tras cada cambio de tabla de colores |
| 5 | ACES: "Insufficient hard disk space for temporary storage" (intermitente) | Desborde de 32 bits en `GetDiskFreeSpaceA` (depende del espacio libre) | Hook que limita lo informado a menos de 2 GB |
| 6 | ACES: "Tune file extension must begin with a '.'" | Falta `TuneFileExtension` en `KA.INI` (lo escribía el instalador de 16 bits) | `KA.INI` generado con `TuneFileExtension=.WGM` (General MIDI) y las demás claves |
| 7 | ACES escribe `C:\~~ka.swp` | Archivo de intercambio en la raíz de la unidad | Redirigido a la carpeta del juego |
| 8 | KA-MFC: mensajes vacíos o rutas truncadas | `HDPath` se lee en un buffer de 128 bytes | El instalador valida rutas de ≤ 80 caracteres y en la página de códigos ANSI |
| 9 | Aviso "se ejecutará mejor en 256 colores" | Chequeo de profundidad de color | `[Video] NoWarnings=1` |
| 10 | Pantalla chica (640×480) / cambio de resolución | `ChangeDisplaySettingsA`, 640×480 fijo | Se ignora el cambio de modo y se escala: **modo escenario** (ventana hija de 640×480 en KA-MFC) o **modo lienzo** (área centrada en una ventana a pantalla completa en PEEWEE/ACES). Se traducen blits, mouse, `GetClientRect` e `InvalidateRect` |
| 11 | Chequeo de CD | Etiqueta/tipo de unidad | Modo ISO: montaje real (`Mount-DiskImage`). Modo copia: unidad virtual con `DefineDosDevice` (equivalente a `subst`, sin admin) + `GetDriveTypeA`/`GetVolumeInformationA` simulados |
| 12 | `KA.INI` en `C:\Windows` | API de INI sin ruta | Hook que redirige `KA.INI` a `<instalación>\games\KA.INI` (**no** se usa VirtualStore ni permisos de administrador) |
| 13 | Al arrastrar un objeto (p. ej. la galleta o el hueso del perrito en Educación Infantil) aparecen recortes del fondo agrandados alrededor del mouse | El motor guarda el fondo bajo el objeto **leyendo de la ventana** (`BitBlt` con la ventana como origen) y luego lo restaura. La ventana real tiene la imagen escalada, así que se leía un trozo equivocado y ya agrandado | `trhook` mantiene una **sombra** sin escalar de 640×480 con todo lo que el juego dibuja en la ventana, y sirve desde ella las lecturas con la ventana como origen |
| 14 | ACES (Infantil 1° Ciclo, Primeros Pasos): al escribir el nombre y avanzar, "Couldn't save data to file" (en *Ace Messages*: `If (validate name in roster) = FALSE`) | Para guardar la ficha del alumno (`<ProductHDRoot>\st<N>.dat`, `prschool.dat`), el analizador de rutas de ACES recorre cada carpeta con `FindFirstFileA` y rechaza las que tienen el atributo **oculto** o de sistema. Devuelve "badly formed path name" sin llegar a abrir el archivo. La instalación predeterminada está dentro de `AppData`, que es una carpeta oculta. Confirmado: `C:\X\OCULTO\PRSCHOOL` falla y `C:\X\A\B\C\D\E\F` funciona (no influyen ni el largo ni el formato 8.3) | `trhook` quita los atributos oculto y de sistema en `FindFirstFileA`, `FindNextFileA` y `GetFileAttributesA`. Corrige también las instalaciones existentes sin reinstalar |
| 15 | KA-MFC (Infantil 2° Ciclo), "ordenar las muñecas": el objeto agarrado no sigue al mouse. Se desplaza o se frena antes del borde (≈3/4 de la pantalla al 125 %, ≈1/3 con 1.0.4) | El juego crea su ventana de 640×480 centrada (p. ej. en 363,144) y, al arrastrar, convierte el puntero restando **esa** posición. `trhook` la agranda y la mueve (p. ej. a 171,0), y le devolvía coordenadas de pantalla con el origen real. El error depende de la resolución y del DPI. No era la virtualización de DPI | En modo escenario `trhook` presenta al juego una **posición virtual coherente**: la ventana sigue donde la creó. `GetCursorPos`, `SetCursorPos`, `GetMessagePos`, `MSG.pt`, `ClientToScreen`, `ScreenToClient`, `MapWindowPoints`, `GetWindowRect` y `WindowFromPoint` usan ese origen. Además, todo se presenta desde la sombra de 640×480 con 1 px de margen, para que no queden restos de 1 px con escalas no enteras. El proceso se declara consciente de DPI (`TRAMPOLIN_DPIAWARE=0` lo desactiva). Verificado arrastrando muñecas a 1,6× y 2,25× |
| 16 | 5° Curso (3G), y posiblemente los demás que usan `WSOUND32.DLL`: tras unos minutos se cierra con 0xC0000005 en `WSOUND32.DLL+0x1F306` (un `memset`) | `WSOUND32.DLL` (Watcom) declara sus secciones con tamaño virtual 0. Windows 95 las mapeaba completas hasta la sección siguiente y la DLL usa esa memoria: su `.bss` real (≈0x13000) es mayor que lo que trae el archivo (0x12200). Windows 10 solo mapea los bytes del archivo, y el hueco queda reservado y no se puede habilitar en memoria | Al configurar cada juego antes de abrirlo, `Repair-TrSectionSizes` (en `Trampolin.Core.psm1`) completa en `WSOUND32.DLL` el tamaño de cada sección hasta la siguiente. Es idempotente y no hace falta reinstalar. Verificado llamando al `memset` de la DLL sobre ese borde: la original falla con 0xC0000005 y la reparada no |
| 17 | 6° Curso (4G): sin sonido. Además, el murciélago de ayuda (barra inferior) aparece y se va enseguida | 1) La receta escribía `SoundStrategy=2` (de la numeración de Primera Infancia), que en 4G no abre ningún dispositivo de audio. 2) `[Options] SoundOn` no es encendido/apagado sino una máscara: el valor por omisión (-1) habilita todo, mientras que `1` (lo que escribió la 1.0.7) deja el mezclador enviando silencio (todas las muestras en 128). 3) El murciélago se queda mientras dura su locución, así que con audio silencioso "terminaba" al instante | Receta de 4G en `games.json`: `SoundStrategy=100` (autodetectar, como el instalador original) y `SoundOn=-1`, sin `MusicStrategy`. El lanzador reescribe el INI en cada inicio y corrige las instalaciones existentes. Verificado: con la traza, `waveOutWrite` envía audio real (muestras 65..210) y el murciélago se queda. Con `SoundOn=1` se reproduce el problema |

### 0.3 Cómo usarlo

- **Usuario final:** descomprimir `runtime\dist\TrampolinRuntime-1.0.0.zip` y hacer doble clic en `Trampolin.cmd` (ver `runtime\LEEME-RUNTIME.md`).
- **Desarrollo:** `runtime\native\build.cmd` (requiere Build Tools de VS con C++ x86) y `powershell -File runtime\build.ps1 -IsoFolder <carpeta de ISOs>` (compila, prueba y empaqueta).
- **Fallos del juego:** si el juego se cae (por ejemplo `0xC0000005`, TR-RUN-004), `trhook` registra siempre en `logs\juego-<ID>.log` las líneas `FALLO`: módulo + desplazamiento, dirección accedida, registros y cadena de llamadas aproximada. El lanzador las copia a *Ver detalles / Copiar informe*. `TRAMPOLIN_VIEW=1152x864` fija el tamaño de la vista escalada, para reproducir otras resoluciones.
- **Diagnóstico:** definir `TRAMPOLIN_TRACE=1` registra en `logs\juego-<ID>.log` cada INI, archivo, ventana y llamada de audio. `TRAMPOLIN_WING_LOG=<archivo>` registra las llamadas de WinG.

---

## Índice

1. [Diagnóstico: qué hay en las ISOs y por qué no funcionan](#1-diagnóstico)
2. [Estrategia general](#2-estrategia-general)
3. [Arquitectura del producto *Trampolín Runtime*](#3-arquitectura-del-producto)
4. [Recetas de instalación por juego (Nivel 0)](#4-recetas-de-instalación-por-juego-nivel-0)
5. [Nivel 1 — Capas de compatibilidad de Windows](#5-nivel-1--capas-de-compatibilidad-de-windows)
6. [Nivel 2 — Wrapper DxWnd](#6-nivel-2--wrapper-dxwnd)
7. [Nivel 3 — Runtime propio (WING32.DLL de reemplazo + hooks)](#7-nivel-3--runtime-propio)
8. [El instalador/lanzador con UI](#8-el-instaladorlanzador-con-ui)
9. [Manejo de errores y catálogo de mensajes](#9-manejo-de-errores)
10. [Plan de ejecución paso a paso (fases y tareas)](#10-plan-de-ejecución-paso-a-paso)
11. [Matriz de pruebas](#11-matriz-de-pruebas)
12. [Diagnóstico y resolución de problemas](#12-diagnóstico-y-resolución-de-problemas)
13. [Riesgos y planes de contingencia](#13-riesgos-y-planes-de-contingencia)
14. [Apéndices](#14-apéndices)

---

## 1. Diagnóstico

### 1.1 Identificación de los juegos

Las ISOs son la localización española (Anaya) de la serie **JumpStart** de Knowledge Adventure. El análisis se hizo leyendo las cabeceras PE/NE, las tablas de importación, las cadenas de los ejecutables y los INI de instalación.

| # | ISO (en este directorio) | Juego original | ShortTitle | Ejecutable de juego | Motor | Etiqueta de volumen (ISO9660 / Joliet) |
|---|---|---|---|---|---|---|
| 1 | `Trampolín Educación Infantil - Primeros Pasos.iso` (255 MB) | JumpStart Toddlers (1996) | `TODDLER` | `SUPPORT\W32\TODDLER.EXE` (lanzador) → `SUPPORT\W32\ACES.EXE` | **ACES** (Watcom C 10, 1995) | `Educación Infantil - Primeros Pa` / `Educación Infant` |
| 2 | `Trampolín Educación Infantil - 1° Ciclo.iso` (141 MB) | JumpStart Preschool (1996) | `PRSCHOOL` | `SUPPORT\W32\PRSCHOOL.EXE` (lanzador) → `SUPPORT\W32\ACES.EXE` | **ACES** | `Educación Infantil - 1º Ciclo` / `Educación Infant` |
| 3 | `Trampolín Educación Infantil - 2° Ciclo.iso` (94 MB) | JumpStart Kindergarten (rev. 1997) | `KG` | `SUPPORT\W32\KG.EXE` | **KA-MFC** (MSVC + MFC + "Broadway") | `Educación Infantil - 2º Ciclo` / `Educación Infant` |
| 4 | `Trampolín Educación Infantil - Primera Infancia.iso` (154 MB) | JumpStart Pre-K (1998) | `PRE_K` | `PRE_K.EXE` (raíz y `SUPPORT\CMN`) | **PEEWEE** (Borland C++ 1995) | `NEW` |
| 5 | `Trampolin - 1° Ciclo.iso` (417 MB) | JumpStart 1st Grade | `FG` | `SUPPORT\W32\FG.EXE` | **KA-MFC** | `Trampolín - 8 a 10 años [Windows` / `Trampolín - 8 a` |
| 6 | `Trampolin - 2° Ciclo.iso` (301 MB) | JumpStart 2nd Grade | `2G` | `SUPPORT\W32\2G.EXE` | **KA-MFC** | `SEGUNDO_CICLO` |
| 7 | `Trampolin - 5° Curso.iso` (494 MB) | JumpStart 3rd Grade "Mystery Mountain" (1998) | `3G` | `SUPPORT\W32\3g.exe` | **KA-MFC** (versión 1998) | `NUEVO` |
| 8 | `Trampolin - 6° Curso.iso` (524 MB) | JumpStart 4th Grade (1998) | `4G` | `SUPPORT\CMN\4G.EXE` | **PEEWEE** + Smacker | `6Curso` |

`trampolin_anaya.zip` (2,3 GB) contiene exactamente las mismas 8 ISOs; el runtime lo acepta como origen alternativo (se descomprime a una carpeta temporal), pero no hace falta.

> ⚠️ Las etiquetas de volumen reales que devuelve Windows al montar una ISO dependen de si usa la tabla Joliet (16 caracteres, UTF-16) o la ISO9660 (32 caracteres). **El instalador no hardcodea la etiqueta**: monta la ISO, la lee con `Get-Volume` y la escribe en `KA.INI` (ver §4).

### 1.2 El hallazgo clave: los juegos son de 32 bits

| Componente | Formato | ¿Corre en Win10 x64? |
|---|---|---|
| `FG.EXE`, `2G.EXE`, `3G.EXE`, `KG.EXE` | PE32 i386, GUI, MSVC/MFC | **Sí** (WoW64) |
| `ACES.EXE`, `PRSCHOOL.EXE`, `TODDLER.EXE`, `AUTORUN.EXE` | PE32 i386, Watcom | **Sí** |
| `PRE_K.EXE`, `4G.EXE` | PE32 i386, Borland | **Sí** |
| `WING32.DLL` | PE32, **importa solo GDI32/USER32/KERNEL32** (implementación nativa NT, sin thunks a 16 bits) | **Sí** |
| `WSOUND32.DLL`, `SMACKW32.DLL` | PE32 | **Sí** |
| `SETUP.EXE` / `INSTALAR.EXE` (InstallShield 3) | **NE de 16 bits** | **No**: Windows x64 no tiene NTVDM |
| `SUPPORT\W16\*`, `WING.DLL`, `WINGDE.DLL`, `WINGDIB.DRV`, `DVA.386`, `DIB.DRV` | 16 bits / VxD | No (y no hacen falta) |

**Conclusión:** el modo de compatibilidad "Windows XP" falla porque el problema no está en la API. Lo que pasa es esto:

1. **El instalador es de 16 bits.** Nunca llega a copiar archivos ni a escribir la configuración. Sin instalación, el juego no encuentra sus rutas.
2. **La configuración es estilo Windows 3.x.** Hay un `KA.INI` en `%WINDIR%` (secciones por ShortTitle: `ProductHDRoot`, `ProductCDRoot`, `CDVol`, `SrcDrv`/`CDDrv`) y un INI propio en la carpeta del juego (`.\FG.INI` con `[Paths] HDPath / CDPath / SoundCDPath`; `PRE_K.INI`/`4G.INI` con `[Hardware]`; `3G.INI` con `[Video]`).
3. **Hay chequeo de CD.** `GetDriveTypeA` + `GetVolumeInformationA` comparan contra la etiqueta guardada. Los mensajes en los juegos son "Por favor, inserte el CD-Rom…" y, en ACES, "Can't find file big enough on CD-ROM".
4. **Gráficos de 8 bits con paleta.** Los motores usan `ChangeDisplaySettingsA` (640×480), `SetSystemPaletteUse`, `SetSysColors`, `RealizePalette` y `AnimatePalette`. En Windows 8+ el modo de 256 colores es emulado por DWM: la animación de paleta y la paleta del sistema se comportan distinto y aparecen colores corruptos, fondos negros o parpadeo.
5. **Dependencia de WinG.** Si `WING32.DLL` no está junto al exe ni en `System32`/`SysWOW64`, el juego muestra *"No se encuentra WING32.DLL - anulada ejecución"* (lo dice `MESSAGES.INI`).

Ninguno de estos problemas requiere una VM. Todos se resuelven con **una instalación reconstruida + configuración + una capa de compatibilidad gráfica**.

### 1.3 Detalle técnico por familia de motor

**KA-MFC** (FG, 2G, KG, 3G)
- Recursos en `xx001.RSC` en el CD y `xx002.RSC` instalados en el disco. Formato `BWRF10` = "Broadway Resource File".
- Voces/sonido en `SOUND.BAL` (CD, 50-360 MB) y `SOUND2.BAL` (disco).
- Música en `.MID`/`.MGM` vía `midiOut*`/MCI.
- Lee `MODULE.INI`, `MODULEL.INI`, `SPEECH.INI`, `SPEECH2.INI`, `MESSAGES.INI`, `MCQ.INI` y `DEBUG.INI`. **Estos INI tienen valores cifrados con checksum** ("Archivo INI dañado"), así que **no se editan, solo se copian**.
- Jugadores en `PLYR%04d.INI`, más `volumes.sav` y `ka.atr`.
- Carga dinámica de `WING32.DLL` y `WSOUND32.DLL` (WaveOut + `OpenDriver/SendDriverMessage`).
- 3G además usa `ChangeDisplaySettingsA`/`EnumDisplaySettingsA`, tiene `[Video] FullScreen=1 HideTaskBar=1` y llama a `SHAppBarMessage` para ocultar la barra de tareas.

**ACES** (TODDLER, PRSCHOOL)
- El lanzador (`PRSCHOOL.EXE`/`TODDLER.EXE`, alias KALOAD) interpreta un `.ARG` y termina ejecutando:
  `ACES.EXE <ProductCDRoot>\<ShortTitle>\START.PAC -iniSect <ShortTitle>`
  con `-VOL <CDVol> -DRIVE <SrcDrv|CDDrv>` leídos de `KA.INI`.
- `<ShortTitle>` en el CD es **un único archivo contenedor** (`PRSCHOOL` de 137 MB, `TODDLER` de 246 MB) que ACES abre como si fuera un directorio.
- Usa `CreateThread`, `GetThreadContext`, `ResumeThread` y `VirtualProtect` (temporizador por hilo / parches en memoria).
- Requiere un único proceso KA ("Sólo puede ejecutar una aplicación de Knowledge Adventure a la vez").

**PEEWEE** (PRE_K, 4G)
- Borland C++ 1995. Datos en contenedores `.DF` (cabecera `DF\0\0`); 4G suma 1.797 videos Smacker (`MOVIES\**\*.SMK`, `SMK2`).
- Configuración en `<HDRoot>\<ShortTitle>.INI`, sección `[Hardware]`:
  - `GraphicStrategy` = 1 StretchDIBits, 2 WinG, 3 CreateDIBSection, 4 DispDIB, 5 DirectDraw (100 = autodetectar)
  - `SoundStrategy` = 1 sin sonido, 2 waveOut, 3 WaveMix, 4 DirectSound, 5 AIL
  - `MusicStrategy` = 1 sin música, 2 MCI, 3 midiStream
  - `ResourceDirectory` = raíz del CD
- **Este motor se puede configurar en modos modernos sin parchear nada** (`GraphicStrategy=3`, `SoundStrategy=2`).

---

## 2. Estrategia general

Se aplican **capas escalonadas**: cada juego usa la capa mínima que lo hace funcionar bien. El instalador guarda por juego qué capa usar (catálogo `games.json`, §8.4).

```
Nivel 0  Instalación reconstruida (copiar archivos + KA.INI + INI del juego)   ← SIEMPRE
Nivel 1  Capas de compatibilidad de Windows (AppCompatFlags\Layers)            ← SIEMPRE
Nivel 2  DxWnd (wrapper de terceros, GPL): paleta, ventana, escalado, CD falso ← si Nivel 1 no alcanza
Nivel 3  Runtime propio: WING32.DLL de reemplazo + loader con hooks            ← objetivo final recomendado
```

**Origen de datos (elección del usuario en la UI):**

| Modo | Cómo funciona | Ventajas | Desventajas |
|---|---|---|---|
| **A. "Copiar al disco"** (recomendado) | Se extrae la ISO completa (7-Zip o montaje + copia) a `<Instalación>\cd\<ID>\`. Se usa `subst` a una letra libre **o** el hook de volumen del Nivel 3 para pasar el chequeo de CD. | Rápido, no necesita la ISO después | Ocupa 0,1–0,5 GB por juego |
| **B. "Usar la ISO montada"** | El lanzador monta la ISO con `Mount-DiskImage` antes de jugar y la desmonta al salir. | Fidelidad total: unidad tipo CD-ROM con la etiqueta real, sin hooks | Hay que conservar las ISOs y lleva unos segundos de montaje |

El modo B pasa el chequeo de CD sin trucos, porque Windows expone la ISO montada como `DRIVE_CDROM` con su etiqueta. Por eso es el **modo de referencia para las pruebas** y el que asegura que funcione desde el primer día. El modo A queda como opción en cuanto el hook de volumen (Nivel 3) o `subst` + la etiqueta esté validado para cada juego.

---

## 3. Arquitectura del producto

### 3.1 Estructura del repositorio (código fuente del runtime)

```
Trampolin/                         ← este proyecto
├─ RUNTIME.md                      ← este documento
├─ runtime/
│  ├─ Trampolin.cmd                ← punto de entrada (doble clic)
│  ├─ LEEME-RUNTIME.md             ← documento para el usuario final
│  ├─ src/
│  │  ├─ Trampolin.ps1             ← arranque: carga módulos, decide asistente vs. lanzador
│  │  ├─ Core/
│  │  │  ├─ Trampolin.Core.psm1    ← lógica (sin UI): detección, instalación, INI, compat, lanzamiento
│  │  │  ├─ Trampolin.Errors.psm1  ← catálogo de errores + Invoke-Step + logging
│  │  │  └─ Trampolin.Iso.psm1     ← montaje/extracción/validación de ISOs
│  │  ├─ UI/
│  │  │  ├─ Wizard.ps1             ← asistente de instalación (WinForms)
│  │  │  ├─ Launcher.ps1           ← lanzador/biblioteca (WinForms)
│  │  │  ├─ Dialogs.ps1            ← diálogo de error amigable, confirmaciones
│  │  │  └─ Theme.ps1              ← fuentes, colores, íconos
│  │  └─ data/
│  │     ├─ games.json             ← catálogo declarativo de los 8 juegos (§8.4)
│  │     ├─ strings.es.json        ← todos los textos de UI y errores
│  │     └─ dxwnd/*.dxw            ← perfiles DxWnd por juego (Nivel 2)
│  ├─ native/                      ← Nivel 3 (C, x86)
│  │  ├─ wing32/                   ← WING32.DLL de reemplazo
│  │  ├─ trhook/                   ← trhook.dll (Detours): hooks GDI/USER/KERNEL
│  │  ├─ trlaunch/                 ← trlaunch.exe: CreateProcess(SUSPENDED)+inyección
│  │  └─ CMakeLists.txt
│  ├─ tools/                       ← 7-Zip portable (7za.exe), DxWnd (si se redistribuye), ps2exe
│  ├─ tests/                       ← Pester: tests de Core sin UI
│  └─ build.ps1                    ← empaqueta dist\TrampolinRuntime-x.y.z.zip (+ .exe opcional)
```

### 3.2 Estructura instalada en la máquina del usuario

Por defecto `%LOCALAPPDATA%\Trampolin` (no requiere permisos de administrador). Configurable en el asistente.

```
%LOCALAPPDATA%\Trampolin\
├─ Trampolin.cmd / Trampolin.exe   ← lanzador
├─ app\                            ← copia de runtime\src y runtime\native\bin
├─ games\<ID>\                     ← "HDRoot" de cada juego (exe, DLLs, INIs, *002.RSC, partidas)
├─ cd\<ID>\                        ← solo en modo A: contenido completo del CD
├─ manifest.json                   ← qué se instaló, de dónde, con qué opciones (permite reparar/desinstalar)
├─ settings.json                   ← preferencias del usuario
├─ logs\trampolin-YYYYMMDD.log     ← log técnico
└─ LEEME-RUNTIME.md
```

Accesos directos en el Escritorio y en el Menú Inicio (`Programas\Trampolín\<Nombre del juego>.lnk`). Todos apuntan a `Trampolin.exe --play <ID>`, nunca al exe original, para que el lanzador aplique montaje, capas y hooks.

### 3.3 `KA.INI` sin permisos de administrador

Los juegos leen `KA.INI` con `GetPrivateProfileStringA("…", "…", …, "KA.INI")`, sin ruta, así que el archivo se busca en `%WINDIR%`. Hay dos estrategias, y el instalador usa la **1** por defecto:

1. **UAC File Virtualization (sin admin):** los exes de 1995-98 son de 32 bits y **no tienen manifiesto** `requestedExecutionLevel`, así que Windows les aplica virtualización de archivos. Sus lecturas de `C:\Windows\KA.INI` se resuelven primero contra `%LOCALAPPDATA%\VirtualStore\Windows\KA.INI`. El instalador escribe ahí, sin elevar permisos.
   - *Validación obligatoria (Fase R1):* confirmar con Process Monitor que el proceso tiene `Virtualized = True` y que lee el archivo del VirtualStore.
2. **Escritura real en `C:\Windows\KA.INI` (con admin):** fallback si la virtualización está deshabilitada por política (`EnableVirtualization=0`). El asistente pide elevar permisos una sola vez, con un mensaje explicativo.
3. **Nivel 3:** el hook de `GetPrivateProfileStringA`/`WritePrivateProfileStringA` redirige `KA.INI` a `<Instalación>\games\KA.INI`. Es la solución definitiva y no depende de nada del sistema.

---

## 4. Recetas de instalación por juego (Nivel 0)

Notación:
- `CD` = raíz de la ISO montada (por ejemplo `E:\`) o `<Instalación>\cd\<ID>` en modo A.
- `HD` = `<Instalación>\games\<ID>`.

En todas las recetas, **no copiar** nada de `SUPPORT\W16`, `WINGDE.DLL`, `WING.DLL`, `WINGDIB.DRV`, `DVA.386`, `DIB.DRV`, `UTILDISK`, `EREG`, `WIN32S` ni los instaladores. El chequeo final de cada receta es que **el juego llegue al menú principal con colores correctos y voz**.

### 4.1 Familia KA-MFC: FG (1° Ciclo), 2G (2° Ciclo), KG (Infantil 2° Ciclo), 3G (5° Curso)

| Paso | Acción | Detalle |
|---|---|---|
| 1 | Crear `HD` | `New-Item -ItemType Directory HD` |
| 2 | Copiar el exe y las DLLs de 32 bits | `CD\SUPPORT\W32\*` → `HD\` (ej. `FG.EXE`, `WSOUND32.DLL`; en 3G también `SMACKW32.DLL`) |
| 3 | Copiar los archivos comunes | `CD\SUPPORT\CMN\*` → `HD\` (INIs cifrados, `*002.RSC`, `SOUND2.BAL`, `.MGM`, `.MID`, `.HLP`, etc.) |
| 4 | Copiar WinG de 32 bits | `CD\SUPPORT\WINSYS\WING32.DLL` → `HD\` (o el `WING32.DLL` propio del Nivel 3) |
| 5 | Normalizar nombres | El exe tiene que llamarse `<ShortTitle>.EXE` (3G viene como `3g.exe`, no importa: NTFS no distingue mayúsculas) |
| 6 | Quitar "solo lectura" | `attrib -R HD\* /S` (los archivos que vienen de un CD conservan el atributo y los juegos escriben `PLYR*.INI` y `volumes.sav`) |
| 7 | Escribir `HD\<ShortTitle>.INI` | Ver plantilla abajo |
| 8 | Escribir la sección en `KA.INI` | Ver plantilla abajo |
| 9 | (3G) sección `[Video]` | `FullScreen=0` en modo ventana / `1` en pantalla completa, y `HideTaskBar=0` |

**Plantilla `HD\FG.INI`** (las claves salen de las cadenas del exe: `Paths`, `HDPath`, `CDPath`, `SoundCDPath`, `AllowVolumeChanges`):

```ini
[Paths]
HDPath=C:\Users\<user>\AppData\Local\Trampolin\games\FG\
CDPath=E:\FG\32BIT\
SoundCDPath=E:\FG\
[Options]
AllowVolumeChanges=1
```

> 🔎 **A validar en Fase R1:** la semántica exacta de `CDPath` y `SoundCDPath` (si apuntan a la raíz del CD o a `FG\32BIT\`, y si terminan en `\`). El método para confirmarlo es sistemático:
> 1. Hacer la instalación con la ISO montada.
> 2. Correr Process Monitor con filtro `Process Name is FG.EXE` + `Result is NAME NOT FOUND or PATH NOT FOUND`.
> 3. Ajustar hasta que no queden accesos fallidos a `*.RSC`/`*.BAL`.
> 4. Guardar el resultado en `games.json`.
>
> También se puede comparar con un `FG.INI` generado por el instalador original en un Windows 98 (en una VM, una sola vez): es la forma más rápida de obtener la verdad de referencia. Lo mismo para `KA.INI`.

Distribución de datos en cada CD (para las plantillas):

| ID | Subcarpeta de recursos en CD | Archivo de sonido en CD |
|---|---|---|
| FG | `FG\32BIT\` | `FG\SOUND.BAL` |
| 2G | `2G\32BIT\` | `2G\SOUND.BAL` |
| KG | `KG\32BIT\` | `KG\SOUND.BAL` |
| 3G | `3G\` | `3G\Sound.bal` |

**Plantilla de sección en `KA.INI`** (los nombres de clave salen de los `.ARG`: `ProductHDRoot`, `ProductCDRoot`, `CDVol`, `SrcDrv`/`CDDrv`):

```ini
[FG]
ProductHDRoot=C:\Users\<user>\AppData\Local\Trampolin\games\FG
ProductCDRoot=E:
CDVol=<etiqueta leída con Get-Volume>
SrcDrv=E
CDDrv=E
Lang=ESP
```

### 4.2 Familia ACES: TODDLER (Primeros Pasos), PRSCHOOL (Infantil 1° Ciclo)

| Paso | Acción |
|---|---|
| 1 | Crear `HD` |
| 2 | `CD\SUPPORT\W32\*` → `HD\` (`ACES.EXE`, `KALOAD.EXE` si está, `PRSCHOOL.EXE`/`TODDLER.EXE`). **No** copiar la subcarpeta `BKUP\` de Primeros Pasos (es una versión anterior) |
| 3 | `CD\SUPPORT\CMN\*` → `HD\` (`*.ARG`, `STR.INI`) |
| 4 | `CD\<ShortTitle>.INI` (si existe, ej. `PRSCHOOL.INI`) → `HD\` y cambiar `lang=JPN` → `lang=ESP` **solo si las pruebas lo requieren** (viene así en el CD español: a validar) |
| 5 | `CD\SUPPORT\WINSYS\WING32.DLL` → `HD\` |
| 6 | `PLSWAIT.BMP` del CD (si existe) → `HD\` |
| 7 | `attrib -R` |
| 8 | Escribir la sección `[PRSCHOOL]`/`[TODDLER]` en `KA.INI` con `ProductHDRoot`, `ProductCDRoot`, `CDVol`, `SrcDrv` (PRSCHOOL) / `CDDrv` (TODDLER) |

**Lanzamiento:** se saltea el lanzador KALOAD (su único trabajo es armar la línea de comandos y chequear memoria con heurísticas de Win3.x) y se ejecuta directamente:

```
HD\ACES.EXE E:\PRSCHOOL\START.PAC -iniSect PRSCHOOL
HD\ACES.EXE E:\TODDLER\START.PAC  -iniSect TODDLER
```

con directorio de trabajo `HD`. Si ACES rechaza el arranque directo (por ejemplo, porque espera un evento o ventana del lanzador), se lanza `PRSCHOOL.EXE` y se registra en el log. Las dos variantes son configurables en `games.json` (`launchMode: "direct" | "loader"`).

> En modo A (datos copiados al disco), `E:\PRSCHOOL` se reemplaza por `<cd>\PRSCHOOL`, que **es un archivo**, no una carpeta. ACES resuelve `<archivo>\START.PAC` como ruta dentro del contenedor. A validar que eso funcione fuera de una unidad CD. Si no funciona, el modo A para ACES usa `subst T: <cd>` + hook de `GetDriveTypeA` (Nivel 3) o directamente el modo B.

### 4.3 Familia PEEWEE: PRE_K (Primera Infancia), 4G (6° Curso)

| Paso | PRE_K | 4G |
|---|---|---|
| 1 | Crear `HD` | Crear `HD` |
| 2 | `CD\SUPPORT\CMN\*` → `HD\` (`PRE_K.EXE`, `DATA.DF`, `WSOUND32.DLL`) | `CD\SUPPORT\CMN\*` → `HD\` (`4G.EXE`, `SMACKW32.DLL`, `4G.INI`) |
| 3 | `WING32.DLL` → `HD\` | `WING32.DLL` → `HD\` |
| 4 | `attrib -R` | `attrib -R` |
| 5 | `HD\PRE_K.INI` (plantilla abajo) | `HD\4G.INI` (plantilla abajo) |
| 6 | Sección `[PRE_K]` en `KA.INI` | Sección `[4G]` en `KA.INI` (+ `ChkFile=4grev11`, ver `SETUP.INI`) |

```ini
[Hardware]
; 3 = CreateDIBSection (no depende de WinG ni de la paleta del sistema)
GraphicStrategy=3
; 2 = waveOut
SoundStrategy=2
; 2 = MCI (MIDI)
MusicStrategy=2
ResourceDirectory=E:\
```

Si `GraphicStrategy=3` da problemas de paleta, se prueba en este orden 2 (WinG con nuestro `WING32.DLL`), luego 1, y por último 5 (DirectDraw, con un wrapper `ddraw.dll` tipo cnc-ddraw). Las combinaciones validadas se guardan en `games.json`.

### 4.4 Archivos de ayuda (.HLP)

Windows 10 no trae `WinHlp32.exe`. Opciones, de menor a mayor esfuerzo:
- (a) No ofrecer la ayuda (es material para padres).
- (b) Convertir los `.HLP` a HTML con `helpdeco` en tiempo de instalación y abrir el HTML desde el lanzador ("Guía para padres").
- (c) Indicar cómo instalar WinHlp32 de forma no oficial.

**Recomendado: (b)**, como tarea opcional de la Fase R5.

---

## 5. Nivel 1 — Capas de compatibilidad de Windows

Se aplican por ejecutable en el registro del usuario (sin admin):

```
HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers
  "<HD>\FG.EXE" = "~ WIN98 256COLOR 640X480 DWM8And16BitMitigation HIGHDPIAWARE"
```

| Capa | Para qué |
|---|---|
| `WIN98` (o `WIN95`) | `GetVersion` devuelve 4.10. Algunos motores eligen caminos de código según la versión (por ejemplo, el modo NT de WinG) |
| `256COLOR` | Fuerza el modo de 8 bits emulado (paleta) |
| `640X480` | Fuerza la resolución 640×480 |
| `DWM8And16BitMitigation` | Mitigación de DWM para apps de 8/16 bits (mejora la paleta en muchos casos) |
| `HIGHDPIAWARE` | Evita el escalado borroso por DPI y coordenadas de mouse desplazadas |
| (opcional) `DISABLEDXMAXIMIZEDWINDOWEDMODE` | Solo para la estrategia DirectDraw de PEEWEE |

**Matriz inicial a probar** (la definitiva queda en `games.json`):

| ID | Capas iniciales |
|---|---|
| FG, 2G, KG, 3G | `~ WIN98 256COLOR 640X480 DWM8And16BitMitigation HIGHDPIAWARE` |
| TODDLER, PRSCHOOL | `~ WIN95 256COLOR 640X480 DWM8And16BitMitigation HIGHDPIAWARE` |
| PRE_K, 4G | `~ WIN98 HIGHDPIAWARE` (con `GraphicStrategy=3` no deberían necesitar 256COLOR; si los colores fallan, agregar `256COLOR DWM8And16BitMitigation`) |

**Shim personalizado (opcional, solo si hace falta):** con *Compatibility Administrator (32-bit)* del Windows ADK se crea `Trampolin.sdb` con `CorrectFilePaths` (para redirigir `C:\Windows\KA.INI`) y `ForceDisplayMode`, y se instala con `sdbinst -q Trampolin.sdb` (requiere admin). Se prefiere el Nivel 3 porque no necesita admin ni el ADK.

**DEP:** en Windows 10 cliente la política es `OptIn`: los exes sin la marca `NX_COMPAT` (todos estos) **no** tienen DEP activo, así que `VirtualProtect`/código autogenerado de ACES no debería fallar. Solo si un juego se cierra con `0xC0000005` en una dirección de datos se verifica con `bcdedit /enum {current}` (campo `nx`) y se agrega la excepción en *Prevención de ejecución de datos*.

**Afinidad de CPU:** si ACES muestra animaciones aceleradas, cuelgues aleatorios o audio cortado, el lanzador lo arranca con afinidad a una sola CPU (`$p.ProcessorAffinity = 1`) y prioridad `AboveNormal`.

---

## 6. Nivel 2 — Wrapper DxWnd

[DxWnd](https://sourceforge.net/projects/dxwnd/) (GPL) intercepta GDI/DirectDraw en procesos de 32 bits y ofrece, entre otras cosas:

- Ventana escalada 4:3 y pantalla completa falsa.
- **Emulación de paleta GDI**: el juego cree que está en 8 bits y DxWnd convierte a 32 bits.
- Bloqueo de `ChangeDisplaySettings` y de `SetSysColors`.
- **CD-ROM falso** (tipo de unidad y etiqueta de volumen), útil para el modo A.
- Limitador de FPS y ajuste de temporizadores.

**Integración:**
1. Incluir DxWnd en `runtime\tools\dxwnd\` (es GPL, se puede redistribuir con licencia y código fuente referenciado) **o** descargarlo en la instalación desde SourceForge, con hash verificado.
2. Un perfil `.dxw` por juego en `runtime\src\data\dxwnd\<ID>.dxw`, generado en la Fase R2 con la GUI de DxWnd y exportado.
3. El lanzador ejecuta `dxwnd.exe /r:<n>` (lanzar la entrada n del perfil) o `/c:<archivo.dxw>`, según la versión. El comando exacto se valida en la Fase R2 y queda en `games.json`.

**Opciones de partida para los perfiles** (se ajustan probando):
- Video: *Windowed*, *Keep aspect ratio*, *Initial window size 1280×960*, *Emulate palette (GDI)*, *Lock color depth*, *Fix ChangeDisplaySettings*.
- Input: *Correct mouse position*, *Clip cursor* (opcional).
- Sistema: *Fake CD drive / volume label* (modo A), *Hide taskbar* = off.

Desventaja: dependencia de un tercero, configuración opaca y posibles falsos positivos de antivirus por la inyección. Por eso el Nivel 3 es el objetivo final.

---

## 7. Nivel 3 — Runtime propio

Objetivo: **no depender de DxWnd ni de la emulación de 256 colores de Windows**. Las tres familias de motor dibujan en un buffer de 8 bits y lo presentan por WinG (o por DIB/GDI): hay **un punto de interceptación pequeño y bien definido**.

### 7.1 Componentes

| Componente | Lenguaje | Rol |
|---|---|---|
| `WING32.DLL` (propio) | C (C11), x86, sin CRT o CRT estática | Reemplazo drop-in con las **10 exportaciones** de WinG. Mantiene los bitmaps de 8 bits del juego en memoria propia y **presenta en color de 32 bits** escalado |
| `trhook.dll` | C + Microsoft Detours (MIT), x86 | Hooks de USER32/GDI32/KERNEL32 para neutralizar efectos globales y redirigir rutas/volúmenes |
| `trlaunch.exe` | C, x86 | Crea el proceso del juego suspendido, inyecta `trhook.dll` (`DetourCreateProcessWithDllEx`), pasa la configuración por memoria compartida y lo reanuda |

Compilación: Visual Studio 2022 Build Tools (toolset v143, `-A Win32`) o MinGW-w64 i686, con CMake. Detours se obtiene vía vcpkg (`detours:x86-windows-static`).

### 7.2 `WING32.DLL` de reemplazo

API de WinG (las mismas firmas que la DLL original, exportadas por nombre):

| Export | Implementación propuesta |
|---|---|
| `WinGCreateDC()` | `CreateCompatibleDC(NULL)` + registro en la tabla interna |
| `WinGRecommendDIBFormat(BITMAPINFO*)` | Devuelve 8 bpp, **top-down** (`biHeight = -1`), `BI_RGB`, `TRUE` |
| `WinGCreateBitmap(hdc, BITMAPINFO*, void** ppBits)` | `CreateDIBSection` de **8 bpp** con la tabla de color del juego. Se guarda `{hbm, bits, w, h, pitch, colortable[256]}` y se devuelve el puntero de bits |
| `WinGGetDIBPointer(hbm, BITMAPINFO*)` | Busca en la tabla interna y devuelve los bits |
| `WinGSetDIBColorTable(hdc, start, n, RGBQUAD*)` | Actualiza la tabla interna y `SetDIBColorTable` del DIB. **Ésta es la paleta "verdadera" del juego** |
| `WinGGetDIBColorTable(...)` | Devuelve la tabla interna |
| `WinGBitBlt(dst, x, y, w, h, src, sx, sy)` | **Presentación:** si `dst` es el DC de una ventana, convierte el rectángulo 8→32 bpp con la tabla actual en un backbuffer de 32 bpp y hace `StretchBlt`/`StretchDIBits` a la ventana con el escalado y la relación de aspecto configurados. Si `dst` es un DC de memoria, hace `BitBlt` normal |
| `WinGStretchBlt(...)` | Igual, con escalado |
| `WinGCreateHalftonePalette()` | Paleta halftone de 256 colores estándar (como la original) |
| `WinGCreateHalftoneBrush(hdc, color, type)` | Brocha de patrón 8×8 (como la original) |

Pseudocódigo del camino crítico:

```c
BOOL WINAPI WinGBitBlt(HDC dst, int x, int y, int w, int h, HDC src, int sx, int sy) {
    WingBmp *b = wing_lookup_dc(src);
    if (!b || !is_window_dc(dst))
        return BitBlt(dst, x, y, w, h, src, sx, sy, SRCCOPY);
    // 1) 8bpp → 32bpp con la paleta del juego (o la que trhook capturó con AnimatePalette)
    const uint32_t *pal = tr_effective_palette(b);           // 256 entradas XRGB
    convert8to32(b->bits, b->pitch, sx, sy, w, h, g_back.bits, g_back.pitch, x, y, pal);
    // 2) presentación escalada del rectángulo sucio
    RECT r = map_to_client(x, y, w, h);                      // aspecto 4:3, letterbox, escala entera opcional
    return StretchDIBits(dst, r.left, r.top, r.right - r.left, r.bottom - r.top,
                         x, y, w, h, g_back.bits, &g_back.bmi, DIB_RGB_COLORS, SRCCOPY) != 0;
}
```

- La conversión 8→32 de 640×480 es de unos 300 K píxeles: menos de 1 ms con una LUT. No hace falta GPU.
- Escalado: entero (2×, 3×) con *nearest*, o ajuste a ventana con `HALFTONE`. Opción en la UI.
- `AnimatePalette`/`SetPaletteEntries` (los usan para fundidos) los intercepta `trhook` y actualizan `tr_effective_palette`, que fuerza un redibujado completo del backbuffer.

### 7.3 Hooks en `trhook.dll`

| Función | Comportamiento |
|---|---|
| `ChangeDisplaySettingsA` | Devuelve `DISP_CHANGE_SUCCESSFUL` sin cambiar el modo y redimensiona la ventana del juego al tamaño configurado |
| `EnumDisplaySettingsA` | Reporta un modo 640×480×8 disponible |
| `GetDeviceCaps(BITSPIXEL/PLANES/NUMCOLORS/SIZEPALETTE/RASTERCAPS)` | Simula una pantalla de 8 bpp con `RC_PALETTE` (para que el motor elija la ruta de paleta/WinG) |
| `SetSystemPaletteUse`, `SetSysColors` | No-op y devuelve éxito (evita que se rompan los colores del escritorio) |
| `CreatePalette`, `SelectPalette`, `RealizePalette`, `AnimatePalette`, `SetPaletteEntries`, `GetSystemPaletteEntries` | Mantienen una "paleta lógica del sistema" virtual y la sincronizan con `WING32.DLL` |
| `SetDIBitsToDevice`, `StretchDIBits` con DIBs de 8 bpp `DIB_PAL_COLORS` | Traducción a RGB con la paleta virtual (ruta no-WinG) |
| `SHAppBarMessage(ABM_SETSTATE)` | No-op: no oculta la barra de tareas |
| `GetDriveTypeA(X:)` | Devuelve `DRIVE_CDROM` para la letra/carpeta virtual del CD (modo A) |
| `GetVolumeInformationA` | Devuelve la etiqueta esperada (`CDVol`) para la unidad virtual |
| `GetPrivateProfileStringA/IntA`, `WritePrivateProfileStringA` con `lpFileName` = `KA.INI` sin ruta | Redirigen a `<Instalación>\games\KA.INI` |
| `CreateFileA`/`FindFirstFileA` con prefijo `X:\` virtual | (Solo si `subst` no alcanza.) Reescriben la ruta a `<Instalación>\cd\<ID>\` |
| `CreateWindowExA` (ventana principal) | Fuerza `WS_OVERLAPPEDWINDOW` en modo ventana y centra la ventana |
| `ClipCursor`, `SetCursorPos` | Traducen coordenadas lógicas 640×480 ↔ ventana escalada |
| `GetCursorPos`, `ScreenToClient`, mensajes `WM_MOUSE*` | **Escalado inverso de coordenadas** del mouse (crítico cuando la ventana no es 640×480) |
| `timeGetTime`, `GetTickCount` | (Opcional) suavizado si se detectan problemas de velocidad |

**Escalado de entrada:** cuando la ventana se escala, el juego tiene que seguir viendo un área cliente de 640×480. La forma más simple y robusta es crear la ventana del juego a 640×480 real (oculta o detrás) y **presentar en una ventana host escalada propia del runtime** que reenvía la entrada con las coordenadas transformadas. Es lo que hacen DxWnd/dgVoodoo en modo ventana. Se elige en la Fase R3 tras un prototipo:

- (i) Escalar la ventana del juego y transformar mensajes.
- (ii) Ventana host + reenvío.

**Recomendado: (ii)**, porque aísla por completo al juego del DPI y de la resolución real.

### 7.4 `trlaunch.exe`

```
trlaunch.exe --game FG --exe "<HD>\FG.EXE" --cwd "<HD>" --args "" ^
             --config "<Instalación>\app\runtime-FG.json" --log "<Instalación>\logs"
```

1. Lee la configuración del juego (escala, ventana/pantalla completa, rutas virtuales, etiqueta).
2. `DetourCreateProcessWithDllExA(..., CREATE_SUSPENDED, "trhook.dll")`.
3. Escribe la configuración en un *file mapping* con nombre `Local\Trampolin-<pid>`.
4. `ResumeThread` y espera al proceso. Devuelve su código de salida, que el lanzador usa para diagnosticar (§9).
5. Mutex único: si ya hay un juego KA corriendo, avisa de forma amigable (los juegos solo admiten una instancia).

---

## 8. El instalador/lanzador con UI

### 8.1 Tecnología

- **PowerShell 5.1 + WinForms (.NET Framework 4.8)**: vienen con Windows 10, así que hay **cero dependencias para el usuario**.
- `Trampolin.cmd`:
  ```bat
  @echo off
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app\Trampolin.ps1" %*
  ```
- Opcional: compilar `Trampolin.ps1` a `Trampolin.exe` con **ps2exe** (`-noConsole -STA -iconFile trampolin.ico`) para tener un .exe con ícono propio.
- 7-Zip: se usa `7za.exe` portable incluido en `tools\`. Si no está, la ISO se extrae montándola con `Mount-DiskImage` y copiando con `robocopy`.
- Elevación de permisos: **nunca por defecto**. Solo si el usuario elige "Instalar para todos los usuarios" o si falla la virtualización de `KA.INI`.

### 8.2 Asistente de instalación (primera ejecución, o "Agregar juegos")

Ventana de 720×520, no redimensionable, botones **Atrás / Siguiente / Cancelar**, tipografía Segoe UI 10 pt y un encabezado con el logo.

| # | Pantalla | Controles / inputs | Validaciones y comportamiento |
|---|---|---|---|
| 1 | **Bienvenida** | Texto de presentación y lista de chequeos con íconos ✔/⚠/✖ | Chequeos: Windows 10/11 64 bits; .NET 4.8; PowerShell ≥ 5.1; espacio libre en la unidad de destino; `Mount-DiskImage` disponible; 7-Zip (incluido); virtualización UAC activa. Un ✖ bloquea "Siguiente" y muestra la explicación |
| 2 | **¿Dónde están los juegos?** | TextBox + botón "Examinar…" (FolderBrowserDialog) con la carpeta que contiene las ISOs o el ZIP. Botón "Buscar automáticamente" (Escritorio, Descargas, Documentos, la carpeta actual) | Para cada ISO encontrada: tamaño exacto (tabla §14.1), lectura del PVD (`CD001`) y presencia del archivo clave (ej. `SUPPORT\W32\FG.EXE`). El SHA-256 se calcula en segundo plano y se muestra como "verificado" o "desconocido: puede ser otra edición" (no bloquea). Si encuentra un ZIP: "Se encontró trampolin_anaya.zip. ¿Extraer las ISOs? (necesita 2,4 GB temporales)" |
| 3 | **Elegí los juegos** | `ListView` con checkboxes: ícono, nombre amigable ("Educación Infantil – Primeros Pasos (2-3 años)"), edad, tamaño en disco, estado (Disponible / Ya instalado / ISO no encontrada) | Al menos uno seleccionado. "Seleccionar todos" / "Ninguno". Los juegos sin ISO aparecen deshabilitados, con un tooltip que explica por qué |
| 4 | **Dónde instalar** | TextBox + "Examinar…" (por defecto `%LOCALAPPDATA%\Trampolin`). Opción de datos: ◉ "Copiar los juegos al disco (recomendado, no necesita la ISO después)" / ○ "Usar las ISOs desde su ubicación actual (ocupa menos espacio)". ☐ "Instalar para todos los usuarios (requiere administrador)" | La ruta tiene que ser escribible (se prueba creando un archivo temporal), no estar dentro de `Program Files` sin admin y no ser una unidad de red. Espacio requerido vs. libre en tiempo real ("Necesario: 2,1 GB — Libre: 120 GB"). Rutas con caracteres no ANSI (ej. `Á`, `ñ`): los juegos usan APIs `A` (ANSI), así que si la ruta no se puede representar en la página de códigos 1252 se muestra un aviso y se ofrece `C:\Trampolin` |
| 5 | **Pantalla y sonido** | ◉ Ventana / ○ Pantalla completa. Tamaño de ventana: combo (2× 1280×960 recomendado, 3×, ajustar al monitor). Filtro: ◉ Píxeles nítidos / ○ Suavizado. Volumen de música (slider). ☐ "Crear accesos directos en el escritorio" (marcado). ☐ "Agregar al menú Inicio" (marcado) | Estas opciones se guardan en `settings.json` y se pueden cambiar desde el lanzador |
| 6 | **Resumen** | Lista de lo que se va a hacer, espacio total y botón **Instalar** | — |
| 7 | **Instalando** | Barra de progreso global + barra por paso. Etiqueta "Copiando Educación Primaria 1° Ciclo… (3/8)". Detalle desplegable con las últimas líneas del log. Botón **Cancelar** | El trabajo corre en un `Runspace` aparte para no congelar la UI. Al cancelar se pide confirmación y se hace **rollback** del juego en curso: se borra `games\<ID>` parcial y se revierten las entradas de registro y de `KA.INI` |
| 8 | **Listo** | ✔/⚠ por juego. Botones "Jugar ahora" (abre el lanzador) y "Ver detalles" | Si algún juego falló, se muestra el mensaje amigable correspondiente (§9) y el resto queda instalado |

### 8.3 Lanzador ("Biblioteca Trampolín")

- **Vista principal:** grilla de tarjetas (FlowLayoutPanel) con el ícono extraído del exe (`[System.Drawing.Icon]::ExtractAssociatedIcon`), el nombre y la edad, y el botón grande **▶ Jugar**.
- **Menú contextual por juego:** Opciones (ventana/pantalla completa, escala, capa gráfica Nivel 1/2/3, modo de datos), **Reparar** (revalida archivos contra el manifest y reescribe INIs y registro), **Abrir carpeta de partidas**, **Hacer copia de seguridad de partidas** (zip de `PLYR*.INI`, `volumes.sav`, `ka.atr`), **Desinstalar**.
- **Barra inferior:** "Agregar juegos…" (vuelve al asistente), "Ayuda" (abre `LEEME-RUNTIME.md` renderizado en un `WebBrowser` o en el navegador), "Abrir log", "Acerca de".
- **Al presionar Jugar:**
  1. Chequeo rápido (existe el exe, existe la ISO si el modo es B).
  2. Montaje de la ISO si corresponde, con barra "Preparando el disco…".
  3. Actualización de `KA.INI` y `<ID>.INI` si cambió la letra de unidad.
  4. Lanzamiento según la capa: L1 directo / L2 DxWnd / L3 `trlaunch`.
  5. El lanzador se minimiza.
  6. Al terminar el juego, desmonta la ISO, restaura la ventana y analiza el código de salida y el tiempo de ejecución (si duró menos de 5 s → "parece que el juego no pudo arrancar", §9).
- **Línea de comandos:** `Trampolin.exe --play FG` (usado por los accesos directos), `--install`, `--repair FG`, `--uninstall FG`, `--silent` (instalación desatendida con `settings.json`).

### 8.4 Catálogo declarativo `games.json`

Toda la lógica específica de cada juego vive en datos, no en código:

```json
{
  "id": "FG",
  "name": "Educación Primaria – 1° Ciclo",
  "age": "6-7 años",
  "engine": "ka-mfc",
  "iso": { "names": ["Trampolin - 1° Ciclo.iso"], "size": 416952320,
           "sha256": "<se completa en Fase R1>", "keyFile": "SUPPORT/W32/FG.EXE" },
  "copy": [
    { "from": "SUPPORT/W32/*",           "to": "." },
    { "from": "SUPPORT/CMN/*",           "to": "." },
    { "from": "SUPPORT/WINSYS/WING32.DLL", "to": "." }
  ],
  "exe": "FG.EXE",
  "launch": { "mode": "direct", "args": "" },
  "ini": {
    "FG.INI": { "Paths": { "HDPath": "{HD}\\", "CDPath": "{CD}\\FG\\32BIT\\", "SoundCDPath": "{CD}\\FG\\" } },
    "KA.INI": { "FG": { "ProductHDRoot": "{HD}", "ProductCDRoot": "{CDROOT}", "CDVol": "{LABEL}", "SrcDrv": "{DRIVE}" } }
  },
  "compat": { "layer": 3, "appcompat": "~ WIN98 256COLOR 640X480 DWM8And16BitMitigation HIGHDPIAWARE",
              "dxwnd": "FG.dxw", "affinity": 0 },
  "saves": ["PLYR*.INI", "volumes.sav", "ka.atr"],
  "validated": { "date": null, "notes": "" }
}
```

Variables: `{HD}`, `{CD}` (raíz de datos del CD: `E:` o `<inst>\cd\FG`), `{CDROOT}`, `{DRIVE}`, `{LABEL}`, `{INSTALL}`.

### 8.5 API interna de `Trampolin.Core.psm1`

| Función | Responsabilidad |
|---|---|
| `Test-TrPrerequisites` | Devuelve una lista de `{Id, Ok, Severity, Message}` para la pantalla 1 |
| `Find-TrIsos -Path` | Escanea la carpeta (y los ZIP), cruza con `games.json` y devuelve `{GameId, Path, SizeOk, KeyFileOk, Sha256Status}` |
| `Expand-TrZip` | Extrae las ISOs de `trampolin_anaya.zip` con progreso |
| `Mount-TrIso` / `Dismount-TrIso` | `Mount-DiskImage -PassThru` → letra y etiqueta (`Get-Volume`). Reintentos y timeout |
| `Copy-TrIsoContent` | 7-Zip (`7za x -o… -y -bsp1`, progreso parseado) o montaje + `robocopy /E /R:1 /W:1 /NP` |
| `Install-TrGame -Id -Options` | Orquesta: copiar → `attrib -R` → INIs → registro → accesos directos → manifest. Cada paso es idempotente |
| `Write-TrIni` | Escribe INI en **ANSI (cp1252)** con CRLF (los juegos usan `GetPrivateProfileStringA`). Merge, no sobrescritura, de `KA.INI` |
| `Set-TrCompatLayer` / `Remove-TrCompatLayer` | Registro `AppCompatFlags\Layers` |
| `New-TrShortcut` | `WScript.Shell` COM → `.lnk` con ícono del exe original |
| `Start-TrGame -Id` | Preparación + lanzamiento + espera + limpieza + diagnóstico |
| `Repair-TrGame`, `Uninstall-TrGame`, `Backup-TrSaves` | Mantenimiento a partir de `manifest.json` |

Todo lo de Core se puede testear con **Pester** sin UI (`tests\Core.Tests.ps1`), usando una ISO de prueba pequeña generada con `oscdimg`/`IMAPI2FS` y un `games.json` de prueba.

---

## 9. Manejo de errores

### 9.1 Principios

1. **El usuario nunca ve un stack trace ni un mensaje en inglés.** Ve un diálogo amigable con: ícono, título claro, qué pasó en lenguaje simple, **qué puede hacer** (botones de acción) y un enlace "Ver detalles técnicos" que despliega el código y la excepción.
2. **Todo paso de trabajo pasa por `Invoke-TrStep`:**
   ```powershell
   function Invoke-TrStep {
       param([string]$Name, [scriptblock]$Action, [string]$ErrorCode, [scriptblock]$Rollback)
       Write-TrLog -Level Info "BEGIN $Name"
       try   { $r = & $Action; Write-TrLog -Level Info "OK $Name"; return $r }
       catch {
           Write-TrLog -Level Error "FAIL $Name :: $($_.Exception.GetType().FullName) :: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
           if ($Rollback) { try { & $Rollback } catch { Write-TrLog -Level Error "ROLLBACK FAIL $Name :: $_" } }
           throw [TrampolinException]::new($ErrorCode, $_.Exception)   # la UI lo traduce con strings.es.json
       }
   }
   ```
3. **Log técnico** en `logs\trampolin-YYYYMMDD.log` (rotación a 10 archivos): timestamp, nivel, paso, versión de Windows, versión del runtime y comandos ejecutados. Botón "Copiar informe" que pone en el portapapeles el resumen + las últimas 200 líneas del log.
4. Las **operaciones largas** corren fuera del hilo de UI. Los errores vuelven a la UI por una cola sincronizada.
5. Los **errores parciales** no abortan todo: si falla un juego, los demás se instalan y el resumen lo indica.

### 9.2 Catálogo de errores (`strings.es.json`)

| Código | Cuándo | Mensaje al usuario | Acciones ofrecidas |
|---|---|---|---|
| `TR-ENV-001` | Windows de 32 bits o versión < 10 | "Trampolín Runtime necesita Windows 10 u 11 de 64 bits." | Cerrar |
| `TR-ENV-002` | Falta .NET 4.8 / PowerShell 5.1 | "Falta un componente de Windows (.NET Framework 4.8). Instalalo desde Windows Update y volvé a intentar." | Abrir Windows Update, Reintentar |
| `TR-ENV-003` | Virtualización UAC deshabilitada | "Tu equipo tiene una configuración de seguridad que impide guardar la configuración de los juegos sin permisos de administrador." | Continuar como administrador, Cancelar |
| `TR-ISO-001` | No se encontraron ISOs | "No encontramos los discos de Trampolín en esa carpeta. Elegí la carpeta donde están los archivos .iso." | Examinar…, Buscar automáticamente |
| `TR-ISO-002` | Tamaño o archivo clave incorrecto | "El archivo «{archivo}» no parece un disco de Trampolín válido o está dañado." | Elegir otro archivo, Ignorar este juego |
| `TR-ISO-003` | `Mount-DiskImage` falla | "No pudimos abrir el disco «{juego}». Puede que otro programa lo esté usando o que tu Windows no permita montar imágenes." | Reintentar, Usar el modo "Copiar al disco", Ver detalles |
| `TR-ISO-004` | Hash desconocido (no bloquea) | "Este disco es una edición distinta de la que probamos. Probablemente funcione igual." | Continuar |
| `TR-DSK-001` | Sin espacio | "No hay espacio suficiente en {unidad}: se necesitan {n} GB y hay {m} GB libres." | Elegir otra carpeta, Usar modo ISO, Liberar espacio |
| `TR-DSK-002` | Carpeta no escribible | "No se puede escribir en «{ruta}». Elegí otra carpeta (por ejemplo, la sugerida)." | Usar carpeta sugerida, Examinar… |
| `TR-DSK-003` | Ruta no representable en ANSI | "Los juegos son de 1997 y no entienden algunos caracteres de esa ruta (como «{car}»). Te recomendamos instalar en C:\Trampolin." | Usar C:\Trampolin, Elegir otra |
| `TR-CPY-001` | Error de lectura durante la copia | "Hubo un problema leyendo el disco «{juego}» (archivo {archivo}). La imagen puede estar dañada." | Reintentar, Saltar juego, Ver detalles |
| `TR-CPY-002` | Archivo bloqueado o antivirus | "Windows o el antivirus bloquearon un archivo del juego ({archivo}). Algunos antivirus desconfían de los programas antiguos." | Reintentar, Cómo agregar una excepción, Ver detalles |
| `TR-CFG-001` | Error al escribir INI/registro | "No pudimos guardar la configuración de «{juego}»." | Reintentar como administrador, Ver detalles |
| `TR-RUN-001` | Juego ya en ejecución | "Ya hay un juego de Trampolín abierto. Cerralo antes de abrir otro." | Ir al juego abierto, Aceptar |
| `TR-RUN-002` | Falta la ISO (modo B) | "Para jugar a «{juego}» necesitamos el archivo «{iso}», que ya no está en {ruta}." | Buscar el archivo…, Copiar el juego al disco |
| `TR-RUN-003` | El proceso termina en < 5 s | "«{juego}» se cerró al iniciar." | Probar con otro modo de compatibilidad (pasa al Nivel 2/3), Reparar, Ver detalles |
| `TR-RUN-004` | Código de salida `0xC0000005` (access violation) | "«{juego}» tuvo un error interno y se cerró." | Probar modo de compatibilidad alternativo, Copiar informe |
| `TR-RUN-005` | El juego no crea su ventana en 30 s | "«{juego}» está tardando demasiado en abrir." | Esperar, Cerrar juego |
| `TR-RUN-006` | Antivirus bloquea la inyección de `trhook.dll` | "El antivirus impidió activar el modo de compatibilidad avanzado." | Usar modo básico, Cómo agregar una excepción |
| `TR-UPD-001` | Error inesperado | "Ocurrió un error inesperado. No es tu culpa." | Copiar informe, Abrir log |

Las acciones "Probar con otro modo de compatibilidad" implementan un **fallback automático escalonado**: Nivel 3 → Nivel 2 → Nivel 1, guardando el que funcionó en `settings.json`.

---

## 10. Plan de ejecución paso a paso

Cada tarea indica **quién** la puede hacer: 🤖 = Claude Code en esta máquina, 👤 = humano (requiere ver la pantalla, jugar o decidir), 🤝 = ambos (Claude prepara, el humano verifica). Cada fase termina con un **criterio de salida** verificable.

### Fase R0 — Preparación del entorno (½ día)

| # | Tarea | Quién | Detalle / comando |
|---|---|---|---|
| R0.1 | Inicializar git en el proyecto y `.gitignore` (excluir `*.iso`, `*.zip`, `dist/`, `runtime/tools/*.exe`) | 🤖 | `git init` |
| R0.2 | Crear la estructura `runtime\` (§3.1) | 🤖 | |
| R0.3 | Instalar herramientas de diagnóstico | 👤 | Sysinternals **Process Monitor**, **Process Explorer**, **API Monitor** (rohitab), **x32dbg**, 7-Zip (ya instalado: `C:\Program Files\7-Zip\7z.exe`) |
| R0.4 | Instalar el toolchain nativo para el Nivel 3 | 👤/🤖 | `winget install Microsoft.VisualStudio.2022.BuildTools` (workload C++), `winget install Kitware.CMake`, vcpkg + `vcpkg install detours:x86-windows-static` |
| R0.5 | (Opcional, muy recomendado) Obtener la **verdad de referencia**: en una VM Win98 de un solo uso (86Box/PCem/VirtualBox), instalar cada juego con su instalador original y copiar `C:\WINDOWS\KA.INI`, `<HD>\*.INI` y el listado de archivos instalados | 👤 | Elimina las conjeturas de §4 sobre claves de INI. Es una tarea única: la VM no forma parte del producto |
| R0.6 | Calcular el SHA-256 de las 8 ISOs y volcarlo a `games.json` | 🤖 | `Get-FileHash *.iso -Algorithm SHA256` |

**Salida:** repositorio creado, herramientas instaladas, hashes registrados.

### Fase R1 — Prueba de concepto manual del Nivel 0 + 1 (1-2 días)

Para **cada** juego, empezando por FG (la familia KA-MFC cubre 4 de los 8 juegos), luego PRE_K (PEEWEE) y luego PRSCHOOL (ACES):

| # | Tarea | Quién | Detalle |
|---|---|---|---|
| R1.1 | Montar la ISO | 🤖 | `$img = Mount-DiskImage -ImagePath "<ruta>" -PassThru; $vol = $img \| Get-Volume; $vol.DriveLetter; $vol.FileSystemLabel` |
| R1.2 | Aplicar la receta §4 a mano en `C:\TrampolinPOC\games\<ID>` | 🤖 | `robocopy E:\SUPPORT\W32 <HD> /E`, `robocopy E:\SUPPORT\CMN <HD> /E`, `copy E:\SUPPORT\WINSYS\WING32.DLL <HD>`, `attrib -R <HD>\* /S` |
| R1.3 | Escribir el INI del juego y `KA.INI` en `%LOCALAPPDATA%\VirtualStore\Windows\KA.INI` | 🤖 | Codificación ANSI |
| R1.4 | Aplicar la capa de compatibilidad | 🤖 | `New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' -Name '<HD>\FG.EXE' -Value '~ WIN98 256COLOR 640X480 DWM8And16BitMitigation HIGHDPIAWARE' -Force` |
| R1.5 | Arrancar Process Monitor (filtro por el exe) y lanzar el juego | 👤 | Observar si arranca, si aparece la intro, los colores y si se oye la voz |
| R1.6 | Analizar el log de ProcMon: `NAME NOT FOUND`/`PATH NOT FOUND` en `*.INI`, `*.RSC`, `*.BAL`, `*.DF`; lecturas de `C:\Windows\KA.INI` (¿virtualizado?) | 🤖 | Exportar a CSV (`Procmon.exe /OpenLog x.pml /SaveAs x.csv`) y filtrar con PowerShell |
| R1.7 | Iterar las claves de INI hasta que no haya accesos fallidos relevantes | 🤝 | Documentar el resultado en `games.json` |
| R1.8 | Probar la matriz §11 para el juego | 👤 | Registrar los resultados en `runtime\tests\matrix.md` |
| R1.9 | Variantes de capa (con/sin `256COLOR`, `WIN95` vs `WIN98`; PEEWEE `GraphicStrategy` 1/2/3/5) | 🤝 | Registrar cuál funciona mejor |

**Salida:** para cada juego, una receta confirmada (archivos, INI, capas) y un estado: ✅ jugable con Nivel 0+1 / ⚠ jugable con problemas (colores, mouse, sonido) / ❌ no arranca. Los ⚠ y ❌ pasan a la Fase R2 o R3.

### Fase R2 — Nivel 2 con DxWnd (1 día)

| # | Tarea | Quién |
|---|---|---|
| R2.1 | Descargar DxWnd y verificar la versión y la línea de comandos soportada (`dxwnd.exe /?` o el README) | 🤖 |
| R2.2 | Para cada juego ⚠/❌: crear un perfil en la GUI de DxWnd con las opciones de §6 e iterar hasta que funcione | 👤 |
| R2.3 | Exportar los perfiles a `runtime\src\data\dxwnd\<ID>.dxw` | 👤 |
| R2.4 | Probar el lanzamiento por línea de comandos desde PowerShell | 🤖 |
| R2.5 | Repetir la matriz §11 | 👤 |

**Salida:** los 8 juegos son jugables con Nivel 0+1 o con Nivel 2. **En este punto el objetivo (1) ya está cumplido funcionalmente** y se puede construir el instalador (Fase R4) en paralelo con la Fase R3.

### Fase R3 — Nivel 3: runtime propio (1-2 semanas)

| # | Tarea | Quién | Criterio |
|---|---|---|---|
| R3.1 | Proyecto CMake `runtime\native` con targets `wing32` (SHARED, `.def` con las 10 exportaciones, nombre de salida `WING32`), `trhook` (SHARED + Detours) y `trlaunch` (EXE), todo `-A Win32` | 🤖 | `cmake -B build -A Win32 && cmake --build build --config Release` compila |
| R3.2 | `WING32.DLL` passthrough: misma semántica que la original más logging de cada llamada (parámetros, tamaños, paletas) | 🤖 | FG funciona igual que con la DLL original y el log muestra la secuencia de llamadas |
| R3.3 | Analizar el log: tamaños de bitmaps, orientación (top-down/bottom-up), frecuencia de `WinGBitBlt` y uso de `AnimatePalette` | 🤝 | Documento `native\wing32\NOTES.md` |
| R3.4 | Implementar el backbuffer de 32 bpp + conversión con LUT + presentación escalada (§7.2) | 🤖 | FG se ve con colores correctos **sin** la capa `256COLOR` |
| R3.5 | `trhook` mínimo: `ChangeDisplaySettingsA`, `SetSystemPaletteUse`, `SetSysColors`, `SHAppBarMessage`, `GetDeviceCaps` | 🤖 | El escritorio no cambia de resolución ni de colores al jugar |
| R3.6 | Paleta virtual: `CreatePalette`/`SelectPalette`/`RealizePalette`/`AnimatePalette`/`SetPaletteEntries` → LUT de WING32 | 🤖 | Los fundidos a negro y entre escenas se ven bien |
| R3.7 | Ventana host escalada + reenvío de input con transformación de coordenadas (§7.3 opción ii) | 🤖 | Clics precisos a 2× y 3× y en pantalla completa con letterbox |
| R3.8 | Redirección de `KA.INI` y volumen/CD virtual (`GetDriveTypeA`, `GetVolumeInformationA`, rutas) | 🤖 | Modo A funciona sin montar la ISO ni `subst` |
| R3.9 | Ruta no-WinG (`StretchDIBits`/`SetDIBitsToDevice` de 8 bpp) para PEEWEE con `GraphicStrategy=1/3` y para ACES si no usa WinG | 🤖 | PRE_K, 4G y ACES se ven bien |
| R3.10 | `trlaunch`: creación suspendida + inyección + configuración por memoria compartida + código de salida | 🤖 | |
| R3.11 | Pruebas de regresión con los 8 juegos (matriz §11) | 👤 | Todos ✅ en Nivel 3 |
| R3.12 | Firmar los binarios (opcional; reduce los falsos positivos de antivirus) | 👤 | Certificado de firma de código |

### Fase R4 — Instalador y lanzador con UI (1 semana; puede empezar tras R2)

| # | Tarea | Quién |
|---|---|---|
| R4.1 | `Trampolin.Errors.psm1`: `Invoke-TrStep`, `Write-TrLog`, la clase `TrampolinException` y la carga de `strings.es.json` | 🤖 |
| R4.2 | `Trampolin.Iso.psm1`: `Find-TrIsos`, `Mount-TrIso`, `Copy-TrIsoContent` (con progreso), `Expand-TrZip` | 🤖 |
| R4.3 | `Trampolin.Core.psm1`: instalación, INI (ANSI), registro, accesos directos, manifest, reparar, desinstalar, backup | 🤖 |
| R4.4 | Tests Pester de Core con un `games.json` de prueba y una ISO sintética | 🤖 |
| R4.5 | `UI\Wizard.ps1`: las 8 pantallas de §8.2, trabajo en un Runspace y progreso | 🤖 |
| R4.6 | `UI\Launcher.ps1`: biblioteca, opciones por juego, menú contextual, fallback automático de capas | 🤖 |
| R4.7 | `UI\Dialogs.ps1`: diálogo de error amigable con detalles desplegables y botones de acción | 🤖 |
| R4.8 | `Trampolin.cmd` + `build.ps1` (empaqueta `dist\TrampolinRuntime-<versión>.zip`; opcional `ps2exe` → `Trampolin.exe`) | 🤖 |
| R4.9 | Revisión de usabilidad: hacer la instalación completa como lo haría un padre o madre sin conocimientos técnicos | 👤 |
| R4.10 | Escribir `LEEME-RUNTIME.md` (§10.1) | 🤖 |

### Fase R5 — Pulido (2-3 días)

- R5.1 🤖 Conversión de los `.HLP` a HTML (helpdeco) → "Guía para padres" en el lanzador.
- R5.2 🤖 Mejoras de MIDI opcionales: detectar si hay un sintetizador alternativo (por ejemplo, VirtualMIDISynth) y documentarlo en el LEEME.
- R5.3 🤖 Desinstalación completa: borra `games\`, `cd\`, accesos directos, registro `Layers` y secciones de `KA.INI`, y **pregunta antes de borrar las partidas**.
- R5.4 👤 Pruebas en una segunda máquina limpia con Windows 10 y otra con Windows 11.

### Fase R6 — Entrega

- 🤖 `dist\TrampolinRuntime-1.0.0.zip` con `Trampolin.cmd`, `app\`, `tools\` y `LEEME-RUNTIME.md`. No incluye las ISOs.
- 👤 Prueba de aceptación final (§11.3).

### 10.1 Contenido de `LEEME-RUNTIME.md` (documento para el usuario final)

1. Qué es y qué necesitás (Windows 10/11 64 bits, las ISOs, unos 3 GB libres).
2. Instalación en 5 pasos con capturas: descomprimir el ZIP → doble clic en `Trampolin.cmd` → elegir la carpeta de las ISOs → elegir juegos y carpeta → Instalar.
3. Cómo jugar (acceso directo o biblioteca) y cómo salir del juego.
4. Opciones: ventana o pantalla completa, tamaño, sonido.
5. Partidas: dónde se guardan y cómo hacer copia de seguridad.
6. Problemas frecuentes, con las mismas soluciones del catálogo §9.2 en formato pregunta-respuesta: "La pantalla se ve con colores raros", "No hay sonido", "El antivirus lo bloquea", "Me pide el CD".
7. Desinstalar.
8. Créditos y aviso legal: juegos de Knowledge Adventure/Anaya; el runtime no incluye los juegos.

---

## 11. Matriz de pruebas

### 11.1 Por juego (registrar ✅/⚠/❌ + nota)

| Prueba | Qué verificar |
|---|---|
| T1 Arranque | El proceso arranca, no hay diálogo de error y la ventana aparece en menos de 10 s |
| T2 Intro | Animación o video de introducción con colores correctos y sonido |
| T3 Registro de jugador | Crear un jugador nuevo, escribir el nombre (teclado), se crea `PLYR0001.INI` |
| T4 Menú principal | Colores correctos, cursor del juego visible, hotspots responden al mouse |
| T5 Actividad (×3) | Entrar a 3 actividades distintas, jugar 2 minutos cada una |
| T6 Voz | Diálogos de personajes (`SOUND.BAL`/`.DF`) sin cortes ni desincronización |
| T7 Música | MIDI suena y el volumen del juego la controla |
| T8 Fundidos | Transiciones entre escenas sin parpadeo ni "flash" de colores |
| T9 Video | (4G) los Smacker se reproducen |
| T10 Velocidad | Animaciones a velocidad normal (comparar con un video de YouTube del juego original) |
| T11 Guardar y salir | Salir desde el juego y volver a entrar: el progreso se conserva |
| T12 Imprimir | (Si el juego lo ofrece) imprimir a "Microsoft Print to PDF" |
| T13 Alt+Tab | Cambiar de ventana y volver: el juego sigue con colores correctos |
| T14 Escritorio | Al salir, la resolución y los colores del escritorio están intactos |
| T15 DPI | Con el escalado de Windows al 150 %, el mouse coincide con los botones |
| T16 Sesión larga | 30 minutos de juego sin cuelgues ni pérdida de memoria (Process Explorer) |

### 11.2 Del instalador

Instalación limpia; instalación con ruta personalizada con espacios; ruta con `ñ` (tiene que dar el aviso `TR-DSK-003`); cancelar a mitad (rollback); sin espacio (simulado con un VHD pequeño); ISO renombrada; ISO truncada (`TR-ISO-002`); modo B con la ISO movida (`TR-RUN-002`); reparar después de borrar un archivo; desinstalar (no quedan restos salvo las partidas si el usuario elige conservarlas); ejecución como usuario estándar sin admin; Windows 11.

### 11.3 Aceptación final

- Un usuario sin conocimientos técnicos instala los 8 juegos solo con `LEEME-RUNTIME.md` en menos de 15 minutos.
- Los 8 juegos pasan T1-T11 y T13-T15.
- No queda ningún cambio en el sistema fuera de `%LOCALAPPDATA%\Trampolin`, `VirtualStore\Windows\KA.INI`, `HKCU\…\Layers` y los accesos directos (verificado con un snapshot de registro y archivos antes/después).

---

## 12. Diagnóstico y resolución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| "No se encuentra WING32.DLL" | Falta la DLL junto al exe | Copiar `SUPPORT\WINSYS\WING32.DLL` (o la propia) a `HD` |
| "La ejecución en modo no-WinG requiere 256 colores" | WinG no cargó y el escritorio está en 32 bits | Ver la fila anterior; o capa `256COLOR` |
| "Por favor, inserte el CD-Rom…" | Etiqueta/letra de `KA.INI` desactualizada, o modo A sin CD virtual | Reparar (reescribe la etiqueta), modo B, o Nivel 3 con volumen virtual |
| "Archivo INI dañado" | Se editó o recodificó un INI cifrado (`MESSAGES.INI`, `MODULE.INI`, etc.) | Reparar (vuelve a copiarlo del CD tal cual) |
| Colores psicodélicos / fondo negro / parpadeo | Emulación de paleta de DWM | Nivel 3 (o Nivel 2 con *Emulate palette*) |
| El escritorio cambia de colores después de jugar | `SetSysColors` del juego | Nivel 3 (hook) o cerrar sesión. El lanzador guarda `GetSysColor` antes y los restaura después |
| Mouse desplazado | Escalado DPI | Capa `HIGHDPIAWARE`; Nivel 3 con transformación de entrada |
| Sin voces pero con música | `WSOUND32.DLL` no encuentra un dispositivo o falla `OpenDriver` | Verificar la salida de audio predeterminada; probar `SoundStrategy=2`; API Monitor sobre `waveOutOpen` |
| Sin música | No hay dispositivo MIDI | Verificar "Microsoft GS Wavetable Synth" (`midiOutGetNumDevs`); ver R5.2 |
| ACES se cuelga o va acelerado | Temporización por hilo y multinúcleo | Afinidad a 1 CPU |
| Se cierra al instante sin mensaje | DLL faltante, ruta o DEP | ProcMon (DLL no encontrada), Visor de eventos → Application Error (módulo con fallo), x32dbg |
| No guarda progreso | Archivos de solo lectura | `attrib -R` (Reparar) |

**Procedimiento general de diagnóstico** (lo puede hacer Claude con la salida de las herramientas):
1. Process Monitor filtrado por el proceso → exportar CSV → buscar `NAME NOT FOUND` y `ACCESS DENIED`.
2. API Monitor con los grupos *Graphics and Gaming → GDI*, *Audio and Video → Windows Multimedia* y *System Services → Kernel* → ver la última llamada antes del fallo.
3. Visor de eventos (`Get-WinEvent -LogName Application -MaxEvents 20 | ? ProviderName -eq 'Application Error'`) → módulo y offset del fallo.
4. x32dbg: lanzar el exe y romper en la excepción. Con el offset, ubicar la función en Ghidra (importar el exe con auto-análisis; en los exe KA-MFC aplicar las firmas FID de MFC 4.x/MSVC 5, en ACES (Watcom) usar `__watcall` como convención por defecto y en PEEWEE (Borland) `__fastcall`).

---

## 13. Riesgos y planes de contingencia

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Las claves de INI deducidas no son exactas | Media | Medio | ProcMon + verdad de referencia en VM Win98 de un solo uso (R0.5) |
| ACES no funciona con el contenedor fuera de una unidad CD | Media | Medio | Modo B (ISO montada) para ACES |
| Paleta: la capa `256COLOR` no alcanza | Alta | Alto | Niveles 2/3 (diseñados justamente para esto) |
| Antivirus marca `trhook.dll`/DxWnd por la inyección | Media | Medio | Firmar binarios; fallback a Nivel 1/2; mensaje `TR-RUN-006` |
| Una actualización de Windows rompe el montaje o la virtualización | Baja | Medio | Modo A + Nivel 3 (no depende de ninguna de las dos) |
| Algún juego usa una API sin hookear y falla en Nivel 3 | Media | Bajo | El fallback automático a Nivel 2/1 y el log de llamadas facilitan agregar el hook |
| Bugs de los juegos que en 1997 quedaban ocultos (timing, desbordes) | Baja | Medio | Afinidad, limitador de FPS, parche binario puntual (Ghidra) documentado por juego |

**Contingencia final (no recomendada, rompe la premisa "sin VM"):** si algún juego resultara imposible, el lanzador puede ofrecer correrlo en 86Box/PCem con una imagen de Windows 98 preconfigurada. Se descarta salvo necesidad extrema.

---

## 14. Apéndices

### 14.1 Tamaños exactos de las ISOs (para validación)

| ISO | Bytes |
|---|---|
| Trampolin - 1° Ciclo.iso | 416 952 320 |
| Trampolin - 2° Ciclo.iso | 300 566 528 |
| Trampolin - 5° Curso.iso | 494 227 456 |
| Trampolin - 6° Curso.iso | 524 453 888 |
| Trampolín Educación Infantil - 1° Ciclo.iso | 140 679 168 |
| Trampolín Educación Infantil - 2° Ciclo.iso | 94 410 752 |
| Trampolín Educación Infantil - Primera Infancia.iso | 153 976 832 |
| Trampolín Educación Infantil - Primeros Pasos.iso | 255 424 512 |

### 14.2 Imports relevantes por ejecutable (resumen del análisis)

- **FG/KG.EXE**: `USER32!ChangeDisplaySettingsA/EnumDisplaySettingsA/SetSysColors`, `GDI32!SetSystemPaletteUse/AnimatePalette/RealizePalette/StretchDIBits/SetDIBitsToDevice`, `KERNEL32!GetVolumeInformationA/GetDriveTypeA/GetPrivateProfileStringA`, `WINMM!midiOut*/mciSendStringA/waveOutGetDevCapsA`, `SHELL32!SHAppBarMessage`; dinámicos: `WING32.DLL`, `WSOUND32.DLL`.
- **2G.EXE**: igual, sin `ChangeDisplaySettingsA`.
- **3G.EXE**: igual que FG + `DragQueryFileA`, `RegQueryValueExA`, `GetVersionExA`.
- **ACES.EXE**: `KERNEL32!CreateThread/GetThreadContext/ResumeThread/VirtualProtect/GetVolumeInformationA/GetDriveTypeA`, `WINMM!aux*/midiOut*/waveOut*/mciSendCommandA`, `GDI32!AnimatePalette/SetDIBitsToDevice/StretchDIBits/PlayMetaFile`; dinámico: `WING32.DLL`.
- **PRE_K.EXE / 4G.EXE**: `GDI32!CreateDIBitmap/StretchDIBits/SetSystemPaletteUse/GdiFlush`, `WINMM!waveOut*/timeBeginPeriod`, `USER32!SetSysColors/ShowCursor`; 4G: `smackw32!_Smack*`; dinámico: `WING32.DLL` (todas las exportaciones).
- **WING32.DLL** (original): exporta `WinGBitBlt, WinGCreateBitmap, WinGCreateDC, WinGCreateHalftoneBrush, WinGCreateHalftonePalette, WinGGetDIBColorTable, WinGGetDIBPointer, WinGRecommendDIBFormat, WinGSetDIBColorTable, WinGStretchBlt`; importa solo GDI32/USER32/KERNEL32.

### 14.3 Comandos de referencia

```powershell
# Montar ISO y obtener letra y etiqueta
$img = Mount-DiskImage -ImagePath "C:\…\Trampolin - 1° Ciclo.iso" -PassThru
$vol = $img | Get-Volume
"$($vol.DriveLetter): '$($vol.FileSystemLabel)'"
Dismount-DiskImage -ImagePath $img.ImagePath

# Extraer ISO sin montar
& "C:\Program Files\7-Zip\7z.exe" x "Trampolin - 1° Ciclo.iso" -o"C:\Trampolin\cd\FG" -y -bsp1

# Escribir INI en ANSI (cp1252) con CRLF
[IO.File]::WriteAllLines($path, $lines, [Text.Encoding]::GetEncoding(1252))

# Capa de compatibilidad
$k = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
New-Item $k -Force | Out-Null
New-ItemProperty $k -Name 'C:\Trampolin\games\FG\FG.EXE' -Value '~ WIN98 256COLOR 640X480 DWM8And16BitMitigation HIGHDPIAWARE' -PropertyType String -Force

# Lanzar con afinidad a 1 CPU
$p = Start-Process -FilePath $exe -WorkingDirectory $hd -PassThru; $p.ProcessorAffinity = 1; $p.WaitForExit(); $p.ExitCode
```
