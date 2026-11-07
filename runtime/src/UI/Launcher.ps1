# Launcher.ps1 — "Biblioteca Trampolín": elegir y jugar los juegos instalados.

function Invoke-TrRuntimeUpdateUI {
    <#
      Si se descomprimió una versión nueva sin instalarla, los accesos directos y Steam siguen
      abriendo la vieja: ofrece actualizar la instalación. Con -Quiet (accesos directos y Steam) no
      vuelve a preguntar por una versión que el usuario ya rechazó.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, $Owner = $null, [switch]$Quiet)
    $old = Get-TrOutdatedInstall -Root $Root -Config $Config
    if (-not $old -or ($Quiet -and $old.Declined)) { return }
    $was = $(if ($old.Installed) { "la $($old.Installed)" } else { 'una anterior' })
    $remember = {
        if ($Config.newerCopy -is [Collections.IDictionary]) { $Config.newerCopy.declined = $true; Save-TrConfig $Config }
    }
    if (-not $old.SourceExists) {
        Show-TrInfo -Title 'Hay una versión más nueva' -Owner $Owner -Message ("Trampolín $($old.Newer) se abrió desde «$($old.Source)», pero esa carpeta ya no está. " +
            'Para actualizar, descomprimí de nuevo esa versión, abrí su Trampolin.cmd y elegí «Actualizar».')
        Write-TrLog Warn "Instalación desactualizada ($was); la copia $($old.Newer) ya no está en $($old.Source)"
        & $remember
        return
    }
    $intro = $(if (Test-TrSamePath (Get-TrAppRoot) $old.Source) { "Estás usando Trampolín $($old.Newer), pero la versión instalada es $was." }
        else { "Hay una versión más nueva de Trampolín ($($old.Newer)) en «$($old.Source)», pero la instalada es $was." })
    $msg = "$intro Los accesos directos, el menú Inicio y Steam abren la versión instalada, así que ahí no vas a ver las correcciones nuevas.`r`n`r`n" +
        '¿Actualizar la instalación ahora? Los juegos y las partidas no se tocan.'
    if (-not (Show-TrConfirm -Title 'La versión instalada es más vieja' -Message $msg -Yes 'Actualizar' -No 'Jugar sin actualizar' -Owner $Owner)) {
        Write-TrLog Warn "Instalación desactualizada ($was, hay $($old.Newer) en $($old.Source)): el usuario eligió no actualizar"
        & $remember
        return
    }
    try {
        Install-TrRuntimeFiles -Root $Root -Source $old.Source | Out-Null
        Write-TrLog Info "Instalación actualizada a $($old.Newer) desde $($old.Source)"
        Show-TrInfo -Title 'Instalación actualizada' -Message "Trampolín $($old.Newer) quedó instalado. Los accesos directos y Steam ya usan esta versión." -Owner $Owner
    } catch {
        [void](Show-TrError $_ $Owner)
    }
}

function ConvertTo-TrNotesText {
    <# Las novedades (Markdown del CHANGELOG) en texto simple para mostrar. #>
    param([string]$Notes)
    $lines = foreach ($line in ("$Notes" -replace "`r`n", "`n").Split("`n")) {
        $line = ($line -replace '^#+\s*', '').Replace('**', '').Replace('`', '')
        ($line -replace '^(\s*)[-*]\s+', '$1• ').TrimEnd()
    }
    $text = ($lines -join "`r`n").Trim()
    $(if ($text) { $text } else { 'Correcciones y mejoras.' })
}

