using System.Runtime.InteropServices;

namespace Resona.Windows.Native;

/// <summary>
/// Always-on-top desktop lyrics window implemented with a Win32 layered window.
/// Locking makes it click-through; dragging is supported when unlocked.
/// </summary>
public sealed class DesktopLyricsWindow : IDisposable
{
    private const string ClassName = "ResonaDesktopLyricsWindow";
    private const uint WS_POPUP = 0x80000000;
    private const int WS_EX_LAYERED = 0x00080000;
    private const int WS_EX_TOPMOST = 0x00000008;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int GWL_EXSTYLE = -20;
    private const uint WM_PAINT = 0x000F;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_NCLBUTTONDOWN = 0x00A1;
    private const int HTCAPTION = 2;
    private const uint SW_SHOWNOACTIVATE = 4;
    private const uint SW_HIDE = 0;
    private const int LWA_COLORKEY = 1;
    private const uint WM_SET_LYRIC = 0x8000 + 10;
    private const uint WM_SET_VISIBLE = 0x8000 + 11;
    private const uint WM_SET_LOCKED = 0x8000 + 12;
    private const uint WM_SET_FONT = 0x8000 + 13;
    private const uint WM_EXIT = 0x8000 + 14;
    private const uint SPI_GETWORKAREA = 0x0030;

    private readonly ManualResetEventSlim _ready = new();
    private Thread? _thread;
    private IntPtr _hwnd;
    private WndProc? _proc;
    private string _lyric = "Resona · 此刻想听什么？";
    private bool _visible;
    private bool _locked;
    private int _fontSize = 28;
    private int _x;
    private int _y;
    private bool _positioned;

    public void Start()
    {
        if (_thread is not null)
        {
            return;
        }

        _thread = new Thread(MessageLoop)
        {
            IsBackground = true,
            Name = "ResonaDesktopLyrics",
        };
        _thread.Start();
        _ready.Wait();
    }

    public void SetLyric(string text)
    {
        _lyric = string.IsNullOrWhiteSpace(text) ? "Resona · 此刻想听什么？" : text;
        Post(WM_SET_LYRIC);
    }

    public void SetVisible(bool visible)
    {
        _visible = visible;
        Post(WM_SET_VISIBLE);
    }

    public void SetLocked(bool locked)
    {
        _locked = locked;
        Post(WM_SET_LOCKED);
    }

    public void SetFontSize(int size)
    {
        _fontSize = Math.Clamp(size, 18, 48);
        Post(WM_SET_FONT);
    }

    public void Dispose()
    {
        if (_thread is null)
        {
            return;
        }

        PostMessage(_hwnd, WM_EXIT, IntPtr.Zero, IntPtr.Zero);
        _thread.Join(TimeSpan.FromSeconds(2));
        _thread = null;
        _hwnd = IntPtr.Zero;
        _ready.Reset();
    }

    private void Post(uint message) => PostMessage(_hwnd, message, IntPtr.Zero, IntPtr.Zero);

    private void MessageLoop()
    {
        _proc = HandleMessage;
        var instance = GetModuleHandle(null);
        var windowClass = new WindowClass
        {
            Size = (uint)Marshal.SizeOf<WindowClass>(),
            WindowProc = _proc,
            Instance = instance,
            Background = GetStockObject(4),
            ClassName = ClassName,
        };
        if (RegisterClassEx(ref windowClass) == 0)
        {
            _ready.Set();
            return;
        }

        _hwnd = CreateWindowEx(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            ClassName,
            string.Empty,
            WS_POPUP,
            0, 0, 400, 80,
            IntPtr.Zero,
            IntPtr.Zero,
            instance,
            IntPtr.Zero);
        SetLayeredWindowAttributes(_hwnd, 0, 0, LWA_COLORKEY);
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
        switch (message)
        {
            case WM_PAINT:
                Paint(hwnd);
                return IntPtr.Zero;

            case WM_SET_LYRIC:
                ResizeAndPlace();
                InvalidateRect(hwnd, IntPtr.Zero, true);
                return IntPtr.Zero;

            case WM_SET_VISIBLE:
                ShowWindow(hwnd, _visible ? SW_SHOWNOACTIVATE : SW_HIDE);
                if (_visible)
                {
                    ResizeAndPlace();
                }
                return IntPtr.Zero;

            case WM_SET_LOCKED:
                ApplyLock();
                return IntPtr.Zero;

            case WM_SET_FONT:
                ResizeAndPlace();
                InvalidateRect(hwnd, IntPtr.Zero, true);
                return IntPtr.Zero;

            case WM_EXIT:
                DestroyWindow(hwnd);
                PostQuitMessage(0);
                return IntPtr.Zero;

            case WM_LBUTTONDOWN:
                if (!_locked)
                {
                    ReleaseCapture();
                    SendMessage(hwnd, WM_NCLBUTTONDOWN, new IntPtr(HTCAPTION), IntPtr.Zero);
                }
                return IntPtr.Zero;
        }

        return DefWindowProc(hwnd, message, wParam, lParam);
    }

