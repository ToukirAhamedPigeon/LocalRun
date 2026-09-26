# LocalRun command converter.
# Turns a command file (.bat / .cmd / .ps1) or commands pasted from terminals into a recipe draft
# for <app>/local-run/startapp.json. It only READS the commands, it never runs them.
#
# What it understands: cd / pushd / popd, set and $env: variables, PATH changes, virtualenv
# activation, start / Start-Process / wt windows, timeouts, simple "if exist" guards, && chains,
# npx concurrently, terminal prompts in pasted text, and the usual dev servers, installers,
# databases and tools of each stack. Everything it guesses or cannot convert is reported in
# Notes, so the draft can be checked before it is saved.
#
# Entry point: Convert-CommandsToRecipe -Text <commands> -Kind paste|bat|ps1 -Root <app folder>

# ---------------------------------------------------------------- small helpers
function ConvertTo-RecipeJson($value, [int]$indent = 0) {
    $pad = ' ' * $indent
    $inner = ' ' * ($indent + 2)
    if ($null -eq $value) { return 'null' }
    if ($value -is [bool]) { return $(if ($value) { 'true' } else { 'false' }) }
    if ($value -is [int] -or $value -is [long] -or $value -is [double]) { return ([string]$value) }
    if ($value -is [string]) {
        $s = $value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return '"' + $s + '"'
    }
    if ($value -is [System.Collections.IDictionary]) {
        if ($value.Count -eq 0) { return '{}' }
        $parts = foreach ($k in $value.Keys) { $inner + (ConvertTo-RecipeJson ([string]$k)) + ': ' + (ConvertTo-RecipeJson $value[$k] ($indent + 2)) }
        return "{`r`n" + ($parts -join ",`r`n") + "`r`n$pad}"
    }
    if ($value -is [System.Collections.IEnumerable]) {
        $items = @($value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($i in $items) { $inner + (ConvertTo-RecipeJson $i ($indent + 2)) }
        return "[`r`n" + ($parts -join ",`r`n") + "`r`n$pad]"
    }
    return (ConvertTo-RecipeJson ([string]$value) $indent)
}

function Get-Unquoted([string]$s) {
    $s = $s.Trim()
    if ($s.Length -ge 2 -and (($s[0] -eq '"' -and $s[-1] -eq '"') -or ($s[0] -eq "'" -and $s[-1] -eq "'"))) { return $s.Substring(1, $s.Length - 2) }
    return $s
}

# Splits on whitespace outside quotes and brackets; tokens keep their quotes.
function Split-ConvArgs([string]$s) {
    $tokens = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder
    $quote = [char]0
    $depth = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($quote -ne [char]0) {
            [void]$sb.Append($ch)
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; [void]$sb.Append($ch); continue }
        if ($ch -eq '(' -or $ch -eq '{') { $depth++ }
        if (($ch -eq ')' -or $ch -eq '}') -and $depth -gt 0) { $depth-- }
        if ([char]::IsWhiteSpace($ch) -and $depth -eq 0) {
            if ($sb.Length -gt 0) { [void]$tokens.Add($sb.ToString()); [void]$sb.Clear() }
            continue
        }
        [void]$sb.Append($ch)
    }
    if ($sb.Length -gt 0) { [void]$tokens.Add($sb.ToString()) }
    return $tokens.ToArray()
}

# Splits a line on a separator (&&, &, ;, ||) outside quotes and brackets.
function Split-ConvChain([string]$s, [string[]]$separators) {
    $parts = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder
    $quote = [char]0
    $depth = 0
    $i = 0
    while ($i -lt $s.Length) {
        $ch = $s[$i]
        if ($quote -ne [char]0) {
            [void]$sb.Append($ch)
            if ($ch -eq $quote) { $quote = [char]0 }
            $i++; continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; [void]$sb.Append($ch); $i++; continue }
        if ($ch -eq '(' -or $ch -eq '{') { $depth++ }
        if (($ch -eq ')' -or $ch -eq '}') -and $depth -gt 0) { $depth-- }
        $hit = $null
        if ($depth -eq 0) {
            foreach ($sep in $separators) {
                if ($i + $sep.Length -le $s.Length -and $s.Substring($i, $sep.Length) -eq $sep) {
                    # a single & must not be the first half of && or part of 2>&1
                    if ($sep -eq '&' -and (($i + 1 -lt $s.Length -and $s[$i + 1] -eq '&') -or ($i -gt 0 -and ($s[$i - 1] -eq '>' -or $s[$i - 1] -eq '&')))) { continue }
                    if ($sep -eq '|' -and (($i + 1 -lt $s.Length -and $s[$i + 1] -eq '|') -or ($i -gt 0 -and $s[$i - 1] -eq '|'))) { continue }
                    $hit = $sep; break
                }
            }
        }
        if ($hit) {
            [void]$parts.Add($sb.ToString().Trim()); [void]$sb.Clear()
            $i += $hit.Length; continue
        }
        [void]$sb.Append($ch)
        $i++
    }
    [void]$parts.Add($sb.ToString().Trim())
    return @($parts | Where-Object { $_ })
}

# Brace balance outside quotes, for PowerShell blocks.
function Get-BraceDelta([string]$s) {
    $d = 0
    $quote = [char]0
    foreach ($ch in $s.ToCharArray()) {
        if ($quote -ne [char]0) { if ($ch -eq $quote) { $quote = [char]0 }; continue }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq '#') { break }
        if ($ch -eq '{') { $d++ } elseif ($ch -eq '}') { $d-- }
    }
    return $d
}

function Get-ParenDelta([string]$s) {
    $d = 0
    $quote = [char]0
    foreach ($ch in $s.ToCharArray()) {
        if ($quote -ne [char]0) { if ($ch -eq $quote) { $quote = [char]0 }; continue }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq '#') { break }
        if ($ch -eq '(') { $d++ } elseif ($ch -eq ')') { $d-- }
    }
    return $d
}

