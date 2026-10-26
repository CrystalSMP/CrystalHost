@echo off
title CrystalHost Setup
rem Laedt das aktuelle Setup von GitHub und startet es (nichts wird systemweit installiert)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $f=Join-Path $env:TEMP 'CrystalHost-Setup.ps1'; Invoke-WebRequest 'https://raw.githubusercontent.com/CrystalSMP/CrystalHost/main/setup/CrystalHost-Setup.ps1' -OutFile $f -UseBasicParsing; & $f"
