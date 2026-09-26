# Builds the release files into dist\:
#   LocalRun-Setup-<version>.exe  - the installer (wizard + Terms, per-user, no admin)
#   LocalRun-<version>.zip        - portable copy (unzip and run LocalRun.vbs)
# Uses only what ships with Windows: PowerShell 5.1 and the .NET Framework 4 csc.exe.
# Usage:  powershell -ExecutionPolicy Bypass -File installer\build.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$Root  = Split-Path -Parent $PSScriptRoot
$Dist  = Join-Path $Root 'dist'
$Work  = Join-Path $Dist 'build'
$Csc   = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $Csc)) { $Csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }

# Single source of truth for the version: $AppVersion in LocalRun.ps1
if ((Get-Content -LiteralPath (Join-Path $Root 'LocalRun.ps1') -Raw) -notmatch '\$AppVersion = ''([^'']+)''') { throw 'AppVersion not found in LocalRun.ps1' }
$Version = $Matches[1]
$FileVersion = (($Version -split '\.') + @('0', '0', '0', '0'))[0..3] -join '.'

# The recipe engine, the converter, the rules (shown in the in-app guide), the JSON schema and the templates.
function Copy-RecipeFiles($dest) {
    Copy-Item -LiteralPath (Join-Path $Root 'engine.ps1') -Destination $dest
    Copy-Item -LiteralPath (Join-Path $Root 'converter.ps1') -Destination $dest
    New-Item -ItemType Directory -Path (Join-Path $dest 'docs') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root 'docs\recipe-format.md') -Destination (Join-Path $dest 'docs')
    foreach ($dir in 'schema', 'templates') {
        Copy-Item -LiteralPath (Join-Path $Root $dir) -Destination $dest -Recurse
    }
}

if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $Work 'payload\assets') -Force | Out-Null

# Payload = what gets installed. Install.ps1 is for git/zip users; the installer makes its own shortcuts.
$files = @{
    'LocalRun.ps1'           = 'LocalRun.ps1'
    'LocalRun.vbs'           = 'LocalRun.vbs'
    'LocalRun.bat'           = 'LocalRun.bat'
    'README.md'              = 'README.md'
    'TERMS.md'               = 'TERMS.md'
    'LICENSE'                = 'LICENSE'
    'assets\logo.png'        = 'assets\logo.png'
    'assets\localrun.ico'    = 'assets\localrun.ico'
    'installer\Uninstall.ps1' = 'Uninstall.ps1'
    'installer\Uninstall.vbs' = 'Uninstall.vbs'
}
foreach ($src in $files.Keys) {
    Copy-Item -LiteralPath (Join-Path $Root $src) -Destination (Join-Path $Work "payload\$($files[$src])")
}
Copy-RecipeFiles (Join-Path $Work 'payload')
$payloadZip = Join-Path $Work 'payload.zip'
[System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $Work 'payload'), $payloadZip, 'Optimal', $false)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'setup.ps1') -Destination (Join-Path $Work 'setup.ps1')

# Version constant for the assembly attributes
Set-Content -LiteralPath (Join-Path $Work 'Version.cs') -Encoding ASCII -Value @"
namespace LocalRunSetup { static class Build { public const string Version = "$FileVersion"; } }
"@

$exe = Join-Path $Dist "LocalRun-Setup-$Version.exe"
& $Csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$exe" `
    "/win32icon:$(Join-Path $Root 'assets\localrun.ico')" `
    /reference:System.Windows.Forms.dll `
    "/resource:$(Join-Path $Work 'setup.ps1'),setup.ps1" `
    "/resource:$payloadZip,payload.zip" `
    (Join-Path $PSScriptRoot 'Bootstrap.cs') (Join-Path $Work 'Version.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

# Portable zip: the app folder as it is in the repo, under a LocalRun\ root.
$zip = Join-Path $Dist "LocalRun-$Version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
$portable = Join-Path $Work 'portable\LocalRun'
New-Item -ItemType Directory -Path (Join-Path $portable 'assets') -Force | Out-Null
foreach ($f in 'LocalRun.ps1', 'LocalRun.vbs', 'LocalRun.bat', 'Install.ps1', 'README.md', 'TERMS.md', 'LICENSE', 'assets\logo.png', 'assets\localrun.ico') {
    Copy-Item -LiteralPath (Join-Path $Root $f) -Destination (Join-Path $portable $f)
}
Copy-RecipeFiles $portable
[System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $Work 'portable'), $zip, 'Optimal', $false)

Remove-Item -LiteralPath $Work -Recurse -Force
Get-Item -LiteralPath $exe, $zip | ForEach-Object { '{0,-32} {1,8:N0} KB' -f $_.Name, ($_.Length / 1KB) }
