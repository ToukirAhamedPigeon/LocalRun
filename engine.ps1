# LocalRun recipe engine.
# Reads a recipe (<app>/local-run/startapp.json) and runs it: checks -> setup steps -> services -> running.
# No UI here. LocalRun.ps1 calls New-Run, then Invoke-RunTick every half second, and reads
# $run.Status / $run.Phase. Tests can drive the same functions headless.
#
# The recipe format is documented in docs/recipe-format.md and schema/localrun.schema.json.

$script:EngineLogRoot = Join-Path $env:LOCALAPPDATA 'LocalRun\logs'

$script:RecipeTopKeys   = @('$schema', 'name', 'description', 'root', 'path', 'env', 'profiles', 'checks', 'setup', 'services', 'open', 'message')
$script:ServiceKeys     = @('name', 'run', 'cwd', 'env', 'shell', 'port', 'shared', 'ready', 'when', 'stop', 'description')
$script:StepKeys        = @('name', 'run', 'cwd', 'env', 'shell', 'when', 'timeout', 'description')
$script:CheckKeys       = @('name', 'exists', 'command', 'match', 'portFree', 'portBusy', 'fix', 'warn', 'when')
$script:ReadyKeys       = @('port', 'url', 'status', 'log', 'command', 'match', 'delay', 'exit', 'timeout')
$script:WhenKeys        = @('profile', 'notProfile', 'exists', 'missing', 'newer', 'portFree', 'portBusy', 'any')

