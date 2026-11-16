@echo off
rem Double-click to import Bluetooth keys exported by Linux (bt-dualboot-sync).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bt-dualboot-sync.ps1" %*
