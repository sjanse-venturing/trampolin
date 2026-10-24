# Sync.ps1 — interfaz de la sincronización de partidas: «Sincronización…», vincular Google Drive
# y los pasos antes de abrir y al cerrar cada juego (mismo comportamiento que linux/trampolin/ui.py).

function Invoke-TrSyncBeforePlayUI {
    <# Antes de jugar: trae la partida más reciente. Devuelve $true para jugar, $false para no jugar. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, $Owner = $null)
    if (-not (Test-TrSyncEnabled $Config) -or -not (Get-TrManifest -Root $Root).games.Contains($Id)) { return $true }
    $name = (Get-TrGame $Id).name
    while ($true) {
        $sync = Invoke-TrWithProgress -Title "Buscando la partida más reciente de «$name»…" -Owner $Owner -Marquee -Arguments @{ id = $Id; root = $Root; config = $Config } -Script {
            param($sync, $a)
            $sync.Message = 'Conectando…'
            Sync-TrBeforePlay -Id $a.id -Root $a.root -Config $a.config
        }
        if (-not $sync.Error) { Write-TrLog Info "Sincronización antes de jugar: $($sync.Result.Message)"; return $true }
        $info = $sync.Error
        $info.Message += "`r`n`r`nPodés jugar igual con la partida de este equipo: al cerrar el juego se va a guardar en la sincronización."
        $info.Actions = @('playlocal', 'retry') + $(if ($info.Code -eq 'TR-SYN-003') { @('relink') } else { @() }) + @('details')
        $action = Show-TrError $info $Owner
        if ($action -eq 'playlocal') { return $true }
        if ($action -eq 'relink') { [void](Show-TrSyncDialog -Config $Config -Root $Root -Owner $Owner); continue }
        if ($action -ne 'retry') { return $false }
    }
}

function Invoke-TrSyncAfterPlayUI {
    <# Al cerrar el juego: sube la partida. Muestra el error con la causa si no se pudo. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, $Owner = $null)
    if (-not (Test-TrSyncEnabled $Config) -or -not (Get-TrManifest -Root $Root).games.Contains($Id)) { return }
    $name = (Get-TrGame $Id).name
    while ($true) {
        $sync = Invoke-TrWithProgress -Title "Guardando la partida de «$name» en la sincronización…" -Owner $Owner -Marquee -Arguments @{ id = $Id; root = $Root; config = $Config } -Script {
            param($sync, $a)
            $sync.Message = 'Conectando…'
            Sync-TrAfterPlay -Id $a.id -Root $a.root -Config $a.config
        }
        if (-not $sync.Error) {
            Write-TrLog Info "Sincronización al cerrar: $($sync.Result.Message)"
            if ($sync.Result.Conflict) {
                Show-TrInfo -Title 'Había otra partida más vieja' -Owner $Owner -Message ("Otro equipo había guardado una partida de «{0}» que no llegaste a usar. Se guardó la tuya (es la más reciente) y la otra quedó en:`r`n{1}" -f $name, $sync.Result.Conflict)
            }
            return
        }
        $info = $sync.Error
        $info.Message += "`r`n`r`nLa partida quedó guardada en este equipo y se va a subir la próxima vez que se sincronice."
        $info.Actions = @('retry') + $(if ($info.Code -eq 'TR-SYN-003') { @('relink') } else { @() }) + @('details')
        $action = Show-TrError $info $Owner
        if ($action -eq 'relink') { [void](Show-TrSyncDialog -Config $Config -Root $Root -Owner $Owner); continue }
        if ($action -ne 'retry') { return }
    }
}

