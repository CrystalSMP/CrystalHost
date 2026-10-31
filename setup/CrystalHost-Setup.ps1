# CrystalHost-Setup (mit Fenster, ohne Terminal)
#   - richtet einen neuen Minecraft-Server ein ODER bindet einen Server ein, der schon auf dem PC liegt
#   - laedt Java, (bei neuem Server) Paper, ein eigenes Python und die Tunnel-Programme
#   - alles landet in %USERPROFILE%\CrystalHost\<Servername> - nichts wird systemweit installiert
#   - am Ende: Owner-Code + Knopf zum Online-Panel (https://crystalsmp.github.io/CrystalHost/panel/)
# Start ueber CrystalHost-Setup.vbs (Doppelklick) - dann erscheint kein Konsolenfenster.
param(
    [string]$Source = "https://raw.githubusercontent.com/CrystalSMP/CrystalHost/main/app",  # oder lokaler Ordner zum Testen
    [string]$Root = (Join-Path $env:USERPROFILE "CrystalHost"),
    [string]$AutoTest = ""   # nur fuer Tests: Ordner eines vorhandenen Servers -> Formular wird automatisch ausgefuellt und abgeschickt
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$PYTHON_VERSION = "3.13.9"
$PANEL_URL = "https://crystalsmp.github.io/CrystalHost/panel/"

# ------------------------------------------------------------------ Farben / Fenster
$bg = [Drawing.Color]::FromArgb(11, 13, 18); $card = [Drawing.Color]::FromArgb(20, 24, 33); $line = [Drawing.Color]::FromArgb(35, 42, 55)
$fg = [Drawing.Color]::FromArgb(231, 234, 240); $muted = [Drawing.Color]::FromArgb(138, 147, 166); $accent = [Drawing.Color]::FromArgb(139, 92, 246)
$fontUi = New-Object Drawing.Font("Segoe UI", 10); $fontBold = New-Object Drawing.Font("Segoe UI Semibold", 10)

$form = New-Object Windows.Forms.Form
$form.Text = "CrystalHost Setup"; $form.ClientSize = New-Object Drawing.Size(560, 640); $form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"; $form.MaximizeBox = $false; $form.BackColor = $bg; $form.ForeColor = $fg; $form.Font = $fontUi

function New-Label($text, $x, $y, $w = 500, $h = 22, $font = $fontUi, $color = $fg) {
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y)
    $l.Size = New-Object Drawing.Size($w, $h); $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [Drawing.Color]::Transparent
    $form.Controls.Add($l); return $l
}
function New-Box($x, $y, $w = 500, $text = "") {
    $t = New-Object Windows.Forms.TextBox; $t.Location = New-Object Drawing.Point($x, $y); $t.Size = New-Object Drawing.Size($w, 26)
    $t.BackColor = $card; $t.ForeColor = $fg; $t.BorderStyle = "FixedSingle"; $t.Text = $text; $form.Controls.Add($t); return $t
}
function New-Button($text, $x, $y, $w = 160, $primary = $false) {
    $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 38)
    $b.FlatStyle = "Flat"; $b.Font = $fontBold; $b.Cursor = "Hand"
    if ($primary) { $b.BackColor = $accent; $b.ForeColor = [Drawing.Color]::White; $b.FlatAppearance.BorderSize = 0 }
    else { $b.BackColor = $card; $b.ForeColor = $fg; $b.FlatAppearance.BorderColor = $line }
    $form.Controls.Add($b); return $b
}

$title = New-Label "CrystalHost" 28 20 500 40 (New-Object Drawing.Font("Segoe UI", 20, [Drawing.FontStyle]::Bold)) $fg
$sub = New-Label "Kostenloser Minecraft-Server auf deinem PC – mit Online-Panel" 30 62 500 22 $fontUi $muted