# ---------------------------------------------------------------- reading + validation
function Get-Names($obj) {
    if ($null -eq $obj) { return @() }
    return @($obj.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-KnownKeys($obj, $allowed, $where, $warnings) {
    foreach ($k in (Get-Names $obj)) {
        if ($allowed -notcontains $k) { [void]$warnings.Add("$where has an unknown field '$k' (ignored).") }
    }
}

# Returns @{ Recipe; Errors; Warnings }. Errors stop a run; warnings are shown but ignored.
function Read-Recipe([string]$path) {
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $result = @{ Recipe = $null; Errors = $errors; Warnings = $warnings }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { [void]$errors.Add("Recipe file not found: $path"); return $result }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $r = ConvertFrom-Json $raw
    } catch {
        # PowerShell's message embeds the whole file; keep the reason and turn the offset into line:column.
        $msg = ($_.Exception.Message -split '\r?\n')[0]
        $where = ''
        if ($msg -match '^(.*?)\s*\((\d+)\):') {
            $reason = $Matches[1]
            $offset = [int]$Matches[2]
            $before = $raw.Substring(0, [Math]::Min($offset, $raw.Length))
            $line = ([regex]::Matches($before, "`n")).Count + 1
            $col = $offset - $before.LastIndexOf("`n")
            $where = " at line $line, column $col"
            $msg = $reason.TrimEnd('.')
        }
        $hint = if ($msg -match 'escape') { ' In JSON a backslash must be doubled (C:\\laragon), or use forward slashes (C:/laragon).' } else { '' }
        [void]$errors.Add("The file is not valid JSON$($where): $msg.$hint")
        return $result
    }
    if ($null -eq $r -or $r -is [array]) { [void]$errors.Add('The recipe must be a JSON object: { ... }'); return $result }
    $result.Recipe = $r
    Test-KnownKeys $r $script:RecipeTopKeys 'The recipe' $warnings

    $services = @($r.services)
    if ($services.Count -eq 0 -or $null -eq $r.services) { [void]$errors.Add("'services' is required and must list at least one service.") }
    $names = @{}
    $i = 0
    foreach ($s in $services) {
        $i++
        $label = if ($s.name) { "Service '$($s.name)'" } else { "Service #$i" }
        if (-not $s.name) { [void]$errors.Add("$label needs a 'name'.") }
        elseif ($names.ContainsKey([string]$s.name)) { [void]$errors.Add("Two services are named '$($s.name)'. Names must be unique.") }
        else { $names[[string]$s.name] = $true }
        if (-not $s.run) { [void]$errors.Add("$label needs a 'run' command.") }
        if ($s.shared -and -not $s.port) { [void]$errors.Add("$label is 'shared' but has no 'port' (the port is how LocalRun sees it is already running).") }
        if ($s.shell -and @('cmd', 'powershell') -notcontains $s.shell) { [void]$errors.Add("$label has shell '$($s.shell)'. Use 'cmd' or 'powershell'.") }
        Test-KnownKeys $s $script:ServiceKeys $label $warnings
        if ($s.ready) { Test-KnownKeys $s.ready $script:ReadyKeys "$label ready" $warnings }
        if ($s.when) { Test-KnownKeys $s.when $script:WhenKeys "$label when" $warnings }
    }
    $i = 0
    foreach ($st in @($r.setup)) {
        if ($null -eq $st) { continue }
        $i++
        $label = if ($st.name) { "Setup step '$($st.name)'" } else { "Setup step #$i" }
        if (-not $st.run) { [void]$errors.Add("$label needs a 'run' command.") }
        Test-KnownKeys $st $script:StepKeys $label $warnings
    }
    $i = 0
    foreach ($c in @($r.checks)) {
        if ($null -eq $c) { continue }
        $i++
        $label = if ($c.name) { "Check '$($c.name)'" } else { "Check #$i" }
        if (-not ($c.exists -or $c.command -or $c.portFree -or $c.portBusy)) { [void]$errors.Add("$label needs one of 'exists', 'command', 'portFree' or 'portBusy'.") }
        Test-KnownKeys $c $script:CheckKeys $label $warnings
    }
    if ($r.profiles -and $r.profiles -is [array]) { [void]$errors.Add("'profiles' must be an object, e.g. { ""lan"": { ""env"": { } } }.") }
    return $result
}

function Get-RecipeProfiles($recipe) {
    if (-not $recipe -or -not $recipe.profiles) { return @() }
    return @(Get-Names $recipe.profiles)
}

# ---------------------------------------------------------------- small helpers
function Test-PortListening([int]$port) {
    try {
        foreach ($ep in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            if ($ep.Port -eq $port) { return $true }
        }
    } catch {}
    return $false
}

# The address a phone on the same Wi-Fi can reach: the adapter that has a default gateway.
# (Docker, WSL and Hyper-V adapters have private addresses too, but no gateway a phone can use.)
function Get-LanAddress {
    try {
        $ip = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
            ForEach-Object { $_.IPv4Address.IPAddress } |
            Where-Object { $_ -and $_ -ne '127.0.0.1' } | Select-Object -First 1
        if ($ip) { return [string]$ip }
    } catch {}
    return '127.0.0.1'
}

function Expand-RecipeText([string]$text, $ctx) {
    if ($null -eq $text) { return $null }
    if ($text.Contains('${LAN_IP}') -and -not $ctx.LanIp) { $ctx.LanIp = Get-LanAddress }
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $key = $m.Groups[1].Value
        if ($key -eq 'ROOT') { return $ctx.Root }
        if ($key -eq 'LAN_IP') { return $ctx.LanIp }
        if ($key -eq 'PROFILE') { return $ctx.Profile }
        if ($key -like 'env:*') { $v = [Environment]::GetEnvironmentVariable($key.Substring(4)); if ($null -eq $v) { return '' } else { return $v } }
        return $m.Value
    }
    return [regex]::Replace($text, '\$\{([^}]+)\}', $evaluator)
}

# Relative paths are relative to the recipe root. Wildcards pick the last (highest-versioned) match.
function Resolve-RecipePath([string]$path, $ctx, [switch]$Pick) {
    $p = Expand-RecipeText $path $ctx
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $ctx.Root $p }
    if ($Pick -and ($p.Contains('*') -or $p.Contains('?'))) {
        $match = Resolve-Path -Path $p -ErrorAction SilentlyContinue | Select-Object -Last 1 -ExpandProperty Path
        if ($match) { return $match }
    }
    return $p
}

