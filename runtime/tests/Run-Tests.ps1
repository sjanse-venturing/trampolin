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
Import-TrStrings (Join-Path $src 'data\strings.es.json')

$script:passed = 0; $script:failed = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "  OK   $Name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "  FALLA $Name :: $($_.Exception.Message)" -ForegroundColor Red }
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
    }
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("Resultado: {0} correctas, {1} con fallas" -f $script:passed, $script:failed) -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
exit $(if ($script:failed) { 1 } else { 0 })
