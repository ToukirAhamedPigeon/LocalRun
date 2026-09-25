# Creates Desktop and Start Menu shortcuts for LocalRun on this PC, with the LocalRun icon.
# Each shortcut also carries LocalRun's AppUserModelID, the same ID the app sets on itself,
# so the taskbar shows LocalRun's icon and a pinned shortcut groups with the running window.
# Run once per PC:  right-click > Run with PowerShell
$dir   = $PSScriptRoot
$icon  = Join-Path $dir 'assets\localrun.ico'
$appId = 'Pigeonic.LocalRun'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace LocalRunSetup {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey { public Guid FormatId; public int PropertyId; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    public static class Shortcut {
        // PKEY_AppUserModel_ID
        static PropertyKey AppIdKey() {
            PropertyKey k; k.FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.PropertyId = 5; return k;
        }

        static object Open(string path) {
            object link = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
            ((IPersistFile)link).Load(path, 2 /* STGM_READWRITE */);
            return link;
        }

        public static void SetAppId(string path, string appId) {
            object link = Open(path);
            try {
                IPropertyStore store = (IPropertyStore)link;
                PropertyKey key = AppIdKey();
                PropVariant value = new PropVariant();
                value.vt = 31; // VT_LPWSTR
                value.p = Marshal.StringToCoTaskMemUni(appId);
                try {
                    Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
                    Marshal.ThrowExceptionForHR(store.Commit());
                } finally { Marshal.FreeCoTaskMem(value.p); }
                ((IPersistFile)link).Save(path, true);
            } finally { Marshal.ReleaseComObject(link); }
        }

        public static string GetAppId(string path) {
            object link = Open(path);
            try {
                PropertyKey key = AppIdKey();
                PropVariant value;
                Marshal.ThrowExceptionForHR(((IPropertyStore)link).GetValue(ref key, out value));
                return value.vt == 31 ? Marshal.PtrToStringUni(value.p) : null;
            } finally { Marshal.ReleaseComObject(link); }
        }
    }
}
'@

$shell = New-Object -ComObject WScript.Shell
$targets = @(
    [Environment]::GetFolderPath('Desktop'),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
)
foreach ($folder in $targets) {
    $path = Join-Path $folder 'LocalRun.lnk'
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $dir 'LocalRun.vbs') + '"'
    $lnk.WorkingDirectory = $dir
    $lnk.Description = 'Start local projects with one click'
    if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Save()
    try {
        [LocalRunSetup.Shortcut]::SetAppId($path, $appId)
        Write-Host "Shortcut created: $path  (taskbar ID: $([LocalRunSetup.Shortcut]::GetAppId($path)))"
    } catch {
        Write-Host "Shortcut created: $path  (taskbar ID not set: $($_.Exception.Message))"
    }
}