function Test-When($when, $ctx) {
    if ($null -eq $when) { return $true }
    if ($when.any) {
        $hit = $false
        foreach ($w in @($when.any)) { if (Test-When $w $ctx) { $hit = $true; break } }
        if (-not $hit) { return $false }
    }
    if ($when.profile -and $when.profile -ne $ctx.Profile) { return $false }
    if ($when.notProfile -and $when.notProfile -eq $ctx.Profile) { return $false }
    if ($when.exists -and -not (Test-Path -Path (Resolve-RecipePath $when.exists $ctx))) { return $false }
    if ($when.missing -and (Test-Path -Path (Resolve-RecipePath $when.missing $ctx))) { return $false }
    if ($when.newer) {
        $pair = @($when.newer)
        $a = Resolve-RecipePath $pair[0] $ctx
        $b = Resolve-RecipePath $pair[1] $ctx
        if (-not (Test-Path -LiteralPath $a)) { return $false }
        if ((Test-Path -LiteralPath $b) -and ((Get-Item -LiteralPath $a).LastWriteTime -le (Get-Item -LiteralPath $b).LastWriteTime)) { return $false }
    }
    if ($when.portFree -and (Test-PortListening ([int]$when.portFree))) { return $false }
    if ($when.portBusy -and -not (Test-PortListening ([int]$when.portBusy))) { return $false }
    return $true
}

function Write-EngineLog($run, [string]$msg) {
    try { Add-Content -LiteralPath $run.EngineLog -Value "$(Get-Date -Format 'HH:mm:ss')  $msg" -Encoding UTF8 } catch {}
}