function Show-TrUpdatePrompt {
    param([Parameter(Mandatory)]$Release, $Current, $Owner = $null)
    $was = $(if ($Current) { "la $($Current.ToString(3))" } else { 'una anterior' })
    $f = New-TrForm -Title 'Trampolín' -Width 600 -Height 440
    $t = New-TrLabel -Text 'Hay una versión nueva de Trampolín' -X 20 -Y 18 -Width 560 -Font $global:TrTheme.FontBig
    $m = New-TrLabel -Text ("Está disponible la versión $($Release.Version) (tenés $was). Actualizar tarda unos segundos; " +
        'los juegos y las partidas no se tocan.') -X 20 -Y 52 -Width 560 -Height 44
    $h = New-TrLabel -Text 'Novedades' -X 20 -Y 102 -Width 560 -Font $global:TrTheme.FontBold
    $notes = New-Object System.Windows.Forms.TextBox
    $notes.Multiline = $true; $notes.ReadOnly = $true; $notes.ScrollBars = 'Vertical'; $notes.BackColor = [System.Drawing.Color]::White
    $notes.Location = New-Object System.Drawing.Point(20, 126); $notes.Size = New-Object System.Drawing.Size(560, 220)
    $notes.Text = ConvertTo-TrNotesText $Release.Notes
    $by = New-TrButton -Text 'Actualizar' -Width 140 -Primary; $by.Location = New-Object System.Drawing.Point(440, 360)
    $bn = New-TrButton -Text 'Ahora no' -Width 140; $bn.Location = New-Object System.Drawing.Point(290, 360)
    $by.DialogResult = 'Yes'; $bn.DialogResult = 'No'
    $f.Controls.AddRange(@($t, $m, $h, $notes, $by, $bn)); $f.AcceptButton = $by; $f.CancelButton = $bn
    $f.Add_Shown({ $by.Focus() }.GetNewClosure())
    $r = $f.ShowDialog($Owner); $f.Dispose()
    $r -eq 'Yes'
}

function Invoke-TrReleaseUpdateUI {
    <#
      Al abrir la biblioteca o un juego: si hay una versión nueva publicada en GitHub, ofrece
      instalarla. Si se instala, vuelve a abrir Trampolín (ya actualizado) con los mismos
      argumentos y termina este proceso.
    #>
    param([Parameter(Mandatory)][string]$Root, [string[]]$Arguments = @(), $Owner = $null)
    try { $release = Get-TrPendingUpdate -Root $Root }
    catch { Write-TrLog Warn "No se pudo consultar si hay actualizaciones: $_"; return }     # nunca impide jugar
    if (-not $release -or (Get-TrRunningGame -Root $Root)) { return }
    if (-not (Show-TrUpdatePrompt -Release $release -Current (Get-TrRuntimeVersion) -Owner $Owner)) {
        Write-TrLog Info "Hay una actualización ($($release.Version)): el usuario eligió «Ahora no»"
        return
    }
    $sync = Invoke-TrWithProgress -Title "Actualizando Trampolín a la versión $($release.Version)…" -Owner $Owner -Arguments @{ release = $release; root = $Root } -Script {
        param($sync, $a)
        Install-TrUpdate -Release $a.release -Root $a.root -Cancel $sync -OnProgress { param($p, $m) $sync.Percent = $p; $sync.Message = $m }
    }
    if ($sync.Error) { [void](Show-TrError $sync.Error $Owner); return }
    Show-TrInfo -Title 'Trampolín actualizado' -Message "Ya tenés la versión $($release.Version). Trampolín se vuelve a abrir." -Owner $Owner
    $entry = Join-Path $Root 'app\src\Trampolin.ps1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $entry)) + $Arguments
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argList
    exit 0
}

