# Dialogs.ps1 — diálogos amigables (error, confirmación, progreso en segundo plano).

function Show-TrError {
    <#
      Muestra un error en lenguaje simple, con detalles técnicos plegados y
      botones de acción. Devuelve la acción elegida ('retry', 'skip', ... o 'close').
    #>
    param([Parameter(Mandatory)]$ErrorObject, $Owner = $null)
    $info = $ErrorObject
    if (-not ($ErrorObject.PSObject.Properties.Name -contains 'Code' -and $ErrorObject.PSObject.Properties.Name -contains 'Details')) {
        $info = Get-TrErrorInfo $ErrorObject
    }
    Write-TrLog Error ("Se mostró al usuario {0}: {1}" -f $info.Code, $info.Message)

    $f = New-TrForm -Title 'Trampolín' -Width 560 -Height 250
    $f.TopMost = $true
    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Image = [System.Drawing.SystemIcons]::Warning.ToBitmap()
    $pic.Location = New-Object System.Drawing.Point(20, 22); $pic.Size = New-Object System.Drawing.Size(32, 32)
    $title = New-TrLabel -Text $info.Title -X 66 -Y 20 -Width 470 -Font $global:TrTheme.FontBig
    $msg = New-TrLabel -Text $info.Message -X 66 -Y 52 -Width 470 -Height 90
    $details = New-Object System.Windows.Forms.TextBox
    $details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
    $details.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $details.Text = $info.Details -replace "`r?`n", "`r`n"
    $details.Location = New-Object System.Drawing.Point(20, 196); $details.Size = New-Object System.Drawing.Size(520, 160)
    $details.Visible = $false
    $f.Controls.AddRange(@($pic, $title, $msg, $details))

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.FlowDirection = 'RightToLeft'; $panel.Location = New-Object System.Drawing.Point(20, 150)
    $panel.Size = New-Object System.Drawing.Size(520, 42)
    $f.Controls.Add($panel)

    $result = @{ action = 'close' }
    $close = New-TrButton -Text 'Cerrar' -Width 110 -Primary
    $close.Add_Click({ $result.action = 'close'; $f.Close() }.GetNewClosure())
    $panel.Controls.Add($close)
    foreach ($a in $info.Actions) {
        if ($a -eq 'close') { continue }
        $b = New-TrButton -Text (Get-TrActionLabel $a) -Width 150
        $act = $a
        if ($a -eq 'details') {
            $b.Add_Click({
                $details.Visible = -not $details.Visible
                $f.ClientSize = New-Object System.Drawing.Size(560, $(if ($details.Visible) { 370 } else { 250 }))
            }.GetNewClosure())
        } elseif ($a -eq 'copy') {
            $b.Add_Click({ [System.Windows.Forms.Clipboard]::SetText((Get-TrReport $info)); $b.Text = 'Copiado ✓' }.GetNewClosure())
        } else {
            $b.Add_Click({ $result.action = $act; $f.Close() }.GetNewClosure())
        }
        $panel.Controls.Add($b)
    }
    if ($info.Actions -notcontains 'copy') {
        $cp = New-TrButton -Text 'Copiar informe' -Width 130
        $cp.Add_Click({ [System.Windows.Forms.Clipboard]::SetText((Get-TrReport $info)); $cp.Text = 'Copiado ✓' }.GetNewClosure())
        $panel.Controls.Add($cp)
    }
    $f.AcceptButton = $close
    [void]$f.ShowDialog($Owner)
    $f.Dispose()
    $result.action
}

function Show-TrConfirm {
    param([string]$Title, [string]$Message, [string]$Yes = 'Sí', [string]$No = 'No', $Owner = $null)
    $f = New-TrForm -Title 'Trampolín' -Width 500 -Height 200
    $t = New-TrLabel -Text $Title -X 20 -Y 18 -Width 460 -Font $global:TrTheme.FontBig
    $m = New-TrLabel -Text $Message -X 20 -Y 52 -Width 460 -Height 80
    $by = New-TrButton -Text $Yes -Width 140 -Primary; $by.Location = New-Object System.Drawing.Point(340, 145)
    $bn = New-TrButton -Text $No -Width 140; $bn.Location = New-Object System.Drawing.Point(190, 145)
    $by.DialogResult = 'Yes'; $bn.DialogResult = 'No'
    $f.Controls.AddRange(@($t, $m, $by, $bn)); $f.AcceptButton = $by; $f.CancelButton = $bn
    $r = $f.ShowDialog($Owner); $f.Dispose()
    $r -eq 'Yes'
}

