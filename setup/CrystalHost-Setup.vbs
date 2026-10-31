' CrystalHost Setup - laedt das aktuelle Setup von GitHub und oeffnet das Setup-Fenster (ohne Konsole)
Set sh = CreateObject("WScript.Shell")
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & _
      """$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; " & _
      "$f=Join-Path $env:TEMP 'CrystalHost-Setup.ps1'; " & _
      "Invoke-WebRequest 'https://raw.githubusercontent.com/CrystalSMP/CrystalHost/main/setup/CrystalHost-Setup.ps1' -OutFile $f -UseBasicParsing; " & _
      "& $f"""
sh.Run cmd, 0, False
