param(
    [switch]$SkipBuild,
    [string]$Version = "3.4.1"
)

$ErrorActionPreference = "Stop"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $SkipBuild) {
    Write-Host "[0/4] Running clean release build (-NoReload)..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "build_release.ps1") -NoReload
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$winReleaseDir = Join-Path $root "apps\agent_mcp_app\build\windows\x64\runner\Release"
$webBuildDir   = Join-Path $root "apps\agent_mcp_app\build\web"
$cliBinPath    = Join-Path $root "bin\agent-mcp.exe"
$iconPath      = Join-Path $root "apps\agent_mcp_app\assets\app_icon.ico"

foreach ($reqPath in @($winReleaseDir, $webBuildDir, $cliBinPath, $iconPath)) {
    if (-not (Test-Path $reqPath)) {
        throw "Missing required build artifact: $reqPath (run without -SkipBuild first)"
    }
}

$outRoot    = Join-Path $root "release"
$stageRoot  = Join-Path $outRoot "_clean_stage"
$zipOutPath = Join-Path $outRoot "AgentMCP-v$Version-windows-x64-portable.zip"
$sfxOutPath = Join-Path $outRoot "AgentMCP-v$Version-windows-x64-sfx.exe"

Write-Host "[1/4] Assembling zero-config clean staging directory..." -ForegroundColor Cyan
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

Copy-Item -Recurse -Force (Join-Path $winReleaseDir "*") $stageRoot
Copy-Item -Force $cliBinPath (Join-Path $stageRoot "agent-mcp.exe")
Copy-Item -Force $iconPath (Join-Path $stageRoot "app_icon.ico")
Copy-Item -Recurse -Force $webBuildDir (Join-Path $stageRoot "web_dashboard")

$forbiddenRelPaths = @(
    "config",
    "logs",
    "bin",
    "data\cache",
    "data\oauth_state.json",
    "data\window_state.json",
    "data\tunnel_state.json",
    "data\update_prefs.json"
)
foreach ($rel in $forbiddenRelPaths) {
    $p = Join-Path $stageRoot $rel
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}

$leaked = Get-ChildItem -Path $stageRoot -Recurse -Include @(
    "mcp_config.json",
    "mcp_sub_servers.json",
    "oauth_state.json",
    "window_state.json",
    "tunnel_state.json",
    "update_prefs.json",
    "*.log"
) -ErrorAction SilentlyContinue
if ($leaked) {
    throw "Sanitization check failed! Found personal state files: $($leaked.FullName -join ', ')"
}

Write-Host "[2/4] Compressing clean portable archive ($zipOutPath)..." -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $zipOutPath) { Remove-Item -Force $zipOutPath }
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stageRoot,
    $zipOutPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

Write-Host "[3/4] Compiling Concentric Prism Zero-UAC Windows Installer ($sfxOutPath)..." -ForegroundColor Cyan
$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    throw "Could not locate .NET Framework v4.0 csc.exe on this machine."
}

$csFile = Join-Path $outRoot "_sfx_stub.cs"
$csSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Agent MCP Prism Setup")]
[assembly: AssemblyProduct("Agent MCP Console")]
[assembly: AssemblyVersion("3.4.1.0")]

namespace AgentMcpSfx {
    internal sealed class InstallOptions {
        public bool Silent;
        public bool Cli;
        public bool AutoConfirmClose;
        public bool CreateShortcut = true;
        public bool ShortcutExplicit;
        public bool ShowHelp;
        public string ExplicitDir;
        public string After = "gui";
        public int DelayMs;
    }

    internal static class Program {
        internal const string AppVersion = "__APP_VERSION__";
        private const string RegSubKey = @"Software\AgentMCP";

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AllocConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool QueryFullProcessImageName(IntPtr hProcess, int dwFlags, StringBuilder lpExeName, ref int lpdwSize);

        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [STAThread]
        private static int Main(string[] args) {
            InstallOptions opts = ParseArgs(args);

            if (opts.ShowHelp) {
                EnsureConsole();
                PrintUsage();
                return 0;
            }

            if (opts.Silent) {
                return RunSilentInstall(opts);
            }

            if (opts.Cli) {
                EnsureConsole();
                return RunCliInstall(opts);
            }

            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SfxForm(opts));
            return 0;
        }

        private static void EnsureConsole() {
            try {
                if (!AttachConsole(-1)) {
                    AllocConsole();
                }
            } catch { }
        }

        private static void PrintUsage() {
            Console.WriteLine("Agent MCP v" + AppVersion + " Prism Smart Installer (Zero-UAC)");
            Console.WriteLine("Usage:");
            Console.WriteLine("  installer.exe                                 Launch Concentric Prism GUI installer");
            Console.WriteLine("  installer.exe --silent [--after gui|tray|cli|none] [--dir <path>] [--delay-ms <N>]");
            Console.WriteLine("  installer.exe --cli [--yes] [--after gui|tray|cli|none] [--dir <path>]");
            Console.WriteLine("  installer.exe --extract-to <path>             Silent extract to target directory (no launch)");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --silent, -S, /S       Unattended zero-prompt install (auto-closes running instance)");
            Console.WriteLine("  --cli                  Console/CLI install mode with stdout progress");
            Console.WriteLine("  --dir, -o <path>       Override target installation directory");
            Console.WriteLine("  --after <mode>         Post-install action: gui (default) | tray | cli | none");
            Console.WriteLine("  --yes, -y              Auto-confirm closing running Agent MCP instances in CLI mode");
            Console.WriteLine("  --no-shortcut          Skip creating Desktop shortcut");
            Console.WriteLine("  --delay-ms <N>         Optional delay before stopping running instances");
        }