# ------------------------------------------------------------------ Eingaben
$y = 104
New-Label "Was möchtest du tun?" 30 $y 500 22 $fontBold | Out-Null
$rbNew = New-Object Windows.Forms.RadioButton; $rbNew.Text = "Neuen Server erstellen"; $rbNew.Checked = $true
$rbNew.Location = New-Object Drawing.Point(30, ($y + 26)); $rbNew.Size = New-Object Drawing.Size(240, 24); $rbNew.ForeColor = $fg; $form.Controls.Add($rbNew)
$rbOld = New-Object Windows.Forms.RadioButton; $rbOld.Text = "Vorhandenen Server benutzen"
$rbOld.Location = New-Object Drawing.Point(280, ($y + 26)); $rbOld.Size = New-Object Drawing.Size(250, 24); $rbOld.ForeColor = $fg; $form.Controls.Add($rbOld)

$lblFolder = New-Label "Ordner deines Servers (dort, wo die .jar und server.properties liegen):" 30 ($y + 58) 500 20 $fontUi $muted
$tbFolder = New-Box 30 ($y + 80) 380
$btnFolder = New-Button "Ordner wählen" 418 ($y + 77) 112
$lblFolder.Visible = $false; $tbFolder.Visible = $false; $btnFolder.Visible = $false

$y2 = $y + 120
New-Label "Name deines Servers" 30 $y2 240 20 $fontUi $muted | Out-Null
$tbName = New-Box 30 ($y2 + 22) 240 "MeinServer"
New-Label "Dein Name (für das Panel)" 290 $y2 240 20 $fontUi $muted | Out-Null
$tbOwner = New-Box 290 ($y2 + 22) 240 $env:USERNAME

$totalGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
New-Label "RAM für den Server (dein PC hat $totalGb GB)" 30 ($y2 + 62) 500 20 $fontUi $muted | Out-Null
$numRam = New-Object Windows.Forms.NumericUpDown; $numRam.Location = New-Object Drawing.Point(30, ($y2 + 84)); $numRam.Size = New-Object Drawing.Size(80, 26)
$numRam.Minimum = 1; $numRam.Maximum = [math]::Max(1, $totalGb - 1); $numRam.Value = [math]::Max(1, [math]::Min(6, [math]::Floor($totalGb / 2)))
$numRam.BackColor = $card; $numRam.ForeColor = $fg; $form.Controls.Add($numRam)
New-Label "GB" 116 ($y2 + 87) 40 22 | Out-Null

$cbAuto = New-Object Windows.Forms.CheckBox; $cbAuto.Text = "Mit Windows automatisch starten (empfohlen)"; $cbAuto.Checked = $true
$cbAuto.Location = New-Object Drawing.Point(30, ($y2 + 124)); $cbAuto.Size = New-Object Drawing.Size(500, 24); $cbAuto.ForeColor = $fg; $form.Controls.Add($cbAuto)
$cbEula = New-Object Windows.Forms.CheckBox; $cbEula.Text = "Ich akzeptiere die Minecraft-EULA"; $cbEula.Location = New-Object Drawing.Point(30, ($y2 + 152))
$cbEula.Size = New-Object Drawing.Size(250, 24); $cbEula.ForeColor = $fg; $form.Controls.Add($cbEula)
$lnkEula = New-Object Windows.Forms.LinkLabel; $lnkEula.Text = "(lesen)"; $lnkEula.Location = New-Object Drawing.Point(282, ($y2 + 155))
$lnkEula.Size = New-Object Drawing.Size(60, 20); $lnkEula.LinkColor = [Drawing.Color]::FromArgb(167, 139, 250); $form.Controls.Add($lnkEula)
$lnkEula.Add_LinkClicked({ Start-Process "https://aka.ms/MinecraftEULA" })

$btnGo = New-Button "Server einrichten" 30 ($y2 + 196) 500 $true

