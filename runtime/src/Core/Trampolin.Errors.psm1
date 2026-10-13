# Trampolin.Errors.psm1 — errores con mensajes amigables y log técnico.
# Compatible con Windows PowerShell 5.1.

Set-StrictMode -Version 2.0

if (-not ('TrampolinException' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
public class TrampolinException : Exception {
    public string Code { get; private set; }
    public Hashtable Data2 { get; private set; }
    public TrampolinException(string code, Hashtable data, Exception inner)
        : base(code, inner) { Code = code; Data2 = data ?? new Hashtable(); }
}
'@
}

$script:LogFile = $null
$script:Strings = $null

function Initialize-TrLog {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Force -Path $Directory | Out-Null }
    $script:LogFile = Join-Path $Directory ('trampolin-{0:yyyyMMdd}.log' -f (Get-Date))
    # Conservar solo los últimos 10 logs.
    Get-ChildItem -LiteralPath $Directory -Filter 'trampolin-*.log' | Sort-Object Name -Descending |
        Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-TrLog Info ("=== Trampolín Runtime — {0} — PowerShell {1} — {2}" -f (Get-Date -Format s), $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
}

function Get-TrLogFile { $script:LogFile }

function Write-TrLog {
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('Info', 'Warn', 'Error', 'Debug')][string]$Level,
        [Parameter(Mandatory, Position = 1)][string]$Message
    )
    if (-not $script:LogFile) { return }
    $line = '{0:HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Level.ToUpper(), $Message
    try {
        $sw = New-Object IO.StreamWriter($script:LogFile, $true, (New-Object Text.UTF8Encoding($false)))
        try { $sw.WriteLine($line) } finally { $sw.Dispose() }
    } catch { }
}

function Import-TrStrings {
    param([Parameter(Mandatory)][string]$Path)
    $script:Strings = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-TrError {
    <# Crea una excepción con código del catálogo. Uso: throw (New-TrError 'TR-ISO-002' @{ file = 'x.iso' }) #>
    param(
        [Parameter(Mandatory, Position = 0)][string]$Code,
        [Parameter(Position = 1)][hashtable]$Data = @{},
        [Parameter(Position = 2)][Exception]$Inner = $null
    )
    New-Object TrampolinException($Code, $Data, $Inner)
}

function Get-TrErrorInfo {
    <# Traduce cualquier error (ErrorRecord o Exception) a {Code, Title, Message, Actions, Details}. #>
    param([Parameter(Mandatory)]$ErrorObject)
    $ex = $ErrorObject
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) { $ex = $ErrorObject.Exception }
    # Desenvolver hasta encontrar una TrampolinException.
    $tr = $null; $cur = $ex
    while ($cur) {
        if ($cur -is [TrampolinException]) { $tr = $cur; break }
        $cur = $cur.InnerException
    }
    $code = 'TR-GEN-001'; $data = @{}
    if ($tr) { $code = $tr.Code; $data = $tr.Data2 }
    $entry = $null
    if ($script:Strings) { $entry = $script:Strings.errors.$code }
    if (-not $entry) { $code = 'TR-GEN-001'; if ($script:Strings) { $entry = $script:Strings.errors.'TR-GEN-001' } }
    $title = 'Error'; $message = "$ex"; $actions = @('details')
    if ($entry) {
        $title = $entry.title
        $message = $entry.message
        $actions = @($entry.actions)
        foreach ($k in $data.Keys) { $message = $message.Replace('{' + $k + '}', [string]$data[$k]) }
    }
    $details = New-Object Text.StringBuilder
    [void]$details.AppendLine("Código: $code")
    $cur = $ex
    while ($cur) {
        [void]$details.AppendLine(('{0}: {1}' -f $cur.GetType().FullName, $cur.Message))
        $cur = $cur.InnerException
    }
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord] -and $ErrorObject.ScriptStackTrace) {
        [void]$details.AppendLine($ErrorObject.ScriptStackTrace)
    }
    [pscustomobject]@{ Code = $code; Title = $title; Message = $message; Actions = $actions; Details = $details.ToString() }
}

function Get-TrActionLabel {
    param([Parameter(Mandatory)][string]$Action)
    if ($script:Strings -and $script:Strings.actions.$Action) { return $script:Strings.actions.$Action }
    $Action
}

function Invoke-TrStep {
    <#
      Ejecuta un paso con log, traduce excepciones al código indicado y ejecuta
      un rollback opcional. Las TrampolinException se propagan sin cambiar el código.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$ErrorCode = 'TR-GEN-001',
        [hashtable]$ErrorData = @{},
        [scriptblock]$Rollback = $null
    )
    Write-TrLog Info "INICIO $Name"
    try {
        $result = & $Action
        Write-TrLog Info "OK $Name"
        return $result
    } catch {
        $err = $_
        Write-TrLog Error ("FALLO {0} :: {1} :: {2}`n{3}" -f $Name, $err.Exception.GetType().FullName, $err.Exception.Message, $err.ScriptStackTrace)
        if ($Rollback) {
            try { & $Rollback; Write-TrLog Info "ROLLBACK $Name" } catch { Write-TrLog Error "ROLLBACK FALLÓ $Name :: $_" }
        }
        $inner = $err.Exception
        $c = $inner
        while ($c) {
            # La cancelación del usuario y los errores ya traducidos se propagan sin cambios.
            if ($c -is [TrampolinException] -or $c -is [OperationCanceledException]) { throw $c }
            $c = $c.InnerException
        }
        throw (New-TrError $ErrorCode $ErrorData $inner)
    }
}

function Get-TrReport {
    <# Texto para "Copiar informe": resumen del error + últimas líneas del log. #>
    param($Info)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('Informe de Trampolín Runtime')
    [void]$sb.AppendLine(('Fecha: {0:s}  Windows: {1}' -f (Get-Date), [Environment]::OSVersion.VersionString))
    if ($Info) {
        [void]$sb.AppendLine(('Error: {0} — {1}' -f $Info.Code, $Info.Message))
        [void]$sb.AppendLine($Info.Details)
    }
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        [void]$sb.AppendLine('--- Últimas líneas del log ---')
        Get-Content -LiteralPath $script:LogFile -Tail 200 -Encoding UTF8 | ForEach-Object { [void]$sb.AppendLine($_) }
    }
    $sb.ToString()
}

Export-ModuleMember -Function Initialize-TrLog, Get-TrLogFile, Write-TrLog, Import-TrStrings, New-TrError, Get-TrErrorInfo,
    Get-TrActionLabel, Invoke-TrStep, Get-TrReport