        internal static InstallOptions ParseArgs(string[] args) {
            var o = new InstallOptions();
            if (args == null) return o;
            for (int i = 0; i < args.Length; i++) {
                string a = (args[i] ?? "").Trim();
                string al = a.ToLowerInvariant();
                if (al == "--help" || al == "-h" || al == "/?") {
                    o.ShowHelp = true;
                } else if (al == "--silent" || al == "-s" || al == "/s" || al == "/silent") {
                    o.Silent = true;
                    o.AutoConfirmClose = true;
                } else if (al == "--cli" || al == "--console") {
                    o.Cli = true;
                } else if (al == "--yes" || al == "-y" || al == "--auto-close") {
                    o.AutoConfirmClose = true;
                } else if (al == "--no-shortcut") {
                    o.CreateShortcut = false;
                    o.ShortcutExplicit = true;
                } else if (al == "--shortcut") {
                    o.CreateShortcut = true;
                    o.ShortcutExplicit = true;
                } else if ((al == "--dir" || al == "-o" || al == "--target") && i + 1 < args.Length) {
                    o.ExplicitDir = Path.GetFullPath(args[++i]);
                } else if (al == "--extract-to" && i + 1 < args.Length) {
                    o.ExplicitDir = Path.GetFullPath(args[++i]);
                    o.Silent = true;
                    o.AutoConfirmClose = true;
                    o.After = "none";
                    o.CreateShortcut = false;
                    o.ShortcutExplicit = true;
                } else if (al == "--after" && i + 1 < args.Length) {
                    o.After = NormalizeAfter(args[++i]);
                } else if (al.StartsWith("--after=")) {
                    o.After = NormalizeAfter(a.Substring(8));
                } else if (al == "--delay-ms" && i + 1 < args.Length) {
                    int ms;
                    if (int.TryParse(args[++i], out ms) && ms > 0) o.DelayMs = Math.Min(ms, 30000);
                }
            }
            return o;
        }

        private static string NormalizeAfter(string raw) {
            string s = (raw ?? "gui").Trim().ToLowerInvariant();
            if (s == "tray" || s == "silent" || s == "background") return "tray";
            if (s == "cli" || s == "console") return "cli";
            if (s == "none" || s == "no" || s == "exit") return "none";
            return "gui";
        }

