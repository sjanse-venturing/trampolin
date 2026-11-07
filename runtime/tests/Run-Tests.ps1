<#
  Pruebas automáticas del núcleo de Trampolín Runtime (sin interfaz gráfica).
  Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 [-IsoFolder <carpeta con las .iso>]
  Con -IsoFolder se ejecutan también las pruebas de integración contra las imágenes reales.
  Devuelve código de salida 0 si todo pasa.
#>
param([string]$IsoFolder)

$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
Import-Module (Join-Path $src 'Core\Trampolin.Errors.psm1') -Force
Import-Module (Join-Path $src 'Core\Trampolin.Core.psm1') -Force
Import-Module (Join-Path $src 'Core\Trampolin.Sync.psm1') -Force
Import-Module (Join-Path $src 'Core\Trampolin.Steam.psm1') -Force
Import-Module (Join-Path $src 'Core\Trampolin.Update.psm1') -Force
Add-Type -AssemblyName System.IO.Compression, System.Web.Extensions
Import-TrStrings (Join-Path $src 'data\strings.es.json')

$script:passed = 0; $script:failed = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "  OK   $Name" -ForegroundColor Green }
    catch {
        $script:failed++; Write-Host "  FALLA $Name :: $($_.Exception.Message)" -ForegroundColor Red
        if ($env:TRAMPOLIN_TEST_VERBOSE) { Write-Host (Get-TrErrorInfo $_).Details }
    }
}
function Assert-True { param($Cond, [string]$Msg = 'condición falsa') if (-not $Cond) { throw $Msg } }
function Assert-Throws {
    param([scriptblock]$Body, [string]$Code)
    try { & $Body } catch { $info = Get-TrErrorInfo $_; if ($Code -and $info.Code -ne $Code) { throw "se esperaba $Code y se obtuvo $($info.Code)" }; return }
    throw "se esperaba un error $Code"
}

