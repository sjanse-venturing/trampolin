# Launcher.ps1 — "Biblioteca Trampolín": elegir y jugar los juegos instalados.

function Show-TrLauncher {
    param([Parameter(Mandatory)]$Config)

    $state = @{ session = $null; reopenWizard = $false; preselect = @() }
    $form = New-TrForm -Title 'Biblioteca Trampolín' -Width 880 -Height 620 -Resizable
    $form.MinimumSize = New-Object System.Drawing.Size(640, 480)
    $header = New-TrHeader -Title 'Biblioteca Trampolín' -Subtitle 'Elegí un juego y presioná «Jugar»'
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.AutoScroll = $true; $flow.Padding = New-Object System.Windows.Forms.Padding(16)
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 56; $bottom.BackColor = [System.Drawing.Color]::FromArgb(238, 234, 226)
    $btnAdd = New-TrButton -Text 'Agregar juegos…' -Width 150; $btnAdd.Location = New-Object System.Drawing.Point(16, 11)
    $btnOptions = New-TrButton -Text 'Opciones…' -Width 120; $btnOptions.Location = New-Object System.Drawing.Point(174, 11)
    $btnHelp = New-TrButton -Text 'Ayuda' -Width 100; $btnHelp.Location = New-Object System.Drawing.Point(302, 11)
    $btnLog = New-TrButton -Text 'Ver registro' -Width 120; $btnLog.Location = New-Object System.Drawing.Point(410, 11)
    $lblStatus = New-TrLabel -Text '' -X 545 -Y 19 -Width 320 -Color $global:TrTheme.Muted
    $lblStatus.AutoEllipsis = $true; $lblStatus.Anchor = 'Left,Right,Top'
    $bottom.Controls.AddRange(@($btnAdd, $btnOptions, $btnHelp, $btnLog, $lblStatus))
    $form.Controls.AddRange(@($flow, $bottom, $header))
    $tip = New-Object System.Windows.Forms.ToolTip

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRepair = $menu.Items.Add('Reparar')
    $miBackup = $menu.Items.Add('Copia de seguridad de las partidas')
    $miFolder = $menu.Items.Add('Abrir la carpeta del juego')
    [void]$menu.Items.Add('-')
    $miUninstall = $menu.Items.Add('Desinstalar…')

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
        $lblStatus.Text = "Instalados: $($games.Count) de $(@(Get-TrCatalog).Count)"; $tip.SetToolTip($lblStatus, $root)
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
    $miUninstall.Add_Click({
        $id = $menu.Tag; $name = (Get-TrGame $id).name
        if (-not (Show-TrConfirm -Title "¿Desinstalar «$name»?" -Message 'Se borrarán los archivos del juego de esta computadora. Antes guardaremos una copia de las partidas en Documentos.' -Yes 'Desinstalar' -No 'Cancelar' -Owner $form)) { return }
        try {
            $zip = Uninstall-TrGame -Id $id -Root $root -KeepSaves
            Show-TrInfo -Title 'Juego desinstalado' -Message $(if ($zip) { "Las partidas quedaron guardadas en:`r`n$zip" } else { 'No había partidas para guardar.' }) -Owner $form
        } catch { [void](Show-TrError $_ $form) }
        & $refresh
    })

    $btnAdd.Add_Click({ $state.reopenWizard = $true; $form.Close() })
    $btnHelp.Add_Click({
        $doc = @((Join-Path $root 'LEEME-RUNTIME.md'), (Join-Path (Get-TrAppRoot) 'LEEME-RUNTIME.md')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
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