# Fortschritt
$lblStep = New-Label "" 30 ($y2 + 250) 500 22 $fontBold
$bar = New-Object Windows.Forms.ProgressBar; $bar.Location = New-Object Drawing.Point(30, ($y2 + 276)); $bar.Size = New-Object Drawing.Size(500, 14)
$bar.Visible = $false; $form.Controls.Add($bar)
$lblInfo = New-Label "" 30 ($y2 + 296) 500 40 $fontUi $muted

$rbOld.Add_CheckedChanged({
    $old = $rbOld.Checked
    $lblFolder.Visible = $old; $tbFolder.Visible = $old; $btnFolder.Visible = $old
})
$btnFolder.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Ordner deines Minecraft-Servers auswählen"
    if ($dlg.ShowDialog() -eq "OK") {
        $tbFolder.Text = $dlg.SelectedPath
        if ($tbName.Text -eq "MeinServer") { $tbName.Text = Split-Path $dlg.SelectedPath -Leaf }
    }
})

# ------------------------------------------------------------------ Helfer
function Pump { [System.Windows.Forms.Application]::DoEvents() }
function Step($text, $info = "") { $lblStep.Text = $text; $lblInfo.Text = $info; $bar.Value = 0; Pump }
function Download($url, $file) {
    for ($try = 1; $try -le 3; $try++) {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add("User-Agent", "CrystalHost-Setup")
        $script:dlPct = 0
        Register-ObjectEvent $wc DownloadProgressChanged -SourceIdentifier "dl" -Action { $script:dlPct = $EventArgs.ProgressPercentage } | Out-Null
        try {
            $task = $wc.DownloadFileTaskAsync($url, $file)
            while (-not $task.IsCompleted) { $bar.Value = [math]::Min(100, [math]::Max(0, $script:dlPct)); Pump; Start-Sleep -Milliseconds 80 }
            if ($task.IsFaulted) { throw $task.Exception.InnerException }
            $bar.Value = 100; Pump; return
        } catch {
            if ($try -eq 3) { throw "Download fehlgeschlagen: $url ($($_.Exception.Message))" }
            Start-Sleep -Seconds 2
        } finally {
            Unregister-Event -SourceIdentifier "dl" -ErrorAction SilentlyContinue; $wc.Dispose()
        }
    }
}
function Fetch($rel, $dest) {
    if ($Source -match '^https?://') { Download "$Source/$rel" $dest } else { Copy-Item (Join-Path $Source $rel) $dest -Force }
}
function Port-Used($p) {
    # Belegt, wenn schon etwas darauf hoert (Abfrage der Listener + Verbindungstest, falls die Abfrage nichts liefert)
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners().Port
    if ($listeners -contains $p) { return $true }
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync("127.0.0.1", $p).Wait(300) -and $c.Connected } catch { return $false } finally { $c.Close() }
}
function Free-Port($start) {
    $p = $start; while (Port-Used $p) { $p++ }; return $p
}
function Read-Props($file) {
    $props = [ordered]@{}
    if (Test-Path $file) { Get-Content $file | Where-Object { $_ -match '^[^#].*=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $props[$k.Trim()] = $v.Trim() } }
    return $props
}
function Set-Props($file, $changes) {
    $lines = if (Test-Path $file) { @(Get-Content $file) } else { @() }
    $seen = @{}
    $out = foreach ($l in $lines) {
        $k = ($l -split '=', 2)[0]
        if ($l -notmatch '^#' -and $l -match '=' -and $changes.Contains($k)) { "$k=$($changes[$k])"; $seen[$k] = $true } else { $l }
    }
    foreach ($k in $changes.Keys) { if (-not $seen[$k]) { $out += "$k=$($changes[$k])" } }
    [IO.File]::WriteAllLines($file, [string[]]$out, (New-Object Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------ Einrichten
$btnGo.Add_Click({
    $name = $tbName.Text.Trim(); if (-not $name) { $name = "MeinServer" }
    $folderName = ($name -replace '[^\w\- ]', '').Trim(); if (-not $folderName) { $folderName = "MeinServer" }
    $owner = $tbOwner.Text.Trim(); if (-not $owner) { $owner = $env:USERNAME }
    $useOld = $rbOld.Checked
    if (-not $cbEula.Checked) { [Windows.Forms.MessageBox]::Show("Bitte akzeptiere die Minecraft-EULA – ohne sie darf kein Server laufen.", "CrystalHost") | Out-Null; return }
    $oldDir = $tbFolder.Text.Trim()
    $oldJar = $null
    if ($useOld) {
        if (-not (Test-Path $oldDir)) { [Windows.Forms.MessageBox]::Show("Bitte wähle den Ordner deines Servers.", "CrystalHost") | Out-Null; return }
        $jars = Get-ChildItem $oldDir -Filter *.jar -File
        $oldJar = ($jars | Where-Object { $_.Name -match '^(server|paper|purpur|spigot|fabric-server|forge|minecraft_server)' } | Sort-Object Length -Descending | Select-Object -First 1)
        if (-not $oldJar) { $oldJar = $jars | Sort-Object Length -Descending | Select-Object -First 1 }
        if (-not $oldJar) { [Windows.Forms.MessageBox]::Show("In diesem Ordner liegt keine .jar – ist das wirklich ein Minecraft-Server?", "CrystalHost") | Out-Null; return }
        $oldPort = (Read-Props (Join-Path $oldDir "server.properties"))['server-port']; if (-not $oldPort) { $oldPort = 25565 }
        if (Port-Used ([int]$oldPort)) {
            [Windows.Forms.MessageBox]::Show("Auf Port $oldPort läuft gerade schon ein Server.`nBitte beende deinen Server zuerst – dieselbe Welt darf nie zweimal gleichzeitig laufen.", "CrystalHost") | Out-Null; return
        }
    }
    foreach ($c in @($btnGo, $rbNew, $rbOld, $tbName, $tbOwner, $numRam, $cbAuto, $cbEula, $btnFolder, $tbFolder)) { $c.Enabled = $false }
    $bar.Visible = $true

    $base = Join-Path $Root $folderName
    $rt = Join-Path $base "runtime"
    $srv = if ($useOld) { $oldDir } else { Join-Path $base "server" }
    $tmp = Join-Path $env:TEMP ("crystalhost-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    try {
        New-Item -ItemType Directory -Force -Path $base, $rt, $srv, (Join-Path $base "web"), $tmp | Out-Null

        Step "1/5  Java wird geladen …" "ca. 50 MB – einmalig"
        $javaDir = Join-Path $rt "java"
        if (-not (Test-Path (Join-Path $javaDir "bin\java.exe"))) {
            Download "https://api.adoptium.net/v3/binary/latest/25/ga/windows/x64/jre/hotspot/normal/eclipse" "$tmp\java.zip"
            Expand-Archive "$tmp\java.zip" "$tmp\java" -Force
            $inner = Get-ChildItem "$tmp\java" -Directory | Select-Object -First 1
            if (Test-Path $javaDir) { Remove-Item $javaDir -Recurse -Force }
            Move-Item $inner.FullName $javaDir
        }

        $mcVersion = $null
        if ($useOld) {
            Step "2/5  Vorhandener Server wird eingebunden …" $oldJar.Name
            $jarName = $oldJar.Name
        } else {
            Step "2/5  Minecraft-Server (Paper) wird geladen …"
            $proj = Invoke-RestMethod "https://fill.papermc.io/v3/projects/paper"
            $mcVersion = ($proj.versions.PSObject.Properties | Select-Object -First 1).Value | Where-Object { $_ -notmatch '-(rc|pre)' } | Select-Object -First 1
            $builds = Invoke-RestMethod "https://fill.papermc.io/v3/projects/paper/versions/$mcVersion/builds"
            $build = $builds | Where-Object { $_.channel -eq "STABLE" } | Select-Object -First 1
            if (-not $build) { $build = $builds | Select-Object -First 1 }
            Download $build.downloads.'server:default'.url (Join-Path $srv "server.jar")
            $jarName = "server.jar"
        }

        Step "3/5  Panel-Programme werden geladen …"
        $pyDir = Join-Path $rt "python"
        if (-not (Test-Path (Join-Path $pyDir "python.exe"))) {
            Download "https://www.python.org/ftp/python/$PYTHON_VERSION/python-$PYTHON_VERSION-embed-amd64.zip" "$tmp\py.zip"
            Expand-Archive "$tmp\py.zip" $pyDir -Force
        }
        if (-not (Test-Path "$rt\cloudflared.exe")) { Download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" "$rt\cloudflared.exe" }
        if (-not (Test-Path "$rt\bore.exe")) {
            $rel = Invoke-RestMethod "https://api.github.com/repos/ekzhang/bore/releases/latest"
            $asset = $rel.assets | Where-Object { $_.name -like "*x86_64-pc-windows-msvc.zip" } | Select-Object -First 1
            Download $asset.browser_download_url "$tmp\bore.zip"
            Expand-Archive "$tmp\bore.zip" "$tmp\bore" -Force
            Copy-Item (Get-ChildItem "$tmp\bore" -Recurse -Filter bore.exe | Select-Object -First 1).FullName "$rt\bore.exe"
        }
        Fetch "host.py" (Join-Path $base "host.py")
        Fetch "web/index.html" (Join-Path $base "web\index.html")

        Step "4/5  Server wird eingerichtet …"
        $propsFile = Join-Path $srv "server.properties"
        $props = Read-Props $propsFile
        $mcPort = if ($props['server-port']) { [int]$props['server-port'] } else { Free-Port 25565 }
        $chars = [char[]]"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
        $changes = [ordered]@{ "enable-rcon" = "true" }
        if (-not $props['rcon.password']) { $changes["rcon.password"] = -join (1..24 | ForEach-Object { $chars | Get-Random }) }
        if (-not $props['rcon.port']) { $changes["rcon.port"] = Free-Port 25575 }
        if (-not $useOld) {
            $changes["server-port"] = $mcPort; $changes["motd"] = "§d$name §8| §7gehostet mit CrystalHost"
            $changes["max-players"] = 20; $changes["view-distance"] = 8; $changes["simulation-distance"] = 8
        }
        Set-Props $propsFile $changes
        if (-not (Select-String -Path (Join-Path $srv "eula.txt") -Pattern 'eula=true' -Quiet -ErrorAction SilentlyContinue)) {
            Set-Content (Join-Path $srv "eula.txt") "# Akzeptiert im CrystalHost-Setup am $(Get-Date -Format 'dd.MM.yyyy HH:mm')`neula=true" -Encoding ASCII
        }
        $cfg = [ordered]@{
            name = $name; owner = $owner; plan = "free"; version = $mcVersion
            port = $mcPort; panelPort = (Free-Port 8130); ramMb = [int]$numRam.Value * 1024
            java = (Join-Path $javaDir "bin\java.exe"); autostart = $true; publicTunnel = $true
            serverDir = $(if ($useOld) { $srv } else { $null }); jar = $jarName
        }
        [IO.File]::WriteAllText((Join-Path $base "host.json"), ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

        $pyw = Join-Path $pyDir "pythonw.exe"
        $starter = Join-Path $base "CrystalHost-Starten.vbs"
        Set-Content $starter "Set sh = CreateObject(`"WScript.Shell`")`r`nsh.CurrentDirectory = `"$base`"`r`nsh.Run `"`"`"$pyw`"`" -I `"`"$base\host.py`"`"`", 0, False" -Encoding ASCII
        $desk = [Environment]::GetFolderPath("Desktop")
        if (-not $AutoTest) { Set-Content (Join-Path $desk "$name - Panel.url") "[InternetShortcut]`r`nURL=$PANEL_URL" -Encoding ASCII }
        if ($cbAuto.Checked) {
            $ws = New-Object -ComObject WScript.Shell
            $s = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Startup")) "CrystalHost - $folderName.lnk"))
            $s.TargetPath = "wscript.exe"; $s.Arguments = "`"$starter`""; $s.WorkingDirectory = $base; $s.Save()
        }

        Step "5/5  Server startet …" "Das Panel geht online – gleich bekommst du deinen Code."
        Start-Process wscript.exe -ArgumentList "`"$starter`""
        $zugang = Join-Path $base "ZUGANG.txt"
        for ($i = 0; $i -lt 60 -and -not (Test-Path $zugang); $i++) { Start-Sleep -Milliseconds 500; Pump }
        $code = if (Test-Path $zugang) { (Get-Content $zugang | Where-Object { $_ -match '^C[HS]-' } | Select-Object -First 1) } else { "(siehe ZUGANG.txt)" }

        # ------------------------------------------------------------- Fertig
        foreach ($c in @($form.Controls)) { if ($c -ne $title) { $c.Visible = $false } }
        $sub.Visible = $true; $sub.Text = "Dein Server '$name' ist eingerichtet! 🎉"; $sub.ForeColor = [Drawing.Color]::FromArgb(34, 197, 94)
        New-Label "Dein Owner-Code (nur für dich – gut aufbewahren):" 30 110 500 22 $fontBold | Out-Null
        $tbCode = New-Box 30 136 500 $code; $tbCode.ReadOnly = $true; $tbCode.Font = New-Object Drawing.Font("Consolas", 13, [Drawing.FontStyle]::Bold); $tbCode.Height = 32
        $btnCopy = New-Button "Code kopieren" 30 182 160
        $btnCopy.Add_Click({ [Windows.Forms.Clipboard]::SetText($tbCode.Text); $btnCopy.Text = "Kopiert ✓" })
        New-Label "So geht's weiter:" 30 240 500 22 $fontBold | Out-Null
        New-Label "1.  Öffne das Panel und melde dich mit dem Code an." 30 266 500 22 | Out-Null
        New-Label "2.  Unter 'Zugänge' erstellst du Codes für Freunde." 30 290 500 22 | Out-Null
        New-Label "3.  Die Adresse für deine Freunde steht oben im Panel." 30 314 500 22 | Out-Null
        New-Label "Das Panel funktioniert von überall, solange dieser PC an ist." 30 350 500 22 $fontUi $muted | Out-Null
        $btnPanel = New-Button "Panel öffnen" 30 392 500 $true
        $btnPanel.Add_Click({ Start-Process $PANEL_URL })
        $btnClose = New-Button "Fertig" 30 440 500
        $btnClose.Add_Click({ $form.Close() })
    } catch {
        $lblStep.Text = "Das hat leider nicht geklappt"; $lblStep.ForeColor = [Drawing.Color]::FromArgb(239, 68, 68)
        $lblInfo.Text = "$($_.Exception.Message)`nBitte Internet prüfen und das Setup nochmal starten."
        $btnGo.Enabled = $true; $btnGo.Text = "Nochmal versuchen"
        foreach ($c in @($rbNew, $rbOld, $tbName, $tbOwner, $numRam, $cbAuto, $cbEula, $btnFolder, $tbFolder)) { $c.Enabled = $true }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
})

if ($AutoTest) {
    $form.Add_Shown({
        $rbOld.Checked = $true; $tbFolder.Text = $AutoTest; $tbName.Text = "AutoTest"; $cbEula.Checked = $true; $cbAuto.Checked = $false; $numRam.Value = 2
        $btnGo.PerformClick()
        "$($sub.Text) | $($lblStep.Text) | $($lblInfo.Text)" | Set-Content (Join-Path $Root "autotest-ergebnis.txt") -Encoding UTF8
        $form.Close()
    })
}
[void]$form.ShowDialog()
