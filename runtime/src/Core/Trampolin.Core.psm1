# Trampolin.Core.psm1 — lógica de Trampolín Runtime (sin interfaz gráfica).
# Compatible con Windows PowerShell 5.1.

Set-StrictMode -Version 2.0

$script:SrcRoot = Split-Path -Parent $PSScriptRoot           # ...\src
$script:AppRoot = Split-Path -Parent $script:SrcRoot          # ...\runtime  (o <instalación>\app)
$script:ConfigDir = Join-Path $env:LOCALAPPDATA 'Trampolin'
$script:ConfigFile = Join-Path $script:ConfigDir 'config.json'
$script:Catalog = $null
$script:MaxRootLength = 80   # el motor KA-MFC guarda HDPath en un buffer de 128 bytes

if (-not ('TrIso' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'TrIso.cs') }
if (-not ('TrNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TrNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DefineDosDevice(int flags, string device, string target);
    [DllImport("kernel32.dll")]
    public static extern int GetACP();
}
'@
}

# ---------------------------------------------------------------------------
# Rutas y configuración
# ---------------------------------------------------------------------------

function Get-TrAppRoot { $script:AppRoot }

function Get-TrNativeBin {
    $candidates = @((Join-Path $script:AppRoot 'native\bin'), (Join-Path $script:AppRoot 'bin'))
    foreach ($c in $candidates) { if (Test-Path -LiteralPath (Join-Path $c 'trlaunch.exe')) { return $c } }
    $candidates[0]
}

function Get-TrCatalog {
    if (-not $script:Catalog) {
        $json = Get-Content -LiteralPath (Join-Path $script:SrcRoot 'data\games.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Catalog = @($json.games | Sort-Object order)
    }
    $script:Catalog
}

function Get-TrGame {
    param([Parameter(Mandatory)][string]$Id)
    $g = Get-TrCatalog | Where-Object { $_.id -eq $Id }
    if (-not $g) { throw "Juego desconocido: $Id" }
    $g
}

function ConvertTo-TrHashtable {
    # ConvertFrom-Json en PS 5.1 devuelve PSCustomObject; esto lo pasa a hashtable (recursivo).
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-TrHashtable $p.Value }
        return $h
    }
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        return @($Object | ForEach-Object { ConvertTo-TrHashtable $_ })
    }
    $Object
}

function Read-TrJson {
    param([Parameter(Mandatory)][string]$Path, $Default)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try { return ConvertTo-TrHashtable (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-TrLog Warn "JSON ilegible ($Path): $_"; return $Default }
}

function Write-TrJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-TrConfig {
    $cfg = Read-TrJson -Path $script:ConfigFile -Default $null
    if (-not $cfg) {
        $cfg = [ordered]@{ installRoot = $null; isoFolder = $null; dataMode = 'copy'; scale = 0; desktopShortcuts = $true }
    }
    foreach ($k in @('installRoot', 'isoFolder', 'dataMode', 'scale', 'desktopShortcuts')) {
        if (-not $cfg.Contains($k)) { $cfg[$k] = $null }
    }
    if (-not $cfg.dataMode) { $cfg.dataMode = 'copy' }
    if ($null -eq $cfg.scale) { $cfg.scale = 0 }
    if ($null -eq $cfg.desktopShortcuts) { $cfg.desktopShortcuts = $true }
    $cfg
}

function Save-TrConfig { param([Parameter(Mandatory)]$Config) Write-TrJson -Path $script:ConfigFile -Value $Config }

function Get-TrDefaultInstallRoot { Join-Path $env:LOCALAPPDATA 'Trampolin' }

function Get-TrManifest {
    param([Parameter(Mandatory)][string]$Root)
    $m = Read-TrJson -Path (Join-Path $Root 'manifest.json') -Default $null
    if (-not $m) { $m = [ordered]@{ version = 1; games = [ordered]@{} } }
    if (-not $m.games) { $m.games = [ordered]@{} }
    $m
}

function Save-TrManifest {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Manifest)
    Write-TrJson -Path (Join-Path $Root 'manifest.json') -Value $Manifest
}

# ---------------------------------------------------------------------------
# Requisitos previos
# ---------------------------------------------------------------------------

