' What Windows runs to uninstall LocalRun (Settings > Apps > Installed apps).
' Copies Uninstall.ps1 to %TEMP% and runs it from there, so this folder can be deleted.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
tmp = sh.ExpandEnvironmentStrings("%TEMP%")
fso.CopyFile dir & "\Uninstall.ps1", tmp & "\LocalRun-Uninstall.ps1", True
sh.CurrentDirectory = tmp
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & tmp & "\LocalRun-Uninstall.ps1"" -InstallDir """ & dir & """", 0, False
