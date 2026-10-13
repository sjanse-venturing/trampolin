# Wizard.ps1 — asistente de instalación de Trampolín Runtime (WinForms).
#
# Los manejadores de eventos se ejecutan mientras ShowDialog() está activo dentro
# de Show-TrWizard, así que ven sus variables locales. El estado mutable vive en
# el hashtable $state; los datos por control, en la propiedad .Tag.

function Show-TrWizard {
    param([Parameter(Mandatory)]$Config, [string[]]$Preselect = @())

    $catalog = @(Get-TrCatalog)
    $state = @{
        page = 0; found = @(); zips = @(); sync = $null; results = @(); installed = $false; cancelled = $false
        isoFolder = $(if ($Config.isoFolder) { $Config.isoFolder } else { Get-TrDefaultIsoFolder })
        root = $(if ($Config.installRoot) { $Config.installRoot } else { Get-TrDefaultInstallRoot })
        mode = $Config.dataMode; scale = [int]$Config.scale; desktop = [bool]$Config.desktopShortcuts
    }

    $form = New-TrForm -Title 'Instalar Trampolín' -Width 780 -Height 580
    $header = New-TrHeader -Title 'Trampolín' -Subtitle 'Instalación de los juegos clásicos en Windows 10/11'
    $content = New-Object System.Windows.Forms.Panel
    $content.Location = New-Object System.Drawing.Point(0, 78); $content.Size = New-Object System.Drawing.Size(780, 442)
    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = 'Bottom'; $footer.Height = 60; $footer.BackColor = [System.Drawing.Color]::FromArgb(238, 234, 226)
    $btnBack = New-TrButton -Text '< Atrás'; $btnBack.Location = New-Object System.Drawing.Point(380, 13)
    $btnNext = New-TrButton -Text 'Siguiente >' -Primary; $btnNext.Location = New-Object System.Drawing.Point(510, 13)
    $btnCancel = New-TrButton -Text 'Cancelar'; $btnCancel.Location = New-Object System.Drawing.Point(640, 13)
    $footer.Controls.AddRange(@($btnBack, $btnNext, $btnCancel))
    $form.Controls.AddRange(@($content, $footer, $header))

    function New-Page {
        $p = New-Object System.Windows.Forms.Panel
        $p.Dock = 'Fill'; $p.Padding = New-Object System.Windows.Forms.Padding(24, 16, 24, 8); $p.Visible = $false
        $content.Controls.Add($p)
        $p
    }

    # ---- Página 0: bienvenida y requisitos --------------------------------
    $p0 = New-Page
    $p0.Controls.Add((New-TrLabel -Text '¡Hola! Este asistente instala los juegos Trampolín para que funcionen en esta computadora, sin máquinas virtuales.' -X 24 -Y 16 -Width 720 -Height 44))
    $p0.Controls.Add((New-TrLabel -Text 'Revisamos que todo esté listo:' -X 24 -Y 70 -Font $global:TrTheme.FontBold))
    $lvReq = New-Object System.Windows.Forms.ListView
    $lvReq.View = 'Details'; $lvReq.FullRowSelect = $true; $lvReq.HeaderStyle = 'Nonclickable'
    $lvReq.Location = New-Object System.Drawing.Point(24, 98); $lvReq.Size = New-Object System.Drawing.Size(728, 170)
    [void]$lvReq.Columns.Add('', 40); [void]$lvReq.Columns.Add('Requisito', 260); [void]$lvReq.Columns.Add('Detalle', 410)
    $p0.Controls.Add($lvReq)
    $lblReq = New-TrLabel -Text '' -X 24 -Y 280 -Width 728 -Height 60
    $p0.Controls.Add($lblReq)
    $p0.Controls.Add((New-TrLabel -Text 'Vas a necesitar los archivos de los discos (.iso) o el archivo trampolin_anaya.zip.' -X 24 -Y 350 -Width 728 -Color $global:TrTheme.Muted))

    # ---- Página 1: ubicación de las ISOs ----------------------------------
    $p1 = New-Page
    $p1.Controls.Add((New-TrLabel -Text '¿Dónde están los discos de los juegos?' -X 24 -Y 12 -Font $global:TrTheme.FontBig))
    $p1.Controls.Add((New-TrLabel -Text 'Elegí la carpeta que contiene los archivos .iso (o el .zip con todos los discos).' -X 24 -Y 44 -Width 728))
    $txtIso = New-Object System.Windows.Forms.TextBox
    $txtIso.Location = New-Object System.Drawing.Point(24, 76); $txtIso.Width = 470
    $btnIsoBrowse = New-TrButton -Text 'Examinar…' -Width 110; $btnIsoBrowse.Location = New-Object System.Drawing.Point(502, 72)
    $btnIsoScan = New-TrButton -Text 'Buscar' -Width 130; $btnIsoScan.Location = New-Object System.Drawing.Point(620, 72)
    $lvIso = New-Object System.Windows.Forms.ListView
    $lvIso.View = 'Details'; $lvIso.FullRowSelect = $true
    $lvIso.Location = New-Object System.Drawing.Point(24, 116); $lvIso.Size = New-Object System.Drawing.Size(728, 230)
    [void]$lvIso.Columns.Add('Juego', 260); [void]$lvIso.Columns.Add('Estado', 120); [void]$lvIso.Columns.Add('Archivo', 340)
    $lblIso = New-TrLabel -Text '' -X 24 -Y 352 -Width 560 -Height 44
    $btnZip = New-TrButton -Text 'Extraer el ZIP…' -Width 160; $btnZip.Location = New-Object System.Drawing.Point(592, 356); $btnZip.Visible = $false
    $p1.Controls.AddRange(@($txtIso, $btnIsoBrowse, $btnIsoScan, $lvIso, $lblIso, $btnZip))

    # ---- Página 2: elegir juegos --------------------------------------------
    $p2 = New-Page
    $p2.Controls.Add((New-TrLabel -Text 'Elegí los juegos a instalar' -X 24 -Y 12 -Font $global:TrTheme.FontBig))
    $lvGames = New-Object System.Windows.Forms.ListView
    $lvGames.View = 'Details'; $lvGames.CheckBoxes = $true; $lvGames.FullRowSelect = $true
    $lvGames.Location = New-Object System.Drawing.Point(24, 48); $lvGames.Size = New-Object System.Drawing.Size(728, 300)
    [void]$lvGames.Columns.Add('Juego', 330); [void]$lvGames.Columns.Add('Edad', 110); [void]$lvGames.Columns.Add('Disco', 260)
    $btnAll = New-TrButton -Text 'Todos' -Width 100; $btnAll.Location = New-Object System.Drawing.Point(24, 358)
    $btnNone = New-TrButton -Text 'Ninguno' -Width 100; $btnNone.Location = New-Object System.Drawing.Point(132, 358)
    $lblGames = New-TrLabel -Text '' -X 250 -Y 364 -Width 500 -Color $global:TrTheme.Muted
    $p2.Controls.AddRange(@($lvGames, $btnAll, $btnNone, $lblGames))

    # ---- Página 3: carpeta y modo -------------------------------------------
    $p3 = New-Page
    $p3.Controls.Add((New-TrLabel -Text '¿Dónde querés instalar los juegos?' -X 24 -Y 12 -Font $global:TrTheme.FontBig))
    $txtRoot = New-Object System.Windows.Forms.TextBox
    $txtRoot.Location = New-Object System.Drawing.Point(24, 52); $txtRoot.Width = 590
    $btnRoot = New-TrButton -Text 'Examinar…' -Width 130; $btnRoot.Location = New-Object System.Drawing.Point(622, 48)
    $p3.Controls.Add((New-TrLabel -Text 'No hace falta ser administrador. Usá una ruta corta y sin caracteres especiales.' -X 24 -Y 84 -Width 728 -Color $global:TrTheme.Muted))
    $rbCopy = New-Object System.Windows.Forms.RadioButton
    $rbCopy.Text = 'Copiar los juegos completos a la computadora (recomendado: después no necesitás los .iso)'
    $rbCopy.Location = New-Object System.Drawing.Point(24, 126); $rbCopy.Width = 728
    $rbIso = New-Object System.Windows.Forms.RadioButton
    $rbIso.Text = 'Usar los discos (.iso) desde donde están ahora (ocupa menos espacio)'
    $rbIso.Location = New-Object System.Drawing.Point(24, 158); $rbIso.Width = 728
    $lblSpace = New-TrLabel -Text '' -X 24 -Y 206 -Width 728 -Font $global:TrTheme.FontBold
    $p3.Controls.AddRange(@($txtRoot, $btnRoot, $rbCopy, $rbIso, $lblSpace))

    # ---- Página 4: pantalla --------------------------------------------------
    $p4 = New-Page
    $p4.Controls.Add((New-TrLabel -Text '¿Cómo se ven los juegos?' -X 24 -Y 12 -Font $global:TrTheme.FontBig))
    $p4.Controls.Add((New-TrLabel -Text 'Los juegos se diseñaron para 640×480. Podés agrandarlos para que ocupen tu pantalla.' -X 24 -Y 44 -Width 728))
    $scaleOptions = @(
        @{ v = 0; t = 'Ajustar a la pantalla (recomendado)' },
        @{ v = 2; t = 'Doble de tamaño (1280×960) si entra en la pantalla' },
        @{ v = 1; t = 'Tamaño original (640×480, más chico)' }
    )
    $y = 84
    $rbScale = @()
    foreach ($o in $scaleOptions) {
        $rb = New-Object System.Windows.Forms.RadioButton
        $rb.Text = $o.t; $rb.Tag = $o.v; $rb.Location = New-Object System.Drawing.Point(24, $y); $rb.Width = 700
        $p4.Controls.Add($rb); $rbScale += $rb; $y += 34
    }
    $chkDesktop = New-Object System.Windows.Forms.CheckBox
    $chkDesktop.Text = 'Crear accesos directos en el Escritorio'; $chkDesktop.Location = New-Object System.Drawing.Point(24, 210); $chkDesktop.Width = 600
    $p4.Controls.Add($chkDesktop)
    $p4.Controls.Add((New-TrLabel -Text 'Siempre se agregan al menú Inicio, en la carpeta «Trampolín».' -X 24 -Y 240 -Width 700 -Color $global:TrTheme.Muted))

    # ---- Página 5: resumen ---------------------------------------------------
    $p5 = New-Page
    $p5.Controls.Add((New-TrLabel -Text 'Todo listo para instalar' -X 24 -Y 12 -Font $global:TrTheme.FontBig))
    $txtSummary = New-Object System.Windows.Forms.TextBox
    $txtSummary.Multiline = $true; $txtSummary.ReadOnly = $true; $txtSummary.BackColor = [System.Drawing.Color]::White
    $txtSummary.Location = New-Object System.Drawing.Point(24, 48); $txtSummary.Size = New-Object System.Drawing.Size(728, 330); $txtSummary.ScrollBars = 'Vertical'
    $p5.Controls.Add($txtSummary)

    # ---- Página 6: instalando -----------------------------------------------
    $p6 = New-Page
    $lblInstTitle = New-TrLabel -Text 'Instalando…' -X 24 -Y 12 -Font $global:TrTheme.FontBig
    $barAll = New-Object System.Windows.Forms.ProgressBar
    $barAll.Location = New-Object System.Drawing.Point(24, 56); $barAll.Size = New-Object System.Drawing.Size(728, 26)
    $lblInst = New-TrLabel -Text '' -X 24 -Y 92 -Width 728 -Height 44
    $lstLog = New-Object System.Windows.Forms.ListBox
    $lstLog.Location = New-Object System.Drawing.Point(24, 142); $lstLog.Size = New-Object System.Drawing.Size(728, 230)
    $lstLog.Font = $global:TrTheme.FontSmall
    $p6.Controls.AddRange(@($lblInstTitle, $barAll, $lblInst, $lstLog))

    # ---- Página 7: final ----------------------------------------------------
    $p7 = New-Page
    $lblDone = New-TrLabel -Text '¡Listo!' -X 24 -Y 12 -Width 728 -Font $global:TrTheme.FontBig
    $lvDone = New-Object System.Windows.Forms.ListView
    $lvDone.View = 'Details'; $lvDone.FullRowSelect = $true
    $lvDone.Location = New-Object System.Drawing.Point(24, 52); $lvDone.Size = New-Object System.Drawing.Size(728, 280)
    [void]$lvDone.Columns.Add('', 40); [void]$lvDone.Columns.Add('Juego', 300); [void]$lvDone.Columns.Add('Resultado', 380)
    $lblDone2 = New-TrLabel -Text 'Podés jugar desde la «Biblioteca Trampolín» o desde los accesos directos del menú Inicio.' -X 24 -Y 342 -Width 728 -Height 44
    $p7.Controls.AddRange(@($lblDone, $lvDone, $lblDone2))

    $pages = @($p0, $p1, $p2, $p3, $p4, $p5, $p6, $p7)

    # ---- Lógica ---------------------------------------------------------------
    $refreshSpace = {
        $ids = @($lvGames.CheckedItems | ForEach-Object { $_.Tag.id })
        $mode = $(if ($rbCopy.Checked) { 'copy' } else { 'iso' })
        $need = Get-TrRequiredBytes -GameIds $ids -DataMode $mode
        $free = $null
        try { $free = (New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($txtRoot.Text)))).AvailableFreeSpace } catch { }
        $lblSpace.Text = 'Espacio necesario: ' + (Format-TrSize $need) + $(if ($null -ne $free) { '   —   Libre: ' + (Format-TrSize $free) } else { '' })
        $lblSpace.ForeColor = $(if ($null -ne $free -and $free -lt $need) { $global:TrTheme.Bad } else { $global:TrTheme.Ok })
    }

    $scanIsos = {
        $form.Cursor = 'WaitCursor'
        $lvIso.Items.Clear(); $btnZip.Visible = $false
        try {
            $r = Find-TrIsos -Folder $txtIso.Text
            $state.found = @($r.Isos); $state.zips = @($r.Zips); $state.isoFolder = $txtIso.Text
            foreach ($i in $state.found) {
                $gname = '(desconocido)'
                if ($i.GameId) { $gname = (Get-TrGame $i.GameId).name }
                $status = switch ($i.Status) { 'ok' { 'Listo ✓' } 'invalid' { 'Dañado ✗' } default { 'No reconocido' } }
                $it = New-Object System.Windows.Forms.ListViewItem($gname)
                [void]$it.SubItems.Add($status); [void]$it.SubItems.Add($i.Name)
                if ($i.Message) { $it.ToolTipText = $i.Message }
                if ($i.Status -ne 'ok') { $it.ForeColor = $global:TrTheme.Bad }
                [void]$lvIso.Items.Add($it)
            }
            $ok = @($state.found | Where-Object { $_.Status -eq 'ok' }).Count
            $lblIso.Text = "Encontramos $ok de $($catalog.Count) juegos."
            $lblIso.ForeColor = $(if ($ok) { $global:TrTheme.Ok } else { $global:TrTheme.Bad })
            if ($state.zips.Count -and $ok -lt $catalog.Count) {
                $btnZip.Visible = $true
                $lblIso.Text += " También hay un archivo .zip ($($state.zips[0].Name)) que puede contener los discos."
            }
        } catch {
            $info = Get-TrErrorInfo $_
            Write-TrLog Error "Búsqueda de discos falló: $($info.Details)"
            $lblIso.Text = $info.Message; $lblIso.ForeColor = $global:TrTheme.Bad
            $state.found = @()
        } finally { $form.Cursor = 'Default' }
    }

    $fillGames = {
        $lvGames.Items.Clear()
        foreach ($g in $catalog) {
            $iso = $state.found | Where-Object { $_.GameId -eq $g.id -and $_.Status -eq 'ok' } | Select-Object -First 1
            $it = New-Object System.Windows.Forms.ListViewItem($g.name)
            [void]$it.SubItems.Add($g.age)
            [void]$it.SubItems.Add($(if ($iso) { $iso.Name } else { 'No se encontró el disco' }))
            $it.Tag = @{ id = $g.id; iso = $(if ($iso) { $iso.Path } else { $null }) }
            if (-not $iso) { $it.ForeColor = [System.Drawing.Color]::Gray }
            [void]$lvGames.Items.Add($it)
            $it.Checked = [bool]$iso -and ($Preselect.Count -eq 0 -or $Preselect -contains $g.id)
        }
    }

    $showPage = {
        param([int]$n)
        for ($i = 0; $i -lt $pages.Count; $i++) { $pages[$i].Visible = ($i -eq $n) }
        $state.page = $n
        $btnBack.Enabled = ($n -gt 0 -and $n -lt 6); $btnBack.Visible = ($n -ne 7)
        $btnNext.Visible = ($n -ne 6)
        $btnCancel.Visible = ($n -ne 7)
        $btnNext.Text = switch ($n) { 5 { 'Instalar' } 7 { 'Abrir la biblioteca' } default { 'Siguiente >' } }
        $btnNext.Width = $(if ($n -eq 7) { 250 } else { 120 })
        if ($n -eq 7) { $btnNext.Location = New-Object System.Drawing.Point(500, 13) } else { $btnNext.Location = New-Object System.Drawing.Point(510, 13) }
        switch ($n) {
            0 {
                $lvReq.Items.Clear(); $blocking = $false
                foreach ($r in Test-TrPrerequisites) {
                    $it = New-Object System.Windows.Forms.ListViewItem($(if ($r.Ok) { '✔' } elseif ($r.Blocking) { '✖' } else { '⚠' }))
                    [void]$it.SubItems.Add($r.Name); [void]$it.SubItems.Add([string]$r.Detail)
                    $it.ForeColor = $(if ($r.Ok) { $global:TrTheme.Ok } elseif ($r.Blocking) { $global:TrTheme.Bad } else { $global:TrTheme.Warn })
                    [void]$lvReq.Items.Add($it)
                    if (-not $r.Ok -and $r.Blocking) { $blocking = $true }
                }
                $btnNext.Enabled = -not $blocking
                $lblReq.Text = $(if ($blocking) { 'Hay un requisito que no se cumple. Revisá el detalle y volvé a abrir el instalador.' } else { 'Todo en orden. Presioná «Siguiente».' })
                $lblReq.ForeColor = $(if ($blocking) { $global:TrTheme.Bad } else { $global:TrTheme.Ok })
                if (Get-Command Mount-DiskImage -ErrorAction SilentlyContinue) { } else { $state.mode = 'copy' }
            }
            1 { $btnNext.Enabled = $true; if (-not $txtIso.Text) { $txtIso.Text = $state.isoFolder }; if ($lvIso.Items.Count -eq 0 -and $txtIso.Text) { & $scanIsos } }
            2 { & $fillGames; $lblGames.Text = 'Los juegos en gris no tienen su disco en la carpeta elegida.' }
            3 {
                if (-not $txtRoot.Text) { $txtRoot.Text = $state.root }
                $rbCopy.Checked = ($state.mode -ne 'iso'); $rbIso.Checked = ($state.mode -eq 'iso')
                $rbIso.Enabled = [bool](Get-Command Mount-DiskImage -ErrorAction SilentlyContinue)
                & $refreshSpace
            }
            4 { foreach ($rb in $rbScale) { $rb.Checked = ([int]$rb.Tag -eq $state.scale) }; $chkDesktop.Checked = $state.desktop }
            5 {
                $sel = @($lvGames.CheckedItems | ForEach-Object { $_.Text })
                $mode = $(if ($state.mode -eq 'copy') { 'Copiar los juegos completos a la computadora' } else { 'Usar los .iso desde su ubicación' })
                $scaleText = ($scaleOptions | Where-Object { $_.v -eq $state.scale }).t
                $txtSummary.Text = (@(
                    "Juegos a instalar ($($sel.Count)):"
                ) + ($sel | ForEach-Object { "   • $_" }) + @(
                    '',
                    "Carpeta de instalación:  $($state.root)",
                    "Modo:  $mode",
                    "Pantalla:  $scaleText",
                    "Accesos directos en el Escritorio:  $(if ($state.desktop) { 'Sí' } else { 'No' })",
                    '',
                    "Espacio necesario aproximado:  $(Format-TrSize (Get-TrRequiredBytes -GameIds @($lvGames.CheckedItems | ForEach-Object { $_.Tag.id }) -DataMode $state.mode))"
                )) -join "`r`n"
            }
        }
    }

    $validatePage = {
        switch ($state.page) {
            1 {
                if (-not @($state.found | Where-Object { $_.Status -eq 'ok' }).Count) {
                    [void](Show-TrError (Get-TrErrorInfo (New-TrError 'TR-ISO-001' @{ path = $txtIso.Text })) $form); return $false
                }
            }
            2 {
                if ($lvGames.CheckedItems.Count -eq 0) { Show-TrInfo -Title 'Elegí al menos un juego' -Message 'Marcá la casilla de los juegos que querés instalar.' -Owner $form; return $false }
            }
            3 {
                $state.mode = $(if ($rbCopy.Checked) { 'copy' } else { 'iso' })
                $need = Get-TrRequiredBytes -GameIds @($lvGames.CheckedItems | ForEach-Object { $_.Tag.id }) -DataMode $state.mode
                try { $state.root = Test-TrInstallRoot -Path $txtRoot.Text -RequiredBytes $need; $txtRoot.Text = $state.root }
                catch { [void](Show-TrError $_ $form); return $false }
            }
            4 {
                foreach ($rb in $rbScale) { if ($rb.Checked) { $state.scale = [int]$rb.Tag } }
                $state.desktop = $chkDesktop.Checked
            }
        }
        $true
    }

    $startInstall = {
        $games = @($lvGames.CheckedItems | ForEach-Object { @{ id = $_.Tag.id; iso = $_.Tag.iso } })
        $Config.installRoot = $state.root; $Config.isoFolder = $state.isoFolder; $Config.dataMode = $state.mode
        $Config.scale = $state.scale; $Config.desktopShortcuts = $state.desktop
        Save-TrConfig $Config
        Initialize-TrLog (Join-Path $state.root 'logs')
        Write-TrLog Info ("Instalación: {0} juego(s) en {1}, modo {2}" -f $games.Count, $state.root, $state.mode)
        $lstLog.Items.Clear()
        & $showPage 6
        $state.sync = Start-TrBackground -Arguments @{ root = $state.root; mode = $state.mode; games = $games; desktop = $state.desktop } -Script {
            param($sync, $a)
            $results = @()
            $sync.Message = 'Copiando el programa…'
            Install-TrRuntimeFiles -Root $a.root | Out-Null
            $n = $a.games.Count; $i = 0
            foreach ($g in $a.games) {
                $name = (Get-TrGame $g.id).name
                if ($sync.Cancel) { $results += @{ id = $g.id; ok = $false; msg = 'Cancelado' }; continue }
                [void]$sync.Lines.Add("Instalando $name…")
                try {
                    $base = 100 * $i / $n
                    Install-TrGame -Id $g.id -IsoPath $g.iso -Root $a.root -DataMode $a.mode -Cancel $sync -OnProgress {
                        param($p, $m) $sync.Percent = [int]($base + $p / $n); $sync.Message = $m
                    }
                    New-TrShortcuts -Id $g.id -Root $a.root -Desktop $a.desktop
                    $results += @{ id = $g.id; ok = $true; msg = 'Instalado correctamente' }
                    [void]$sync.Lines.Add("✓ $name")
                } catch [OperationCanceledException] {
                    $results += @{ id = $g.id; ok = $false; msg = 'Cancelado' }; [void]$sync.Lines.Add("Cancelado: $name")
                } catch {
                    $info = Get-TrErrorInfo $_
                    $results += @{ id = $g.id; ok = $false; msg = $info.Message; info = $info }
                    [void]$sync.Lines.Add("✗ ${name}: $($info.Message)")
                }
                $i++
            }
            $sync.Percent = 100
            $results
        }
        $timer.Start()
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $state.shownLines = 0
    $timer.Add_Tick({
        $s = $state.sync
        if (-not $s) { return }
        $barAll.Value = [Math]::Max(0, [Math]::Min(100, [int]$s.Percent))
        $lblInst.Text = $s.Message
        while ($state.shownLines -lt $s.Lines.Count) { [void]$lstLog.Items.Add($s.Lines[$state.shownLines]); $state.shownLines++; $lstLog.TopIndex = $lstLog.Items.Count - 1 }
        if ($s.Done) {
            $timer.Stop()
            Stop-TrBackground $s
            $lvDone.Items.Clear()
            if ($s.Error) {
                [void](Show-TrError $s.Error $form)
                $state.results = @()
            } else { $state.results = @($s.Result) }
            $okCount = 0
            foreach ($r in $state.results) {
                $it = New-Object System.Windows.Forms.ListViewItem($(if ($r.ok) { '✔' } else { '✖' }))
                [void]$it.SubItems.Add((Get-TrGame $r.id).name); [void]$it.SubItems.Add($r.msg)
                $it.ForeColor = $(if ($r.ok) { $global:TrTheme.Ok } else { $global:TrTheme.Bad })
                $it.Tag = $r
                [void]$lvDone.Items.Add($it)
                if ($r.ok) { $okCount++ }
            }
            $state.installed = ($okCount -gt 0)
            $lblDone.Text = $(if ($state.cancelled) { 'Instalación cancelada' } elseif ($okCount -eq $state.results.Count -and $okCount) { '¡Listo! Los juegos ya están instalados.' } else { "Se instalaron $okCount de $($state.results.Count) juegos." })
            & $showPage 7
            if (-not $state.installed) { $btnNext.Text = 'Cerrar' }
        }
    })

    # ---- Eventos ----------------------------------------------------------------
    $btnIsoBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Elegí la carpeta donde están los archivos .iso de Trampolín'
        if ($txtIso.Text -and (Test-Path -LiteralPath $txtIso.Text)) { $dlg.SelectedPath = $txtIso.Text }
        if ($dlg.ShowDialog($form) -eq 'OK') { $txtIso.Text = $dlg.SelectedPath; & $scanIsos }
    })
    $btnIsoScan.Add_Click({ & $scanIsos })
    $btnZip.Add_Click({
        $zip = $state.zips[0].FullName
        $dest = Join-Path (Split-Path -Parent $zip) 'Trampolin ISOs'
        if (-not (Show-TrConfirm -Title 'Extraer los discos' -Message "Vamos a extraer los discos de «$($state.zips[0].Name)» en la carpeta «$dest». Necesita unos 2,5 GB libres." -Yes 'Extraer' -No 'Cancelar' -Owner $form)) { return }
        $sync = Invoke-TrWithProgress -Title 'Extrayendo los discos del ZIP…' -Owner $form -Arguments @{ zip = $zip; dest = $dest } -Script {
            param($sync, $a)
            Expand-TrZipIsos -Zip $a.zip -Destination $a.dest -Cancel $sync -OnProgress { param($p, $m) $sync.Percent = $p; $sync.Message = $m }
        }
        if ($sync.Error) { [void](Show-TrError $sync.Error $form) } else { $txtIso.Text = $dest; & $scanIsos }
    })
    $lvGames.Add_ItemCheck({
        param($sender, $e)
        $it = $lvGames.Items[$e.Index]
        if ($e.NewValue -eq 'Checked' -and -not $it.Tag.iso) { $e.NewValue = 'Unchecked' }
    })
    $btnAll.Add_Click({ foreach ($it in $lvGames.Items) { if ($it.Tag.iso) { $it.Checked = $true } } })
    $btnNone.Add_Click({ foreach ($it in $lvGames.Items) { $it.Checked = $false } })
    $btnRoot.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Elegí la carpeta de instalación'
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog($form) -eq 'OK') { $txtRoot.Text = Join-Path $dlg.SelectedPath 'Trampolin'; & $refreshSpace }
    })
    $txtRoot.Add_TextChanged({ & $refreshSpace })
    $rbCopy.Add_CheckedChanged({ & $refreshSpace })

    $btnBack.Add_Click({ if ($state.page -gt 0) { & $showPage ($state.page - 1) } })
    $btnNext.Add_Click({
        if ($state.page -eq 7) { $form.DialogResult = 'OK'; $form.Close(); return }
        if (-not (& $validatePage)) { return }
        if ($state.page -eq 5) { & $startInstall; return }
        & $showPage ($state.page + 1)
    })
    $btnCancel.Add_Click({
        if ($state.page -eq 6) {
            if ($state.sync -and -not $state.sync.Done -and (Show-TrConfirm -Title '¿Cancelar la instalación?' -Message 'Se deshará la instalación del juego que se está copiando. Los juegos ya terminados quedan instalados.' -Yes 'Cancelar instalación' -No 'Seguir' -Owner $form)) {
                $state.sync.Cancel = $true; $state.cancelled = $true; $lblInst.Text = 'Cancelando…'
            }
            return
        }
        $form.DialogResult = 'Cancel'; $form.Close()
    })
    $form.Add_FormClosing({
        param($sender, $e)
        if ($state.page -eq 6 -and $state.sync -and -not $state.sync.Done) { $e.Cancel = $true }
    })
    $form.Add_Shown({ & $showPage 0 })

    [void]$form.ShowDialog()
    $timer.Dispose(); $form.Dispose()
    $state.installed
}

function Get-TrDefaultIsoFolder {
    # Carpeta probable de las ISOs: la del programa, Descargas o Documentos.
    $candidates = @(
        (Split-Path -Parent (Get-TrAppRoot)),
        (Join-Path $env:USERPROFILE 'Downloads'),
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('Desktop')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c) -and (Get-ChildItem -LiteralPath $c -Filter '*.iso' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $c }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c) -and (Get-ChildItem -LiteralPath $c -Filter 'trampolin*.zip' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $c }
    }
    [Environment]::GetFolderPath('MyDocuments')
}
