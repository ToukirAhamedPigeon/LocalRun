// LocalRun-Setup.exe: a tiny bootstrapper. It carries setup.ps1 and payload.zip as embedded
// resources, extracts them to a temp folder, runs the setup wizard hidden-console, then cleans up.
// Built by installer\build.ps1 with the csc.exe that ships with Windows (.NET Framework 4).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("LocalRun Setup")]
[assembly: AssemblyDescription("Installer for LocalRun")]
[assembly: AssemblyCompany("Pigeonic")]
[assembly: AssemblyProduct("LocalRun")]
[assembly: AssemblyCopyright("Copyright © 2026 Pigeonic")]
[assembly: AssemblyVersion(LocalRunSetup.Build.Version)]
[assembly: AssemblyFileVersion(LocalRunSetup.Build.Version)]
[assembly: AssemblyInformationalVersion(LocalRunSetup.Build.Version)]

namespace LocalRunSetup {
    static class Program {
        [STAThread]
        static int Main(string[] args) {
            string temp = Path.Combine(Path.GetTempPath(), "LocalRunSetup-" + Guid.NewGuid().ToString("N"));
            try {
                Directory.CreateDirectory(temp);
                Assembly me = Assembly.GetExecutingAssembly();
                foreach (string name in new string[] { "setup.ps1", "payload.zip" }) {
                    using (Stream source = me.GetManifestResourceStream(name))
                    using (FileStream target = File.Create(Path.Combine(temp, name))) {
                        source.CopyTo(target);
                    }
                }

                // Forward any arguments (e.g. -Quiet -InstallDir "...") to the wizard.
                StringBuilder forwarded = new StringBuilder();
                foreach (string a in args) {
                    forwarded.Append(" \"").Append(a.Replace("\"", "\\\"")).Append('"');
                }

                ProcessStartInfo psi = new ProcessStartInfo(
                    Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                    "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" +
                        Path.Combine(temp, "setup.ps1") + "\"" + forwarded);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WorkingDirectory = temp;
                using (Process p = Process.Start(psi)) {
                    p.WaitForExit();
                    return p.ExitCode;
                }
            } catch (Exception ex) {
                MessageBox.Show("LocalRun Setup could not start:\n\n" + ex.Message, "LocalRun Setup",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            } finally {
                try { Directory.Delete(temp, true); } catch { }
            }
        }
    }
}
