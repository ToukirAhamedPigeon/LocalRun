# LocalRun Engine: plan for "one click, any stack"

_Draft, 2026-09-26. Status: proposal, not started._

## 1. The problem, stated from real projects

Every project needs its own start script, and every stack differs: PHP 7.4 on Laragon, Python 3.11 + FastAPI, NestJS, .NET. Versions differ between projects. Some projects need two apps started together (Project A: two apps). Some need to be reachable from a phone on the same Wi-Fi (Project B, over HTTPS so the phone browser allows the camera). Today each script is written by hand, or by an AI in the project folder: 202 lines for Project A and 559 lines for Project B.

## 2. The finding that shapes the plan

Reading the two real scripts line by line, the variability is **not** where it looks:

| In both scripts | Project A `start-dev.ps1` | Project B `dev-windows.ps1` |
|---|---|---|
| Pin a toolchain version | Laragon PHP 7.4, MySQL 8.1 on PATH | `.venv` Python, must be ≥ 3.11 |
| Find a binary with fallbacks | fixed Laragon paths | override env → Memurai → Laragon `redis-x64-*` → PATH → fakeredis |
| Preflight checks with a fix hint | `.env`, DB has tables, port 80 owner | `.venv`, `backend\.env`, `node_modules`, 5432 |
| Conditional setup steps | `composer install` if lock is newer, assets, `storage:link` | ensure bucket; `-Seed` → migrate + seed |
| Shared services: start only if not already listening | MySQL, Redis, Apache | Redis, storage (Postgres expected) |
| Readiness | wait for port; HTTP 200/3xx | wait for port; `/health/ready` JSON `status == ok` |
| Process identity + tree kill | by process name | port owner + start time, `taskkill /T` |
| Logs, exit watch | none | per-service log files, tail on exit |
| Modes | `-Stop -Status -InstallDeps` | `-Lan -Seed -Tunnel -Stop` |
| LAN / phone | none | LAN IP by default gateway, mkcert, `VITE_HOST=0.0.0.0`, phone CA steps |
| After start | open 2 URLs | open URL, print phone URL |

**About 80% of each script is the same machinery, written again. About 20% is facts about the project.** Stacks don't need to be normalised. The *verbs* do:

> **Build the machinery once, inside LocalRun. Each project then becomes a short file of facts: a *recipe*.**

## 3. The recipe (`local-run/startapp.json` in the app folder)

Declarative data in a small, fixed vocabulary. It lives with the project, so it is versioned with the code and teammates share it.

| Primitive | What it covers |
|---|---|
| `requires` | tool + version + where to look (`find` globs, env override, PATH) + a fix hint. The resolved path is prepended to PATH **per service**, so PHP 7.4 and PHP 8.2 projects can run at the same time. |
| `checks` | preflight: `exists`, `command`, `port-free`, `http`, `sql` — each with a `fix` message |
| `steps` | setup commands with `when`: `missing <path>`, `newer <a> than <b>`, `profile <name>` |
| `services` | `run` (`exe` + `args` + `cwd` + `env`), `port`, `after` (order), `ready` (`port` / `http` + json condition / log regex), `shared` (leave alone if already running, stop only if we started it), `first` (binary candidates), `fallback` (+ `ephemeral` warning) |
| `profiles` | named modes that override env/args and add steps: `lan`, `seed`, `tunnel`, … |
| `open` | URLs to open once ready |
| `script` | **escape hatch**: run an existing script as-is. Nothing is ever impossible to express. |

Variables: `${LAN_IP}`, `${PROJECT}`, `${env:NAME}`, `${tool:php}`, `${port:api}`.

### Sketch: Project A, two Laravel apps on Laragon
```json
{
  "name": "Project A (app1 + app2)",
  "requires": {
    "php":   { "version": "7.4", "find": ["C:/laragon/bin/php/php-7.4*"] },
    "mysql": { "version": "8.1", "find": ["C:/laragon/bin/mysql/mysql-8.1*"] }
  },
  "checks": [
    { "exists": ".env", "fix": "Copy .env.example to .env" },
    { "exists": "../app2/.env", "fix": "Copy .env.example to .env in app2" },
    { "sql": "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='app_db'", "expect": "> 0" }
  ],
  "steps": [
    { "run": "composer install --no-interaction --prefer-dist", "cwd": ["./", "../app2"],
      "when": { "missing": "vendor/autoload.php", "newer": ["composer.lock", "vendor/composer/installed.json"] } },
    { "run": "php artisan storage:link", "cwd": ["./", "../app2"], "when": { "missing": "public/storage" } }
  ],
  "services": [
    { "id": "mysql",  "shared": true, "port": 3306, "run": "${tool:mysql}/bin/mysqld.exe --defaults-file=${tool:mysql}/my.ini", "ready": { "port": 3306, "timeout": 90 } },
    { "id": "redis",  "shared": true, "optional": true, "port": 6379, "run": { "first": ["C:/laragon/bin/redis/redis-x64-*/redis-server.exe"] } },
    { "id": "apache", "shared": true, "port": 80, "after": ["mysql"], "run": { "first": ["C:/laragon/bin/apache/httpd-2.4*/bin/httpd.exe"] } }
  ],
  "open": ["http://app1.local/", "http://app2.local/"]
}
```

