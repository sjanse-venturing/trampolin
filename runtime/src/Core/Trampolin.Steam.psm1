# Trampolin.Steam.psm1 — accesos «no de Steam» (shortcuts.vdf) para abrir los juegos desde Steam,
# Big Picture y Steam Link, con su artwork (portada, cabecera, fondo y logo). Compatible con Windows
# PowerShell 5.1. Refleja linux/trampolin/steam.py y linux/trampolin/art.py (mismo formato binario,
# mismo appid, mismos campos y misma composición del artwork).

Set-StrictMode -Version 2.0

$script:Tag = 'Trampolín'
$script:LibraryName = 'Biblioteca Trampolín'

function Initialize-TrVdf {
    # Se compila recién cuando hace falta, para no demorar el arranque de la biblioteca.
    if ('TrVdf' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Specialized;
using System.IO;
using System.Text;

public static class TrVdf {
    // VDF binario de Steam: 0x00 mapa, 0x01 texto, 0x02 entero de 32 bits, 0x07 entero de 64 bits, 0x08 fin.
    public static OrderedDictionary Load(byte[] data) {
        if (data == null || data.Length == 0) return new OrderedDictionary();
        int pos = 0;
        return ReadMap(data, ref pos);
    }

    static string CStr(byte[] d, ref int pos) {
        int end = Array.IndexOf(d, (byte)0, pos);
        if (end < 0) throw new InvalidDataException("VDF truncado");
        string s = Encoding.UTF8.GetString(d, pos, end - pos);
        pos = end + 1;
        return s;
    }

    static OrderedDictionary ReadMap(byte[] d, ref int pos) {
        var map = new OrderedDictionary();
        while (true) {
            if (pos >= d.Length) throw new InvalidDataException("VDF truncado");
            byte t = d[pos++];
            if (t == 0x08) return map;
            string key = CStr(d, ref pos);
            switch (t) {
                case 0x00: map[key] = ReadMap(d, ref pos); break;
                case 0x01: map[key] = CStr(d, ref pos); break;
                case 0x02: map[key] = BitConverter.ToInt32(d, pos); pos += 4; break;
                case 0x07: map[key] = BitConverter.ToUInt64(d, pos); pos += 8; break;
                default: throw new InvalidDataException(string.Format("Tipo VDF desconocido 0x{0:X2}", t));
            }
        }
    }

    public static byte[] Dump(IDictionary map) {
        var ms = new MemoryStream();
        Write(ms, map);
        return ms.ToArray();
    }

    static void Bytes(MemoryStream ms, byte[] b) { ms.Write(b, 0, b.Length); }

    static void Write(MemoryStream ms, IDictionary map) {
        foreach (DictionaryEntry e in map) {
            byte[] key = Encoding.UTF8.GetBytes(Convert.ToString(e.Key) + "\0");
            object v = e.Value;
            if (v is System.Management.Automation.PSObject) v = ((System.Management.Automation.PSObject)v).BaseObject;
            if (v is IDictionary) { ms.WriteByte(0x00); Bytes(ms, key); Write(ms, (IDictionary)v); }
            else if (v is ulong) { ms.WriteByte(0x07); Bytes(ms, key); Bytes(ms, BitConverter.GetBytes((ulong)v)); }
            else if (v is bool || v is int || v is short || v is byte || v is long || v is uint) {
                long n = (v is bool) ? (((bool)v) ? 1 : 0) : Convert.ToInt64(v);
                if (n > int.MaxValue || n < int.MinValue) { ms.WriteByte(0x07); Bytes(ms, key); Bytes(ms, BitConverter.GetBytes((ulong)n)); }
                else { ms.WriteByte(0x02); Bytes(ms, key); Bytes(ms, BitConverter.GetBytes((int)n)); }
            }
            else { ms.WriteByte(0x01); Bytes(ms, key); Bytes(ms, Encoding.UTF8.GetBytes(Convert.ToString(v) + "\0")); }
        }
        ms.WriteByte(0x08);
    }

    static uint[] table;

    public static uint Crc32(byte[] data) {
        if (table == null) {
            var t = new uint[256];
            for (uint i = 0; i < 256; i++) {
                uint c = i;
                for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
                t[i] = c;
            }
            table = t;
        }
        uint crc = 0xFFFFFFFFu;
        foreach (byte b in data) crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }

    // El appid que Steam calcula para un acceso no-Steam (entero de 32 bits con signo en el VDF).
    public static int ShortcutAppId(string exe, string name) {
        uint v = Crc32(Encoding.UTF8.GetBytes(exe + name)) | 0x80000000u;
        return unchecked((int)v);
    }
}
'@ -ReferencedAssemblies ([psobject].Assembly.Location)
}

function ConvertFrom-TrVdf { param([byte[]]$Bytes) Initialize-TrVdf; [TrVdf]::Load($Bytes) }
function ConvertTo-TrVdf { param([Parameter(Mandatory)][Collections.IDictionary]$Map) Initialize-TrVdf; , [TrVdf]::Dump($Map) }
function Get-TrShortcutAppId { param([string]$Exe, [string]$Name) Initialize-TrVdf; [TrVdf]::ShortcutAppId($Exe, $Name) }

# ---------------------------------------------------------------------------
# Steam instalado
# ---------------------------------------------------------------------------

function Get-TrSteamRoot {
    <# Carpeta de Steam (o $null si no está instalado). #>
    foreach ($k in @(@('HKCU:\Software\Valve\Steam', 'SteamPath'), @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'), @('HKLM:\SOFTWARE\Valve\Steam', 'InstallPath'))) {
        try {
            $v = (Get-ItemProperty -LiteralPath $k[0] -Name $k[1] -ErrorAction Stop).($k[1])
            if ($v) {
                $p = [IO.Path]::GetFullPath(($v -replace '/', '\'))
                if (Test-Path -LiteralPath (Join-Path $p 'steam.exe')) { return $p }
            }
        } catch { }
    }
    $null
}

function Get-TrSteamUserConfigDirs {
    <# userdata\<id>\config de cada usuario de Steam que inició sesión en este equipo. #>
    $root = Get-TrSteamRoot
    if (-not $root) { return @() }
    @(Get-ChildItem -LiteralPath (Join-Path $root 'userdata') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'config')) } |
        ForEach-Object { Join-Path $_.FullName 'config' })
}

function Test-TrSteamInstalled { [bool](Get-TrSteamRoot) }

function Test-TrSteamRunning { [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue) }

function Stop-TrSteam {
    <# Pide a Steam que se cierre y espera hasta $Timeout segundos. Devuelve $true si se cerró. #>
    param([int]$Timeout = 60)
    $root = Get-TrSteamRoot
    if (-not $root) { return $true }
    Start-Process -FilePath (Join-Path $root 'steam.exe') -ArgumentList '-shutdown' | Out-Null
    $end = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $end) {
        if (-not (Test-TrSteamRunning)) { Start-Sleep -Seconds 1; return $true }
        Start-Sleep -Milliseconds 500
    }
    $false
}