$tmp = Join-Path $env:TEMP ('trampolin-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Write-Host 'Catálogo'
Test-Case 'games.json tiene los 8 juegos con los campos necesarios' {
    $c = @(Get-TrCatalog)
    Assert-True ($c.Count -eq 8) "hay $($c.Count) juegos"
    foreach ($g in $c) {
        foreach ($f in 'id', 'name', 'age', 'engine', 'iso', 'copy', 'exe', 'icon') { Assert-True ($g.PSObject.Properties.Name -contains $f) "$($g.id) sin '$f'" }
        Assert-True ($g.engine -in 'aces', 'ka-mfc', 'peewee') "$($g.id): motor desconocido"
    }
    Assert-True (@($c.id | Select-Object -Unique).Count -eq 8) 'ids repetidos'
}
Test-Case 'strings.es.json cubre todos los códigos usados' {
    $codes = Select-String -Path (Join-Path $src 'Core\*.psm1'), (Join-Path $src 'UI\*.ps1') -Pattern "TR-[A-Z]{3}-\d{3}" -AllMatches |
        ForEach-Object { $_.Matches.Value } | Select-Object -Unique
    $json = Get-Content -LiteralPath (Join-Path $src 'data\strings.es.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($code in $codes) { Assert-True ($json.errors.PSObject.Properties.Name -contains $code) "falta $code" }
}

Write-Host 'Errores'
Test-Case 'Get-TrErrorInfo reemplaza variables del mensaje' {
    $i = Get-TrErrorInfo (New-TrError 'TR-DSK-001' @{ drive = 'C:'; need = '2 GB'; free = '1 GB' })
    Assert-True ($i.Message -like '*C:*2 GB*1 GB*') $i.Message
}
Test-Case 'Errores desconocidos se muestran como TR-GEN-001' {
    $i = Get-TrErrorInfo ([Exception]::new('algo raro'))
    Assert-True ($i.Code -eq 'TR-GEN-001')
}
Test-Case 'Invoke-TrStep traduce excepciones y ejecuta el rollback' {
    $flag = @{ rolled = $false }
    Assert-Throws { Invoke-TrStep -Name 'prueba' -ErrorCode 'TR-CFG-001' -Action { throw 'x' } -Rollback { $flag.rolled = $true } } 'TR-CFG-001'
    Assert-True $flag.rolled 'no hubo rollback'
}

Write-Host 'Carpeta de instalación'
Test-Case 'Acepta una carpeta temporal' { Assert-True ((Test-TrInstallRoot -Path (Join-Path $tmp 'ok')) -like '*ok') }
Test-Case 'Rechaza rutas demasiado largas (TR-DSK-004)' { Assert-Throws { Test-TrInstallRoot -Path ('C:\' + ('x' * 90)) } 'TR-DSK-004' }
Test-Case 'Rechaza caracteres fuera de la página de códigos (TR-DSK-003)' { Assert-Throws { Test-TrInstallRoot -Path (Join-Path $tmp ([string][char]0x65E5 + [char]0x672C)) } 'TR-DSK-003' }
Test-Case 'Rechaza carpetas de red (TR-DSK-002)' { Assert-Throws { Test-TrInstallRoot -Path '\\servidor\juegos' } 'TR-DSK-002' }

Write-Host 'INI'
Test-Case 'Set-TrIniValues agrega y reemplaza conservando el resto' {
    $p = Join-Path $tmp 'a.ini'
    [IO.File]::WriteAllLines($p, @('[Paths]', 'HDPath=viejo', 'Otra=1', '', '[Video]', 'X=2'))
    Set-TrIniValues -Path $p -Values @{ Paths = @{ HDPath = '{HD}\'; CDPath = 'T:\' }; Nueva = @{ K = 'v' } } -Vars @{ HD = 'C:\J' }
    $t = [IO.File]::ReadAllText($p)
    Assert-True ($t -match 'HDPath=C:\\J\\') 'HDPath'
    Assert-True ($t -match 'Otra=1') 'clave preservada'
    Assert-True ($t -match 'CDPath=T:\\') 'clave nueva'
    Assert-True ($t -match '\[Nueva\]\s+K=v') 'sección nueva'
    Assert-True ($t -match 'X=2') 'otra sección preservada'
}
Test-Case 'Set-TrIniValues escribe en ANSI (los juegos usan APIs "A")' {
    $p = Join-Path $tmp 'b.ini'
    Set-TrIniValues -Path $p -Values @{ S = @{ Nombre = 'Trampolín' } }
    $bytes = [IO.File]::ReadAllBytes($p)
    Assert-True ($bytes -contains 0xED) 'la í no se guardó como byte ANSI 0xED'
}

Write-Host 'Versión instalada'
Test-Case 'Avisa si la instalación es más vieja que esta copia y deja de avisar al actualizar' {
    $root = Join-Path $tmp 'version'
    $app = Join-Path $root 'app'
    $current = Get-TrRuntimeVersion
    Assert-True ($current -is [version]) 'esta copia no informa su versión (falta VERSION)'
    Assert-True ($null -eq (Get-TrOutdatedInstall -Root $root)) 'avisó sin nada instalado'
    New-Item -ItemType Directory -Force -Path (Join-Path $app 'src') | Out-Null
    [IO.File]::WriteAllText((Join-Path $app 'src\Trampolin.ps1'), '#')
    $old = Get-TrOutdatedInstall -Root $root
    Assert-True ($old -and $null -eq $old.Installed -and $old.Newer -eq $current -and $old.SourceExists) 'no avisó con una instalación sin VERSION'
    [IO.File]::WriteAllText((Join-Path $app 'VERSION'), "1.0.8`n")
    Assert-True ((Get-TrOutdatedInstall -Root $root).Installed -eq [version]'1.0.8') 'no avisó con una instalación 1.0.8'
    [IO.File]::WriteAllText((Join-Path $app 'VERSION'), "99.0.0`n")
    Assert-True ($null -eq (Get-TrOutdatedInstall -Root $root)) 'avisó con una instalación más nueva'
    Remove-Item -LiteralPath (Join-Path $app 'VERSION')
    Install-TrRuntimeFiles -Root $root | Out-Null
    Assert-True ((Get-TrRuntimeVersion -AppRoot $app) -eq $current) 'la instalación no guardó su versión'
    Assert-True ($null -eq (Get-TrOutdatedInstall -Root $root)) 'siguió avisando después de actualizar'
}

Test-Case 'Desde un acceso directo (la instalada) avisa de la copia más nueva anotada y se actualiza desde ella' {
    $core = Get-Module Trampolin.Core
    $self = & $core { $script:AppRoot }
    $root = Join-Path $tmp 'version2'
    $app = Join-Path $root 'app'
    New-Item -ItemType Directory -Force -Path (Join-Path $app 'src') | Out-Null
    [IO.File]::WriteAllText((Join-Path $app 'src\Trampolin.ps1'), '#')
    [IO.File]::WriteAllText((Join-Path $app 'VERSION'), "1.0.8`n")
    $cfg = [ordered]@{ newerCopy = $null }
    Assert-True (Register-TrRuntimeCopy -Config $cfg -Root $root) 'esta copia no se anotó'
    Assert-True (-not (Register-TrRuntimeCopy -Config $cfg -Root $root)) 'se volvió a anotar sin cambios'
    $cfg.newerCopy.declined = $true
    Assert-True (-not (Register-TrRuntimeCopy -Config $cfg -Root $root)) 'abrir la misma copia borró el «no actualizar»'
    $cfg.newerCopy.declined = $false
    try {
        & $core { param($p) $script:AppRoot = $p } $app          # ahora "somos" la instalada
        Assert-True (-not (Register-TrRuntimeCopy -Config $cfg -Root $root)) 'la instalada se anotó a sí misma'
        $old = Get-TrOutdatedInstall -Root $root -Config $cfg
        Assert-True ($old -and $old.Installed -eq [version]'1.0.8' -and (Test-TrSamePath $old.Source $self) -and $old.SourceExists -and -not $old.Declined) 'la instalada no avisó'
        Assert-True ($null -eq (Get-TrOutdatedInstall -Root $root -Config ([ordered]@{ newerCopy = $null }))) 'avisó sin nada anotado'
        $gone = [ordered]@{ newerCopy = [ordered]@{ version = '9.9.9'; path = (Join-Path $tmp 'borrada'); declined = $false } }
        $old = Get-TrOutdatedInstall -Root $root -Config $gone
        Assert-True ($old -and -not $old.SourceExists -and $old.Newer -eq [version]'9.9.9') 'no detectó la copia borrada'
    } finally { & $core { param($p) $script:AppRoot = $p } $self }
    Install-TrRuntimeFiles -Root $root -Source $self | Out-Null
    Assert-True ((Get-TrRuntimeVersion -AppRoot $app) -eq (Get-TrRuntimeVersion)) 'no se actualizó desde la copia anotada'
    & $core { param($p) $script:AppRoot = $p } $app
    try { Assert-True ($null -eq (Get-TrOutdatedInstall -Root $root -Config $cfg)) 'siguió avisando después de actualizar' }
    finally { & $core { param($p) $script:AppRoot = $p } $self }
}

Write-Host 'Actualizaciones (versiones publicadas en GitHub, mismas reglas que Linux)'
Set-TrUpdateStateFile (Join-Path $tmp 'update-state.json')
$env:TRAMPOLIN_NO_UPDATE = $null
$env:TRAMPOLIN_UPDATE_URL = 'https://x/latest'
function New-TestPackage {
    <# ZIP mínimo con la forma del de build.ps1. $Extra: ruta relativa (o completa si empieza con '../') → texto. #>
    param([string]$Version, [hashtable]$Extra = @{}, [string[]]$Skip = @())
    $prefix = "TrampolinRuntime-$Version/"
    $files = [ordered]@{}
    foreach ($r in 'VERSION', 'trampolin.sh', 'Trampolin.cmd', 'linux/main.py', 'src/Trampolin.ps1', 'src/data/games.json',
        'native/bin/trlaunch.exe', 'native/bin/trhook.dll', 'native/bin/WING32.DLL') { if ($r -notin $Skip) { $files[$r] = 'x' } }
    if ($files.Contains('VERSION')) { $files['VERSION'] = "$Version`n" }
    foreach ($k in $Extra.Keys) { $files[$k] = $Extra[$k] }
    $ms = New-Object IO.MemoryStream
    $z = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($k in $files.Keys) {
        $name = $(if ($k.StartsWith('../')) { $k } else { $prefix + $k })
        $w = New-Object IO.StreamWriter($z.CreateEntry($name).Open())
        $w.Write($files[$k]); $w.Dispose()
    }
    $z.Dispose()
    , $ms.ToArray()
}
function New-TestGitHub {
    <# Transporte falso: publica $Version con $Package (y la suma $Sha) y anota las llamadas. #>
    param([string]$Version, [byte[]]$Package, [string]$Sha, [hashtable]$Extra = @{})
    $gh = @{ calls = [Collections.ArrayList]::new(); routes = @{} }
    if (-not $Sha) { $Sha = Get-TrSha256 $Package }
    $name = "TrampolinRuntime-$Version.zip"
    $gh.routes["https://x/$name"] = $Package
    $gh.routes["https://x/$name.sha256"] = [Text.Encoding]::ASCII.GetBytes("$Sha  $name`n")
    $rel = @{ tag_name = "v$Version"; body = "### Agregado`n- Algo nuevo"; html_url = 'https://x/r'
        assets = @(@{ name = $name; browser_download_url = "https://x/$name" }, @{ name = "$name.sha256"; browser_download_url = "https://x/$name.sha256" }) }
    foreach ($k in $Extra.Keys) { $rel[$k] = $Extra[$k] }
    $gh.routes['https://x/latest'] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-TrJsonText $rel))
    $gh.transport = {
        param($Method, $Url, $Headers, $Body, $Timeout)
        [void]$gh.calls.Add($Url)
        if ($gh.routes.ContainsKey($Url)) { @{ Status = 200; Body = $gh.routes[$Url] } } else { @{ Status = 404; Body = [byte[]]@() } }
    }.GetNewClosure()
    $gh
}
function Reset-TestUpdateState { Remove-Item -LiteralPath (Join-Path $tmp 'update-state.json') -ErrorAction SilentlyContinue }
function New-TestInstall {
    param([string]$Name, [string]$Version = '1.2.0')
    $root = Join-Path $tmp $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'app') | Out-Null
    if ($Version) { [IO.File]::WriteAllText((Join-Path $root 'app\VERSION'), "$Version`n") }
    $root
}

Test-Case 'Versiones: v1.2 = 1.2.0, 1.10 > 1.9, no acepta sufijos' {
    Assert-True ((ConvertTo-TrVersion 'v1.2') -eq [version]'1.2.0') 'v1.2'
    Assert-True ((ConvertTo-TrVersion '1.10.0') -gt (ConvertTo-TrVersion '1.9.9')) '1.10 > 1.9'
    Assert-True ($null -eq (ConvertTo-TrVersion '1.2.0-beta')) 'aceptó un sufijo'
}
Test-Case 'Solo ofrece versiones publicadas con paquete y más nuevas que la instalada' {
    $root = New-TestInstall 'upd1'
    $app = Join-Path $root 'app'
    Reset-TestUpdateState
    $gh = New-TestGitHub '1.3.0' (New-TestPackage '1.3.0')
    $r = Get-TrPendingUpdate -Root $root -Transport $gh.transport -AppRoot $app
    Assert-True ($r -and $r.Version -eq '1.3.0' -and $r.Notes -like '*Algo nuevo*') 'no ofreció la 1.3.0'
    Reset-TestUpdateState
    $gh = New-TestGitHub '1.2.0' (New-TestPackage '1.2.0')
    Assert-True ($null -eq (Get-TrPendingUpdate -Root $root -Transport $gh.transport -AppRoot $app)) 'ofreció la misma versión'
    Reset-TestUpdateState
    $gh = New-TestGitHub '1.3.0' (New-TestPackage '1.3.0') -Extra @{ prerelease = $true }
    Assert-True ($null -eq (Get-TrLatestRelease -Force -Transport $gh.transport)) 'aceptó una versión de prueba'
    $gh = New-TestGitHub '1.3.0' (New-TestPackage '1.3.0') -Extra @{ assets = @() }
    Assert-True ($null -eq (Get-TrLatestRelease -Force -Transport $gh.transport)) 'aceptó una versión sin paquete'
    Remove-Item -LiteralPath (Join-Path $app 'VERSION')
    Reset-TestUpdateState
    $gh = New-TestGitHub '1.3.0' (New-TestPackage '1.3.0')
    Assert-True ((Get-TrPendingUpdate -Root $root -Transport $gh.transport -AppRoot $app).Version -eq '1.3.0') 'no ofreció actualizar una instalación sin VERSION'
}
Test-Case 'Una copia que no es la instalada no consulta' {
    $root = New-TestInstall 'upd2'
    Reset-TestUpdateState
    $gh = New-TestGitHub '1.3.0' (New-TestPackage '1.3.0')
    Assert-True ($null -eq (Get-TrPendingUpdate -Root $root -Transport $gh.transport -AppRoot (Join-Path $tmp 'otra-copia'))) 'ofreció actualizar'
    Assert-True ($gh.calls.Count -eq 0) 'consultó GitHub'
}
Test-Case 'Consulta como mucho cada minCheckMinutes y sin red usa la última conocida' {
    Reset-TestUpdateState
    $gh = New-TestGitHub '1.3.0' (New-TestPackage '1.3.0')
    $now = [DateTime]::new(2026, 11, 7, 12, 0, 0, [DateTimeKind]::Utc)
    Assert-True ((Get-TrLatestRelease -Now $now -Transport $gh.transport).Version -eq '1.3.0') 'primera consulta'
    Assert-True ((Get-TrLatestRelease -Now $now.AddMinutes(5) -Transport $gh.transport).Version -eq '1.3.0') 'segunda consulta'
    Assert-True ($gh.calls.Count -eq 1) "consultó $($gh.calls.Count) veces"
    $offline = { param($Method, $Url, $Headers, $Body, $Timeout) throw (New-Object Net.Http.HttpRequestException('sin red')) }
    Assert-True ((Get-TrLatestRelease -Now $now.AddHours(1) -Transport $offline).Version -eq '1.3.0') 'sin red no devolvió la última conocida'
}
Test-Case 'Instala la versión nueva en <instalación>\app sin tocar las partidas' {
    $root = New-TestInstall 'upd3'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'games\FG') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'games\FG\plyr0001.ini'), '[x]')
    Reset-TestUpdateState
    $gh = New-TestGitHub '1.3.0' (New-TestPackage '1.3.0' -Extra @{ 'src/Trampolin.ps1' = '# nuevo' })
    $rel = Get-TrLatestRelease -Force -Transport $gh.transport
    $steps = [Collections.ArrayList]::new()
    $v = Install-TrUpdate -Release $rel -Root $root -Transport $gh.transport -OnProgress { param($p, $m) [void]$steps.Add($p) }
    Assert-True ($v -eq '1.3.0') "devolvió $v"
    Assert-True ((Get-TrRuntimeVersion -AppRoot (Join-Path $root 'app')) -eq [version]'1.3.0') 'no quedó la 1.3.0'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'app\src\Trampolin.ps1')) -eq '# nuevo') 'no se copió el programa nuevo'
    Assert-True (Test-Path (Join-Path $root 'games\FG\plyr0001.ini')) 'se borró una partida'
    Assert-True ($steps[$steps.Count - 1] -eq 100) 'el progreso no llegó a 100'
}
foreach ($bad in @(
        @{ name = 'suma de verificación incorrecta'; pkg = { New-TestPackage '1.3.0' }; sha = ('0' * 64) },
        @{ name = 'rutas fuera del paquete'; pkg = { New-TestPackage '1.3.0' -Extra @{ '../evil.cmd' = 'x' } }; sha = $null },
        @{ name = 'paquete de otra versión'; pkg = { New-TestPackage '1.3.0' -Extra @{ VERSION = "1.1.0`n" } }; sha = $null },
        @{ name = 'paquete incompleto'; pkg = { New-TestPackage '1.3.0' -Skip 'native/bin/trhook.dll' }; sha = $null })) {
    Test-Case "Rechaza la actualización: $($bad.name)" {
        $root = New-TestInstall ('upd-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        Reset-TestUpdateState
        $gh = New-TestGitHub '1.3.0' (& $bad.pkg) $bad.sha
        $rel = Get-TrLatestRelease -Force -Transport $gh.transport
        Assert-Throws { Install-TrUpdate -Release $rel -Root $root -Transport $gh.transport } 'TR-UPD-002'
        Assert-True ((Get-TrRuntimeVersion -AppRoot (Join-Path $root 'app')) -eq [version]'1.2.0') 'cambió la instalación'
        Assert-True (-not (Test-Path (Join-Path $root 'app\src'))) 'copió archivos'
    }
}
Test-Case 'Si no se puede descargar avisa con TR-UPD-001' {
    $root = New-TestInstall 'upd4'
    Reset-TestUpdateState
    $gh = New-TestGitHub '1.3.0' (New-TestPackage '1.3.0')
    $rel = Get-TrLatestRelease -Force -Transport $gh.transport
    $gh.routes.Remove('https://x/TrampolinRuntime-1.3.0.zip')
    Assert-Throws { Install-TrUpdate -Release $rel -Root $root -Transport $gh.transport } 'TR-UPD-001'
}
$env:TRAMPOLIN_UPDATE_URL = $null

Write-Host 'Partidas (exportar / importar, mismo formato que Linux)'
function New-FakeInstall {
    <# Instalación mínima: manifiesto y el exe de cada juego, sin copiar discos. #>
    param([string]$Name, [string[]]$Ids)
    $root = Join-Path $tmp $Name
    $m = [ordered]@{ version = 1; games = [ordered]@{} }
    foreach ($id in $Ids) {
        $hd = Join-Path $root "games\$id"
        New-Item -ItemType Directory -Force -Path $hd | Out-Null
        [IO.File]::WriteAllText((Join-Path $hd (Get-TrGame $id).exe), 'MZ')
        $m.games[$id] = [ordered]@{ id = $id; dataMode = 'copy'; hd = $hd; cd = $null; isoPath = ''; label = '' }
    }
    Save-TrManifest -Root $root -Manifest $m
    $root
}
Test-Case 'Exportar todas e importar en otra instalación' {
    $a = New-FakeInstall 'savesA' @('KG', 'PRSCHOOL')
    [IO.File]::WriteAllText((Join-Path $a 'games\KG\PLYR0001.INI'), "[Player]`r`nName=Ana")
    [IO.File]::WriteAllText((Join-Path $a 'games\KG\volumes.sav'), 'v')
    [IO.File]::WriteAllText((Join-Path $a 'games\KG\KG.INI'), 'no es partida')
    [IO.File]::WriteAllText((Join-Path $a 'games\PRSCHOOL\ST1.DAT'), 'alumno')
    $zip = Export-TrAllSaves -Root $a -Destination (Join-Path $tmp 'out')
    Assert-True ($zip -and (Split-Path -Leaf $zip) -like 'trampolin-partidas-*.zip') "nombre del zip: $zip"
    $content = Read-TrSavesZip -Zip $zip
    Assert-True ($content.Games['KG'].Count -eq 2) 'KG debería tener 2 archivos (KG.INI no es partida)'
    $b = New-FakeInstall 'savesB' @('KG')
    [IO.File]::WriteAllText((Join-Path $b 'games\KG\plyr0001.ini'), 'vieja')
    $r = Import-TrSaves -Root $b -Zip $zip -BackupDestination (Join-Path $tmp 'bk')
    Assert-True (@($r.Imported['KG']).Count -eq 2) 'no importó KG'
    Assert-True ($r.Skipped['PRSCHOOL'] -eq 'no está instalado') 'PRSCHOOL debería saltearse'
    Assert-True (@($r.Backups).Count -eq 1) 'no guardó la copia de las partidas anteriores'
    $names = @(Get-ChildItem (Join-Path $b 'games\KG') -Filter 'plyr*' | ForEach-Object Name)
    Assert-True ($names.Count -eq 1 -and $names[0] -ceq 'PLYR0001.INI') "archivos: $($names -join ',')"
    Assert-True ([IO.File]::ReadAllText((Join-Path $b 'games\KG\PLYR0001.INI')) -match 'Ana') 'contenido'
}
Test-Case 'Importa un zip de un juego del formato anterior (sin trampolin-saves.json)' {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $src = Join-Path $tmp 'legacy'; New-Item -ItemType Directory -Force -Path $src | Out-Null
    [IO.File]::WriteAllText((Join-Path $src 'PLYR0002.INI'), 'Beto')
    $zip = Join-Path $tmp 'KG-20260101-120000.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    $b = New-FakeInstall 'savesC' @('KG')
    $r = Import-TrSaves -Root $b -Zip $zip -BackupDestination (Join-Path $tmp 'bk')
    Assert-True (Test-Path (Join-Path $b 'games\KG\PLYR0002.INI')) 'no se importó'
}
Test-Case 'Rechaza zips que no son partidas y entradas peligrosas (TR-SAV-001)' {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $tmp 'otro.zip'
    $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
    try {
        foreach ($n in @('../evil.ini', 'KG/../../x.sav', 'KG/sub/PLYR1.INI', 'KG/KG.EXE')) {
            $w = New-Object IO.StreamWriter($archive.CreateEntry($n).Open()); $w.Write('x'); $w.Dispose()
        }
    } finally { $archive.Dispose() }
    Assert-Throws { Read-TrSavesZip -Zip $zip } 'TR-SAV-001'
}

Write-Host 'Sincronización de partidas (mismo formato y reglas que Linux)'
$env:TRAMPOLIN_SAVES_DIR = Join-Path $tmp 'copias'
$syncModule = Get-Module Trampolin.Sync
function Use-Device { param([string]$Name) & $syncModule { param($p) $script:StateFile = $p } (Join-Path $tmp "sync-state-$Name.json") }
function Set-Save {
    param([string]$Root, [string]$Id, [string]$Name, [string]$Text, [string]$When)
    $p = Join-Path $Root "games\$Id\$Name"
    [IO.File]::WriteAllText($p, $Text)
    (Get-Item -LiteralPath $p).LastWriteTimeUtc = ConvertFrom-TrSyncIso $When
    $p
}
function New-TestZip {
    <# Zip de prueba: $Entries = @{ nombre = byte[] }; $Manifest = hashtable o $null. #>
    param([hashtable]$Entries, $Manifest)
    $ms = New-Object IO.MemoryStream
    $a = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        if ($Manifest) {
            $w = New-Object IO.StreamWriter($a.CreateEntry('trampolin-saves.json').Open())
            $w.Write((ConvertTo-TrJsonText $Manifest)); $w.Dispose()
        }
        foreach ($k in $Entries.Keys) { $s = $a.CreateEntry($k).Open(); $s.Write($Entries[$k], 0, $Entries[$k].Length); $s.Dispose() }
    } finally { $a.Dispose() }
    , $ms.ToArray()
}
function New-TestManifest {
    param([string]$Id, [hashtable]$Entries, [string]$Updated = '2026-01-01T10:00:00Z', [hashtable]$Over = @{})
    $files = @(foreach ($k in $Entries.Keys) { @{ name = $k; size = $Entries[$k].Length; sha256 = (Get-TrSha256 $Entries[$k]); mtime = $Updated } })
    $m = @{ format = 2; createdAt = $Updated; platform = 'linux'; games = @($Id); gameId = $Id; updatedAt = $Updated; deviceId = 'abc'; deviceName = 'Deck'
        bundleHash = (Get-TrBundleHash $files); files = $files }
    foreach ($k in $Over.Keys) { $m[$k] = $Over[$k] }
    $m
}
function Assert-Rejected {
    param([byte[]]$Data, [string]$Id = 'FG')
    try { [void](Test-TrSyncBundle -Id $Id -Data $Data) } catch { $i = Get-TrErrorInfo $_; if ($i.Code -ne 'TR-SYN-005') { throw "se esperaba TR-SYN-005 y se obtuvo $($i.Code): $($i.Details)" }; return $i.Message }
    throw 'se esperaba TR-SYN-005'
}
$b = { param([string]$s) , [Text.Encoding]::ASCII.GetBytes($s) }
$exeBytes = [byte[]](@(0x4D, 0x5A) + @(0) * 0x3A + @(0x40, 0, 0, 0, 0x50, 0x45, 0, 0))

