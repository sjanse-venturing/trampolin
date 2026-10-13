# Trampolín Remaster — Guía para el usuario

**Trampolín Remaster** es una versión moderna (en desarrollo) de los juegos *Trampolín* (Anaya / Knowledge Adventure). Funciona en Windows 10 y 11 y **usa tus propios discos** (`.iso`) sin modificarlos ni copiarlos a internet.

> **Estado actual (versión 0.1):** podés registrar tus discos, recorrer la **Galería** de escenarios de los juegos de Primaria e Infantil 2° Ciclo con su música, y **explorar y exportar** todos los recursos (imágenes, voces, música, textos). Para **jugar**, el botón *Jugar (original)* abre el juego original mediante **Trampolín Runtime**. La reimplementación jugable de cada juego avanza por etapas (ver `REMASTER.md`).

---

## 1. Qué necesitás

- Windows 10 u 11 de 64 bits.
- Los discos de los juegos como archivos `.iso` (por ejemplo, los de `trampolin_anaya.zip` descomprimidos).
- Para *Jugar (original)*: tener instalado **Trampolín Runtime** (carpeta `runtime` del proyecto).

## 2. Instalar y abrir

**Opción A — versión portable (recomendada):**
1. Descomprimí `TrampolinRemaster-0.1.0-portable.zip` en una carpeta.
2. Abrí **`Trampolin Remaster.exe`**.

**Opción B — desde el código fuente:**
1. Hacé doble clic en **`Trampolin-Remaster.cmd`**.
2. La primera vez se verifica que tengas **Node.js** (si falta, ofrece instalarlo), se descargan los componentes y se prepara la aplicación. Puede tardar unos minutos. Las siguientes veces abre en segundos.

## 3. Primera vez: registrar los discos

1. Presioná **Empezar**.
2. **Elegir carpeta…**: indicá dónde están los `.iso`. La aplicación reconoce automáticamente cada juego.
3. Elegí si usar los discos **desde donde están** (recomendado) o **copiarlos** a otra carpeta.
4. **Registrar discos** → **Ir a la biblioteca**.

Podés agregar más discos cuando quieras con **Agregar discos** (arriba a la derecha).

## 4. La biblioteca

Cada juego muestra su estado:

| Etiqueta | Qué podés hacer |
|---|---|
| **Galería y recursos** | *Galería*: escenarios a pantalla completa con fundidos y música del juego. *Recursos*: explorador. |
| **Explorador de recursos** | *Recursos*: navegar el disco y exportar lo que se pueda leer. |
| **Original: listo** | Trampolín Runtime está instalado con este juego: *Jugar (original)* lo abre. |

### Galería
- Clic, **→** o **Espacio**: siguiente escenario · **←**: anterior.
- **♪ Música**: activar o desactivar · **⛶**: pantalla completa · **Esc** o **✕ Salir**: volver.

### Recursos
- Navegá el disco a la izquierda. Los contenedores (📦) se abren como carpetas.
- **Imágenes**: vista previa, paleta de colores y **Exportar PNG**.
- **Voces y sonidos**: reproducir, elegir la frecuencia y **Exportar WAV**.
- **Música** (MIDI): reproducir con el sintetizador integrado.
- **Textos**: lectura directa (incluye los scripts originales de algunos juegos).
- **Guardar original…**: guarda el archivo tal cual está en el disco.

## 5. Opciones

**Opciones** (arriba): tamaño de la imagen (*Ajustar a la ventana*, *Escala entera* o *Tamaño original*), suavizado y volumen de música y voces.

## 6. Problemas frecuentes

| Mensaje | Qué hacer |
|---|---|
| **No encontramos los discos** | Elegí la carpeta que contiene los archivos `.iso`. |
| **Disco no válido** | La imagen está dañada o incompleta: volvé a copiarla. |
| **Falta el disco** | Moviste o borraste el `.iso`. En la tarjeta del juego, **···** → *Buscar el disco…*. |
| **Falta Trampolín Runtime** | Instalá Trampolín Runtime (descomprimí su `.zip` y abrí `Trampolin.cmd`), instalá el juego y volvé a intentar. |
| **Recurso ilegible** / «formato en investigación» | Ese tipo de archivo todavía no está reimplementado; podés guardarlo con *Guardar original…*. |
| **Falta Node.js** (opción B) | Aceptá instalarlo cuando se ofrezca, o descargalo de nodejs.org, y volvé a abrir `Trampolin-Remaster.cmd`. |
| **No pudimos descargar los componentes** (opción B) | Revisá la conexión a internet y volvé a intentar. |
| **Cualquier otro error** | Presioná **Copiar informe** en el mensaje y envialo a quien te ayude. Los registros están en `%APPDATA%\Trampolín Remaster\logs` (**Ayuda → Abrir registros**). |

## 7. Privacidad y aviso legal

- Todo funciona sin conexión (salvo la descarga inicial de componentes en la opción B). No se envía ningún dato.
- Los juegos *Trampolín* son propiedad de sus titulares (Knowledge Adventure / Anaya). Trampolín Remaster **no incluye** contenido de los juegos: lee los discos que vos aportás.
- Para volver a empezar desde cero, borrá la carpeta `%APPDATA%\Trampolín Remaster`.
