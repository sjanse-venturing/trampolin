@echo off
rem Trampolin Remaster - doble clic para preparar (la primera vez) y abrir la aplicacion.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0scripts\run.ps1" %*
