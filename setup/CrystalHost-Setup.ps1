# CrystalHost-Setup: richtet auf diesem PC kostenlos einen Minecraft-Server mit Web-Panel ein.
#   - laedt Java, Paper (Minecraft-Server), ein eigenes Python und die Tunnel-Programme herunter
#   - alles landet in %USERPROFILE%\CrystalHost\<Servername> - nichts wird systemweit installiert
#   - am Ende oeffnet sich das Panel im Browser, der Owner-Code steht in ZUGANG.txt
# Aufruf normalerweise ueber CrystalHost-Setup.bat (Doppelklick).
param(
    [string]$Source = "https://raw.githubusercontent.com/CrystalSMP/CrystalHost/main/app",  # oder lokaler Ordner zum Testen
    [string]$Root = (Join-Path $env:USERPROFILE "CrystalHost"),
    [switch]$Test   # ohne Fragen, ohne Autostart/Start/Verknuepfungen (fuer Tests)
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest ist mit Fortschrittsbalken extrem langsam
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PYTHON_VERSION = "3.13.9"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Step($n, $text) { Write-Host ""; Write-Host "[$n/7] $text" -ForegroundColor Magenta }
function Download($url, $file) {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing; return } catch {
            if ($i -eq 3) { throw "Download fehlgeschlagen: $url ($($_.Exception.Message))" }
            Start-Sleep -Seconds 3
        }
    }
}
function Fetch($rel, $dest) {
    # App-Dateien aus dem GitHub-Repo oder (zum Testen) aus einem lokalen Ordner
    if ($Source -match '^https?://') { Download "$Source/$rel" $dest } else { Copy-Item (Join-Path $Source $rel) $dest -Force }
}
function Free-Port($start) {
    $used = (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue).LocalPort
    $p = $start; while ($used -contains $p) { $p++ }; return $p
}

Clear-Host
Say ""
Say "   ____                _        _ _   _           _   " Magenta
Say "  / ___|_ __ _   _ ___| |_ __ _| | | | | ___  ___| |_ " Magenta
Say " | |   | '__| | | / __| __/ _`` | | |_| |/ _ \/ __| __|" Magenta
Say " | |___| |  | |_| \__ \ || (_| | |  _  | (_) \__ \ |_ " Magenta
Say "  \____|_|   \__, |___/\__\__,_|_|_| |_|\___/|___/\__|" Magenta
Say "             |___/   Kostenloser Minecraft-Server auf deinem PC" Magenta
Say ""

# ------------------------------------------------------------------ Fragen
Step 1 "Ein paar Fragen"
$name = if ($Test) { "TestServer" } else { Read-Host "  Wie soll dein Server heissen? (z. B. MeinSMP)" }
if (-not $name) { $name = "MeinServer" }
$folderName = ($name -replace '[^\w\- ]', '').Trim(); if (-not $folderName) { $folderName = "MeinServer" }
$owner = if ($Test) { "Tester" } else { Read-Host "  Dein Name (fuer das Panel)" }
if (-not $owner) { $owner = $env:USERNAME }

$totalGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$suggest = [math]::Max(2, [math]::Min(6, [math]::Floor($totalGb / 2)))
$ram = if ($Test) { 2 } else { Read-Host "  Wie viel RAM fuer den Server in GB? Dein PC hat $totalGb GB (Enter = $suggest)" }
if (-not ($ram -as [int])) { $ram = $suggest }
$ram = [math]::Max(1, [math]::Min([int]$ram, $totalGb - 1))

Say ""
Say "  Minecraft-Server duerfen nur betrieben werden, wenn du die Minecraft-EULA akzeptierst:" Yellow
Say "  https://aka.ms/MinecraftEULA" Yellow
$eula = if ($Test) { "j" } else { Read-Host "  Akzeptierst du die Minecraft-EULA? (j/n)" }
if ($eula -notmatch '^(j|ja|y|yes)$') { Say "  Ohne EULA kann kein Server laufen. Setup abgebrochen." Red; Read-Host "Enter zum Schliessen"; exit 1 }

