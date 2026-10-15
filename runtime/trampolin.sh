#!/bin/sh
# Trampolín Runtime para Linux / Steam Deck — abre la biblioteca (o el asistente si no hay nada instalado).
#   trampolin.sh                 biblioteca / asistente
#   trampolin.sh --install       asistente de instalación
#   trampolin.sh --play <ID>     lanza un juego (lo usan los accesos de Steam y del menú)
#   trampolin.sh cli --help      comandos sin interfaz gráfica
here=$(dirname "$(readlink -f "$0")")
if [ ! -f "$here/linux/main.py" ]; then
  echo "No se encontraron los archivos del programa. Descomprimí el ZIP completo antes de ejecutar." >&2
  exit 1
fi
# Steam ejecuta los accesos no-Steam con sus bibliotecas; Python del sistema no las necesita.
unset LD_PRELOAD LD_LIBRARY_PATH PYTHONHOME PYTHONPATH
exec /usr/bin/env python3 -I "$here/linux/main.py" "$@"