function Test-TrPrerequisites {
    $items = New-Object Collections.Generic.List[object]
    $os = [Environment]::OSVersion.Version
    $is64 = [Environment]::Is64BitOperatingSystem
    $items.Add([pscustomobject]@{ Name = 'Windows 10/11 de 64 bits'; Ok = ($os.Major -ge 10 -and $is64); Blocking = $true
        Detail = ('Windows {0} ({1})' -f $os, $(if ($is64) { '64 bits' } else { '32 bits' })) })
    $items.Add([pscustomobject]@{ Name = 'Windows PowerShell 5.1 o superior'; Ok = ($PSVersionTable.PSVersion.Major -ge 5); Blocking = $true
        Detail = "PowerShell $($PSVersionTable.PSVersion)" })
    $bin = Get-TrNativeBin
    $missing = @('trlaunch.exe', 'trhook.dll', 'WING32.DLL') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bin $_)) }
    $items.Add([pscustomobject]@{ Name = 'Componentes de compatibilidad'; Ok = (@($missing).Count -eq 0); Blocking = $true
        Detail = $(if (@($missing).Count) { 'Faltan: ' + ($missing -join ', ') } else { $bin }) })
    $mount = [bool](Get-Command Mount-DiskImage -ErrorAction SilentlyContinue)
    $items.Add([pscustomobject]@{ Name = 'Montaje de imágenes de disco'; Ok = $mount; Blocking = $false
        Detail = $(if ($mount) { 'Disponible' } else { 'No disponible: se usará el modo "Copiar al disco"' }) })
    $items
}

# ---------------------------------------------------------------------------
# Discos (ISO)
# ---------------------------------------------------------------------------