$base = Join-Path $Root $folderName
if ((Test-Path (Join-Path $base "host.json")) -and -not $Test) {
    Say "  Unter $base gibt es schon einen Server. Im Free-Plan ist 1 Server moeglich." Yellow
    $again = Read-Host "  Trotzdem neu einrichten? Die Welt bleibt erhalten. (j/n)"
    if ($again -notmatch '^(j|ja|y)$') { exit 0 }
}
$rt = Join-Path $base "runtime"; $srv = Join-Path $base "server"
New-Item -ItemType Directory -Force -Path $base, $rt, $srv, (Join-Path $base "web") | Out-Null
$tmp = Join-Path $env:TEMP ("crystalhost-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ------------------------------------------------------------------ Java
    Step 2 "Java wird geladen (ca. 50 MB)"
    $javaDir = Join-Path $rt "java"
    if (-not (Test-Path (Join-Path $javaDir "bin\java.exe"))) {
        Download "https://api.adoptium.net/v3/binary/latest/25/ga/windows/x64/jre/hotspot/normal/eclipse" "$tmp\java.zip"
        Expand-Archive "$tmp\java.zip" "$tmp\java" -Force
        $inner = Get-ChildItem "$tmp\java" -Directory | Select-Object -First 1
        if (Test-Path $javaDir) { Remove-Item $javaDir -Recurse -Force }
        Move-Item $inner.FullName $javaDir
    }
    Say "  Java bereit" Green

    # ------------------------------------------------------------------ Paper
    Step 3 "Minecraft-Server (Paper) wird geladen"
    $proj = Invoke-RestMethod "https://fill.papermc.io/v3/projects/paper"
    $mcVersion = ($proj.versions.PSObject.Properties | Select-Object -First 1).Value |
        Where-Object { $_ -notmatch '-(rc|pre)' } | Select-Object -First 1
    $builds = Invoke-RestMethod "https://fill.papermc.io/v3/projects/paper/versions/$mcVersion/builds"
    $build = $builds | Where-Object { $_.channel -eq "STABLE" } | Select-Object -First 1
    if (-not $build) { $build = $builds | Select-Object -First 1 }
    Download $build.downloads.'server:default'.url (Join-Path $srv "server.jar")
    Say "  Paper $mcVersion (Build $($build.id)) bereit" Green

    # ------------------------------------------------------------------ Python + Tunnel
    Step 4 "Panel-Programme werden geladen"
    $pyDir = Join-Path $rt "python"
    if (-not (Test-Path (Join-Path $pyDir "python.exe"))) {
        Download "https://www.python.org/ftp/python/$PYTHON_VERSION/python-$PYTHON_VERSION-embed-amd64.zip" "$tmp\py.zip"
        Expand-Archive "$tmp\py.zip" $pyDir -Force
    }
    if (-not (Test-Path "$rt\cloudflared.exe")) {
        Download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" "$rt\cloudflared.exe"
    }
    if (-not (Test-Path "$rt\bore.exe")) {
        $rel = Invoke-RestMethod "https://api.github.com/repos/ekzhang/bore/releases/latest"
        $asset = $rel.assets | Where-Object { $_.name -like "*x86_64-pc-windows-msvc.zip" } | Select-Object -First 1
        Download $asset.browser_download_url "$tmp\bore.zip"
        Expand-Archive "$tmp\bore.zip" "$tmp\bore" -Force
        Copy-Item (Get-ChildItem "$tmp\bore" -Recurse -Filter bore.exe | Select-Object -First 1).FullName "$rt\bore.exe"
    }
    Fetch "host.py" (Join-Path $base "host.py")
    Fetch "web/index.html" (Join-Path $base "web\index.html")
    Say "  Panel bereit" Green

    # ------------------------------------------------------------------ Einstellungen
    Step 5 "Server wird eingerichtet"
    $mcPort = Free-Port 25565
    $panelPort = Free-Port 8130
    $rconPort = Free-Port 25575
    $chars = [char[]]"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
    $rconPw = -join (1..24 | ForEach-Object { $chars | Get-Random })
    Set-Content (Join-Path $srv "eula.txt") "# Akzeptiert im CrystalHost-Setup am $(Get-Date -Format 'dd.MM.yyyy HH:mm')`neula=true" -Encoding ASCII
    $propsFile = Join-Path $srv "server.properties"
    if (-not (Test-Path $propsFile)) {
        @(
            "motd=§d$name §8| §7gehostet mit CrystalHost",
            "server-port=$mcPort",
            "enable-rcon=true",
            "rcon.port=$rconPort",
            "rcon.password=$rconPw",
            "max-players=20",
            "online-mode=true",
            "view-distance=8",
            "simulation-distance=8"
        ) | Set-Content $propsFile -Encoding ASCII
    }
    $cfg = [ordered]@{
        name = $name; owner = $owner; plan = "free"; version = $mcVersion
        port = $mcPort; panelPort = $panelPort; ramMb = [int]$ram * 1024
        java = (Join-Path $javaDir "bin\java.exe"); autostart = $true; publicTunnel = $true
    }
    $cfg | ConvertTo-Json | Set-Content (Join-Path $base "host.json") -Encoding UTF8

    # Starter (ohne Fenster) + Verknuepfungen
    $pyw = Join-Path $pyDir "pythonw.exe"
    $starter = Join-Path $base "CrystalHost-Starten.vbs"
    Set-Content $starter @"
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "$base"
sh.Run """$pyw"" -I ""$base\host.py""", 0, False
"@ -Encoding ASCII
    $ws = New-Object -ComObject WScript.Shell
    if (-not $Test) { Set-Content (Join-Path ([Environment]::GetFolderPath("Desktop")) "$name - Panel.url") "[InternetShortcut]`r`nURL=http://127.0.0.1:$panelPort/" -Encoding ASCII }
    Say "  Fertig eingerichtet in $base" Green

    # ------------------------------------------------------------------ Autostart
    if ($Test) { Say "  Testmodus: kein Autostart, kein Start" Yellow; return }
    Step 6 "Autostart"
    $auto = Read-Host "  Server + Panel automatisch starten, wenn du dich bei Windows anmeldest? (j/n)"
    if ($auto -match '^(j|ja|y)$') {
        $startup = [Environment]::GetFolderPath("Startup")
        $s = $ws.CreateShortcut((Join-Path $startup "CrystalHost - $folderName.lnk"))
        $s.TargetPath = "wscript.exe"; $s.Arguments = "`"$starter`""; $s.WorkingDirectory = $base; $s.Save()
        Say "  Autostart eingerichtet" Green
    } else { Say "  Kein Autostart - starte spaeter mit CrystalHost-Starten.vbs" }

    # ------------------------------------------------------------------ Start
    Step 7 "Server startet"
    Start-Process wscript.exe -ArgumentList "`"$starter`""
    $zugang = Join-Path $base "ZUGANG.txt"
    for ($i = 0; $i -lt 30 -and -not (Test-Path $zugang); $i++) { Start-Sleep -Seconds 1 }
    $code = if (Test-Path $zugang) { (Get-Content $zugang | Where-Object { $_ -match '^CS-' } | Select-Object -First 1) } else { "(siehe ZUGANG.txt)" }

    Say ""
    Say "  ===========================================================" Magenta
    Say "   Dein Server '$name' ist eingerichtet!" Green
    Say ""
    Say "   Panel:        http://127.0.0.1:$panelPort" White
    Say "   Owner-Code:   $code" Yellow
    Say "   (steht auch in $zugang - gut aufbewahren!)" Gray
    Say ""
    Say "   Im Panel siehst du die Adresse fuer deine Freunde und den" Gray
    Say "   Link, mit dem du das Panel auch von unterwegs oeffnen kannst." Gray
    Say "  ===========================================================" Magenta
    Start-Sleep -Seconds 2
    Start-Process "http://127.0.0.1:$panelPort/"
} catch {
    Say ""
    Say "  Fehler: $($_.Exception.Message)" Red
    Say "  Bitte Internetverbindung pruefen und das Setup nochmal starten." Red
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $Test) { Read-Host "`n  Enter zum Schliessen" }