Test-Case 'Un paquete válido pasa la validación (también uno hecho en Linux)' {
    $e = @{ 'PLYR0001.INI' = (& $b "[1G Player]`r`nName=955D,D57E`r`n"); 'volumes.sav' = [byte[]](1, 2, 3) }
    $r = Test-TrSyncBundle -Id 'FG' -Data (New-TestZip $e (New-TestManifest 'FG' $e))
    Assert-True ($r.Contents.Count -eq 2) 'contenido'
    $r = Test-TrSyncBundle -Id 'FG' -Data ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\sync-linux-FG.zip')))
    Assert-True ($r.Manifest['platform'] -eq 'linux' -and $r.Contents.Contains('PLYR0001.INI')) 'paquete de Linux'
}
Test-Case 'Rechaza paquetes peligrosos o manipulados (TR-SYN-005)' {
    $g = @{ 'PLYR0001.INI' = (& $b "[P]`r`nName=A`r`n"); 'volumes.sav' = [byte[]](1, 2, 3) }
    $plus = { param($extra) $h = @{}; foreach ($k in $g.Keys) { $h[$k] = $g[$k] }; foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }; $h }
    $cases = [ordered]@{
        'ruta'          = New-TestZip (& $plus @{ '../x.sav' = [byte[]](1) }) (New-TestManifest 'FG' $g)
        'carpeta'       = New-TestZip @{ 'FG/PLYR0001.INI' = (& $b '[a]') } (New-TestManifest 'FG' @{ 'FG/PLYR0001.INI' = (& $b '[a]') })
        'otro juego'    = New-TestZip $g (New-TestManifest 'KG' $g)
        'no es partida' = New-TestZip @{ 'FG.EXE' = [byte[]](1) } (New-TestManifest 'FG' @{ 'FG.EXE' = [byte[]](1) })
        'sin manifiesto' = New-TestZip $g $null
        'archivo extra' = New-TestZip (& $plus @{ 'ka.atr' = [byte[]](1) }) (New-TestManifest 'FG' $g)
        'hash'          = New-TestZip @{ 'PLYR0001.INI' = $g['PLYR0001.INI']; 'volumes.sav' = [byte[]](9) } (New-TestManifest 'FG' $g)
        'futuro'        = New-TestZip $g (New-TestManifest 'FG' $g '2099-01-01T00:00:00Z')
        'clave extra'   = New-TestZip $g (New-TestManifest 'FG' $g -Over @{ extra = 1 })
        'ejecutable'    = New-TestZip @{ 'volumes.sav' = $exeBytes } (New-TestManifest 'FG' @{ 'volumes.sav' = $exeBytes })
        'zip adentro'   = New-TestZip @{ 'volumes.sav' = [byte[]](0x50, 0x4B, 3, 4, 1) } (New-TestManifest 'FG' @{ 'volumes.sav' = [byte[]](0x50, 0x4B, 3, 4, 1) })
        'ini binario'   = New-TestZip @{ 'PLYR0001.INI' = [byte[]](0x5B, 0x61, 0x5D, 0x0D, 0x0A, 0, 1) } (New-TestManifest 'FG' @{ 'PLYR0001.INI' = [byte[]](0x5B, 0x61, 0x5D, 0x0D, 0x0A, 0, 1) })
        'ini raro'      = New-TestZip @{ 'PLYR0001.INI' = (& $b '<script>') } (New-TestManifest 'FG' @{ 'PLYR0001.INI' = (& $b '<script>') })
        'bomba'         = New-TestZip @{ 'volumes.sav' = (New-Object byte[] (2MB)) } (New-TestManifest 'FG' @{ 'volumes.sav' = (New-Object byte[] (2MB)) })
        'no zip'        = (& $b 'hola')
    }
    foreach ($k in $cases.Keys) { try { [void](Assert-Rejected $cases[$k]) } catch { throw "caso '$k': $($_.Exception.Message)" } }
    $many = @{}; for ($i = 0; $i -lt 70; $i++) { $many['PLYR{0:D4}.INI' -f $i] = (& $b '[a]') }
    Assert-True ((Assert-Rejected (New-TestZip $many (New-TestManifest 'FG' $many))) -like '*demasiados*') 'demasiados archivos'
    $two = New-Object Collections.Hashtable([StringComparer]::Ordinal); $two['ka.atr'] = [byte[]](1); $two['KA.ATR'] = [byte[]](2)
    $dup = New-TestZip $two (New-TestManifest 'FG' @{ 'ka.atr' = [byte[]](1) })
    Assert-True ((Assert-Rejected $dup) -like '*repetidos*') 'nombres repetidos por mayúsculas'
    $mz = [byte[]](0x4D, 0x5A, 0, 1, 2, 3)
    [void](Test-TrSyncBundle -Id 'FG' -Data (New-TestZip @{ 'volumes.sav' = $mz } (New-TestManifest 'FG' @{ 'volumes.sav' = $mz })))
}
Test-Case 'Carpeta: la partida más reciente gana y viaja entre equipos' {
    $a = New-FakeInstall 'syncA' @('FG', '4G'); $bb = New-FakeInstall 'syncB' @('FG', '4G')
    $cloud = Join-Path $tmp 'nube'; New-Item -ItemType Directory -Force -Path $cloud | Out-Null
    $ca = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = $cloud; deviceId = ('a' * 32); deviceName = 'PC' } }
    $cb = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = $cloud; deviceId = ('b' * 32); deviceName = 'Deck' } }
    Use-Device 'a'
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[1G Player]`r`nName=Ana`r`n" '2026-01-01T10:00:00Z')
    Assert-True ((Sync-TrAfterPlay -Id 'FG' -Root $a -Config $ca).Action -eq 'uploaded') 'no subió'
    Assert-True ((Sync-TrAfterPlay -Id 'FG' -Root $a -Config $ca).Action -eq 'same') 'debería estar al día'
    Use-Device 'b'
    $r = Sync-TrBeforePlay -Id 'FG' -Root $bb -Config $cb
    Assert-True ($r.Action -eq 'downloaded') "acción: $($r.Action)"
    $p = Join-Path $bb 'games\FG\PLYR0001.INI'
    Assert-True ([IO.File]::ReadAllText($p) -match 'Ana') 'contenido'
    Assert-True ((ConvertTo-TrSyncIso (Get-Item $p).LastWriteTimeUtc) -eq '2026-01-01T10:00:00Z') 'fecha'
    [void](Set-Save $bb 'FG' 'PLYR0001.INI' "[1G Player]`r`nName=Ana`r`nModule00=1`r`n" '2026-01-02T10:00:00Z')
    Assert-True ((Sync-TrAfterPlay -Id 'FG' -Root $bb -Config $cb).Action -eq 'uploaded') 'B no subió'
    Use-Device 'a'
    $r = Sync-TrBeforePlay -Id 'FG' -Root $a -Config $ca
    Assert-True ($r.Action -eq 'downloaded' -and $r.Backup -and (Test-Path $r.Backup)) 'A no bajó la de B o no guardó copia'
    # Conflicto: B juega sin red después que A.
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`nName=A3`r`n" '2026-01-03T10:00:00Z')
    [void](Sync-TrAfterPlay -Id 'FG' -Root $a -Config $ca)
    Use-Device 'b'
    [void](Set-Save $bb 'FG' 'PLYR0001.INI' "[P]`r`nName=B4`r`n" '2026-01-04T10:00:00Z')
    $r = Sync-TrAfterPlay -Id 'FG' -Root $bb -Config $cb
    Assert-True ($r.Action -eq 'uploaded' -and $r.Conflict -like '*FG-conflicto-PC-*') "conflicto: $($r.Conflict)"
    Assert-True ((Read-TrSavesZip -Zip $r.Conflict).Games['FG'].Contains('PLYR0001.INI')) 'la copia en conflicto no se puede importar'
    # La local más nueva no se pisa al abrir; la remota más nueva no se pisa al cerrar.
    Use-Device 'a'
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`nName=A5`r`n" '2026-01-05T10:00:00Z')
    Assert-True ((Sync-TrBeforePlay -Id 'FG' -Root $a -Config $ca).Action -eq 'local-newer') 'local más nueva'
    Assert-True (@(Get-TrSyncStatus -Root $a | Where-Object { $_.Id -eq 'FG' -and $_.Pending }).Count -eq 1) 'debería quedar pendiente'
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`nName=A0`r`n" '2026-01-01T09:00:00Z')
    Assert-True ((Sync-TrAfterPlay -Id 'FG' -Root $a -Config $ca).Action -eq 'remote-newer') 'no debe pisar una más nueva'
}
Test-Case 'Carpeta: no sincroniza el INI de configuración de PEEWEE' {
    $a = Join-Path $tmp 'syncA'; $bb = Join-Path $tmp 'syncB'
    $ca = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = (Join-Path $tmp 'nube'); deviceId = ('a' * 32); deviceName = 'PC' } }
    Use-Device 'a'
    [void](Set-Save $a '4G' 'SAVE1.SAV' 's' '2026-01-01T10:00:00Z')
    [void](Set-Save $a '4G' '4G.INI' "[Hardware]`r`nResourceDirectory=M:\`r`n" '2026-01-01T10:00:00Z')
    [void](Sync-TrAfterPlay -Id '4G' -Root $a -Config $ca)
    $names = @((Test-TrSyncBundle -Id '4G' -Data ([IO.File]::ReadAllBytes((Join-Path $tmp 'nube\Trampolin-sync\4G.zip')))).Contents.Keys)
    Assert-True ($names.Count -eq 1 -and $names[0] -eq 'SAVE1.SAV') "archivos: $($names -join ',')"
    Use-Device 'b'
    [void](Set-Save $bb '4G' '4G.INI' 'propio' '2025-01-01T10:00:00Z')
    [void](Sync-TrBeforePlay -Id '4G' -Root $bb -Config $ca)
    Assert-True ([IO.File]::ReadAllText((Join-Path $bb 'games\4G\4G.INI')) -eq 'propio') 'pisó el INI del equipo'
}
Test-Case 'Carpeta: un paquete inválido frena el juego pero no impide guardar' {
    $a = New-FakeInstall 'syncC' @('FG')
    $cloud = Join-Path $tmp 'nube2'; New-Item -ItemType Directory -Force -Path (Join-Path $cloud 'Trampolin-sync') | Out-Null
    $c = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = $cloud; deviceId = ('c' * 32); deviceName = 'PC' } }
    $e = @{ 'PLYR0001.INI' = $exeBytes }
    [IO.File]::WriteAllBytes((Join-Path $cloud 'Trampolin-sync\FG.zip'), (New-TestZip $e (New-TestManifest 'FG' $e)))
    Use-Device 'c'
    Assert-Throws { Sync-TrBeforePlay -Id 'FG' -Root $a -Config $c } 'TR-SYN-005'
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`nName=A`r`n" '2026-01-01T10:00:00Z')
    Assert-True ((Sync-TrAfterPlay -Id 'FG' -Root $a -Config $c).Action -eq 'uploaded') 'no reemplazó el paquete inválido'
    Assert-True ((Sync-TrBeforePlay -Id 'FG' -Root $a -Config $c).Action -eq 'same') 'quedó distinto'
}
Test-Case 'Propone una carpeta para sincronizar (la de un programa de sincronización o la de partidas)' {
    $sg = Get-TrSuggestedSyncFolder
    Assert-True ($sg.Path) 'no propuso nada'
    Assert-True (($sg.Source -and (Test-Path -LiteralPath $sg.Path)) -or (-not $sg.Source -and $sg.Path -eq (Get-TrSavesFolder))) "propuesta: $($sg.Path) ($($sg.Source))"
}
Test-Case 'Carpeta inexistente: TR-SYN-002 y queda pendiente' {
    $a = Join-Path $tmp 'syncC'
    $c = [ordered]@{ sync = [ordered]@{ mode = 'folder'; folder = (Join-Path $tmp 'no-existe'); deviceId = ('c' * 32); deviceName = 'PC' } }
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`nName=Z`r`n" '2026-02-01T10:00:00Z')
    Assert-Throws { Sync-TrAfterPlay -Id 'FG' -Root $a -Config $c } 'TR-SYN-002'
    Assert-True (@(Get-TrSyncStatus -Root $a | Where-Object { $_.Id -eq 'FG' -and $_.Pending }).Count -eq 1) 'no quedó pendiente'
}
Test-Case 'El paquete de Windows coincide con el fixture que valida Linux' {
    # tests\fixtures\sync-windows-FG.zip lo genera esta versión; test_linux.py lo valida con Python.
    $r = Test-TrSyncBundle -Id 'FG' -Data ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\sync-windows-FG.zip')))
    Assert-True ($r.Manifest['platform'] -eq 'windows') 'plataforma'
}