# A path as a recipe writes it: relative to the app folder when inside it (or a sibling of it),
# forward slashes always.
function ConvertTo-RecipeRel([string]$abs, [string]$root) {
    if (-not $abs) { return '' }
    try { $full = [System.IO.Path]::GetFullPath($abs) } catch { return $abs.Replace('\', '/') }
    $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
    if ($full.TrimEnd('\') -ieq $r) { return '' }
    if ($full.StartsWith("$r\", [System.StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($r.Length + 1).TrimEnd('\').Replace('\', '/') }
    $parent = Split-Path -Parent $r
    if ($parent -and $full.StartsWith("$($parent.TrimEnd('\'))\", [System.StringComparison]::OrdinalIgnoreCase)) {
        return '../' + $full.Substring($parent.TrimEnd('\').Length + 1).TrimEnd('\').Replace('\', '/')
    }
    return $full.TrimEnd('\').Replace('\', '/')
}

# A path inside a when/exists condition: relative to the app folder, joined with the item's folder.
function Join-RecipeRel([string]$cwdRel, [string]$path) {
    if (-not $cwdRel) { return $path }
    return "$cwdRel/$path"
}

function Resolve-ConvDir($st, [string]$path) {
    $p = Get-Unquoted $path
    if (-not $p) { return $st.Cwd }
    if ($st.Kind -ne 'bat' -and $p -match '^[($]') { $v = Resolve-PsValue $st $p; if ($v) { $p = $v } }
    $p = Expand-ConvVars $st $p
    if ($p -match '^[A-Za-z]:$') { return "$p\" }
    try {
        if ([System.IO.Path]::IsPathRooted($p)) { return [System.IO.Path]::GetFullPath($p) }
        return [System.IO.Path]::GetFullPath((Join-Path $st.Cwd $p))
    } catch { return $st.Cwd }
}

# Replaces the variables the converter knows: %VAR%, %~dp0, %CD% for cmd; $var, $env:VAR,
# $PSScriptRoot and simple Join-Path for PowerShell.
function Expand-ConvVars($st, [string]$s) {
    if (-not $s) { return $s }
    $s = $s -replace '%~dp0\\?', ($st.ScriptDir.TrimEnd('\') + '\').Replace('$', '$$')
    $s = $s -replace '(?i)%CD%', $st.Cwd.Replace('$', '$$')
    foreach ($k in @($st.Vars.Keys)) {
        $v = [string]$st.Vars[$k]
        $s = [regex]::Replace($s, '(?i)%' + [regex]::Escape($k) + '%', { param($m) $v })
    }
    if ($st.Kind -eq 'ps1' -or $st.Kind -eq 'paste') {
        $s = [regex]::Replace($s, '(?i)\$\((Join-Path\s+[^)]*)\)', { param($m) $r = Resolve-PsValue $st $m.Groups[1].Value; if ($null -ne $r) { $r } else { $m.Value } })
        $s = [regex]::Replace($s, '(?i)\$\{?PSScriptRoot\}?', { param($m) $st.ScriptDir.TrimEnd('\') })
        $s = [regex]::Replace($s, '(?i)\$\{?env:(\w+)\}?', { param($m) $n = $m.Groups[1].Value; if ($st.Env.Contains($n)) { [string]$st.Env[$n] } else { "%$n%" } })
        $s = [regex]::Replace($s, '(?i)\$\{?(\w+)\}?', { param($m) $n = $m.Groups[1].Value; if ($st.Vars.ContainsKey($n)) { [string]$st.Vars[$n] } else { $m.Value } })
    }
    return $s
}

# The value of a simple PowerShell expression: a string, a variable, or Join-Path. $null otherwise.
function Resolve-PsValue($st, [string]$expr) {
    $e = $expr.Trim()
    while ($e.StartsWith('(') -and $e.EndsWith(')') -and (Get-ParenDelta $e.Substring(1, $e.Length - 2)) -eq 0) { $e = $e.Substring(1, $e.Length - 2).Trim() }
    if ($e -match "^'([^']*)'$") { return $Matches[1] }
    if ($e -match '^"([^"]*)"$') {
        $v = Expand-ConvVars $st $Matches[1]
        if ($v -match '\$') { return $null }
        return $v
    }
    if ($e -match '(?i)^\$\{?PSScriptRoot\}?$') { return $st.ScriptDir.TrimEnd('\') }
    if ($e -match '(?i)^\$\{?env:(\w+)\}?$') { if ($st.Env.Contains($Matches[1])) { return [string]$st.Env[$Matches[1]] }; return $null }
    if ($e -match '^\$(\w+)$') { if ($st.Vars.ContainsKey($Matches[1])) { return [string]$st.Vars[$Matches[1]] }; return $null }
    if ($e -match '(?i)^Join-Path\s+(.+)$') {
        $args2 = @(Split-ConvArgs $Matches[1] | Where-Object { $_ -notmatch '^-(Path|ChildPath)$' })
        if ($args2.Count -lt 2) { return $null }
        $a = Resolve-PsValue $st $args2[0]
        $b = Resolve-PsValue $st $args2[1]
        if ($null -eq $a -or $null -eq $b) { return $null }
        return (Join-Path $a $b)
    }
    if ($e -match '(?i)^Split-Path\s+(-Parent\s+)?(\S+)(\s+-Parent)?$') {
        $a = Resolve-PsValue $st $Matches[2]
        if ($null -eq $a) { return $null }
        return (Split-Path -Parent $a)
    }
    if ($e -match '^[A-Za-z0-9_.:\\/-]+$' -and $e -notmatch '^-') { return $e }
    return $null
}

function Add-ConvNote($st, [string]$text) {
    if (-not $st.Notes.Contains($text)) { [void]$st.Notes.Add($text) }
}

# ---------------------------------------------------------------- what a command is
function Read-ConvJsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return ConvertFrom-Json ([System.IO.File]::ReadAllText($path)) } catch { return $null }
}

function Get-DotEnvPort([string]$dir) {
    foreach ($name in '.env', '.env.local', '.env.development', '.env.example') {
        $f = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            if ($line -match '^\s*(PORT|APP_PORT|SERVER_PORT|API_PORT)\s*=\s*"?(\d{2,5})"?\s*$') { return [int]$Matches[2] }
        }
    }
    return 0
}

function Get-ConfigPort([string]$dir, [string[]]$files, [string]$pattern) {
    foreach ($name in $files) {
        $f = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        $m = [regex]::Match([System.IO.File]::ReadAllText($f), $pattern)
        if ($m.Success) { foreach ($g in @($m.Groups)[1..($m.Groups.Count - 1)]) { if ($g.Success -and $g.Value) { return [int]$g.Value } } }
    }
    return 0
}

function Get-LaunchSettingsPort([string]$dir) {
    $js = Read-ConvJsonFile (Join-Path $dir 'Properties\launchSettings.json')
    if (-not $js -or -not $js.profiles) { return 0 }
    foreach ($p in $js.profiles.PSObject.Properties) {
        $url = [string]$p.Value.applicationUrl
        foreach ($u in ($url -split ';')) { if ($u -match '^http://[^:]+:(\d+)') { return [int]$Matches[1] } }
    }
    return 0
}

# Flags that name a port, in any stack.
function Get-FlagPort([string]$c) {
    $pats = @('--port[=\s]+(\d{2,5})', '(?:^|\s)-p\s+(\d{2,5})\b', '--urls?[=\s]+"?https?://[^:\s]+:(\d{2,5})', '(?:--bind|-b)[=\s]+"?[\w.\[\]]*:(\d{2,5})',
              '--server\.port[=\s]+(\d{2,5})', '-Dserver\.port=(\d{2,5})', '--address[=\s]+"?[\w.]*:(\d{2,5})', '--listen[=\s]+"?[\w.]*:(\d{2,5})')
    foreach ($p in $pats) { if ($c -match $p) { return [int]$Matches[1] } }
    return 0
}

# Describes one command: long-running (a service) or one-off (setup), its port, label and extras.
# $pkgScript: set when classifying the body of a package.json script.
function Get-CommandInfo([string]$cmd, [string]$dir, $envSnap) {
    $script:ConvDepth++
    try {
        $info = Get-CommandInfoCore $cmd $dir $envSnap
        # a program given by its own path (a venv's python.exe) needs no check for a tool on PATH
        if ($cmd -match '^"?(\$\{ROOT\}|[A-Za-z]:)[\\/]') { $info.Tool = '' }
        return $info
    } finally { $script:ConvDepth-- }
}
$script:ConvDepth = 0

function Get-CommandInfoCore([string]$cmd, [string]$dir, $envSnap) {
    $info = @{ Long = $false; Label = ''; Port = 0; Web = $false; Shared = $false; Stop = ''; Ready = $null
               Guard = $null; Tool = ''; Note = ''; Task = $false; Known = $true }
    $tokens = @(Split-ConvArgs $cmd)
    if ($tokens.Count -eq 0 -or $script:ConvDepth -gt 6) { $info.Known = $false; return $info }
    $first = Get-Unquoted $tokens[0]
    $head = ([System.IO.Path]::GetFileName($first) -replace '(?i)\.(exe|cmd|bat|ps1)$', '').ToLower()
    $rest = if ($tokens.Count -gt 1) { ($tokens[1..($tokens.Count - 1)] -join ' ') } else { '' }
    $norm = "$head $rest".Trim()
    $info.Tool = if ([System.IO.Path]::IsPathRooted($first) -or $first -match '[\\/]') { '' } else { $head }
    $envPort = 0
    if ($envSnap -and $envSnap.Contains('PORT') -and [string]$envSnap['PORT'] -match '^\d+$') { $envPort = [int]$envSnap['PORT'] }

    # npx / bunx / pnpm dlx: classify the tool it runs
    if ($norm -match '^(npx|bunx)\s+(?:-y\s+|--yes\s+)?(.+)$' -or $norm -match '^pnpm\s+(dlx|exec)\s+(.+)$') {
        $inner = Get-CommandInfo $Matches[2] $dir $envSnap
        $inner.Tool = 'node'
        return $inner
    }

    # package managers
    if ($norm -match '^(npm|pnpm|yarn|bun)(\s+(.*))?$') {
        $mgr = $Matches[1]
        $args0 = [string]$Matches[3]
        $info.Tool = 'node'
        $lockGuard = switch ($mgr) {
            'yarn' { @('yarn.lock', 'node_modules/.yarn-integrity') }
            'pnpm' { @('pnpm-lock.yaml', 'node_modules/.modules.yaml') }
            'bun'  { @('bun.lockb', 'node_modules') }
            default { @('package-lock.json', 'node_modules/.package-lock.json') }
        }
        if ($args0 -eq '' -and $mgr -eq 'yarn' -or $args0 -match '^(install|i|ci)(\s|$)') {
            $info.Label = "$mgr install"
            $info.Guard = @{ missing = 'node_modules'; newer = $lockGuard }
            return $info
        }
        if ($args0 -match '^(add|remove|uninstall|update|up|audit|outdated|link|config|init|create|publish|version|exec|dlx|cache|prune)(\s|$)') { $info.Label = $args0; return $info }
        $script0 = ''
        if ($args0 -match '^run(-script)?\s+([^\s]+)') { $script0 = $Matches[2] }
        elseif ($args0 -match '^(start|test)(\s|$)') { $script0 = $Matches[1] }
        elseif ($mgr -ne 'npm' -and $args0 -match '^([^\s-][^\s]*)') { $script0 = $Matches[1] }
        if (-not $script0) { $info.Known = $false; return $info }
        $info.Label = $script0
        $pkg = Read-ConvJsonFile (Join-Path $dir 'package.json')
        $body = if ($pkg -and $pkg.scripts) { [string]$pkg.scripts.$script0 } else { '' }
        $flag = Get-FlagPort $args0
        if ($body) {
            # the script's own command decides, e.g. "vite" is a server, "mix" / "vite build" are one-off
            $sub = $null
            foreach ($seg in (Split-ConvChain $body @('&&', '&', ';'))) {
                $seg2 = $seg -replace '^(cross-env\s+(\w+=\S+\s+)+|(\w+=\S+\s+)+)', ''
                $si = Get-CommandInfo $seg2 $dir $envSnap
                if ($si.Long) { $sub = $si }
            }
            if ($sub) {
                $info.Long = $true; $info.Web = $sub.Web; $info.Ready = $sub.Ready; if ($sub.Label -and $sub.Label -notin @("node", "concurrently")) { $info.Label = $sub.Label }
                $info.Port = if ($flag) { $flag } elseif ($sub.Port) { $sub.Port } else { 0 }
                if ($body -match '\bconcurrently\b|\brun-p\b|\bnpm-run-all\b') { $info.Note = "'$mgr run $script0' starts several processes at once; LocalRun waits for the port given here only" }
                return $info
            }
            if ($body -match '(?i)\b(watch|serve|dev-server|--watch|-w)\b' -and $body -notmatch '(?i)\bbuild\b') { $info.Long = $true; $info.Port = $flag; return $info }
            return $info   # a build / test / lint style script: one-off
        }
        if ($script0 -match '^(dev|start|serve|watch|preview|develop)([:-].*)?$|^start:dev$') {
            $info.Long = $true
            $info.Port = if ($flag) { $flag } else { Get-DotEnvPort $dir }
            $info.Note = "package.json has no '$script0' script here, so its port is a guess"
        }
        return $info
    }

    switch -regex ($norm) {
        '^vite\s+(build|optimize)' { return $info }
        '^vite(\s+(dev|serve|preview))?(\s|$)' {
            $info.Long = $true; $info.Web = $true; $info.Label = 'vite'; $info.Tool = 'node'
            $def = if ($norm -match '\spreview') { 4173 } else { 5173 }
            $cfg = Get-ConfigPort $dir @('vite.config.ts', 'vite.config.js', 'vite.config.mjs', 'vite.config.mts') 'port\s*:\s*(\d{2,5})'
            $info.Port = if (Get-FlagPort $norm) { Get-FlagPort $norm } elseif ($cfg) { $cfg } else { $def }
            return $info
        }
        '^next\s+(dev|start)' { $info.Long = $true; $info.Web = $true; $info.Label = 'next'; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } elseif ($envPort) { $envPort } else { 3000 }); return $info }
        '^react-scripts\s+start' { $info.Long = $true; $info.Web = $true; $info.Label = 'react'; $info.Tool = 'node'; $info.Port = $(if ($envPort) { $envPort } else { 3000 }); return $info }
        '^ng\s+serve' { $info.Long = $true; $info.Web = $true; $info.Label = 'angular'; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 4200 }); $info.Ready = [ordered]@{ port = $info.Port; timeout = 180 }; return $info }
        '^nuxi?\s+(dev|start|preview)' { $info.Long = $true; $info.Web = $true; $info.Label = 'nuxt'; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 3000 }); return $info }
        '^astro\s+(dev|preview)' { $info.Long = $true; $info.Web = $true; $info.Label = 'astro'; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 4321 }); return $info }
        '^(svelte-kit|remix|gatsby)\s+(dev|develop)' { $info.Long = $true; $info.Web = $true; $info.Label = $Matches[1]; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } elseif ($Matches[1] -eq 'gatsby') { 8000 } else { 5173 }); return $info }
        '^vue-cli-service\s+serve|^webpack(-dev-server|\s+serve)' { $info.Long = $true; $info.Web = $true; $info.Label = 'webpack'; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8080 }); return $info }
        '^(mix|webpack|tsc|eslint|prettier|jest|vitest|prisma|sequelize|typeorm|knex|drizzle-kit)(\s|$)' {
            if ($norm -match '(\s--watch|\s-w\b|^mix\s+watch)') { $info.Long = $true; $info.Label = $Matches[1]; return $info }
            $info.Label = $Matches[1]; $info.Tool = 'node'; return $info
        }
        '^nest\s+start' { $info.Long = $true; $info.Label = 'api'; $info.Tool = 'node'; $p = Get-DotEnvPort $dir; $info.Port = $(if ($envPort) { $envPort } elseif ($p) { $p } else { 3000 }); if (-not $p -and -not $envPort) { $info.Note = 'NestJS port 3000 is a guess (no PORT in .env)' }; return $info }
        '^(nodemon|ts-node-dev|ts-node|tsx|node)(\s|$)' {
            if ($norm -match '^node\s+(-v|--version|-e|-p)\b' -or $norm -match '^(node|ts-node|tsx)\s+\S*(seed|migrat|script)') { $info.Tool = 'node'; return $info }
            if ($norm -match '^(node|tsx)\s*$') { $info.Known = $false; return $info }
            $info.Long = $true; $info.Label = 'node'; $info.Tool = 'node'
            $p = Get-DotEnvPort $dir
            $info.Port = if (Get-FlagPort $norm) { Get-FlagPort $norm } elseif ($envPort) { $envPort } else { $p }
            if (-not $info.Port) { $info.Note = "no port found for '$norm'" }
            return $info
        }
        '^json-server\s' { $info.Long = $true; $info.Label = 'json-server'; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 3000 }); return $info }
        '^(http-server|live-server|serve)(\s|$)' { $info.Long = $true; $info.Web = $true; $info.Label = $Matches[1]; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } elseif ($Matches[1] -eq 'serve') { 3000 } else { 8080 }); return $info }
        '^concurrently\s' { $info.Long = $true; $info.Label = 'concurrently'; $info.Tool = 'node'; return $info }
        '^expo\s+start' { $info.Long = $true; $info.Label = 'expo'; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8081 }); return $info }
        '^react-native\s+start' { $info.Long = $true; $info.Label = 'metro'; $info.Tool = 'node'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8081 }); return $info }
        '^react-native\s+run-' { $info.Label = 'install app'; $info.Tool = 'node'; $info.Task = $true; return $info }
        '^flutter\s+run' { $info.Long = $true; $info.Label = 'flutter'; $info.Tool = 'flutter'; $info.Ready = [ordered]@{ log = 'Flutter run key commands|is available at|Syncing files'; timeout = 600 }; return $info }
        '^flutter\s+pub\s+get' { $info.Label = 'flutter pub get'; $info.Tool = 'flutter'; $info.Guard = @{ missing = '.dart_tool'; newer = @('pubspec.lock', '.dart_tool/package_config.json') }; return $info }
        '^emulator\s.*-avd' { $info.Long = $true; $info.Label = 'emulator'; $info.Ready = [ordered]@{ command = 'adb shell getprop sys.boot_completed'; match = '1'; timeout = 240 }; return $info }

        '^php\s+artisan\s+serve' {
            $info.Long = $true; $info.Web = $true; $info.Label = 'laravel'; $info.Tool = 'php'
            $info.Port = if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8000 }
            return $info
        }
        '^php\s+artisan\s+(queue:work|queue:listen|schedule:work|horizon|pulse:check)' { $info.Long = $true; $info.Label = ($Matches[1] -replace ':.*', ''); $info.Tool = 'php'; return $info }
        '^php\s+artisan\s+(reverb:start|websockets:serve|octane:start)' { $info.Long = $true; $info.Label = ($Matches[1] -replace ':.*', ''); $info.Tool = 'php'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } elseif ($Matches[1] -eq 'octane:start') { 8000 } elseif ($Matches[1] -eq 'reverb:start') { 8080 } else { 6001 }); return $info }
        '^php\s+artisan\s+storage:link' { $info.Label = 'storage link'; $info.Tool = 'php'; $info.Guard = @{ missingOnly = 'public/storage' }; return $info }
        '^php\s+artisan\s+key:generate' { $info.Label = 'app key'; $info.Tool = 'php'; $info.Note = "'php artisan key:generate' runs only when .env is new, so an existing key is never replaced"; $info.Guard = @{ missingOnly = '.env' }; return $info }
        '^php\s+artisan\s+(\S+)' { $info.Label = "artisan $($Matches[1])"; $info.Tool = 'php'; return $info }
        '^php\s+-S\s+"?([\w.]*):(\d+)' { $info.Long = $true; $info.Web = $true; $info.Label = 'php'; $info.Tool = 'php'; $info.Port = [int]$Matches[2]; return $info }
        '^composer\s+(install|i)(\s|$)' { $info.Label = 'composer install'; $info.Tool = 'composer'; $info.Guard = @{ missing = 'vendor/autoload.php'; newer = @('composer.lock', 'vendor/composer/installed.json') }; return $info }
        '^composer\s+(\S+)' { $info.Label = "composer $($Matches[1])"; $info.Tool = 'composer'; return $info }

        '^(python3?|py)(\s+-3(\.\d+)?)?\s+-m\s+(.+)$' {
            $mod = $Matches[4]
            if ($mod -match '^venv\s+(\S+)') { $info.Label = 'virtualenv'; $info.Tool = 'python'; $info.Guard = @{ missingOnly = (Get-Unquoted $Matches[1]) }; return $info }
            if ($mod -match '^pip\s') { $info.Label = 'pip install'; $info.Tool = 'python'; return $info }
            if ($mod -match '^http\.server(\s+(\d+))?') { $info.Long = $true; $info.Web = $true; $info.Label = 'http'; $info.Tool = 'python'; $info.Port = $(if ($Matches[2]) { [int]$Matches[2] } else { 8000 }); return $info }
            $inner = Get-CommandInfo $mod $dir $envSnap
            $inner.Tool = 'python'
            # python -m <the project's own module>: a one-off
            if (-not $inner.Known) { $inner.Known = $true; $inner.Label = ($mod -split '\s+')[0] }
            return $inner
        }
        '^(python3?|py)(\s+-3(\.\d+)?)?\s+manage\.py\s+runserver(\s+(\S+))?' {
            $info.Long = $true; $info.Web = $true; $info.Label = 'django'; $info.Tool = 'python'; $info.Port = 8000
            if ($Matches[5] -match '(\d{2,5})$') { $info.Port = [int]$Matches[1] }
            return $info
        }
        '^(python3?|py)(\s+-3(\.\d+)?)?\s+manage\.py\s+(\S+)' { $info.Label = "manage.py $($Matches[4])"; $info.Tool = 'python'; return $info }
        '^uvicorn\s' { $info.Long = $true; $info.Label = 'api'; $info.Tool = 'python'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8000 }); return $info }
        '^fastapi\s+(dev|run)' { $info.Long = $true; $info.Label = 'api'; $info.Tool = 'python'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8000 }); return $info }
        '^(gunicorn|hypercorn|daphne|waitress-serve)\s' { $info.Long = $true; $info.Label = 'api'; $info.Tool = 'python'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8000 }); return $info }
        '^flask\s+run' { $info.Long = $true; $info.Web = $true; $info.Label = 'flask'; $info.Tool = 'python'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 5000 }); return $info }
        '^streamlit\s+run' { $info.Long = $true; $info.Web = $true; $info.Label = 'streamlit'; $info.Tool = 'python'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8501 }); return $info }
        '^celery\s' { $info.Long = $true; $info.Label = $(if ($norm -match '\bbeat\b') { 'celery beat' } else { 'worker' }); $info.Tool = 'python'; return $info }
        '^alembic\s' { $info.Label = 'alembic'; $info.Tool = 'python'; return $info }
        '^(pip3?)\s+install' { $info.Label = 'pip install'; $info.Tool = 'python'; return $info }
        '^(python3?|py)(\s+-3(\.\d+)?)?\s+"?([^\s"]+\.py)"?' {
            $file = [System.IO.Path]::GetFileName($Matches[4]).ToLower()
            $info.Tool = 'python'
            if ($file -match '^(app|main|server|run|wsgi|asgi|api|bot|worker)\.py$') {
                $info.Long = $true; $info.Label = ($file -replace '\.py$', '')
                $info.Port = if (Get-FlagPort $norm) { Get-FlagPort $norm } else { Get-DotEnvPort $dir }
                if (-not $info.Port) { $info.Note = "no port found for '$norm'" }
            } else { $info.Label = $file }
            return $info
        }

        '^dotnet\s+(watch\s+)?run' {
            $info.Long = $true; $info.Label = 'api'; $info.Tool = 'dotnet'
            $info.Port = if (Get-FlagPort $norm) { Get-FlagPort $norm } else { Get-LaunchSettingsPort $dir }
            if ($info.Port) { $info.Ready = [ordered]@{ port = $info.Port; timeout = 180 } } else { $info.Note = 'no applicationUrl in Properties/launchSettings.json; add the port' }
            return $info
        }
        '^dotnet\s+restore' { $info.Label = 'dotnet restore'; $info.Tool = 'dotnet'; $info.Guard = @{ missingOnly = 'obj' }; return $info }
        '^dotnet\s+(\S+)' { $info.Label = "dotnet $($Matches[1])"; $info.Tool = 'dotnet'; return $info }
        '^(mvn|mvnw|gradle|gradlew)\s+.*(spring-boot:run|bootRun)' {
            $info.Long = $true; $info.Label = 'api'; $info.Tool = 'java'
            $cfg = Get-ConfigPort $dir @('src\main\resources\application.properties', 'src\main\resources\application.yml', 'src\main\resources\application.yaml') 'server\.port\s*[=:]\s*(\d{2,5})|port:\s*(\d{2,5})'
            $info.Port = if (Get-FlagPort $norm) { Get-FlagPort $norm } elseif ($cfg) { $cfg } else { 8080 }
            $info.Ready = [ordered]@{ port = $info.Port; timeout = 240 }
            return $info
        }
        '^(mvn|mvnw|gradle|gradlew)\s' { $info.Label = $Matches[1]; $info.Tool = 'java'; return $info }
        '^java\s.*-jar' { $info.Long = $true; $info.Label = 'java'; $info.Tool = 'java'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 8080 }); $info.Ready = [ordered]@{ port = $info.Port; timeout = 240 }; if (-not (Get-FlagPort $norm)) { $info.Note = 'port 8080 for java -jar is a guess' }; return $info }
        '^(go\s+run|air)(\s|$)' { $info.Long = $true; $info.Label = 'go'; $info.Tool = $(if ($norm -match '^go') { 'go' } else { '' }); $info.Port = $(if ($envPort) { $envPort } else { Get-DotEnvPort $dir }); return $info }
        '^cargo\s+run' { $info.Long = $true; $info.Label = 'rust'; $info.Tool = 'cargo'; $info.Port = Get-DotEnvPort $dir; return $info }
        '^(bundle\s+exec\s+)?(rails)\s+(s|server)(\s|$)' { $info.Long = $true; $info.Web = $true; $info.Label = 'rails'; $info.Tool = 'ruby'; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 3000 }); return $info }
        '^hugo\s+serve' { $info.Long = $true; $info.Web = $true; $info.Label = 'hugo'; $info.Port = 1313; return $info }
        '^(bundle\s+exec\s+)?jekyll\s+serve' { $info.Long = $true; $info.Web = $true; $info.Label = 'jekyll'; $info.Port = 4000; return $info }

        '^(docker-compose|docker\s+compose)\s(.*\s)?up(\s|$)' {
            $info.Long = $true; $info.Label = 'docker'; $info.Tool = 'docker'
            $pre = if ($norm -match '^docker-compose') { 'docker-compose' } else { 'docker compose' }
            $files = [regex]::Matches($norm, '(-f|--file)\s+\S+') | ForEach-Object { $_.Value }
            $info.Stop = (@($pre) + @($files) + @('down')) -join ' '
            $info.Ready = [ordered]@{ log = 'Started|Running|Healthy|ready'; timeout = 300 }
            $info.Infra = $true
            if ($norm -match '\s(-d|--detach)(\s|$)') {
                $info.Rewrite = 'detach'
                $info.Note = "'docker compose up -d' returns at once, so LocalRun runs it without -d: the containers then live as long as the run, and Stop runs '$($info.Stop)'"
            }
            return $info
        }
        '^(docker-compose|docker\s+compose)\s' { $info.Label = 'docker compose'; $info.Tool = 'docker'; return $info }
        '^docker\s+run\s' {
            $info.Tool = 'docker'; $info.Label = 'container'
            if ($norm -match '\s(-d|--detach)(\s|$)') { $info.Note = "'docker run -d' starts a container that LocalRun cannot stop; drop -d to make it a service"; return $info }
            $info.Long = $true
            if ($norm -match '\s(-p|--publish)\s+"?(?:[\d.]+:)?(\d{2,5}):\d+') { $info.Port = [int]$Matches[2] }
            return $info
        }
        '^docker\s' { $info.Label = 'docker'; $info.Tool = 'docker'; return $info }

        '^mysqld(\s|$)' { $info.Long = $true; $info.Label = 'mysql'; $info.Infra = $true; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 3306 }); $info.Shared = $true; $info.Ready = [ordered]@{ port = $info.Port; timeout = 90 }; $info.Stop = 'mysqladmin --user=root --host=127.0.0.1 shutdown'; return $info }
        '^mariadbd(\s|$)' { $info.Long = $true; $info.Label = 'mariadb'; $info.Infra = $true; $info.Port = 3306; $info.Shared = $true; $info.Ready = [ordered]@{ port = 3306; timeout = 90 }; return $info }
        '^(redis-server|memurai|valkey-server)(\s|$)' { $info.Long = $true; $info.Label = 'redis'; $info.Infra = $true; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 6379 }); $info.Shared = $true; return $info }
        '^(postgres|pg_ctl)(\s|$)' {
            if ($norm -match '^pg_ctl') { $info.Label = 'postgres'; $info.Note = "'pg_ctl start' returns at once; LocalRun runs it as a setup step"; return $info }
            $info.Long = $true; $info.Label = 'postgres'; $info.Infra = $true; $info.Port = 5432; $info.Shared = $true; return $info
        }
        '^mongod(\s|$)' { $info.Long = $true; $info.Label = 'mongodb'; $info.Infra = $true; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 27017 }); $info.Shared = $true; return $info }
        '^minio\s+server' { $info.Long = $true; $info.Label = 'minio'; $info.Infra = $true; $info.Port = $(if (Get-FlagPort $norm) { Get-FlagPort $norm } else { 9000 }); return $info }
        '^(mailpit|mailhog)(\s|$)' { $info.Long = $true; $info.Label = 'mail'; $info.Infra = $true; $info.Port = 8025; return $info }
        '^httpd(\s|$)' { if ($norm -match '\s-(t|v|V|k)(\s|$)') { $info.Label = 'apache'; return $info }; $info.Long = $true; $info.Label = 'apache'; $info.Port = 80; $info.Shared = $true; return $info }
        '^nginx(\s|$)' { if ($norm -match '\s-(t|s)(\s|$)') { $info.Label = 'nginx'; return $info }; $info.Long = $true; $info.Label = 'nginx'; $info.Port = 80; return $info }
        '^caddy\s+run' { $info.Long = $true; $info.Label = 'caddy'; return $info }
        '^ngrok\s' { $info.Long = $true; $info.Label = 'tunnel'; $info.Ready = [ordered]@{ port = 4040 }; return $info }
        '^cloudflared\s+tunnel' { $info.Long = $true; $info.Label = 'tunnel'; $info.Ready = [ordered]@{ delay = 5 }; return $info }
        '^stripe\s+listen' { $info.Long = $true; $info.Label = 'stripe'; $info.Ready = [ordered]@{ log = 'Ready!'; timeout = 60 }; return $info }
        '^firebase\s+emulators:start' { $info.Long = $true; $info.Label = 'firebase'; $info.Port = 4000; $info.Tool = 'node'; return $info }
        '^(git|curl|mkdir|md|del|rd|rmdir|xcopy|robocopy|type|dir|where|ren|move|choco|winget|scoop)(\s|$)' { $info.Label = $Matches[1]; $info.Tool = ''; return $info }
        '^(copy|cp)\s+"?(\S*?)\.env\.example"?\s+"?(\S*?)\.env"?$' { $info.Label = 'create .env'; $info.Tool = ''; $info.Guard = @{ missingOnly = ($Matches[3].Replace('\', '/') + '.env') }; $info.CopyEnv = $true; return $info }
    }
    $info.Known = $false
    $info.Label = $head
    $info.Tool = ''
    return $info
}

# ---------------------------------------------------------------- reading the text
# Logical lines: continuations joined, comments and here-strings dropped.
function Get-ConvLines([string]$text, [string]$kind) {
    $raw = $text -replace "`r`n", "`n" -split "`n"
    $out = New-Object System.Collections.ArrayList
    $buf = ''
    $inBlockComment = $false
    $inHere = $false
    $paren = 0
    foreach ($l0 in $raw) {
        $l = $l0.TrimEnd()
        if ($kind -ne 'bat') {
            if ($inBlockComment) { if ($l -match '#>') { $inBlockComment = $false }; continue }
            if ($l -match '^\s*<#') { if ($l -notmatch '#>') { $inBlockComment = $true }; continue }
            if ($inHere) { if ($l -match "^['""]@") { $inHere = $false }; continue }
            if ($l -match "@['""]$") { $inHere = $true; [void]$out.Add('#here-string'); continue }
        }
        if ($kind -eq 'ps1') { $l = Remove-PsComment $l }
        if ($buf) { $l = $buf + ' ' + $l.Trim() }
        $buf = ''
        if ($kind -eq 'bat' -and $l.EndsWith('^')) { $buf = $l.Substring(0, $l.Length - 1).TrimEnd(); continue }
        if ($kind -ne 'bat') {
            if ($l.EndsWith('`')) { $buf = $l.Substring(0, $l.Length - 1).TrimEnd(); continue }
            if ($kind -eq 'ps1' -and ($l -match '(\||,|-or|-and|\(|\{\s*|=)$' -and $l -notmatch '^\s*#' -and $l -notmatch '\{\s*$')) { $buf = $l; continue }
            if ($kind -eq 'paste' -and $l.EndsWith('\') -and $l -notmatch '^[A-Za-z]:\\?$' -and $l -notmatch '[A-Za-z]:\\\S*\\$') { $buf = $l.Substring(0, $l.Length - 1).TrimEnd(); continue }
            if ($kind -eq 'ps1') {
                if ((Get-ParenDelta $l) -gt 0) { $buf = $l; continue }
            }
        }
        [void]$out.Add($l)
    }
    if ($buf) { [void]$out.Add($buf) }
    return , $out.ToArray()
}

# Drops a trailing "# comment" outside quotes.
function Remove-PsComment([string]$s) {
    $quote = [char]0
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
        if ($quote -ne [char]0) { if ($ch -eq $quote) { $quote = [char]0 }; continue }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq '#' -and ($i -eq 0 -or [char]::IsWhiteSpace($s[$i - 1]))) { return $s.Substring(0, $i).TrimEnd() }
    }
    return $s
}

# Strips a terminal prompt from a pasted line and returns the folder it names, if any.
function Split-ConvPrompt([string]$line) {
    $l = $line.Trim()
    $l = $l -replace '^\([\w.-]+\)\s+', ''            # (venv) PS ...
    if ($l -match '^PS\s+([A-Za-z]:\\[^>]*)>\s*(.*)$') { return @{ Dir = $Matches[1]; Cmd = $Matches[2] } }
    if ($l -match '^([A-Za-z]:\\[^>]*)>\s*(.*)$') { return @{ Dir = $Matches[1]; Cmd = $Matches[2] } }
    if ($l -match '^[\w.-]+@[\w.-]+(?::|\s)[^$#]*[$#]\s+(.*)$') { return @{ Dir = ''; Cmd = $Matches[1] } }
    if ($l -match '^[$>%]\s+(.*)$') { return @{ Dir = ''; Cmd = $Matches[1] } }
    return @{ Dir = ''; Cmd = $l }
}

# ---------------------------------------------------------------- statements
function New-ConvItem($st, [string]$kind, [string]$run, [string]$cwd) {
    $envSnap = [ordered]@{}
    foreach ($k in $st.Env.Keys) { $envSnap[$k] = $st.Env[$k] }
    $item = @{ Kind = $kind; Run = $run; Cwd = $cwd; Env = $envSnap; When = $st.Cond; Shell = 'cmd'; Info = $null; Delay = 0; Source = $st.LineNo; Terminal = $st.Terminal; Override = $null }
    Add-ConvProfileUse $st $st.Cond
    [void]$st.Items.Add($item)
    return $item
}

# Adds a command (long-running or one-off) found at the current place in the script.
function Add-ConvCommand($st, [string]$cmd, [string]$cwd, [bool]$ownWindow = $false, [bool]$wait = $false, [string]$shell = 'cmd') {
    $c = $cmd.Trim()
    $c = $c -replace '\s+(>|1>|2>|>>)\s*(nul|\$null|NUL)(\s+2>&1)?\s*$', ''
    $c = $c -replace '\s+2>&1\s*$', ''
    $c = $c -replace '\s*\|\s*Out-Null\s*$', ''
    $c = $c -replace '^(call|&)\s+', ''
    if (-not $c) { return }
    if ($c -match '^(start|Start-Process)\b' -or $c -match '^wt(\.exe)?\s') { ConvertFrom-ConvLine $st $c; return }

    # npx concurrently "a" "b": one service per command
    if ($c -match '^(npx\s+)?concurrently\s+(.*)$') {
        $parts = @(Split-ConvArgs $Matches[2] | Where-Object { $_ -notmatch '^-' } | ForEach-Object { Get-Unquoted $_ })
        if ($parts.Count -gt 0) {
            foreach ($p in $parts) { Add-ConvCommand $st $p $cwd $true $false $shell }
            Add-ConvNote $st "'concurrently' was split into one service per command."
            return
        }
    }

    if ($st.Kind -eq 'ps1') {
        # & (Join-Path $Venv 'alembic.exe') upgrade head  /  & $python -m app
        $tok = @(Split-ConvArgs $c)
        if ($tok.Count -gt 0 -and $tok[0] -match '^[($]' -and $tok[0] -notmatch '^\$env:') {
            $exe = Resolve-PsValue $st $tok[0]
            if ($exe) { $c = (@($(if ($exe -match '\s') { '"' + $exe + '"' } else { $exe })) + @($tok | Select-Object -Skip 1)) -join ' ' }
        }
        $expanded = Expand-ConvVars $st $c
        if ($expanded -notmatch '\$\w') { $c = $expanded }
    } else {
        $c = $c -replace '%~dp0\\?', ($st.ScriptDir.TrimEnd('\') + '\').Replace('$', '$$')
    }
    # Unix habits in pasted commands: cmd.exe has copy / move, not cp / mv
    if ($c -match '^(cp|mv)\s+(-\w+\s+)*("[^"]+"|\S+)\s+("[^"]+"|\S+)$') {
        $verb = if ($Matches[1] -eq 'cp') { 'copy' } else { 'move' }
        $c = "$verb $($Matches[3].Replace('/', '\')) $($Matches[4].Replace('/', '\'))"
    }
    # paths inside the app folder stay valid on any PC
    $c = [regex]::Replace($c, [regex]::Escape($st.Root) + '(?=[\\/"\s]|$)', { '${ROOT}' }, 'IgnoreCase')
    $c = [regex]::Replace($c, '\$\{ROOT\}[^\s"]*', { param($m) $m.Value.Replace('\', '/') })
    if ($shell -eq 'cmd' -and ($c -match '\$\w|\b(Get|Set|New|Remove|Test|Invoke|Start|Stop|Write|Select|Where|ForEach)-\w+' )) { $shell = 'powershell' }
    $info = Get-CommandInfo $c $cwd $st.Env
    if ($info.Note) { Add-ConvNote $st $info.Note }
    if ($info.Rewrite -eq 'detach') { $c = ($c -replace '\s(-d|--detach)(?=\s|$)', '').Trim() }
    # an executable given by full path: forward slashes, as the recipe rules ask
    if ($c -match '^"?((?:[A-Za-z]:|\$\{ROOT\})\\[^"\s]+)"?(.*)$') { $exe = $Matches[1].Replace('\', '/'); $c = $(if ($c.StartsWith('"')) { '"' + $exe + '"' } else { $exe }) + $Matches[2] }
    $long = $info.Long -and -not $wait
    if (-not $info.Known) {
        if ($st.InWrapper) { $long = $true }
        elseif ($ownWindow -and -not $wait) { $long = $true; Add-ConvNote $st "'$c' was started in its own window, so it is treated as a service. Check it has a port." }
        else { Add-ConvNote $st "'$c' is not a command LocalRun knows, so it is treated as a one-off step. If it keeps running, move it to services." }
    }
    $item = New-ConvItem $st $(if ($long) { 'service' } else { 'step' }) $c $cwd
    $item.Info = $info
    $item.Shell = $shell
}

function Add-ConvVenv($st, [string]$activate) {
    # ...\.venv\Scripts\activate(.bat|.ps1) or source venv/bin/activate
    $p = (Get-Unquoted $activate).Replace('/', '\')
    $dir = Split-Path -Parent $p
    if ($dir -match '\\bin$') { $dir = ($dir -replace '\\bin$', '\Scripts') }
    $abs = Resolve-ConvDir $st $dir
    [void]$st.Path.Add($abs)
    $st.Env['VIRTUAL_ENV'] = (Split-Path -Parent $abs)
    Add-ConvNote $st "The virtualenv '$(ConvertTo-RecipeRel (Split-Path -Parent $abs) $st.Root)' is activated by putting its Scripts folder first on 'path'."
}

function Set-ConvEnv($st, [string]$name, [string]$value) {
    if ($name -ieq 'PATH') {
        $v = Expand-ConvVars $st $value
        foreach ($part in ($v -split ';')) {
            $part = $part.Trim().Trim('"')
            if (-not $part -or $part -match '(?i)^%PATH%$|^\$env:Path$|\$env:PATH') { continue }
            if ($part -match '%\w+%') { continue }
            try { $abs = if ([System.IO.Path]::IsPathRooted($part)) { $part } else { Join-Path $st.Cwd $part } } catch { continue }
            if (-not $st.Path.Contains($abs)) { [void]$st.Path.Add($abs) }
        }
        return
    }
    $st.Env[$name] = (Expand-ConvVars $st $value)
    $st.Vars[$name] = $st.Env[$name]
}

# One logical line of a script or a paste.
function ConvertFrom-ConvLine($st, [string]$line) {
    $l = $line.Trim()
    if (-not $l) { return }
    if ($l -match '^@') { $l = $l.Substring(1).Trim() }

    # comments and noise
    if ($l -match '^(?i)(rem(\s|$)|::|#)') { return }
    if ($l -match '^(?i)(echo(\.|\s|$)|title\s|cls$|color\s|chcp\s|setlocal|endlocal|pause|mode\s|prompt\s|Write-(Host|Output|Verbose|Warning|Information)\b|Clear-Host|\$ErrorActionPreference|\$ProgressPreference|Set-StrictMode|\[Console\]|\$Host\.|Read-Host|Import-Module|#requires)') { return }
    if ($l -match '^(?i)(exit|goto\s+:?eof|return)(\s|$)') { if ($st.Depth -eq 0 -and $st.Blocks.Count -eq 0) { $st.Done = $true }; return }
    # try { X } finally { Y } on one line: both parts run, in order
    if ($st.Kind -ne 'bat' -and $l -match '^(?i)try\s*\{(.*)\}\s*(catch\s*\{.*\}\s*)?finally\s*\{(.*)\}\s*$') {
        $try = $Matches[1]; $fin = $Matches[3]
        foreach ($stmt in (Split-ConvChain $try @(';'))) { ConvertFrom-ConvLine $st $stmt }
        foreach ($stmt in (Split-ConvChain $fin @(';'))) { ConvertFrom-ConvLine $st $stmt }
        return
    }
    # if (-not (Test-Path x)) { throw "..." } stops the script: that is a check, and its message the fix
    if ($l -match '^(?i)throw\s+(.+)$') {
        if ($st.Cond -and $st.Cond.Contains('missing')) {
            $msg = Expand-ConvVars $st (Get-Unquoted $Matches[1])
            $msg = [regex]::Replace($msg, [regex]::Escape($st.Root) + '\\?', '', 'IgnoreCase')
            $path = [string]$st.Cond['missing']
            [void]$st.Checks.Add([ordered]@{ name = "$path exists"; exists = $path; fix = $msg })
        } else { $st.Skipped++ }
        return
    }
    if ($l -match '^(?i)(goto\s|:\w)') { $st.Skipped++; Add-ConvNote $st "The script jumps between labels (goto). Only the part before the first label was converted."; if ($l -match '^:\w') { $st.Done = $true }; return }

    # && chains: split, but keep cd on the same "terminal"
    $chain = @(Split-ConvChain $l @('&&', '||'))
    if ($chain.Count -gt 1 -and $l -notmatch '^(?i)(start|Start-Process|wt)\b') {
        foreach ($part in $chain) { ConvertFrom-ConvLine $st $part }
        return
    }
    if ($st.Kind -ne 'bat' -and $l -notmatch '^(?i)(start|Start-Process|wt|if|foreach|for|while)\b') {
        $semi = @(Split-ConvChain $l @(';'))
        if ($semi.Count -gt 1) { foreach ($part in $semi) { ConvertFrom-ConvLine $st $part }; return }
    }
    if ($st.Kind -eq 'bat' -and $l -notmatch '^(?i)(start|if|for)\b') {
        $amp = @(Split-ConvChain $l @('&'))
        if ($amp.Count -gt 1) { foreach ($part in $amp) { ConvertFrom-ConvLine $st $part }; return }
    }

    # folders
    if ($l -match '^(?i)(cd|chdir|sl|Set-Location|pushd|Push-Location)(\s+/d)?(\s+-(Literal)?Path)?\s+(.+)$') {
        $verb = $Matches[1].ToLower()
        $target = $Matches[5].Trim()
        if ($verb -match 'push') { [void]$st.Stack.Add($st.Cwd) }
        $st.Cwd = Resolve-ConvDir $st $target
        return
    }
    if ($l -match '^(?i)(popd|Pop-Location)$') {
        if ($st.Stack.Count -gt 0) { $st.Cwd = $st.Stack[$st.Stack.Count - 1]; $st.Stack.RemoveAt($st.Stack.Count - 1) }
        return
    }
    if ($l -match '^[A-Za-z]:$') { $st.Cwd = "$l\"; return }

    # variables
    if ($l -match '^(?i)set\s+"?(\w+)=(.*?)"?$' -and $l -notmatch '^(?i)set\s+/[ap]') { Set-ConvEnv $st $Matches[1] $Matches[2]; return }
    if ($l -match '^(?i)set\s+/[ap]') { $st.Skipped++; return }
    if ($l -match '^(?i)export\s+(\w+)=(.*)$') { Set-ConvEnv $st $Matches[1] (Get-Unquoted $Matches[2]); return }
    if ($l -match '^(?i)\$env:(\w+)\s*=\s*(.+)$') {
        $n = $Matches[1]; $v = $Matches[2].Trim()
        if ($n -ieq 'Path') { Set-ConvEnv $st 'PATH' (Expand-ConvVars $st (Get-Unquoted $v)); return }
        $val = Resolve-PsValue $st $v
        # set under a switch: the profile's env
        if ($st.Cond -and $st.Cond.Contains('profile')) {
            $p = $st.Cond['profile']
            if ($null -eq $val) { Add-ConvNote $st "`$env:$n in the '$p' profile is computed by the script, so it was left out. Add it to the profile's env if it is needed."; return }
            if (-not $st.ProfileEnv.Contains($p)) { $st.ProfileEnv[$p] = [ordered]@{} }
            $st.ProfileEnv[$p][$n] = $val
            Add-ConvProfileUse $st $st.Cond
            return
        }
        if ($null -eq $val) { $val = Get-Unquoted $v; Add-ConvNote $st "`$env:$n is computed in the script; check its value in 'env'." }
        $st.Env[$n] = $val
        return
    }
    if ($l -match '^\$(\w+)\s*=\s*(.+)$') {
        $n = $Matches[1]
        $val = Resolve-PsValue $st $Matches[2]
        if ($null -ne $val) { $st.Vars[$n] = $val } else { $st.Skipped++ }
        return
    }
    if ($l -match '^(?i)param\s*\(|^\[CmdletBinding') { return }

    # virtualenv activation
    if ($l -match '^(?i)(call\s+|\.\s+|source\s+|&\s+)?"?([^"\s]*[\\/](Scripts|bin)[\\/]activate(\.bat|\.ps1)?)"?\s*$') { Add-ConvVenv $st $Matches[2]; return }

    # waits
    $n = -1
    if ($l -match '^(?i)timeout(\s+/t)?\s+(\d+)') { $n = [int]$Matches[2] }
    elseif ($l -match '^(?i)Start-Sleep(\s+-(Seconds|s))?\s+(\d+)\s*$') { $n = [int]$Matches[3] }
    elseif ($l -match '^(?i)ping\s+(-n\s+)(\d+)\s+127\.0\.0\.1') { $n = [int]$Matches[2] - 1 }
    elseif ($l -match '^(?i)sleep\s+(\d+)\s*$') { $n = [int]$Matches[1] }
    if ($n -ge 0) {
        $it = New-ConvItem $st 'delay' '' $st.Cwd
        $it.Delay = $n
        return
    }

    # bat: if [not] exist X cmd / ( block
    if ($l -match '^(?i)if\s+(not\s+)?exist\s+("[^"]+"|\S+)\s+(.*)$') {
        $neg = [bool]$Matches[1]
        $path = ConvertTo-RecipeRel (Resolve-ConvDir $st $Matches[2]) $st.Root
        $body = $Matches[3].Trim()
        $cond = if ($neg) { [ordered]@{ missing = $path } } else { [ordered]@{ exists = $path } }
        if ($body -eq '(') { [void]$st.CondStack.Add($st.Cond); $st.Cond = $cond; $st.Depth++; return }
        $body = $body.Trim('(', ')').Trim()
        if ($body -match '^(?i)(echo|exit|goto)\b') { return }
        $old = $st.Cond; $st.Cond = $cond
        ConvertFrom-ConvLine $st $body
        $st.Cond = $old
        return
    }
    if ($st.Kind -eq 'bat' -and $l -match '^\)\s*(else\s*\(?)?') {
        if ($l -match 'else') { $st.Skipped++; $st.Cond = [ordered]@{ never = $true } ; return }
        if ($st.CondStack.Count -gt 0) { $st.Cond = $st.CondStack[$st.CondStack.Count - 1]; $st.CondStack.RemoveAt($st.CondStack.Count - 1) }
        if ($st.Depth -gt 0) { $st.Depth-- }
        return
    }
    if ($l -match '^(?i)(if|for)\s') {
        $st.Skipped++
        Add-ConvNote $st "Lines with conditions or loops (if / for) that are not a simple 'if exist' were not converted."
        return
    }

    # start "title" /d dir cmd /k "..." | start http://... | start "" npm run dev
    if ($l -match '^(?i)start(\s+|$)(.*)$') {
        $tokens = @(Split-ConvArgs $Matches[2])
        $i = 0; $dir = $st.Cwd; $wait = $false
        if ($i -lt $tokens.Count -and $tokens[$i].StartsWith('"')) {
            # the first quoted token is the window title, unless it is the only thing
            if ($tokens.Count -gt 1 -or (Get-Unquoted $tokens[$i]) -notmatch '^https?://') { $i++ }
        }
        while ($i -lt $tokens.Count -and $tokens[$i] -match '^/') {
            $sw = $tokens[$i].ToLower()
            if ($sw -eq '/d' -and $i + 1 -lt $tokens.Count) { $dir = Resolve-ConvDir $st $tokens[$i + 1]; $i += 2; continue }
            if ($sw -like '/d*' -and $sw.Length -gt 2) { $dir = Resolve-ConvDir $st $tokens[$i].Substring(2); $i++; continue }
            if ($sw -eq '/wait') { $wait = $true }
            $i++
        }
        if ($i -ge $tokens.Count) { return }
        $rest = ($tokens[$i..($tokens.Count - 1)] -join ' ')
        Add-ConvStarted $st $rest $dir $wait
        return
    }

    # Start-Process
    if ($l -match '^(?i)Start-Process\s+(.*)$') {
        $tokens = @(Split-ConvArgs $Matches[1])
        $file = $null; $argList = @(); $dir = $st.Cwd; $wait = $false
        $i = 0
        while ($i -lt $tokens.Count) {
            $t = $tokens[$i]
            if ($t -match '^(?i)-(FilePath|File|FileP\w*)$') { $file = $tokens[$i + 1]; $i += 2; continue }
            if ($t -match '^(?i)-(ArgumentList|Args|Arg\w*)$') {
                $i++
                $argsRaw = New-Object System.Collections.ArrayList
                while ($i -lt $tokens.Count -and $tokens[$i] -notmatch '^-[A-Za-z]') { [void]$argsRaw.Add($tokens[$i]); $i++ }
                $joined = ($argsRaw -join ' ').Trim()
                if ($joined -match '^@\((.*)\)$') { $joined = $Matches[1] }
                $argList = @(Split-ConvChain $joined @(',') | ForEach-Object {
                    $a = $_.Trim()
                    $v = Resolve-PsValue $st $a
                    if ($null -ne $v) { $v } else { (Get-Unquoted $a) -replace '`"', '"' }
                })
                continue
            }
            if ($t -match '^(?i)-(WorkingDirectory|WorkingDir\w*)$') { $v = Resolve-PsValue $st $tokens[$i + 1]; $dir = if ($v) { Resolve-ConvDir $st $v } else { $st.Cwd }; $i += 2; continue }
            if ($t -match '^(?i)-Wait$') { $wait = $true; $i++; continue }
            if ($t -match '^(?i)-(WindowStyle|Verb|RedirectStandard\w+)$') { $i += 2; continue }
            if ($t -match '^-') { $i++; continue }
            if (-not $file) { $file = $t } else { $argList += (Get-Unquoted $t) }
            $i++
        }
        if (-not $file) { return }
        $fv = Resolve-PsValue $st $file
        $f = if ($null -ne $fv) { $fv } else { Get-Unquoted $file }
        if ($f -match '\s') { $f = '"' + $f + '"' }
        $cmdLine = (@($f) + @($argList | ForEach-Object { [string]$_ })) -join ' '
        Add-ConvStarted $st $cmdLine $dir $wait
        return
    }

    # Windows Terminal: wt -d dir cmd /k npm run dev ; new-tab -d dir2 ...
    if ($l -match '^(?i)wt(\.exe)?\s+(.*)$') {
        foreach ($tab in (Split-ConvChain $Matches[2] @(' ; ', '`;', '\;'))) {
            $t = $tab -replace '^(?i)(new-tab|nt|split-pane|sp)\s*', ''
            $dir = $st.Cwd
            if ($t -match '^(?i)(-d|--startingDirectory)\s+("[^"]+"|\S+)\s*(.*)$') { $dir = Resolve-ConvDir $st $Matches[2]; $t = $Matches[3] }
            $t = $t -replace '^(?i)(--title|-p|--profile)\s+("[^"]+"|\S+)\s*', ''
            if ($t) { Add-ConvStarted $st $t $dir $false }
        }
        return
    }

    # PowerShell: the script's own helper functions, cmdlets that only print or compute, and
    # leftovers of if / else blocks are logic, not commands to run
    if ($st.Kind -ne 'bat') {
        $first = ($l -split '\s+')[0]
        if ($st.Starters -and $st.Starters.ContainsKey($first.ToLower())) { Add-ConvWrapperCall $st $l; return }
        if ($l -match '^(?i)(function|filter)\s|^\$|^\[' -or $st.Functions.ContainsKey($first.ToLower()) -or
            $l -match '^(?i)(else|elseif|catch|finally|try|switch|break|continue|throw|trap)\b|^[{}]' -or
            ($first -match '^[A-Za-z]+-[A-Za-z]+$' -and (Get-Command $first -CommandType Cmdlet, Function -ErrorAction SilentlyContinue))) {
            $st.Skipped++
            return
        }
    }

    # plain command
    Add-ConvCommand $st $l $st.Cwd $false $false
}

# A command started in its own window or process: unwrap cmd /k "...", powershell -Command "...".
function Add-ConvStarted($st, [string]$cmdLine, [string]$dir, [bool]$wait) {
    $c = $cmdLine.Trim()
    $u = (Get-Unquoted $c) -replace '^\$\{?\w+\}?://', 'http://'   # "${scheme}://..." chosen by the script
    if ($u -match '^https?://\S+$') {
        if ($st.Cond) { [void]$st.Open.Add([ordered]@{ url = $u; when = $st.Cond }); Add-ConvProfileUse $st $st.Cond }
        else { [void]$st.Open.Add($u) }
        return
    }
    if ($c -match '^(?i)(chrome|msedge|firefox|explorer)(\.exe)?\s+"?(https?://[^"\s]+)') { [void]$st.Open.Add($Matches[3]); return }
    $shell = 'cmd'
    if ($c -match '^(?i)"?cmd(\.exe)?"?\s+(/[kc])\s+(.*)$') {
        $inner = $Matches[3].Trim()
        if ($inner.StartsWith('"') -and $inner.EndsWith('"')) { $inner = $inner.Substring(1, $inner.Length - 2) }
        $c = $inner
    } elseif ($c -match '^(?i)"?(powershell|pwsh)(\.exe)?"?\s+(.*)$') {
        $rest = $Matches[3]
        if ($rest -match '(?i)-(File|f)\s+("[^"]+"|\S+)(.*)$') {
            $c = "powershell -NoProfile -ExecutionPolicy Bypass -File $($Matches[2])$($Matches[3])"
            Add-ConvNote $st "A PowerShell script ($(Get-Unquoted $Matches[2])) is called as it is. Convert that script too for readiness and ports."
        } elseif ($rest -match '(?i)-(Command|c)\s+(.*)$') {
            $c = Get-Unquoted $Matches[2].Trim()
            $shell = 'cmd'   # the content decides: PowerShell syntax switches it back
        }
    }
    # cd inside the window only changes that window's folder
    $saveCwd = $st.Cwd; $saveVars = $st.Vars.Clone(); $saveEnv = [ordered]@{}; foreach ($k in $st.Env.Keys) { $saveEnv[$k] = $st.Env[$k] }
    $savePath = @($st.Path)
    $st.Cwd = $dir
    $parts = @(Split-ConvChain $c @('&&', '&', ';'))
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $p = $parts[$i]
        $last = $i -eq $parts.Count - 1
        if ($p -match '^(?i)(cd|pushd|Set-Location|cd\s+/d)\b|^(?i)set\s|^(?i)\$env:|activate(\.bat|\.ps1)?"?$|^(?i)(title|echo)\b') { ConvertFrom-ConvLine $st $p; continue }
        Add-ConvCommand $st $p $st.Cwd $last $wait $shell
    }
    $st.Cwd = $saveCwd; $st.Vars = $saveVars; $st.Env = $saveEnv
    # a venv activated inside the window still counts: path entries are kept
    foreach ($x in $savePath) { if (-not $st.Path.Contains($x)) { [void]$st.Path.Add($x) } }
}

# PowerShell blocks: which lines inside { } are converted.
function Enter-PsLine($st, [string]$line) {
    $l = $line.Trim()
    $delta = Get-BraceDelta $l
    $top = if ($st.Blocks.Count -gt 0) { $st.Blocks[$st.Blocks.Count - 1] } else { $null }
    $inSkip = $false
    foreach ($b in $st.Blocks) { if ($b.Skip) { $inSkip = $true } }

    # one-line guard: if (-not (Test-Path 'x')) { cmd }
    if ($delta -eq 0 -and $l -match '\}\s*$' -and $l -match $script:PsGuard) {
        if ($inSkip) { $st.Skipped++; return }
        $cond = Get-PsGuardCond $st $Matches[1] $Matches[4]
        $body = $l.Substring($l.IndexOf('{') + 1).TrimEnd().TrimEnd('}')
        $old = $st.Cond
        $st.Cond = Join-ConvCond $old $cond
        $st.Depth++; try { foreach ($stmt in (Split-ConvChain $body @(';'))) { ConvertFrom-ConvLine $st $stmt } } finally { $st.Depth-- }
        $st.Cond = $old
        return
    }
    # one-line switch: if (-not $NoBrowser) { Start-Process ... }
    if ($delta -eq 0 -and $l -match '\}\s*$' -and $l -match $script:PsSwitchIf -and $st.Switches.ContainsKey($Matches[2].ToLower())) {
        if ($inSkip) { $st.Skipped++; return }
        $cond = Get-PsSwitchCond $st $Matches[1] $Matches[2]
        $body = $l.Substring($l.IndexOf('{') + 1).TrimEnd().TrimEnd('}')
        $old = $st.Cond
        $st.Cond = Join-ConvCond $old $cond
        $st.Depth++; try { foreach ($stmt in (Split-ConvChain $body @(';'))) { ConvertFrom-ConvLine $st $stmt } } finally { $st.Depth-- }
        $st.Cond = $old
        return
    }

    if ($delta -gt 0) {
        # a block opens on this line
        $kind = 'other'; $skip = $true; $cond = $null
        if ($l -match '^(?i)function\s') { $kind = 'function' }
        elseif ($l -match '^(?i)(try|finally)\s*\{') { $kind = 'try'; $skip = $false }
        elseif ($l -match '^\}?\s*(?i)(catch)\b') { $kind = 'catch' }
        elseif ($l -match '\{\s*$' -and $l -match $script:PsGuard) {
            $kind = 'guard'; $skip = $false
            $cond = Get-PsGuardCond $st $Matches[1] $Matches[4]
        }
        elseif ($l -match '\{\s*$' -and $l -match $script:PsSwitchIf -and $st.Switches.ContainsKey($Matches[2].ToLower())) {
            $kind = 'profile'; $skip = $false
            $cond = Get-PsSwitchCond $st $Matches[1] $Matches[2]
        }
        elseif ($l -match '^\}?\s*(?i)(if|elseif|else)\b') { $kind = 'if' }
        elseif ($l -match '^(?i)(foreach|for|while|do|switch)\b') { $kind = 'loop' }
        elseif ($l -match '^(?i)(Start-Job|Invoke-Command)') { $kind = 'job' }
        if ($inSkip -and $kind -ne 'function') { $skip = $true }
        [void]$st.Blocks.Add(@{ Kind = $kind; Skip = $skip; Cond = $st.Cond; Line = $l })
        if ($cond) { $st.Cond = Join-ConvCond $st.Cond $cond }
        if ($kind -eq 'loop') { Add-ConvNote $st 'Loops (foreach / for / while) were not converted. If a loop starts one thing per folder, list them as separate steps or services.' }
        if ($kind -eq 'if') { Add-ConvNote $st "Blocks under 'if (...)' other than 'if (Test-Path ...)' were not converted, except services they start. Check the draft against the script." }
        if ($kind -eq 'function') { Add-ConvNote $st 'Functions defined in the script were not converted.' }
        # code after the { on the same line
        if ($l -match '\{(.+)$' -and $Matches[1].Trim() -and -not $skip) { ConvertFrom-ConvLine $st $Matches[1].TrimEnd('}').Trim() }
        return
    }
    if ($delta -lt 0) {
        # } finally { Pop-Location }: the finally part still runs
        if (-not $inSkip -and $l -match '^\}\s*(?i)finally\s*\{(.*)\}\s*$') { foreach ($stmt in (Split-ConvChain $Matches[1] @(';'))) { ConvertFrom-ConvLine $st $stmt } }
        for ($k = 0; $k -lt -$delta -and $st.Blocks.Count -gt 0; $k++) {
            $b = $st.Blocks[$st.Blocks.Count - 1]
            $st.Blocks.RemoveAt($st.Blocks.Count - 1)
            $st.Cond = $b.Cond
        }
        # "} else {" style lines have delta 0 and are handled below
        return
    }
    if ($l -match '^\}\s*(?i)(else|elseif|catch|finally)\b.*\{\s*$') {
        if ($top) { $top.Skip = $l -notmatch '(?i)finally' ; if ($l -match '(?i)else') { $top.Kind = 'if'; $top.Skip = $true } }
        return
    }
    if ($inSkip) {
        # inside skipped code only services started with Start-Process / start are kept
        $inFunction = $false
        foreach ($b in $st.Blocks) { if ($b.Kind -eq 'function') { $inFunction = $true } }
        $first = ($l -split '\s+')[0].ToLower()
        # a value set in a branch can still be what a later call uses
        if (-not $inFunction -and $l -match '^\$\w+\s*=' -and $l -notmatch '^(?i)\$env:') { ConvertFrom-ConvLine $st $l; return }
        if (-not $inFunction -and ($l -match '^(?i)(Start-Process|start)\s' -or $st.Starters.ContainsKey($first))) {
            $before = $st.Items.Count
            ConvertFrom-ConvLine $st $l
            for ($k = $before; $k -lt $st.Items.Count; $k++) {
                if ($st.Items[$k].Kind -ne 'service') { $st.Items.RemoveAt($k); $k-- }
            }
            if ($st.Items.Count -gt $before -and -not $st.Items[$st.Items.Count - 1].Override) { Add-ConvNote $st 'Services started inside if / else blocks were kept. If the script only starts them when their port is free, mark them "shared".' }
            return
        }
        if ($l -and $l -notmatch '^\s*#') { $st.Skipped++ }
        return
    }
    ConvertFrom-ConvLine $st $l
}

# ---------------------------------------------------------------- script shape (PowerShell)
# Two things a start script often has that matter for the recipe:
# - switch parameters (-Seed, -NoBrowser, -Lan): they become profiles;
# - a helper function that wraps Start-Process, e.g. Start-Service $Key $Label $Port $File $Args $Dir:
#   every call to it starts a service, so calls are converted as services.
function Read-PsScriptShape($st, $lines) {
    foreach ($line in $lines) {
        if ($line -match '^\s*(?i)function\s') { break }
        if ($line -match '^\s*(?i)param\s*\(') {
            foreach ($m in [regex]::Matches($line, '(?i)\[switch\]\s*\$(\w+)')) { $st.Switches[$m.Groups[1].Value.ToLower()] = $m.Groups[1].Value }
            break
        }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\s*(?i)function\s+([\w-]+)\s*(\(([^)]*)\))?') { continue }
        $name = $Matches[1]
        $paramText = [string]$Matches[3]
        $body = New-Object System.Text.StringBuilder
        $depth = 0
        $j = $i
        do {
            [void]$body.AppendLine($lines[$j])
            $depth += Get-BraceDelta $lines[$j]
            $j++
        } while ($j -lt $lines.Count -and $depth -gt 0)
        $text = $body.ToString()
        if (-not $paramText -and $text -match '(?i)\bparam\s*\(([^)]*)\)') { $paramText = $Matches[1] }
        $params = @([regex]::Matches($paramText, '\$(\w+)') | ForEach-Object { $_.Groups[1].Value })
        if ($text -notmatch '(?i)Start-Process\b' -or $params.Count -eq 0) { continue }
        $pick = { param($pattern) if ($text -match $pattern -and $params -contains $Matches[1]) { $Matches[1] } else { '' } }
        $def = @{
            Params = $params
            File   = & $pick '(?i)Start-Process\s+(?:-FilePath\s+)?\$(\w+)'
            Args   = & $pick '(?i)-ArgumentList\s+\$(\w+)'
            Dir    = & $pick '(?i)-WorkingDirectory\s+\$(\w+)'
            Port   = @($params | Where-Object { $_ -match '(?i)port' })[0]
            Name   = @($params | Where-Object { $_ -match '^(?i)(key|name|service)$' })[0]
            Shared = [bool]($text -match '(?i)(Test-Port\w*|Get-NetTCPConnection|Test-NetConnection)' -and $text -match '(?i)\breturn\b')
        }
        if ($def.File) { $st.Starters[$name.ToLower()] = $def }
    }
}

# A call to a Start-Process wrapper: bind its arguments to the function's parameters.
function Add-ConvWrapperCall($st, [string]$line) {
    $tokens = @(Split-ConvArgs $line)
    $fn = $tokens[0]
    $def = $st.Starters[$fn.ToLower()]
    $vals = @{}
    $pos = 0
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        if ($t -match '^-(\w+)$' -and $def.Params -contains $Matches[1] -and $i + 1 -lt $tokens.Count) { $vals[$Matches[1]] = $tokens[$i + 1]; $i++; continue }
        if ($pos -lt $def.Params.Count) { $vals[$def.Params[$pos]] = $t; $pos++ }
    }
    $label = if ($def.Name -and $vals[$def.Name]) { Resolve-PsValue $st $vals[$def.Name] } else { $null }
    $file = Resolve-PsValue $st ([string]$vals[$def.File])
    if (-not $file) {
        Add-ConvNote $st "$fn$(if ($label) { " '$label'" }) starts $($vals[$def.File]), which the script looks up while it runs, so that call was left out (another branch may have been kept). Put the program's path in its 'run' if you want it."
        return
    }
    $parts = @(if ($file -match '\s') { '"' + $file + '"' } else { $file })
    if ($def.Args -and $vals[$def.Args]) {
        $raw = ([string]$vals[$def.Args]).Trim()
        if ($raw -match '^@\((.*)\)$') { $raw = $Matches[1] }
        foreach ($a in (Split-ConvChain $raw @(','))) {
            $v = Resolve-PsValue $st $a
            if ($null -eq $v) { Add-ConvNote $st "$fn '$label': the argument $a is worked out while the script runs, so that call was left out."; return }
            $parts += $(if ($v -match '\s') { '"' + $v + '"' } else { $v })
        }
    }
    $dir = $st.Cwd
    if ($def.Dir -and $vals[$def.Dir]) { $d = Resolve-PsValue $st $vals[$def.Dir]; if ($d) { $dir = Resolve-ConvDir $st $d } }
    $port = 0
    if ($def.Port -and $vals[$def.Port]) { $pv = Resolve-PsValue $st $vals[$def.Port]; if ($pv -match '^\d+$') { $port = [int]$pv } }
    $before = $st.Items.Count
    $st.InWrapper = $true
    try { Add-ConvStarted $st ($parts -join ' ') $dir $false } finally { $st.InWrapper = $false }
    if ($st.Items.Count -gt $before) {
        $it = $st.Items[$st.Items.Count - 1]
        $it.Kind = 'service'
        $it.Override = @{ Name = $(if ($label) { ($label -replace '[^\w.-]', '') } else { '' }); Port = $port; Shared = $def.Shared -and $port }
    }
}

# if (-not (Test-Path x)) {  /  if ($Switch) {  /  if (-not $Switch) {
$script:PsGuard = '^(?i)if\s*\(\s*(-not\s*|!\s*)?\(?\s*Test-Path\s+(-(Literal)?Path\s+)?("[^"]+"|''[^'']+''|\([^()]*\)|\$\w+|[^\s)]+)\s*\)?\s*\)\s*\{'
$script:PsSwitchIf = '^(?i)if\s*\(\s*(-not\s+|!\s*)?\$(\w+)\s*\)\s*\{'

function Get-PsGuardCond($st, [string]$neg, [string]$token) {
    $pv = Resolve-PsValue $st $token
    if ($null -eq $pv) { $pv = Get-Unquoted $token }
    $path = ConvertTo-RecipeRel (Resolve-ConvDir $st $pv) $st.Root
    if ($neg) { return [ordered]@{ missing = $path } }
    return [ordered]@{ exists = $path }
}

function Get-PsSwitchCond($st, [string]$neg, [string]$name) {
    $p = Get-ConvProfileName $st.Switches[$name.ToLower()]
    if ($neg) { return [ordered]@{ notProfile = $p } }
    return [ordered]@{ profile = $p }
}

# The profile a switch parameter becomes: -NoBrowser -> no-browser.
function Get-ConvProfileName([string]$paramName) {
    return ($paramName -creplace '([a-z0-9])([A-Z])', '$1-$2').ToLower()
}

# Conditions nest: an inner one adds to the outer.
function Join-ConvCond($outer, $inner) {
    if (-not $outer) { return $inner }
    if (-not $inner) { return $outer }
    return [ordered]@{ all = @($outer, $inner) }
}

function Add-ConvProfileUse($st, $cond) {
    if (-not $cond) { return }
    foreach ($k in 'profile', 'notProfile') {
        if ($cond.Contains($k) -and -not $st.ProfilesUsed.Contains($cond[$k])) { [void]$st.ProfilesUsed.Add($cond[$k]) }
    }
    if ($cond.Contains('all')) { foreach ($c in $cond['all']) { Add-ConvProfileUse $st $c } }
}

# ---------------------------------------------------------------- building the recipe
$script:ConvToolChecks = [ordered]@{
    node     = @{ name = 'Node.js'; command = 'node -v'; fix = 'Install Node.js (nodejs.org) and open LocalRun again' }
    php      = @{ name = 'PHP'; command = 'php -v'; fix = 'Install PHP, or add its folder to "path"' }
    composer = @{ name = 'Composer'; command = 'composer --version'; fix = 'Install Composer (getcomposer.org)' }
    python   = @{ name = 'Python'; command = 'python --version'; fix = 'Install Python (python.org), or create the virtualenv' }
    dotnet   = @{ name = '.NET SDK'; command = 'dotnet --version'; fix = 'Install the .NET SDK (dot.net)' }
    java     = @{ name = 'Java'; command = 'java -version'; fix = 'Install a JDK and set JAVA_HOME' }
    docker   = @{ name = 'Docker running'; command = 'docker info'; fix = 'Start Docker Desktop and wait until it says running' }
    flutter  = @{ name = 'Flutter'; command = 'flutter --version'; fix = 'Install Flutter and add it to PATH' }
    go       = @{ name = 'Go'; command = 'go version'; fix = 'Install Go (go.dev)' }
    cargo    = @{ name = 'Rust'; command = 'cargo --version'; fix = 'Install Rust (rustup.rs)' }
    ruby     = @{ name = 'Ruby'; command = 'ruby -v'; fix = 'Install Ruby' }
}

function Get-ConvWhen($item, [string]$root) {
    $cwdRel = ConvertTo-RecipeRel $item.Cwd $root
    $parts = New-Object System.Collections.ArrayList
    if ($item.When) {
        if ($item.When.Contains('never')) { return 'never' }
        [void]$parts.Add($item.When)
    }
    $g = if ($item.Info) { $item.Info.Guard } else { $null }
    if ($g -and -not $item.When) {
        if ($g.missingOnly) { return [ordered]@{ missing = (Join-RecipeRel $cwdRel $g.missingOnly) } }
        $any = New-Object System.Collections.ArrayList
        [void]$any.Add([ordered]@{ missing = (Join-RecipeRel $cwdRel $g.missing) })
        if ($g.newer) { [void]$any.Add([ordered]@{ newer = @((Join-RecipeRel $cwdRel $g.newer[0]), (Join-RecipeRel $cwdRel $g.newer[1])) }) }
        return [ordered]@{ any = $any.ToArray() }
    }
    if ($parts.Count -eq 1) { return $parts[0] }
    return $null
}

function Get-ConvName([string]$base, $used) {
    $n = $base
    $i = 2
    while ($used.ContainsKey($n.ToLower())) { $n = "$base-$i"; $i++ }
    $used[$n.ToLower()] = $true
    return $n
}

function Convert-CommandsToRecipe {
    param([string]$Text, [ValidateSet('paste', 'bat', 'ps1')][string]$Kind = 'paste', [string]$Root, [string]$ScriptDir = '', [string]$StartDir = '', [string]$SourceName = '')
    $Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $ScriptDir) { $ScriptDir = $Root }
    if (-not $StartDir) { $StartDir = $Root }
    $st = @{ Kind = $Kind; Root = $Root; ScriptDir = $ScriptDir; Cwd = $StartDir; Env = [ordered]@{}; Vars = @{}; Path = New-Object System.Collections.ArrayList
             Items = New-Object System.Collections.ArrayList; Open = New-Object System.Collections.ArrayList; Notes = New-Object System.Collections.ArrayList
             Stack = New-Object System.Collections.ArrayList; Cond = $null; CondStack = New-Object System.Collections.ArrayList; Depth = 0
             Blocks = New-Object System.Collections.ArrayList; Skipped = 0; Done = $false; LineNo = 0; Terminal = 1 }

    $lines = Get-ConvLines $Text $Kind
    $st.Functions = @{}
    foreach ($line in $lines) { if ($line -match '^\s*(?i)(function|filter)\s+([\w-]+)') { $st.Functions[$Matches[2].ToLower()] = $true } }
    $st.Switches = @{}
    $st.Starters = @{}
    $st.Checks = New-Object System.Collections.ArrayList
    $st.ProfileEnv = [ordered]@{}
    $st.ProfilesUsed = New-Object System.Collections.ArrayList
    if ($Kind -eq 'ps1') { Read-PsScriptShape $st $lines }
    foreach ($line in $lines) {
        $st.LineNo++
        if ($st.Done) { break }
        if ($Kind -eq 'paste') {
            # a blank line starts the next terminal: back to the app folder, own variables
            if (-not $line.Trim()) {
                if ($st.Items.Count -gt 0 -or $st.Cwd -ne $StartDir) { $st.Cwd = $StartDir; $st.Env = [ordered]@{}; $st.Terminal++ }
                continue
            }
            $pr = Split-ConvPrompt $line
            if ($pr.Dir) { try { $st.Cwd = [System.IO.Path]::GetFullPath($pr.Dir) } catch {} }
            if (-not $pr.Cmd) { continue }
            ConvertFrom-ConvLine $st $pr.Cmd
        } elseif ($Kind -eq 'ps1') {
            if ($line -eq '#here-string') { $st.Skipped++; continue }
            Enter-PsLine $st $line
        } else {
            ConvertFrom-ConvLine $st $line
        }
    }

    # ---- sort items into setup, services, open
    $setup = New-Object System.Collections.ArrayList
    $services = New-Object System.Collections.ArrayList
    $checks = New-Object System.Collections.ArrayList
    $used = @{}
    $toolsSeen = New-Object System.Collections.ArrayList
    $envCopies = @{}
    $serviceTerminals = @{}
    $hasInfra = [bool]@($st.Items | Where-Object { $_.Kind -eq 'service' -and $_.Info.Infra }).Count
    $dbStep = '(?i)\bmigrat|\bseed|\bdb:|prisma\s+(migrate|db)|alembic|loaddata|flyway|liquibase'
    $lastService = $null
    $webUrls = New-Object System.Collections.ArrayList
    $wrapperPorts = @{}

    # env common to every command goes to the top; the rest stays on the command that set it
    $runItems = @($st.Items | Where-Object { $_.Kind -ne 'delay' })
    $commonEnv = [ordered]@{}
    if ($runItems.Count -gt 0) {
        foreach ($k in $runItems[0].Env.Keys) {
            $v = $runItems[0].Env[$k]
            $same = $true
            foreach ($it in $runItems) { if (-not $it.Env.Contains($k) -or [string]$it.Env[$k] -ne [string]$v) { $same = $false; break } }
            if ($same -and $k -ne 'VIRTUAL_ENV') { $commonEnv[$k] = $v }
        }
    }

    foreach ($it in $st.Items) {
        if ($it.Kind -eq 'delay') {
            if ($lastService -and -not $lastService.Contains('port') -and -not $lastService.Contains('ready') -and $it.Delay -gt 0) { $lastService['ready'] = [ordered]@{ delay = $it.Delay } }
            continue
        }
        $when = Get-ConvWhen $it $Root
        if ($when -eq 'never') { continue }
        $info = $it.Info
        if ($info.Tool -and -not $toolsSeen.Contains($info.Tool)) { [void]$toolsSeen.Add($info.Tool) }
        if ($info.CopyEnv) { $envCopies[(ConvertTo-RecipeRel $it.Cwd $Root)] = $true }
        $cwdRel = ConvertTo-RecipeRel $it.Cwd $Root
        $ownEnv = [ordered]@{}
        foreach ($k in $it.Env.Keys) { if (-not $commonEnv.Contains($k) -and $k -ne 'VIRTUAL_ENV') { $ownEnv[$k] = $it.Env[$k] } }

        if ($it.Kind -eq 'service') {
            $serviceTerminals[$(if ($Kind -eq 'paste') { $it.Terminal } else { 0 })] = $true
            $label = if ($cwdRel -and $cwdRel -notmatch '^\.\./|^[A-Za-z]:') { ($cwdRel -split '/')[-1] } elseif ($info.Label) { $info.Label } else { 'service' }
            if ($info.Shared -and $info.Label) { $label = $info.Label }
            $port = $info.Port
            if (-not $port -and $ownEnv.Contains('PORT') -and [string]$ownEnv['PORT'] -match '^\d+$') { $port = [int]$ownEnv['PORT'] }
            $shared = [bool]$info.Shared
            $ov = $it.Override
            if ($ov) {
                # started through the script's own helper: its name and port arguments win
                if ($ov.Name) { $label = $ov.Name }
                if ($ov.Port) { $port = $ov.Port }
                if ($ov.Shared) { $shared = $true }
                if ($ov.Port -and $wrapperPorts.ContainsKey($ov.Port)) {
                    Add-ConvNote $st "'$label' is another way to start what '$($wrapperPorts[$ov.Port])' starts on port $($ov.Port) (the script picks one while it runs); only the first was kept."
                    continue
                }
                if ($ov.Port) { $wrapperPorts[$ov.Port] = $label }
            }
            $s = [ordered]@{ name = '' }
            if ($cwdRel) { $s['cwd'] = $cwdRel }
            $s['run'] = $it.Run
            if ($it.Shell -eq 'powershell') { $s['shell'] = 'powershell' }
            if ($ownEnv.Count -gt 0) { $s['env'] = $ownEnv }
            if ($port) { $s['port'] = $port }
            if ($shared -and $port) { $s['shared'] = $true }
            if ($info.Ready) { $s['ready'] = $info.Ready }
            if ($when) { $s['when'] = $when }
            if ($info.Stop) { $s['stop'] = $info.Stop }
            $s['_label'] = $label
            $s['_infra'] = [bool]$info.Infra
            [void]$services.Add($s)
            $lastService = $s
            if ($info.Web -and $port) { [void]$webUrls.Add(@{ Url = "http://localhost:$port"; Cwd = $it.Cwd; Label = [string]$info.Label }) }
            if (-not $port -and -not $info.Ready) { Add-ConvNote $st "Service '$label' has no port, so LocalRun treats it as ready at once. Add ""port"" if it listens on one." }
        } else {
            $label = $info.Label
            if (-not $label) { $label = (($it.Run -split '\s+')[0..1] -join ' ') }
            if ($cwdRel -and $cwdRel -notmatch '^[A-Za-z]:') { $label = "$label ($((($cwdRel -split '/')[-1])))" }
            $s = [ordered]@{ name = $label }
            if ($cwdRel) { $s['cwd'] = $cwdRel }
            $s['run'] = $it.Run
            if ($it.Shell -eq 'powershell') { $s['shell'] = 'powershell' }
            if ($ownEnv.Count -gt 0) { $s['env'] = $ownEnv }
            $afterDb = $Kind -eq 'paste' -and $hasInfra -and $it.Run -match $dbStep
            if ($serviceTerminals.ContainsKey($(if ($Kind -eq 'paste') { $it.Terminal } else { 0 })) -or $info.Task -or $afterDb) {
                # a one-off after a service needs that service: it becomes a task
                $s['ready'] = [ordered]@{ exit = $true }
                if ($when) { $s['when'] = $when }
                $s['_label'] = $label
                $s['_dbtask'] = $afterDb
                [void]$services.Add($s)
            } else {
                if ($when) { $s['when'] = $when }
                # a new .env gets its key in the same step, so the key is made once, for that .env
                $prev = if ($setup.Count -gt 0) { $setup[$setup.Count - 1] } else { $null }
                if ($info.Label -eq 'app key' -and $prev -and $prev['name'] -like 'create .env*' -and [string]$prev['cwd'] -eq [string]$s['cwd']) {
                    $prev['run'] = "$($prev['run']) && $($s['run'])"
                    $prev['name'] = $prev['name'] -replace '^create \.env', 'create .env and app key'
                    continue
                }
                [void]$setup.Add($s)
            }
        }
    }

    # unique names; services named after their folder or tool
    # pasted terminals have no order: databases, caches and containers start first
    if ($Kind -eq 'paste') {
        $infra = @($services | Where-Object { $_['_infra'] })
        $dbTasks = @($services | Where-Object { $_['_dbtask'] })
        if ($infra.Count -gt 0 -and -not $services[0]['_infra']) {
            $rest = @($services | Where-Object { -not $_['_infra'] -and -not $_['_dbtask'] })
            $services.Clear()
            foreach ($x in @($infra + $dbTasks + $rest)) { [void]$services.Add($x) }
            Add-ConvNote $st 'Databases, caches and containers were moved to the front so they are ready before the apps that use them.'
            if ($dbTasks.Count -gt 0) { Add-ConvNote $st 'Database steps (migrations, seeds) run as tasks once the database is up.' }
        }
    }
    foreach ($s in $services) {
        $s['name'] = Get-ConvName ([string]$s['_label']) $used
        $s.Remove('_label')
        $s.Remove('_infra')
        $s.Remove('_dbtask')
        # the recipe's field order: name, cwd, run, shell, env, port, shared, ready, when, stop
    }
    $stepNames = @{}
    foreach ($s in $setup) { $s['name'] = Get-ConvName ([string]$s['name']) $stepNames }

    # checks: the script's own (a missing file that stops it), the tools used, and .env files
    $checked = @{}
    foreach ($c in $st.Checks) { if (-not $checked.ContainsKey($c.exists)) { $checked[$c.exists] = $true; [void]$checks.Add($c) } }
    foreach ($t in $toolsSeen) {
        if (-not $script:ConvToolChecks.Contains($t)) { continue }
        $def = $script:ConvToolChecks[$t]
        if ($t -eq 'python' -and $st.Path.Count -gt 0 -and ($st.Path | Where-Object { $_ -match 'Scripts$' })) { $def = @{ name = 'Python (virtualenv)'; command = 'python --version'; fix = 'Create the virtualenv first (python -m venv .venv) and install the requirements' } }
        [void]$checks.Add([ordered]@{ name = $def.name; command = $def.command; fix = $def.fix })
    }
    $dirs = New-Object System.Collections.ArrayList
    [void]$dirs.Add($Root)
    foreach ($it in $st.Items) { if ($it.Cwd -and -not $dirs.Contains($it.Cwd)) { [void]$dirs.Add($it.Cwd) } }
    foreach ($d in $dirs) {
        $rel = ConvertTo-RecipeRel $d $Root
        if ($rel -match '^[A-Za-z]:') { continue }
        if ((Test-Path -LiteralPath (Join-Path $d '.env.example')) -and -not $envCopies.ContainsKey($rel)) {
            $e = Join-RecipeRel $rel '.env'
            if ($checked.ContainsKey($e)) { continue }
            [void]$checks.Add([ordered]@{ name = "$e exists"; exists = $e; fix = "Copy $(Join-RecipeRel $rel '.env.example') to $e and fill it in" })
        }
    }

    # ---- the recipe, fields in the documented order
    $recipe = [ordered]@{}
    $recipe['$schema'] = 'https://raw.githubusercontent.com/ToukirAhamedPigeon/LocalRun/main/schema/localrun.schema.json'
    $name = Split-Path -Leaf $Root
    $pkg = Read-ConvJsonFile (Join-Path $Root 'package.json')
    if ($pkg -and $pkg.name -and [string]$pkg.name -notmatch '^@') { $name = [string]$pkg.name }
    $recipe['name'] = $name
    $recipe['description'] = if ($SourceName) { "Converted by LocalRun from $SourceName. Check it, then keep it next to the app." } else { 'Converted by LocalRun from pasted commands. Check it, then keep it next to the app.' }
    if ($st.Path.Count -gt 0) { $recipe['path'] = @($st.Path | ForEach-Object { ConvertTo-RecipeRel $_ $Root } | Select-Object -Unique) }
    if ($commonEnv.Count -gt 0) { $recipe['env'] = $commonEnv }
    if ($checks.Count -gt 0) { $recipe['checks'] = $checks.ToArray() }
    if ($setup.Count -gt 0) { $recipe['setup'] = $setup.ToArray() }
    $recipe['services'] = $services.ToArray()
    # the script's switches that changed something become profiles
    if ($st.ProfilesUsed.Count -gt 0) {
        $profiles = [ordered]@{}
        $byName = @{}
        foreach ($v in $st.Switches.Values) { $byName[(Get-ConvProfileName $v)] = $v }
        foreach ($p in $st.ProfilesUsed) {
            $def = [ordered]@{ description = "Like running the script with -$($byName[$p])" }
            if ($st.ProfileEnv.Contains($p)) { $def['env'] = $st.ProfileEnv[$p] }
            $profiles[$p] = $def
        }
        $recipe['profiles'] = $profiles
        Add-ConvNote $st "The script's switches became profiles ($(@($st.ProfilesUsed) -join ', ')), under the arrow next to Run. Anything else a switch did (certificates, messages) was not converted."
    }
    $open = New-Object System.Collections.ArrayList
    $seenUrls = @{}
    foreach ($o in $st.Open) {
        $u = if ($o -is [string]) { $o } else { $o['url'] }
        if (-not $seenUrls.ContainsKey($u)) { $seenUrls[$u] = $true; [void]$open.Add($o) }
    }
    $open = @($open)
    if ($open.Count -eq 0 -and $webUrls.Count -gt 0) {
        # the last web server, but a page-rendering framework wins over the asset server
        # (Vite / webpack) running in the same folder, e.g. Laravel + Vite
        $pages = 'laravel|django|rails|flask|php|streamlit'
        $pick = $webUrls[$webUrls.Count - 1]
        foreach ($w in $webUrls) { if ($w.Label -match "^($pages)$" -and $pick.Label -match '^(vite|webpack)$' -and $w.Cwd -eq $pick.Cwd) { $pick = $w } }
        $open = @($pick.Url)
        Add-ConvNote $st "Opens $($open[0]) when everything is ready. Remove ""open"" if you do not want a browser tab."
    }
    if ($open.Count -gt 0) { $recipe['open'] = $open }

    if ($services.Count -eq 0) {
        [void]$st.Notes.Insert(0, 'No long-running command (dev server, database, worker) was found, and a recipe needs at least one service. Add it under "services", or paste the command you run to start the app.')
    }
    if ($st.Skipped -gt 0) {
        [void]$st.Notes.Insert(0, "$($st.Skipped) line(s) are program logic (conditions, loops, functions, computed values) and were not converted. For an exact conversion of a script like this, use 'Copy AI prompt'.")
    }
    return @{ Recipe = $recipe; Json = (ConvertTo-RecipeJson $recipe); Notes = $st.Notes.ToArray(); Services = $services.Count; Complex = ($services.Count -eq 0 -or ($st.Skipped -gt 5 -and $st.Items.Count -lt 2)) }
}

# The folder a command file most likely belongs to: the nearest folder with a .git or a
# project file, looking up from the file (a script in scripts\ or local-run\ belongs to its app).
function Get-ConvAppFolder([string]$file) {
    $dir = Get-RecipeRoot $file
    $d = $dir
    for ($i = 0; $i -lt 3 -and $d; $i++) {
        foreach ($m in '.git', 'package.json', 'composer.json', 'pyproject.toml', 'requirements.txt', 'docker-compose.yml', 'pom.xml', 'build.gradle', 'go.mod', 'Cargo.toml', 'pubspec.yaml') {
            if (Test-Path -LiteralPath (Join-Path $d $m)) { return $d }
        }
        if (Get-ChildItem -LiteralPath $d -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1) { return $d }
        $d = Split-Path -Parent $d
    }
    return $dir
}
