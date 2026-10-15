<#
  Empaqueta Trampolín Runtime para distribuir.

  Uso:
    powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 [-SkipNative] [-SkipTests] [-IsoFolder <carpeta>]

  Pasos: compila los componentes nativos (MSVC x86), normaliza la codificación de
  los scripts (UTF-8 con BOM para Windows PowerShell 5.1), verifica la sintaxis,
  ejecuta las pruebas y genera dist\TrampolinRuntime-<versión>.zip.

  El mismo ZIP sirve para Windows (Trampolin.cmd) y para Linux / Steam Deck
  (trampolin.sh + linux\). Desde Linux, build.sh arma el mismo paquete y además
  conserva el permiso de ejecución de trampolin.sh.
#>
param([switch]$SkipNative, [switch]$SkipTests, [string]$IsoFolder, [string]$Version = '1.0.0')

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
function Step([string]$t) { Write-Host "==> $t" -ForegroundColor Cyan }

if (-not $SkipNative) {
    Step 'Compilando componentes nativos (x86)'
    & cmd.exe /c (Join-Path $here 'native\build.cmd')
    if ($LASTEXITCODE -ne 0) { throw "La compilación nativa falló (código $LASTEXITCODE). ¿Están instaladas las Build Tools de Visual Studio con C++?" }
}
foreach ($f in 'trlaunch.exe', 'trhook.dll', 'WING32.DLL') {
    if (-not (Test-Path (Join-Path $here "native\bin\$f"))) { throw "Falta native\bin\$f. Ejecutá build.ps1 sin -SkipNative." }
}

Step 'Normalizando codificación (UTF-8 con BOM)'
Get-ChildItem (Join-Path $here 'src'), (Join-Path $here 'tests') -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
        [IO.File]::WriteAllBytes($_.FullName, [byte[]](0xEF, 0xBB, 0xBF) + $b)
        Write-Host "   BOM agregado: $($_.Name)"
    }
}

Step 'Verificando sintaxis'
$bad = 0
Get-ChildItem (Join-Path $here 'src'), (Join-Path $here 'tests') -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in @($errors)) { if ($e) { Write-Host ("   {0}:{1} {2}" -f $_.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red; $bad++ } }
}
if ($bad) { throw "Hay $bad errores de sintaxis." }

if (-not $SkipTests) {
    Step 'Ejecutando pruebas (Windows PowerShell 5.1)'
    $testArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'tests\Run-Tests.ps1'))
    if ($IsoFolder) { $testArgs += @('-IsoFolder', $IsoFolder) }
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @testArgs
    if ($LASTEXITCODE -ne 0) { throw 'Las pruebas fallaron.' }
}

Step 'Armando el paquete'
$dist = Join-Path $here 'dist'
$name = "TrampolinRuntime-$Version"
$stage = Join-Path $dist $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'native\bin') | Out-Null
Copy-Item (Join-Path $here 'src') $stage -Recurse
Copy-Item (Join-Path $here 'native\bin\*') (Join-Path $stage 'native\bin')
Copy-Item (Join-Path $here 'linux') $stage -Recurse
Get-ChildItem (Join-Path $stage 'linux') -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
Copy-Item (Join-Path $here 'Trampolin.cmd'), (Join-Path $here 'trampolin.sh'), (Join-Path $here 'LEEME-RUNTIME.md') $stage
$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, 'Optimal', $true)
Step ("Listo: {0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