function Find-TrIsos {
    <# Busca imágenes de los juegos en una carpeta (y un nivel de subcarpetas). #>
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) { throw (New-TrError 'TR-ISO-001' @{ path = $Folder }) }
    $catalog = Get-TrCatalog
    $files = @(Get-ChildItem -LiteralPath $Folder -Filter '*.iso' -File -ErrorAction SilentlyContinue)
    $files += @(Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.iso' -File -ErrorAction SilentlyContinue })
    $result = New-Object Collections.Generic.List[object]
    foreach ($f in $files) {
        $game = $catalog | Where-Object { $_.iso.size -eq $f.Length } | Select-Object -First 1
        if (-not $game) { $game = $catalog | Where-Object { $_.iso.file -eq $f.Name } | Select-Object -First 1 }
        $entry = [ordered]@{ GameId = $null; Path = $f.FullName; Name = $f.Name; Size = $f.Length; Label = $null; Status = 'unknown'; Message = '' }
        try {
            $iso = New-Object TrIso($f.FullName)
            try {
                $entry.Label = $iso.VolumeLabel
                if (-not $game) {
                    foreach ($g in $catalog) { if ($iso.Find($g.iso.keyFile)) { $game = $g; break } }
                }
                if ($game) {
                    $entry.GameId = $game.id
                    if ($iso.Find($game.iso.keyFile)) {
                        $entry.Status = 'ok'
                        if ($f.Length -ne $game.iso.size) { $entry.Message = 'Edición distinta de la probada; probablemente funcione.' }
                    } else { $entry.Status = 'invalid'; $entry.Message = 'Falta un archivo clave del juego.' }
                } else { $entry.Message = 'No corresponde a ningún juego Trampolín conocido.' }
            } finally { $iso.Dispose() }
        } catch {
            $entry.Status = 'invalid'
            $entry.Message = "No se pudo leer: $($_.Exception.Message)"
        }
        $result.Add([pscustomobject]$entry)
    }
    $zips = @(Get-ChildItem -LiteralPath $Folder -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    # Arrays comunes: PowerShell 5.1 falla al aplicar @() a una List[object] guardada en un objeto.
    [pscustomobject]@{ Isos = [object[]]$result.ToArray(); Zips = [object[]]$zips }
}

function Expand-TrZipIsos {
    <# Extrae las imágenes .iso de un ZIP (por ejemplo trampolin_anaya.zip). #>
    param([Parameter(Mandatory)][string]$Zip, [Parameter(Mandatory)][string]$Destination, [scriptblock]$OnProgress, $Cancel)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -like '*.iso' })
        $total = ($entries | Measure-Object Length -Sum).Sum; $done = 0
        foreach ($e in $entries) {
            $target = Join-Path $Destination ([IO.Path]::GetFileName($e.FullName))
            if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -eq $e.Length) { $done += $e.Length; continue }
            $in = $e.Open(); $out = [IO.File]::Create($target)
            try {
                $buf = New-Object byte[] (1MB)
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    if ($Cancel -and $Cancel.Cancel) { throw (New-Object OperationCanceledException) }
                    $out.Write($buf, 0, $n); $done += $n
                    if ($OnProgress) { & $OnProgress ([int](100 * $done / [Math]::Max(1, $total))) "Extrayendo $($e.Name)…" }
                }
            } finally { $in.Dispose(); $out.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Get-TrFreeDriveLetter {
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
    foreach ($l in 'TRAMPOLINZYXWVUSQKJHGF'.ToCharArray() | Select-Object -Unique) {
        if ($used -notcontains [string]$l) { return [string]$l }
    }
    throw (New-TrError 'TR-ISO-004')
}

function Mount-TrIso {
    <# Monta la ISO (si no lo está) y devuelve @{ Drive = 'M:'; Label; MountedByUs }. #>
    param([Parameter(Mandatory)][string]$Path, [string]$GameName = '')
    if (-not (Test-Path -LiteralPath $Path)) { throw (New-TrError 'TR-RUN-002' @{ game = $GameName; iso = $Path }) }
    try {
        $img = Get-DiskImage -ImagePath $Path -ErrorAction Stop
        $byUs = $false
        if (-not $img.Attached) { $img = Mount-DiskImage -ImagePath $Path -PassThru -ErrorAction Stop; $byUs = $true }
        $vol = $null
        for ($i = 0; $i -lt 20 -and -not ($vol -and $vol.DriveLetter); $i++) {
            $vol = $img | Get-Volume -ErrorAction SilentlyContinue
            if (-not ($vol -and $vol.DriveLetter)) { Start-Sleep -Milliseconds 250 }
        }
        if (-not ($vol -and $vol.DriveLetter)) { throw 'La imagen se montó pero Windows no le asignó una letra de unidad.' }
        [pscustomobject]@{ Drive = "$($vol.DriveLetter):"; Label = $vol.FileSystemLabel; MountedByUs = $byUs; Path = $Path }
    } catch {
        if ($_.Exception -is [TrampolinException]) { throw }
        throw (New-TrError 'TR-ISO-003' @{ game = $GameName } $_.Exception)
    }
}

function Dismount-TrIso {
    param([Parameter(Mandatory)]$Mount)
    if ($Mount.MountedByUs) {
        try { Dismount-DiskImage -ImagePath $Mount.Path -ErrorAction Stop | Out-Null } catch { Write-TrLog Warn "No se pudo desmontar $($Mount.Path): $_" }
    }
}

function New-TrSubst {
    <# Asigna una letra de unidad a una carpeta (como "subst"), sin permisos de administrador. #>
    param([Parameter(Mandatory)][string]$Folder)
    $letter = Get-TrFreeDriveLetter
    if (-not [TrNative]::DefineDosDevice(0, "${letter}:", $Folder)) {
        throw ("No se pudo asignar la unidad ${letter}: (error {0})" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    "${letter}:"
}

function Remove-TrSubst {
    param([Parameter(Mandatory)][string]$Drive, [Parameter(Mandatory)][string]$Folder)
    # DDD_REMOVE_DEFINITION (2) | DDD_EXACT_MATCH_ON_REMOVE (4)
    [void][TrNative]::DefineDosDevice(6, $Drive, $Folder)
}

# ---------------------------------------------------------------------------
# Validaciones de la carpeta de instalación
# ---------------------------------------------------------------------------

function Test-TrInstallRoot {
    <# Lanza un error del catálogo si la carpeta no sirve. Devuelve la ruta normalizada. #>
    param([Parameter(Mandatory)][string]$Path, [long]$RequiredBytes = 0)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -gt $script:MaxRootLength) { throw (New-TrError 'TR-DSK-004' @{ max = $script:MaxRootLength }) }
    $ansi = [Text.Encoding]::GetEncoding([TrNative]::GetACP())
    $bad = @($full.ToCharArray() | Where-Object { $ansi.GetString($ansi.GetBytes([string]$_)) -ne [string]$_ } | Select-Object -Unique)
    if ($bad.Count) { throw (New-TrError 'TR-DSK-003' @{ chars = (-join $bad) }) }
    if ($full.StartsWith('\\')) { throw (New-TrError 'TR-DSK-002' @{ path = $full }) }
    try {
        if (-not (Test-Path -LiteralPath $full)) { New-Item -ItemType Directory -Force -Path $full -ErrorAction Stop | Out-Null }
        $probe = Join-Path $full ('.trampolin-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'ok'); Remove-Item -LiteralPath $probe -Force
    } catch { throw (New-TrError 'TR-DSK-002' @{ path = $full } $_.Exception) }
    if ($RequiredBytes -gt 0) {
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
        if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
            throw (New-TrError 'TR-DSK-001' @{ drive = $drive.Name.TrimEnd('\'); need = (Format-TrSize $RequiredBytes); free = (Format-TrSize $drive.AvailableFreeSpace) })
        }
    }
    $full
}

function Format-TrSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    ('{0:N0} MB' -f [Math]::Ceiling($Bytes / 1MB))
}

function Get-TrRequiredBytes {
    <# Espacio necesario aproximado para instalar los juegos indicados. #>
    param([Parameter(Mandatory)][string[]]$GameIds, [Parameter(Mandatory)][string]$DataMode)
    $total = 0L
    foreach ($id in $GameIds) {
        $g = Get-TrGame $id
        $total += 15MB
        if ($DataMode -eq 'copy') { $total += [long]$g.iso.size }
    }
    $total + 50MB
}

# ---------------------------------------------------------------------------
# INI (en ANSI, como los leen los juegos)
# ---------------------------------------------------------------------------

function Expand-TrTemplate {
    param([string]$Text, [hashtable]$Vars)
    if ($null -eq $Text) { return $Text }
    foreach ($k in $Vars.Keys) { $Text = $Text.Replace('{' + $k + '}', [string]$Vars[$k]) }
    $Text
}

function Set-TrIniValues {
    <# Fusiona secciones/claves en un INI conservando el resto del contenido. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Values, [hashtable]$Vars = @{})
    $enc = [Text.Encoding]::GetEncoding([TrNative]::GetACP())
    $lines = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path) {
        foreach ($l in [IO.File]::ReadAllLines($Path, $enc)) { $lines.Add($l) }
        (Get-Item -LiteralPath $Path).IsReadOnly = $false
    }
    foreach ($section in $Values.Keys) {
        $kv = $Values[$section]
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -ieq "[$section]") { $start = $i; break }
        }
        if ($start -lt 0) {
            if ($lines.Count -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
            $lines.Add("[$section]"); $start = $lines.Count - 1
        }
        foreach ($key in $kv.Keys) {
            $value = Expand-TrTemplate ([string]$kv[$key]) $Vars
            $end = $lines.Count
            for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim().StartsWith('[')) { $end = $i; break } }
            $found = $false
            for ($i = $start + 1; $i -lt $end; $i++) {
                $t = $lines[$i]
                $eq = $t.IndexOf('=')
                if ($eq -gt 0 -and $t.Substring(0, $eq).Trim() -ieq $key) { $lines[$i] = "$key=$value"; $found = $true; break }
            }
            if (-not $found) {
                $insert = $end
                while ($insert -gt $start + 1 -and -not $lines[$insert - 1].Trim()) { $insert-- }
                $lines.Insert($insert, "$key=$value")
            }
        }
    }
    [IO.File]::WriteAllLines($Path, $lines.ToArray(), $enc)
}

