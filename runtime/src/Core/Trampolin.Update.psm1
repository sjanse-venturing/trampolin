# Trampolin.Update.psm1 — actualizaciones automáticas desde las versiones publicadas en GitHub.
# Compatible con Windows PowerShell 5.1. Refleja linux/trampolin/update.py: mismas reglas
# (data\update.json), mismo paquete (el ZIP de build.ps1 / build.sh) y misma verificación
# (el SHA-256 publicado junto al ZIP).
#
#   Consulta:  GET latestUrl (la última versión publicada; GitHub no incluye borradores ni versiones
#              de prueba). Se anota en update-state.json y no se repite antes de minCheckMinutes.
#   Instalar:  descarga el ZIP y su .sha256, los verifica, descomprime en una carpeta temporal y copia
#              el programa en <instalación>\app. Los juegos y las partidas no se tocan.
#
# Solo se actualiza la copia instalada (<instalación>\app, la que abren los accesos directos y Steam):
# una copia descomprimida o el repositorio no consultan nada.

Set-StrictMode -Version 2.0

$script:SrcRoot = Split-Path -Parent $PSScriptRoot
$script:StateFile = Join-Path (Join-Path $env:LOCALAPPDATA 'Trampolin') 'update-state.json'
$script:Settings = $null
# Lo mínimo que tiene que traer un paquete para poder reemplazar la instalación.
$script:Required = @('VERSION', 'trampolin.sh', 'Trampolin.cmd', 'linux/main.py', 'src/Trampolin.ps1', 'src/data/games.json',
    'native/bin/trlaunch.exe', 'native/bin/trhook.dll', 'native/bin/WING32.DLL')
$script:DefaultTransport = { param($Method, $Url, $Headers, $Body, $Timeout) Invoke-TrHttp -Method $Method -Url $Url -Headers $Headers -Body $Body -Timeout $Timeout }

function Get-TrUpdateSettings {
    if (-not $script:Settings) { $script:Settings = ConvertFrom-TrJsonStrict ([IO.File]::ReadAllText((Join-Path $script:SrcRoot 'data\update.json'), [Text.Encoding]::UTF8)) }
    $script:Settings
}

function Set-TrUpdateStateFile { param([string]$Path) $script:StateFile = $Path }    # para las pruebas

function Get-TrLatestUrl {
    $s = Get-TrUpdateSettings
    if ($env:TRAMPOLIN_UPDATE_URL) { return $env:TRAMPOLIN_UPDATE_URL }
    $s.latestUrl.Replace('{repo}', $s.repo)
}

function ConvertTo-TrVersion {
    <# 'v1.2' o '1.2.0' → [version] 1.2.0; $null si no es una versión. #>
    param([string]$Text)
    if ("$Text" -match '^\s*v?(\d+)\.(\d+)(?:\.(\d+))?\s*$') {
        $patch = $(if ($Matches[3]) { $Matches[3] } else { '0' })
        return [version]"$($Matches[1]).$($Matches[2]).$patch"
    }
    $null
}

function ConvertFrom-TrReleaseJson {
    <# Respuesta de la API de GitHub → @{ Version; Notes; ZipUrl; ShaUrl; Page }, o $null si no es una versión utilizable. #>
    param([string]$Text)
    try { $d = ConvertFrom-TrJsonStrict $Text } catch { return $null }
    if (-not ($d -is [Collections.IDictionary]) -or $d['draft'] -eq $true -or $d['prerelease'] -eq $true) { return $null }
    $v = ConvertTo-TrVersion ([string]$d['tag_name'])
    if (-not $v) { return $null }
    $s = Get-TrUpdateSettings
    $vs = $v.ToString(3)
    $assets = @{}
    foreach ($a in @($d['assets'])) { if ($a -is [Collections.IDictionary] -and $a['name']) { $assets[[string]$a['name']] = [string]$a['browser_download_url'] } }
    $zip = $assets[$s.asset.Replace('{version}', $vs)]
    $sha = $assets[$s.checksum.Replace('{version}', $vs)]
    if (-not $zip -or -not $sha) { return $null }     # versión sin paquete (o todavía subiéndose)
    $notes = [string]$d['body']
    if ($notes.Length -gt 20000) { $notes = $notes.Substring(0, 20000) }
    @{ Version = $vs; Notes = $notes; ZipUrl = $zip; ShaUrl = $sha; Page = [string]$d['html_url'] }
}