### Sketch: Project B, FastAPI + Vite + Redis + object storage, with LAN mode for a phone
```json
{
  "name": "Project B",
  "requires": { "python": { "version": ">=3.11", "find": [".venv/Scripts/python.exe"], "fix": "py -3.11 -m venv .venv" } },
  "checks": [
    { "exists": "backend/.env" },
    { "exists": "frontend/node_modules", "fix": "cd frontend; npm ci" },
    { "port-busy": 5432, "warn": "Is the PostgreSQL service running?" }
  ],
  "services": [
    { "id": "redis", "shared": true, "port": 6379,
      "run": { "first": ["${env:APP_REDIS_EXE}", "%ProgramFiles%/Memurai/memurai.exe", "C:/laragon/bin/redis/redis-x64-*/redis-server.exe", "PATH:redis-server"],
               "args": "--port 6379 --appendonly yes --dir .dev-data/redis" },
      "fallback": { "run": "${tool:python} scripts/dev_redis.py", "ephemeral": "In-memory only: data is lost on stop" } },
    { "id": "storage", "port": 9000,
      "run": { "first": ["tools/minio.exe", "%ProgramFiles%/MinIO/minio.exe", "PATH:minio"], "args": "server minio-data --address 127.0.0.1:9000" },
      "fallback": { "run": ".venv/Scripts/moto_server.exe -H 127.0.0.1 -p 9000", "ephemeral": "In-memory only: uploaded files are lost on stop" } },
    { "id": "api", "cwd": "backend", "port": 8000, "after": ["redis", "storage"],
      "before": ["${tool:python} -m scripts.ensure_bucket"],
      "run": "${tool:python} -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload",
      "ready": { "http": "http://127.0.0.1:8000/health/ready", "json": "status == 'ok'", "timeout": 60 } },
    { "id": "web", "cwd": "frontend", "port": 5173, "run": "npm run dev" }
  ],
  "profiles": {
    "seed": { "steps": [{ "run": ".venv/Scripts/alembic.exe upgrade head", "cwd": "backend" }, { "run": "${tool:python} -m scripts.seed", "cwd": "backend" }] },
    "lan":  { "tls": "mkcert", "env": { "VITE_HOST": "0.0.0.0", "VITE_HTTPS": "1", "VITE_ALLOWED_HOSTS": "${LAN_IP}" },
              "open": "https://${LAN_IP}:5173", "phone": true }
  },
  "open": ["http://localhost:5173"]
}
```
**Test of the design:** if these two recipes can replace the 761 lines of script and do everything the scripts do (start, stop, status, LAN, seed), the vocabulary is right. If Project B needs the `script` escape hatch for more than one step, the vocabulary is wrong and must change before any UI work.

## 4. The engine (built once, used by every recipe)

Lifted from what the Project B script already gets right:
- **Toolchain resolution:** Laragon `bin\*` folders, nvm-windows / fnm / Volta, `py -3.x`, venvs, pyenv-win, dotnet `global.json`. A per-service PATH so versions never collide. Clear preflight errors, e.g. "needs Node 18, found 20 → `nvm install 18`".
- **Process model:** track the **port owner**, not the wrapper pid (`cmd /c npm`, venv python re-exec). Identity = pid + start time. `taskkill /T`. Stop only what this run started. Leave shared services alone.
- **Readiness:** port, HTTP status, JSON condition, log regex, each with a timeout. On failure, show the failing step and the last 15 log lines.
- **Logs:** one stream per service, shown in LocalRun as tabs, and also saved to disk.
- **LAN mode, generic:** LAN IP by default gateway (skipping Docker/WSL/Hyper-V adapters), mkcert certificate reissued per run, `${LAN_IP}` variable, **QR code** in the app for the phone URL, the one-time CA instructions per phone OS, and a firewall-rule prompt (the one step that needs admin).
- **Groups:** one click runs several recipes together. Shared services such as MySQL on 3306 are started once.
- **CLI too:** `localrun up project-b --profile lan`, `localrun down`, `localrun status`. It is scriptable, and it is how the engine gets tested.