function Show-TrDriveLinkDialog {
    <# Vincular Google Drive con un código (se puede autorizar desde el celular). Devuelve el correo o $null. #>
    param($Owner = $null)
    $f = New-TrForm -Title 'Vincular Google Drive' -Width 620 -Height 360
    $f.Controls.Add((New-TrLabel -Text 'Vincular Google Drive' -X 20 -Y 16 -Font $global:TrTheme.FontBig))
    $msg = New-TrLabel -Text 'Pidiendo un código a Google…' -X 20 -Y 50 -Width 580 -Height 44
    $code = New-TrLabel -Text '' -X 20 -Y 100 -Width 580 -Height 50 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 24)) -Color $global:TrTheme.Primary
    $url = New-TrLabel -Text '' -X 20 -Y 156 -Width 580 -Font $global:TrTheme.FontBold
    $note = New-TrLabel -Text 'Las partidas se guardan en una carpeta privada de la app: no aparecen en tu Drive ni las puede ver nadie más.' -X 20 -Y 196 -Width 580 -Height 40 -Font $global:TrTheme.FontSmall -Color $global:TrTheme.Muted
    $btnCopy = New-TrButton -Text 'Copiar el código' -Width 150; $btnCopy.Location = New-Object System.Drawing.Point(214, 300); $btnCopy.Enabled = $false
    $btnOpen = New-TrButton -Text 'Abrir el navegador' -Width 150; $btnOpen.Location = New-Object System.Drawing.Point(372, 300); $btnOpen.Enabled = $false
    $btnCancel = New-TrButton -Text 'Cancelar' -Width 90; $btnCancel.Location = New-Object System.Drawing.Point(510, 300)
    $f.Controls.AddRange(@($msg, $code, $url, $note, $btnCopy, $btnOpen, $btnCancel))
    $f.CancelButton = $btnCancel

    $sync = Start-TrBackground -Script {
        param($sync, $a)
        $be = New-TrDriveBackend
        $d = Start-TrDriveLink $be
        $sync.Url = $d.verification_url; $sync.Code = $d.user_code
        $interval = [int]$d.interval
        $deadline = (Get-Date).AddSeconds([int]$d.expires_in)
        while (-not $sync.Cancel -and (Get-Date) -lt $deadline) {
            for ($i = 0; $i -lt 4 * $interval -and -not $sync.Cancel; $i++) { Start-Sleep -Milliseconds 250 }
            if ($sync.Cancel) { return $null }
            $r = Get-TrDriveLinkResult $be $d.device_code
            if ($r -eq 'slow_down') { $interval += 5 } elseif ($r -ne 'pending') { return $r }
        }
        if (-not $sync.Cancel) { throw (New-TrError 'TR-SYN-003' @{ detail = 'no se autorizó el acceso a tiempo' }) }
        $null
    }
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 300
    $timer.Add_Tick({
        if ($sync.Contains('Code') -and $sync.Code -and -not $code.Text) {
            $msg.Text = "1. En el celular o en la computadora, entrá a la dirección de abajo.`r`n2. Iniciá sesión con tu cuenta de Google y escribí este código:"
            $code.Text = $sync.Code; $url.Text = $sync.Url
            $btnCopy.Enabled = $true; $btnOpen.Enabled = $true
        }
        if ($sync.Done) { $timer.Stop(); $f.Close() }
    })
    $btnCopy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($code.Text); $btnCopy.Text = 'Copiado ✓' })
    $btnOpen.Add_Click({ Start-Process $url.Text })
    $btnCancel.Add_Click({ $sync.Cancel = $true; $f.Close() })
    $f.Add_FormClosing({ $sync.Cancel = $true })
    $f.Add_Shown({ $timer.Start() })
    [void]$f.ShowDialog($Owner)
    $timer.Dispose(); $f.Dispose()
    $cancelled = $sync.Cancel -and -not $sync.Done
    Stop-TrBackground $sync
    if ($sync.Error -and -not $cancelled) { [void](Show-TrError $sync.Error $Owner); return $null }
    if ($cancelled) { return $null }
    $sync.Result
}