function New-FakeGoogle {
    <# Transporte HTTP falso que imita OAuth y Drive. $State.fail: códigos a devolver; $State.down: sin red. #>
    $state = @{ files = @{}; fail = New-Object Collections.ArrayList; tokensOk = $true; down = $false }
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $reply = { param($status, $obj) @{ Status = $status; Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-TrJsonText $obj)) } }
    $transport = {
        param($Method, $Url, $Headers, $Body, $Timeout)
        if ($state.down) { throw (New-Object Net.Http.HttpRequestException('No se puede resolver el nombre remoto')) }
        $u = [Uri]$Url
        $form = $(if ($Body) { [Text.Encoding]::ASCII.GetString($Body) } else { '' })
        switch ($u.AbsolutePath) {
            '/device/code' { return (& $reply 200 @{ device_code = 'DEV'; user_code = 'ABCD-EFGH'; verification_url = 'https://www.google.com/device'; interval = 1; expires_in = 600 }) }
            '/token' {
                if ($form -like '*device_code*') {
                    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"email":"ana@example.com"}')).TrimEnd('=')
                    return (& $reply 200 @{ access_token = 'AT'; refresh_token = 'RT'; expires_in = 3600; id_token = "x.$payload.y" })
                }
                if (-not $state.tokensOk) { return (& $reply 400 @{ error = 'invalid_grant'; error_description = 'Token has been expired or revoked.' }) }
                return (& $reply 200 @{ access_token = 'AT'; expires_in = 3600 })
            }
            '/revoke' { return (& $reply 200 @{}) }
        }
        if ($Headers['Authorization'] -ne 'Bearer AT') { return (& $reply 401 @{ error = @{ message = 'Invalid Credentials' } }) }
        if ($state.fail.Count) {
            $code = $state.fail[0]; $state.fail.RemoveAt(0)
            return (& $reply $code @{ error = @{ message = 'falla simulada'; errors = @(@{ reason = $(if ($code -eq 403) { 'storageQuotaExceeded' } else { 'backendError' }) }) } })
        }
        if ($u.AbsolutePath -eq '/drive/v3/files' -and $Method -eq 'GET') {
            return (& $reply 200 @{ files = @($state.files.Keys | ForEach-Object { @{ id = $_; name = $state.files[$_].name; appProperties = $state.files[$_].appProperties } }) })
        }
        if ($u.AbsolutePath -like '/drive/v3/files/*' -and $Method -eq 'GET') {
            return @{ Status = 200; Body = $state.files[$u.Segments[-1]].data }
        }
        if ($u.AbsolutePath -like '/upload/drive/v3/files*') {
            $ct = $Headers['Content-Type']; $boundary = $ct.Substring($ct.IndexOf('boundary=') + 9)
            $text = [Text.Encoding]::GetEncoding(28591).GetString($Body)
            $parts = $text.Split(@("--$boundary"), [StringSplitOptions]::None)
            $meta = $js.DeserializeObject($parts[1].Substring($parts[1].IndexOf("`r`n`r`n") + 4).TrimEnd("`r", "`n"))
            $zipText = $parts[2].Substring($parts[2].IndexOf("`r`n`r`n") + 4); $zipText = $zipText.Substring(0, $zipText.Length - 2)
            $id = $(if ($Method -eq 'PATCH') { $u.Segments[-1] } else { 'id' + ($state.files.Count + 1) })
            if ($Method -eq 'POST' -and -not ($meta.ContainsKey('parents'))) { throw 'faltó parents=appDataFolder' }
            $state.files[$id] = @{ name = $meta['name']; appProperties = $meta['appProperties']; data = [Text.Encoding]::GetEncoding(28591).GetBytes($zipText) }
            return (& $reply 200 @{ id = $id })
        }
        & $reply 404 @{ error = @{ message = 'ruta desconocida' } }
    }.GetNewClosure()
    @{ State = $state; Transport = $transport }
}
$googleConf = @{ clientId = 'cid'; clientSecret = 'sec'; scope = 'drive.appdata'; authBase = 'https://oauth.test'; apiBase = 'https://api.test'; timeoutSeconds = 5; retries = 3; retryDelay = 0.01 }
Test-Case 'Google Drive: vincular, subir, actualizar y bajar en otro equipo' {
    $g = New-FakeGoogle
    $da = New-TrDriveBackend -TokenPath (Join-Path $tmp 'token-a.json') -Transport $g.Transport -Conf $googleConf
    $db = New-TrDriveBackend -TokenPath (Join-Path $tmp 'token-b.json') -Transport $g.Transport -Conf $googleConf
    $code = Start-TrDriveLink $da
    Assert-True ($code.user_code -eq 'ABCD-EFGH') 'código'
    Assert-True ((Get-TrDriveLinkResult $da $code.device_code) -eq 'ana@example.com') 'correo'
    Assert-True ((Get-TrDriveEmail $da) -eq 'ana@example.com') 'token guardado'
    Assert-True (-not ([IO.File]::ReadAllText((Join-Path $tmp 'token-a.json')) -like '*refresh_token*')) 'el token debe quedar cifrado'
    [void](Get-TrDriveLinkResult $db 'DEV')
    $a = New-FakeInstall 'driveA' @('FG'); $bb = New-FakeInstall 'driveB' @('FG')
    $ca = [ordered]@{ sync = [ordered]@{ mode = 'drive'; deviceId = ('a' * 32); deviceName = 'PC' } }
    Use-Device 'da'
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`nName=Ana`r`n" '2026-01-01T10:00:00Z')
    Assert-True ((Sync-TrAfterPlay -Id 'FG' -Root $a -Config $ca -Backend $da).Action -eq 'uploaded') 'no subió'
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`nName=Ana2`r`n" '2026-01-02T10:00:00Z')
    Assert-True ((Sync-TrAfterPlay -Id 'FG' -Root $a -Config $ca -Backend $da).Action -eq 'uploaded') 'no actualizó'
    Assert-True ($g.State.files.Count -eq 1) "debería haber un solo archivo en Drive: $($g.State.files.Count)"
    Use-Device 'db'
    Assert-True ((Sync-TrBeforePlay -Id 'FG' -Root $bb -Config $ca -Backend $db).Action -eq 'downloaded') 'no bajó'
    Assert-True ([IO.File]::ReadAllText((Join-Path $bb 'games\FG\PLYR0001.INI')) -match 'Ana2') 'contenido'
    Remove-TrDriveLink $db
    Assert-True (-not (Get-TrDriveEmail $db)) 'no se desvinculó'
}
Test-Case 'Google Drive: errores con su causa (reintentos, cuota, permiso vencido, sin red)' {
    $g = New-FakeGoogle
    $d = New-TrDriveBackend -TokenPath (Join-Path $tmp 'token-e.json') -Transport $g.Transport -Conf $googleConf
    [void](Get-TrDriveLinkResult $d 'DEV')
    $a = New-FakeInstall 'driveE' @('FG')
    $c = [ordered]@{ sync = [ordered]@{ mode = 'drive'; deviceId = ('e' * 32); deviceName = 'PC' } }
    Use-Device 'de'
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`n" '2026-01-01T10:00:00Z')
    [void]$g.State.fail.AddRange(@(503, 500))
    Assert-True ((Sync-TrAfterPlay -Id 'FG' -Root $a -Config $c -Backend $d).Action -eq 'uploaded') 'no reintentó'
    [void]$g.State.fail.AddRange(@(500, 500, 500, 500, 500))
    Assert-Throws { Sync-TrBeforePlay -Id 'FG' -Root $a -Config $c -Backend $d } 'TR-SYN-006'
    $g.State.fail.Clear(); [void]$g.State.fail.Add(403)
    [void](Set-Save $a 'FG' 'PLYR0001.INI' "[P]`r`nX=1`r`n" '2026-01-02T10:00:00Z')
    Assert-Throws { Sync-TrAfterPlay -Id 'FG' -Root $a -Config $c -Backend $d } 'TR-SYN-004'
    $d.access = $null; $g.State.tokensOk = $false
    Assert-Throws { Sync-TrAfterPlay -Id 'FG' -Root $a -Config $c -Backend $d } 'TR-SYN-003'
    $g.State.tokensOk = $true; $g.State.down = $true
    $info = $null
    try { [void](Sync-TrAfterPlay -Id 'FG' -Root $a -Config $c -Backend $d) } catch { $info = Get-TrErrorInfo $_ }
    Assert-True ($info -and $info.Code -eq 'TR-SYN-001' -and $info.Message -like '*No se puede resolver*') "sin red: $($info.Code) $($info.Message)"
    $nc = @{}; foreach ($k in $googleConf.Keys) { $nc[$k] = $googleConf[$k] }; $nc.clientId = ''
    Assert-Throws { Start-TrDriveLink (New-TrDriveBackend -TokenPath (Join-Path $tmp 't.json') -Conf $nc) } 'TR-SYN-008'
}

Test-Case 'Google Drive: el cliente OAuth se puede cargar desde la interfaz' {
    & $syncModule { param($p) $script:ClientFile = $p } (Join-Path $tmp 'google-client.json')
    Assert-True ((Save-TrGoogleClient -ClientId 'no-es-un-id' -ClientSecret 'GOCSPX-abcdefghijkl') -like '*googleusercontent*') 'aceptó un ID inválido'
    Assert-True ([bool](Save-TrGoogleClient -ClientId '123-abc.apps.googleusercontent.com' -ClientSecret 'corto')) 'aceptó un secreto inválido'
    Assert-True ($null -eq (Save-TrGoogleClient -ClientId ' 123-abc.apps.googleusercontent.com ' -ClientSecret 'GOCSPX-abcdefghijkl')) 'no guardó'
    Assert-True ((Get-TrGoogleSettings).clientId -eq '123-abc.apps.googleusercontent.com') 'no lo lee'
    Assert-True (Test-TrDriveAvailable) 'no quedó disponible'
}

Write-Host 'Steam (accesos para Big Picture y Steam Link)'
Test-Case 'VDF compatible con Linux y appid igual al de Python' {
    $doc = ConvertFrom-TrVdf ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\shortcuts-linux.vdf')))
    $e = $doc['shortcuts']['0']
    Assert-True ($e['AppName'] -eq 'Otro juego' -and $e['appid'] -eq -123 -and $e['LastPlayTime'] -eq 5 -and $e['tags']['0'] -eq 'X') 'lectura'
    $big = $doc['shortcuts']['1']
    Assert-True ($big['AppName'] -eq 'Trampolín - FG' -and $big['grande'] -eq [uint64]5000000000) 'texto UTF-8 y entero de 64 bits'
    $again = ConvertTo-TrVdf $doc
    Assert-True ([Convert]::ToBase64String($again) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\shortcuts-linux.vdf')))) 'no queda idéntico al reescribirlo'
    # Mismo valor que steam.shortcut_appid('"C:\x\powershell.exe"', 'Trampolín - FG') en Python.
    Assert-True ((Get-TrShortcutAppId '"C:\x\powershell.exe"' 'Trampolín - FG') -eq [int](Get-Content (Join-Path $PSScriptRoot 'fixtures\appid.txt'))) 'appid'
}
Test-Case 'Update-TrSteamShortcutsFile conserva los accesos ajenos y la última vez que se jugó' {
    $root = New-FakeInstall 'steam' @('FG')
    $p = Join-Path $tmp 'shortcuts.vdf'
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\shortcuts-linux.vdf') $p
    $wanted = @(Get-TrWantedSteamShortcuts -Root $root)
    Assert-True ($wanted.Count -eq 2 -and $wanted[1].LaunchOptions -like '*Trampolin.ps1" --play FG') 'accesos'
    $fgName = "Trampolín - $((Get-TrGame 'FG').name)"
    [void](Update-TrSteamShortcutsFile -Path $p -Wanted $wanted)
    $doc = ConvertFrom-TrVdf ([IO.File]::ReadAllBytes($p))
    $fg = @($doc['shortcuts'].Values | Where-Object { $_['AppName'] -eq $fgName })[0]
    $fg['LastPlayTime'] = 1234
    [IO.File]::WriteAllBytes($p, (ConvertTo-TrVdf $doc))
    [void](Update-TrSteamShortcutsFile -Path $p -Wanted @(Get-TrWantedSteamShortcuts -Root $root))
    $doc = ConvertFrom-TrVdf ([IO.File]::ReadAllBytes($p))
    $names = @($doc['shortcuts'].Values | ForEach-Object { $_['AppName'] })
    Assert-True ($names.Count -eq 3 -and $names -contains 'Biblioteca Trampolín' -and $names -contains 'Otro juego' -and $names -contains $fgName) "accesos: $($names -join '|')"
    $fg = @($doc['shortcuts'].Values | Where-Object { $_['AppName'] -eq $fgName })[0]
    Assert-True ($fg['LastPlayTime'] -eq 1234) 'perdió LastPlayTime'
    Assert-True ($fg['appid'] -eq (Get-TrShortcutAppId $fg['Exe'] $fg['AppName'])) 'appid'
    Assert-True (Test-Path "$p.trampolin.bak") 'falta la copia del original'
}

Add-Type -AssemblyName System.Drawing
function Get-TrTestImageSize { param([string]$Path) $i = [Drawing.Image]::FromFile($Path); try { "$($i.Width)x$($i.Height)" } finally { $i.Dispose() } }
function New-TrArtFakeInstall {
    <# Instalación mínima con un ejecutable real (con ícono) en lugar del exe de cada juego. #>
    param([string]$Name, [string[]]$Ids)
    $root = New-FakeInstall $Name $Ids
    foreach ($id in $Ids) { Copy-Item (Join-Path $env:SystemRoot 'System32\notepad.exe') (Join-Path $root "games\$id\$((Get-TrGame $id).icon)") -Force }
    $root
}
Test-Case 'Artwork de Steam: ícono ampliado sobre su color, con las medidas de Steam (juego sin imagen del disco)' {
    $root = New-TrArtFakeInstall 'art1' @('PRE_K')
    $dir = New-TrArtImages -Id 'PRE_K' -Root $root
    Assert-True ((Get-TrTestImageSize "$dir\portrait.png") -eq '600x900' -and (Get-TrTestImageSize "$dir\header.png") -eq '920x430' -and (Get-TrTestImageSize "$dir\hero.png") -eq '1920x620') 'medidas'
    Assert-True (-not (Test-Path "$dir\logo.png")) 'no debería tener logo'
    $b = New-Object Drawing.Bitmap "$dir\portrait.png"
    try {
        Assert-True ($b.GetPixel(96, 246).ToArgb() -eq [Drawing.Color]::White.ToArgb()) 'falta el marco centrado'
        Assert-True ($b.GetPixel(5, 5).ToArgb() -eq $b.GetPixel(595, 895).ToArgb()) 'el fondo no es de un solo color'
    } finally { $b.Dispose() }
    $t = (Get-Item "$dir\hero.png").LastWriteTime
    Start-Sleep -Milliseconds 50
    [void](New-TrArtImages -Id 'PRE_K' -Root $root)
    Assert-True ((Get-Item "$dir\hero.png").LastWriteTime -eq $t) 'regeneró sin cambios en las fuentes'
}
Test-Case 'Artwork de Steam: imagen de la copia del disco, logo recortado por el polígono y copia a config\grid' {
    $root = New-TrArtFakeInstall 'art2' @('3G')
    # Caja sintética como la de 5° Curso: fondo rojo, «lápiz» azul dentro del polígono de la receta.
    $boxPath = Join-Path $root 'cd\3G\SUPPORT\AUTORUN\SUPPORT\3G.BMP'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $boxPath) | Out-Null
    $box = New-Object Drawing.Bitmap 363, 360, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [Drawing.Graphics]::FromImage($box)
    $g.Clear([Drawing.Color]::FromArgb(255, 0, 0)); $g.FillRectangle([Drawing.Brushes]::Blue, 50, 235, 220, 70); $g.FillRectangle([Drawing.Brushes]::Green, 0, 0, 363, 200)
    $g.Dispose(); $box.Save($boxPath, [Drawing.Imaging.ImageFormat]::Bmp); $box.Dispose()
    $dir = New-TrArtImages -Id '3G' -Root $root
    Assert-True (Test-Path (Join-Path $root 'games\3G\art\picture.bmp')) 'no guardó la imagen del disco'
    Assert-True ((Get-TrTestImageSize "$dir\logo.png") -eq '900x230') 'medida del logo'
    $l = New-Object Drawing.Bitmap "$dir\logo.png"
    try {
        Assert-True ($l.GetPixel(2, 2).A -eq 0) 'el borde del logo no es transparente (quedó el rojo de la caja)'
        $c = $l.GetPixel(300, 115); Assert-True ($c.A -eq 255 -and $c.B -gt 200 -and $c.R -lt 50) "el centro del logo no es el lápiz ($c)"
    } finally { $l.Dispose() }
    $p = New-Object Drawing.Bitmap "$dir\portrait.png"
    try { Assert-True ($p.GetPixel(300, 530).G -gt 100) 'falta la imagen del disco en la franja' } finally { $p.Dispose() }
    # Copia a config\grid con el appid sin signo (Steam no necesita estar cerrado).
    $cfg = Join-Path $root 'steam\userdata\42\config'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null
    $m = Get-Module Trampolin.Steam
    & $m { param($c) $script:TestConfigDirs = $c; function script:Get-TrSteamUserConfigDirs { $script:TestConfigDirs } } $cfg
    try {
        $wanted = @(Get-TrWantedSteamShortcuts -Root $root)
        Install-TrSteamArt -Root $root -Wanted $wanted
        $u = [uint32]([int64]$wanted[1].appid -band 0xFFFFFFFFL)
        $names = @(Get-ChildItem (Join-Path $cfg 'grid') | ForEach-Object Name | Sort-Object)
        Assert-True (($names -join ',') -eq ((@("${u}_hero.png", "${u}_logo.png", "$u.png", "${u}p.png") | Sort-Object) -join ',')) "archivos: $($names -join ',')"
    } finally { Import-Module (Join-Path $src 'Core\Trampolin.Steam.psm1') -Force }
}
Test-Case 'Imagen del disco guardada dentro de un archivo de recursos (DIB en un offset)' {
    $root = New-TrArtFakeInstall 'art3' @('KG')
    $pic = (Get-TrGame 'KG').art.picture
    # DIB de 640x480 de 8 bits con paleta de grises, después de bytes cualesquiera.
    $w = 640; $h = 480; $dib = New-Object byte[] (40 + 1024 + $w * $h)
    [BitConverter]::GetBytes([uint32]40).CopyTo($dib, 0); [BitConverter]::GetBytes([int]$w).CopyTo($dib, 4); [BitConverter]::GetBytes([int]$h).CopyTo($dib, 8)
    [BitConverter]::GetBytes([uint16]1).CopyTo($dib, 12); [BitConverter]::GetBytes([uint16]8).CopyTo($dib, 14)
    for ($i = 0; $i -lt 256; $i++) { $dib[40 + 4 * $i] = $i; $dib[41 + 4 * $i] = $i; $dib[42 + 4 * $i] = $i }
    for ($i = 0; $i -lt $w * $h; $i++) { $dib[1064 + $i] = 200 }
    $file = New-Object byte[] ($pic.offset + $dib.Length + 100)
    $dib.CopyTo($file, $pic.offset)
    $rsc = Join-Path $root "cd\KG\$($pic.file)"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rsc) | Out-Null
    [IO.File]::WriteAllBytes($rsc, $file)
    $out = Save-TrArtSource -Id 'KG' -Root $root
    Assert-True ((Get-TrTestImageSize $out) -eq '640x480') 'no quedó un BMP válido'
    $b = New-Object Drawing.Bitmap $out
    try { Assert-True ($b.GetPixel(10, 10).R -eq 200) 'píxeles' } finally { $b.Dispose() }
    # Un offset que no apunta a una imagen es un error (no se escribe nada).
    $root2 = New-TrArtFakeInstall 'art4' @('KG')
    $rsc2 = Join-Path $root2 "cd\KG\$($pic.file)"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rsc2) | Out-Null
    [IO.File]::WriteAllBytes($rsc2, (New-Object byte[] ($pic.offset + 2000)))
    $failed = $false; try { [void](Save-TrArtSource -Id 'KG' -Root $root2) } catch { $failed = $true }
    Assert-True ($failed -and -not (Test-Path (Join-Path $root2 'games\KG\art\picture.bmp'))) 'aceptó un offset sin imagen'
}

if ($IsoFolder) {
    Write-Host 'Integración con las imágenes reales'
    $found = $null
    Test-Case 'Find-TrIsos reconoce las imágenes' {
        $script:found = Find-TrIsos -Folder $IsoFolder
        Assert-True (@($script:found.Isos | Where-Object Status -eq 'ok').Count -ge 1) 'ninguna imagen reconocida'
    }
    Test-Case 'Cada imagen reconocida tiene su archivo clave y etiqueta' {
        foreach ($i in @($script:found.Isos | Where-Object Status -eq 'ok')) {
            $iso = New-Object TrIso($i.Path)
            try { Assert-True ($iso.Find((Get-TrGame $i.GameId).iso.keyFile)) "$($i.GameId) sin archivo clave"; Assert-True $iso.VolumeLabel "$($i.GameId) sin etiqueta" }
            finally { $iso.Dispose() }
        }
    }
    Test-Case 'Install-TrGame (modo iso) crea la carpeta del juego con WING32 propio' {
        $i = @($script:found.Isos | Where-Object Status -eq 'ok')[0]
        $root = Join-Path $tmp 'inst'
        Install-TrGame -Id $i.GameId -IsoPath $i.Path -Root $root -DataMode iso
        $g = Get-TrGame $i.GameId
        Assert-True (Test-Path (Join-Path $root "games\$($i.GameId)\$($g.exe)")) 'falta el exe'
        $w = Get-Item (Join-Path $root "games\$($i.GameId)\WING32.DLL")
        Assert-True ($w.Length -ne 12800) 'quedó el WING32.DLL original'
        Assert-True ((Get-TrManifest -Root $root).games.Contains($i.GameId)) 'no quedó en el manifiesto'
        $script:instGame = $i.GameId
    }
    Test-Case 'Artwork de Steam del juego instalado, con las medidas de Steam' {
        $dir = New-TrArtImages -Id $script:instGame -Root (Join-Path $tmp 'inst')
        foreach ($s in @(@('portrait.png', '600x900'), @('header.png', '920x430'), @('hero.png', '1920x620'))) {
            Assert-True ((Get-TrTestImageSize (Join-Path $dir $s[0])) -eq $s[1]) "$($s[0])"
        }
    }
    Test-Case 'La imagen del artwork de cada juego se lee de su disco (modo iso)' {
        $ok = @($script:found.Isos | Where-Object { $_.Status -eq 'ok' -and ((Get-TrGame $_.GameId).PSObject.Properties.Name -contains 'art') })
        $root = New-FakeInstall 'artiso' @($ok | ForEach-Object GameId)
        $m = Get-TrManifest -Root $root
        foreach ($i in $ok) { $m.games[$i.GameId].dataMode = 'iso'; $m.games[$i.GameId].isoPath = $i.Path }
        Save-TrManifest -Root $root -Manifest $m
        $expected = @{ KG = '640x480'; FG = '640x480'; '2G' = '640x480'; '3G' = '363x360'; '4G' = '357x360' }
        foreach ($i in $ok) {
            $p = Save-TrArtSource -Id $i.GameId -Root $root
            Assert-True ($p -and (Get-TrTestImageSize $p) -eq $expected[$i.GameId]) "$($i.GameId): $(if ($p) { Get-TrTestImageSize $p } else { 'sin imagen' })"
        }
    }
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("Resultado: {0} correctas, {1} con fallas" -f $script:passed, $script:failed) -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
exit $(if ($script:failed) { 1 } else { 0 })
