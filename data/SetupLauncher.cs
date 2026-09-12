// Built locally with .NET Framework csc.exe /target:winexe /platform:x64.
// Windows Setup and logon tasks use this entry point without allocating a console.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

internal static class SetupLauncher
{
    private static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;

    [DllImport("kernel32.dll")]
    private static extern uint GetOEMCP();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);

    private static bool WaitForOobe()
    {
        DateTime deadline = DateTime.UtcNow.AddHours(2);
        bool logged = false;
        while (true)
        {
            bool complete;
            if (OOBEComplete(out complete) && complete) { return true; }
            if (!logged) { Log("guard-debug", "WAIT OOBE completion before opening the debug viewer"); logged = true; }
            if (DateTime.UtcNow >= deadline) { Log("guard-debug", "ERROR OOBE wait timed out"); return false; }
            Thread.Sleep(500);
        }
    }

    private static void Log(string mode, string text)
    {
        string entry = DateTime.Now.ToString("s") + " [" + mode + "] " + text + Environment.NewLine;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                File.AppendAllText(Path.Combine(Root, "launcher.log"), entry, new UTF8Encoding(true));
                return;
            }
            catch (IOException) { Thread.Sleep(50); }
            catch (UnauthorizedAccessException) { return; } // Limited-user guard viewer only reads system logs.
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string mode = args.Length == 1 ? args[0].ToLowerInvariant() : "invalid";
        string script;
        string switches;
        switch (mode)
        {
            case "prepare": script = "Prepare.ps1"; switches = ""; break;
            case "prepare-register": script = "Prepare.ps1"; switches = " -RegisterOnly"; break;
            case "finalize": script = "Finalize.ps1"; switches = " -FirstLogon"; break;
            case "finalize-wait": script = "Finalize.ps1"; switches = " -WaitForOobe"; break;
            case "guard": script = "guard.ps1"; switches = ""; break;
            case "guard-debug": script = "guard.ps1"; switches = " -ShowDebugWindow"; break;
            default: Log("invalid", "Unsupported launcher mode"); return 87;
        }

        try
        {
            string scriptPath = Path.Combine(Root, script);
            if (!File.Exists(scriptPath))
            {
                Log(mode, "Script not found: " + script);
                return 2;
            }
            // The optional visible log viewer must not appear over OOBE screens.
            if (mode == "guard-debug" && !WaitForOobe()) { return 1460; }
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"" + switches;
            start.WorkingDirectory = Root;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            // Windows PowerShell 5.1 uses the system OEM encoding for redirected console output.
            start.StandardOutputEncoding = Encoding.GetEncoding((int)GetOEMCP());
            start.StandardErrorEncoding = start.StandardOutputEncoding;

            using (Process child = new Process())
            {
                child.StartInfo = start;
                if (!child.Start()) { Log(mode, "Could not start PowerShell"); return 1; }
                Log(mode, "START PID=" + child.Id);
                child.StandardInput.Close();
                // Drain both streams concurrently so hidden scripts cannot fill a pipe and stall.
                Task<string> output = child.StandardOutput.ReadToEndAsync();
                Task<string> error = child.StandardError.ReadToEndAsync();
                child.WaitForExit();
                string stdout = output.GetAwaiter().GetResult();
                string stderr = error.GetAwaiter().GetResult();
                if (!String.IsNullOrWhiteSpace(stdout)) { Log(mode, stdout.Trim()); }
                if (!String.IsNullOrWhiteSpace(stderr)) { Log(mode, "STDERR " + stderr.Trim()); }
                Log(mode, "END ExitCode=" + child.ExitCode);
                return child.ExitCode;
            }
        }
        catch (Exception error)
        {
            Log(mode, "ERROR " + error.Message);
            return 1;
        }
    }
}
