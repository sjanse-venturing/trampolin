<#
  Prepara (la primera vez) y abre Trampolín Remaster desde el código fuente.
  Lo invoca Trampolin-Remaster.cmd. Muestra una ventana de progreso y, ante
  cualquier problema, un mensaje claro en español con el registro técnico.

  Pasos: verificar Node.js → instalar dependencias (npm) → asegurar Electron →
  compilar si hay cambios → abrir la aplicación.
#>
param([switch]$Rebuild)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ('setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
function Log([string]$m) { Add-Content -LiteralPath $log -Value ('{0:HH:mm:ss} {1}' -f (Get-Date), $m) -Encoding UTF8 }

# --- Ventana de progreso -----------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Trampolín Remaster'; $form.Size = New-Object System.Drawing.Size(480, 170)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(251, 247, 239)
$title = New-Object System.Windows.Forms.Label
$title.Text = 'Preparando Trampolín Remaster…'; $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$title.AutoSize = $true; $title.Location = New-Object System.Drawing.Point(20, 18)
$status = New-Object System.Windows.Forms.Label
$status.Text = ''; $status.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$status.Size = New-Object System.Drawing.Size(430, 22); $status.Location = New-Object System.Drawing.Point(22, 52)
$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Style = 'Marquee'; $bar.MarqueeAnimationSpeed = 30
$bar.Size = New-Object System.Drawing.Size(430, 18); $bar.Location = New-Object System.Drawing.Point(22, 82)
$form.Controls.AddRange(@($title, $status, $bar))

function Set-Status([string]$t) { $status.Text = $t; Log $t; [System.Windows.Forms.Application]::DoEvents() }

function Show-Problem([string]$message, [string]$titleText = 'No se pudo abrir Trampolín Remaster') {
    Log "ERROR: $message"
    $form.Hide()
    [void][System.Windows.Forms.MessageBox]::Show("$message`r`n`r`nDetalle técnico guardado en:`r`n$log", $titleText, 'OK', 'Warning')
    exit 1
}

function Invoke-Step([string]$exe, [string[]]$arguments, [string]$what, [string]$friendly = '') {
    # Ejecuta un proceso sin congelar la ventana y guarda su salida en el registro.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    Log "> $exe $($psi.Arguments)"
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    Log $out.Result; Log $err.Result
    if ($p.ExitCode -ne 0) { Show-Problem $(if ($friendly) { $friendly } else { "Falló el paso: $what (código $($p.ExitCode))." }) }
}

$form.Show()
Set-Status 'Verificando Node.js…'

# --- 1. Node.js -----------------------------------------------------------------
$node = Get-Command node.exe -ErrorAction SilentlyContinue
$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
$nodeOk = $false
if ($node -and $npm) {
    $ver = (& $node.Source --version) -replace '^v', ''
    Log "Node.js $ver"
    $nodeOk = [int]($ver.Split('.')[0]) -ge 20
}
if (-not $nodeOk) {
    $form.Hide()
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    $msg = 'Para ejecutar Trampolín Remaster desde el código fuente hace falta Node.js 20 o superior (es gratuito).'
    if ($winget) {
        $r = [System.Windows.Forms.MessageBox]::Show("$msg`r`n`r`n¿Querés instalarlo ahora? Al terminar, volvé a abrir Trampolin-Remaster.cmd.", 'Falta Node.js', 'YesNo', 'Question')
        if ($r -eq 'Yes') {
            Start-Process -FilePath $winget.Source -ArgumentList 'install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements' -Wait
            [void][System.Windows.Forms.MessageBox]::Show('Listo. Cerrá esta ventana y volvé a abrir Trampolin-Remaster.cmd.', 'Node.js instalado', 'OK', 'Information')
        }
    } else {
        [void][System.Windows.Forms.MessageBox]::Show("$msg`r`n`r`nSe abrirá la página de descarga. Instalá la versión LTS y volvé a abrir Trampolin-Remaster.cmd.", 'Falta Node.js', 'OK', 'Information')
        Start-Process 'https://nodejs.org/es/download'
    }
    exit 1
}

# --- 2. Dependencias -----------------------------------------------------------
$lockMarker = Join-Path $root 'node_modules\.package-lock.json'
$needInstall = -not (Test-Path $lockMarker) -or ((Get-Item (Join-Path $root 'package.json')).LastWriteTime -gt (Get-Item $lockMarker).LastWriteTime)
if ($needInstall) {
    Set-Status 'Descargando componentes (solo la primera vez, puede tardar unos minutos)…'
    $useCi = Test-Path (Join-Path $root 'package-lock.json')
    Invoke-Step $npm.Source @($(if ($useCi) { 'ci' } else { 'install' }), '--no-audit', '--no-fund') 'instalar los componentes' 'No pudimos descargar los componentes necesarios. Revisá tu conexión a internet y volvé a intentar.'
}

# --- 3. Electron (algunas versiones de npm no ejecutan su instalador) ---------
$electron = Join-Path $root 'node_modules\electron\dist\electron.exe'
if (-not (Test-Path $electron)) {
    Set-Status 'Descargando el motor de la aplicación (Electron)…'
    Invoke-Step $node.Source @('node_modules/electron/install.js') 'descargar Electron'
    if (-not (Test-Path $electron)) { Show-Problem 'No se pudo descargar Electron. Revisá tu conexión a internet y volvé a intentar.' }
}

# --- 4. Compilar si hay cambios ------------------------------------------------
$mainJs = Join-Path $root 'dist\main\main.js'
$newest = Get-ChildItem (Join-Path $root 'src') -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($Rebuild -or -not (Test-Path $mainJs) -or $newest.LastWriteTime -gt (Get-Item $mainJs).LastWriteTime) {
    Set-Status 'Preparando la aplicación…'
    Invoke-Step $npm.Source @('run', 'build') 'compilar la aplicación'
}

# --- 5. Abrir ------------------------------------------------------------------
Set-Status 'Abriendo…'
Start-Process -FilePath $electron -ArgumentList '.' -WorkingDirectory $root
Log 'Aplicación iniciada.'
Start-Sleep -Milliseconds 800
$form.Close()
