# REMASTER — Reimplementación moderna de la serie Trampolín para Windows 10/11

> **Objetivo:** construir una versión nueva y nativa de los juegos *Trampolín* (JumpStart de Knowledge Adventure, 1995-1998). Un **motor reimplementado desde cero**, al estilo de ScummVM, que lee los datos originales de las ISOs del usuario (gráficos, sonidos, música, scripts y textos) y los ejecuta en una aplicación moderna con escalado, modo ventana, audio y UI actuales. **Nunca redistribuye contenido con copyright.**
>
> **Producto final:** *Trampolín Remaster* = aplicación de escritorio para Windows (`Trampolín Remaster.exe`) con asistente de importación de ISOs, biblioteca de juegos, opciones, manejo de errores amigable, scripts de instalación/ejecución (`remaster\Trampolin-Remaster.cmd`, `scripts\*.ps1`) y el documento de usuario `LEEME-REMASTER.md`.

---

## 0. Estado de la implementación (2026-10-11)

> **Fases M0 y M1 implementadas en `remaster/`**, más una parte del motor (M3). La aplicación funciona y está probada contra las 8 ISOs reales. La reimplementación **jugable** de cada juego (M2-M4) es el trabajo de los próximos meses, según el plan de este documento. Mientras tanto, la app abre la versión original con Trampolín Runtime (plan B, §11.3).

### 0.1 Qué se construyó

| Pieza | Archivos | Estado |
|---|---|---|
| App de escritorio | `remaster/src/main/*` (Electron 44, proceso principal), `src/preload/preload.cjs`, `src/renderer/*` (interfaz en TypeScript sin frameworks) | ✅ `contextIsolation` + `sandbox`, CSP estricta, IPC que nunca lanza excepciones entre procesos |
| Lectores de formatos (TS puro) | `src/formats/`: `iso9660` (ISO+Joliet), `kafs`, `bwrf`, `bmp` (8 bits + RLE8), `kasnd`, `acespal`, `midi`, `wav`, `vfs` | ✅ F1-F4, F10, MIDI; F5 parcial (PCM) |
| Sistema de archivos virtual | `src/formats/vfs.ts` | ✅ ISO → carpetas → contenedores BWRF/KAFS anidados, con rutas uniformes (`FG/SOUND.BAL\|BA/BA005B.SND`) |
| Motor (núcleo) | `src/renderer/engine/`: `presenter` (superficie indexada de 640×480 + paleta + escalado ajustar/entero/original + suavizado), `audio` (mezclador WebAudio), `synth` (sintetizador GM propio), `midiplayer` | ✅ base de M3 |
| Asistente de primera ejecución | `src/renderer/ui/wizard.ts` | ✅ detecta los 8 discos, los usa en su lugar o los copia (con progreso) |
| Biblioteca | `ui/library.ts` | ✅ miniaturas decodificadas de los discos, estado por juego, relocalizar o quitar disco |
| **Galería** (primer uso del motor) | `ui/gallery.ts` | ✅ KG, FG, 2G, 3G: escenarios a pantalla completa con fundidos por paleta y música del juego |
| Visor de recursos | `ui/viewer.ts` | ✅ árbol, vista previa de imagen/paleta/sonido/MIDI/texto/hex, exportar PNG/WAV/original |
| Puente con Runtime | `src/main/runtime-bridge.ts` | ✅ "Jugar (original)" con Trampolín Runtime, si está instalado |
| Errores | `src/shared/errors.ts`, `ui/modal.ts`, `main/log.ts` | ✅ catálogo tipado, mensajes amigables, "Copiar informe", log rotativo |
| Scripts | `Trampolin-Remaster.cmd` + `scripts/run.ps1` (ventana de progreso: verifica Node, instala, compila, abre), `scripts/package.mjs` | ✅ portable en `release/TrampolinRemaster-0.1.0-portable.zip` |
| Pruebas | `test/formats.test.ts` (14), `test/iso.integration.test.ts` (10, contra las ISOs reales con `TRAMPOLIN_ISOS`) | ✅ 24/24 |
| Documento de usuario | `remaster/LEEME-REMASTER.md` | ✅ |

### 0.2 Hallazgos nuevos que cambian el plan

1. **Los scripts fuente de ACES están en los discos.** Los paquetes `PRSCHOOL` y `TODDLER` contienen el **código fuente** "Accomplish" (`.ACE`) de **todas** las actividades: 198 archivos (1,4 MB) y 92 archivos (464 KB), con comentarios e historial de revisiones de 1995 (por ejemplo `MENU/MANIMS.ACE`). La reimplementación de ACES pasa de "descifrar bytecode" (F14) a **escribir un intérprete de un lenguaje documentado por su propio código**. Esa familia baja de riesgo y su estimación se reduce (§11).
2. **"KA Sound File" confirmado:** cabecera de 54 bytes. En `0x0F` va la codificación (1 = PCM, 2 = comprimido), en `0x13` los bits (8 sin signo / 16 con signo), en `0x20` la cantidad de muestras y los datos empiezan en `0x36`. El 99 % de los sonidos de los juegos KA-MFC son PCM (ya reproducibles). El códec comprimido lo usan casi todos los sonidos de ACES (1.477 de 1.543): pendiente F5.
3. **Música:** los `.WGM` de ACES son MIDI estándar (SMF); los `.WSB` serían la variante para FM.
4. Motores originales y compatibilidad: ver RUNTIME.md §0.2. Varias causas (deadlocks de audio en `DllMain`, animación de paleta) también afectan el diseño del motor nuevo: el presentador trabaja en 8 bits indexados justamente para reproducir los fundidos por paleta.

### 0.3 Cómo usarlo

