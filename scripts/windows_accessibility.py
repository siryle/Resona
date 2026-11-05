"""Query the test process through MSAA so its native AXTree is exercised."""
import ctypes
from ctypes import wintypes
import subprocess
import time
import uuid


def query_accessibility(process_id):
    user32 = ctypes.WinDLL('user32')
    oleacc = ctypes.WinDLL('oleacc')
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    user32.EnumChildWindows.argtypes = [wintypes.HWND, callback_type, wintypes.LPARAM]
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    iid = (ctypes.c_byte * 16).from_buffer_copy(
        uuid.UUID('618736e0-3c3d-11cf-810c-00aa00389b71').bytes_le,
    )
    oleacc.AccessibleObjectFromWindow.argtypes = [
        wintypes.HWND, wintypes.DWORD, ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    observed = False

    @callback_type
    def visit_child(window, _):
        nonlocal observed
        name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(window, name, len(name))
        if name.value != 'FLUTTERVIEW':
            return True
        accessible = ctypes.c_void_p()
        status = oleacc.AccessibleObjectFromWindow(window, 0xfffffffc, iid,
                                                   ctypes.byref(accessible))
        if status == 0 and accessible:
            table = ctypes.cast(
                accessible, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)),
            ).contents
            release = ctypes.WINFUNCTYPE(wintypes.ULONG, ctypes.c_void_p)(table[2])
            child_count = ctypes.WINFUNCTYPE(
                wintypes.LONG, ctypes.c_void_p, ctypes.POINTER(wintypes.LONG),
            )(table[8])
            count = wintypes.LONG()
            try:
                observed |= child_count(accessible, ctypes.byref(count)) == 0 and count.value > 0
            finally:
                release(accessible)
        return True

    @callback_type
    def visit_window(window, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(window, ctypes.byref(owner))
        if owner.value == process_id:
            user32.EnumChildWindows(window, visit_child, 0)
        return True

    user32.EnumWindows(visit_window, 0)
    return observed


def run_accessibility_smoke(executable, directory):
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    ole32 = ctypes.OleDLL('ole32')
    ole32.CoInitializeEx(None, 2)
    try:
        with subprocess.Popen(
            [str(executable)], cwd=directory, startupinfo=startup,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding='utf-8', errors='replace',
        ) as process:
            observed = False
            deadline = time.monotonic() + 90
            try:
                while True:
                    observed |= query_accessibility(process.pid)
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(str(executable), 90)
                    try:
                        output, _ = process.communicate(timeout=min(0.25, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        continue
            except BaseException:
                process.kill()
                process.communicate()
                raise
            print(output)
            if (process.returncode or not observed or
                    'Windows accessibility smoke checks passed.' not in output or
                    'accessibility_bridge.cc' in output):
                raise SystemExit('Native Windows accessibility regression checks failed.')
            print('Verified the native MSAA tree with an accessibility client attached.')
    finally:
        ole32.CoUninitialize()