function Start-TrSteam {
    $root = Get-TrSteamRoot
    if ($root) { Start-Process -FilePath (Join-Path $root 'steam.exe') | Out-Null }
}

# ---------------------------------------------------------------------------
# Accesos
# ---------------------------------------------------------------------------

function Get-TrWantedSteamShortcuts {
    <# La biblioteca y un acceso por juego instalado, con los mismos argumentos que los .lnk del menú Inicio. #>
    param([Parameter(Mandatory)][string]$Root)
    $exe = '"{0}"' -f (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $ps1 = Join-Path $Root 'app\src\Trampolin.ps1'
    $base = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $ps1
    $items = @(@{ name = $script:LibraryName; opts = $base; icon = '' })
    foreach ($g in @(Get-TrInstalledGames -Root $Root)) {
        $icon = $(if (Test-Path -LiteralPath $g.Icon) { $g.Icon } else { '' })
        $items += @{ name = "Trampolín - $($g.Name)"; opts = "$base --play $($g.Id)"; icon = $icon; id = $g.Id }
    }
    foreach ($i in $items) {
        $script:LastArtIds[(Get-TrShortcutAppId $exe $i.name)] = $(if ($i.Contains('id')) { $i.id } else { $null })
        [ordered]@{
            appid = (Get-TrShortcutAppId $exe $i.name); AppName = $i.name; Exe = $exe; StartDir = ('"{0}"' -f $Root); icon = $i.icon
            ShortcutPath = ''; LaunchOptions = $i.opts; IsHidden = 0; AllowDesktopConfig = 1; AllowOverlay = 1; OpenVR = 0; Devkit = 0
            DevkitGameID = ''; DevkitOverrideAppID = 0; LastPlayTime = 0; FlatpakAppID = ''; tags = [ordered]@{ '0' = $script:Tag }
        }
    }
}

function Test-TrOurShortcut {
    param($Entry)
    foreach ($k in 'LaunchOptions', 'launchoptions') { if ($Entry.Contains($k) -and ([string]$Entry[$k]) -like '*Trampolin.ps1*') { return $true } }
    foreach ($k in 'Exe', 'exe') { if ($Entry.Contains($k) -and ([string]$Entry[$k]).Trim('"') -like '*/trampolin.sh') { return $true } }
    $false
}

function Update-TrSteamShortcutsFile {
    <# Reemplaza nuestros accesos en un shortcuts.vdf conservando los demás. Devuelve cuántos escribió. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Wanted)
    $data = $null
    if (Test-Path -LiteralPath $Path) { $data = [IO.File]::ReadAllBytes($Path) }
    $doc = ConvertFrom-TrVdf $data
    $current = @()
    if ($doc.Contains('shortcuts') -and $doc['shortcuts'] -is [Collections.IDictionary]) { $current = @($doc['shortcuts'].Values) }
    $keep = @($current | Where-Object { -not (Test-TrOurShortcut $_) })
    $old = @{}
    foreach ($e in @($current | Where-Object { Test-TrOurShortcut $_ })) {
        $n = $(if ($e.Contains('AppName')) { $e['AppName'] } elseif ($e.Contains('appname')) { $e['appname'] } else { '' })
        $old[[string]$n] = $e
    }
    $merged = New-Object Collections.Specialized.OrderedDictionary
    $i = 0
    foreach ($e in $keep) { $merged[[string]$i] = $e; $i++ }
    foreach ($w in @($Wanted)) {
        $prev = $old[$w.AppName]
        if ($prev -and $prev.Contains('LastPlayTime')) { $w.LastPlayTime = $prev['LastPlayTime'] }   # conservar la última vez que se jugó
        $merged[[string]$i] = $w; $i++
    }
    $out = New-Object Collections.Specialized.OrderedDictionary
    $out['shortcuts'] = $merged
    $bytes = ConvertTo-TrVdf $out
    if ($data -and -not (Test-Path -LiteralPath "$Path.trampolin.bak")) { Copy-Item -LiteralPath $Path -Destination "$Path.trampolin.bak" }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    @($Wanted).Count
}

# ---------------------------------------------------------------------------
# Artwork (config\grid): portada vertical, cabecera, fondo y logo
# ---------------------------------------------------------------------------

$script:LastArtIds = @{}

# Estilo común a todos los juegos: el ícono del juego ampliado como pixel art dentro de un marco blanco
# (escala entera k: marco de 34k con el ícono de 32k adentro), sobre el color principal del ícono, y una franja
# con la imagen del disco (recortada para cubrirla) si la receta "art" la tiene. Sin imagen, el marco va
# centrado. Mismas medidas y posiciones que LAYOUTS en linux/trampolin/art.py.
$script:ArtLayouts = [ordered]@{
    'portrait.png' = @{ w = 600; h = 900; k = 12; frame = @(96, 56); alone = @(96, 246); picture = @(0, 520, 600, 380) }
    'header.png' = @{ w = 920; h = 430; k = 10; frame = @(45, 45); alone = @(290, 45); picture = @(430, 0, 490, 430) }
    'hero.png' = @{ w = 1920; h = 620; k = 10; frame = @(236, 70); alone = @(790, 70); picture = @(880, 0, 1040, 620) }
}
# En el fondo el marco va arriba: Steam muestra abajo a la izquierda el logo (o el nombre, si no hay logo).
$script:ArtGridNames = [ordered]@{ 'portrait.png' = '{0}p.png'; 'header.png' = '{0}.png'; 'hero.png' = '{0}_hero.png'; 'logo.png' = '{0}_logo.png' }

function Get-TrDominantColor {
    <# Color más frecuente entre los píxeles opacos (empate: el que aparece primero, de arriba abajo). #>
    param([Parameter(Mandatory)]$Bitmap)
    $count = @{}; $first = @{}; $i = 0
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            if ($c.A -ge 128) {
                $k = ([int]$c.R -shl 16) -bor ([int]$c.G -shl 8) -bor [int]$c.B
                if ($count.ContainsKey($k)) { $count[$k]++ } else { $count[$k] = 1; $first[$k] = $i }
            }
            $i++
        }
    }
    if (-not $count.Count) { return [Drawing.Color]::FromArgb(128, 128, 128) }
    $best = @($count.Keys | Sort-Object @{ e = { $count[$_] }; Descending = $true }, @{ e = { $first[$_] } })[0]
    [Drawing.Color]::FromArgb(($best -shr 16) -band 255, ($best -shr 8) -band 255, $best -band 255)
}