function Repair-TrSectionSizes {
    <#
      WSOUND32.DLL (compilada con Watcom) declara sus secciones con tamaño virtual 0.
      Windows 95 las mapeaba completas hasta la sección siguiente y la DLL usa esa
      memoria (su .bss real es más grande que los datos del archivo). Windows 10 solo
      mapea los bytes del archivo y el juego se cierra con 0xC0000005 al limpiar un
      búfer (5° Curso, WSOUND32.DLL+0x1F306). Se completa el tamaño de cada sección
      hasta la siguiente. Devuelve $true si modificó el archivo.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return $false }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -le 0 -or $pe + 24 -gt $b.Length -or [BitConverter]::ToUInt32($b, $pe) -ne 0x4550) { return $false }
    $count = [BitConverter]::ToUInt16($b, $pe + 6)
    $table = $pe + 24 + [BitConverter]::ToUInt16($b, $pe + 20)
    $sizeOfImage = [BitConverter]::ToUInt32($b, $pe + 24 + 56)
    $changed = $false
    for ($i = 0; $i -lt $count; $i++) {
        $h = $table + 40 * $i
        if ([BitConverter]::ToUInt32($b, $h + 8) -ne 0) { continue }
        $va = [BitConverter]::ToUInt32($b, $h + 12)
        $next = if ($i + 1 -lt $count) { [BitConverter]::ToUInt32($b, $h + 40 + 12) } else { $sizeOfImage }
        if ($next -le $va) { continue }
        [BitConverter]::GetBytes([uint32]($next - $va)).CopyTo($b, $h + 8)
        $changed = $true
    }
    if ($changed) {
        (Get-Item -LiteralPath $Path).IsReadOnly = $false
        [IO.File]::WriteAllBytes($Path, $b)
    }
    $changed
}

function Write-TrGameConfig {
    <# Escribe el INI propio del juego y su sección de KA.INI con las rutas actuales. #>
    param([Parameter(Mandatory)]$Game, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Vars)
    $hd = $Vars.HD
    $ini = ConvertTo-TrHashtable $Game.ini
    if ($ini) { foreach ($file in $ini.Keys) { Set-TrIniValues -Path (Join-Path $hd $file) -Values $ini[$file] -Vars $Vars } }
    $ka = ConvertTo-TrHashtable $Game.kaIni
    if ($ka -and $ka.Count) { Set-TrIniValues -Path (Join-Path $Root 'games\KA.INI') -Values $ka -Vars $Vars }
    $wsound = Join-Path $hd 'WSOUND32.DLL'
    if ((Test-Path -LiteralPath $wsound) -and (Repair-TrSectionSizes -Path $wsound)) {
        Write-TrLog Info "WSOUND32.DLL de $($Game.id): secciones completadas como en Windows 95"
    }
}

# ---------------------------------------------------------------------------
# Copia de archivos desde la ISO
# ---------------------------------------------------------------------------

