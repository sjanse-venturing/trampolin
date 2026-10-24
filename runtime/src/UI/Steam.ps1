# Steam.ps1 — «Agregar a Steam»: la biblioteca y los juegos como accesos «no de Steam», para abrirlos
# desde Steam, Big Picture o Steam Link (mismo comportamiento que add_to_steam de linux/trampolin/ui.py).

function Invoke-TrAddToSteamUI {
    <# Agrega los accesos (cierra Steam un momento si está abierto). Devuelve $true si quedaron agregados. #>
    param([Parameter(Mandatory)][string]$Root, $Owner = $null)
    if (-not @(Get-TrSteamUserConfigDirs).Count) { [void](Show-TrError (Get-TrErrorInfo (New-TrError 'TR-STM-001')) $Owner); return $false }
    $running = Test-TrSteamRunning
    if ($running -and -not (Show-TrConfirm -Title '¿Cerrar Steam un momento?' -Message 'Para agregar los juegos a Steam hay que cerrarlo. Lo volvemos a abrir enseguida.' -Yes 'Cerrar Steam y agregar' -No 'Cancelar' -Owner $Owner)) {
        return $false
    }
    while ($true) {
        $sync = Invoke-TrWithProgress -Title 'Agregando los juegos a Steam…' -Owner $Owner -Marquee -Arguments @{ root = $Root; running = $running } -Script {
            param($sync, $a)
            $sync.Message = 'Preparando las imágenes para Steam…'
            Update-TrArtImages -Root $a.root
            if ($a.running) {
                $sync.Message = 'Cerrando Steam…'
                if (-not (Stop-TrSteam)) { throw (New-TrError 'TR-STM-002') }
            }
            $sync.Message = 'Agregando los juegos…'
            $files = @(Add-TrToSteam -Root $a.root)
            if ($a.running) { $sync.Message = 'Abriendo Steam…'; Start-TrSteam }
            $files
        }
        if (-not $sync.Error) { break }
        if ((Show-TrError $sync.Error $Owner) -ne 'retry') { return $false }
    }
    Show-TrInfo -Title 'Listo' -Owner $Owner -Message ("Los juegos aparecen en tu biblioteca de Steam (en «No de Steam»). Podés abrirlos desde Big Picture o desde Steam Link en el celular o la TV." +
        "`r`n`r`nPara manejarlos con el control, en Steam elegí el juego → Administrar → Configuración del control y usá la plantilla «Teclado y mouse» (o «Gamepad con mouse»).")
    $true
}