- **Usuario:** `remaster\release\TrampolinRemaster-0.1.0-portable.zip` → `Trampolin Remaster.exe`; o doble clic en `remaster\Trampolin-Remaster.cmd` (ver `remaster\LEEME-REMASTER.md`).
- **Desarrollo:** `npm install`, `npm run build`, `npm start`, `npm test` (con `TRAMPOLIN_ISOS=<carpeta>` para la integración) y `npm run package`.

### 0.4 Próximos pasos (en orden)

1. **F5:** códec comprimido de "KA Sound File" (ACES) con Ghidra sobre `ACES.EXE`/`WSOUND32.DLL`.
2. **F11/F12:** `LzH2`/`LzH3` (imágenes y películas de ACES).
3. **Intérprete Accomplish** a partir de los `.ACE` (gramática, objetos, eventos) → primer juego jugable: *Infantil 1° Ciclo*.
4. **F6/F7:** ATR/SCN para KA-MFC → escenas interactivas de FG.
5. **F16:** `.DF` de PEEWEE.

---

## Índice

1. [Por qué reimplementar y no parchear](#1-por-qué-reimplementar-y-no-parchear)
2. [Lo que ya sabemos de los datos (ingeniería inversa inicial)](#2-lo-que-ya-sabemos-de-los-datos)
3. [Arquitectura del remaster](#3-arquitectura-del-remaster)
4. [Fase 1 — Ingeniería inversa de formatos](#4-fase-1--ingeniería-inversa-de-formatos)
5. [Fase 2 — Ingeniería inversa del comportamiento](#5-fase-2--ingeniería-inversa-del-comportamiento)
6. [Fase 3 — Motor nuevo](#6-fase-3--motor-nuevo)
7. [Fase 4 — Juego por juego](#7-fase-4--juego-por-juego)
8. [Fase 5 — Remasterización (mejoras)](#8-fase-5--remasterización)
9. [Producto final: app, instalador, UI y errores](#9-producto-final)
10. [Plan de ejecución paso a paso](#10-plan-de-ejecución-paso-a-paso)
11. [Estimaciones, riesgos y plan B](#11-estimaciones-riesgos-y-plan-b)
12. [Aspectos legales](#12-aspectos-legales)

---

## 1. Por qué reimplementar y no parchear

| Enfoque | Descripción | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **A. Parchear los binarios originales** | Modificar `FG.EXE` y los demás (Ghidra + parches) y envolverlos | Rápido para arreglos puntuales | Hay que parchear 9 binarios de 3 compiladores distintos; los gráficos y la resolución quedan en 640×480 a 8 bits; no hay código fuente y cada cambio es frágil | Sirve de **puente** y ya está cubierto por RUNTIME.md (Nivel 3) |
| **B. Recompilación / descompilación completa** | Descompilar todo el exe a C compilable (estilo "decomp projects") | Fidelidad máxima | Meses o años por juego; MFC/Watcom/Borland complican la recompilación exacta | Desproporcionado |
| **C. Reimplementar el motor (estilo ScummVM)** ✅ | Escribir un motor nuevo que entienda los **formatos de datos** y el **lenguaje de scripts** de cada familia, y reproducir en código nuevo la lógica que no está en datos | Un motor por familia sirve para varios juegos; es moderno, escalable y portable; permite mejoras | Requiere RE de formatos y comportamiento | **Recomendado** |

**La clave del enfoque C:** hay solo **3 familias de motor** para 8 juegos, y gran parte del contenido vive en datos documentables:

| Familia | Juegos | Datos más importantes |
|---|---|---|
| **KA-MFC / "Broadway"** | FG (1° Ciclo), 2G (2° Ciclo), KG (Infantil 2° Ciclo), 3G (5° Curso) — **4 juegos** | `.RSC` (BWRF10: escenas `.SCN`, actores `.ATR`, bitmaps BMP), `SOUND.BAL` (voces), `.MID`/`.MGM` (música), INIs de contenido (preguntas, módulos, diálogos) |
| **ACES ("Accomplish")** | TODDLER (Primeros Pasos), PRSCHOOL (Infantil 1° Ciclo) — **2 juegos** | Contenedor KAFS con **scripts en un lenguaje tipo inglés** (`.ACE`) y su versión compilada (`.PAC`), paletas en texto (`.PAL`), imágenes comprimidas (`.CMP`, "LzH2"), películas (`.MVI`/`.MOV`, "LzH3"), fuentes `.FNT`, sonidos `.SND` |
| **PEEWEE** | PRE_K (Primera Infancia), 4G (6° Curso) — **2 juegos** | Contenedores `.DF` (tabla de recursos por ID), videos Smacker `.SMK` (4G) |

---

## 2. Lo que ya sabemos de los datos

Análisis hecho el 2026-10-11 sobre las ISOs de este directorio, con lectura binaria directa. Esto **ya está verificado**, no son hipótesis.

### 2.1 `BWRF10` — Broadway Resource File (`*.RSC`, familia KA-MFC)

```
offset  tamaño  campo
0       6       magic "BWRF10"
6       4       u32 count  (n entradas)
10      20*n    entradas: char name[12] (ASCIIZ, rellenado con 0), u32 offset, u32 size
...             datos concatenados; offset+size de la última entrada == tamaño del archivo
```

Ejemplo `FG\32BIT\BA001.RSC`: 334 entradas = 256 `.ATR` + 75 `.BMP` + 3 `.SCN`.

- **`.BMP`**: **BMP de Windows estándar** (`BM`, `BITMAPINFOHEADER`, 640×480, 8 bpp, `biCompression = 1` = **RLE8**, con paleta de 256 colores). Se decodifica con cualquier lector de BMP. ✅
- **`.SCN`** (escena): `"SCN"` + nombre[16] + bitmap de fondo[?] (`"ba001.bmp"`) + lista de objetos/actores: nombre lógico (`"Arrow"`), recurso (`ARROW.BMP`/`arrow.atr`), coordenadas y tamaños (`0x35×0x2C`), etc. Hay que mapear la estructura completa (Fase 1).
- **`.ATR`** (actor/animación): `"ATR11"` + nombre[16] + bitmap de paleta (`BA001.BMP`) + cabecera de cuadros (ancho/alto, por ejemplo 0x34×0x2A, número de cuadros, hotspot) + **datos de sprite comprimidos con un códec propio tipo RLE** (secuencias `0f f1 …`, `10 xx`, `11 xx`). Hay que descifrar el códec (Fase 1, con Ghidra sobre la rutina que lo lee).
- Convención: `xx001.RSC` en el CD (contenido) y `xx002.RSC` instalados en el disco (resumen/índices).

### 2.2 KAFS — sistema de archivos de Knowledge Adventure (`SOUND.BAL`, `SOUND2.BAL`, contenedores ACES `TODDLER`/`PRSCHOOL`)

El **mismo formato** se usa en los archivos de sonido del motor MFC y en el pack completo del motor ACES. Es un árbol de directorios:

```
Directorio (en el offset X; la raíz está en 0):
  u32 n
  n × entrada { u32 nameOffset, i32 dataOffset (absoluto en el archivo), u32 size, u32 flags, u32 reserved }
      flags & 0x8000 → es un subdirectorio (dataOffset apunta a otro bloque "Directorio")
      entradas "." y ".." siempre presentes ("..": dataOffset = -1 en la raíz)
  u32 namesLength
  char names[namesLength]   (ASCIIZ concatenados; nameOffset indexa acá)
  ...datos alineados
```

Verificado:
- `FG\SOUND.BAL` (326 MB): 41 directorios y **5.786 archivos `.SND`** (por ejemplo `/BA/BA005B.SND`).
- `PRSCHOOL` (137 MB): 7.911 entradas, entre ellas 2.409 `.CMP`, 1.543 `.SND`, 531 `.MVI`, 198 `.ACE`, 166 `.PAL`, 135 `.MSG`, 132 `.MOV`, 51 `.TXT`, 40 `.PAX`, fuentes `.FNT` y tiles `.TIL/.T00-.T15`.

### 2.3 `KA Sound File` (`*.SND`)

```
"KA Sound File" 0x1A  + bytes de parámetros (p. ej. 02 01 01 06 08 08 02 01 66 ... / 02 02 01 06 08 10 ...)
+ cabecera con longitudes  + datos
```

- Variante `… 08 08 …`: **PCM de 8 bits sin signo** (silencio = `0x80`, verificado en `/BA/BA005B.SND`).
- Variante `… 08 10 …`: datos empaquetados de 4 bits (nibbles `0x44 0x55 …`), probablemente **ADPCM** (IMA o propietario). A determinar en la Fase 1.
- Frecuencia de muestreo: probablemente codificada en los bytes de parámetros (por ejemplo 11.025 o 22.050 Hz). A determinar.

### 2.4 Formatos de ACES

| Extensión | Contenido verificado |
|---|---|
| `.ACE` | **Código fuente** del lenguaje de scripts "Accomplish" en un inglés casi natural: *"Make a blue screen. In it, Make labels… When the enter key is pressed, Change foo to yellow."* |
| `.PAC` / `.PAX` | Scripts compilados a bytecode (`START.PAC` empieza con `BZ`, con cadenas embebidas: `PRSCHOOL`, `SHELL\ENG\LANGUAGE.TXT`, `PRSCHOOL.CMP`, `concentration`, `letter`, `number`, `picture`, `shape`) |
| `.PAL` | Paleta **en texto**: `PAL\r\n<n>\r\nR G B\r\n…` |
| `.CMP` | Imagen comprimida, magic `LzH2` (LZ + Huffman, variante propietaria), con metadatos (`+WINFIX+`) |
| `.MVI` | Película/animación, magic `LzH3`, que contiene sub-bloques `LzH2` y referencias `dog.mov` |
| `.FNT`, `.TXT`, `.MSG`, `.TIL`/`.Txx`, `.DAT`, `.WGM` | Fuentes, textos/etiquetas, mensajes, tiles. A analizar |

**Implicación importante:** si `.PAC` es la compilación de `.ACE`, en el peor caso hay que escribir un **intérprete del bytecode**, y en el mejor, un **intérprete del lenguaje fuente** (si todos los `.PAC` tienen su `.ACE` correspondiente; a verificar). Los dos son mucho más tratables que reimplementar la lógica a mano.

### 2.5 PEEWEE `.DF`

```
"DF" 00 00 | u32 ? | u32 capacidad (0x3A98 = 15000) | ... | tabla u32 offset[id] desde 0x10 (0 = recurso vacío) | datos
```

En `DATA.DF` de Pre-K hay unos 11.700 IDs con offset no nulo. El contenido de los recursos **no tiene cabeceras legibles**: probablemente está comprimido u ofuscado. Es el formato menos conocido y queda **para el final** (Fase 4).

### 2.6 Otros

- `.MID`: MIDI estándar (SMF). ✅
- `.MGM`: bloque `mdat` (variante de música o secuencia: posiblemente un formato MIDI propietario de KA). A determinar.
- `.SMK`: **Smacker v2** (`SMK2`, 640×480). Lo decodifican FFmpeg y libsmacker. ✅
- INIs de contenido (`MODULE.INI`, `SPEECH.INI`, `MCQ.INI`, `MESSAGES.INI`): **valores cifrados** (hexadecimal + checksum: `MaxLevel=EB,EB000000`, `Tool09=9ECAA7592CA5B13687,356F166F`). El algoritmo está en el exe y se recupera con Ghidra buscando las referencias a `"CorruptINI"`.

---

## 3. Arquitectura del remaster

### 3.1 Stack tecnológico

| Capa | Elección | Motivo |
|---|---|---|
| Lenguaje | **TypeScript** (estricto) | Es el ecosistema del usuario (WebStorm); fácil de leer y mantener; sobra potencia para 640×480 |
| Shell de escritorio | **Electron** | UI nativa de Windows, acceso a archivos, empaquetado a `.exe`; Chromium trae Canvas/WebGL/WebAudio |
| Render | Canvas 2D (fase inicial) → WebGL2 (filtros de escalado, shaders CRT/xBR opcionales) | Simple primero, mejoras después |
| Audio | WebAudio (mezclador propio) + sintetizador MIDI por software (SoundFont GM, p. ej. *spessasynth* o un sintetizador propio) | Independiente de los dispositivos MIDI de Windows |
| Video | Decodificador Smacker en TS (portado de libsmacker, LGPL) o preconversión con FFmpeg durante la importación | Smacker es simple y está bien documentado |
| Herramientas de RE | Ghidra, ImHex (patrones `.hexpat`), Python 3 (scripts de exploración), x32dbg, API Monitor, Frida | Estándar de la industria |
| Tests | Vitest (unitarios de decodificadores), Playwright para Electron (e2e de la UI), golden images | |

Alternativa considerada: C++20 + SDL3, más "clásico" y más portable a consolas, pero más lento de iterar para este equipo. Si en el futuro hiciera falta, el diseño modular (formatos ⟂ motor ⟂ plataforma) permite portar los módulos.

### 3.2 Estructura del repositorio

```
remaster/
├─ Trampolin-Remaster.cmd       ← doble clic: verifica, instala dependencias, compila y ejecuta
├─ LEEME-REMASTER.md            ← documento para el usuario final
├─ package.json / tsconfig*.json
├─ scripts/
│  ├─ setup.ps1                 ← verifica Node.js, instala dependencias, mensajes amigables
│  ├─ run.ps1                   ← compila si hace falta y ejecuta
│  └─ package.ps1               ← genera la app portable/instalable en dist\
├─ src/
│  ├─ formats/                  ← lectores puros (sin DOM ni Node): BinaryReader, iso9660, kafs, bwrf, bmp, kasnd, aces-pal, ...
│  ├─ engine/                   ← motor: VFS, recursos, escena, actores, audio, input, loop, guardado
│  │  └─ families/{kamfc,aces,peewee}/   ← intérpretes y lógica específica por familia
│  ├─ main/                     ← proceso principal de Electron: ventanas, IPC, importación, logs, errores
│  ├─ preload/                  ← puente seguro (contextIsolation) renderer ↔ main
│  ├─ renderer/                 ← UI: asistente, biblioteca, opciones, visor de recursos, pantalla de juego
│  └─ shared/                   ← tipos, catálogo de juegos, códigos de error
├─ tools/                       ← CLI: extract, dump, ImHex patterns, Ghidra scripts
└─ test/                        ← unit + e2e
```

### 3.3 Flujo de datos

```
ISO del usuario ──(importación)──► lector ISO9660 propio (sin montar)
     │                                   │
     │                                   ▼
     │                    VFS: rutas del CD (FG/32BIT/BA001.RSC, FG/SOUND.BAL, ...)
     │                                   │  + KAFS (SOUND.BAL, PRSCHOOL) montados como subárboles
     ▼                                   ▼
Biblioteca (%APPDATA%\Trampolin Remaster\library.json)  ←  caché de assets decodificados (opcional)
                                         │
                                         ▼
           Motor (familia) ── escena/actores/scripts ── Render (Canvas/WebGL) / Audio (WebAudio)
```

**Decisión:** el motor lee **directamente de la ISO** con un lector ISO9660 propio (random access con `fs.read`). No hace falta extraer ni montar, y el usuario solo "registra" sus ISOs. La caché de assets decodificados es opcional (se usa para velocidad).

---

## 4. Fase 1 — Ingeniería inversa de formatos

Para **cada formato**: (1) hipótesis desde la observación, (2) patrón ImHex, (3) búsqueda de la rutina lectora en Ghidra para confirmar campos, (4) decodificador en TS con tests y (5) validación visual o auditiva contra el juego original corriendo con RUNTIME.md.

### 4.1 Preparación de Ghidra (una vez por exe)

1. Instalar Ghidra (requiere JDK 21) y crear el proyecto `TrampolinRE`.
2. Importar `FG.EXE`, `3G.EXE`, `ACES.EXE`, `PRE_K.EXE`, `4G.EXE`, `WSOUND32.DLL` y `SMACKW32.DLL`.
3. Auto-análisis con *Decompiler Parameter ID* activado.
4. **KA-MFC:** aplicar las firmas FID de MFC 4.x/MSVC 5 (o el script *RecoverClassesFromRTTI*) para nombrar clases y métodos de MFC y separar el código propio del de la biblioteca.
5. **Watcom (ACES):** convenciones de llamada por registro (`__watcall`); configurar el *calling convention* por defecto.
6. **Borland (PEEWEE):** `__fastcall` de Borland y los nombres exportados (`.edata` trae símbolos como `_wingBitBlt`, `_get_program_path`, `_drawing_surface`).
7. Buscar referencias a cadenas clave (`"BWRF10"`, `"KA Sound File"`, `"CorruptINI"`, `"LzH2"`, `".SCN"`, `"ATR11"`, `"DF"`) para llegar a los lectores.

### 4.2 Orden y detalle

| # | Formato | Pasos concretos | Criterio de "terminado" |
|---|---|---|---|
| F1 | **ISO9660/Joliet** | Lector propio: PVD/SVD, path table o recorrido de directorios, nombres Joliet UCS-2 | Lista los mismos archivos que 7-Zip en las 8 ISOs |
| F2 | **KAFS** | §2.2 (ya conocido) | Lista y extrae los `.SND` de `SOUND.BAL` y todo `PRSCHOOL`/`TODDLER` |
| F3 | **BWRF10** | §2.1 (ya conocido) | Lista todas las entradas de todos los `.RSC` de los 4 juegos MFC sin solaparse |
| F4 | **BMP RLE8** | Decodificador RLE8 (modos absoluto, delta y fin de línea) | Los 75 BMP de `BA001.RSC` se ven idénticos a capturas del juego |
| F5 | **KA Sound File** | Comparar varias cabeceras, ubicar el parser en `WSOUND32.DLL` (busca `"KA Sound File"`), identificar frecuencia, bits y códec. Si es ADPCM, probar IMA y luego un códec propio con la tabla de pasos extraída del binario | Reproducción sin ruido y a velocidad correcta de 20 `.SND` al azar, comparada con una grabación del original |
| F6 | **ATR** (sprites) | En Ghidra, buscar `"ATR11"` → función de carga → función de dibujo (blit con transparencia). Reimplementar el códec en TS. Validar renderizando todos los cuadros de `ARROW.ATR` | Las animaciones de los personajes se ven igual que en el original |
| F7 | **SCN** (escenas) | Mapear la estructura completa: fondo, lista de objetos, hotspots, z-order, rutas (*paths*). Correlacionar con lo que se ve en pantalla | El visor reconstruye la composición estática de 10 escenas |
| F8 | **INIs cifrados** | Ghidra: referencias a `"CorruptINI"` → función de descifrado y checksum → reimplementar | `MODULE.INI`/`MCQ.INI`/`SPEECH.INI` descifrados a texto legible |
| F9 | **MGM** | Comparar con `.MID`; buscar el lector de `"mdat"` | Reproducción igual al original |
| F10 | **ACES `.PAL`** | Parser de texto | Paletas aplicadas correctamente |
| F11 | **ACES `.CMP` (LzH2)** | Ghidra en ACES.EXE: buscar `"LzH2"`. Es probablemente LZSS + Huffman estilo LHA `-lh5-`: probar primero el algoritmo LHA estándar | Imágenes de ACES visibles |
| F12 | **ACES `.MVI` (LzH3)** | Contenedor de cuadros LzH2 + tiempos + sonido | Películas reproducidas |
| F13 | **ACES `.FNT`, `.TIL/.Txx`, `.MSG`, `.TXT`** | Exploración + Ghidra | Texto y tiles correctos |
| F14 | **ACES `.PAC` (bytecode)** | Comparar `.ACE` ↔ `.PAC` del mismo nombre para inferir opcodes. Ghidra: intérprete de ACES (bucle `switch` grande) | Desensamblador de `.PAC` a texto legible |
| F15 | **Smacker** | Portar libsmacker o usar FFmpeg en la importación | Videos de 4G reproducidos |
| F16 | **PEEWEE `.DF`** | Ghidra en PRE_K.EXE (que tiene símbolos Borland útiles): buscar el lector por `"%s%s.INI"`/`.DF`, la tabla de IDs y la descompresión | Imágenes y sonidos de Pre-K visibles y audibles |

Cada formato se entrega con: `src/formats/<fmt>.ts`, `tools/imhex/<fmt>.hexpat`, `test/formats/<fmt>.test.ts` (con fixtures pequeños generados desde las ISOs **en tiempo de test, no versionados**) y una sección en `docs/formats.md`.

---

## 5. Fase 2 — Ingeniería inversa del comportamiento

Lo que **no** está en datos hay que observarlo y reimplementarlo.

### 5.1 Técnicas

1. **Trazado dinámico** sobre el juego original corriendo con *Trampolín Runtime* (RUNTIME.md):
   - API Monitor y el log del `WING32.DLL` propio: qué recursos se cargan, en qué orden y con qué timing.
   - Process Monitor: qué `.RSC`/`.SND` se leen en cada pantalla (offsets incluidos), para correlacionar escenas con archivos.
   - Frida (`frida -f FG.EXE -l trace.js`): hooks a las funciones internas identificadas en Ghidra (carga de escena, reproducción de sonido, evaluación de respuesta).
2. **Grabaciones de referencia:** video y audio de cada actividad jugada en el original (OBS), usados como "oráculo" para comparar.
3. **Ghidra:** máquina de estados de cada actividad, reglas de puntaje y progresión, formato de los `PLYR%04d.INI`.
4. **Cadenas de los exes** como pistas: en 3G hay un **mini-lenguaje de animación** embebido: `start actor %s on path %ld at point %d,%d`, `aligned to regmark`, `stapled to actor %s at offset %d,%d`, `on trajectory %s`. El motor interpreta comandos de texto, lo que facilita reimplementarlo.

### 5.2 Entregables por familia

- **KA-MFC:** especificación de escena (`.SCN`), sistema de actores/paths/trayectorias, comandos de animación, sistema de preguntas (`MCQ.INI` → banco de preguntas), registro de jugadores, mapa de navegación entre módulos (`MODULE.INI`), diálogos (`SPEECH.INI` → archivo `.SND` en `SOUND.BAL`).
- **ACES:** especificación del lenguaje Accomplish (gramática, objetos, eventos `When … is pressed`, comandos `Make`, `Change`, `Restore`, `Display`) y del bytecode `.PAC`.
- **PEEWEE:** recursos por ID, lógica de actividades (probablemente en código, no en datos: es la familia de mayor esfuerzo).

---

## 6. Fase 3 — Motor nuevo

### 6.1 Módulos

| Módulo | Responsabilidad |
|---|---|
| `vfs` | Acceso uniforme: ISO9660 → archivo; KAFS → subárbol; BWRF → subárbol. Rutas insensibles a mayúsculas. Lectura asíncrona por rangos |
| `resources` | Caché LRU de assets decodificados (bitmaps → `ImageBitmap`, sonidos → `AudioBuffer`) |
| `gfx` | Superficie lógica de 640×480 en **8 bpp indexado** (fiel al original: fundidos y animación de paleta exactos) → conversión a RGBA con LUT → presentación escalada (entera / ajustar, filtro nearest/suave/xBR) |
| `audio` | Mezclador WebAudio: canales de voz, efectos y música; volúmenes independientes; duck de música durante las voces |
| `midi` | Secuenciador SMF + sintetizador SoundFont |
| `input` | Mouse lógico (coordenadas 640×480 desde la ventana escalada), teclado, cursores del juego |
| `scene` | Fondo + actores + z-order + hotspots + paths |
| `script` | Intérpretes: KA-MFC (comandos de animación + lógica de módulos), ACES (Accomplish/bytecode), PEEWEE |
| `save` | Perfiles de jugador en JSON (`%APPDATA%\Trampolin Remaster\saves\`), con **importación** de los `PLYR*.INI` originales |
| `loop` | Lógica a la tasa original (por ejemplo 15 o 30 ticks/s, a medir), render a la tasa del monitor con interpolación nula (pixel art) |

### 6.2 Principios

- **Fidelidad primero:** el modo "Original" reproduce el comportamiento 1:1; las mejoras son opcionales (§8).
- **Determinismo:** el loop de lógica es independiente del render, así que se puede testear con *golden frames*.
- **Sin assets en el repo:** todo se lee de las ISOs del usuario.

---

## 7. Fase 4 — Juego por juego

Orden recomendado (de mayor a menor reaprovechamiento):

1. **FG (1° Ciclo)**: primer juego de la familia KA-MFC, con todo el trabajo de formatos ya hecho.
2. **2G, KG, 3G**: misma familia, diferencias incrementales (3G tiene el mini-lenguaje de animación más rico).
3. **PRSCHOOL** y luego **TODDLER**: familia ACES, con el intérprete Accomplish.
4. **PRE_K** y luego **4G**: familia PEEWEE, con el formato DF y Smacker.

Hitos por juego (cada uno se valida contra las grabaciones de referencia):

| Hito | Descripción |
|---|---|
| H1 | Visor: todos los assets del juego navegables en el *Visor de recursos* de la app |
| H2 | Intro y menú principal reproducidos (gráficos, música, voz, hotspots) |
| H3 | Registro y selección de jugador |
| H4 | Cada actividad jugable (una por una; checklist por actividad) |
| H5 | Progresión, puntajes y guardado |
| H6 | Paridad: una sesión completa de 30 minutos sin diferencias perceptibles respecto del original |

---

## 8. Fase 5 — Remasterización

Opcionales, se activan en Opciones → "Mejoras":

- **Escalado:** filtros xBR/HQx/ScaleFX por shader (WebGL2), y escalado entero con barras laterales.
- **Arte HD:** pipeline offline de *upscaling* con IA (por ejemplo Real-ESRGAN para anime/ilustración) de fondos y sprites, **revisado a mano** y guardado como "pack HD" local generado desde las ISOs del usuario. Los sprites se reescalan cuadro por cuadro conservando el índice de transparencia.
- **Audio:** remuestreo de alta calidad de las voces (8/11 kHz → 48 kHz), reducción de ruido opcional, MIDI con SoundFont de alta calidad.
- **Accesibilidad:** subtítulos de las voces (cuando el texto existe en los INI/MSG), cursor grande, modo alto contraste, tiempos de espera configurables.
- **Calidad de vida:** guardado automático, perfiles de padres, informe de progreso exportable (PDF/HTML).
- **Pruebas de regresión visual:** *golden frames* del modo "Original" vs. capturas del juego original. Las mejoras nunca rompen el modo Original.

---

## 9. Producto final

### 9.1 Instalación y ejecución

**Para el usuario final** (fase de distribución):
- `TrampolinRemaster-Setup.exe` (NSIS vía electron-builder): carpeta de instalación, accesos directos, desinstalador. **O** la versión portable `TrampolinRemaster-portable.zip` → `Trampolín Remaster.exe`.

**Desde el código fuente** (lo que entrega este repositorio):
- `remaster\Trampolin-Remaster.cmd` (doble clic) ejecuta `scripts\run.ps1`, que:
  1. Verifica que Node.js ≥ 20 esté instalado. Si no está, muestra un diálogo amigable con el enlace de descarga, o ofrece instalarlo con `winget install OpenJS.NodeJS.LTS`.
  2. Corre `npm ci`/`npm install` si falta `node_modules` o cambió `package-lock.json`, con progreso visible.
  3. Compila TypeScript si las fuentes son más nuevas que la salida.
  4. Ejecuta la app.
  5. Ante cualquier error, muestra un diálogo con el mensaje en español y guarda el detalle en `remaster\logs\setup-*.log`.
- `scripts\package.ps1` genera `dist\` (portable y, si se pide, instalador).

### 9.2 Asistente de primera ejecución (dentro de la app)

| Paso | Pantalla | Inputs | Validaciones |
|---|---|---|---|
| 1 | **Bienvenida** | — | — |
| 2 | **Tus discos** | Botón "Elegir carpeta…" (busca `*.iso` y `trampolin_anaya.zip`) y "Agregar archivo ISO…". Lista de ISOs detectadas con juego, edad, estado | Lectura del PVD, archivo clave por juego y tamaño; SHA-256 en segundo plano. Errores amigables (`E_ISO_INVALID`, `E_ISO_UNKNOWN`) |
| 3 | **Dónde guardar** | Carpeta de datos (por defecto `%APPDATA%\Trampolin Remaster`) para perfiles y caché. ☐ "Copiar las ISOs a la carpeta de la app" (para no depender de su ubicación) | Escribible; espacio libre |
| 4 | **Importación** | Barra de progreso: indexado de cada ISO, catálogo de recursos, prueba de decodificación de una muestra. Botón Cancelar | Reanudable; un error en una ISO no aborta las demás |
| 5 | **Listo** | "Ir a la biblioteca" | — |

### 9.3 Pantallas principales

- **Biblioteca:** tarjetas por juego (portada extraída de los datos, edad, estado de soporte: *Jugable*, *Parcial*, *Solo visor*), botón **Jugar** y menú (Visor de recursos, Opciones, Quitar).
- **Pantalla de juego:** canvas escalado, barra superior que se oculta sola (Pausa, Volumen, Pantalla completa, Salir), `F11` para pantalla completa y `Esc` para el menú de pausa.
- **Visor de recursos:** árbol del VFS (ISO → contenedores → recursos), vista previa de imagen/paleta/sprite/sonido/texto, exportar a PNG/WAV/MID/TXT. Es la herramienta central de las fases 1-2.
- **Opciones:** video (escalado, filtro, pantalla completa, mejoras), audio (volúmenes, SoundFont), controles, accesibilidad, avanzado (abrir logs, limpiar caché, modo desarrollador).
- **Perfiles:** jugadores, importación de partidas originales.

### 9.4 Manejo de errores

- **Códigos tipados** en `src/shared/errors.ts`: `class TrError extends Error { code: TrErrorCode; userMessage: string; action?: TrAction; cause?: unknown }`.
- **Catálogo** (`src/shared/errors.ts` + `strings.es`):

| Código | Mensaje para el usuario | Acción |
|---|---|---|
| `E_NODE_MISSING` (script) | "Para ejecutar Trampolín Remaster necesitás instalar Node.js (gratis)." | Abrir página / instalar con winget |
| `E_DEPS_INSTALL` (script) | "No pudimos descargar los componentes necesarios. Revisá tu conexión a internet." | Reintentar / Ver log |
| `E_ISO_NOT_FOUND` | "No encontramos discos de Trampolín en esa carpeta." | Elegir otra carpeta |
| `E_ISO_INVALID` | "«{archivo}» no es una imagen de disco válida o está dañada." | Elegir otro archivo |
| `E_ISO_UNKNOWN` | "Este disco no corresponde a ningún juego Trampolín conocido." | Elegir otro archivo |
| `E_ISO_MOVED` | "No encontramos el disco de «{juego}» en {ruta}. ¿Lo moviste?" | Buscar… / Quitar juego |
| `E_DISK_FULL` | "No hay espacio suficiente en {unidad}." | Elegir otra carpeta |
| `E_NOT_WRITABLE` | "No se puede escribir en «{ruta}»." | Elegir otra carpeta |
| `E_ASSET_DECODE` | "Un recurso del juego no se pudo leer ({recurso}). El juego puede seguir, pero algo puede verse o sonar mal." | Continuar / Copiar informe |
| `E_GAME_UNSUPPORTED` | "Este juego todavía no se puede jugar en el Remaster. Podés explorar sus recursos o jugarlo con Trampolín Runtime." | Abrir visor / Abrir Runtime |
| `E_ENGINE_CRASH` | "El juego tuvo un problema y se detuvo. Tu progreso hasta el último guardado está a salvo." | Reintentar desde el menú / Copiar informe |
| `E_UNEXPECTED` | "Ocurrió un error inesperado. No es tu culpa." | Copiar informe / Abrir logs |

- **Proceso principal:** `process.on('uncaughtException' | 'unhandledRejection')` → log + diálogo amigable, sin cerrar la app salvo que el estado sea irrecuperable.
- **Renderer:** *error boundary* por pantalla. Un error en el motor muestra la pantalla de error recuperable, no una ventana en blanco.
- **Log:** `%APPDATA%\Trampolin Remaster\logs\remaster-YYYYMMDD.log` (rotación a 7 días), con versión, sistema operativo, juego, escena y la pila completa. Botón **"Copiar informe"**.

### 9.5 Documento de usuario `LEEME-REMASTER.md`

Qué es; requisitos; instalación (portable / instalador / desde código fuente con `Trampolin-Remaster.cmd`); primera ejecución e importación de discos; jugar; opciones; estado de soporte por juego; problemas frecuentes (catálogo de §9.4 en formato pregunta-respuesta); privacidad (todo local, sin conexión); aviso legal.

---

## 10. Plan de ejecución paso a paso

🤖 = Claude Code · 👤 = humano · 🤝 = ambos.

### Fase M0 — Fundaciones (3-5 días)

| # | Tarea | Quién |
|---|---|---|
| M0.1 | `remaster/` con Electron + TypeScript estricto, ESLint y Vitest. `package.json` con scripts `build`, `start`, `test`, `extract` | 🤖 |
| M0.2 | `scripts/setup.ps1`, `scripts/run.ps1` y `Trampolin-Remaster.cmd` con verificación de Node.js, instalación de dependencias y mensajes amigables | 🤖 |
| M0.3 | `src/shared/catalog.ts`: los 8 juegos (ID, nombre, edad, familia, ISO esperada, tamaño, archivo clave) | 🤖 |
| M0.4 | `src/shared/errors.ts` + logging en main + diálogo de error | 🤖 |
| M0.5 | Lector ISO9660/Joliet (F1) + tests contra las 8 ISOs | 🤖 |
| M0.6 | Asistente de primera ejecución + biblioteca (§9.2-9.3) | 🤖 |

**Salida:** la app arranca, importa las 8 ISOs y muestra la biblioteca.

### Fase M1 — Formatos conocidos y visor (1 semana)

| # | Tarea | Quién |
|---|---|---|
| M1.1 | KAFS (F2), BWRF10 (F3), BMP RLE8 (F4), `.PAL` de ACES (F10), MIDI (reproducción) | 🤖 |
| M1.2 | **Visor de recursos** con árbol, vista previa de imágenes y paletas y exportación a PNG | 🤖 |
| M1.3 | KA Sound File: variante PCM 8 bits (F5 parcial) + reproducción en el visor | 🤖 |
| M1.4 | Revisión visual: comparar 20 bitmaps con capturas del original (vía RUNTIME) | 👤 |

### Fase M2 — Formatos desconocidos con Ghidra (2-4 semanas)

| # | Tarea | Quién |
|---|---|---|
| M2.1 | Instalar Ghidra + JDK 21 y crear el proyecto con los 7 binarios (§4.1) | 👤 |
| M2.2 | KA Sound File, variante comprimida (F5) | 🤝 Claude puede leer el pseudocódigo exportado de Ghidra (`Export → C`) y reimplementarlo |
| M2.3 | ATR (F6) y SCN (F7) | 🤝 |
| M2.4 | INIs cifrados (F8) y MGM (F9) | 🤝 |
| M2.5 | LzH2/LzH3 (F11-F12), FNT/TIL/MSG (F13) | 🤝 |
| M2.6 | Bytecode `.PAC` (F14) | 🤝 |
| M2.7 | Smacker (F15) y DF (F16) | 🤝 |

**Método de colaboración recomendado:** el humano ubica la función en Ghidra y exporta su pseudocódigo C a `remaster/re/<binario>/<función>.c`. Claude la analiza, la anota y escribe el decodificador equivalente en TypeScript con tests. Ghidra también se puede manejar en modo *headless* (`analyzeHeadless` con scripts Python/Java), así que buena parte del trabajo lo puede automatizar Claude.

### Fase M3 — Motor (3-4 semanas)

M3.1 VFS + recursos · M3.2 gfx indexado + escalado · M3.3 audio + MIDI · M3.4 input · M3.5 escena/actores/paths · M3.6 loop determinista · M3.7 guardado · M3.8 pantalla de juego con pausa y opciones. Todo 🤖, con revisión 👤 de sensaciones (timing, audio).

### Fase M4 — Juegos (de 4 a 12 semanas **por familia**)

Según §7. Cada hito H1-H6 cierra con una revisión 👤 contra la grabación de referencia.

### Fase M5 — Remasterización y distribución (2-4 semanas)

§8 + `scripts/package.ps1` (electron-builder: NSIS + portable), firma de código opcional, pruebas en Windows 10 y 11 limpios, `LEEME-REMASTER.md` final.

---

## 11. Estimaciones, riesgos y plan B

### 11.1 Esfuerzo estimado (una persona con asistencia de Claude Code)

| Fase | Estimación |
|---|---|
| M0 Fundaciones | 3-5 días |
| M1 Formatos conocidos + visor | 1 semana |
| M2 RE de formatos | 2-4 semanas |
| M3 Motor | 3-4 semanas |
| M4 KA-MFC (4 juegos) | 6-12 semanas |
| M4 ACES (2 juegos) | 3-6 semanas (el código fuente `.ACE` de todas las actividades está en los discos, ver §0.2) |
| M4 PEEWEE (2 juegos) | 6-12 semanas (la lógica está en código, no en datos) |
| M5 Remaster + distribución | 2-4 semanas |
| **Total** | **≈ 6-12 meses** para los 8 juegos con paridad completa |

### 11.2 Riesgos

| Riesgo | Mitigación |
|---|---|
| Lógica de actividades codificada en C++ (no en datos), sobre todo en PEEWEE | RE dirigido con Ghidra + trazas con Frida; priorizar actividades; aceptar "Parcial" temporalmente |
| Códecs propietarios difíciles (ATR, LzH2, DF) | Ghidra + comparación de entrada y salida en memoria (volcando el buffer decodificado del proceso original con x32dbg/Frida como oráculo) |
| Timing y "sensación" distintos del original | Medir los ticks reales con trazas; grabaciones de referencia |
| Alcance excesivo | El orden por familia entrega valor temprano (FG jugable antes que nada) y el visor es útil desde M1 |
| Diferencias regionales en los datos (versión española) | Todo se valida con las ISOs del usuario, no con documentación de la versión en inglés |

### 11.3 Plan B

Si una familia resulta inviable de reimplementar en un plazo razonable, la app de Remaster **lanza ese juego con Trampolín Runtime (Nivel 3)** desde la misma biblioteca. Mantiene la experiencia unificada (UI, perfiles, escalado vía el `WING32.DLL` propio) mientras avanza la reimplementación.

---

## 12. Aspectos legales

- Los juegos son propiedad de sus titulares (Knowledge Adventure → hoy en manos de terceros; edición española de Anaya). "Abandonware" **no** es una figura legal: el remaster **no incluye ni redistribuye** ningún asset, y el usuario aporta sus propias ISOs.
- El código del motor es original. Las bibliotecas de terceros se usan respetando sus licencias (Electron MIT, libsmacker LGPL si se porta, SoundFonts con licencia libre).
- La ingeniería inversa con fines de interoperabilidad está contemplada en muchas jurisdicciones (por ejemplo, Directiva UE 2009/24/CE art. 6). Conviene validarlo con asesoramiento local antes de distribuir públicamente.