function Get-TrPolygonCrossings {
    <# Abscisas donde la recta horizontal Y corta los lados de un polígono [[x, y], ...]. #>
    param([double]$Y, $Polygon)
    $n = @($Polygon).Count; $j = $n - 1
    for ($i = 0; $i -lt $n; $i++) {
        $xi = [double]$Polygon[$i][0]; $yi = [double]$Polygon[$i][1]; $xj = [double]$Polygon[$j][0]; $yj = [double]$Polygon[$j][1]
        if (($yi -gt $Y) -ne ($yj -gt $Y)) { ($xj - $xi) * ($Y - $yi) / ($yj - $yi) + $xi }
        $j = $i
    }
}

function New-TrArtImages {
    <#
      Genera las imágenes de Steam de un juego instalado en <Root>\games\<ID>\art\steam: el ícono del ejecutable y,
      si la receta "art" la tiene, la imagen del disco (Save-TrArtSource) y el logo recortado de ella. Devuelve la
      carpeta, o $null si falta el ejecutable. Se regeneran solo si cambió alguna de las fuentes.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root)
    $game = Get-TrGame $Id
    $hd = Join-Path $Root "games\$Id"
    $exe = Join-Path $hd $game.icon
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    $src = $null
    try { $src = Save-TrArtSource -Id $Id -Root $Root } catch { Write-TrLog Warn "No se pudo leer la imagen del disco de ${Id}: $_" }
    $art = $(if ($game.PSObject.Properties.Name -contains 'art') { $game.art } else { $null })
    $out = Join-Path $hd 'art\steam'
    $hero = Join-Path $out 'hero.png'
    if (Test-Path -LiteralPath $hero) {
        $t = (Get-Item -LiteralPath $hero).LastWriteTime
        $newer = @(@($exe, $src) | Where-Object { $_ -and (Get-Item -LiteralPath $_).LastWriteTime -gt $t })
        if (-not $newer.Count) { return $out }
    }
    Add-Type -AssemblyName System.Drawing
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $icon = ([Drawing.Icon]::ExtractAssociatedIcon($exe)).ToBitmap()
    $pic = $(if ($src) { New-Object Drawing.Bitmap $src } else { $null })
    $wrap = New-Object Drawing.Imaging.ImageAttributes
    $wrap.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)   # sin bordes semitransparentes al escalar
    try {
        $bg = Get-TrDominantColor $icon
        foreach ($name in $script:ArtLayouts.Keys) {
            $l = $script:ArtLayouts[$name]
            $canvas = New-Object Drawing.Bitmap $l.w, $l.h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [Drawing.Graphics]::FromImage($canvas)
            try {
                $g.Clear($bg)
                $at = $l.alone
                if ($pic) {
                    # Recorte centrado de la imagen con la proporción de la franja, escalado para cubrirla.
                    $r = $l.picture; $s = [Math]::Max($r[2] / $pic.Width, $r[3] / $pic.Height)
                    $sw = [int][Math]::Round($r[2] / $s); $sh = [int][Math]::Round($r[3] / $s)
                    $sx = [int][Math]::Floor(($pic.Width - $sw) / 2); $sy = [int][Math]::Floor(($pic.Height - $sh) / 2)
                    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $g.DrawImage($pic, (New-Object Drawing.Rectangle $r[0], $r[1], $r[2], $r[3]), $sx, $sy, $sw, $sh, [Drawing.GraphicsUnit]::Pixel, $wrap)
                    $at = $l.frame
                }
                $k = $l.k
                $g.FillRectangle([Drawing.Brushes]::White, $at[0], $at[1], 34 * $k, 34 * $k)
                $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
                $g.DrawImage($icon, (New-Object Drawing.Rectangle ($at[0] + $k), ($at[1] + $k), (32 * $k), (32 * $k)))
                $canvas.Save((Join-Path $out $name), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $g.Dispose(); $canvas.Dispose() }
        }
        $logoPath = Join-Path $out 'logo.png'
        Remove-Item -LiteralPath $logoPath -Force -ErrorAction SilentlyContinue
        if ($pic -and $art -and ($art.PSObject.Properties.Name -contains 'logo')) {
            # Logo: lo que queda dentro del polígono, sin el color de fondo de la caja (con tolerancia).
            $poly = @($art.logo.polygon)
            $xs = @($poly | ForEach-Object { [int]$_[0] }); $ys = @($poly | ForEach-Object { [int]$_[1] })
            $x0 = ($xs | Measure-Object -Minimum).Minimum; $y0 = ($ys | Measure-Object -Minimum).Minimum
            $lw = ($xs | Measure-Object -Maximum).Maximum - $x0; $lh = ($ys | Measure-Object -Maximum).Maximum - $y0
            $key = $art.logo.key; $kr = [Convert]::ToInt32($key.Substring(0, 2), 16); $kg = [Convert]::ToInt32($key.Substring(2, 2), 16); $kb = [Convert]::ToInt32($key.Substring(4, 2), 16)
            $tol = [int]$art.logo.tolerance
            $logo = New-Object Drawing.Bitmap $lw, $lh, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
            for ($y = 0; $y -lt $lh; $y++) {
                $cross = @(Get-TrPolygonCrossings ($y0 + $y + 0.5) $poly)
                for ($x = 0; $x -lt $lw; $x++) {
                    # Regla par-impar con el centro del píxel.
                    $cx = $x0 + $x + 0.5; $in = $false
                    foreach ($cr in $cross) { if ($cx -lt $cr) { $in = -not $in } }
                    if (-not $in) { continue }
                    $c = $pic.GetPixel($x0 + $x, $y0 + $y)
                    $d = [Math]::Abs([int]$c.R - $kr) + [Math]::Abs([int]$c.G - $kg) + [Math]::Abs([int]$c.B - $kb)
                    if ($d -gt $tol) { $logo.SetPixel($x, $y, $c) }
                }
            }
            $canvas = New-Object Drawing.Bitmap 900, 230, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [Drawing.Graphics]::FromImage($canvas)
            try {
                $g.Clear([Drawing.Color]::Transparent)
                $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $s = [Math]::Min(900 / $lw, 230 / $lh); $w = [int][Math]::Floor($lw * $s); $h = [int][Math]::Floor($lh * $s)
                $g.DrawImage($logo, (New-Object Drawing.Rectangle ([int][Math]::Round((900 - $w) / 2)), ([int][Math]::Round((230 - $h) / 2)), $w, $h), 0, 0, $lw, $lh, [Drawing.GraphicsUnit]::Pixel, $wrap)
                $canvas.Save($logoPath, [Drawing.Imaging.ImageFormat]::Png)
            } finally { $g.Dispose(); $canvas.Dispose(); $logo.Dispose() }
        }
    } finally {
        $icon.Dispose(); $wrap.Dispose()
        if ($pic) { $pic.Dispose() }
    }
    Write-TrLog Info "Artwork de Steam generado en $out"
    $out
}