function Copy-TrFromIso {
    <#
      Copia desde la ISO: cada carpeta de $Sources se copia "aplanada" en $Destination
      (su contenido, con subcarpetas). Con $Sources vacío copia el disco entero.
    #>
    param(
        [Parameter(Mandatory)][string]$IsoPath, [Parameter(Mandatory)][string]$Destination,
        [string[]]$Sources = @(), [string[]]$Exclude = @(), [scriptblock]$OnBytes, $Cancel
    )
    $iso = New-Object TrIso($IsoPath)
    $copied = 0L
    try {
        $jobs = New-Object Collections.Generic.List[object]
        if (-not $Sources -or $Sources.Count -eq 0) {
            foreach ($e in $iso.List('')) { $jobs.Add(@($e, $e.Path)) }
        } else {
            foreach ($src in $Sources) {
                $prefix = $src.Trim('\') + '\'
                foreach ($e in $iso.List($src)) { $jobs.Add(@($e, $e.Path.Substring($prefix.Length))) }
            }
        }
        foreach ($job in $jobs) {
            $e = $job[0]; $rel = $job[1]
            if ($Exclude | Where-Object { ('\' + $rel + '\') -like ('*\' + $_ + '\*') }) { continue }
            if ($Cancel -and $Cancel.Cancel) { throw (New-Object OperationCanceledException) }
            $target = Join-Path $Destination $rel
            if ($e.IsDirectory) { if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }; continue }
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -eq $e.Size) { $copied += $e.Size; continue }
            try { $copied += $iso.Extract($e, $target) }
            catch [UnauthorizedAccessException] { throw (New-TrError 'TR-CPY-002' @{ file = $rel } $_.Exception) }
            catch [IO.IOException] { throw (New-TrError 'TR-CPY-001' @{ game = [IO.Path]::GetFileName($IsoPath); file = $rel } $_.Exception) }
            if ($OnBytes) { & $OnBytes $e.Size $rel }
        }
    } finally { $iso.Dispose() }
    $copied
}

function Get-TrCopySize {
    param([Parameter(Mandatory)][string]$IsoPath, [string[]]$Sources = @())
    $iso = New-Object TrIso($IsoPath)
    try {
        if (-not $Sources -or $Sources.Count -eq 0) { return ($iso.List('') | Measure-Object Size -Sum).Sum }
        $t = 0L; foreach ($s in $Sources) { $t += ($iso.List($s) | Measure-Object Size -Sum).Sum }; return $t
    } finally { $iso.Dispose() }
}

# ---------------------------------------------------------------------------
# Instalación del runtime y de los juegos
# ---------------------------------------------------------------------------

function Install-TrRuntimeFiles {
    <# Copia el programa a <Root>\app para que la instalación no dependa de la carpeta de descarga. #>
    param([Parameter(Mandatory)][string]$Root)
    $app = Join-Path $Root 'app'
    $src = $script:AppRoot
    if ([IO.Path]::GetFullPath($src).TrimEnd('\') -ieq [IO.Path]::GetFullPath($app).TrimEnd('\')) { return $app }
    New-Item -ItemType Directory -Force -Path $app | Out-Null
    Copy-Item -LiteralPath (Join-Path $src 'src') -Destination $app -Recurse -Force
    $binDst = Join-Path $app 'native\bin'
    New-Item -ItemType Directory -Force -Path $binDst | Out-Null
    Copy-Item -Path (Join-Path (Get-TrNativeBin) '*') -Destination $binDst -Force
    foreach ($f in @('Trampolin.cmd', 'LEEME-RUNTIME.md')) {
        $p = Join-Path $src $f
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $app -Force }
    }
    $cmd = @(
        '@echo off',
        'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app\src\Trampolin.ps1" %*'
    )
    [IO.File]::WriteAllLines((Join-Path $Root 'Trampolin.cmd'), $cmd, [Text.Encoding]::ASCII)
    if (Test-Path -LiteralPath (Join-Path $src 'LEEME-RUNTIME.md')) { Copy-Item -LiteralPath (Join-Path $src 'LEEME-RUNTIME.md') -Destination $Root -Force }
    $app
}

function Install-TrGame {
    <#
      Instala (o repara) un juego. $OnProgress recibe (porcentaje, texto).
      Modo 'copy': copia también todo el disco a <Root>\cd\<ID> para no necesitar la ISO.
    #>
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$IsoPath, [Parameter(Mandatory)][string]$Root,
        [ValidateSet('copy', 'iso')][string]$DataMode = 'copy', [scriptblock]$OnProgress, $Cancel, [switch]$Repair
    )
    $game = Get-TrGame $Id
    $hd = Join-Path $Root "games\$Id"
    $cd = Join-Path $Root "cd\$Id"
    $existedBefore = Test-Path -LiteralPath $hd
    $progress = { param($p, $t) if ($OnProgress) { & $OnProgress $p $t } }

    $rollback = {
        if (-not $existedBefore -and -not $Repair) {
            Remove-Item -LiteralPath $hd -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $cd -Recurse -Force -ErrorAction SilentlyContinue
        }
    }.GetNewClosure()

    Invoke-TrStep -Name "Instalar $Id" -ErrorCode 'TR-CPY-001' -ErrorData @{ game = $game.name; file = '' } -Rollback $rollback -Action {
        & $progress 0 "Preparando $($game.name)…"
        $label = $null
        $iso = New-Object TrIso($IsoPath)
        try {
            $label = $iso.VolumeLabel
            if (-not $iso.Find($game.iso.keyFile)) { throw (New-TrError 'TR-ISO-002' @{ file = [IO.Path]::GetFileName($IsoPath) }) }
        } finally { $iso.Dispose() }

        $sources = @($game.copy)
        $total = [long](Get-TrCopySize -IsoPath $IsoPath -Sources $sources)
        if ($DataMode -eq 'copy') { $total += [long](Get-TrCopySize -IsoPath $IsoPath) }
        $counter = @{ done = 0L }
        # Sin GetNewClosure: el bloque se ejecuta dentro de Copy-TrFromIso y resuelve $counter/$progress por ámbito dinámico.
        $onBytes = { param($n, $rel) $counter.done += $n; & $progress ([int](95 * $counter.done / [Math]::Max(1, $total))) "Copiando $($game.name): $rel" }

        New-Item -ItemType Directory -Force -Path $hd | Out-Null
        Copy-TrFromIso -IsoPath $IsoPath -Destination $hd -Sources $sources -Exclude @($game.exclude) -OnBytes $onBytes -Cancel $Cancel | Out-Null
        if ($DataMode -eq 'copy') {
            New-Item -ItemType Directory -Force -Path $cd | Out-Null
            Copy-TrFromIso -IsoPath $IsoPath -Destination $cd -OnBytes $onBytes -Cancel $Cancel | Out-Null
        }
        & $progress 96 'Aplicando la capa de compatibilidad…'
        Copy-Item -LiteralPath (Join-Path (Get-TrNativeBin) 'WING32.DLL') -Destination $hd -Force
        Get-ChildItem -LiteralPath $hd -Recurse -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }

        $manifest = Get-TrManifest -Root $Root
        $manifest.games[$Id] = [ordered]@{
            id = $Id; name = $game.name; dataMode = $DataMode; isoPath = $IsoPath; label = $label
            hd = $hd; cd = $(if ($DataMode -eq 'copy') { $cd } else { $null }); installedAt = (Get-Date -Format s)
        }
        Save-TrManifest -Root $Root -Manifest $manifest
        & $progress 100 "$($game.name): listo."
    }
}

function New-TrShortcuts {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [bool]$Desktop = $true)
    $game = Get-TrGame $Id
    $shell = New-Object -ComObject WScript.Shell
    $targets = @([Environment]::GetFolderPath('Programs') + '\Trampolín')
    if ($Desktop) { $targets += [Environment]::GetFolderPath('Desktop') }
    $icon = Join-Path $Root "games\$Id\$($game.icon)"
    foreach ($dir in $targets) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $lnk = $shell.CreateShortcut((Join-Path $dir ("Trampolín - {0}.lnk" -f ($game.name -replace '[\\/:*?"<>|]', '-'))))
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" --play {1}' -f (Join-Path $Root 'app\src\Trampolin.ps1'), $Id)
        $lnk.WorkingDirectory = $Root
        if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = "$icon,0" }
        $lnk.Description = "$($game.name) ($($game.age))"
        $lnk.WindowStyle = 7
        $lnk.Save()
    }
    $lib = $shell.CreateShortcut((Join-Path ($targets[0]) 'Biblioteca Trampolín.lnk'))
    $lib.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lib.Arguments = ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f (Join-Path $Root 'app\src\Trampolin.ps1'))
    $lib.WorkingDirectory = $Root
    $lib.WindowStyle = 7
    $lib.Save()
}