function ConvertTo-TrRelease {
    param($Value)
    if (-not ($Value -is [Collections.IDictionary]) -or -not (ConvertTo-TrVersion ([string]$Value['Version'])) -or -not $Value['ZipUrl'] -or -not $Value['ShaUrl']) { return $null }
    @{ Version = [string]$Value['Version']; Notes = [string]$Value['Notes']; ZipUrl = [string]$Value['ZipUrl']; ShaUrl = [string]$Value['ShaUrl']; Page = [string]$Value['Page'] }
}

function Get-TrLatestRelease {
    <#
      Última versión publicada. Consulta GitHub como mucho cada minCheckMinutes; sin red, devuelve la
      última conocida. $null si no hay ninguna (o están desactivadas).
    #>
    param([switch]$Force, $Now = $null, [scriptblock]$Transport = $script:DefaultTransport)
    if ($env:TRAMPOLIN_NO_UPDATE) { return $null }
    $s = Get-TrUpdateSettings
    $nowUtc = $(if ($Now) { ([DateTime]$Now).ToUniversalTime() } else { [DateTime]::UtcNow })
    $st = @{}
    if (Test-Path -LiteralPath $script:StateFile) {
        try { $st = ConvertFrom-TrJsonStrict ([IO.File]::ReadAllText($script:StateFile, [Text.Encoding]::UTF8)) } catch { Write-TrLog Warn "update-state.json ilegible: $_" }
        if (-not ($st -is [Collections.IDictionary])) { $st = @{} }
    }
    $cached = ConvertTo-TrRelease $st['latest']
    $last = [DateTime]::MinValue
    $hasLast = [DateTime]::TryParseExact([string]$st['checkedAt'], "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$last)
    if (-not $Force -and $hasLast) {
        $age = $nowUtc - $last
        if ($age -ge [TimeSpan]::Zero -and $age -lt [TimeSpan]::FromMinutes([double]$s.minCheckMinutes)) { return $cached }
    }
    try {
        $r = & $Transport 'GET' (Get-TrLatestUrl) @{ 'User-Agent' = 'TrampolinRuntime'; 'Accept' = 'application/vnd.github+json' } $null ([int]$s.timeoutSeconds)
    } catch {
        Write-TrLog Info "No se pudo consultar si hay actualizaciones: $($_.Exception.Message)"
        return $cached
    }
    if ($r.Status -eq 200) { $rel = ConvertFrom-TrReleaseJson ([Text.Encoding]::UTF8.GetString($r.Body)) }
    elseif ($r.Status -eq 404) { $rel = $null }        # todavía no hay versiones publicadas
    else {
        Write-TrLog Warn "No se pudo consultar si hay actualizaciones: HTTP $($r.Status)"
        return $cached
    }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:StateFile) | Out-Null
        $tmp = "$($script:StateFile).tmp"
        $state = @{ checkedAt = $nowUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture); latest = $rel }
        [IO.File]::WriteAllText($tmp, (ConvertTo-TrJsonText $state), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:StateFile -Force
    } catch { Write-TrLog Warn "No se pudo guardar update-state.json: $_" }
    $rel
}

function Get-TrPendingUpdate {
    <# La versión publicada, si esta copia es la instalada en <Root>\app y la publicada es más nueva; si no, $null. #>
    param([Parameter(Mandatory)][string]$Root, [scriptblock]$Transport = $script:DefaultTransport, [string]$AppRoot = (Get-TrAppRoot))
    if (-not (Test-TrSamePath $AppRoot (Join-Path $Root 'app'))) { return $null }
    $rel = Get-TrLatestRelease -Transport $Transport
    if (-not $rel) { return $null }
    $current = Get-TrRuntimeVersion -AppRoot $AppRoot
    if (-not $current -or (ConvertTo-TrVersion $rel.Version) -gt $current) { return $rel }
    $null
}

