# LocalRun

<img src="assets/logo.png" width="64" align="right" alt="LocalRun logo">

A small Windows desktop app that starts your local projects with one click.

Each project keeps its own run command (`.bat`, `.cmd` or `.ps1`) inside its own folder: the script that brings up the app and all its dependencies on localhost. LocalRun is the one place that lists those commands and runs them.

---

## Contents
- [Features](#features)
- [Getting started](#getting-started)
- [Tech stack](#tech-stack)
- [Architecture](#architecture)
- [How it works](#how-it-works)
- [Code map](#code-map)
- [Design decisions](#design-decisions)
- [Limitations](#limitations)

---

## Features
- Add, edit and remove projects (title + command file). You can also drag a command file onto the window to add it.
- **Run** opens the command in its own console window, started from the project's folder.
- A running project glows and shows **Stop**, which closes the console and every process it started.
- Missing command files are flagged, so the same app works across several PCs.
- No install and no dependencies: it runs on Windows PowerShell 5.1 and WPF, which are built into Windows.

## Getting started
1. Double-click `LocalRun.vbs`. On PCs that block `.vbs` files, use `LocalRun.bat`.
2. Optional: right-click `Install.ps1` → **Run with PowerShell** to add Desktop and Start Menu shortcuts with the LocalRun icon.

On a new PC, just clone this repository (or copy the folder) and do the same.

| Shortcut | Action |
|---|---|
| `Ctrl+N` | New project |
| `Enter` | Save the open dialog / confirm removal |
| `Esc` | Close the dialog |

---

## Tech stack

| Layer | Technology | Used for |
|---|---|---|
| Runtime | **Windows PowerShell 5.1** | The whole app is a single script. Nothing is compiled or installed. |
| UI framework | **WPF** (`PresentationFramework`, .NET Framework 4.x) | Window, controls, styles, gradients, effects |
| UI markup | **XAML**, parsed at runtime with `XamlReader.Parse` | The main window, plus a separate template for each project card |
| Window chrome | `System.Windows.Shell.WindowChrome` | Custom dark title bar that still keeps native drag, snap and resize |
| Native API | **DWM** (`dwmapi.dll`) via `Add-Type` P/Invoke | Rounded corners and border colour on Windows 11 |
| Animation | WPF `DoubleAnimation` + `CubicEase` / `BackEase` / `SineEase` | Card entrance, hover lift, glow pulse, dialogs, toasts, background glows |
| Timing | `DispatcherTimer` | Watching launched processes, hiding toasts |
| Storage | JSON (`ConvertTo-Json` / `ConvertFrom-Json`), UTF-8 | The per-machine project list |
| Process control | `Start-Process -PassThru`, `cmd.exe /k`, `powershell.exe -NoExit`, `taskkill /T /F` | Running and stopping projects |
| Launcher | **VBScript** (`WScript.Shell.Run`, window style 0) | Starting the app with no console window |
| Shortcuts | `WScript.Shell` COM (`CreateShortcut`) | Desktop and Start Menu shortcuts in `Install.ps1` |
| Icon | Multi-size `.ico` (16–256 px, PNG-encoded frames) | Shortcut and window icon |

---

## Architecture

```mermaid
flowchart TD
    U([User]) -->|double-click| L[LocalRun.vbs / LocalRun.bat]
    L -->|powershell -STA -WindowStyle Hidden| APP

    subgraph APP[LocalRun.ps1 - one process, one UI thread]
        UI[UI layer<br/>Window XAML + Card XAML<br/>styles, animations]
        EV[Behaviour layer<br/>event handlers, dialogs, toasts]
        DATA[Data layer<br/>Load-Projects / Save-Projects]
        PROC[Process layer<br/>Start-Project / Stop-Project<br/>1 s process watcher]
        UI <--> EV
        EV --> DATA
        EV --> PROC
        PROC -->|state change| UI
    end

    DATA <-->|read / write| J[(%APPDATA%\LocalRun\projects.json)]
    PROC -->|cmd /k or powershell -NoExit| C1[Project console]
    C1 --> S1[Project's own run script<br/>servers, databases, workers]
    PROC -.->|taskkill /PID /T /F| C1
```

The app is one PowerShell process with one WPF UI thread. It has four logical layers, all in `LocalRun.ps1`:

1. **UI layer:** two XAML documents. The *window* holds the title bar, header, card list, empty state, drop hint, dialog overlay and toast. The *card* template is parsed once for each project. Shared styles (`FlameBtn`, `GhostBtn`, `IconBtn`, `Field`, and so on) live in the window's resources. Cards reach them through `DynamicResource`, because each card is parsed on its own before it joins the window.
2. **Behaviour layer:** the event handlers for buttons, keyboard, drag-and-drop, dialogs and toasts. Each card button carries its project `Id` in `Tag`, so one shared handler serves every card and no closures are needed.
3. **Data layer:** an in-memory `ArrayList` of `{ Id, Title, Path }`. It is written to JSON after every change.
4. **Process layer:** launches consoles and keeps an `Id → Process` table of what is running. A one-second timer notices consoles that were closed by hand.

### File structure
```
LocalRun/
├── LocalRun.ps1        # the application (UI, data, process control)
├── LocalRun.vbs        # hidden-window launcher (normal entry point)
├── LocalRun.bat        # fallback launcher where .vbs is blocked
├── Install.ps1         # creates Desktop + Start Menu shortcuts on this PC
└── assets/
    ├── logo.png        # app logo (title bar, empty state, window icon)
    └── localrun.ico    # multi-size icon for shortcuts
```

### Data model
Stored per machine in `%APPDATA%\LocalRun\projects.json`, outside the app folder. This lets the same folder, or the same git clone, carry a different list on each PC:

```json
[
  { "Id": "3f1c0d...", "Title": "Budget", "Path": "D:\\Projects\\budget\\run-all.bat" },
  { "Id": "9a77b2...", "Title": "VMOMS",  "Path": "D:\\Projects\\vmoms\\start.ps1" }
]
```

`Id` is a GUID. It keeps a project's identity stable while it is renamed, edited or running. The list is migrated automatically from the earlier `LocalhostLauncher` location if one exists.

---

## How it works

### Running a project
The command always starts **in the command file's own folder**, so relative paths inside the script behave the same way as when you double-click it.

| File type | How it is launched | Window |
|---|---|---|
| `.bat`, `.cmd` | `cmd.exe /k title LocalRun - <Title> & "<path>"` | Stays open, titled with the project name |
| `.ps1` | `powershell.exe -NoExit -ExecutionPolicy Bypass -File "<path>"` | Stays open |
| anything else | `Start-Process <path>` (Windows file association) | Not tracked |

Consoles stay open (`/k`, `-NoExit`) so logs remain visible and `Ctrl+C` still works. `-ExecutionPolicy Bypass` applies only to that one process. It does not change the machine's policy.

### Running state
- **A project counts as running while its console process is alive.**
- **Stop** calls `taskkill /PID <console> /T /F`. The `/T` flag ends the whole process tree: the console plus the servers it started (node, dotnet, php, python and so on).
- If you close a console yourself, the watcher notices within a second, and the card returns to *Ready* with a toast.

### Card states
| State | Dot | Card | Button |
|---|---|---|---|
| Ready | grey | plain border | gradient **Run** |
| Running | green, pulsing | flame-gradient border with a pulsing glow | red **Stop** |
| File not found | red | plain border | dimmed **Run** (shows an error when clicked) |

### Animations
- Cards fade and slide in one after another at startup. When you add or edit a project, only that card animates.
- On hover, a card grows slightly and a button's glow brightens.
- Pressing Run makes the card give a short bounce. While the project runs, its glow pulses on a sine wave.
- Dialogs open with a back-eased scale and a fade. A removed card shrinks and fades out.
- Toasts rise from the bottom and hide themselves after about 2.6 seconds.
- Three soft radial glows drift slowly behind the window.

---

## Code map
`LocalRun.ps1` is split into commented sections, in this order:

| Section | Contents |
|---|---|
| XAML | `$WindowXaml` (window + styles), `$CardXaml` (one project card) |
| helpers | `Animate`, `Stop-Animation`, `Get-Color`, `Get-Brush`, easing objects, tile colour palette |
| data | `Load-Projects`, `Save-Projects`, `Get-Project`, `Test-ProjectFile` |
| window | XAML load, named-element lookup, logo and icon |
| toast | `Show-Toast` + auto-hide timer |
| cards | `New-Card`, `Render-Cards`, `Set-CardState`, `Update-Counts` |
| run / stop | `Start-Project`, `Stop-Project`, process-watcher timer |
| dialogs | `Open-Overlay`, `Close-Overlay`, `Show-Editor`, `Save-Editor`, `Show-DeleteConfirm`, `Confirm-Delete` |
| wiring | button, keyboard, drag-and-drop and window events; DWM styling; startup animations |

---

## Design decisions
- **PowerShell + WPF instead of Electron, .NET or Python.** Everything it needs already ships with Windows 10 and 11, so it runs on a locked-down office PC with nothing to install, no build step and no admin rights. The whole app is a folder you can read and edit.
- **WPF, not WinForms.** Gradients, drop-shadow glows, rounded templates and a real animation system. The first version was WinForms, and it looked its age.
- **XAML parsed at runtime.** Keeps the markup declarative without a compiler or a project file.
- **Per-machine data outside the app folder.** The app is portable and shareable through git, while each PC keeps its own project list.
- **Script files are ASCII-only.** Windows PowerShell 5.1 reads BOM-less scripts in the system code page, so non-ASCII UI glyphs are written as XAML entities (`&#xE768;`) or `[char]` codes. Project titles in any language, such as Bangla, are stored as UTF-8 JSON and display correctly.

## Limitations
- Windows only.
- **Stop** ends processes, not containers. Anything started with `docker compose up -d` keeps running.
- Running state lives in memory. If you close and reopen LocalRun, projects that are still running show as *Ready*, and their consoles have to be closed by hand.
- A script that ends with `exit` closes its console, so the project shows as stopped even if it started background services.
- Only consoles that LocalRun launches are tracked. Other file types open through their Windows association.
