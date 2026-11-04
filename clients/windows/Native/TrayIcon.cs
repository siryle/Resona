using System.Runtime.InteropServices;

namespace Resona.Windows.Native;

/// <summary>
/// Win32 system-tray icon with a dedicated message-only window. It re-adds the
/// icon after Explorer restarts (TaskbarCreated) and offers a minimal context menu.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    public event Action? OpenRequested;
    public event Action? ExitRequested;

    private const string ClassName = "ResonaTrayIconWindow";
    private const uint NIM_ADD = 0x00000000;
    private const uint NIM_MODIFY = 0x00000001;
    private const uint NIM_DELETE = 0x00000002;
    private const uint NIF_MESSAGE = 0x00000001;
    private const uint NIF_ICON = 0x00000002;
    private const uint NIF_TIP = 0x00000004;
    private const uint WM_COMMAND = 0x0111;
    private const uint WM_NULL = 0x0000;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONUP = 0x0205;
    private const uint TRAY_CALLBACK = 0x8000 + 1;
    private const uint TRAY_EXIT = 0x8000 + 2;
    private const uint TRAY_UPDATE = 0x8000 + 3;
    private const uint MENU_OPEN = 1001;
    private const uint MENU_EXIT = 1002;

    private readonly ManualResetEventSlim _ready = new();
    private Thread? _thread;
    private IntPtr _hwnd;
    private IntPtr _icon;
    private WndProc? _wndProc;
    private uint _taskbarCreated;
    private string _tooltip = "Resona";

    public void Start()
    {
        if (_thread is not null)
        {
            return;
        }

        _icon = LoadIcon(IntPtr.Zero, new IntPtr(32512));
        _thread = new Thread(MessageLoop)
        {
            IsBackground = true,
            Name = "ResonaTray",
        };
        _thread.Start();
        _ready.Wait();
    }

    public void UpdateTooltip(string text)
    {
        _tooltip = string.IsNullOrEmpty(text) ? "Resona" : text;
        if (_hwnd != IntPtr.Zero)
        {
            PostMessage(_hwnd, TRAY_UPDATE, IntPtr.Zero, IntPtr.Zero);
        }
    }

    public void Dispose()
    {
        if (_thread is null)
        {
            return;
        }

        PostMessage(_hwnd, TRAY_EXIT, IntPtr.Zero, IntPtr.Zero);
        if (!_thread.Join(TimeSpan.FromSeconds(2)))
        {
            return;
        }

        _thread = null;
        _hwnd = IntPtr.Zero;
        _ready.Reset();
    }

    private void MessageLoop()
    {
        _wndProc = HandleMessage;
        var instance = GetModuleHandle(null);
        var windowClass = new WindowClass
        {
            Size = (uint)Marshal.SizeOf<WindowClass>(),
            WindowProc = _wndProc,
            Instance = instance,
            ClassName = ClassName,
        };

        if (RegisterClassEx(ref windowClass) == 0)
        {
            _ready.Set();
            return;
        }

        _hwnd = CreateWindowEx(
            0,
            ClassName,
            string.Empty,
            0,
            0, 0, 0, 0,
            new IntPtr(-3),
            IntPtr.Zero,
            instance,
            IntPtr.Zero);
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        if (_icon == IntPtr.Zero)
        {
            _icon = LoadIcon(IntPtr.Zero, new IntPtr(32512));
        }
        AddOrUpdateIcon(NIM_ADD);
        _ready.Set();

        while (GetMessage(out var message, IntPtr.Zero, 0, 0))
        {
            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }

        UnregisterClass(ClassName, instance);
    }

    private IntPtr HandleMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == TRAY_CALLBACK)
        {
            var lowWord = unchecked((int)(lParam.ToInt64() & 0xFFFF));
            if (lowWord == WM_LBUTTONUP)
            {
                OpenRequested?.Invoke();
            }
            else if (lowWord == WM_RBUTTONUP)
            {
                ShowContextMenu();
            }
            return IntPtr.Zero;
        }

        if (message == WM_COMMAND)
        {
            var command = unchecked((uint)(wParam.ToInt64() & 0xFFFF));
            if (command == MENU_OPEN)
            {
                OpenRequested?.Invoke();
            }
            else if (command == MENU_EXIT)
            {
                ExitRequested?.Invoke();
            }
            return IntPtr.Zero;
        }

        if (message == _taskbarCreated)
        {
            AddOrUpdateIcon(NIM_ADD);
            return IntPtr.Zero;
        }

        if (message == TRAY_UPDATE)
        {
            AddOrUpdateIcon(NIM_MODIFY);
            return IntPtr.Zero;
        }

        if (message == TRAY_EXIT)
        {
            AddOrUpdateIcon(NIM_DELETE);
            DestroyWindow(hwnd);
            PostQuitMessage(0);
            return IntPtr.Zero;
        }

        return DefWindowProc(hwnd, message, wParam, lParam);
    }

    private void AddOrUpdateIcon(uint action)
    {
        var data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(),
            Window = _hwnd,
            Id = 1,
            Flags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            CallbackMessage = TRAY_CALLBACK,
            Icon = _icon,
            Tip = _tooltip,
        };
        Shell_NotifyIcon(action, ref data);
    }

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero)
        {
            return;
        }

        AppendMenu(menu, 0x00000000, new IntPtr(MENU_OPEN), "打开 Resona");
        AppendMenu(menu, 0x00000800, IntPtr.Zero, null);
        AppendMenu(menu, 0x00000000, new IntPtr(MENU_EXIT), "退出 Resona");
        GetCursorPos(out var point);
        SetForegroundWindow(_hwnd);
        TrackPopupMenu(menu, 0x0002 | 0x0020, point.X, point.Y, 0, _hwnd, IntPtr.Zero);
        PostMessage(_hwnd, WM_NULL, IntPtr.Zero, IntPtr.Zero);
        DestroyMenu(menu);
    }

    private delegate IntPtr WndProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint Size;
        public uint Style;
        [MarshalAs(UnmanagedType.FunctionPtr)]
        public WndProc WindowProc;
        public int ClassExtra;
        public int WindowExtra;
        public IntPtr Instance;
        public IntPtr Icon;
        public IntPtr Cursor;
        public IntPtr Background;
        public string MenuName;
        public string ClassName;
        public IntPtr SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public IntPtr Handle;
        public uint Value;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public Point Point;
    }

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassEx(ref WindowClass windowClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        uint extendedStyle,
        string className,
        string windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        IntPtr parent,
        IntPtr menu,
        IntPtr instance,
        IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int exitCode);

    [DllImport("user32.dll")]
    private static extern bool GetMessage(out Message message, IntPtr hwnd, uint min, uint max);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref Message message);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref Message message);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool UnregisterClass(string className, IntPtr instance);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenu(IntPtr menu, uint flags, IntPtr id, string? text);

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr hwnd, IntPtr rect);

    [DllImport("user32.dll")]
    private static extern IntPtr LoadIcon(IntPtr instance, IntPtr iconName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? moduleName);
}
