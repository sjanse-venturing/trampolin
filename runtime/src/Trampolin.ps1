# Trampolin.ps1 — punto de entrada de Trampolín Runtime.
#
#   Trampolin.ps1                 abre la biblioteca (o el asistente si no hay nada instalado)
#   Trampolin.ps1 --install       abre el asistente de instalación
#   Trampolin.ps1 --play <ID>     lanza un juego directamente (lo usan los accesos directos)
#
# Requiere Windows PowerShell 5.1 en modo STA (Trampolin.cmd ya lo invoca así).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# WinForms necesita STA: si no lo estamos, nos relanzamos.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath)) + $args
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argList
    return
}

$here = $PSScriptRoot
try {
    Import-Module (Join-Path $here 'Core\Trampolin.Errors.psm1') -Force
    Import-Module (Join-Path $here 'Core\Trampolin.Core.psm1') -Force
    . (Join-Path $here 'UI\Theme.ps1')
    . (Join-Path $here 'UI\Dialogs.ps1')
    . (Join-Path $here 'UI\Wizard.ps1')
    . (Join-Path $here 'UI\Launcher.ps1')
    Import-TrStrings (Join-Path $here 'data\strings.es.json')
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "Faltan archivos de Trampolín Runtime o están dañados. Volvé a descomprimir el programa completo.`r`n`r`nDetalle: $($_.Exception.Message)",
        'Trampolín', 'OK', 'Error')
    exit 1
}

# Argumentos
$mode = 'auto'; $playId = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ($args[$i]) {
        '^--?play$' { $mode = 'play'; $playId = $args[$i + 1]; $i++ }
        '^--?install$' { $mode = 'install' }
    }
}

$config = Get-TrConfig
$logRoot = $(if ($config.installRoot) { Join-Path $config.installRoot 'logs' } else { Join-Path $env:LOCALAPPDATA 'Trampolin\logs' })
Initialize-TrLog $logRoot

# Último recurso: cualquier error no previsto se muestra amigablemente.
trap {
    Write-TrLog Error "Error no controlado: $_`n$($_.ScriptStackTrace)"
    try { [void](Show-TrError $_) } catch { }
    exit 1
}

function Invoke-TrPlay {
    param([string]$Id)
    $cfg = Get-TrConfig
    if (-not $cfg.installRoot) { throw (New-TrError 'TR-RUN-006' @{ game = $Id }) }
    $session = $null
    try {
        $session = Start-TrGame -Id $Id -Root $cfg.installRoot -Scale ([int]$cfg.scale)
    } catch {
        $action = Show-TrError $_
        if ($action -in @('locate', 'repair')) { Invoke-TrMain -Mode 'auto' }
        return
    }
    $diag = Complete-TrGame -Session $session
    if ($diag) {
        $action = Show-TrError (Get-TrErrorInfo $diag)
        if ($action -eq 'repair') { Invoke-TrMain -Mode 'auto' }
    }
}

function Invoke-TrMain {
    param([string]$Mode)
    $openWizard = ($Mode -eq 'install')
    while ($true) {
        $cfg = Get-TrConfig
        $hasGames = $cfg.installRoot -and @(Get-TrInstalledGames -Root $cfg.installRoot).Count -gt 0
        if ($openWizard -or -not $hasGames) {
            $installed = Show-TrWizard -Config $cfg
            $openWizard = $false
            $cfg = Get-TrConfig
            $hasGames = $cfg.installRoot -and @(Get-TrInstalledGames -Root $cfg.installRoot).Count -gt 0
            if (-not $hasGames) { return }
            if ($cfg.installRoot) { Initialize-TrLog (Join-Path $cfg.installRoot 'logs') }
        }
        $r = Show-TrLauncher -Config $cfg
        if ($r -ne 'wizard') { return }
        $openWizard = $true
    }
}

switch ($mode) {
    'play' { Invoke-TrPlay -Id $playId }
    default { Invoke-TrMain -Mode $mode }
}
