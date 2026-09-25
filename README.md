# LocalRun

<img src="assets/logo.png" width="64" align="right" alt="LocalRun logo">

A small Windows desktop app that starts your local projects with one click.

Each project keeps its own run command (`.bat`, `.cmd` or `.ps1`) inside its own folder — the script that brings up the app and all its dependencies on localhost. LocalRun is the one place that lists those commands and runs them.

## Features
- Add, edit and remove projects (title + command file); drag a command file onto the window to add it
- **Run** opens the command in its own console, started from the project's folder
- Running projects glow and show **Stop**, which closes the console and every process it started
- Missing command files are flagged, so the same app works on several PCs
- No install and no dependencies — Windows PowerShell 5.1 + WPF, both built into Windows

## Use
1. Double-click `LocalRun.vbs` (or `LocalRun.bat` where `.vbs` is blocked).
2. Optional: right-click `Install.ps1` → **Run with PowerShell** to add Desktop and Start Menu shortcuts.

The project list is stored per machine in `%APPDATA%\LocalRun\projects.json`, so copying this folder to another PC starts with that PC's own list.

**Shortcuts:** `Ctrl+N` new project · `Enter` save · `Esc` close dialog.

> Stop ends the console's process tree. Docker containers started by a command keep running.
