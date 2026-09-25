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
- Footer with copyright, social links and an **About** dialog (version, developer, company). Links open in the browser; no URL is shown in the app.
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
| Native API | **DWM** (`dwmapi.dll`) and `user32.dll` via `Add-Type` P/Invoke | Rounded corners and border colour on Windows 11; focusing the running window |
| Animation | WPF `DoubleAnimation` + `CubicEase` / `BackEase` / `SineEase` | Card entrance, hover lift, glow pulse, dialogs, toasts, background glows |
| Timing | `DispatcherTimer` | Watching launched processes, hiding toasts |
| Database | **SQLite 3** through Windows' own `winsqlite3.dll`, via a small C# P/Invoke wrapper (`LocalRun.Db`) | The per-machine project list: WAL journal, `synchronous = FULL`, parameterised statements |
| Single instance | Named `System.Threading.Mutex` (`Local\Pigeonic.LocalRun`) | A second launch focuses the open window instead of opening another |
| Logging | Plain text log (`localrun.log`) | Startup, import and database errors |
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
        DATA[Data layer<br/>Load-Projects + row-level<br/>Add / Update / Remove]
        PROC[Process layer<br/>Start-Project / Stop-Project<br/>1 s process watcher]
        UI <--> EV
        EV --> DATA
        EV --> PROC
        PROC -->|state change| UI
    end

    DATA <-->|winsqlite3.dll| J[(%APPDATA%\LocalRun\localrun.db)]
    PROC -->|cmd /k or powershell -NoExit| C1[Project console]
    C1 --> S1[Project's own run script<br/>servers, databases, workers]
    PROC -.->|taskkill /PID /T /F| C1
```

The app is one PowerShell process with one WPF UI thread. It has four logical layers, all in `LocalRun.ps1`:

1. **UI layer:** two XAML documents. The *window* holds the title bar, header, card list, empty state, drop hint, dialog overlay and toast. The *card* template is parsed once for each project. Shared styles (`FlameBtn`, `GhostBtn`, `IconBtn`, `Field`, and so on) live in the window's resources. Cards reach them through `DynamicResource`, because each card is parsed on its own before it joins the window.
2. **Behaviour layer:** the event handlers for buttons, keyboard, drag-and-drop, dialogs and toasts. Each card button carries its project `Id` in `Tag`, so one shared handler serves every card and no closures are needed.
3. **Data layer:** a SQLite database. Each add, edit or delete writes **only its own row**. The in-memory `ArrayList` of `{ Id, Title, Path }` is always re-read from the database after a change, so it can never overwrite stored data with a stale copy.
4. **Process layer:** launches consoles and keeps an `Id → Process` table of what is running. A one-second timer notices consoles that were closed by hand.

### File structure
```
LocalRun/
├── LocalRun.ps1        # the application (UI, data, process control)
├── LocalRun.vbs        # hidden-window launcher (normal entry point)
├── LocalRun.bat        # fallback launcher where .vbs is blocked
├── Install.ps1         # creates Desktop + Start Menu shortcuts on this PC
├── .gitignore          # guards against database / log files ever being committed
└── assets/
    ├── logo.png        # app logo (title bar, empty state, window icon)
    └── localrun.ico    # multi-size icon for shortcuts
```

### Data model
Stored per machine in **`%APPDATA%\LocalRun\localrun.db`**, outside the app folder. So the data never goes into git, and the same folder or git clone carries a different list on each PC.

```sql
CREATE TABLE projects (
    id          TEXT PRIMARY KEY,      -- GUID, stable while renamed, edited or running
    title       TEXT NOT NULL,
    path        TEXT NOT NULL,         -- the project's .bat / .cmd / .ps1
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,         -- local time, yyyy-MM-dd HH:mm:ss
    updated_at  TEXT NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);   -- e.g. json_imported
```

| File in `%APPDATA%\LocalRun` | Purpose |
|---|---|
| `localrun.db` (+ `-wal`, `-shm`) | The database |
| `localrun.log` | Startup line with the project count, plus any import or database error |
| `projects.json.imported` | Backup of the pre-1.1 JSON list, after it was imported |

**How data is kept safe**
- **Row-level writes.** Adding, editing or removing a project touches one row, never the whole list.
- **Durable commits.** WAL journal with `synchronous = FULL`, so a saved change survives a crash or a power cut.
- **One window at a time.** A named mutex stops two windows from holding different copies of the list.
- **Re-read on focus.** Coming back to the window reloads from the database and re-checks which command files exist.
- **Safe migration.** On first start, v1.1 imports the older `projects.json` (and the first prototype's `LocalhostLauncher` list). A JSON file is renamed to `*.imported` only after every project in it is confirmed in the database. If anything fails, the file is left untouched, the reason is logged, and the import is retried on the next start.

> Windows' `winsqlite3.dll` is built with `SQLITE_OMIT_LOCALTIME`, so `datetime('now', 'localtime')` returns NULL there. Timestamps are therefore set from PowerShell.

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
| native | C# compiled with `Add-Type`: `LocalRun.Native` (DWM, window focus) and `LocalRun.Db` (SQLite wrapper) |
| single instance | Named mutex; a second launch focuses the open window and exits |
| XAML | `$WindowXaml` (window + styles), `$CardXaml` (one project card) |
| helpers | `Animate`, `Stop-Animation`, `Get-Color`, `Get-Brush`, easing objects, tile colour palette |
| data | `Open-Database`, `Import-JsonProjects`, `Load-Projects`, `Add-ProjectRow`, `Update-ProjectRow`, `Remove-ProjectRow`, `Get-Project`, `Test-ProjectFile` |
| window | XAML load, named-element lookup, logo and icon |
| toast | `Show-Toast` + auto-hide timer |
| cards | `New-Card`, `Render-Cards`, `Set-CardState`, `Update-Counts` |
| run / stop | `Start-Project`, `Stop-Project`, process-watcher timer |
| dialogs | `Open-Overlay`, `Close-Overlay`, `Show-Editor`, `Save-Editor`, `Show-DeleteConfirm`, `Confirm-Delete` |
| about + links | `Open-Link`, copyright year, social icon and About dialog wiring (`$Links`, `$AppVersion`) |
| wiring | button, keyboard, drag-and-drop and window events; DWM styling; startup animations |

---

## Design decisions
- **PowerShell + WPF instead of Electron, .NET or Python.** Everything it needs already ships with Windows 10 and 11, so it runs on a locked-down office PC with nothing to install, no build step and no admin rights. The whole app is a folder you can read and edit.
- **WPF, not WinForms.** Gradients, drop-shadow glows, rounded templates and a real animation system. The first version was WinForms, and it looked its age.
- **XAML parsed at runtime.** Keeps the markup declarative without a compiler or a project file.
- **Per-machine data outside the app folder.** The app is portable and shareable through git, while each PC keeps its own project list.
- **SQLite through `winsqlite3.dll` rather than System.Data.SQLite.** Windows 10 and 11 already ship SQLite, so a ~150-line P/Invoke wrapper replaces a NuGet package and its native DLLs. The zero-install promise holds.
- **SQLite instead of the v1.0 JSON file.** The JSON file was rewritten in full on every save, so a window holding a stale or empty list could overwrite good data. Row-level writes plus a single instance close that hole.
- **Script files are ASCII-only.** Windows PowerShell 5.1 reads BOM-less scripts in the system code page, so non-ASCII UI glyphs are written as XAML entities (`&#xE768;`) or `[char]` codes. Project titles in any language, such as Bangla, are stored as UTF-16 text in SQLite and display correctly.

## Limitations
- Windows 10 (1703+) or 11 only, since it needs the built-in `winsqlite3.dll`.
- **Stop** ends processes, not containers. Anything started with `docker compose up -d` keeps running.
- Running state lives in memory. If you close and reopen LocalRun, projects that are still running show as *Ready*, and their consoles have to be closed by hand.
- A script that ends with `exit` closes its console, so the project shows as stopped even if it started background services.
- Only consoles that LocalRun launches are tracked. Other file types open through their Windows association.
