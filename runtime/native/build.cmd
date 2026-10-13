@echo off
rem Compila los componentes nativos (x86) de Trampolin Runtime con MSVC.
rem Uso: build.cmd            (salida en runtime\native\bin)
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
set "OUT=%HERE%bin"
set "OBJ=%HERE%obj"

if not defined VSCMD_ARG_TGT_ARCH (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" (
    echo [ERROR] No se encontro Visual Studio / Build Tools. Instale "Desktop development with C++".
    exit /b 2
  )
  for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%i"
  if not defined VSINSTALL (
    echo [ERROR] No se encontro el compilador de C++ ^(componente VC.Tools.x86.x64^).
    exit /b 2
  )
  call "!VSINSTALL!\VC\Auxiliary\Build\vcvarsall.bat" x86 >nul || (echo [ERROR] vcvarsall fallo & exit /b 2)
)
if /i not "%VSCMD_ARG_TGT_ARCH%"=="x86" (
  echo [ERROR] El entorno de compilacion no es x86 ^(es %VSCMD_ARG_TGT_ARCH%^).
  exit /b 2
)

if not exist "%OUT%" mkdir "%OUT%"
if not exist "%OBJ%" mkdir "%OBJ%"
set "CFLAGS=/nologo /utf-8 /O2 /W3 /MT /GS- /D_CRT_SECURE_NO_WARNINGS /Fo%OBJ%\\"

echo === WING32.DLL
cl %CFLAGS% /LD "%HERE%wing32\wing32.c" /Fe"%OUT%\WING32.DLL" /link /DEF:"%HERE%wing32\wing32.def" gdi32.lib user32.lib kernel32.lib || exit /b 1

echo === trhook.dll
cl %CFLAGS% /LD "%HERE%trhook\trhook.c" /Fe"%OUT%\trhook.dll" /link /DEF:"%HERE%trhook\trhook.def" gdi32.lib user32.lib kernel32.lib shell32.lib winmm.lib || exit /b 1

echo === trlaunch.exe
cl %CFLAGS% "%HERE%trlaunch\trlaunch.c" /Fe"%OUT%\trlaunch.exe" /link /SUBSYSTEM:WINDOWS user32.lib kernel32.lib || exit /b 1

del /q "%OUT%\*.exp" "%OUT%\*.lib" 2>nul
echo OK: binarios en %OUT%
exit /b 0
