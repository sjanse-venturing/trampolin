# Trampolín Runtime — Guía para el usuario

Trampolín Runtime permite jugar los juegos clásicos **Trampolín** (Anaya / Knowledge Adventure, 1995-1998) en **Windows 10 y Windows 11** de 64 bits, sin máquinas virtuales y sin cambiar la configuración de tu computadora.

Juegos incluidos (necesitás sus discos en formato `.iso`):

| Juego | Edad |
|---|---|
| Educación Infantil – Primeros Pasos | 2 a 3 años |
| Educación Infantil – 1° Ciclo | 3 a 4 años |
| Educación Infantil – Primera Infancia | 4 años |
| Educación Infantil – 2° Ciclo | 5 años |
| Educación Primaria – 1° Ciclo | 6 a 7 años |
| Educación Primaria – 2° Ciclo | 7 a 8 años |
| Educación Primaria – 5° Curso | 8 a 9 años |
| Educación Primaria – 6° Curso | 9 a 10 años |

---

## 1. Qué necesitás

- Windows 10 u 11 de 64 bits.
- Los discos de los juegos como archivos `.iso` (o el archivo `trampolin_anaya.zip` que los contiene).
- Espacio libre: unos **2,5 GB** para los 8 juegos copiados a la computadora (o unos 100 MB si elegís usar los `.iso` desde donde están).
- **No** hace falta ser administrador ni instalar nada más.

## 2. Instalar

1. Descomprimí el archivo `TrampolinRuntime-x.y.z.zip` en cualquier carpeta (por ejemplo, en *Descargas*).
2. Hacé **doble clic en `Trampolin.cmd`**.
3. Seguí el asistente:
   1. **Bienvenida**: revisa que la computadora sea compatible. Si todo está en verde, presioná *Siguiente*.
   2. **¿Dónde están los discos?**: elegí la carpeta con los `.iso` y presioná *Buscar*. Si solo tenés el `.zip`, usá *Extraer el ZIP…*.
   3. **Elegí los juegos**: marcá los que quieras (por defecto, todos los que se encontraron).
   4. **¿Dónde instalar?**: dejá la carpeta sugerida o elegí otra con una **ruta corta y sin caracteres especiales** (por ejemplo, `C:\Trampolin`). Elegí también si querés **copiar los juegos completos** (recomendado: después no necesitás los `.iso`) o **usar los `.iso`** desde donde están.
   5. **Pantalla**: *Ajustar a la pantalla* (recomendado), *Doble de tamaño* o *Tamaño original*.
   6. **Resumen** → *Instalar*. Podés cancelar en cualquier momento: se deshace solo el juego que se estaba copiando.
4. Al terminar, presioná **Abrir la biblioteca**.

## 3. Jugar

- Desde la **Biblioteca Trampolín** (menú Inicio → *Trampolín* → *Biblioteca Trampolín*): presioná **▶ Jugar** en el juego que quieras.
- O directamente desde los accesos directos del menú Inicio (carpeta **Trampolín**) o del Escritorio.

Para salir de un juego, usá la salida del propio juego (por ejemplo, la flecha roja o el cartel **SALIDA**). Al cerrarse, vuelve la biblioteca.

> Los juegos se ven en pantalla completa con bordes negros a los costados: es normal, son juegos de formato 4:3.

## 4. Opciones y mantenimiento

En la biblioteca, el botón **···** de cada juego ofrece:

- **Reparar**: vuelve a copiar los archivos del juego sin tocar las partidas guardadas.
- **Copia de seguridad de las partidas**: guarda un `.zip` en *Documentos\Trampolín - partidas*.
- **Abrir la carpeta del juego**.
- **Desinstalar…**: borra el juego (antes guarda una copia de las partidas).

Abajo hay botones para **Agregar juegos…**, cambiar el **tamaño de pantalla** (*Opciones…*), ver esta **Ayuda** y **Ver registro** (para pedir ayuda técnica).

## 5. Problemas frecuentes

| Problema | Qué hacer |
|---|---|
| **«No encontramos los discos»** | Elegí la carpeta que contiene los archivos `.iso`. Si tenés el `.zip`, usá *Extraer el ZIP…*. |
| **«El archivo … no parece un disco válido»** | La imagen está dañada o incompleta. Volvé a descargarla o copiarla. |
| **«Carpeta no compatible» / «Ruta demasiado larga»** | Los juegos son de 1997: usá una carpeta corta y sin acentos ni símbolos, como `C:\Trampolin`. |
| **«No hay espacio suficiente»** | Liberá espacio, elegí otra unidad o usá la opción *Usar los discos (.iso)*. |
| **«Falta el disco del juego»** | Elegiste *usar los .iso* y moviste o borraste el archivo. Presioná *Buscar el archivo…* e indicá dónde está. |
| **«El juego se cerró al iniciar»** | Usá **Reparar**. Si sigue pasando, mirá la fila siguiente. |
| **«Un antivirus bloquea…» / «No se pudo iniciar»** | Para funcionar en Windows moderno, Trampolín Runtime agrega una pequeña capa de compatibilidad al juego (`trhook.dll`). Algunos antivirus la confunden con algo peligroso. Agregá la carpeta de instalación a las excepciones del antivirus. |
| **«Couldn't save data to file» al escribir el nombre** (Educación Infantil) | Está corregido desde la versión 1.0.1 de Trampolín Runtime: actualizá a esa versión o a una posterior. |
| **No se escucha la música** | Verificá el volumen de Windows y que haya un dispositivo de salida de audio activo. |
| **Ya hay un juego abierto** | Solo se puede jugar a uno por vez. Cerralo antes de abrir otro. |
| **Cualquier otro error** | En el mensaje de error presioná **Copiar informe** y envialo a quien te ayude con la computadora. El registro completo está en `<carpeta de instalación>\logs`. |

## 6. Desinstalar todo

1. En la biblioteca, desinstalá cada juego (*···* → *Desinstalar…*). Las partidas quedan guardadas en *Documentos\Trampolín - partidas*.
2. Borrá la carpeta de instalación (por defecto `%LOCALAPPDATA%\Trampolin`).
3. Borrá la carpeta del menú Inicio *Trampolín* si quedó vacía.

Trampolín Runtime **no** modifica el registro de Windows, la carpeta `C:\Windows` ni la configuración de pantalla.

## 7. Privacidad y aviso legal

- Todo funciona sin conexión a internet. No se envía ningún dato.
- Los juegos *Trampolín* son propiedad de sus respectivos titulares (Knowledge Adventure / Anaya). Trampolín Runtime **no incluye los juegos**: usa los discos que vos aportás.
- `WING32.DLL`, `trhook.dll` y `trlaunch.exe` son componentes propios de compatibilidad: reemplazan la biblioteca WinG de 1994 y adaptan los juegos al Windows actual (pantalla, sonido y archivos) sin modificar los juegos originales.