function Show-TrInfo {
    param([string]$Title, [string]$Message, $Owner = $null)
    $f = New-TrForm -Title 'Trampolín' -Width 500 -Height 190
    $t = New-TrLabel -Text $Title -X 20 -Y 18 -Width 460 -Font $global:TrTheme.FontBig
    $m = New-TrLabel -Text $Message -X 20 -Y 52 -Width 460 -Height 80
    $ok = New-TrButton -Text 'Aceptar' -Width 120 -Primary; $ok.Location = New-Object System.Drawing.Point(360, 140); $ok.DialogResult = 'OK'
    $f.Controls.AddRange(@($t, $m, $ok)); $f.AcceptButton = $ok
    [void]$f.ShowDialog($Owner); $f.Dispose()
}

function Start-TrBackground {
    <#
      Ejecuta $Script en otro runspace (con los módulos de Trampolín cargados) para
      no congelar la ventana. $Script recibe ($Sync, $Arguments). $Sync es un
      hashtable sincronizado con: Percent, Message, Done, Error, Result, Cancel.
    #>
    param([Parameter(Mandatory)][scriptblock]$Script, $Arguments = $null)
    $sync = [hashtable]::Synchronized(@{ Percent = 0; Message = ''; Done = $false; Error = $null; Result = $null; Cancel = $false; Lines = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)) })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $core = Join-Path $PSScriptRoot '..\Core'
    $strings = Join-Path $PSScriptRoot '..\data\strings.es.json'
    $logFile = Get-TrLogFile
    [void]$ps.AddScript({
        param($core, $strings, $logFile, $sync, $body, $arguments)
        $ErrorActionPreference = 'Stop'
        try {
            Import-Module (Join-Path $core 'Trampolin.Errors.psm1')
            Import-Module (Join-Path $core 'Trampolin.Core.psm1')
            Import-TrStrings $strings
            if ($logFile) { Initialize-TrLog (Split-Path -Parent $logFile) }
            $sync.Result = & ([scriptblock]::Create($body)) $sync $arguments
        } catch {
            $sync.Error = Get-TrErrorInfo $_
        } finally { $sync.Done = $true }
    }).AddArgument($core).AddArgument($strings).AddArgument($logFile).AddArgument($sync).AddArgument($Script.ToString()).AddArgument($Arguments)
    $handle = $ps.BeginInvoke()
    $sync.PowerShell = $ps; $sync.Handle = $handle; $sync.Runspace = $rs
    $sync
}

function Stop-TrBackground {
    param($Sync)
    try { $Sync.PowerShell.EndInvoke($Sync.Handle) } catch { }
    try { $Sync.PowerShell.Dispose(); $Sync.Runspace.Dispose() } catch { }
}

function Invoke-TrWithProgress {
    <# Ventanita modal de progreso para tareas cortas (reparar, copia de seguridad...). Devuelve $Sync. #>
    param([string]$Title, [scriptblock]$Script, $Arguments, $Owner = $null)
    $f = New-TrForm -Title 'Trampolín' -Width 460 -Height 140
    $f.ControlBox = $false
    $l = New-TrLabel -Text $Title -X 20 -Y 18 -Width 420
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(20, 52); $bar.Size = New-Object System.Drawing.Size(420, 22)
    $sub = New-TrLabel -Text '' -X 20 -Y 84 -Width 420 -Font $global:TrTheme.FontSmall -Color $global:TrTheme.Muted
    $f.Controls.AddRange(@($l, $bar, $sub))
    $sync = Start-TrBackground -Script $Script -Arguments $Arguments
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 150
    $timer.Add_Tick({
        $bar.Value = [Math]::Max(0, [Math]::Min(100, [int]$sync.Percent)); $sub.Text = $sync.Message
        if ($sync.Done) { $timer.Stop(); $f.Close() }
    }.GetNewClosure())
    $f.Add_Shown({ $timer.Start() }.GetNewClosure())
    [void]$f.ShowDialog($Owner)
    $timer.Dispose(); $f.Dispose()
    Stop-TrBackground $sync
    $sync
}