function Show-TrLauncher {
    param([Parameter(Mandatory)]$Config)

    $state = @{ session = $null; reopenWizard = $false; preselect = @(); versionChecked = $false }
    $form = New-TrForm -Title 'Biblioteca Trampolín' -Width 1060 -Height 620 -Resizable
    $form.MinimumSize = New-Object System.Drawing.Size(640, 480)
    $header = New-TrHeader -Title 'Biblioteca Trampolín' -Subtitle 'Elegí un juego y presioná «Jugar»'
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.AutoScroll = $true; $flow.Padding = New-Object System.Windows.Forms.Padding(16)
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 56; $bottom.BackColor = [System.Drawing.Color]::FromArgb(238, 234, 226)
    $btnAdd = New-TrButton -Text 'Agregar juegos…' -Width 150; $btnAdd.Location = New-Object System.Drawing.Point(16, 11)
    $btnSaves = New-TrButton -Text 'Partidas ▾' -Width 110; $btnSaves.Location = New-Object System.Drawing.Point(174, 11)
    $btnSync = New-TrButton -Text 'Sincronización…' -Width 140; $btnSync.Location = New-Object System.Drawing.Point(292, 11)
    $btnSteam = New-TrButton -Text 'Agregar a Steam' -Width 140; $btnSteam.Location = New-Object System.Drawing.Point(440, 11)
    $btnOptions = New-TrButton -Text 'Opciones…' -Width 110; $btnOptions.Location = New-Object System.Drawing.Point(588, 11)
    $btnHelp = New-TrButton -Text 'Ayuda' -Width 90; $btnHelp.Location = New-Object System.Drawing.Point(706, 11)
    $btnLog = New-TrButton -Text 'Ver registro' -Width 110; $btnLog.Location = New-Object System.Drawing.Point(804, 11)
    $lblStatus = New-TrLabel -Text '' -X 926 -Y 19 -Width 120 -Color $global:TrTheme.Muted
    $lblStatus.AutoEllipsis = $true; $lblStatus.Anchor = 'Left,Right,Top'
    $bottom.Controls.AddRange(@($btnAdd, $btnSaves, $btnSync, $btnSteam, $btnOptions, $btnHelp, $btnLog, $lblStatus))
    $form.Controls.AddRange(@($flow, $bottom, $header))
    $tip = New-Object System.Windows.Forms.ToolTip

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRepair = $menu.Items.Add('Reparar')
    $miBackup = $menu.Items.Add('Copia de seguridad de las partidas')
    $miImport = $menu.Items.Add('Importar partidas…')
    $miFolder = $menu.Items.Add('Abrir la carpeta del juego')
    [void]$menu.Items.Add('-')
    $miUninstall = $menu.Items.Add('Desinstalar…')

    $savesMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miExportAll = $savesMenu.Items.Add('Exportar todas las partidas…')
    $miImportAll = $savesMenu.Items.Add('Importar partidas…')
    [void]$savesMenu.Items.Add('-')
    $miSavesFolder = $savesMenu.Items.Add('Abrir la carpeta de copias')

    $root = $Config.installRoot

    $refresh = {
        $flow.SuspendLayout()
        $flow.Controls.Clear()
        $games = @(Get-TrInstalledGames -Root $root)
        if (-not $games.Count) {
            $empty = New-Object System.Windows.Forms.Panel
            $empty.Size = New-Object System.Drawing.Size(800, 200)
            $empty.Controls.Add((New-TrLabel -Text 'Todavía no hay juegos instalados.' -X 10 -Y 20 -Font $global:TrTheme.FontBig))
            $b = New-TrButton -Text 'Instalar juegos' -Width 200 -Primary; $b.Location = New-Object System.Drawing.Point(10, 64)
            $b.Add_Click({ $state.reopenWizard = $true; $form.Close() })
            $empty.Controls.Add($b)
            $flow.Controls.Add($empty)
        }
        foreach ($g in $games) {
            $card = New-Object System.Windows.Forms.Panel
            $card.Size = New-Object System.Drawing.Size(255, 200); $card.Margin = New-Object System.Windows.Forms.Padding(8)
            $card.BackColor = $global:TrTheme.Card; $card.BorderStyle = 'FixedSingle'
            $pic = New-Object System.Windows.Forms.PictureBox
            $pic.Location = New-Object System.Drawing.Point(14, 14); $pic.Size = New-Object System.Drawing.Size(48, 48); $pic.SizeMode = 'Zoom'
            $img = Get-TrGameIcon -Path $g.Icon; if ($img) { $pic.Image = $img }
            $name = New-TrLabel -Text $g.Name -X 70 -Y 12 -Width 175 -Height 48 -Font $global:TrTheme.FontBold
            $age = New-TrLabel -Text $g.Age -X 70 -Y 62 -Width 175 -Color $global:TrTheme.Muted
            $mode = $(if ($g.Entry.dataMode -eq 'copy') { 'Instalado en la computadora' } else { 'Usa el disco (.iso)' })
            $st = New-TrLabel -Text $(if ($g.Healthy) { $mode } else { 'Instalación incompleta: usá «Reparar»' }) -X 14 -Y 96 -Width 230 -Font $global:TrTheme.FontSmall -Color $(if ($g.Healthy) { $global:TrTheme.Muted } else { $global:TrTheme.Bad })
            $play = New-TrButton -Text '▶  Jugar' -Width 170 -Primary; $play.Location = New-Object System.Drawing.Point(14, 140); $play.Height = 40
            $play.Tag = $g.Id
            $more = New-TrButton -Text '···' -Width 56; $more.Location = New-Object System.Drawing.Point(188, 140); $more.Height = 40
            $more.Tag = $g.Id
            $play.Add_Click({ param($sender, $e) & $startGame $sender.Tag })
            $more.Add_Click({ param($sender, $e) $menu.Tag = $sender.Tag; $menu.Show($sender, 0, $sender.Height) })
            $card.Controls.AddRange(@($pic, $name, $age, $st, $play, $more))
            $flow.Controls.Add($card)
        }
        $flow.ResumeLayout()
        $lblStatus.Text = "Instalados: $($games.Count) de $(@(Get-TrCatalog).Count)"
        $tip.SetToolTip($lblStatus, $root + $(if (Test-TrSyncEnabled $Config) { "`r`nSincronización: " + $(if ($Config.sync.mode -eq 'folder') { $Config.sync.folder } else { 'Google Drive' }) } else { '' }))
    }

    $locateIso = {
        param([string]$Id)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Imagen de disco (*.iso)|*.iso'; $dlg.Title = "Buscá el disco de «$((Get-TrGame $Id).name)»"
        if ($dlg.ShowDialog($form) -ne 'OK') { return $false }
        $found = (Find-TrIsos -Folder (Split-Path -Parent $dlg.FileName)).Isos | Where-Object { $_.Path -eq $dlg.FileName -and $_.GameId -eq $Id -and $_.Status -eq 'ok' }
        if (-not $found) { [void](Show-TrError (Get-TrErrorInfo (New-TrError 'TR-ISO-002' @{ file = [IO.Path]::GetFileName($dlg.FileName) })) $form); return $false }
        $m = Get-TrManifest -Root $root; $m.games[$Id].isoPath = $dlg.FileName; Save-TrManifest -Root $root -Manifest $m
        $true
    }

    $repairGame = {
        param([string]$Id)
        $entry = (Get-TrManifest -Root $root).games[$Id]
        if (-not (Test-Path -LiteralPath $entry.isoPath)) {
            Show-TrInfo -Title 'Necesitamos el disco' -Message "Para reparar «$((Get-TrGame $Id).name)» necesitamos su archivo .iso. Indicanos dónde está." -Owner $form
            if (-not (& $locateIso $Id)) { return }
            $entry = (Get-TrManifest -Root $root).games[$Id]
        }
        $sync = Invoke-TrWithProgress -Title "Reparando «$((Get-TrGame $Id).name)»…" -Owner $form -Arguments @{ id = $Id; iso = $entry.isoPath; root = $root; mode = $entry.dataMode } -Script {
            param($sync, $a)
            Install-TrGame -Id $a.id -IsoPath $a.iso -Root $a.root -DataMode $a.mode -Repair -Cancel $sync -OnProgress { param($p, $m) $sync.Percent = $p; $sync.Message = $m }
        }
        if ($sync.Error) { [void](Show-TrError $sync.Error $form) } else { Show-TrInfo -Title 'Reparación terminada' -Message 'El juego se reparó correctamente. Tus partidas no se modificaron.' -Owner $form }
        & $refresh
    }

    $startGame = {
        param([string]$Id)
        if (-not $state.versionChecked) { $state.versionChecked = $true; Invoke-TrRuntimeUpdateUI -Root $root -Config $Config -Owner $form }
        if (-not (Invoke-TrSyncBeforePlayUI -Id $Id -Root $root -Config $Config -Owner $form)) { return }
        $attempt = 0
        while ($attempt -lt 3) {
            $attempt++
            try {
                $state.session = Start-TrGame -Id $Id -Root $root -Scale ([int]$Config.scale)
                $lblStatus.Text = "Jugando: $((Get-TrGame $Id).name)…"
                $form.WindowState = 'Minimized'
                $gameTimer.Start()
                return
            } catch {
                $info = Get-TrErrorInfo $_
                $action = Show-TrError $info $form
                if ($action -eq 'locate') { if (& $locateIso $Id) { continue } }
                elseif ($action -eq 'repair') { & $repairGame $Id; return }
                elseif ($action -eq 'retry') { continue }
                return
            }
        }
    }

    $gameTimer = New-Object System.Windows.Forms.Timer
    $gameTimer.Interval = 500
    $gameTimer.Add_Tick({
        $s = $state.session
        if (-not $s -or -not $s.Process.HasExited) { return }
        $gameTimer.Stop()
        $diag = Complete-TrGame -Session $s
        $state.session = $null
        $form.WindowState = 'Normal'; $form.Activate()
        Invoke-TrSyncAfterPlayUI -Id $s.Id -Root $root -Config $Config -Owner $form
        & $refresh
        if ($diag) {
            $action = Show-TrError (Get-TrErrorInfo $diag) $form
            if ($action -eq 'repair') { & $repairGame $s.Id }
        }
    })

    $miRepair.Add_Click({ & $repairGame $menu.Tag })
    $miFolder.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path $root "games\$($menu.Tag)")) })
    $miBackup.Add_Click({
        try {
            $zip = Backup-TrSaves -Id $menu.Tag -Root $root
            if ($zip) { Show-TrInfo -Title 'Copia de seguridad lista' -Message "Las partidas se guardaron en:`r`n$zip" -Owner $form }
            else { Show-TrInfo -Title 'No hay partidas' -Message 'Este juego todavía no tiene partidas guardadas.' -Owner $form }
        } catch { [void](Show-TrError $_ $form) }
    })
    $importSaves = {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Copias de partidas (*.zip)|*.zip'; $dlg.Title = 'Elegí la copia de partidas (.zip)'
        if (Test-Path -LiteralPath (Get-TrSavesFolder)) { $dlg.InitialDirectory = Get-TrSavesFolder }
        if ($dlg.ShowDialog($form) -ne 'OK') { return }
        try { $content = Read-TrSavesZip -Zip $dlg.FileName } catch { [void](Show-TrError $_ $form); return }
        $names = @(Get-TrCatalog | Where-Object { $content.Games.ContainsKey($_.id) } | ForEach-Object { $_.name }) -join ', '
        if (-not (Show-TrConfirm -Title '¿Importar estas partidas?' -Message "Juegos: $names.`r`nLas partidas que tengas ahora de esos juegos se reemplazan (antes guardamos una copia en «Trampolín - partidas»)." -Yes 'Importar' -No 'Cancelar' -Owner $form)) { return }
        try { $r = Import-TrSaves -Root $root -Zip $dlg.FileName } catch { [void](Show-TrError $_ $form); return }
        $lines = @(foreach ($id in $r.Imported.Keys) { '✔ {0}: {1} archivo(s)' -f (Get-TrGame $id).name, @($r.Imported[$id]).Count })
        $lines += @(foreach ($id in $r.Skipped.Keys) { '–  {0}: {1}' -f (Get-TrGame $id).name, $r.Skipped[$id] })
        Show-TrInfo -Title $(if ($r.Imported.Count) { 'Partidas importadas' } else { 'No se importó nada' }) -Message ($lines -join "`r`n") -Owner $form
    }
    $miImport.Add_Click({ & $importSaves })
    $miImportAll.Add_Click({ & $importSaves })
    $miExportAll.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '¿Dónde guardar las partidas? (por ejemplo, un pendrive)'
        $folder = Get-TrSavesFolder
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $dlg.SelectedPath = $folder
        if ($dlg.ShowDialog($form) -ne 'OK') { return }
        try {
            $zip = Export-TrAllSaves -Root $root -Destination $dlg.SelectedPath
            if ($zip) { Show-TrInfo -Title 'Partidas exportadas' -Message "Todas las partidas quedaron en:`r`n$zip`r`n`r`nCopiá ese archivo a la otra computadora (o al Steam Deck) y usá «Importar partidas…»." -Owner $form }
            else { Show-TrInfo -Title 'No hay partidas' -Message 'Ninguno de los juegos instalados tiene partidas guardadas.' -Owner $form }
        } catch { [void](Show-TrError $_ $form) }
    })
    $miSavesFolder.Add_Click({
        $folder = Get-TrSavesFolder
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $folder)
    })
    $btnSaves.Add_Click({ $savesMenu.Show($btnSaves, (New-Object System.Drawing.Point(0, 0)), [System.Windows.Forms.ToolStripDropDownDirection]::AboveRight) })
    $miUninstall.Add_Click({
        $id = $menu.Tag; $name = (Get-TrGame $id).name
        if (-not (Show-TrConfirm -Title "¿Desinstalar «$name»?" -Message 'Se borrarán los archivos del juego de esta computadora. Antes guardaremos una copia de las partidas en Documentos.' -Yes 'Desinstalar' -No 'Cancelar' -Owner $form)) { return }
        try {
            $zip = Uninstall-TrGame -Id $id -Root $root -KeepSaves
            $msg = $(if ($zip) { "Las partidas quedaron guardadas en:`r`n$zip" } else { 'No había partidas para guardar.' })
            if (-not (Update-TrSteamShortcuts -Root $root)) { $msg += "`r`n`r`nSteam está abierto: cuando lo cierres, usá «Agregar a Steam» para quitar el juego de la lista." }
            Show-TrInfo -Title 'Juego desinstalado' -Message $msg -Owner $form
        } catch { [void](Show-TrError $_ $form) }
        & $refresh
    })

    $btnAdd.Add_Click({ $state.reopenWizard = $true; $form.Close() })
    $btnSync.Add_Click({
        if ($state.session) { [void](Show-TrError (Get-TrErrorInfo (New-TrError 'TR-RUN-001')) $form); return }
        if (Show-TrSyncDialog -Config $Config -Root $root -Owner $form) { & $refresh }
    })
    $btnSteam.Add_Click({
        if (Invoke-TrAddToSteamUI -Root $root -Owner $form) { $Config.steamShortcuts = $true; Save-TrConfig $Config }
    })
    $btnHelp.Add_Click({
        $doc = Get-TrGuidePath -Root $root
        if ($doc) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $doc) }
    })
    $btnLog.Add_Click({
        $log = Get-TrLogFile
        if ($log -and (Test-Path -LiteralPath $log)) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $log) }
    })
    $btnOptions.Add_Click({
        $f = New-TrForm -Title 'Opciones' -Width 460 -Height 230
        $f.Controls.Add((New-TrLabel -Text 'Tamaño de los juegos en pantalla' -X 20 -Y 16 -Font $global:TrTheme.FontBold))
        $opts = @(@{ v = 0; t = 'Ajustar a la pantalla (recomendado)' }, @{ v = 2; t = 'Doble de tamaño si entra' }, @{ v = 1; t = 'Tamaño original (640×480)' })
        $y = 48; $rbs = @()
        foreach ($o in $opts) {
            $rb = New-Object System.Windows.Forms.RadioButton
            $rb.Text = $o.t; $rb.Tag = $o.v; $rb.Location = New-Object System.Drawing.Point(24, $y); $rb.Width = 400
            $rb.Checked = ([int]$Config.scale -eq $o.v); $f.Controls.Add($rb); $rbs += $rb; $y += 30
        }
        $ok = New-TrButton -Text 'Guardar' -Primary; $ok.Location = New-Object System.Drawing.Point(316, 176); $ok.DialogResult = 'OK'
        $f.Controls.Add($ok); $f.AcceptButton = $ok
        if ($f.ShowDialog($form) -eq 'OK') {
            foreach ($rb in $rbs) { if ($rb.Checked) { $Config.scale = [int]$rb.Tag } }
            Save-TrConfig $Config
        }
        $f.Dispose()
    })
    $form.Add_FormClosing({
        param($sender, $e)
        if ($state.session) {
            Show-TrInfo -Title 'Hay un juego abierto' -Message 'Cerrá el juego antes de salir de la biblioteca.' -Owner $form
            $e.Cancel = $true
        }
    })
    $form.Add_Shown({ & $refresh })

    [void]$form.ShowDialog()
    $gameTimer.Dispose(); $form.Dispose()
    if ($state.reopenWizard) { return 'wizard' }
    'exit'
}