function Remove-TrShortcuts {
    param([Parameter(Mandatory)][string]$Id)
    $game = Get-TrGame $Id
    $name = "Trampolín - {0}.lnk" -f ($game.name -replace '[\\/:*?"<>|]', '-')
    foreach ($dir in @(([Environment]::GetFolderPath('Programs') + '\Trampolín'), [Environment]::GetFolderPath('Desktop'))) {
        Remove-Item -LiteralPath (Join-Path $dir $name) -Force -ErrorAction SilentlyContinue
    }
}

function Get-TrInstalledGames {
    param([Parameter(Mandatory)][string]$Root)
    $m = Get-TrManifest -Root $Root
    foreach ($g in Get-TrCatalog) {
        if ($m.games.Contains($g.id)) {
            $e = $m.games[$g.id]
            $ok = Test-Path -LiteralPath (Join-Path $e.hd $g.exe)
            [pscustomobject]@{ Id = $g.id; Name = $g.name; Age = $g.age; Engine = $g.engine; Entry = $e; Healthy = $ok
                Icon = (Join-Path $e.hd $g.icon) }
        }
    }
}

function Backup-TrSaves {
    <# Comprime las partidas de un juego en Documentos\Trampolín - partidas. Devuelve la ruta del zip (o $null). #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $game = Get-TrGame $Id
    $hd = Join-Path $Root "games\$Id"
    $files = @(foreach ($pat in @($game.saves)) { Get-ChildItem -LiteralPath $hd -Filter $pat -File -ErrorAction SilentlyContinue })
    $files = @($files | Where-Object { $_.Name -notin @('~~ka.swp') } | Sort-Object FullName -Unique)
    if (-not $files.Count) { return $null }
    $destDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Trampolín - partidas'
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $zip = Join-Path $destDir ('{0}-{1:yyyyMMdd-HHmmss}.zip' -f $Id, (Get-Date))
    $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
    try { foreach ($f in $files) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $f.Name) } }
    finally { $archive.Dispose() }
    $zip
}

