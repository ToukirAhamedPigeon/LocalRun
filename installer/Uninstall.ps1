# LocalRun uninstaller. Uninstall.vbs (what Windows runs from Settings > Apps) copies this
# file to %TEMP% and runs it from there, so the install folder itself can be deleted.
param([Parameter(Mandatory = $true)][string]$InstallDir)

Add-Type -AssemblyName PresentationFramework
Set-Location -LiteralPath $env:TEMP
[Environment]::CurrentDirectory = $env:TEMP

$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Pigeonic.LocalRun'
$DataDir = Join-Path $env:APPDATA 'LocalRun'

function Ask($text, $buttons = 'YesNo', $icon = 'Question') {
    return [System.Windows.MessageBox]::Show($text, 'Uninstall LocalRun', $buttons, $icon)
}

$InstallDir = $InstallDir.Trim().TrimEnd('\')

# Safety: only ever delete a folder that really is a LocalRun installation.
$looksRight = (Test-Path -LiteralPath (Join-Path $InstallDir 'LocalRun.ps1')) -and
              (Test-Path -LiteralPath (Join-Path $InstallDir 'Uninstall.vbs')) -and
              ($InstallDir.Length -gt 3) -and
              ($InstallDir -ne $env:USERPROFILE.TrimEnd('\'))
if (-not $looksRight) {
    Ask "This does not look like a LocalRun installation:`n$InstallDir`n`nNothing was removed." 'OK' 'Error' | Out-Null
    exit 1
}

if ((Ask 'Remove LocalRun from this PC?') -ne 'Yes') { exit 0 }

$appScript = Join-Path $InstallDir 'LocalRun.ps1'
$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($appScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
if (@($running).Count -gt 0) {
    Ask 'LocalRun is running. Close it, then run the uninstaller again.' 'OK' 'Warning' | Out-Null
    exit 1
}

$removeData = $false
if (Test-Path -LiteralPath $DataDir) {
    $removeData = (Ask "Also delete your saved projects?`n`nChoose No to keep them for a future install." 'YesNo' 'Question') -eq 'Yes'
}

$problems = @()

# Shortcuts: only the ones Setup recorded, and only if they still point into this installation.
$reg = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
if ($reg -and $reg.Shortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($s in ($reg.Shortcuts -split '\|')) {
        if (-not $s -or -not (Test-Path -LiteralPath $s)) { continue }
        try {
            if ($shell.CreateShortcut($s).Arguments.IndexOf($InstallDir, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Remove-Item -LiteralPath $s -Force -ErrorAction Stop
            }
        } catch { $problems += "Shortcut ${s}: $($_.Exception.Message)" }
    }
}

Remove-Item -Path $RegPath -Recurse -Force -ErrorAction SilentlyContinue

try { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop }
catch { $problems += "Install folder: $($_.Exception.Message)" }

if ($removeData) {
    try { Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction Stop }
    catch { $problems += "Saved projects: $($_.Exception.Message)" }
}

if ($problems.Count -gt 0) {
    Ask ("LocalRun was removed, but some items could not be deleted:`n`n" + ($problems -join "`n")) 'OK' 'Warning' | Out-Null
} elseif ($removeData) {
    Ask 'LocalRun has been removed from this PC.' 'OK' 'Information' | Out-Null
} else {
    Ask "LocalRun has been removed from this PC.`n`nYour saved projects were kept in $DataDir." 'OK' 'Information' | Out-Null
}
