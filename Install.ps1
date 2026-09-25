# Creates Desktop and Start Menu shortcuts for LocalRun on this PC (with the LocalRun icon).
# Run once per PC:  right-click > Run with PowerShell
$dir  = $PSScriptRoot
$icon = Join-Path $dir 'assets\localrun.ico'
$shell = New-Object -ComObject WScript.Shell
$targets = @(
    [Environment]::GetFolderPath('Desktop'),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
)
foreach ($folder in $targets) {
    $lnk = $shell.CreateShortcut((Join-Path $folder 'LocalRun.lnk'))
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $dir 'LocalRun.vbs') + '"'
    $lnk.WorkingDirectory = $dir
    $lnk.Description = 'Start local projects with one click'
    if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Save()
    Write-Host "Shortcut created: $folder\LocalRun.lnk"
}