function Expand-TrUpdatePackage {
    <#
      Valida el paquete (carpeta TrampolinRuntime-<versión>/, sin rutas raras, con los archivos
      necesarios y la versión correcta) y lo descomprime en $Destination. Devuelve la carpeta del programa.
    #>
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $prefix = "TrampolinRuntime-$Version/"
    $bad = { param($reason) New-TrError 'TR-UPD-002' @{ version = $Version; reason = $reason } }
    try { $z = [IO.Compression.ZipFile]::OpenRead($ZipPath) } catch { throw (& $bad 'no es un ZIP válido') }
    try {
        $names = @{}; $total = [long]0
        foreach ($e in $z.Entries) {
            $n = $e.FullName
            if (-not $n.StartsWith($prefix, [StringComparison]::Ordinal)) { throw (& $bad 'tiene archivos fuera de la carpeta del programa') }
            $rel = $n.Substring($prefix.Length)
            if ($rel -and ($n.Contains('\') -or $rel.Contains(':') -or @($rel.TrimEnd('/').Split('/') | Where-Object { $_ -in '', '.', '..' }).Count)) {
                throw (& $bad 'tiene rutas no permitidas')
            }
            if ((($e.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw (& $bad 'tiene enlaces simbólicos') }
            $total += $e.Length
            if ($rel -and -not $rel.EndsWith('/')) { $names[$rel] = $e }
        }
        if ($total -gt 4 * [long](Get-TrUpdateSettings).maxZipBytes) { throw (& $bad 'es demasiado grande') }
        $missing = @($script:Required | Where-Object { -not $names.ContainsKey($_) })
        if ($missing.Count) { throw (& $bad "le faltan archivos: $($missing -join ', ')") }
        $reader = New-Object IO.StreamReader($names['VERSION'].Open(), [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        if ((ConvertTo-TrVersion $text) -ne (ConvertTo-TrVersion $Version)) { throw (& $bad 'la versión del paquete no coincide') }
    } finally { $z.Dispose() }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
    Join-Path $Destination "TrampolinRuntime-$Version"
}

function Install-TrUpdate {
    <#
      Descarga, verifica e instala una versión en <Root>\app. Devuelve la versión instalada.
      $OnProgress recibe (porcentaje, texto); $Cancel es el hashtable de Start-TrBackground.
    #>
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)][string]$Root, [scriptblock]$OnProgress, $Cancel,
        [scriptblock]$Transport = $script:DefaultTransport)
    $s = Get-TrUpdateSettings
    $v = [string]$Release.Version
    $progress = { param($p, $m) if ($OnProgress) { & $OnProgress $p $m } }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('trampolin-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        & $progress 5 "Descargando Trampolín $v…"
        $headers = @{ 'User-Agent' = 'TrampolinRuntime' }
        try {
            $sha = & $Transport 'GET' $Release.ShaUrl $headers $null ([int]$s.timeoutSeconds)
            if ($sha.Status -ne 200) { throw "HTTP $($sha.Status) al descargar la suma de verificación" }
            if ($Cancel -and $Cancel.Cancel) { throw (New-Object OperationCanceledException) }
            $zip = & $Transport 'GET' $Release.ZipUrl $headers $null ([int]$s.downloadTimeoutSeconds)
            if ($zip.Status -ne 200) { throw "HTTP $($zip.Status) al descargar el paquete" }
        } catch {
            if ($_.Exception -is [OperationCanceledException]) { throw }
            $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
            throw (New-TrError 'TR-UPD-001' @{ version = $v; detail = $e.Message } $_.Exception)
        }
        if ($zip.Body.Length -gt [long]$s.maxZipBytes) { throw (New-TrError 'TR-UPD-002' @{ version = $v; reason = 'es demasiado grande' }) }
        & $progress 85 'Verificando…'
        $shaText = [Text.Encoding]::ASCII.GetString($sha.Body)
        if ($shaText -notmatch '^\s*([0-9a-fA-F]{64})\b') { throw (New-TrError 'TR-UPD-002' @{ version = $v; reason = 'no se publicó la suma de verificación' }) }
        if ((Get-TrSha256 $zip.Body) -ne $Matches[1].ToLowerInvariant()) { throw (New-TrError 'TR-UPD-002' @{ version = $v; reason = 'la suma de verificación no coincide' }) }
        $zipPath = Join-Path $work 'paquete.zip'
        [IO.File]::WriteAllBytes($zipPath, $zip.Body)
        $src = Expand-TrUpdatePackage -ZipPath $zipPath -Version $v -Destination (Join-Path $work 'x')
        if ($Cancel -and $Cancel.Cancel) { throw (New-Object OperationCanceledException) }
        & $progress 92 'Instalando…'
        $app = Join-Path $Root 'app'
        try { Install-TrRuntimeFiles -Root $Root -Source $src | Out-Null }
        catch { throw (New-TrError 'TR-UPD-003' @{ version = $v; path = $app; detail = $_.Exception.Message } $_.Exception) }
        Write-TrLog Info "Trampolín actualizado a $v en $app"
        & $progress 100 'Listo'
        $v
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-TrUpdateSettings, Set-TrUpdateStateFile, ConvertTo-TrVersion, ConvertFrom-TrReleaseJson, Get-TrLatestRelease,
    Get-TrPendingUpdate, Expand-TrUpdatePackage, Install-TrUpdate