function Show-TrGoogleSetupDialog {
    <# «Cómo habilitarlo…»: pasos cortos para crear el cliente OAuth y campos para pegarlo. Devuelve $true si se guardó. #>
    param($Owner = $null)
    $help = Get-TrGoogleHelpInfo
    $f = New-TrForm -Title 'Habilitar Google Drive' -Width 640 -Height 470
    $f.Controls.Add((New-TrLabel -Text 'Habilitar Google Drive' -X 20 -Y 14 -Font $global:TrTheme.FontBig))
    $f.Controls.Add((New-TrLabel -Text 'Hay que registrar Trampolín en Google Cloud con tu cuenta (es gratis y se hace una sola vez):' -X 20 -Y 46 -Width 600 -Height 22))
    $steps = @(
        '1.  Abrí Google Cloud, creá un proyecto y habilitá «Google Drive API».',
        '2.  En «Pantalla de consentimiento de OAuth»: tipo Externo, agregá el permiso (copialo con el botón) y tocá «Publicar app».',
        '3.  En «Credenciales» → «Crear credenciales» → «ID de cliente de OAuth», elegí «TVs y dispositivos de entrada limitada».',
        '4.  Pegá acá abajo el ID y el secreto que te muestra Google.'
    )
    $y = 76
    foreach ($t in $steps) {
        $h = 22 + (Get-TrExtraHeight -Text $t -Width 600 -Height 22)
        $f.Controls.Add((New-TrLabel -Text $t -X 20 -Y $y -Width 600 -Height $h)); $y += $h + 6
    }
    $btnConsole = New-TrButton -Text 'Abrir Google Cloud' -Width 170 -Primary; $btnConsole.Location = New-Object System.Drawing.Point(20, 250)
    $btnScope = New-TrButton -Text 'Copiar el permiso' -Width 160; $btnScope.Location = New-Object System.Drawing.Point(198, 250)
    $btnMore = New-TrButton -Text 'Ver la guía' -Width 120; $btnMore.Location = New-Object System.Drawing.Point(366, 250)
    $f.Controls.Add((New-TrLabel -Text 'ID de cliente:' -X 20 -Y 306))
    $txtId = New-Object System.Windows.Forms.TextBox; $txtId.Location = New-Object System.Drawing.Point(140, 303); $txtId.Width = 480
    $f.Controls.Add((New-TrLabel -Text 'Secreto:' -X 20 -Y 342))
    $txtSecret = New-Object System.Windows.Forms.TextBox; $txtSecret.Location = New-Object System.Drawing.Point(140, 339); $txtSecret.Width = 480; $txtSecret.UseSystemPasswordChar = $true
    $lblErr = New-TrLabel -Text '' -X 140 -Y 368 -Width 480 -Color $global:TrTheme.Bad
    $btnCancel = New-TrButton -Text 'Cancelar' -Width 110; $btnCancel.Location = New-Object System.Drawing.Point(380, 414); $btnCancel.DialogResult = 'Cancel'
    $btnSave = New-TrButton -Text 'Guardar' -Width 120 -Primary; $btnSave.Location = New-Object System.Drawing.Point(500, 414)
    $f.Controls.AddRange(@($btnConsole, $btnScope, $btnMore, $txtId, $txtSecret, $lblErr, $btnCancel, $btnSave))
    $f.CancelButton = $btnCancel
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($btnScope, $help.Scope)
    $btnConsole.Add_Click({ Start-Process $help.ConsoleUrl })
    $btnScope.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($help.Scope); $btnScope.Text = 'Copiado ✓' })
    $btnMore.Add_Click({
        $doc = Get-TrGuidePath
        if ($doc) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $doc) }
    })
    $btnSave.Add_Click({
        $err = Save-TrGoogleClient -ClientId $txtId.Text -ClientSecret $txtSecret.Text
        if ($err) { $lblErr.Text = $err; return }
        $f.DialogResult = 'OK'; $f.Close()
    })
    $r = $f.ShowDialog($Owner)
    $tip.Dispose(); $f.Dispose()
    $r -eq 'OK'
}