function Update-TrArtImages {
    <# Genera el artwork de los juegos instalados antes de cerrar Steam. #>
    param([Parameter(Mandatory)][string]$Root)
    foreach ($g in @(Get-TrInstalledGames -Root $Root)) {
        try { [void](New-TrArtImages -Id $g.Id -Root $Root) } catch { Write-TrLog Warn "No se pudo generar el artwork de $($g.Id): $_" }
    }
}

function Install-TrSteamArt {
    <# Copia el artwork de cada juego a userdata\<id>\config\grid con los nombres que espera Steam. No requiere cerrar Steam. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Wanted)
    foreach ($w in @($Wanted)) {
        $id = $script:LastArtIds[$w.appid]
        if (-not $id) { continue }
        $dir = $null
        try { $dir = New-TrArtImages -Id $id -Root $Root } catch { Write-TrLog Warn "No se pudo generar el artwork de ${id}: $_" }
        if (-not $dir) { continue }
        $appid = [uint32]([int64]$w.appid -band 0xFFFFFFFFL)
        foreach ($cfg in @(Get-TrSteamUserConfigDirs)) {
            $grid = Join-Path $cfg 'grid'
            New-Item -ItemType Directory -Force -Path $grid | Out-Null
            foreach ($name in $script:ArtGridNames.Keys) {
                $file = Join-Path $dir $name
                $target = Join-Path $grid ($script:ArtGridNames[$name] -f $appid)
                if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination $target -Force }
                else { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

function Add-TrToSteam {
    <# Escribe los accesos en todos los usuarios de Steam. Steam tiene que estar cerrado. Devuelve los archivos. #>
    param([Parameter(Mandatory)][string]$Root)
    $dirs = @(Get-TrSteamUserConfigDirs)
    if (-not $dirs.Count) { throw (New-TrError 'TR-STM-001') }
    $wanted = @(Get-TrWantedSteamShortcuts -Root $Root)
    $written = @()
    foreach ($d in $dirs) {
        $path = Join-Path $d 'shortcuts.vdf'
        try {
            [void](Update-TrSteamShortcutsFile -Path $path -Wanted @($wanted | ForEach-Object { $c = [ordered]@{}; foreach ($k in $_.Keys) { $c[$k] = $_[$k] }; $c }))
        } catch {
            Remove-Item -LiteralPath "$path.tmp" -Force -ErrorAction SilentlyContinue
            throw (New-TrError 'TR-STM-003' @{ file = $path; detail = $_.Exception.Message } $_.Exception)
        }
        Write-TrLog Info "Accesos de Steam actualizados en $path ($($wanted.Count))"
        $written += $path
    }
    try { Install-TrSteamArt -Root $Root -Wanted $wanted } catch { Write-TrLog Warn "No se pudo copiar el artwork de Steam: $_" }
    $written
}

function Update-TrSteamShortcuts {
    <#
      Tras instalar o desinstalar: actualiza los accesos solo donde ya se habían agregado y solo si Steam está
      cerrado (si está abierto, al cerrarse pisaría el archivo). Devuelve $true si no quedó nada pendiente.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $targets = @(foreach ($d in @(Get-TrSteamUserConfigDirs)) {
        $p = Join-Path $d 'shortcuts.vdf'
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $doc = ConvertFrom-TrVdf ([IO.File]::ReadAllBytes($p))
            if ($doc.Contains('shortcuts') -and @($doc['shortcuts'].Values | Where-Object { Test-TrOurShortcut $_ }).Count) { $p }
        } catch { Write-TrLog Warn "shortcuts.vdf ilegible ($p): $_" }
    })
    if (-not $targets.Count) { return $true }
    if (Test-TrSteamRunning) { return $false }
    $wanted = @(Get-TrWantedSteamShortcuts -Root $Root)
    foreach ($p in $targets) {
        try { [void](Update-TrSteamShortcutsFile -Path $p -Wanted $wanted); Write-TrLog Info "Accesos de Steam actualizados en $p" }
        catch { Write-TrLog Warn "No se pudieron actualizar los accesos de Steam en ${p}: $_"; return $false }
    }
    try { Install-TrSteamArt -Root $Root -Wanted $wanted } catch { Write-TrLog Warn "No se pudo copiar el artwork de Steam: $_" }
    $true
}

Export-ModuleMember -Function Update-TrSteamShortcuts, ConvertFrom-TrVdf, ConvertTo-TrVdf, Get-TrShortcutAppId, Get-TrSteamRoot, Get-TrSteamUserConfigDirs, Test-TrSteamInstalled,
    Test-TrSteamRunning, Stop-TrSteam, Start-TrSteam, Get-TrWantedSteamShortcuts, Update-TrSteamShortcutsFile, Add-TrToSteam, New-TrArtImages, Update-TrArtImages, Install-TrSteamArt
