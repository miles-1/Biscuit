using System;
using System.IO;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using System.Net.Http;
using System.Threading.Tasks;

namespace BiscuitLauncher
{
    static class Program
    {
        private static NotifyIcon trayIcon;
        private static Process serverProcess;
        private static string workspacePath;
        private static string configDir;
        private static string logFile;
        private static string appDir;

        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            appDir = AppDomain.CurrentDomain.BaseDirectory;
            string homeDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            configDir = Path.Combine(homeDir, ".config", "biscuit");
            string lastWsFile = Path.Combine(configDir, "last_workspace.txt");
            logFile = Path.Combine(configDir, "biscuit.log");

            Directory.CreateDirectory(configDir);

            if (args.Length > 0 && Directory.Exists(args[0]))
            {
                workspacePath = Path.GetFullPath(args[0]);
            }
            else
            {
                string lastDir = "";
                if (File.Exists(lastWsFile))
                {
                    try { lastDir = File.ReadAllText(lastWsFile).Trim(); } catch { }
                }

                using (FolderBrowserDialog fbd = new FolderBrowserDialog())
                {
                    fbd.Description = "Select your Biscuit course workspace folder:";
                    fbd.ShowNewFolderButton = true;
                    if (!string.IsNullOrEmpty(lastDir) && Directory.Exists(lastDir))
                    {
                        fbd.SelectedPath = lastDir;
                    }

                    if (fbd.ShowDialog() == DialogResult.OK && !string.IsNullOrEmpty(fbd.SelectedPath))
                    {
                        workspacePath = fbd.SelectedPath;
                    }
                    else
                    {
                        return;
                    }
                }
            }

            try { File.WriteAllText(lastWsFile, workspacePath); } catch { }

            SetupTrayIcon();
        static void SetupTrayIcon()
        {
            trayIcon = new NotifyIcon();
            trayIcon.Text = "Biscuit Assignment Server";

            string icoPath = Path.Combine(appDir, "Resources", "Biscuit.ico");
            if (!File.Exists(icoPath))
                icoPath = Path.Combine(appDir, "Resources", "public", "favicon.ico");

            if (File.Exists(icoPath))
            {
                try { trayIcon.Icon = new Icon(icoPath); } catch { trayIcon.Icon = SystemIcons.Application; }
            }
            else
            {
                trayIcon.Icon = SystemIcons.Application;
            }

            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem itemOpenUi = new ToolStripMenuItem("Open Biscuit Web UI", null, (s, e) => OpenWebUi());
            itemOpenUi.Font = new Font(itemOpenUi.Font, FontStyle.Bold);

            ToolStripMenuItem itemOpenWorkspace = new ToolStripMenuItem("Open Course Workspace Folder", null, (s, e) => OpenWorkspaceFolder());
            ToolStripMenuItem itemViewLogs = new ToolStripMenuItem("View Server Logs", null, (s, e) => ViewLogs());
            ToolStripSeparator sep = new ToolStripSeparator();
            ToolStripMenuItem itemExit = new ToolStripMenuItem("Exit Biscuit", null, (s, e) => ExitApplication());

            menu.Items.Add(itemOpenUi);
            menu.Items.Add(itemOpenWorkspace);
            menu.Items.Add(itemViewLogs);
            menu.Items.Add(sep);
            menu.Items.Add(itemExit);

            trayIcon.ContextMenuStrip = menu;
            trayIcon.DoubleClick += (s, e) => OpenWebUi();
            trayIcon.Visible = true;
        }