## 5. How a recipe gets written: the real challenge

Three layers, with a human confirming at each:
1. **Import:** existing scripts keep working as `script` recipes. No forced migration.
2. **Detectors:** a rule pack per stack reads `composer.json` + `artisan`, `package.json` (vite / nest scripts), `*.csproj`, `pyproject.toml` / `requirements.txt` / `manage.py`, `docker-compose.yml`, `.env*` (ports, DB), and Laragon's config. The output is a **draft recipe**. Rule packs are data too, so they are open to contributions.
3. **AI author:** a *Generate recipe* button runs Claude Code headless (`claude -p`) in the project folder. It uses a fixed prompt, the recipe JSON schema and the detector findings, and it returns **recipe JSON only, not a script**. LocalRun validates it against the schema, runs preflight as a dry run, and shows it for approval. This reuses the Claude subscription already on the machine, so there are no API keys to manage. Without Claude Code, a *Copy prompt* button lets any AI chat do it.
4. **Repair loop:** when a start fails, LocalRun already knows *which* step failed and has its log tail. *Fix with AI* sends exactly that and proposes a patch to the recipe. **Each new project's differences then become a quick fix, not a debugging session.**

### 5a. A free local model instead of (or besides) Claude: added 2026-09-26
An **AI provider** setting: *Local (built in)* · *Ollama (if already installed)* · *Claude Code CLI* · *Copy prompt*.

**Built-in local option, kept light:**
- **Runtime: llama.cpp `llama-server`** (MIT), the CPU build for Windows x64: a small portable folder with no service and no install. It offers an OpenAI-compatible HTTP API on `127.0.0.1` and **JSON-schema-constrained output**, so the model *cannot* return invalid recipe JSON. Ollama is not bundled, because it is a much larger install with a background service, but it is used if the user already has it (it also supports JSON-schema output).
- **Model: not bundled in the installer.** Weights are 1–3 GB, so the installer stays ~250 KB. Weights are downloaded on the first *Generate recipe*, **only after the user confirms** (the privacy statement promises no network use unless requested), with a checksum check. Candidates, all licensed so an MIT app can use them:
  | Model | License | Q4 size | Note |
  |---|---|---|---|
  | Qwen3.5 4B (or current Qwen small) | Apache 2.0 (verify on model card) | ~2.5 GB | best quality/size for structured extraction |
  | Phi-4-mini-instruct 3.8B | MIT | ~2.3 GB | ~12 tok/s CPU-only, 128K context |
  | Gemma 4 E2B | Apache 2.0 | ~1.5 GB | fastest, lowest RAM |
  | Qwen2.5-Coder 1.5B | Apache 2.0 | ~1 GB | smallest code model. ⚠ **not the 3B**, which is under the Qwen *Research* license |
- **Expected speed:** a recipe is ~600–1,200 output tokens → roughly **1–2 minutes on CPU**. RAM ~3–4 GB.

**The design that makes a small model good enough:** the model never reads the repository. The **detectors** (deterministic) read the files and produce a compact *project summary* of a few KB: stack, versions, scripts, ports, env keys, the services found. The model only turns that summary into a recipe, inside a JSON schema, with validation and a preflight dry run afterwards. A 2–4 B model is weak at reading a whole codebase but adequate at this narrow, constrained job.

**Choose the model with evidence, not guesses:** after P0, the hand-written Project A and Project B recipes become the *gold standard*. Run each candidate model on the same detector summaries and score how close its recipe comes (correct services, ports, order, readiness, LAN profile). Pick the smallest model that passes. If none passes, the local option ships as *draft only*, with Claude/Ollama for hard cases.

### 5b. Requirement (2026-09-26): everything local, total install ≤ 500 MB, no Claude needed
_This supersedes the model table in 5a. Those models are 1.5–2.5 GB._

**Size budget:** app ~1 MB + llama.cpp CPU runtime ~30–60 MB (measure) + model **≤ ~400 MB** → under 500 MB.

