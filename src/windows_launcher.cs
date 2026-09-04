using System;
using System.IO;
using System.Net;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace BiscuitLauncher
{
    static class Program
    {
        const int SW_HIDE = 0;
        const int SW_SHOWMINIMIZED = 2;
        const uint WM_SETICON = 0x0080;
        const int ICON_SMALL = 0;
        const int ICON_BIG = 1;
        const uint IMAGE_ICON = 1;
        const uint LR_LOADFROMFILE = 0x0010;
        const uint LR_DEFAULTSIZE = 0x0040;
        const uint MB_ICONERROR = 0x00000010;
        const int CTRL_C_EVENT = 0;
        const int CTRL_BREAK_EVENT = 1;
        const int CTRL_CLOSE_EVENT = 2;
        const int CTRL_LOGOFF_EVENT = 5;
        const int CTRL_SHUTDOWN_EVENT = 6;

        static Process serverProcess;
        static string workspacePath;
        static string logFile;
        static string appDir;
        static ConsoleCtrlHandler ctrlHandler;

        delegate bool ConsoleCtrlHandler(int ctrlType);

        [STAThread]
        static void Main(string[] args)
        {
            try
            {
                SetCurrentProcessExplicitAppUserModelID("com.biscuit.app");
            }
            catch { }

            try { Application.EnableVisualStyles(); } catch { }
            try { Application.SetCompatibleTextRenderingDefault(false); } catch { }

            appDir = AppDomain.CurrentDomain.BaseDirectory;
            string homeDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string configDir = Path.Combine(homeDir, ".config", "biscuit");
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

                workspacePath = PickFolder("Select your Biscuit course workspace folder", lastDir);
                if (string.IsNullOrEmpty(workspacePath) || !Directory.Exists(workspacePath))
                    return;
            }

            try { File.WriteAllText(lastWsFile, workspacePath); } catch { }

            if (!AllocConsole())
            {
                NativeMessageBox("Could not create the Biscuit server console window.", "Biscuit Error");
                return;
            }

            try { Console.Title = "Biscuit"; } catch { }
            ApplyConsoleIcon();
            ctrlHandler = OnConsoleCtrl;
            SetConsoleCtrlHandler(ctrlHandler, true);

            RotateLogIfNeeded();
            WriteLogHeader();
            WriteBanner();

            IntPtr hwnd = GetConsoleWindow();
            if (hwnd != IntPtr.Zero)
                ShowWindow(hwnd, SW_SHOWMINIMIZED);

            if (!StartServerProcess())
                return;

            Thread pollThread = new Thread(PollServerAndOpenBrowser);
            pollThread.IsBackground = true;
            pollThread.Start();

            try { serverProcess.WaitForExit(); }
            catch { }
        }

        static string PickFolder(string title, string initialPath)
        {
            try
            {
                using (FolderBrowserDialog dialog = new FolderBrowserDialog())
                {
                    dialog.Description = title;
                    dialog.ShowNewFolderButton = true;
                    if (!string.IsNullOrEmpty(initialPath) && Directory.Exists(initialPath))
                        dialog.SelectedPath = initialPath;
                    if (dialog.ShowDialog() != DialogResult.OK)
                        return null;
                    return dialog.SelectedPath;
                }
            }
            catch (Exception ex)
            {
                NativeMessageBox("Could not open the folder picker.\n\n" + ex.Message, "Biscuit Error");
                return null;
            }
        }

        static void ApplyConsoleIcon()
        {
            string icoPath = Path.Combine(appDir, "Resources", "Biscuit.ico");
            if (!File.Exists(icoPath))
                icoPath = Path.Combine(appDir, "Resources", "public", "favicon.ico");
            if (!File.Exists(icoPath))
                return;

            IntPtr hwnd = GetConsoleWindow();
            if (hwnd == IntPtr.Zero)
                return;

            IntPtr icon = LoadImage(IntPtr.Zero, icoPath, IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
            if (icon == IntPtr.Zero)
                return;

            SendMessage(hwnd, WM_SETICON, new IntPtr(ICON_SMALL), icon);
            SendMessage(hwnd, WM_SETICON, new IntPtr(ICON_BIG), icon);
        }

        static void RotateLogIfNeeded()
        {
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
        }

        static void WriteLogHeader()
        {
            string header = string.Format(
                "\r\n============================================================\r\n  Biscuit started at {0:yyyy-MM-dd HH:mm:ss}\r\n  Workspace: {1}\r\n  URL:       http://127.0.0.1:8080\r\n============================================================\r\n",
                DateTime.Now, workspacePath);
            try { File.AppendAllText(logFile, header); } catch { }
        }

        static void WriteBanner()
        {
            try
            {
                Console.WriteLine("============================================================");
                Console.WriteLine("  Biscuit");
                Console.WriteLine("  Workspace: " + workspacePath);
                Console.WriteLine("  URL:       http://127.0.0.1:8080");
                Console.WriteLine("  Close this window to stop the server.");
                Console.WriteLine("============================================================");
                Console.WriteLine("Starting backend...");
            }
            catch { }
        }

        static bool StartServerProcess()
        {
            string backendExe = Path.Combine(appDir, "app", "bin", "biscuit-server.exe");
            if (!File.Exists(backendExe))
                backendExe = Path.Combine(appDir, "app", "bin", "Biscuit.exe");
            if (!File.Exists(backendExe))
            {
                NativeMessageBox("Biscuit backend executable not found at:\n" + backendExe, "Biscuit Error");
                return false;
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = backendExe;
            psi.WorkingDirectory = workspacePath;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardInput = true;

            string resBin = Path.Combine(appDir, "Resources", "bin");
            string appBin = Path.Combine(appDir, "app", "bin");
            string appLib = Path.Combine(appDir, "app", "lib");
            string resLib = Path.Combine(appDir, "Resources", "lib");
            string currentPath = Environment.GetEnvironmentVariable("PATH") ?? "";
            psi.EnvironmentVariables["PATH"] = resBin + ";" + appBin + ";" + appLib + ";" + resLib + ";" + currentPath;

            serverProcess = new Process();
            serverProcess.StartInfo = psi;
            serverProcess.EnableRaisingEvents = true;
            serverProcess.OutputDataReceived += (s, e) => TeeLine(e.Data);
            serverProcess.ErrorDataReceived += (s, e) => TeeLine(e.Data);

            try
            {
                serverProcess.Start();
                serverProcess.BeginOutputReadLine();
                serverProcess.BeginErrorReadLine();
                return true;
            }
            catch (Exception ex)
            {
                NativeMessageBox("Failed to launch Biscuit backend:\n" + ex.Message, "Biscuit Error");
                return false;
            }
        }

        static void TeeLine(string line)
        {
            if (string.IsNullOrEmpty(line))
                return;
            try { Console.WriteLine(line); } catch { }
            try { File.AppendAllText(logFile, line + "\r\n"); } catch { }
        }

        static void PollServerAndOpenBrowser()
        {
            string url = "http://127.0.0.1:8080/";
            for (int i = 0; i < 300; i++)
            {
                if (serverProcess == null || serverProcess.HasExited)
                    return;
                try
                {
                    HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                    req.Method = "GET";
                    req.Timeout = 400;
                    req.ReadWriteTimeout = 400;
                    using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                    {
                        int code = (int)resp.StatusCode;
                        if (code >= 200 && code < 500)
                        {
                            OpenWebUi();
                            return;
                        }
                    }
                }
                catch (WebException ex)
                {
                    HttpWebResponse resp = ex.Response as HttpWebResponse;
                    if (resp != null && (int)resp.StatusCode < 500)
                    {
                        OpenWebUi();
                        return;
                    }
                }
                catch { }
                Thread.Sleep(200);
            }
        }

        static void OpenWebUi()
        {
            try
            {
                Process.Start(new ProcessStartInfo("http://127.0.0.1:8080") { UseShellExecute = true });
            }
            catch { }
        }

        static bool OnConsoleCtrl(int ctrlType)
        {
            if (ctrlType == CTRL_C_EVENT || ctrlType == CTRL_BREAK_EVENT ||
                ctrlType == CTRL_CLOSE_EVENT || ctrlType == CTRL_LOGOFF_EVENT ||
                ctrlType == CTRL_SHUTDOWN_EVENT)
            {
                KillServer();
            }
            return false;
        }

        static void KillServer()
        {
            if (serverProcess == null || serverProcess.HasExited)
                return;
            try
            {
                serverProcess.Kill();
                serverProcess.WaitForExit(3000);
            }
            catch { }
        }

        static void NativeMessageBox(string text, string caption)
        {
            MessageBoxW(IntPtr.Zero, text, caption, MB_ICONERROR);
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AllocConsole();

        [DllImport("kernel32.dll")]
        static extern IntPtr GetConsoleWindow();

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);

        [DllImport("user32.dll")]
        static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        [DllImport("user32.dll")]
        static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadImage(IntPtr hInst, string name, uint type, int cx, int cy, uint fuLoad);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern void SetCurrentProcessExplicitAppUserModelID(string appID);
    }
}
