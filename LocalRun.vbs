' Starts LocalRun without a console window. Double-click this, or use the shortcut Install.ps1 creates.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\LocalRun.ps1""", 0, False