**What fits (Q4/Q8 GGUF, licences usable in an MIT app):**
| Model | Licence | Size | Note |
|---|---|---|---|
| Qwen2.5-Coder 0.5B Instruct | Apache 2.0 | ~0.4 GB (Q4) | code-trained; the likely base |
| IBM Granite 4.0 Nano 350M | Apache 2.0 | ~0.25–0.4 GB | newest (2026), made for on-device use |
| SmolLM2 360M Instruct | Apache 2.0 | ~0.25–0.4 GB | fallback |
| Qwen3 0.6B | Apache 2.0 | ~0.4–0.5 GB | borderline on size |

At 0.35–0.6 B parameters, CPU speed is fast (a recipe in well under a minute) and RAM is ~1 GB.

**The honest limit:** a model this size **cannot do what Claude Code does in general**: read an arbitrary repository, reason about it, run commands, iterate. It *can* do one narrow, repetitive task well, especially after fine-tuning on that exact task. So the requirement is met by **changing the job, not by finding a magic model**:

| Part of the job | Done by |
|---|---|
| Find the stack, versions, ports, scripts, env keys, services | **Rules (detectors)**: deterministic, no model |
| Known stacks: start commands, order, readiness, LAN tweaks (Vite `--host`, uvicorn `--host`, `dotnet --urls`, `artisan serve --host`) | **Stack packs**: a curated catalog of data files, no model |
| Ambiguous choices, e.g. which of 6 npm scripts is the dev server, or which env key is the API URL | **Small model, picking from the given candidates** (classification, JSON-constrained) |
| Unknown or long-tail stacks | **Small model drafts** from the compact summary; the user confirms |
| Why did it fail? | **Error catalog** (port in use, missing module, wrong version, DB refused, missing `.env`…) + **small model classifies the log tail** into it → catalog fix |

**Making the small model good at this task: distillation.** This is a one-time job at development time, not on the user's PC:
1. Collect ~300–1,000 real projects across stacks (public GitHub repos: Laravel, Django/FastAPI, NestJS/Express, ASP.NET, Rails…) plus real private projects.
2. Detectors → project summary. **Claude (the teacher) writes the gold recipe** for each. Keep only recipes that validate against the schema and pass a preflight/run check. A small filtered set beats a big noisy one.
3. LoRA fine-tune each candidate (0.35–0.6 B) on a free Colab/Kaggle GPU. Models this size train in minutes to hours.
4. Quantize to GGUF, then evaluate on a held-out set **plus the P0 gold recipes (Project A, Project B)**. Ship the smallest model that passes.
5. Every failure users choose to report becomes new training data for the next version.

Claude is used **only to make the training data**, a few dollars' worth, once. At runtime LocalRun needs no Claude, no internet, no API key.

**Added effort:** roughly +4–6 slots on top of section 6 (dataset, fine-tune, eval, packaging). It only makes sense after P0–P2 prove the recipe design.

Why a recipe rather than a generated script: the AI only has to get **facts** right, inside a vocabulary that can be validated. The fragile parts (process identity, tree kill, readiness, LAN, TLS) are written once, tested once, and never generated again.

## 6. Phases

| Phase | Output | Effort (3-hour slots) | Go / no-go |
|---|---|---|---|
| **P0** | Recipe schema v0 + hand-written recipes for Project A and Project B. No code. | 1 | Can the recipes express both scripts without the escape hatch? If not, redesign. |
| **P1** | Engine + CLI: requires, checks, steps, services, ready, stop, logs | 2 | `localrun up project-a` and `up project-b` match the scripts |
| **P2** | UI: services per project, status dots, log tabs, Run-all / Stop-all, groups, profile picker on Run | 2 | Used daily for a week instead of the scripts |
| **P3** | LAN mode: IP, mkcert, phone URL + QR, CA guide, firewall prompt | 1 | Project B runs on a phone over HTTPS from one click |
| **P4** | Detectors for Laravel/Laragon, Vite, NestJS, FastAPI/Django, ASP.NET | 1–2 | Draft recipe for a *new* project needs ≤ 3 edits |
| **P5** | AI author + Fix-with-AI via `claude -p` | 1 | A new project runs from a generated recipe in under 10 minutes |

About 8–9 slots. **Stop after any phase that misses its go/no-go.**

## 7. Scope and order

- This is a plan for LocalRun as a free, open-source tool. Effort is counted in 3-hour slots. Stop after any phase that misses its go/no-go.
- **P0 comes first and is cheap:** it tells whether the rest is worth doing. The fine-tuned local model (5b) only makes sense after P0–P2 have proven the recipe design.
- For a handful of projects, the payoff of P1–P5 is small, because writing one script with an AI assistant takes minutes. The payoff grows with the number of projects and users.
- Project A and Project B are real, private projects used as test cases. Their recipes are kept outside this repository.