    private void ApplyLock()
    {
        var style = GetWindowLongPtr(_hwnd, GWL_EXSTYLE).ToInt64();
        style = _locked
            ? style | WS_EX_TRANSPARENT
            : style & ~WS_EX_TRANSPARENT;
        SetWindowLongPtr(_hwnd, GWL_EXSTYLE, new IntPtr(style));
    }

    private void ResizeAndPlace()
    {
        var bounds = Measure(_lyric);
        var width = Math.Min(bounds.Width + 48, 1200);
        var height = bounds.Height + 24;
        if (!_positioned)
        {
            GetWorkArea(out var work);
            _x = work.Left + (work.Right - work.Left - width) / 2;
            _y = work.Bottom - height - 80;
            _positioned = true;
        }
        else
        {
            GetWorkArea(out var work);
            _x = Math.Clamp(_x, work.Left, work.Right - width);
            _y = Math.Clamp(_y, work.Top, work.Bottom - height);
        }

        SetWindowPos(_hwnd, IntPtr.Zero, _x, _y, width, height, 0x0010 | 0x0040);
    }

    private Rect Measure(string text)
    {
        var hdc = GetDC(_hwnd);
        var font = CreateFont(
            -MulDiv(_fontSize, GetDeviceCaps(hdc, 90), 72),
            0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, "Segoe UI");
        var previous = SelectObject(hdc, font);
        var rect = new Rect();
        DrawText(hdc, text, -1, ref rect, 0x0400 | 0x0004 | 0x0020);
        SelectObject(hdc, previous);
        DeleteObject(font);
        ReleaseDC(_hwnd, hdc);
        return rect;
    }

    private void Paint(IntPtr hwnd)
    {
        BeginPaint(hwnd, out var paint);
        var hdc = paint.Hdc;
        SetBkMode(hdc, 1);
        SetTextColor(hdc, 0x00FFFFFF);
        var font = CreateFont(
            -MulDiv(_fontSize, GetDeviceCaps(hdc, 90), 72),
            0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, "Segoe UI");
        var previous = SelectObject(hdc, font);
        GetClientRect(hwnd, out var client);
        DrawText(hdc, _lyric, -1, ref client, 0x0001 | 0x0004 | 0x0020);
        SelectObject(hdc, previous);
        DeleteObject(font);
        EndPaint(hwnd, ref paint);
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

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
        public int Width => Right - Left;
        public int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PaintStruct
    {
        public IntPtr Hdc;
        public int Erase;
        public Rect Paint;
        public int Restore;
        public int IncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] RgbReserved;
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

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassEx(ref WindowClass windowClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        int extendedStyle,
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
    private static extern bool UnregisterClass(string className, IntPtr instance);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, uint command);

    [DllImport("user32.dll")]
    private static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint colorKey, byte alpha, int flags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool InvalidateRect(IntPtr hwnd, IntPtr rect, bool erase);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern bool SystemParametersInfo(uint action, uint parameter, out Rect rect, uint flag);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hwnd, out Rect rect);

    [DllImport("user32.dll")]
    private static extern IntPtr BeginPaint(IntPtr hwnd, out PaintStruct paint);

    [DllImport("user32.dll")]
    private static extern bool EndPaint(IntPtr hwnd, ref PaintStruct paint);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFont(
        int height,
        int width,
        int escapement,
        int orientation,
        int weight,
        uint italic,
        uint underline,
        uint strikeOut,
        uint charSet,
        uint outputPrecision,
        uint clipPrecision,
        uint quality,
        uint pitchAndFamily,
        string faceName);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hdc, IntPtr handle);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr handle);

    [DllImport("gdi32.dll")]
    private static extern int SetBkMode(IntPtr hdc, int mode);

    [DllImport("gdi32.dll")]
    private static extern uint SetTextColor(IntPtr hdc, uint color);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int DrawText(IntPtr hdc, string text, int length, ref Rect rect, uint format);

    [DllImport("gdi32.dll")]
    private static extern int GetDeviceCaps(IntPtr hdc, int index);

    [DllImport("gdi32.dll")]
    private static extern IntPtr GetStockObject(int index);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    private static int MulDiv(int number, int numerator, int denominator) => (int)((long)number * numerator / denominator);

    private void GetWorkArea(out Rect rect) => SystemParametersInfo(SPI_GETWORKAREA, 0, out rect, 0);
}