function Show-TrSyncDialog {
    <# «Sincronización…»: elegir el modo, vincular, probar y ver el estado de cada juego. Devuelve $true si se guardó. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Root, $Owner = $null)
    $s = Get-TrSyncConfig $Config
    $drive = New-TrDriveBackend
    $state = @{ saved = $false; available = $false }
    $f = New-TrForm -Title 'Sincronización de partidas' -Width 820 -Height 640
    $f.Controls.Add((New-TrLabel -Text 'Sincronización de partidas' -X 20 -Y 14 -Font $global:TrTheme.FontBig))
    $f.Controls.Add((New-TrLabel -Text 'Cuando está activada, al abrir un juego se usa la partida más reciente de todos tus equipos (Windows, Linux o Steam Deck), y al cerrarlo se guarda la tuya.' -X 20 -Y 44 -Width 780 -Height 40))
    $rbOff = New-Object System.Windows.Forms.RadioButton; $rbOff.Text = 'Desactivada'; $rbOff.Location = New-Object System.Drawing.Point(20, 92); $rbOff.Width = 780
    $rbFolder = New-Object System.Windows.Forms.RadioButton; $rbFolder.Text = 'Carpeta sincronizada (Google Drive para escritorio, OneDrive, Dropbox, Syncthing, pendrive…)'
    $rbFolder.Location = New-Object System.Drawing.Point(20, 122); $rbFolder.Width = 780
    $txtFolder = New-Object System.Windows.Forms.TextBox; $txtFolder.Location = New-Object System.Drawing.Point(44, 154); $txtFolder.Width = 590; $txtFolder.Text = [string]$s.folder
    $suggested = Get-TrSuggestedSyncFolder
    if (-not $txtFolder.Text) { $txtFolder.Text = $suggested.Path }
    $lblFolderHint = New-TrLabel -Text '' -X 44 -Y 178 -Width 740 -Height 18 -Font $global:TrTheme.FontSmall -Color $global:TrTheme.Muted
    $folderHint = {
        $lblFolderHint.Text = $(if ($txtFolder.Text -ne $suggested.Path) { '' }
            elseif ($suggested.Source) { "Sugerida: la carpeta de $($suggested.Source) de este equipo (usá la misma cuenta en los otros)." }
            else { 'Sugerida: la carpeta de partidas de este equipo. Para sincronizar, elegí una que copie otro programa (Google Drive, OneDrive, Syncthing…) o un pendrive.' })
    }
    $txtFolder.Add_TextChanged({ & $folderHint })
    & $folderHint
    $btnFolder = New-TrButton -Text 'Examinar…' -Width 140; $btnFolder.Location = New-Object System.Drawing.Point(642, 150)
    $rbDrive = New-Object System.Windows.Forms.RadioButton; $rbDrive.Text = 'Google Drive (iniciando sesión una vez con un código)'
    $rbDrive.Location = New-Object System.Drawing.Point(20, 196); $rbDrive.Width = 780
    $lblDrive = New-TrLabel -Text '' -X 44 -Y 224 -Width 440 -Height 44 -Color $global:TrTheme.Muted
    $lblDrive.TextAlign = 'MiddleLeft'
    $btnLink = New-TrButton -Text 'Vincular…' -Width 150; $btnLink.Location = New-Object System.Drawing.Point(492, 226)
    $btnUnlink = New-TrButton -Text 'Desvincular' -Width 132; $btnUnlink.Location = New-Object System.Drawing.Point(650, 226)
    $f.Controls.Add((New-TrLabel -Text 'Nombre de este equipo:' -X 20 -Y 282))
    $txtDevice = New-Object System.Windows.Forms.TextBox; $txtDevice.Location = New-Object System.Drawing.Point(190, 279); $txtDevice.Width = 260; $txtDevice.MaxLength = 64; $txtDevice.Text = [string]$s.deviceName
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.Location = New-Object System.Drawing.Point(20, 318); $lv.Size = New-Object System.Drawing.Size(780, 240)
    [void]$lv.Columns.Add('Juego', 330); [void]$lv.Columns.Add('Partida de este equipo', 165); [void]$lv.Columns.Add('Última sincronización', 165); [void]$lv.Columns.Add('Estado', 100)
    $btnTest = New-TrButton -Text 'Probar conexión' -Width 150; $btnTest.Location = New-Object System.Drawing.Point(20, 586)
    $btnNow = New-TrButton -Text 'Sincronizar ahora' -Width 160; $btnNow.Location = New-Object System.Drawing.Point(178, 586)
    $btnCancel = New-TrButton -Text 'Cancelar' -Width 110; $btnCancel.Location = New-Object System.Drawing.Point(560, 586); $btnCancel.DialogResult = 'Cancel'
    $btnSave = New-TrButton -Text 'Guardar' -Width 120 -Primary; $btnSave.Location = New-Object System.Drawing.Point(680, 586)
    $f.Controls.AddRange(@($rbOff, $rbFolder, $txtFolder, $lblFolderHint, $btnFolder, $rbDrive, $lblDrive, $btnLink, $btnUnlink, $txtDevice, $lv, $btnTest, $btnNow, $btnCancel, $btnSave))
    $f.CancelButton = $btnCancel
    switch ($s.mode) { 'folder' { $rbFolder.Checked = $true } 'drive' { $rbDrive.Checked = $true } default { $rbOff.Checked = $true } }

    $refresh = {
        $txtFolder.Enabled = $rbFolder.Checked; $btnFolder.Enabled = $rbFolder.Checked
        $email = Get-TrDriveEmail $drive
        $state.available = Test-TrDriveAvailable
        $rbDrive.Enabled = $state.available
        if (-not $state.available) {
            $lblDrive.Text = 'Falta habilitar el acceso a Google en este equipo (una sola vez).'
            $btnLink.Text = 'Cómo habilitarlo…'
        } else {
            $lblDrive.Text = $(if ($email) { "Vinculado con $email" } else { 'Sin vincular' })
            $btnLink.Text = $(if ($email) { 'Cambiar de cuenta…' } else { 'Vincular…' })
        }
        $btnUnlink.Enabled = [bool]$email
        $lv.Items.Clear()
        foreach ($r in @(Get-TrSyncStatus -Root $Root)) {
            $it = New-Object System.Windows.Forms.ListViewItem($r.Name)
            [void]$it.SubItems.Add((Format-TrSyncDate $r.LocalUpdatedAt)); [void]$it.SubItems.Add((Format-TrSyncDate $r.LastSyncAt))
            [void]$it.SubItems.Add($(if (-not $r.LocalUpdatedAt) { 'Sin partidas' } elseif ($r.Pending) { 'Pendiente' } else { 'Al día' }))
            if ($r.LocalUpdatedAt -and $r.Pending) { $it.ForeColor = $global:TrTheme.Warn }
            [void]$lv.Items.Add($it)
        }
    }

    $apply = {
        # Valida y guarda la configuración. Devuelve $false si falta algo.
        $mode = $(if ($rbFolder.Checked) { 'folder' } elseif ($rbDrive.Checked) { 'drive' } else { 'off' })
        if ($mode -eq 'folder' -and $txtFolder.Text -eq $suggested.Path -and -not (Test-Path -LiteralPath $txtFolder.Text)) {
            New-Item -ItemType Directory -Force -Path $txtFolder.Text -ErrorAction SilentlyContinue | Out-Null   # la carpeta de partidas puede no existir todavía
        }
        if ($mode -eq 'folder' -and -not ($txtFolder.Text -and (Test-Path -LiteralPath $txtFolder.Text -PathType Container))) {
            Show-TrInfo -Title 'Elegí la carpeta' -Message 'Elegí una carpeta que exista (por ejemplo, la de Google Drive para escritorio).' -Owner $f; return $false
        }
        if ($mode -eq 'drive' -and -not (Get-TrDriveEmail $drive)) {
            Show-TrInfo -Title 'Falta vincular la cuenta' -Message 'Tocá «Vincular…» para conectar tu cuenta de Google.' -Owner $f; return $false
        }
        $s.mode = $mode
        $s.folder = $(if ($txtFolder.Text) { $txtFolder.Text } else { $null })
        if ($txtDevice.Text.Trim()) { $s.deviceName = $txtDevice.Text.Trim() }
        Save-TrConfig $Config
        $state.saved = $true
        $true
    }

    foreach ($rb in @($rbOff, $rbFolder, $rbDrive)) { $rb.Add_CheckedChanged({ & $refresh }) }
    $btnFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Elegí la carpeta que se sincroniza (por ejemplo, «Mi unidad» de Google Drive para escritorio)'
        if ($txtFolder.Text -and (Test-Path -LiteralPath $txtFolder.Text)) { $dlg.SelectedPath = $txtFolder.Text }
        if ($dlg.ShowDialog($f) -eq 'OK') { $txtFolder.Text = $dlg.SelectedPath }
    })
    $btnLink.Add_Click({
        if (-not $state.available) {
            if (Show-TrGoogleSetupDialog -Owner $f) { & $refresh; if ($state.available) { $rbDrive.Checked = $true } }
            return
        }
        $email = Show-TrDriveLinkDialog -Owner $f
        if ($email) {
            $rbDrive.Checked = $true
            Show-TrInfo -Title 'Google Drive vinculado' -Message "Listo: las partidas se van a guardar en la cuenta $email." -Owner $f
        }
        & $refresh
    })
    $btnUnlink.Add_Click({
        if (-not (Show-TrConfirm -Title '¿Desvincular Google Drive?' -Message 'Este equipo deja de sincronizar con esa cuenta. Las partidas que ya están en Drive y las de este equipo no se borran.' -Yes 'Desvincular' -No 'Cancelar' -Owner $f)) { return }
        [void](Invoke-TrWithProgress -Title 'Desvinculando…' -Owner $f -Marquee -Script { param($sync, $a) Remove-TrDriveLink (New-TrDriveBackend) })
        if ($rbDrive.Checked) { $rbOff.Checked = $true }
        & $refresh
    })
    $btnTest.Add_Click({
        if (-not (& $apply)) { return }
        if (-not (Test-TrSyncEnabled $Config)) { Show-TrInfo -Title 'Sincronización desactivada' -Message 'Elegí una carpeta o Google Drive para probar la conexión.' -Owner $f; return }
        $r = Invoke-TrWithProgress -Title 'Probando la conexión…' -Owner $f -Marquee -Arguments @{ config = $Config } -Script { param($sync, $a) Test-TrSyncBackend (Get-TrSyncBackend -Config $a.config) }
        if ($r.Error) { [void](Show-TrError $r.Error $f) } else { Show-TrInfo -Title 'Todo bien' -Message 'La sincronización funciona.' -Owner $f }
    })
    $btnNow.Add_Click({
        if (-not (& $apply)) { return }
        if (-not (Test-TrSyncEnabled $Config)) { Show-TrInfo -Title 'Sincronización desactivada' -Message 'Elegí una carpeta o Google Drive para sincronizar.' -Owner $f; return }
        if (Get-TrRunningGame -Root $Root) { [void](Show-TrError (Get-TrErrorInfo (New-TrError 'TR-RUN-001')) $f); return }
        $r = Invoke-TrWithProgress -Title 'Sincronizando las partidas…' -Owner $f -Arguments @{ config = $Config; root = $Root } -Script {
            param($sync, $a)
            Sync-TrAll -Root $a.root -Config $a.config -OnProgress { param($p, $m) $sync.Percent = $p; $sync.Message = $m }
        }
        & $refresh
        if ($r.Error) { [void](Show-TrError $r.Error $f); return }
        $results = @($r.Result)
        $lines = @(foreach ($x in $results) { if ($x.Error) { '✖ {0}: {1}' -f (Get-TrGame $x.Id).name, $x.Error.Title } else { '✔ ' + $x.Result.Message } })
        $conflicts = @($results | Where-Object { $_.Result -and $_.Result.Conflict } | ForEach-Object { $_.Result.Conflict })
        if ($conflicts.Count) { $lines += @('', "Las partidas que perdieron quedaron en «$(Split-Path -Parent $conflicts[0])».") }
        $failed = @($results | Where-Object { $_.Error })
        Show-TrInfo -Title $(if ($failed.Count) { 'Sincronización con errores' } else { 'Sincronización terminada' }) -Message ($lines -join "`r`n") -Owner $f
        if ($failed.Count) { [void](Show-TrError $failed[0].Error $f) }
    })
    $btnSave.Add_Click({ if (& $apply) { $f.DialogResult = 'OK'; $f.Close() } })
    $f.Add_Shown({ & $refresh })
    [void]$f.ShowDialog($Owner)
    $f.Dispose()
    $state.saved
}