function Uninstall-TrGame {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [switch]$KeepSaves)
    Invoke-TrStep -Name "Desinstalar $Id" -ErrorCode 'TR-CFG-001' -ErrorData @{ game = (Get-TrGame $Id).name } -Action {
        $backup = $null
        if ($KeepSaves) { $backup = Backup-TrSaves -Id $Id -Root $Root }
        Remove-TrShortcuts -Id $Id
        Remove-Item -LiteralPath (Join-Path $Root "games\$Id") -Recurse -Force -ErrorAction Stop
        Remove-Item -LiteralPath (Join-Path $Root "cd\$Id") -Recurse -Force -ErrorAction SilentlyContinue
        $m = Get-TrManifest -Root $Root
        if ($m.games.Contains($Id)) { $m.games.Remove($Id) }
        Save-TrManifest -Root $Root -Manifest $m
        $backup
    }
}

# ---------------------------------------------------------------------------
# Lanzamiento
# ---------------------------------------------------------------------------

function Get-TrRunningGame {
    param([Parameter(Mandatory)][string]$Root)
    $games = (Join-Path $Root 'games').TrimEnd('\') + '\'
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($games, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    } | Select-Object -First 1
}

function Start-TrGame {
    <#
      Prepara la unidad de datos, escribe la configuración y lanza el juego.
      Devuelve una "sesión" que hay que cerrar con Complete-TrGame.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [int]$Scale = 0)
    $game = Get-TrGame $Id
    $m = Get-TrManifest -Root $Root
    if (-not $m.games.Contains($Id)) { throw (New-TrError 'TR-RUN-006' @{ game = $game.name }) }
    $entry = $m.games[$Id]
    $hd = $entry.hd
    if (-not (Test-Path -LiteralPath (Join-Path $hd $game.exe))) { throw (New-TrError 'TR-RUN-006' @{ game = $game.name }) }
    if (Get-TrRunningGame -Root $Root) { throw (New-TrError 'TR-RUN-001') }

    $session = [pscustomobject]@{ Id = $Id; Game = $game; Root = $Root; Process = $null; Started = $null; Mount = $null
        Subst = $null; CdFolder = $null; ExitCode = $null }
    try {
        $cdDrive = $null; $label = $entry.label; $fakeCd = $false
        if ($entry.dataMode -eq 'copy' -and $entry.cd -and (Test-Path -LiteralPath $entry.cd)) {
            $cdDrive = New-TrSubst -Folder $entry.cd
            $session.Subst = $cdDrive; $session.CdFolder = $entry.cd; $fakeCd = $true
        } else {
            $session.Mount = Mount-TrIso -Path $entry.isoPath -GameName $game.name
            $cdDrive = $session.Mount.Drive; $label = $session.Mount.Label
        }
        Write-TrLog Info "Juego ${Id}: datos en $cdDrive ('$label'), carpeta $hd"
        $vars = @{ HD = $hd; CD = $cdDrive; LABEL = $label }
        Invoke-TrStep -Name "Configurar $Id" -ErrorCode 'TR-CFG-001' -ErrorData @{ game = $game.name } -Action {
            Write-TrGameConfig -Game $game -Root $Root -Vars $vars
        }

        $bin = Get-TrNativeBin
        $logDir = Join-Path $Root 'logs'
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $env:TRAMPOLIN_LOG = Join-Path $logDir "juego-$Id.log"
        if ($env:TRAMPOLIN_TRACE -ne '1') { $env:TRAMPOLIN_TRACE = '0' }   # diagnóstico: definir TRAMPOLIN_TRACE=1 antes de abrir
        $env:TRAMPOLIN_KAINI = Join-Path $Root 'games\KA.INI'
        $env:TRAMPOLIN_SCALE = [string]$Scale
        $env:TRAMPOLIN_SWAPDIR = $hd
        $env:TRAMPOLIN_QUIET = $null
        if ($fakeCd) { $env:TRAMPOLIN_CDDRIVE = $cdDrive.Substring(0, 1); $env:TRAMPOLIN_CDLABEL = $label }
        else { $env:TRAMPOLIN_CDDRIVE = $null; $env:TRAMPOLIN_CDLABEL = $null }
        if (Test-Path -LiteralPath $env:TRAMPOLIN_LOG) { Clear-Content -LiteralPath $env:TRAMPOLIN_LOG -ErrorAction SilentlyContinue }

        $gameArgs = Expand-TrTemplate ([string]$game.args) $vars
        $argLine = ('--wait --cwd "{0}" -- "{1}" {2}' -f $hd, (Join-Path $hd $game.exe), $gameArgs).Trim()
        Write-TrLog Info "Lanzando: trlaunch.exe $argLine"
        $session.Process = Start-Process -FilePath (Join-Path $bin 'trlaunch.exe') -ArgumentList $argLine -WorkingDirectory $hd -PassThru
        $session.Started = Get-Date
    } catch {
        Complete-TrGame -Session $session -NoDiagnose | Out-Null
        throw
    }
    $session
}