        static void StartServerProcess()
        {
            string backendExe = Path.Combine(appDir, "app", "bin", "Biscuit.exe");
            if (!File.Exists(backendExe))
            {
                MessageBox.Show("Biscuit backend executable not found at:\n" + backendExe, "Biscuit Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                ExitApplication();
                return;
            }

            try
            {
                if (File.Exists(logFile) && new FileInfo(logFile).Length > 5 * 1024 * 1024)
                {
                    string[] lines = File.ReadAllLines(logFile);
                    if (lines.Length > 5000)
                    {
                        string[] recent = new string[5000];
                        Array.Copy(lines, lines.Length - 5000, recent, 0, 5000);
                        File.WriteAllLines(logFile, recent);
                    }
                }
            }
            catch { }

            try
            {
                string header = string.Format("\r\n============================================================\r\n  Biscuit started at {0:yyyy-MM-dd HH:mm:ss}\r\n  Workspace: {1}\r\n  URL:       http://127.0.0.1:8080\r\n============================================================\r\n", DateTime.Now, workspacePath);
                File.AppendAllText(logFile, header);
            }
            catch { }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = backendExe;
            psi.WorkingDirectory = workspacePath;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;

            string resBin = Path.Combine(appDir, "Resources", "bin");
            string appBin = Path.Combine(appDir, "app", "bin");
            string currentPath = Environment.GetEnvironmentVariable("PATH") ?? "";
            psi.EnvironmentVariables["PATH"] = resBin + ";" + appBin + ";" + currentPath;

            serverProcess = new Process();
            serverProcess.StartInfo = psi;

            serverProcess.OutputDataReceived += (s, e) =>
            {
                if (!string.IsNullOrEmpty(e.Data))
                {
                    try { File.AppendAllText(logFile, e.Data + "\r\n"); } catch { }
                }
            };
            serverProcess.ErrorDataReceived += (s, e) =>
            {
                if (!string.IsNullOrEmpty(e.Data))
                {
                    try { File.AppendAllText(logFile, e.Data + "\r\n"); } catch { }
                }
            };

            try
            {
                serverProcess.Start();
                serverProcess.BeginOutputReadLine();
                serverProcess.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                MessageBox.Show("Failed to launch Biscuit backend:\n" + ex.Message, "Biscuit Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                ExitApplication();
            }
        }

        static async void PollServerAndOpenBrowser()
        {
            string url = "http://127.0.0.1:8080/";
            using (HttpClient client = new HttpClient())
            {
                client.Timeout = TimeSpan.FromMilliseconds(400);
                for (int i = 0; i < 300; i++)
                {
                    if (serverProcess == null || serverProcess.HasExited)
                        break;

                    try
                    {
                        HttpResponseMessage resp = await client.GetAsync(url);
                        if ((int)resp.StatusCode >= 200 && (int)resp.StatusCode < 500)
                        {
                            OpenWebUi();
                            if (trayIcon != null)
                            {
                                trayIcon.ShowBalloonTip(3000, "Biscuit Ready", "Running on http://127.0.0.1:8080", ToolTipIcon.Info);
                            }
                            break;
                        }
                    }
                    catch { }

                    await Task.Delay(200);
                }
            }
        }

        static void OpenWebUi()
        {
            try { Process.Start(new ProcessStartInfo("http://127.0.0.1:8080") { UseShellExecute = true }); } catch { }
        }

        static void OpenWorkspaceFolder()
        {
            if (!string.IsNullOrEmpty(workspacePath) && Directory.Exists(workspacePath))
            {
                try { Process.Start(new ProcessStartInfo("explorer.exe", workspacePath) { UseShellExecute = true }); } catch { }
            }
        }

        static void ViewLogs()
        {
            if (File.Exists(logFile))
            {
                try { Process.Start(new ProcessStartInfo("notepad.exe", logFile) { UseShellExecute = true }); } catch { }
            }
        }

        static void ExitApplication()
        {
            if (serverProcess != null && !serverProcess.HasExited)
            {
                try
                {
                    serverProcess.Kill();
                    serverProcess.WaitForExit(3000);
                }
                catch { }
            }

            if (trayIcon != null)
            {
                trayIcon.Visible = false;
                trayIcon.Dispose();
            }

            Application.Exit();
            Environment.Exit(0);
        }
    }
}
