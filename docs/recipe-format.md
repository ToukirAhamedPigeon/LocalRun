# LocalRun recipe format (local-run/startapp.json)

A recipe tells LocalRun how to start a project: what to check, what to prepare, which services to run, in which order, and how to know each one is ready. LocalRun does the running, waiting, logging and stopping. The recipe only states facts.

## Where it lives

Every app keeps its recipe **inside its own folder**, always at the same place:

```
my-app/
├── local-run/
│   └── startapp.json    <- the recipe
├── src/
├── package.json
└── ...
```

- Add the project in LocalRun with **New project → Browse**, and choose `local-run/startapp.json`. You can also paste or drop the **app folder** itself: LocalRun finds `local-run/startapp.json` inside it.
- **Relative paths start from the app folder** (the folder that contains `local-run`), not from `local-run` itself. So `"cwd": "backend"` means `my-app/backend`.
- The recipe is versioned with the app, so everyone on the team runs the app the same way.
- Existing `.bat`, `.cmd` and `.ps1` files still work as before.

## Write it human-readable

A recipe is read by people as often as by LocalRun. Keep it easy to scan:

- **2-space indentation, one field per line.** Every object and array is opened over several lines.
- **Fields in a steady order:** `$schema`, `name`, `description`, `path`, `env`, `checks`, `setup`, `services`, `profiles`, `open`, `message`. Inside a service: `name`, `cwd`, `run`, `port`, `shared`, `ready`, `when`, `stop`.
- **A `name` on every check, step and service.** It is what the card, the logs and the error messages show.
- **A `fix` on every check**, in plain words.
- **Forward slashes in paths:** `C:/laragon/bin`, not `C:\\laragon\\bin`.

## The smallest recipe

`my-app/local-run/startapp.json`:

```json
{
  "name": "My API",
  "services": [
    {
      "name": "api",
      "run": "npm run dev",
      "port": 3000
    }
  ]
}
```

LocalRun runs `npm run dev` in the app folder, waits until port 3000 is listening, and shows the project as Running. Stop ends the command and everything it started.

## How a run works

1. **checks**: fail fast, with a fix hint (wrong Node version, missing `.env`, port taken).
2. **setup**: one-off commands that must finish first (`npm ci`, `composer install`, migrations), usually only when needed.
3. **services**: long-running commands, started **in the order listed**. Each one must be **ready** before the next starts.
4. **open** URLs in the browser and show the **message**.

Every command runs through `cmd.exe` in its own hidden process. Its output goes to a log (the **Logs** button on the card). If anything fails, the run stops, everything it started is stopped, and the card shows why.

## All fields

### Top level
| Field | Type | Meaning |
|---|---|---|
| `$schema` | string | Optional. Use `https://raw.githubusercontent.com/ToukirAhamedPigeon/LocalRun/main/schema/localrun.schema.json` for autocomplete and validation in VS Code. |
| `name` | string | Project name, used as the default title. |
| `description` | string | Free text. |
| `root` | string | Folder that relative paths start from. Default: the app folder (the parent of `local-run`). Rarely needed: only when the recipe runs something that lives elsewhere. |
| `path` | string[] | Folders put **in front of PATH** for every command, e.g. a specific PHP or Node version. Wildcards pick the highest match: `C:/laragon/bin/php/php-7.4*`. |
| `env` | object | Environment variables for every command. |
| `profiles` | object | Named modes, such as `lan` or `seed`. See Profiles. |
| `checks` | array | See Checks. |
| `setup` | array | See Setup steps. |
| `services` | array | **Required.** See Services. |
| `open` | array | URLs to open when everything is ready. An item is either a string or `{ "url": "...", "when": {...} }`. |
| `message` | string | Shown when ready, e.g. the address to open on a phone. |

### Services
| Field | Type | Meaning |
|---|---|---|
| `name` | string | **Required**, unique. Used for logs. |
| `run` | string | **Required.** The command, exactly as you would type it in a terminal. |
| `cwd` | string | Working folder, relative to `root`. |
| `env` | object | Extra environment variables for this service. |
| `shell` | `"cmd"` \| `"powershell"` | Default `cmd`. Use `powershell` for PowerShell syntax. |
| `port` | number | The port it listens on. It is used to wait for readiness (if no `ready` is given), to detect a port clash, and to clean up on Stop. |
| `shared` | boolean | For shared infrastructure (MySQL, Redis, PostgreSQL). If `port` is **already listening**, LocalRun uses what is there, starts nothing, and never stops it. Needs `port`. |
| `ready` | object | How to know it is ready. See Readiness. Without it: ready when `port` listens, or immediately if there is no port. |
| `stop` | string | Optional command run on Stop before the process is ended, e.g. `docker compose down`. |
| `when` | object | Only run this service if the condition holds. See Conditions. |

