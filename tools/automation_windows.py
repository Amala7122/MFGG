"""Hide only the launched automation process's windows from the user's desktop.

Windows are cloaked through DWM as soon as they appear, so the game keeps
rendering as a normal window while the user never sees it. No activation and no
repeated focus correction. Godot's no_focus project setting must already be
applied before launch.
"""
from __future__ import annotations

import os
import threading
import time


class BackgroundWindows:
    def __init__(self, process_id: int, enabled: bool):
        self.process_id = process_id
        self.enabled = enabled and os.name == "nt"
        self.placements: list[dict] = []
        self.errors: list[str] = []
        self._stop = threading.Event()
        self._thread = None
        if self.enabled:
            self._thread = threading.Thread(target=self._monitor, daemon=True)
            self._thread.start()

    def close(self) -> dict:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        return {"enabled": self.enabled, "placements": self.placements, "errors": self.errors}

    def _monitor(self) -> None:
        try:
            self._monitor_windows()
        except Exception as error:
            self.errors.append(str(error))

    def _monitor_windows(self) -> None:
        import ctypes
        from ctypes import wintypes as w

        user = ctypes.WinDLL("user32", use_last_error=True)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        dwm = ctypes.WinDLL("dwmapi")
        dwm.DwmSetWindowAttribute.argtypes = [w.HWND, w.DWORD, ctypes.c_void_p, w.DWORD]
        dwm.DwmSetWindowAttribute.restype = ctypes.c_long
        callback_type = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        user.EnumWindows.argtypes = [callback_type, w.LPARAM]
        user.EnumWindows.restype = w.BOOL
        user.IsWindowVisible.argtypes = [w.HWND]
        user.IsWindow.argtypes = [w.HWND]
        user.GetWindowThreadProcessId.argtypes = [w.HWND, ctypes.POINTER(w.DWORD)]
        user.GetForegroundWindow.restype = w.HWND
        user.GetWindow.argtypes = [w.HWND, w.UINT]
        user.GetWindow.restype = w.HWND
        user.SetWindowPos.argtypes = [w.HWND, w.HWND, ctypes.c_int, ctypes.c_int,
                                      ctypes.c_int, ctypes.c_int, w.UINT]
        user.SetWindowPos.restype = w.BOOL
        user.ShowWindow.argtypes = [w.HWND, ctypes.c_int]
        user.ShowWindow.restype = w.BOOL

        class ProcessEntry(ctypes.Structure):
            _fields_ = [("dwSize", w.DWORD), ("cntUsage", w.DWORD),
                        ("th32ProcessID", w.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                        ("th32ModuleID", w.DWORD), ("cntThreads", w.DWORD),
                        ("th32ParentProcessID", w.DWORD), ("pcPriClassBase", w.LONG),
                        ("dwFlags", w.DWORD), ("szExeFile", w.WCHAR * 260)]

        kernel.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
        kernel.CreateToolhelp32Snapshot.restype = w.HANDLE
        for name in ("Process32FirstW", "Process32NextW"):
            function = getattr(kernel, name)
            function.argtypes = [w.HANDLE, ctypes.POINTER(ProcessEntry)]
            function.restype = w.BOOL
        kernel.CloseHandle.argtypes = [w.HANDLE]

        def descendants() -> set[int]:
            handle = kernel.CreateToolhelp32Snapshot(2, 0)
            if handle == ctypes.c_void_p(-1).value:
                raise ctypes.WinError(ctypes.get_last_error())
            parents = {}
            entry = ProcessEntry()
            entry.dwSize = ctypes.sizeof(entry)
            try:
                more = kernel.Process32FirstW(handle, ctypes.byref(entry))
                while more:
                    parents[entry.th32ProcessID] = entry.th32ParentProcessID
                    more = kernel.Process32NextW(handle, ctypes.byref(entry))
            finally:
                kernel.CloseHandle(handle)
            owned = {self.process_id}
            while True:
                expanded = owned | {pid for pid, parent in parents.items() if parent in owned}
                if expanded == owned:
                    return owned
                owned = expanded

        seen = set()
        owned = {self.process_id}
        refreshed = 0.0

        @callback_type
        def place(window, _):
            if not user.IsWindowVisible(window):
                return True
            pid = w.DWORD()
            user.GetWindowThreadProcessId(window, ctypes.byref(pid))
            identity = (int(window), pid.value)
            if pid.value not in owned or identity in seen:
                return True
            seen.add(identity)
            # 首次发现先藏起来，压到最底层，再以 SW_SHOWNOACTIVATE 显示：
            # 不在用户界面前闪一下，也不抢前台；窗口保持正常可见以维持渲染性能。
            hidden = bool(user.ShowWindow(window, 0))  # SW_HIDE
            foreground = user.GetForegroundWindow()
            # HWND_BOTTOM; NOMOVE | NOSIZE | NOACTIVATE | NOOWNERZORDER.
            success = bool(user.SetWindowPos(window, 1, 0, 0, 0, 0, 0x213))
            if not success and user.IsWindow(window):
                self.errors.append(f"SetWindowPos({pid.value}): {ctypes.get_last_error()}")
            shown = bool(user.ShowWindow(window, 4))  # SW_SHOWNOACTIVATE
            behind = False
            cursor = foreground
            while cursor:
                if cursor == window:
                    behind = cursor != foreground
                    break
                cursor = user.GetWindow(cursor, 2)  # GW_HWNDNEXT
            self.placements.append({"pid": pid.value, "window": int(window),
                                    "hidden": hidden, "shown_no_activate": shown,
                                    "placed": success, "foreground": foreground,
                                    "behind_foreground": behind})
            return True

        while not self._stop.is_set():
            now = time.monotonic()
            if now - refreshed >= 0.25:
                owned = descendants()
                refreshed = now
            user.EnumWindows(place, 0)
            self._stop.wait(0.01)