function Complete-TrGame {
    <# Limpia la sesión (desmonta, quita la unidad) y devuelve $null o un error diagnóstico. #>
    param([Parameter(Mandatory)]$Session, [switch]$NoDiagnose)
    $diag = $null
    if ($Session.Process) {
        try { $Session.Process.WaitForExit() } catch { }
        $Session.ExitCode = $Session.Process.ExitCode
        $elapsed = ((Get-Date) - $Session.Started).TotalSeconds
        Write-TrLog Info ("Juego {0} terminó: código {1} (0x{1:X8}) tras {2:N0} s" -f $Session.Id, $Session.ExitCode, $elapsed)
        if (-not $NoDiagnose) {
            $code = [int64]$Session.ExitCode
            if ($code -in 9001, 9002, 9003) { $diag = New-TrError 'TR-RUN-005' @{ game = $Session.Game.name } }
            elseif ($code -eq 0xC0000005 -or $code -eq -1073741819) {
                # trhook deja en el log del juego dónde ocurrió el fallo (líneas "FALLO"): va al informe.
                $crash = $null
                $gameLog = Join-Path $Session.Root "logs\juego-$($Session.Id).log"
                if (Test-Path -LiteralPath $gameLog) {
                    $lines = @(Get-Content -LiteralPath $gameLog -Encoding UTF8 | Where-Object { $_ -match '\] FALLO ' })
                    if ($lines.Count) {
                        $text = ($lines | ForEach-Object { $_ -replace '^\[\d+\] FALLO ', '' }) -join [Environment]::NewLine
                        Write-TrLog Error "Detalle del fallo de $($Session.Id):$([Environment]::NewLine)$text"
                        $crash = New-Object Exception("Detalle del fallo:$([Environment]::NewLine)$text")
                    }
                }
                $diag = New-TrError 'TR-RUN-004' @{ game = $Session.Game.name; code = ('0x{0:X8}' -f $Session.ExitCode) } $crash
            }
            elseif ($elapsed -lt 5 -and $code -ne 0) { $diag = New-TrError 'TR-RUN-003' @{ game = $Session.Game.name } }
        }
    }
    if ($Session.Mount) { Dismount-TrIso -Mount $Session.Mount }
    if ($Session.Subst) { Remove-TrSubst -Drive $Session.Subst -Folder $Session.CdFolder }
    $diag
}

Export-ModuleMember -Function Get-TrAppRoot, Get-TrNativeBin, Get-TrCatalog, Get-TrGame, ConvertTo-TrHashtable, Get-TrConfig, Save-TrConfig,
    Get-TrDefaultInstallRoot, Get-TrManifest, Save-TrManifest, Test-TrPrerequisites, Find-TrIsos, Expand-TrZipIsos, Mount-TrIso, Dismount-TrIso,
    New-TrSubst, Remove-TrSubst, Test-TrInstallRoot, Format-TrSize, Get-TrRequiredBytes, Set-TrIniValues, Write-TrGameConfig, Repair-TrSectionSizes, Copy-TrFromIso,
    Get-TrCopySize, Install-TrRuntimeFiles, Install-TrGame, New-TrShortcuts, Remove-TrShortcuts, Get-TrInstalledGames, Backup-TrSaves,
    Uninstall-TrGame, Get-TrRunningGame, Start-TrGame, Complete-TrGame