### Readiness (`ready`): use one kind
| Kind | Example | Ready when |
|---|---|---|
| port | `{ "port": 5173 }` | the port is listening |
| url | `{ "url": "http://127.0.0.1:8000/health" }` | it answers with a status below 400 (redirects count). Optional `"status": [200, 302]`. |
| log | `{ "log": "Listening on|ready in" }` | the service's output matches this regular expression |
| command | `{ "command": "adb shell getprop sys.boot_completed", "match": "1" }` | the command's output matches (or it exits 0 if no `match`); retried every 2 s |
| delay | `{ "delay": 3 }` | after N seconds |
| exit | `{ "exit": true }` | it **finishes with exit code 0**: a one-off *task* that must run after the services above it, e.g. migrations once the database is up. It is not watched afterwards. Default timeout 900 s. |

Add `"timeout": 120` to any of them (seconds, default 60).

### Setup steps
| Field | Type | Meaning |
|---|---|---|
| `name` | string | Label shown while it runs. |
| `run` | string | **Required.** Must finish with exit code 0. |
| `cwd`, `env`, `shell` | | As for services. |
| `when` | object | Usually used so the step runs only when needed. |
| `timeout` | number | Seconds, default 900. |

### Checks: use one of `exists`, `command`, `portFree`, `portBusy`
| Field | Meaning |
|---|---|
| `exists` | A file or folder that must exist (wildcards allowed). |
| `command` + `match` | Run a quick command. It passes if the output matches the regular expression, or, without `match`, if it exits 0. |
| `portFree` | This port must not be in use. |
| `portBusy` | Something must already listen on this port, e.g. a database service you run yourself. |
| `name` | Label. |
| `fix` | Shown when the check fails: tell the developer exactly what to do. |
| `warn` | `true` = only warn, do not stop the run. |
| `when` | Only check under this condition. |

### Conditions (`when`): all listed must hold
| Key | True when |
|---|---|
| `profile` / `notProfile` | the run uses / does not use this profile |
| `exists` / `missing` | a path exists / does not exist (wildcards allowed) |
| `newer` | `["a", "b"]`: `a` is newer than `b`, or `b` does not exist |
| `portFree` / `portBusy` | a port is free / in use |
| `any` | a list of conditions; at least one must hold |

Example, "run composer only if vendor is missing or the lock file changed":
```json
{
  "name": "composer install",
  "run": "composer install --no-interaction",
  "when": {
    "any": [
      {
        "missing": "vendor/autoload.php"
      },
      {
        "newer": [
          "composer.lock",
          "vendor/composer/installed.json"
        ]
      }
    ]
  }
}
```

### Profiles
```json
"profiles": {
  "lan": {
    "description": "Reachable from a phone on the same Wi-Fi",
    "env": {
      "HOST": "0.0.0.0"
    },
    "open": [
      "http://${LAN_IP}:5173"
    ],
    "message": "On your phone open http://${LAN_IP}:5173"
  },
  "seed": {
    "description": "Reset and seed the database first"
  }
}
```
A profile can add `env`, `open` and `message`. Steps and services opt in or out with `"when": { "profile": "seed" }` or `"when": { "notProfile": "lan" }`. With profiles defined, the card gets a **▾** button next to **Run** for choosing one.

### Variables (in commands, paths, env, urls, message)
| Variable | Value |
|---|---|
| `${ROOT}` | the app folder (the parent of `local-run`) |
| `${LAN_IP}` | this PC's address on the local network (the adapter with a default gateway) |
| `${PROFILE}` | the profile name, or empty |
| `${env:NAME}` | an environment variable |

Inside `run` commands you can also use environment variables the normal cmd way, `%NAME%`, including the ones set by `env` and profiles. The templates use this to switch the bind address in the `lan` profile.

## Rules that avoid most mistakes
1. **Backslashes:** in JSON write `C:\\laragon\\bin` or, simpler, `C:/laragon/bin`.
2. **One long-running command per service.** Do not chain two servers with `&`. Make them two services.
3. **One-off commands go in `setup`**, guarded with `when` so they run only when needed. A one-off that needs a running service first (migrations after the database) is a service with `"ready": { "exit": true }`, listed after that service.
4. **Give every server a `port`.** It gives readiness, clash detection and clean Stop for free.
5. **Databases and caches you already run** (Laragon MySQL, a PostgreSQL service, Memurai) → `"shared": true`.
6. **Phone access:** bind to `0.0.0.0` in a `lan` profile (Vite `--host`, `php artisan serve --host 0.0.0.0`, uvicorn `--host 0.0.0.0`, `dotnet run --urls http://0.0.0.0:5000`). Windows may ask once to allow the app through the firewall.
7. **Mobile apps:** Android works (emulator + `flutter run` / `npx react-native run-android`). **iOS simulators need macOS**, so on Windows use a web or Android target.

## Writing a recipe with an AI assistant
In LocalRun open **Recipe guide → Copy AI prompt**, paste it into any AI assistant together with the project's key files (`package.json`, `composer.json`, `*.csproj`, `pyproject.toml`, `docker-compose.yml`, `.env.example`, the README's "run locally" section), and save the answer as `local-run/startapp.json` in the app folder.