function Get-LogTail([string]$file, [int]$lines = 15) {
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { return '' }
    try {
        $fs = [System.IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        try {
            $max = 64KB
            if ($fs.Length -gt $max) { [void]$fs.Seek(-$max, 'End') }
            $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd()
        } finally { $fs.Close() }
        $all = $text -split "\r?\n" | Where-Object { $_ -ne '' }
        return (@($all) | Select-Object -Last $lines) -join "`n"
    } catch { return '' }
}

# Environment for one command: recipe env + profile env + own env, all expanded.
function Get-CommandEnv($run, $own) {
    $vars = [ordered]@{}
    foreach ($src in @($run.Recipe.env, $run.ProfileDef.env, $own)) {
        if ($null -eq $src) { continue }
        foreach ($n in (Get-Names $src)) { $vars[$n] = Expand-RecipeText ([string]$src.$n) $run.Ctx }
    }
    return $vars
}

# Every command runs through cmd.exe so its output lands in one log file and it has one
# process tree to stop. shell=powershell writes the command to a .ps1 and runs that.
function Start-RecipeProcess($run, [string]$command, [string]$cwd, $envVars, [string]$logFile, [string]$shell) {
    $command = Expand-RecipeText $command $run.Ctx
    if ($shell -eq 'powershell') {
        $ps1 = [System.IO.Path]::ChangeExtension($logFile, '.ps1')
        [System.IO.File]::WriteAllText($ps1, $command, (New-Object System.Text.UTF8Encoding $true))
        $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1`""
    }
    $dir = if ($cwd) { Resolve-RecipePath $cwd $run.Ctx } else { $run.Ctx.Root }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Folder not found: $dir" }

    $saved = @{}
    $names = @($envVars.Keys) + @('PATH')
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    try {
        if ($run.PathPrefix) { [Environment]::SetEnvironmentVariable('PATH', ($run.PathPrefix + ';' + $saved['PATH']), 'Process') }
        foreach ($n in $envVars.Keys) { [Environment]::SetEnvironmentVariable($n, [string]$envVars[$n], 'Process') }
        Add-Content -LiteralPath $logFile -Value "> $command   (in $dir)" -Encoding UTF8
        # Parentheses keep the command's own redirections (echo x> file) working inside ours.
        $cmdArgs = "/d /s /c `"($command) >> `"$logFile`" 2>&1`""
        return Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList $cmdArgs `
            -WorkingDirectory $dir -WindowStyle Hidden -PassThru
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
}

function Stop-ProcessTree($proc) {
    if (-not $proc) { return }
    try {
        if (-not $proc.HasExited) { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null }
    } catch {}
    $global:LASTEXITCODE = 0
}

# Something may still hold the port after the tree is gone (a server that re-parented itself).
# Only kill it if it started after this run did - an older process is not ours.
function Stop-PortOwner([int]$port, [datetime]$since) {
    try {
        $owners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique
        foreach ($o in $owners) {
            $p = Get-Process -Id $o -ErrorAction SilentlyContinue
            if ($p -and $p.StartTime -ge $since.AddSeconds(-1)) { & taskkill.exe /PID $o /T /F 2>&1 | Out-Null }
        }
    } catch {}
    $global:LASTEXITCODE = 0
}

# ---------------------------------------------------------------- a run
# The convention is <app>\local-run\startapp.json. Relative paths in a recipe start from the
# app folder, so a recipe inside a "local-run" folder gets its parent as root.
$script:RecipeFolder = 'local-run'
$script:RecipeFile = 'startapp.json'

function Get-RecipeRoot([string]$recipePath) {
    $dir = Split-Path -Parent $recipePath
    if ((Split-Path -Leaf $dir) -eq $script:RecipeFolder) { return (Split-Path -Parent $dir) }
    return $dir
}

# A folder given instead of a file resolves to its local-run\startapp.json, when there is one.
function Resolve-RecipeInput([string]$path) {
    if ($path -and (Test-Path -LiteralPath $path -PathType Container)) {
        $candidate = Join-Path $path (Join-Path $script:RecipeFolder $script:RecipeFile)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $path
}

function New-Run([string]$projectId, [string]$recipePath, [string]$profile = '') {
    $read = Read-Recipe $recipePath
    $recipeDir = Get-RecipeRoot $recipePath
    $logDir = Join-Path $script:EngineLogRoot $projectId
    try {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
    $run = [pscustomobject]@{
        ProjectId = $projectId; RecipePath = $recipePath; Recipe = $read.Recipe
        Warnings = $read.Warnings; Profile = $profile; ProfileDef = $null
        Ctx = @{ Root = $recipeDir; Profile = $profile; LanIp = $null }
        Phase = 'checks'; Status = 'Checking...'; Error = $null; FailedLog = $null
        Steps = @(); StepIndex = 0; Current = $null; CurrentLog = $null; CurrentStart = $null
        Services = (New-Object System.Collections.ArrayList); ServiceIndex = 0
        StartedAt = Get-Date; LogDir = $logDir; EngineLog = (Join-Path $logDir 'localrun.log')
        PathPrefix = ''; Opened = @(); Message = $null
    }
    Write-EngineLog $run "Recipe $recipePath$(if ($profile) { " (profile: $profile)" })"
    if ($read.Errors.Count -gt 0) {
        Set-RunFailed $run ("The recipe has errors:`n- " + ($read.Errors -join "`n- ")) $null
        return $run
    }
    $r = $read.Recipe
    if ($r.root) { $run.Ctx.Root = Resolve-RecipePath $r.root @{ Root = $recipeDir; Profile = $profile; LanIp = $null } }
    if ($profile) {
        if ((Get-RecipeProfiles $r) -notcontains $profile) { Set-RunFailed $run "The recipe has no profile named '$profile'." $null; return $run }
        $run.ProfileDef = $r.profiles.$profile
    }
    foreach ($w in $read.Warnings) { Write-EngineLog $run "warning: $w" }
    return $run
}

function Set-RunFailed($run, [string]$reason, [string]$logFile) {
    $run.Phase = 'failed'
    $run.Error = $reason
    $run.FailedLog = $logFile
    $first = ($reason -split "`n")[0]
    $run.Status = "Failed: $first"
    Write-EngineLog $run "FAILED: $reason"
    Stop-RunProcesses $run
}

function Stop-RunProcesses($run) {
    if ($run.Current) { Stop-ProcessTree $run.Current; $run.Current = $null }
    for ($i = $run.Services.Count - 1; $i -ge 0; $i--) {
        $s = $run.Services[$i]
        if ($s.External -or -not $s.Proc) { continue }
        if ($s.Def.stop) {
            # The service's own shutdown first (e.g. docker compose down); the tree kill is the fallback.
            Write-EngineLog $run "stop: $($s.Name) -> $($s.Def.stop)"
            [void](Invoke-CheckCommand $run $s.Def.stop 60000 $s.Def.cwd (Get-CommandEnv $run $s.Def.env))
        }
        Stop-ProcessTree $s.Proc
        if ($s.Port) { Stop-PortOwner $s.Port $run.StartedAt }
        $s.Proc = $null
    }
}

function Stop-Run($run) {
    if (-not $run) { return }
    Write-EngineLog $run 'Stopping'
    Stop-RunProcesses $run
    $run.Phase = 'stopped'
    $run.Status = 'Stopped'
}

function Test-RunActive($run) {
    return $run -and @('checks', 'setup', 'services', 'running') -contains $run.Phase
}

function Invoke-Checks($run) {
    $r = $run.Recipe
    # PATH entries first: checks like "node --version" must see the pinned toolchain.
    $prefix = @()
    foreach ($p in @($r.path)) {
        if (-not $p) { continue }
        $resolved = Resolve-RecipePath $p $run.Ctx -Pick
        if (-not (Test-Path -LiteralPath $resolved)) { return "PATH entry not found: $p" }
        $prefix += $resolved
    }
    $run.PathPrefix = $prefix -join ';'

    $i = 0
    foreach ($c in @($r.checks)) {
        if ($null -eq $c) { continue }
        $i++
        if (-not (Test-When $c.when $run.Ctx)) { continue }
        $label = if ($c.name) { $c.name } else { "check #$i" }
        $problem = $null
        if ($c.exists) {
            if (-not (Test-Path -Path (Resolve-RecipePath $c.exists $run.Ctx))) { $problem = "'$($c.exists)' does not exist" }
        } elseif ($c.portFree) {
            if (Test-PortListening ([int]$c.portFree)) { $problem = "port $($c.portFree) is already in use" }
        } elseif ($c.portBusy) {
            if (-not (Test-PortListening ([int]$c.portBusy))) { $problem = "nothing is listening on port $($c.portBusy)" }
        } elseif ($c.command) {
            $out = Invoke-CheckCommand $run $c.command
            if ($null -eq $out) { $problem = "'$($c.command)' did not finish in 15 seconds" }
            elseif ($c.match) { if ($out.Output -notmatch $c.match) { $problem = "'$($c.command)' printed '$($out.Output.Trim())', expected to match '$($c.match)'" } }
            elseif ($out.ExitCode -ne 0) { $problem = "'$($c.command)' failed (exit $($out.ExitCode)): $($out.Output.Trim())" }
        }
        if ($problem) {
            $msg = "Check '$label': $problem." + $(if ($c.fix) { " Fix: $(Expand-RecipeText $c.fix $run.Ctx)" } else { '' })
            if ($c.warn) { Write-EngineLog $run "warning: $msg"; [void]$run.Warnings.Add($msg) }
            else { return $msg }
        } else { Write-EngineLog $run "ok: $label" }
    }
    return $null
}

# Runs a short command synchronously (checks and command-based readiness). Returns $null on timeout.
function Invoke-CheckCommand($run, [string]$command, [int]$timeoutMs = 15000, [string]$cwd = '', $vars = $null) {
    $command = Expand-RecipeText $command $run.Ctx
    $psi = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $env:WINDIR 'System32\cmd.exe'), "/d /s /c `"($command) 2>&1`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = if ($cwd) { Resolve-RecipePath $cwd $run.Ctx } else { $run.Ctx.Root }
    if ($run.PathPrefix) { $psi.EnvironmentVariables['PATH'] = $run.PathPrefix + ';' + $psi.EnvironmentVariables['PATH'] }
    if ($null -eq $vars) { $vars = Get-CommandEnv $run $null }
    foreach ($n in $vars.Keys) { $psi.EnvironmentVariables[$n] = [string]$vars[$n] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $task = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMs)) { Stop-ProcessTree $p; return $null }
    return @{ Output = $task.Result; ExitCode = $p.ExitCode }
}

function Test-ServiceReady($run, $svc) {
    $ready = $svc.Def.ready
    $elapsed = ((Get-Date) - $svc.StartedAt).TotalSeconds
    if (-not $ready) {
        if ($svc.Port) { return (Test-PortListening $svc.Port) }
        return $true
    }
    if ($ready.delay) { return $elapsed -ge [double]$ready.delay }
    if ($ready.port) { return (Test-PortListening ([int]$ready.port)) }
    if ($ready.url) {
        $url = Expand-RecipeText $ready.url $run.Ctx
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.AllowAutoRedirect = $false
            $req.Timeout = 1500
            $req.ServerCertificateValidationCallback = { $true }
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close() } else { return $false }
        } catch { return $false }
        if ($ready.status) { return @($ready.status) -contains $code }
        return $code -lt 400
    }
    if ($ready.log) {
        return (Get-LogTail $svc.LogFile 200) -match $ready.log
    }
    if ($ready.command) {
        if ($svc.LastProbe -and ((Get-Date) - $svc.LastProbe).TotalSeconds -lt 2) { return $false }
        $svc.LastProbe = Get-Date
        $out = Invoke-CheckCommand $run $ready.command 5000
        if ($null -eq $out) { return $false }
        if ($ready.match) { return $out.Output -match $ready.match }
        return $out.ExitCode -eq 0
    }
    return $true
}

function Get-SafeName([string]$name) { return ($name -replace '[^A-Za-z0-9_.-]', '_') }

# Advances a run by one step. Returns an event for the UI ($null, or @{ Type; Text }).
function Invoke-RunTick($run) {
    if (-not $run) { return $null }
    switch ($run.Phase) {
        'checks' {
            $problem = Invoke-Checks $run
            if ($problem) { Set-RunFailed $run $problem $run.EngineLog; return @{ Type = 'failed'; Text = $run.Error } }
            $run.Steps = @(@($run.Recipe.setup) | Where-Object { $_ -and (Test-When $_.when $run.Ctx) })
            $run.StepIndex = 0
            $run.Phase = 'setup'
            $run.Status = 'Preparing...'
            return $null
        }
        'setup' {
            if ($run.Current) {
                $step = $run.Steps[$run.StepIndex]
                $label = if ($step.name) { $step.name } else { $step.run }
                if ($run.Current.HasExited) {
                    $run.Current.WaitForExit()
                    $code = $run.Current.ExitCode
                    $run.Current = $null
                    if ($code -ne 0) {
                        Set-RunFailed $run "Setup step '$label' failed (exit code $code)." $run.CurrentLog
                        return @{ Type = 'failed'; Text = $run.Error }
                    }
                    Write-EngineLog $run "done: $label"
                    $run.StepIndex++
                } else {
                    $limit = if ($step.timeout) { [double]$step.timeout } else { 900 }
                    $secs = [int]((Get-Date) - $run.CurrentStart).TotalSeconds
                    if ($secs -gt $limit) {
                        Set-RunFailed $run "Setup step '$label' did not finish in $limit seconds." $run.CurrentLog
                        return @{ Type = 'failed'; Text = $run.Error }
                    }
                    $run.Status = "Setting up: $label ($secs s)"
                }
                return $null
            }
            if ($run.StepIndex -lt $run.Steps.Count) {
                $step = $run.Steps[$run.StepIndex]
                $label = if ($step.name) { $step.name } else { $step.run }
                $log = Join-Path $run.LogDir ("setup-{0:D2}-{1}.log" -f ($run.StepIndex + 1), (Get-SafeName $label))
                try {
                    $run.Current = Start-RecipeProcess $run $step.run $step.cwd (Get-CommandEnv $run $step.env) $log $step.shell
                } catch {
                    Set-RunFailed $run "Setup step '$label' could not start: $($_.Exception.Message)" $log
                    return @{ Type = 'failed'; Text = $run.Error }
                }
                $run.CurrentLog = $log
                $run.CurrentStart = Get-Date
                $run.Status = "Setting up: $label"
                Write-EngineLog $run "setup: $label"
                return $null
            }
            foreach ($def in @($run.Recipe.services)) {
                if (-not (Test-When $def.when $run.Ctx)) { Write-EngineLog $run "skipped: $($def.name) (condition not met)"; continue }
                $port = if ($def.port) { [int]$def.port } elseif ($def.ready -and $def.ready.port) { [int]$def.ready.port } else { 0 }
                [void]$run.Services.Add([pscustomobject]@{
                    Name = [string]$def.name; Def = $def; Port = $port; Proc = $null; External = $false
                    Started = $false; Ready = $false; StartedAt = $null; LogFile = (Join-Path $run.LogDir ((Get-SafeName $def.name) + '.log'))
                    LastProbe = $null; Exited = $false; IsTask = $false
                })
            }
            if ($run.Services.Count -eq 0) { Set-RunFailed $run 'No service applies (every service has a condition that is not met).' $run.EngineLog; return @{ Type = 'failed'; Text = $run.Error } }
            $run.ServiceIndex = 0
            $run.Phase = 'services'
            return $null
        }
        'services' {
            $svc = $run.Services[$run.ServiceIndex]
            if (-not $svc.Started) {
                if ($svc.Def.shared -and $svc.Port -and (Test-PortListening $svc.Port)) {
                    $svc.External = $true; $svc.Started = $true; $svc.Ready = $true; $svc.StartedAt = Get-Date
                    Write-EngineLog $run "$($svc.Name): already running on port $($svc.Port) - left alone"
                } else {
                    if ($svc.Port -and (Test-PortListening $svc.Port)) {
                        Set-RunFailed $run "Port $($svc.Port) for '$($svc.Name)' is already in use by another program." $run.EngineLog
                        return @{ Type = 'failed'; Text = $run.Error }
                    }
                    try {
                        $svc.Proc = Start-RecipeProcess $run $svc.Def.run $svc.Def.cwd (Get-CommandEnv $run $svc.Def.env) $svc.LogFile $svc.Def.shell
                    } catch {
                        Set-RunFailed $run "'$($svc.Name)' could not start: $($_.Exception.Message)" $svc.LogFile
                        return @{ Type = 'failed'; Text = $run.Error }
                    }
                    $svc.Started = $true
                    $svc.StartedAt = Get-Date
                    Write-EngineLog $run "start: $($svc.Name)"
                }
                $run.Status = "Starting $($svc.Name)..."
            }
            # A task ("ready": { "exit": true }) is a one-off that runs after the services before it,
            # e.g. migrations once the database is up. It is ready when it exits with code 0.
            if (-not $svc.Ready -and $svc.Def.ready -and $svc.Def.ready.exit -and -not $svc.External) {
                if (-not $svc.Proc.HasExited) {
                    $limit = if ($svc.Def.ready.timeout) { [double]$svc.Def.ready.timeout } else { 900 }
                    $secs = [int]((Get-Date) - $svc.StartedAt).TotalSeconds
                    if ($secs -gt $limit) {
                        Set-RunFailed $run "Task '$($svc.Name)' did not finish in $limit seconds." $svc.LogFile
                        return @{ Type = 'failed'; Text = $run.Error }
                    }
                    $run.Status = "Running task: $($svc.Name) ($secs s)"
                    return $null
                }
                $svc.Proc.WaitForExit()
                if ($svc.Proc.ExitCode -ne 0) {
                    Set-RunFailed $run "Task '$($svc.Name)' failed (exit code $($svc.Proc.ExitCode))." $svc.LogFile
                    return @{ Type = 'failed'; Text = $run.Error }
                }
                $svc.IsTask = $true
                $svc.Ready = $true
                Write-EngineLog $run "done: $($svc.Name)"
            }
            if (-not $svc.Ready) {
                if (Test-ServiceReady $run $svc) {
                    $svc.Ready = $true
                    Write-EngineLog $run "ready: $($svc.Name) ($([int]((Get-Date) - $svc.StartedAt).TotalSeconds) s)"
                } else {
                    if ($svc.Proc -and $svc.Proc.HasExited) {
                        Set-RunFailed $run "'$($svc.Name)' stopped before it was ready (exit code $($svc.Proc.ExitCode))." $svc.LogFile
                        return @{ Type = 'failed'; Text = $run.Error }
                    }
                    $limit = if ($svc.Def.ready -and $svc.Def.ready.timeout) { [double]$svc.Def.ready.timeout } else { 60 }
                    $secs = [int]((Get-Date) - $svc.StartedAt).TotalSeconds
                    if ($secs -gt $limit) {
                        Set-RunFailed $run "'$($svc.Name)' was not ready after $limit seconds." $svc.LogFile
                        return @{ Type = 'failed'; Text = $run.Error }
                    }
                    $run.Status = "Waiting for $($svc.Name) ($secs s)"
                    return $null
                }
            }
            $run.ServiceIndex++
            if ($run.ServiceIndex -lt $run.Services.Count) { return $null }

            $run.Phase = 'running'
            $own = @($run.Services | Where-Object { -not $_.External }).Count
            $run.Status = "Running  -  $($run.Services.Count) service$(if ($run.Services.Count -ne 1) { 's' })"
            Write-EngineLog $run "all ready ($own started, $($run.Services.Count - $own) already running)"
            foreach ($o in @($run.Recipe.open) + @($(if ($run.ProfileDef) { $run.ProfileDef.open }))) {
                if (-not $o) { continue }
                $url = if ($o -is [string]) { $o } else { if (-not (Test-When $o.when $run.Ctx)) { continue }; $o.url }
                $run.Opened += (Expand-RecipeText $url $run.Ctx)
            }
            $msg = if ($run.ProfileDef -and $run.ProfileDef.message) { $run.ProfileDef.message } else { $run.Recipe.message }
            if ($msg) { $run.Message = Expand-RecipeText $msg $run.Ctx }
            return @{ Type = 'ready'; Text = $run.Status }
        }
        'running' {
            foreach ($svc in $run.Services) {
                if ($svc.External -or $svc.Exited -or $svc.IsTask -or -not $svc.Proc) { continue }
                if ($svc.Proc.HasExited) {
                    $svc.Exited = $true
                    Write-EngineLog $run "exited: $($svc.Name) (exit code $($svc.Proc.ExitCode))"
                    $down = @($run.Services | Where-Object { $_.Exited }).Count
                    $run.Status = "Running  -  $down of $($run.Services.Count) stopped"
                    if ($down -eq @($run.Services | Where-Object { -not $_.External -and -not $_.IsTask }).Count) {
                        $run.Phase = 'stopped'
                        $run.Status = 'Stopped (all services exited)'
                    }
                    return @{ Type = 'exited'; Text = "'$($svc.Name)' stopped"; Log = $svc.LogFile }
                }
            }
            return $null
        }
    }
    return $null
}
