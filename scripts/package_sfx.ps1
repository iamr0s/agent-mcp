param(
    [switch]$SkipBuild,
    [string]$Version = "2.3.0"
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

# Copy ONLY pure compilation outputs (never dist\windows which holds live user config/logs)
Copy-Item -Recurse -Force (Join-Path $winReleaseDir "*") $stageRoot
Copy-Item -Force $cliBinPath (Join-Path $stageRoot "agent-mcp.exe")
Copy-Item -Force $iconPath (Join-Path $stageRoot "app_icon.ico")
Copy-Item -Recurse -Force $webBuildDir (Join-Path $stageRoot "web_dashboard")

# Strict sanitization & audit: guarantee zero personal configs, tokens, state, or logs
$forbiddenRelPaths = @(
    "config",
    "logs",
    "bin",
    "data\cache",
    "data\oauth_state.json",
    "data\window_state.json",
    "data\tunnel_state.json"
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

Write-Host "[3/4] Compiling standalone GUI Self-Extracting Archive ($sfxOutPath)..." -ForegroundColor Cyan
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
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("Agent MCP Self-Extracting Setup")]
[assembly: AssemblyProduct("Agent MCP Console")]
[assembly: AssemblyVersion("2.3.0.0")]

namespace AgentMcpSfx {
    internal static class Program {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [STAThread]
        private static int Main(string[] args) {
            for (int i = 0; i < args.Length; i++) {
                if ((args[i] == "--extract-to" || args[i] == "-o") && i + 1 < args.Length) {
                    string target = Path.GetFullPath(args[i + 1]);
                    ExtractPayload(target, null);
                    return 0;
                }
            }

            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SfxForm());
            return 0;
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
                        entry.ExtractToFile(dst, true);
                        if (onProgress != null) onProgress(idx, total, entry.Name);
                    }
                }
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
    }

    internal sealed class SfxForm : Form {
        private readonly TextBox _pathBox;
        private readonly Button _browseBtn;
        private readonly CheckBox _shortcutChk;
        private readonly CheckBox _launchChk;
        private readonly ProgressBar _bar;
        private readonly Label _statusLbl;
        private readonly Button _extractBtn;
        private readonly Button _cancelBtn;

        public SfxForm() {
            // "Agent MCP v2.0 — 便携自解压向导"
            Text = "Agent MCP v2.0 \u2014 \u4FBF\u643A\u81EA\u89E3\u538B\u5411\u5BFC";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            BackColor = Color.FromArgb(245, 244, 237);
            ForeColor = Color.FromArgb(20, 20, 19);
            Font = new Font("Microsoft YaHei UI", 9.5F, FontStyle.Regular);
            ClientSize = new Size(520, 285);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            var titleLbl = new Label {
                Text = "Agent MCP Console v2.0",
                Font = new Font("Georgia", 15F, FontStyle.Bold),
                ForeColor = Color.FromArgb(20, 20, 19),
                AutoSize = true,
                Location = new Point(24, 20)
            };
            // "纯净免安装便携包（不含任何旧配置与密钥，解压即用）"
            var subLbl = new Label {
                Text = "\u7EAF\u51C0\u514D\u5B89\u88C5\u4FBF\u643A\u5305\uFF08\u4E0D\u542B\u4EFB\u4F55\u65E7\u914D\u7F6E\u4E0E\u5BC6\u94A5\uFF0C\u89E3\u538B\u5373\u7528\uFF09",
                ForeColor = Color.FromArgb(115, 114, 108),
                AutoSize = true,
                Location = new Point(26, 52)
            };

            // "解压目标文件夹："
            var dirCaption = new Label {
                Text = "\u89E3\u538B\u76EE\u6807\u6587\u4EF6\u5939\uFF1A",
                AutoSize = true,
                Location = new Point(26, 86)
            };

            string defaultDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs",
                "AgentMCP"
            );
            _pathBox = new TextBox {
                Text = defaultDir,
                Location = new Point(26, 110),
                Size = new Size(382, 27)
            };
            // "浏览..."
            _browseBtn = new Button {
                Text = "\u6D4F\u89C8...",
                Location = new Point(416, 108),
                Size = new Size(80, 29),
                BackColor = Color.FromArgb(250, 249, 245),
                FlatStyle = FlatStyle.System
            };
            _browseBtn.Click += (s, e) => {
                using (var dlg = new FolderBrowserDialog()) {
                    dlg.SelectedPath = _pathBox.Text;
                    dlg.Description = "Agent MCP";
                    if (dlg.ShowDialog(this) == DialogResult.OK) {
                        _pathBox.Text = dlg.SelectedPath;
                    }
                }
            };

            // "创建桌面快捷方式"
            _shortcutChk = new CheckBox {
                Text = "\u521B\u5EFA\u684C\u9762\u5FEB\u6377\u65B9\u5F0F",
                Checked = true,
                AutoSize = true,
                Location = new Point(26, 150)
            };
            // "解压完成后立即启动 Agent MCP"
            _launchChk = new CheckBox {
                Text = "\u89E3\u538B\u5B8C\u6210\u540E\u7ACB\u5373\u542F\u52A8 Agent MCP",
                Checked = true,
                AutoSize = true,
                Location = new Point(210, 150)
            };

            _bar = new ProgressBar {
                Location = new Point(26, 186),
                Size = new Size(470, 16),
                Style = ProgressBarStyle.Continuous,
                Visible = false
            };
            // "准备就绪"
            _statusLbl = new Label {
                Text = "\u51C6\u5907\u5C31\u7EEA",
                ForeColor = Color.FromArgb(115, 114, 108),
                AutoSize = true,
                Location = new Point(26, 208)
            };

            // "立即解压"
            _extractBtn = new Button {
                Text = "\u7ACB\u5373\u89E3\u538B",
                Location = new Point(300, 234),
                Size = new Size(102, 34),
                BackColor = Color.FromArgb(201, 100, 66),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat
            };
            _extractBtn.FlatAppearance.BorderSize = 0;
            _extractBtn.Click += async (s, e) => await RunExtractAsync();

            // "取消"
            _cancelBtn = new Button {
                Text = "\u53D6\u6D88",
                Location = new Point(410, 234),
                Size = new Size(86, 34),
                FlatStyle = FlatStyle.System
            };
            _cancelBtn.Click += (s, e) => Close();

            Controls.AddRange(new Control[] {
                titleLbl, subLbl, dirCaption, _pathBox, _browseBtn,
                _shortcutChk, _launchChk, _bar, _statusLbl, _extractBtn, _cancelBtn
            });
        }

        private async Task RunExtractAsync() {
            string targetDir = _pathBox.Text.Trim();
            if (string.IsNullOrEmpty(targetDir)) {
                MessageBox.Show(this, "\u8BF7\u9009\u62E9\u6709\u6548\u7684\u76EE\u6807\u76EE\u5F55\u3002", "\u63D0\u793A", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            _extractBtn.Enabled = false;
            _browseBtn.Enabled = false;
            _pathBox.ReadOnly = true;
            _bar.Visible = true;
            _bar.Value = 0;

            try {
                await Task.Run(() => {
                    Program.ExtractPayload(targetDir, (cur, total, name) => {
                        BeginInvoke((Action)(() => {
                            _bar.Maximum = Math.Max(total, 1);
                            _bar.Value = Math.Min(cur, _bar.Maximum);
                            _statusLbl.Text = string.Format("\u6B63\u5728\u89E3\u538B ({0}/{1}): {2}", cur, total, name);
                        }));
                    });
                });

                string exePath = Path.Combine(targetDir, "agent_mcp_app.exe");
                string icoPath = Path.Combine(targetDir, "app_icon.ico");
                if (_shortcutChk.Checked && File.Exists(exePath)) {
                    Program.CreateDesktopShortcut(exePath, icoPath);
                }
                _statusLbl.Text = "\u89E3\u538B\u5B8C\u6210\uFF01";

                if (_launchChk.Checked && File.Exists(exePath)) {
                    Process.Start(new ProcessStartInfo {
                        FileName = exePath,
                        WorkingDirectory = targetDir,
                        UseShellExecute = true
                    });
                }
                Close();
            } catch (Exception ex) {
                MessageBox.Show(this, "\u89E3\u538B\u5931\u8D25\uFF1A\n" + ex.Message, "\u9519\u8BEF", MessageBoxButtons.OK, MessageBoxIcon.Error);
                _extractBtn.Enabled = true;
                _browseBtn.Enabled = true;
                _pathBox.ReadOnly = false;
            }
        }
    }
}
'@

$asmVer = if ($Version -match '^\d+\.\d+\.\d+$') { "$Version.0" } else { "2.3.0.0" }
[System.IO.File]::WriteAllText($csFile, $csSource.Replace('AssemblyVersion("2.3.0.0")', "AssemblyVersion(`"$asmVer`")"), (New-Object System.Text.UTF8Encoding($true)))
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
Write-Host "[OK] Self-Extracting EXE: $sfxOutPath ($sfxMb MB)" -ForegroundColor Green
