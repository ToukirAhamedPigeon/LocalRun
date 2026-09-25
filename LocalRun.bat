@echo off
rem Fallback for PCs where .vbs files are blocked.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0LocalRun.ps1"