        internal static bool DetectSystemDarkMode() {
            try {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) {
                    if (k != null) {
                        object v = k.GetValue("AppsUseLightTheme");
                        if (v is int) return ((int)v) == 0;
                    }
                }
            } catch { }
            return false;
        }

        internal static string GetProcessImagePath(Process proc) {
            try {
                IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, proc.Id);
                if (h != IntPtr.Zero) {
                    try {
                        var sb = new StringBuilder(1024);
                        int size = sb.Capacity;
                        if (QueryFullProcessImageName(h, 0, sb, ref size)) {
                            return sb.ToString();
                        }
                    } finally {
                        CloseHandle(h);
                    }
                }
            } catch { }
            try {
                return proc.MainModule != null ? proc.MainModule.FileName : null;
            } catch {
                return null;
            }
        }

        internal static List<Process> FindRunningInstances(string targetDirOrNull) {
            var list = new List<Process>();
            int selfPid = Process.GetCurrentProcess().Id;
            string normTarget = string.IsNullOrEmpty(targetDirOrNull)
                ? null
                : Path.GetFullPath(targetDirOrNull).TrimEnd(Path.DirectorySeparatorChar);

            foreach (string procName in new[] { "agent_mcp_app", "agent-mcp" }) {
                try {
                    foreach (Process p in Process.GetProcessesByName(procName)) {
                        if (p.Id == selfPid) continue;
                        if (normTarget != null && procName == "agent-mcp") {
                            string img = GetProcessImagePath(p);
                            if (string.IsNullOrEmpty(img) ||
                                !img.StartsWith(normTarget, StringComparison.OrdinalIgnoreCase)) {
                                continue;
                            }
                        }
                        list.Add(p);
                    }
                } catch { }
            }
            return list;
        }

        internal static string DetectExistingInstallDir(string explicitDir, out bool isUpgrade) {
            isUpgrade = false;
            if (!string.IsNullOrEmpty(explicitDir)) {
                isUpgrade = File.Exists(Path.Combine(explicitDir, "agent_mcp_app.exe"));
                return explicitDir;
            }

            try {
                foreach (Process p in Process.GetProcessesByName("agent_mcp_app")) {
                    string img = GetProcessImagePath(p);
                    if (!string.IsNullOrEmpty(img) && File.Exists(img)) {
                        string dir = Path.GetDirectoryName(img);
                        if (!string.IsNullOrEmpty(dir)) {
                            isUpgrade = true;
                            return dir;
                        }
                    }
                }
            } catch { }

            try {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RegSubKey)) {
                    if (key != null) {
                        object val = key.GetValue("InstallDir");
                        string regDir = val != null ? val.ToString().Trim() : "";
                        if (!string.IsNullOrEmpty(regDir) && Directory.Exists(regDir)) {
                            isUpgrade = File.Exists(Path.Combine(regDir, "agent_mcp_app.exe"));
                            return regDir;
                        }
                    }
                }
            } catch { }

            string defaultDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs",
                "AgentMCP"
            );
            isUpgrade = File.Exists(Path.Combine(defaultDir, "agent_mcp_app.exe"));
            return defaultDir;
        }

        internal static void SaveInstallRegistry(string targetDir) {
            try {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RegSubKey)) {
                    if (key != null) {
                        key.SetValue("InstallDir", Path.GetFullPath(targetDir));
                        key.SetValue("Version", AppVersion);
                        key.SetValue("UpdatedAt", DateTime.UtcNow.ToString("o"));
                    }
                }
            } catch { }
            // Also promote existing Windows 11 tray icon if already registered
            try {
                string targetExe = Path.Combine(Path.GetFullPath(targetDir), "agent_mcp_app.exe");
                using (RegistryKey notifyRoot = Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings", true)) {
                    if (notifyRoot != null) {
                        foreach (string sub in notifyRoot.GetSubKeyNames()) {
                            using (RegistryKey item = notifyRoot.OpenSubKey(sub, true)) {
                                if (item == null) continue;
                                string ep = (item.GetValue("ExecutablePath") ?? "").ToString();
                                if (ep.EndsWith(targetExe, StringComparison.OrdinalIgnoreCase) ||
                                    ep.EndsWith(@"\agent_mcp_app.exe", StringComparison.OrdinalIgnoreCase)) {
                                    item.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
                                }
                            }
                        }
                    }
                }
            } catch { }
        }

        internal static void StopRunningInstances(List<Process> procs) {
            if (procs == null || procs.Count == 0) return;
            foreach (Process p in procs) {
                try {
                    if (!p.HasExited) p.CloseMainWindow();
                } catch { }
            }
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(1800);
            while (DateTime.UtcNow < deadline) {
                bool anyAlive = false;
                foreach (Process p in procs) {
                    try {
                        if (!p.HasExited) { anyAlive = true; break; }
                    } catch { }
                }
                if (!anyAlive) break;
                Thread.Sleep(120);
            }
            foreach (Process p in procs) {
                try {
                    if (!p.HasExited) {
                        p.Kill();
                        p.WaitForExit(3000);
                    }
                } catch { }
            }
            Thread.Sleep(350);
        }

        internal static void ExtractPayload(string targetDir, Action<int, int, string> onProgress) {
            Directory.CreateDirectory(targetDir);
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream raw = asm.GetManifestResourceStream("AgentMCP.payload.zip")) {
                if (raw == null) throw new InvalidOperationException("Embedded payload missing.");
                using (ZipArchive archive = new ZipArchive(raw, ZipArchiveMode.Read)) {
                    int total = archive.Entries.Count;
                    int idx = 0;
                    string fullRoot = Path.GetFullPath(targetDir);
                    if (!fullRoot.EndsWith(Path.DirectorySeparatorChar.ToString())) {
                        fullRoot += Path.DirectorySeparatorChar;
                    }
                    foreach (ZipArchiveEntry entry in archive.Entries) {
                        idx++;
                        string rel = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                        string dst = Path.GetFullPath(Path.Combine(targetDir, rel));
                        if (!dst.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)) {
                            continue;
                        }
                        if (string.IsNullOrEmpty(entry.Name)) {
                            Directory.CreateDirectory(dst);
                            continue;
                        }
                        string parent = Path.GetDirectoryName(dst);
                        if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

                        Exception lastErr = null;
                        for (int attempt = 0; attempt < 6; attempt++) {
                            try {
                                entry.ExtractToFile(dst, true);
                                lastErr = null;
                                break;
                            } catch (IOException ex) {
                                lastErr = ex;
                                Thread.Sleep(250);
                            } catch (UnauthorizedAccessException ex) {
                                lastErr = ex;
                                Thread.Sleep(250);
                            }
                        }
                        if (lastErr != null) throw lastErr;
                        if (onProgress != null) onProgress(idx, total, entry.Name);
                    }
                }
            }
        }

        internal static void LaunchAfterInstall(string targetDir, string afterMode) {
            string mode = NormalizeAfter(afterMode);
            if (mode == "none") return;

            string guiExe = Path.Combine(targetDir, "agent_mcp_app.exe");
            string cliExe = Path.Combine(targetDir, "agent-mcp.exe");

            if (mode == "gui" && File.Exists(guiExe)) {
                Process.Start(new ProcessStartInfo {
                    FileName = guiExe,
                    Arguments = "--show",
                    WorkingDirectory = targetDir,
                    UseShellExecute = true
                });
            } else if (mode == "tray" && File.Exists(guiExe)) {
                Process.Start(new ProcessStartInfo {
                    FileName = guiExe,
                    Arguments = "--silent",
                    WorkingDirectory = targetDir,
                    UseShellExecute = true
                });
            } else if (mode == "cli" && File.Exists(cliExe)) {
                Process.Start(new ProcessStartInfo {
                    FileName = "cmd.exe",
                    Arguments = "/k \"\"" + cliExe + "\" --version\"",
                    WorkingDirectory = targetDir,
                    UseShellExecute = true
                });
            }
        }

        internal static void CreateDesktopShortcut(string targetExe, string iconPath) {
            try {
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                string lnkPath = Path.Combine(desktop, "Agent MCP Console.lnk");
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                if (shellType == null) return;
                object shell = Activator.CreateInstance(shellType);
                object shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
                Type scType = shortcut.GetType();
                scType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { targetExe });
                scType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { Path.GetDirectoryName(targetExe) });
                scType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "Agent MCP Console" });
                if (File.Exists(iconPath)) {
                    scType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { iconPath });
                }
                scType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            } catch { }
        }

        private static int RunSilentInstall(InstallOptions opts) {
            try {
                if (opts.DelayMs > 0) Thread.Sleep(opts.DelayMs);
                bool isUpgrade;
                string targetDir = DetectExistingInstallDir(opts.ExplicitDir, out isUpgrade);
                var running = FindRunningInstances(targetDir);
                if (running.Count > 0) {
                    StopRunningInstances(running);
                }
                ExtractPayload(targetDir, null);
                SaveInstallRegistry(targetDir);
                if (opts.CreateShortcut && (!isUpgrade || opts.ShortcutExplicit)) {
                    string exePath = Path.Combine(targetDir, "agent_mcp_app.exe");
                    string icoPath = Path.Combine(targetDir, "app_icon.ico");
                    if (File.Exists(exePath)) CreateDesktopShortcut(exePath, icoPath);
                }
                LaunchAfterInstall(targetDir, opts.After);
                return 0;
            } catch {
                return 1;
            }
        }

        private static int RunCliInstall(InstallOptions opts) {
            try {
                Console.WriteLine("=== Agent MCP v" + AppVersion + " CLI Installer ===");
                bool isUpgrade;
                string targetDir = DetectExistingInstallDir(opts.ExplicitDir, out isUpgrade);
                Console.WriteLine("[1/4] Target directory: " + targetDir + (isUpgrade ? " (upgrade - preserving config/data/logs)" : " (fresh install)"));

                var running = FindRunningInstances(targetDir);
                if (running.Count > 0) {
                    Console.WriteLine("[2/4] Detected " + running.Count + " running Agent MCP instance(s).");
                    if (!opts.AutoConfirmClose) {
                        Console.Write("Close running instance(s) and continue? [Y/n]: ");
                        string ans = (Console.ReadLine() ?? "").Trim().ToLowerInvariant();
                        if (ans == "n" || ans == "no") {
                            Console.WriteLine("Aborted by user.");
                            return 2;
                        }
                    }
                    StopRunningInstances(running);
                    Console.WriteLine("      Stopped running instance(s).");
                } else {
                    Console.WriteLine("[2/4] No running instance detected.");
                }

                Console.WriteLine("[3/4] Extracting files...");
                ExtractPayload(targetDir, (cur, total, name) => {
                    if (cur == total || cur % 25 == 0) {
                        Console.WriteLine(string.Format("      ({0}/{1}) {2}", cur, total, name));
                    }
                });
                SaveInstallRegistry(targetDir);
                if (opts.CreateShortcut && (!isUpgrade || opts.ShortcutExplicit)) {
                    string exePath = Path.Combine(targetDir, "agent_mcp_app.exe");
                    string icoPath = Path.Combine(targetDir, "app_icon.ico");
                    if (File.Exists(exePath)) CreateDesktopShortcut(exePath, icoPath);
                }

                Console.WriteLine("[4/4] Install complete! Post-action: " + opts.After);
                if (opts.After == "cli") {
                    string cliExe = Path.Combine(targetDir, "agent-mcp.exe");
                    Console.WriteLine("CLI binary ready: " + cliExe);
                } else {
                    LaunchAfterInstall(targetDir, opts.After);
                }
                return 0;
            } catch (Exception ex) {
                Console.Error.WriteLine("[ERROR] " + ex.Message);
                return 1;
            }
        }
    }

    internal sealed class SfxForm : Form {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);

        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        private const int DWMWCP_ROUND = 2;
        private const int WM_NCLBUTTONDOWN = 0xA1;
        private const int HTCAPTION = 0x2;

        private readonly InstallOptions _opts;
        private readonly TextBox _pathBox;
        private readonly float _dpi;
        private bool _isDark;
        private bool _isUpgrade;
        private bool _createShortcut;
        private bool _launchAfter;
        private bool _installing;
        private float _progressRatio;
        private string _statusText = "\u51C6\u5907\u5C31\u7EEA \u00B7 \u514D UAC \u6388\u6743\u9759\u9ED8\u90E8\u7F72";

        private RectangleF _rcThemeBtn;
        private RectangleF _rcMinBtn;
        private RectangleF _rcCloseBtn;
        private RectangleF _rcCard;
        private RectangleF _rcPathWell;
        private RectangleF _rcBrowseBtn;
        private RectangleF _rcChkShortcut;
        private RectangleF _rcChkLaunch;
        private RectangleF _rcProgressTrack;
        private RectangleF _rcCancelBtn;
        private RectangleF _rcPrimaryBtn;
        private string _hoverId = "";

        public SfxForm(InstallOptions opts) {
            _opts = opts ?? new InstallOptions();
            _isDark = Program.DetectSystemDarkMode();
            string detectedDir = Program.DetectExistingInstallDir(_opts.ExplicitDir, out _isUpgrade);
            _createShortcut = _opts.ShortcutExplicit ? _opts.CreateShortcut : !_isUpgrade;
            _launchAfter = _opts.After != "none";

            SetStyle(
                ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.ResizeRedraw |
                ControlStyles.UserPaint,
                true
            );
            DoubleBuffered = true;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            Text = "Agent MCP v" + Program.AppVersion + " \u2014 Setup";
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            using (Graphics g = CreateGraphics()) {
                _dpi = g.DpiX > 0 ? g.DpiX / 96f : 1f;
            }
            ClientSize = new Size(S(568), S(388));

            _pathBox = new TextBox {
                BorderStyle = BorderStyle.None,
                Text = detectedDir,
                Font = new Font("Consolas", 9.6f, FontStyle.Regular)
            };
            _pathBox.TextChanged += (s, e) => {
                RefreshUpgradeState();
                Invalidate();
            };
            Controls.Add(_pathBox);

            ComputeLayout();
            ApplyThemeToChildControls();
            RefreshUpgradeState();
        }

        private int S(float v) { return (int)Math.Round(v * _dpi); }
        private float Sf(float v) { return v * _dpi; }

        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            ApplyDwmAttributes();
        }

        private void ApplyDwmAttributes() {
            try {
                int roundPref = DWMWCP_ROUND;
                DwmSetWindowAttribute(Handle, DWMWA_WINDOW_CORNER_PREFERENCE, ref roundPref, sizeof(int));
                int darkFlag = _isDark ? 1 : 0;
                DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkFlag, sizeof(int));
            } catch { }
        }

        private void ComputeLayout() {
            float w = ClientSize.Width;
            float pad = Sf(24);

            // Top-right window & theme pills
            _rcCloseBtn = new RectangleF(w - Sf(44), Sf(14), Sf(30), Sf(26));
            _rcMinBtn   = new RectangleF(w - Sf(78), Sf(14), Sf(30), Sf(26));
            _rcThemeBtn = new RectangleF(w - Sf(150), Sf(14), Sf(66), Sf(26));

            // Concentric main settings card (22px radius)
            _rcCard = new RectangleF(pad, Sf(88), w - pad * 2, Sf(194));

            // Inside card: path well (14px radius) + 999px Browse button
            float innerL = _rcCard.X + Sf(18);
            float innerR = _rcCard.Right - Sf(18);
            _rcBrowseBtn = new RectangleF(innerR - Sf(84), _rcCard.Y + Sf(46), Sf(84), Sf(36));
            _rcPathWell  = new RectangleF(innerL, _rcCard.Y + Sf(46), _rcBrowseBtn.X - innerL - Sf(8), Sf(36));

            _pathBox.Location = new Point((int)Math.Round(_rcPathWell.X + Sf(12)), (int)Math.Round(_rcPathWell.Y + (_rcPathWell.Height - _pathBox.PreferredHeight) * 0.5f));
            _pathBox.Width = Math.Max(80, (int)Math.Round(_rcPathWell.Width - Sf(24)));

            // Two tactile toggle rows inside card
            _rcChkShortcut = new RectangleF(innerL, _rcCard.Y + Sf(100), (innerR - innerL) * 0.46f, Sf(34));
            _rcChkLaunch   = new RectangleF(innerL + (innerR - innerL) * 0.48f, _rcCard.Y + Sf(100), (innerR - innerL) * 0.52f, Sf(34));

            // Capsule progress track inside card footer
            _rcProgressTrack = new RectangleF(innerL, _rcCard.Y + Sf(150), innerR - innerL, Sf(8));

            // Bottom action row (999px stadium capsules)
            float btnY = Sf(326);
            _rcPrimaryBtn = new RectangleF(w - pad - Sf(134), btnY, Sf(134), Sf(40));
            _rcCancelBtn  = new RectangleF(_rcPrimaryBtn.X - Sf(8) - Sf(88), btnY, Sf(88), Sf(40));
        }

        private void ApplyThemeToChildControls() {
            Color bg = _isDark ? Color.FromArgb(10, 10, 12) : Color.FromArgb(250, 250, 251);
            Color wellBg = _isDark ? Color.FromArgb(24, 24, 30) : Color.FromArgb(244, 244, 246);
            Color ink = _isDark ? Color.FromArgb(250, 250, 250) : Color.FromArgb(17, 17, 19);
            BackColor = bg;
            _pathBox.BackColor = wellBg;
            _pathBox.ForeColor = ink;
            ApplyDwmAttributes();
        }

        private void RefreshUpgradeState() {
            string dir = (_pathBox != null ? _pathBox.Text : "").Trim();
            _isUpgrade = !string.IsNullOrEmpty(dir) && File.Exists(Path.Combine(dir, "agent_mcp_app.exe"));
        }

        private static GraphicsPath RoundedRect(RectangleF r, float radius) {
            var path = new GraphicsPath();
            float d = Math.Min(radius * 2f, Math.Min(r.Width, r.Height));
            if (d <= 0.5f) {
                path.AddRectangle(r);
                return path;
            }
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        private static void DrawPrismIconBadge(Graphics g, RectangleF box) {
            // Squircle obsidian-indigo badge (#161838 -> #090A16) + Concentric Refracted Prism Rings
            float rad = box.Width * 0.28f;
            using (GraphicsPath sq = RoundedRect(box, rad))
            using (var bgBrush = new LinearGradientBrush(box, Color.FromArgb(22, 24, 56), Color.FromArgb(9, 10, 22), 45f)) {
                g.FillPath(bgBrush, sq);
                using (var auraPath = new GraphicsPath()) {
                    auraPath.AddEllipse(box.X + box.Width * 0.16f, box.Y + box.Height * 0.18f, box.Width * 0.92f, box.Height * 0.92f);
                    using (var pgb = new PathGradientBrush(auraPath)) {
                        pgb.CenterColor = Color.FromArgb(135, 79, 70, 229);
                        pgb.SurroundColors = new[] { Color.FromArgb(0, 79, 70, 229) };
                        g.SetClip(sq);
                        g.FillPath(pgb, auraPath);
                        g.ResetClip();
                    }
                }
                using (var rimPen = new Pen(Color.FromArgb(76, 165, 180, 252), 1f)) {
                    g.DrawPath(rimPen, sq);
                }
            }

            DrawRotatedPrismRing(
                g,
                new PointF(box.X + box.Width * 0.56f, box.Y + box.Height * 0.56f),
                box.Width * 0.22f,
                box.Width * 0.095f,
                Color.FromArgb(235, 129, 140, 248)
            );
            DrawRotatedPrismRing(
                g,
                new PointF(box.X + box.Width * 0.45f, box.Y + box.Height * 0.45f),
                box.Width * 0.235f,
                box.Width * 0.102f,
                Color.FromArgb(255, 255, 255, 255)
            );
        }

        private static void DrawRotatedPrismRing(Graphics g, PointF center, float halfOuter, float halfInner, Color fill) {
            GraphicsState st = g.Save();
            g.TranslateTransform(center.X, center.Y);
            g.RotateTransform(45f);
            using (GraphicsPath outer = RoundedRect(new RectangleF(-halfOuter, -halfOuter, halfOuter * 2f, halfOuter * 2f), halfOuter * 0.34f))
            using (GraphicsPath inner = RoundedRect(new RectangleF(-halfInner, -halfInner, halfInner * 2f, halfInner * 2f), halfInner * 0.36f)) {
                outer.FillMode = FillMode.Alternate;
                outer.AddPath(inner, false);
                using (var b = new SolidBrush(fill)) {
                    g.FillPath(b, outer);
                }
            }
            g.Restore(st);
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

            Color canvasBg = _isDark ? Color.FromArgb(10, 10, 12) : Color.FromArgb(250, 250, 251);
            Color cardBg   = _isDark ? Color.FromArgb(18, 18, 22) : Color.FromArgb(255, 255, 255);
            Color wellBg   = _isDark ? Color.FromArgb(24, 24, 30) : Color.FromArgb(244, 244, 246);
            Color hairline = _isDark ? Color.FromArgb(36, 255, 255, 255) : Color.FromArgb(24, 17, 17, 19);
            Color ink      = _isDark ? Color.FromArgb(250, 250, 250) : Color.FromArgb(17, 17, 19);
            Color muted    = _isDark ? Color.FromArgb(148, 148, 160) : Color.FromArgb(113, 113, 122);
            Color accent   = _isDark ? Color.FromArgb(129, 140, 248) : Color.FromArgb(79, 70, 229);
            Color accentHi = _isDark ? Color.FromArgb(165, 180, 252) : Color.FromArgb(67, 56, 202);
            Color accentBg = _isDark ? Color.FromArgb(34, 129, 140, 248) : Color.FromArgb(22, 79, 70, 229);

            g.Clear(canvasBg);

            // Subtle ambient Starlight Indigo top glow
            using (var glowPath = new GraphicsPath()) {
                glowPath.AddEllipse(-Sf(60), -Sf(120), ClientSize.Width + Sf(120), Sf(260));
                using (var pgb = new PathGradientBrush(glowPath)) {
                    pgb.CenterColor = _isDark ? Color.FromArgb(30, 99, 102, 241) : Color.FromArgb(18, 79, 70, 229);
                    pgb.SurroundColors = new[] { Color.FromArgb(0, 79, 70, 229) };
                    g.FillPath(pgb, glowPath);
                }
            }

            // Top-right Theme Toggle Pill + Minimize & Close Capsules
            using (GraphicsPath tp = RoundedRect(_rcThemeBtn, _rcThemeBtn.Height * 0.5f))
            using (var tb = new SolidBrush(_hoverId == "theme" ? accentBg : (_isDark ? Color.FromArgb(22, 255, 255, 255) : Color.FromArgb(14, 17, 17, 19))))
            using (var tpen = new Pen(hairline, 1f))
            using (var tf = new Font("Microsoft YaHei UI", 8.2f, FontStyle.Regular)) {
                g.FillPath(tb, tp);
                g.DrawPath(tpen, tp);
                var sfCenter = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                using (var fb = new SolidBrush(ink)) {
                    g.DrawString(_isDark ? "\u263E \u6697\u8272" : "\u2600 \u6D45\u8272", tf, fb, _rcThemeBtn, sfCenter);
                }
            }

            DrawCaptionButton(g, _rcMinBtn, "\u2014", _hoverId == "min", false, _isDark, muted, ink);
            DrawCaptionButton(g, _rcCloseBtn, "\u00D7", _hoverId == "close", true, _isDark, muted, ink);

            // Brand Header: Concentric Prism Icon + Title + Version Pill + Subtitle
            var iconRect = new RectangleF(Sf(24), Sf(22), Sf(44), Sf(44));
            DrawPrismIconBadge(g, iconRect);

            using (var titleFont = new Font("Microsoft YaHei UI", 13.5f, FontStyle.Bold))
            using (var subFont = new Font("Microsoft YaHei UI", 8.8f, FontStyle.Regular))
            using (var badgeFont = new Font("Consolas", 8.5f, FontStyle.Bold))
            using (var inkBrush = new SolidBrush(ink))
            using (var mutedBrush = new SolidBrush(muted))
            using (var accentBrush = new SolidBrush(accent))
            using (var accentBgBrush = new SolidBrush(accentBg)) {
                string titleStr = "Agent MCP Console";
                float titleX = Sf(80);
                float titleY = Sf(22);
                g.DrawString(titleStr, titleFont, inkBrush, titleX, titleY);
                SizeF tSz = g.MeasureString(titleStr, titleFont);

                string verStr = "v" + Program.AppVersion;
                SizeF vSz = g.MeasureString(verStr, badgeFont);
                var verRect = new RectangleF(titleX + tSz.Width + Sf(6), titleY + Sf(3), vSz.Width + Sf(14), Sf(20));
                using (GraphicsPath vp = RoundedRect(verRect, verRect.Height * 0.5f)) {
                    g.FillPath(accentBgBrush, vp);
                }
                var sfC = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(verStr, badgeFont, accentBrush, verRect, sfC);

                g.DrawString(
                    "\u514D UAC \u6388\u6743\u4E00\u952E\u5B89\u88C5\u4E0E\u65E0\u635F\u5347\u7EA7 \u00B7 \u5B8C\u6574\u4FDD\u7559 config / data / logs",
                    subFont,
                    mutedBrush,
                    titleX,
                    Sf(48)
                );
            }

            // Concentric Main Card (22px radius)
            using (GraphicsPath cardPath = RoundedRect(_rcCard, Sf(22)))
            using (var cb = new SolidBrush(cardBg))
            using (var cpen = new Pen(hairline, 1f)) {
                g.FillPath(cb, cardPath);
                g.DrawPath(cpen, cardPath);
            }

            // Card Row 1: Caption + Upgrade/Fresh Pill
            using (var capFont = new Font("Microsoft YaHei UI", 9.0f, FontStyle.Bold))
            using (var tagFont = new Font("Microsoft YaHei UI", 8.2f, FontStyle.Regular))
            using (var inkBrush = new SolidBrush(ink))
            using (var accentBrush = new SolidBrush(accent))
            using (var accentBgBrush = new SolidBrush(accentBg)) {
                g.DrawString("\u5B89\u88C5\u76EE\u6807\u76EE\u5F55", capFont, inkBrush, _rcPathWell.X, _rcCard.Y + Sf(17));

                string modeTag = _isUpgrade
                    ? "\u5DF2\u8BC6\u522B\u73B0\u6709\u7248\u672C \u00B7 \u65E0\u635F\u8986\u76D6\u5347\u7EA7"
                    : "\u5168\u65B0\u514D\u6388\u6743\u5B89\u88C5";
                SizeF mSz = g.MeasureString(modeTag, tagFont);
                var mRect = new RectangleF(_rcBrowseBtn.Right - mSz.Width - Sf(16), _rcCard.Y + Sf(15), mSz.Width + Sf(16), Sf(21));
                using (GraphicsPath mp = RoundedRect(mRect, mRect.Height * 0.5f)) {
                    g.FillPath(accentBgBrush, mp);
                }
                var sfC = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(modeTag, tagFont, accentBrush, mRect, sfC);
            }

            // Path Well (14px radius) + 999px Browse Button
            using (GraphicsPath wp = RoundedRect(_rcPathWell, Sf(13)))
            using (var wb = new SolidBrush(wellBg))
            using (var wpen = new Pen(_pathBox.Focused ? accent : hairline, 1f)) {
                g.FillPath(wb, wp);
                g.DrawPath(wpen, wp);
            }

            DrawCapsuleButton(
                g,
                _rcBrowseBtn,
                "\u6D4F\u89C8...",
                false,
                _hoverId == "browse" && !_installing,
                _isDark,
                ink,
                hairline,
                accent,
                accentHi
            );

            // Custom Concentric Check Pills
            DrawCheckOption(g, _rcChkShortcut, "\u521B\u5EFA\u684C\u9762\u5FEB\u6377\u65B9\u5F0F", _createShortcut, _hoverId == "chk1", _isDark, ink, muted, hairline, accent);
            DrawCheckOption(g, _rcChkLaunch, "\u5B89\u88C5\u540E\u7ACB\u5373\u6253\u5F00\u4E3B\u754C\u9762", _launchAfter, _hoverId == "chk2", _isDark, ink, muted, hairline, accent);

            // Stadium Progress Track & Fill + Status Line
            using (GraphicsPath trk = RoundedRect(_rcProgressTrack, _rcProgressTrack.Height * 0.5f))
            using (var trkBrush = new SolidBrush(wellBg)) {
                g.FillPath(trkBrush, trk);
                float ratio = Math.Max(0f, Math.Min(1f, _progressRatio));
                if (ratio > 0.005f) {
                    float fillW = Math.Max(_rcProgressTrack.Height, _rcProgressTrack.Width * ratio);
                    var fillRect = new RectangleF(_rcProgressTrack.X, _rcProgressTrack.Y, fillW, _rcProgressTrack.Height);
                    using (GraphicsPath fp = RoundedRect(fillRect, _rcProgressTrack.Height * 0.5f))
                    using (var fb = new LinearGradientBrush(fillRect, accent, Color.FromArgb(99, 102, 241), 0f)) {
                        g.FillPath(fb, fp);
                    }
                }
            }

            using (var stFont = new Font("Microsoft YaHei UI", 8.3f, FontStyle.Regular))
            using (var mutedBrush = new SolidBrush(muted)) {
                g.DrawString(_statusText, stFont, mutedBrush, _rcProgressTrack.X, _rcProgressTrack.Bottom + Sf(8));
            }

            // Footer Caption + 999px Cancel & Primary Sculpted Indigo Capsules
            using (var footFont = new Font("Consolas", 8.2f, FontStyle.Regular))
            using (var mutedBrush = new SolidBrush(muted)) {
                g.DrawString("Zero-UAC \u00B7 GUI + Web + CLI", footFont, mutedBrush, Sf(26), _rcPrimaryBtn.Y + Sf(12));
            }

            DrawCapsuleButton(
                g,
                _rcCancelBtn,
                "\u53D6\u6D88",
                false,
                _hoverId == "cancel" && !_installing,
                _isDark,
                ink,
                hairline,
                accent,
                accentHi
            );

            DrawCapsuleButton(
                g,
                _rcPrimaryBtn,
                _installing ? "\u6B63\u5728\u90E8\u7F72..." : (_isUpgrade ? "\u7ACB\u5373\u65E0\u635F\u5347\u7EA7" : "\u7ACB\u5373\u5B89\u88C5"),
                true,
                _hoverId == "primary" && !_installing,
                _isDark,
                ink,
                hairline,
                accent,
                accentHi
            );

            // Outer window 1px hairline border
            using (var winPen = new Pen(hairline, 1f)) {
                g.DrawRectangle(winPen, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
            }
        }

        private void DrawCaptionButton(Graphics g, RectangleF r, string sym, bool hovered, bool isClose, bool isDark, Color muted, Color ink) {
            if (hovered) {
                Color bg = isClose
                    ? Color.FromArgb(220, 38, 38)
                    : (isDark ? Color.FromArgb(28, 255, 255, 255) : Color.FromArgb(18, 17, 17, 19));
                using (GraphicsPath p = RoundedRect(r, r.Height * 0.5f))
                using (var b = new SolidBrush(bg)) {
                    g.FillPath(b, p);
                }
            }
            Color fg = (hovered && isClose) ? Color.White : (hovered ? ink : muted);
            using (var f = new Font("Segoe UI", 9.8f, FontStyle.Regular))
            using (var b = new SolidBrush(fg)) {
                var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(sym, f, b, r, sf);
            }
        }

        private void DrawCheckOption(
            Graphics g,
            RectangleF r,
            string label,
            bool isChecked,
            bool hovered,
            bool isDark,
            Color ink,
            Color muted,
            Color hairline,
            Color accent
        ) {
            if (hovered && !_installing) {
                using (GraphicsPath hp = RoundedRect(r, Sf(10)))
                using (var hb = new SolidBrush(isDark ? Color.FromArgb(18, 255, 255, 255) : Color.FromArgb(10, 17, 17, 19))) {
                    g.FillPath(hb, hp);
                }
            }
            float boxSz = Sf(18);
            var chkRect = new RectangleF(r.X + Sf(6), r.Y + (r.Height - boxSz) * 0.5f, boxSz, boxSz);
            using (GraphicsPath cp = RoundedRect(chkRect, Sf(6))) {
                if (isChecked) {
                    using (var b = new SolidBrush(accent)) {
                        g.FillPath(b, cp);
                    }
                    using (var pen = new Pen(isDark ? Color.FromArgb(10, 10, 12) : Color.White, Sf(1.9f))) {
                        pen.StartCap = LineCap.Round;
                        pen.EndCap = LineCap.Round;
                        pen.LineJoin = LineJoin.Round;
                        g.DrawLines(pen, new[] {
                            new PointF(chkRect.X + boxSz * 0.25f, chkRect.Y + boxSz * 0.52f),
                            new PointF(chkRect.X + boxSz * 0.44f, chkRect.Y + boxSz * 0.71f),
                            new PointF(chkRect.X + boxSz * 0.76f, chkRect.Y + boxSz * 0.31f)
                        });
                    }
                } else {
                    using (var pen = new Pen(hairline, 1.2f)) {
                        g.DrawPath(pen, cp);
                    }
                }
            }
            using (var f = new Font("Microsoft YaHei UI", 8.8f, FontStyle.Regular))
            using (var b = new SolidBrush(isChecked ? ink : muted)) {
                var textRect = new RectangleF(chkRect.Right + Sf(8), r.Y, r.Width - boxSz - Sf(16), r.Height);
                var sf = new StringFormat { Alignment = StringAlignment.Near, LineAlignment = StringAlignment.Center };
                g.DrawString(label, f, b, textRect, sf);
            }
        }

        private static void DrawCapsuleButton(
            Graphics g,
            RectangleF r,
            string text,
            bool primary,
            bool hovered,
            bool isDark,
            Color ink,
            Color hairline,
            Color accent,
            Color accentHi
        ) {
            using (GraphicsPath path = RoundedRect(r, r.Height * 0.5f)) {
                if (primary) {
                    Color cTop = hovered ? accentHi : accent;
                    Color cBot = isDark ? Color.FromArgb(99, 102, 241) : Color.FromArgb(67, 56, 202);
                    using (var br = new LinearGradientBrush(r, cTop, cBot, 90f)) {
                        g.FillPath(br, path);
                    }
                    // Inner top specular rim
                    using (var specPen = new Pen(Color.FromArgb(68, 255, 255, 255), 1f)) {
                        g.DrawPath(specPen, path);
                    }
                    using (var f = new Font("Microsoft YaHei UI", 9.2f, FontStyle.Bold))
                    using (var tb = new SolidBrush(isDark ? Color.FromArgb(10, 10, 14) : Color.White)) {
                        var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                        g.DrawString(text, f, tb, r, sf);
                    }
                } else {
                    Color bg = hovered
                        ? (isDark ? Color.FromArgb(32, 255, 255, 255) : Color.FromArgb(236, 236, 240))
                        : (isDark ? Color.FromArgb(22, 255, 255, 255) : Color.FromArgb(244, 244, 246));
                    using (var br = new SolidBrush(bg))
                    using (var pen = new Pen(hairline, 1f)) {
                        g.FillPath(br, path);
                        g.DrawPath(pen, path);
                    }
                    using (var f = new Font("Microsoft YaHei UI", 9.0f, FontStyle.Regular))
                    using (var tb = new SolidBrush(ink)) {
                        var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                        g.DrawString(text, f, tb, r, sf);
                    }
                }
            }
        }

        private string HitTestControl(Point p) {
            if (_rcCloseBtn.Contains(p)) return "close";
            if (_rcMinBtn.Contains(p)) return "min";
            if (_rcThemeBtn.Contains(p)) return "theme";
            if (_rcBrowseBtn.Contains(p)) return "browse";
            if (_rcChkShortcut.Contains(p)) return "chk1";
            if (_rcChkLaunch.Contains(p)) return "chk2";
            if (_rcCancelBtn.Contains(p)) return "cancel";
            if (_rcPrimaryBtn.Contains(p)) return "primary";
            return "";
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            string hit = HitTestControl(e.Location);
            if (hit != _hoverId) {
                _hoverId = hit;
                Cursor = string.IsNullOrEmpty(hit) ? Cursors.Default : Cursors.Hand;
                Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e) {
            base.OnMouseLeave(e);
            if (_hoverId != "") {
                _hoverId = "";
                Cursor = Cursors.Default;
                Invalidate();
            }
        }

        protected override async void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            string hit = HitTestControl(e.Location);
            if (string.IsNullOrEmpty(hit)) {
                if (e.Y < Sf(84) || !_rcCard.Contains(e.Location)) {
                    ReleaseCapture();
                    SendMessage(Handle, WM_NCLBUTTONDOWN, HTCAPTION, 0);
                }
                return;
            }
            if (hit == "close" || hit == "cancel") {
                if (!_installing) Close();
                return;
            }
            if (hit == "min") {
                WindowState = FormWindowState.Minimized;
                return;
            }
            if (hit == "theme") {
                _isDark = !_isDark;
                ApplyThemeToChildControls();
                Invalidate();
                return;
            }
            if (_installing) return;

            if (hit == "chk1") {
                _createShortcut = !_createShortcut;
                Invalidate();
            } else if (hit == "chk2") {
                _launchAfter = !_launchAfter;
                Invalidate();
            } else if (hit == "browse") {
                using (var dlg = new FolderBrowserDialog()) {
                    dlg.SelectedPath = _pathBox.Text;
                    dlg.Description = "Agent MCP Console";
                    if (dlg.ShowDialog(this) == DialogResult.OK) {
                        _pathBox.Text = dlg.SelectedPath;
                        RefreshUpgradeState();
                        Invalidate();
                    }
                }
            } else if (hit == "primary") {
                await RunExtractAsync();
            }
        }

        private async Task RunExtractAsync() {
            string targetDir = _pathBox.Text.Trim();
            if (string.IsNullOrEmpty(targetDir)) {
                MessageBox.Show(this, "\u8BF7\u9009\u62E9\u6709\u6548\u7684\u76EE\u6807\u76EE\u5F55\u3002", "\u63D0\u793A", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var running = Program.FindRunningInstances(targetDir);
            if (running.Count > 0 && !_opts.AutoConfirmClose) {
                var pidList = new List<string>();
                foreach (var p in running) pidList.Add(p.Id.ToString());
                string prompt = string.Format(
                    "\u68C0\u6D4B\u5230 Agent MCP \u6B63\u5728\u8FD0\u884C\uFF08PID {0}\uFF09\u3002\n\n\u662F\u5426\u5E73\u6ED1\u5173\u95ED\u5F53\u524D\u5B9E\u4F8B\u5E76\u7EE7\u7EED\u8986\u76D6\u5B89\u88C5\uFF1F\n\u60A8\u7684\u914D\u7F6E\u6587\u4EF6\u3001\u6570\u636E\u4E0E\u65E5\u5FD7\u5C06\u88AB\u5B8C\u6574\u4FDD\u7559\u3002",
                    string.Join(", ", pidList.ToArray())
                );
                DialogResult dr = MessageBox.Show(
                    this,
                    prompt,
                    "\u5173\u95ED\u8FD0\u884C\u4E2D\u7684\u5B9E\u4F8B",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question
                );
                if (dr != DialogResult.Yes) return;
            }

            _installing = true;
            _pathBox.ReadOnly = true;
            _progressRatio = 0.02f;
            Invalidate();

            try {
                if (running.Count > 0) {
                    _statusText = "\u6B63\u5728\u5E73\u6ED1\u505C\u6B62\u8FD0\u884C\u4E2D\u7684\u5B9E\u4F8B...";
                    Invalidate();
                    await Task.Run(() => Program.StopRunningInstances(running));
                }

                await Task.Run(() => {
                    Program.ExtractPayload(targetDir, (cur, total, name) => {
                        BeginInvoke((Action)(() => {
                            int safeTotal = Math.Max(total, 1);
                            _progressRatio = (float)cur / safeTotal;
                            int pct = (int)Math.Round(_progressRatio * 100f);
                            _statusText = string.Format("\u6B63\u5728\u90E8\u7F72 ({0}%) \u00B7 {1}", pct, name);
                            Invalidate();
                        }));
                    });
                });

                Program.SaveInstallRegistry(targetDir);
                string exePath = Path.Combine(targetDir, "agent_mcp_app.exe");
                string icoPath = Path.Combine(targetDir, "app_icon.ico");
                if (_createShortcut && File.Exists(exePath)) {
                    Program.CreateDesktopShortcut(exePath, icoPath);
                }
                _progressRatio = 1f;
                _statusText = "\u90E8\u7F72\u5B8C\u6210\uFF01";
                Invalidate();

                if (_launchAfter) {
                    string afterMode = (_opts.After == "none") ? "gui" : _opts.After;
                    Program.LaunchAfterInstall(targetDir, afterMode);
                }
                Close();
            } catch (Exception ex) {
                MessageBox.Show(this, "\u5B89\u88C5\u5931\u8D25\uFF1A\n" + ex.Message, "\u9519\u8BEF", MessageBoxButtons.OK, MessageBoxIcon.Error);
                _installing = false;
                _pathBox.ReadOnly = false;
                Invalidate();
            }
        }
    }
}
'@

$asmVer = if ($Version -match '^\d+\.\d+\.\d+$') { "$Version.0" } else { "3.4.1.0" }
$renderedCs = $csSource.Replace('AssemblyVersion("3.4.1.0")', "AssemblyVersion(`"$asmVer`")").Replace('__APP_VERSION__', $Version)
[System.IO.File]::WriteAllText($csFile, $renderedCs, (New-Object System.Text.UTF8Encoding($true)))
if (Test-Path $sfxOutPath) { Remove-Item -Force $sfxOutPath }

& $csc /nologo /target:winexe /optimize+ `
    "/out:$sfxOutPath" `
    "/win32icon:$iconPath" `
    "/resource:$zipOutPath,AgentMCP.payload.zip" `
    /r:System.dll `
    /r:System.Drawing.dll `
    /r:System.Windows.Forms.dll `
    /r:System.IO.Compression.dll `
    /r:System.IO.Compression.FileSystem.dll `
    $csFile

if ($LASTEXITCODE -ne 0) {
    throw "csc.exe failed with exit code $LASTEXITCODE"
}

Write-Host "[4/4] Cleaning temporary staging files..." -ForegroundColor Cyan
Remove-Item -Force $csFile -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $stageRoot -ErrorAction SilentlyContinue

$zipMb = [math]::Round((Get-Item $zipOutPath).Length / 1MB, 2)
$sfxMb = [math]::Round((Get-Item $sfxOutPath).Length / 1MB, 2)
Write-Host "[OK] Clean Portable ZIP : $zipOutPath ($zipMb MB)" -ForegroundColor Green
Write-Host "[OK] Smart Installer EXE: $sfxOutPath ($sfxMb MB)" -ForegroundColor Green
