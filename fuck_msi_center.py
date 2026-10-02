"""Fuck-MSI-Center: MSI MUX, GPU offsets, system controls and battery limits.

The GUI is intentionally a thin process/JSON client.  Firmware, Registry, and
GPU writes live in guarded PowerShell APIs and are never retried automatically.
An optional, default-off checkbox can run the normal Windows shutdown command
after a MUX request is accepted; its warning is included in the single switch
confirmation for that request.
"""

from __future__ import annotations

import ctypes
import datetime as dt
import json
import locale
import math
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk
from typing import Any, Callable


APP_NAME = "Fuck-MSI-Center"
SCRIPT_PATH = Path(__file__).resolve()
APP_DIR = SCRIPT_PATH.parent
PROJECT_ROOT = APP_DIR
BACKEND_DIR = APP_DIR / "backend"
API_CLI = BACKEND_DIR / "Invoke-FuckMsiCenter.ps1"
AP_PROBE = BACKEND_DIR / "Read-MsiGpuSwitchRequestState.ps1"
OC_API_MODULE = BACKEND_DIR / "MsiGpuOcApi.psd1"
SYSTEM_API_MODULE = BACKEND_DIR / "MsiSystemControlApi.psd1"
DIRECT_API_MODULE = BACKEND_DIR / "MsiDirectHardwareApi.psd1"
POWERSHELL = (
    Path(os.environ.get("SystemRoot", r"C:\Windows"))
    / "System32"
    / "WindowsPowerShell"
    / "v1.0"
    / "powershell.exe"
)

MODE_ORDER = ("Hybrid", "Discrete", "Integrated")
MODE_LABELS = {
    "Hybrid": "混合模式\nHybrid",
    "Discrete": "獨顯模式\nDiscrete",
    "Integrated": "內顯模式\nIntegrated",
}
MODE_DESCRIPTIONS = {
    "Hybrid": "由系統動態使用內顯與獨顯，適合日常使用。",
    "Discrete": "螢幕直接使用獨立顯卡，效能優先。",
    "Integrated": "只使用處理器內顯，續航與低功耗優先。",
}
OC_TARGET_LABELS = {
    "ExtremePerformance": "Extreme Performance（場景 1）",
    "Balanced": "Balanced（場景 2／0 MHz）",
    "Silent": "Silent（場景 3／0 MHz）",
    "SuperBattery": "Super Battery（場景 4／0 MHz）",
    "User": "User（場景 5）",
    "GamingActive": "Gaming Mode：啟用（引用 Extreme）",
    "GamingInactive": "Gaming Mode：停用（0 MHz）",
}
OC_TARGETS = tuple(OC_TARGET_LABELS)
OC_LABEL_TARGETS = {label: target for target, label in OC_TARGET_LABELS.items()}
SYSTEM_FEATURES = ("WebCam", "WinKey", "SwitchFnWin")
SYSTEM_FEATURE_LABELS = {
    "WebCam": "網路攝影機",
    "WinKey": "Windows 鍵",
    "SwitchFnWin": "Fn／Windows 鍵交換",
}
SYSTEM_FEATURE_DESCRIPTIONS = {
    "WebCam": "直接使用 MSI_ACPI WMI 裝置位元切換內建攝影機，不依賴 MSI 服務。",
    "WinKey": "使用 MSI 的 Registry／OmApSvcBroker 鍵盤 hook 策略。",
    "SwitchFnWin": "使用 MSI 的鍵盤 MCU 與 EC／UEFI 持久化路徑交換按鍵位置。",
}
BATTERY_LIMIT_LABELS = {
    60: "60%｜最佳保養",
    80: "80%｜平衡保養",
    100: "100%｜最佳行動",
}
BATTERY_LIMIT_DESCRIPTIONS = {
    60: "電量低於 50% 開始充電，達到 60% 停止。",
    80: "電量低於 70% 開始充電，達到 80% 停止。",
    100: "充電至 100%，適合需要較長電池續航時使用。",
}
SHUTDOWN_COMMAND = "shutdown /s -t 0"
SHUTDOWN_EXE = (
    Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "shutdown.exe"
)
BASE_DPI = 96
BASE_WINDOW_SIZE = (940, 700)
BASE_MINIMUM_SIZE = (820, 620)


def enable_windows_high_dpi_awareness() -> str:
    """Enable the sharpest DPI mode available before Tk creates any window."""
    if os.name != "nt":
        return "unsupported"

    user32 = ctypes.windll.user32
    per_monitor_v2 = ctypes.c_void_p(-4)

    try:
        set_process_context = user32.SetProcessDpiAwarenessContext
        set_process_context.argtypes = [ctypes.c_void_p]
        set_process_context.restype = ctypes.c_bool
        if set_process_context(per_monitor_v2):
            return "Per-Monitor v2"
    except (AttributeError, OSError):
        pass

    # A host or manifest can make the process-level call return access denied.
    # A thread context set before Tk initialization still keeps this UI crisp.
    try:
        set_thread_context = user32.SetThreadDpiAwarenessContext
        set_thread_context.argtypes = [ctypes.c_void_p]
        set_thread_context.restype = ctypes.c_void_p
        if set_thread_context(per_monitor_v2):
            return "Per-Monitor v2 (thread)"
    except (AttributeError, OSError):
        pass

    try:
        shcore = ctypes.windll.shcore
        set_process_awareness = shcore.SetProcessDpiAwareness
        set_process_awareness.argtypes = [ctypes.c_int]
        set_process_awareness.restype = ctypes.c_long
        if set_process_awareness(2) in (0, -2147024891):
            return "Per-Monitor v1"
    except (AttributeError, OSError):
        pass

    try:
        set_process_aware = user32.SetProcessDPIAware
        set_process_aware.argtypes = []
        set_process_aware.restype = ctypes.c_bool
        if set_process_aware():
            return "System DPI aware"
    except (AttributeError, OSError):
        pass

    return "Windows default"


def get_window_dpi(root: tk.Tk) -> int:
    """Read the actual DPI of the monitor currently hosting the Tk window."""
    if os.name == "nt":
        user32 = ctypes.windll.user32
        try:
            get_dpi_for_window = user32.GetDpiForWindow
            get_dpi_for_window.argtypes = [ctypes.c_void_p]
            get_dpi_for_window.restype = ctypes.c_uint
            dpi = int(get_dpi_for_window(root.winfo_id()))
            if dpi > 0:
                return dpi
        except (AttributeError, OSError):
            pass
        try:
            get_dpi_for_system = user32.GetDpiForSystem
            get_dpi_for_system.argtypes = []
            get_dpi_for_system.restype = ctypes.c_uint
            dpi = int(get_dpi_for_system())
            if dpi > 0:
                return dpi
        except (AttributeError, OSError):
            pass

    try:
        measured = int(round(float(root.winfo_fpixels("1i"))))
        return measured if measured > 0 else BASE_DPI
    except (tk.TclError, ValueError):
        return BASE_DPI


def configure_tk_for_dpi(root: tk.Tk, dpi: int) -> float:
    """Match Tk point rendering to Windows and return the UI scale factor."""
    dpi = max(72, int(dpi))
    root.tk.call("tk", "scaling", dpi / 72.0)
    return dpi / BASE_DPI


def is_administrator() -> bool:
    """Return whether this process has an elevated Windows token."""
    if os.name != "nt":
        return False
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except (AttributeError, OSError):
        return False


def elevation_launch_details() -> tuple[str, str]:
    """Return the executable and arguments used for the elevated child."""
    if getattr(sys, "frozen", False):
        return sys.executable, ""
    return sys.executable, subprocess.list2cmdline([str(SCRIPT_PATH)])


def request_administrator_relaunch() -> int:
    """Ask Windows UAC to relaunch this application with a full admin token."""
    executable, parameters = elevation_launch_details()
    shell_execute = ctypes.windll.shell32.ShellExecuteW
    shell_execute.argtypes = [
        ctypes.c_void_p,
        ctypes.c_wchar_p,
        ctypes.c_wchar_p,
        ctypes.c_wchar_p,
        ctypes.c_wchar_p,
        ctypes.c_int,
    ]
    shell_execute.restype = ctypes.c_void_p
    result = shell_execute(
        None,
        "runas",
        executable,
        parameters,
        str(APP_DIR),
        1,
    )
    return int(result or 0)


def show_elevation_required_error(result: int) -> None:
    """Report a canceled or failed UAC request without creating a Tk window."""
    try:
        message_box = ctypes.windll.user32.MessageBoxW
        message_box.argtypes = [
            ctypes.c_void_p,
            ctypes.c_wchar_p,
            ctypes.c_wchar_p,
            ctypes.c_uint,
        ]
        message_box.restype = ctypes.c_int
        message_box(
            None,
            "本工具需要系統管理員權限。UAC 已取消或無法完成，主視窗不會開啟。\n\n"
            f"ShellExecute code: {result}",
            APP_NAME,
            0x00000010,
        )
    except (AttributeError, OSError):
        pass


def decode_process_output(data: bytes) -> str:
    """Decode Windows PowerShell output without assuming one console code page."""
    if not data:
        return ""
    candidates = ["utf-8-sig", locale.getpreferredencoding(False), "cp950", "mbcs"]
    tried: set[str] = set()
    for encoding in candidates:
        if not encoding or encoding.lower() in tried:
            continue
        tried.add(encoding.lower())
        try:
            return data.decode(encoding)
        except (LookupError, UnicodeDecodeError):
            continue
    return data.decode("utf-8", errors="replace")


def parse_json_output(text: str) -> dict[str, Any]:
    """Parse one JSON object, tolerating harmless PowerShell preamble text."""
    cleaned = text.lstrip("\ufeff\r\n ")
    try:
        value = json.loads(cleaned)
    except json.JSONDecodeError:
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start < 0 or end <= start:
            raise ValueError("PowerShell 未回傳可解析的 JSON。")
        value = json.loads(cleaned[start : end + 1])
    if not isinstance(value, dict):
        raise ValueError("PowerShell JSON 根節點不是物件。")
    return value


def parse_ap_state(output: str) -> tuple[int, bool]:
    """Return Get_AP(0).Data[1] and whether its pending bit is set."""
    match = re.search(r"Data\[1\]\s*:\s*0x([0-9A-Fa-f]{2})", output)
    if not match:
        raise ValueError("無法從 Get_AP(0) 輸出判讀 Data[1]。")
    value = int(match.group(1), 16)
    return value, bool(value & 0x02)


def run_process(arguments: list[str]) -> tuple[int, str]:
    """Run a hidden child process and return its exit code and combined output."""
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    completed = subprocess.run(
        arguments,
        cwd=str(PROJECT_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        creationflags=creation_flags,
    )
    stdout = decode_process_output(completed.stdout).strip()
    stderr = decode_process_output(completed.stderr).strip()
    combined = "\n".join(part for part in (stdout, stderr) if part)
    return completed.returncode, combined


def invoke_api(command: str, target: str | None = None) -> dict[str, Any]:
    arguments = [
        str(POWERSHELL),
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(API_CLI),
        "-Command",
        command,
    ]
    if target:
        arguments.extend(["-Target", target])
    if command == "Request":
        arguments.append("-ConfirmRegistryAndFirmwareWrite")
    arguments.append("-Json")
    exit_code, output = run_process(arguments)
    result = parse_json_output(output)
    result.setdefault("ProcessExitCode", exit_code)
    return result


def normalize_oc_target(target: str) -> str:
    """Map Gaming Mode UI choices to the MSI profiles they actually reuse."""
    if target == "GamingActive":
        return "ExtremePerformance"
    if target == "GamingInactive":
        return "Balanced"
    return target


def slider_tick_interval(minimum: int, maximum: int, segments: int = 5) -> int:
    """Return a readable 1/2/5-based tick interval for a Tk scale."""
    span = max(1, int(maximum) - int(minimum))
    raw = span / max(1, int(segments))
    magnitude = 10 ** math.floor(math.log10(raw))
    candidates = [factor * magnitude for factor in (1, 2, 5, 10)]
    return max(1, int(min(candidates, key=lambda value: abs(value - raw))))


def oc_profile_values(status: dict[str, Any], target: str) -> tuple[int, int]:
    """Resolve the offsets exactly as OmApSvcBroker does for a scene."""
    registry = status.get("Registry") or {}
    if target in ("ExtremePerformance", "GamingActive"):
        return int(registry.get("ExtremeCoreMHz", 0)), int(
            registry.get("ExtremeMemoryMHz", 0)
        )
    if target == "User":
        return int(registry.get("UserCoreMHz", 0)), int(
            registry.get("UserMemoryMHz", 0)
        )
    return 0, 0


def invoke_oc_api(
    command: str,
    *,
    target: str | None = None,
    core_offset: int | None = None,
    memory_offset: int | None = None,
    expected_model: str | None = None,
    expected_gpu: str | None = None,
    confirmed: bool = False,
) -> dict[str, Any]:
    """Call the bundled GPU OC JSON API without implementing writes in Python."""
    arguments = [
        str(POWERSHELL),
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(API_CLI),
        "-Command",
        command,
    ]
    if target is not None:
        arguments.extend(["-Target", normalize_oc_target(target)])
    if core_offset is not None:
        arguments.extend(["-CoreOffsetMHz", str(int(core_offset))])
    if memory_offset is not None:
        arguments.extend(["-MemoryOffsetMHz", str(int(memory_offset))])
    if expected_model:
        arguments.extend(["-ExpectedModel", expected_model])
    if expected_gpu:
        arguments.extend(["-ExpectedGpuName", expected_gpu])
    if confirmed and command == "OCSave":
        arguments.append("-ConfirmRegistryWrite")
    if confirmed and command == "OCApply":
        arguments.append("-ConfirmHardwareRisk")
    arguments.append("-Json")
    exit_code, output = run_process(arguments)
    result = parse_json_output(output)
    result.setdefault("ProcessExitCode", exit_code)
    return result


def invoke_system_api(
    command: str,
    *,
    feature: str | None = None,
    enabled: bool | None = None,
    confirmed: bool = False,
) -> dict[str, Any]:
    """Call the allowlisted direct/service system-control API through PowerShell."""
    arguments = [
        str(POWERSHELL),
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(API_CLI),
        "-Command",
        command,
    ]
    if feature is not None:
        arguments.extend(["-Feature", feature])
    if enabled is not None:
        arguments.extend(["-Enabled", "1" if enabled else "0"])
    if confirmed and command == "SystemSet":
        arguments.append("-ConfirmSystemChange")
    arguments.append("-Json")
    exit_code, output = run_process(arguments)
    result = parse_json_output(output)
    result.setdefault("ProcessExitCode", exit_code)
    return result


def invoke_battery_api(
    command: str,
    *,
    charge_limit: int | None = None,
    confirmed: bool = False,
) -> dict[str, Any]:
    """Call the direct battery JSON API; Python never writes to hardware."""
    if command not in ("BatteryStatus", "BatteryPlan", "BatterySet"):
        raise ValueError("不支援的電池命令。")
    if charge_limit is not None and charge_limit not in BATTERY_LIMIT_LABELS:
        raise ValueError("充電上限僅支援 60%、80% 或 100%。")
    arguments = [
        str(POWERSHELL), "-NoProfile", "-NonInteractive", "-ExecutionPolicy",
        "Bypass", "-File", str(API_CLI), "-Command", command,
    ]
    if charge_limit is not None:
        arguments.extend(["-ChargeLimitPercent", str(charge_limit)])
    if confirmed and command == "BatterySet":
        arguments.append("-ConfirmBatteryChange")
    arguments.append("-Json")
    exit_code, output = run_process(arguments)
    result = parse_json_output(output)
    result.setdefault("ProcessExitCode", exit_code)
    return result


def read_ap_state() -> dict[str, Any]:
    arguments = [
        str(POWERSHELL),
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(AP_PROBE),
    ]
    exit_code, output = run_process(arguments)
    if exit_code != 0:
        raise RuntimeError(output or f"Get_AP(0) 查詢失敗，exit code={exit_code}")
    value, pending = parse_ap_state(output)
    return {"Data1": value, "Pending": pending, "RawOutput": output}


def immediate_shutdown_arguments() -> list[str]:
    """Return the exact argv for the explicitly authorized full shutdown."""
    return [str(SHUTDOWN_EXE), "/s", "/t", "0"]


def should_start_auto_shutdown(result: dict[str, Any], enabled: bool) -> bool:
    """Gate shutdown on this request's explicit opt-in and accepted result."""
    return bool(enabled and result.get("Success") and result.get("RequestAccepted"))


def start_immediate_shutdown() -> int:
    """Start shutdown.exe after the GUI has obtained explicit user consent."""
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    process = subprocess.Popen(
        immediate_shutdown_arguments(),
        cwd=str(PROJECT_ROOT),
        creationflags=creation_flags,
    )
    return process.pid


class FuckMsiCenterApp:
    def __init__(self, root: tk.Tk, dpi_awareness: str) -> None:
        self.root = root
        self.root.title(APP_NAME)
        self.dpi_awareness = dpi_awareness
        self.current_dpi = get_window_dpi(root)
        self.ui_scale = configure_tk_for_dpi(root, self.current_dpi)
        self._configure_window_size()

        self.admin = is_administrator()
        self.busy = False
        self.status: dict[str, Any] | None = None
        self.ap_state: dict[str, Any] | None = None
        self.auto_shutdown_var = tk.BooleanVar(value=False)
        self.mode_buttons: dict[str, ttk.Button] = {}
        self.oc_dialog: MsiGpuOcWindow | None = None
        self.system_dialog: MsiSystemControlWindow | None = None
        self.battery_dialog: MsiBatteryWindow | None = None
        self.events: queue.Queue[tuple[Callable[..., None], tuple[Any, ...]]] = queue.Queue()

        self._configure_style()
        self._build_ui()
        self.root.after(100, self._drain_events)
        self.root.after(750, self._watch_monitor_dpi)
        self.log("GUI 已啟動；所有狀態查詢均為唯讀。")
        self.log(
            f"High-DPI：{self.dpi_awareness}，目前 {self.current_dpi} DPI "
            f"({self.ui_scale * 100:.0f}%)。"
        )
        if self.admin:
            self.log("目前為系統管理員權限，可執行 guarded request。")
        else:
            self.log("警告：程序沒有系統管理員權限；切換按鈕保持鎖定。")
        self.refresh_status()

    def _px(self, value: int | float) -> int:
        return max(1, int(round(float(value) * self.ui_scale)))

    def _configure_window_size(self) -> None:
        screen_width = self.root.winfo_screenwidth()
        screen_height = self.root.winfo_screenheight()
        width = min(self._px(BASE_WINDOW_SIZE[0]), int(screen_width * 0.92))
        height = min(self._px(BASE_WINDOW_SIZE[1]), int(screen_height * 0.90))
        minimum_width = min(self._px(BASE_MINIMUM_SIZE[0]), int(screen_width * 0.78))
        minimum_height = min(self._px(BASE_MINIMUM_SIZE[1]), int(screen_height * 0.78))
        left = max(0, (screen_width - width) // 2)
        top = max(0, (screen_height - height) // 2)
        self.root.geometry(f"{width}x{height}+{left}+{top}")
        self.root.minsize(minimum_width, minimum_height)

    def _configure_style(self) -> None:
        style = ttk.Style(self.root)
        for theme in ("vista", "xpnative", "clam"):
            if theme in style.theme_names():
                style.theme_use(theme)
                break
        style.configure("Title.TLabel", font=("Microsoft JhengHei UI", 19, "bold"))
        style.configure("Heading.TLabel", font=("Microsoft JhengHei UI", 11, "bold"))
        style.configure(
            "Mode.TButton",
            font=("Microsoft JhengHei UI", 11, "bold"),
            padding=self._px(14),
        )
        style.configure("Status.TLabel", font=("Microsoft JhengHei UI", 12, "bold"))
        style.configure("Muted.TLabel", foreground="#555555")

    def _watch_monitor_dpi(self) -> None:
        """Keep text and themed controls sharp when the window changes monitor."""
        try:
            dpi = get_window_dpi(self.root)
            if dpi != self.current_dpi:
                old_dpi = self.current_dpi
                self.current_dpi = dpi
                self.ui_scale = configure_tk_for_dpi(self.root, dpi)
                self._configure_style()
                self.log(
                    f"螢幕 DPI 變更：{old_dpi} -> {dpi} "
                    f"({self.ui_scale * 100:.0f}%)；已重新套用 Tk scaling。"
                )
        finally:
            self.root.after(750, self._watch_monitor_dpi)

    def _build_ui(self) -> None:
        outer = ttk.Frame(self.root, padding=self._px(18))
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(4, weight=1)

        header = ttk.Frame(outer)
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)
        ttk.Label(header, text=APP_NAME, style="Title.TLabel").grid(
            row=0, column=0, sticky="w"
        )
        admin_text = "系統管理員：是" if self.admin else "系統管理員：異常"
        self.admin_label = ttk.Label(header, text=admin_text)
        self.admin_label.grid(row=0, column=1, padx=(12, 0))

        status_frame = ttk.LabelFrame(outer, text="GPU MUX 目前狀態", padding=self._px(12))
        status_frame.grid(row=1, column=0, sticky="ew", pady=(14, 10))
        status_frame.columnconfigure(1, weight=1)
        ttk.Label(status_frame, text="Applied mode：").grid(row=0, column=0, sticky="w")
        self.mode_value = ttk.Label(status_frame, text="讀取中…", style="Status.TLabel")
        self.mode_value.grid(row=0, column=1, sticky="w")
        ttk.Label(status_frame, text="Request/AP：").grid(row=1, column=0, sticky="w", pady=(6, 0))
        self.pending_value = ttk.Label(status_frame, text="讀取中…")
        self.pending_value.grid(row=1, column=1, sticky="w", pady=(6, 0))
        ttk.Label(status_frame, text="Legacy WMI：").grid(row=2, column=0, sticky="w", pady=(6, 0))
        self.legacy_value = ttk.Label(status_frame, text="—")
        self.legacy_value.grid(row=2, column=1, sticky="w", pady=(6, 0))

        action_bar = ttk.Frame(status_frame)
        action_bar.grid(row=0, column=2, rowspan=3, padx=(12, 0), sticky="e")
        self.refresh_button = ttk.Button(action_bar, text="重新整理", command=self.refresh_status)
        self.refresh_button.pack(fill="x")
        self.copy_shutdown_button = ttk.Button(
            action_bar, text="複製完整關機命令", command=self.copy_shutdown_command
        )
        self.copy_shutdown_button.pack(fill="x", pady=(8, 0))
        self.open_oc_button = ttk.Button(
            action_bar, text="GPU 核心／VRAM 調校", command=self.open_oc_window
        )
        self.open_oc_button.pack(fill="x", pady=(8, 0))
        self.open_system_button = ttk.Button(
            action_bar, text="系統快捷控制", command=self.open_system_window
        )
        self.open_system_button.pack(fill="x", pady=(8, 0))
        self.open_battery_button = ttk.Button(
            action_bar, text="電池充電上限", command=self.open_battery_window
        )
        self.open_battery_button.pack(fill="x", pady=(8, 0))

        switch_frame = ttk.LabelFrame(outer, text="GPU MUX 目標模式", padding=self._px(12))
        switch_frame.grid(row=2, column=0, sticky="ew", pady=(0, 10))
        for column, mode in enumerate(MODE_ORDER):
            switch_frame.columnconfigure(column, weight=1, uniform="modes")
            cell = ttk.Frame(switch_frame, padding=(self._px(5), self._px(2)))
            cell.grid(row=0, column=column, sticky="nsew")
            button = ttk.Button(
                cell,
                text=MODE_LABELS[mode],
                style="Mode.TButton",
                command=lambda selected=mode: self.prepare_switch(selected),
            )
            button.pack(fill="x")
            ttk.Label(
                cell,
                text=MODE_DESCRIPTIONS[mode],
                wraplength=self._px(245),
                justify="center",
                style="Muted.TLabel",
            ).pack(fill="x", pady=(8, 0))
            self.mode_buttons[mode] = button

        self.auto_shutdown_checkbox = ttk.Checkbutton(
            switch_frame,
            text="切換 request accepted 後自動執行 shutdown /s -t 0",
            variable=self.auto_shutdown_var,
            command=self._on_auto_shutdown_changed,
        )
        self.auto_shutdown_checkbox.grid(
            row=1,
            column=0,
            columnspan=3,
            sticky="w",
            padx=self._px(5),
            pady=(self._px(12), 0),
        )

        notice = ttk.LabelFrame(outer, text="安全提示", padding=self._px(10))
        notice.grid(row=3, column=0, sticky="ew", pady=(0, 10))
        ttk.Label(
            notice,
            text=(
                "切換只代表 request accepted；模式要在完整關機／開機後才會 applied。"
                " 本工具不會自動 retry；只有勾選自動關機並逐次確認後，accepted request 才會觸發 shutdown。"
                " 若 AP pending，三個切換按鈕會鎖定。"
            ),
            wraplength=self._px(870),
            justify="left",
        ).pack(anchor="w")

        log_frame = ttk.LabelFrame(outer, text="Log", padding=self._px(8))
        log_frame.grid(row=4, column=0, sticky="nsew")
        log_frame.rowconfigure(0, weight=1)
        log_frame.columnconfigure(0, weight=1)
        self.log_text = scrolledtext.ScrolledText(
            log_frame,
            height=14,
            wrap="word",
            state="disabled",
            font=("Consolas", 9),
        )
        self.log_text.grid(row=0, column=0, sticky="nsew")

        self.footer_value = ttk.Label(outer, text="", style="Muted.TLabel")
        self.footer_value.grid(row=5, column=0, sticky="w", pady=(8, 0))
        self._update_button_states()

    def log(self, message: str) -> None:
        timestamp = dt.datetime.now().strftime("%H:%M:%S")
        self.log_text.configure(state="normal")
        self.log_text.insert("end", f"[{timestamp}] {message.rstrip()}\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _run_async(
        self,
        work: Callable[[], Any],
        on_success: Callable[[Any], None],
        on_error: Callable[[Exception], None] | None = None,
    ) -> None:
        def runner() -> None:
            try:
                result = work()
            except Exception as exc:  # surfaced on the Tk main thread
                callback = on_error or self._show_background_error
                self.events.put((callback, (exc,)))
            else:
                self.events.put((on_success, (result,)))

        threading.Thread(target=runner, daemon=True).start()

    def _drain_events(self) -> None:
        try:
            while True:
                callback, arguments = self.events.get_nowait()
                callback(*arguments)
        except queue.Empty:
            pass
        self.root.after(100, self._drain_events)

    def _show_background_error(self, error: Exception) -> None:
        self._set_busy(False)
        self.log(f"錯誤：{error}")
        messagebox.showerror("操作失敗", str(error), parent=self.root)

    def _set_busy(self, busy: bool, footer: str = "") -> None:
        self.busy = busy
        self.footer_value.configure(text=footer)
        self.refresh_button.configure(state="disabled" if busy else "normal")
        self.auto_shutdown_checkbox.configure(state="disabled" if busy else "normal")
        self.open_oc_button.configure(state="disabled" if busy else "normal")
        self.open_system_button.configure(state="disabled" if busy else "normal")
        self.open_battery_button.configure(state="disabled" if busy else "normal")
        if self.battery_dialog is not None:
            self.battery_dialog._update_actions()
        self._update_button_states()

    def open_oc_window(self) -> None:
        if self.oc_dialog is not None and self.oc_dialog.window.winfo_exists():
            self.oc_dialog.window.deiconify()
            self.oc_dialog.window.lift()
            self.oc_dialog.window.focus_force()
            return
        self.oc_dialog = MsiGpuOcWindow(self)

    def open_system_window(self) -> None:
        if self.system_dialog is not None and self.system_dialog.window.winfo_exists():
            self.system_dialog.window.deiconify()
            self.system_dialog.window.lift()
            self.system_dialog.window.focus_force()
            return
        self.system_dialog = MsiSystemControlWindow(self)

    def open_battery_window(self) -> None:
        if self.busy:
            return
        if self.battery_dialog is not None and self.battery_dialog.window.winfo_exists():
            self.battery_dialog.window.deiconify()
            self.battery_dialog.window.lift()
            return
        self.battery_dialog = MsiBatteryWindow(self)

    def _on_auto_shutdown_changed(self) -> None:
        if self.auto_shutdown_var.get():
            self.log(
                "已勾選自動完整關機；下次切換確認會一併顯示關機警告，"
                "且只在 request accepted 後執行 shutdown /s -t 0。"
            )
        else:
            self.log("已取消自動完整關機；accepted request 後只顯示手動關機提示。")

    def _update_button_states(self) -> None:
        status = self.status or {}
        current = status.get("Mode")
        verified = bool(self.status and self.status.get("Success"))
        ap_known = self.ap_state is not None
        pending = bool(self.ap_state and self.ap_state.get("Pending"))
        new_switch_supported = bool(status.get("NewSwitchSupport"))
        can_switch = (
            self.admin
            and verified
            and ap_known
            and not pending
            and not self.busy
            and new_switch_supported
        )
        for mode, button in self.mode_buttons.items():
            mode_supported = (
                mode == "Hybrid"
                or (mode == "Discrete" and bool(status.get("DiscreteSupport")))
                or (mode == "Integrated" and bool(status.get("IntegratedSupport")))
            )
            enabled = can_switch and mode_supported and mode != current
            button.configure(state="normal" if enabled else "disabled")

    def refresh_status(self) -> None:
        if self.busy:
            return
        self._set_busy(True, "正在讀取狀態…")
        self.log("讀取 authoritative status 與 Get_AP(0)…")

        def work() -> tuple[dict[str, Any], dict[str, Any] | None, Exception | None]:
            status = invoke_api("Status")
            if not self.admin:
                return status, None, None
            try:
                ap_state = read_ap_state()
            except Exception as exc:
                return status, None, exc
            return status, ap_state, None

        self._run_async(work, self._finish_refresh)

    def _finish_refresh(
        self, result: tuple[dict[str, Any], dict[str, Any] | None, Exception | None]
    ) -> None:
        status, ap_state, ap_error = result
        self.status = status
        self.ap_state = ap_state
        mode = str(status.get("Mode", "Unknown"))
        mode_index = status.get("ModeIndex", "?")
        success = bool(status.get("Success"))
        suffix = "" if success else "（未通過 WMI cross-check）"
        self.mode_value.configure(text=f"{mode} / UEFI applied index={mode_index} {suffix}")
        self.legacy_value.configure(text=str(status.get("LegacyWmiData0") or "未知"))

        if ap_state:
            data1 = int(ap_state["Data1"])
            if ap_state["Pending"]:
                self.pending_value.configure(
                    text=f"PENDING（Data[1]=0x{data1:02X}，禁止重送 request）",
                    foreground="#a12222",
                )
                self.log(
                    f"偵測到 AP pending：Data[1]=0x{data1:02X}。切換按鈕已鎖定；請勿重送。"
                )
            else:
                self.pending_value.configure(text=f"clear（Data[1]=0x{data1:02X}）", foreground="#1f6d3a")
                self.log(f"AP request state clear：Data[1]=0x{data1:02X}。")
        elif not self.admin:
            self.pending_value.configure(text="未知（需系統管理員權限）", foreground="#7a5d00")
        else:
            self.pending_value.configure(text="讀取失敗", foreground="#a12222")

        staged = status.get("StagedTargetIndex")
        self.log(
            f"Status：Success={success}, Mode={mode} ({mode_index}), "
            f"UEFI staged index={staged}, Legacy={status.get('LegacyWmiData0')}, "
            f"Backend={status.get('Backend')}"
        )
        raw_output = str(status.get("RawOutput") or status.get("Error") or "").strip()
        if raw_output:
            self.log(raw_output)
        if ap_error:
            self.log(f"AP 唯讀查詢失敗：{ap_error}")
        if not success:
            self.log("狀態未完整驗證；切換按鈕維持鎖定。")

        self._set_busy(False, "狀態已更新")

    def prepare_switch(self, target: str) -> None:
        if self.busy:
            return
        if not self.admin:
            messagebox.showwarning(
                "需要系統管理員權限",
                "目前程序沒有完整管理員權限。請關閉後重新啟動，並通過自動顯示的 UAC。",
                parent=self.root,
            )
            return
        auto_shutdown = bool(self.auto_shutdown_var.get())
        if auto_shutdown and not SHUTDOWN_EXE.is_file():
            self.log(f"自動關機不可用：找不到 {SHUTDOWN_EXE}。")
            messagebox.showerror(
                "找不到 Windows 關機程式",
                f"找不到：\n{SHUTDOWN_EXE}\n\n沒有送出切換 request。",
                parent=self.root,
            )
            return
        self._set_busy(True, f"正在重新驗證 {target} 切換條件…")
        self.log(
            f"準備切換至 {target}；AutoShutdown={auto_shutdown}；"
            "先重新讀取 status、AP 與 side-effect-free plan。"
        )

        def work() -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
            status = invoke_api("Status")
            ap_state = read_ap_state()
            plan = invoke_api("Plan", target)
            return status, ap_state, plan

        self._run_async(
            work,
            lambda value: self._confirm_switch(target, auto_shutdown, *value),
        )

    def _confirm_switch(
        self,
        target: str,
        auto_shutdown: bool,
        status: dict[str, Any],
        ap_state: dict[str, Any],
        plan: dict[str, Any],
    ) -> None:
        self.status = status
        self.ap_state = ap_state
        if not status.get("Success"):
            self._set_busy(False)
            error = status.get("Error") or status.get("RawOutput") or "狀態驗證失敗。"
            self.log(f"拒絕切換：{error}")
            messagebox.showerror("狀態驗證失敗", str(error), parent=self.root)
            return
        if ap_state.get("Pending"):
            self._set_busy(False)
            value = int(ap_state["Data1"])
            self.pending_value.configure(
                text=f"PENDING（Data[1]=0x{value:02X}，禁止重送 request）",
                foreground="#a12222",
            )
            self.log("拒絕切換：已有 AP pending request；不會自動 retry。")
            messagebox.showwarning(
                "已有待處理 request",
                "Get_AP(0).Data[1].bit1 已設置。請勿重送 request；先執行完整關機／開機，再重新整理狀態。",
                parent=self.root,
            )
            return
        if status.get("Mode") == target:
            self._set_busy(False)
            self.log(f"目前已是 {target}，沒有送出 request。")
            messagebox.showinfo("無需切換", f"目前 applied mode 已是 {target}。", parent=self.root)
            return
        if not plan.get("Success"):
            self._set_busy(False)
            messagebox.showerror("無法建立切換計畫", str(plan.get("Error")), parent=self.root)
            return

        power_action = (
            "你已勾選自動完整關機。Request accepted 後將立即執行：\n"
            f"{SHUTDOWN_COMMAND}\n"
            "Windows 將開始完整關機；此 MSI 機型之後可能由 BIOS 自動重新開機。"
            "請先儲存所有工作；確認後不再另行詢問。"
            if auto_shutdown
            else f"Request accepted 後不會自動關機；請由你手動執行 {SHUTDOWN_COMMAND}。"
        )
        confirmation_action = (
            "確定要送出一次 request，並在被接受後自動完整關機嗎？"
            if auto_shutdown
            else "確定要送出一次 request 嗎？"
        )
        confirmation = (
            f"目前 applied mode：{status.get('Mode')}\n"
            f"目標模式：{target}\n\n"
            f"後端：{plan.get('Backend')}（不依賴 MSI service）\n"
            f"Registry：{plan.get('RegistryValue')}\n"
            f"UEFI byte 5：{plan.get('CurrentUefiByte5')} → {plan.get('PlannedUefiByte5')}\n"
            f"觸發命令：{plan.get('SwitchCommand')}\n"
            f"等待：{plan.get('DelayMilliseconds')} ms\n"
            f"確認命令：{plan.get('AcknowledgeCommand')}（具有 BE02 寫入副作用）\n\n"
            "此操作直接 staging UEFI 並經 MSI_ACPI 送出 firmware request；不連線 "
            "CentralServer，也不寫 MSI Registry。成功只代表 request accepted；"
            "工具不會自動重試。\n\n"
            f"{power_action}\n\n"
            "選擇「否」會取消本次切換 request 與關機流程，不會有任何寫入。\n\n"
            f"{confirmation_action}"
        )
        if not messagebox.askyesno("確認 GPU 模式切換", confirmation, icon="warning", parent=self.root):
            self._set_busy(False, "已取消；沒有送出 request")
            self.log("使用者取消切換；沒有執行 state-changing request。")
            return

        self.footer_value.configure(text=f"正在送出 {target} request，請勿關閉視窗…")
        self.log(
            f"已取得本次明確確認，呼叫 guarded API：Target={target}, "
            f"AutoShutdown={auto_shutdown}。"
        )
        self._run_async(
            lambda: invoke_api("Request", target),
            lambda result: self._finish_request(result, auto_shutdown),
        )

    def _finish_request(self, result: dict[str, Any], auto_shutdown: bool) -> None:
        success = bool(result.get("Success"))
        accepted = bool(result.get("RequestAccepted"))
        already_applied = bool(result.get("AlreadyApplied"))
        raw_output = str(result.get("RawOutput") or result.get("Error") or "").strip()
        self.log(
            f"Request result：Success={success}, Accepted={accepted}, "
            f"AlreadyApplied={already_applied}, ExitCode={result.get('ExitCode')}"
        )
        if raw_output:
            self.log(raw_output)

        if success and accepted:
            self.ap_state = {"Data1": 0x02, "Pending": True, "RawOutput": raw_output}
            self.pending_value.configure(
                text="PENDING（request accepted；等待完整關機／開機）",
                foreground="#a12222",
            )
            if should_start_auto_shutdown(result, auto_shutdown):
                self.footer_value.configure(text="Request accepted；正在執行完整關機…")
                self.log(
                    f"Request accepted 且本次已授權自動關機；現在執行 {SHUTDOWN_COMMAND}。"
                )
                self.root.update_idletasks()
                try:
                    shutdown_pid = start_immediate_shutdown()
                except Exception as error:
                    self._set_busy(False, "自動關機啟動失敗；請手動完整關機")
                    self.log(f"無法啟動 shutdown.exe：{error}")
                    messagebox.showerror(
                        "自動關機啟動失敗",
                        "切換 request 已被接受，但無法啟動 Windows 關機命令。\n\n"
                        f"請立即手動執行：\n{SHUTDOWN_COMMAND}\n\n錯誤：{error}",
                        parent=self.root,
                    )
                else:
                    self.log(f"shutdown.exe 已啟動，PID={shutdown_pid}；等待 Windows 完整關機。")
                return

            self._set_busy(False, "Request accepted；請手動完整關機")
            messagebox.showinfo(
                "Request accepted",
                "切換請求已被接受，但尚未 applied。\n\n"
                "請先儲存工作，再由你手動執行：\n"
                f"{SHUTDOWN_COMMAND}\n\n"
                "開機後重新執行本工具並確認 applied mode 與 AP clear。",
                parent=self.root,
            )
            return
        if success and already_applied:
            self._set_busy(False, "目前模式已符合目標")
            messagebox.showinfo("無需切換", "目前模式已符合目標，沒有送出 request。", parent=self.root)
            self.refresh_status()
            return

        self._set_busy(False, "Request 失敗；禁止自動重試")
        messagebox.showerror(
            "Request 未完成",
            "Guarded request 未成功完成。工具不會自動重試，因為 UEFI target 可能已 staging。\n\n"
            "請保留 Log 並先檢查狀態。",
            parent=self.root,
        )

    def copy_shutdown_command(self) -> None:
        self.root.clipboard_clear()
        self.root.clipboard_append(SHUTDOWN_COMMAND)
        self.root.update_idletasks()
        self.log(f"已複製命令：{SHUTDOWN_COMMAND}（尚未執行）")
        self.footer_value.configure(text="已複製完整關機命令；工具沒有執行它")


class MsiBatteryWindow:
    """Battery Master presets with a fresh plan, one Set, and hardware read-back."""

    def __init__(self, app: FuckMsiCenterApp) -> None:
        self.app = app
        self.window = tk.Toplevel(app.root)
        self.window.title(f"{APP_NAME} | 電池充電上限")
        self.window.transient(app.root)
        self.window.protocol("WM_DELETE_WINDOW", self.close)
        width = min(app._px(720), int(self.window.winfo_screenwidth() * 0.90))
        height = min(app._px(530), int(self.window.winfo_screenheight() * 0.90))
        self.window.geometry(f"{width}x{height}")
        self.window.minsize(min(width, app._px(640)), height)
        self.busy = False
        self.status: dict[str, Any] | None = None
        self.current_var = tk.StringVar(value="讀取中…")
        self.limit_var = tk.IntVar(value=80)
        self.policy_var = tk.StringVar(value="")
        self.footer_var = tk.StringVar(value="")
        self.limit_buttons: list[ttk.Radiobutton] = []
        outer = ttk.Frame(self.window, padding=app._px(18))
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        ttk.Label(outer, text="電池充電上限", style="Title.TLabel").grid(
            row=0, column=0, sticky="w"
        )
        ttk.Label(outer, textvariable=self.current_var, style="Status.TLabel").grid(
            row=1, column=0, sticky="w", pady=(12, 12)
        )
        choices = ttk.LabelFrame(outer, text="Battery Master 模式", padding=app._px(12))
        choices.grid(row=2, column=0, sticky="ew")
        for row, (limit, label) in enumerate(BATTERY_LIMIT_LABELS.items()):
            button = ttk.Radiobutton(choices, text=label, variable=self.limit_var, value=limit)
            button.grid(row=row, column=0, sticky="w", pady=app._px(8))
            self.limit_buttons.append(button)
            ttk.Label(
                choices, text=BATTERY_LIMIT_DESCRIPTIONS[limit],
                wraplength=app._px(390), justify="left",
            ).grid(row=row, column=1, sticky="w", padx=(app._px(16), 0))
        ttk.Label(
            outer, text="降低上限不會主動放電；目前電量高於上限時，會等待自然消耗。",
            wraplength=app._px(660), justify="left",
        ).grid(row=3, column=0, sticky="w", pady=(12, 6))
        ttk.Label(
            outer, textvariable=self.policy_var, wraplength=app._px(660),
            justify="left", style="Muted.TLabel",
        ).grid(row=4, column=0, sticky="ew", pady=(0, 12))
        actions = ttk.Frame(outer)
        actions.grid(row=5, column=0, sticky="ew")
        self.refresh_button = ttk.Button(actions, text="重新整理", command=self.refresh)
        self.refresh_button.pack(side="left")
        self.apply_button = ttk.Button(actions, text="套用充電上限", command=self.prepare_change)
        self.apply_button.pack(side="right")
        ttk.Label(outer, textvariable=self.footer_var, style="Muted.TLabel").grid(
            row=6, column=0, sticky="w", pady=(10, 0)
        )
        self._update_actions()
        self.refresh()

    def close(self) -> None:
        if self.busy:
            return
        self.app.battery_dialog = None
        self.window.destroy()

    def _update_actions(self) -> None:
        available = not self.busy and not self.app.busy
        known = bool(
            self.status and self.status.get("Success") and self.status.get("Supported")
            and self.status.get("ChargeLimitPercent") in BATTERY_LIMIT_LABELS
        )
        self.refresh_button.configure(state="normal" if available else "disabled")
        self.apply_button.configure(
            state="normal" if available and known and self.app.admin else "disabled"
        )
        for button in self.limit_buttons:
            button.configure(state="normal" if available and known else "disabled")

    def _set_busy(self, busy: bool, footer: str = "") -> None:
        self.busy = busy
        self.footer_var.set(footer)
        self.app._set_busy(busy, footer)
        self._update_actions()

    def _show_error(self, error: Any) -> None:
        self.status = None
        self.current_var.set("目前上限：讀取失敗，請重新整理")
        self._set_busy(False, "操作失敗；請重新整理，不會自動重試")
        self.app.log(f"電池充電上限：{error}")
        messagebox.showerror("電池充電上限", str(error), parent=self.window)

    def refresh(self) -> None:
        if self.busy or self.app.busy:
            return
        self.status = None
        self._set_busy(True, "正在讀取電池充電上限…")
        self.app._run_async(
            lambda: invoke_battery_api("BatteryStatus"), self._finish_refresh, self._show_error
        )

    def _finish_refresh(self, result: dict[str, Any]) -> None:
        limit = result.get("ChargeLimitPercent")
        if not result.get("Success") or not result.get("Supported") or limit not in BATTERY_LIMIT_LABELS:
            self._show_error(result.get("Error") or "韌體未回傳已驗證的充電模式。")
            return
        self.status = result
        self.limit_var.set(limit)
        self.current_var.set(f"目前充電上限：{limit}%")
        policy = result.get("MsiPolicy") or {}
        if policy.get("AIChargerEnabled"):
            self.policy_var.set("MSI AI Charger 已啟用，可能自動覆蓋上限。請先在 MSI Center 選擇手動充電模式。")
        else:
            self.policy_var.set("設定直接套用至硬體。重新開啟 MSI Center 時，它可能重新套用已保存的模式。")
        self.app.log(f"BatteryStatus：{limit}%，D7={result.get('RawValueHex')}；唯讀查詢。")
        self._set_busy(False, "充電上限已更新")

    def prepare_change(self) -> None:
        if self.busy or self.app.busy or not self.app.admin or not self.status:
            return
        limit = self.limit_var.get()
        if limit not in BATTERY_LIMIT_LABELS:
            return
        self._set_busy(True, "正在確認目前充電模式…")
        self.app._run_async(
            lambda: invoke_battery_api("BatteryPlan", charge_limit=limit),
            lambda plan: self._confirm_change(limit, plan), self._show_error,
        )

    def _confirm_change(self, limit: int, plan: dict[str, Any]) -> None:
        if not plan.get("Success") or plan.get("ChargeLimitPercent") != limit:
            self._show_error(plan.get("Error") or "充電計畫驗證失敗。")
            return
        if plan.get("AlreadyApplied"):
            self._set_busy(False, "目前上限已符合選擇")
            self.refresh()
            return
        ai_notice = (
            "MSI AI Charger 已啟用，可能自動覆蓋此次設定。\n\n"
            if (plan.get("MsiPolicy") or {}).get("AIChargerEnabled") else ""
        )
        self.app.log(f"BatteryPlan：{plan.get('CurrentLimitPercent')}% → {limit}%；{plan.get('Command')}")
        if not messagebox.askyesno(
            "確認充電上限",
            f"目前：{plan.get('CurrentLimitPercent')}%\n目標：{limit}%\n\n"
            f"{BATTERY_LIMIT_DESCRIPTIONS[limit]}\n"
            "降低上限不會主動放電。MSI Center 重新開啟時可能覆蓋此設定。\n\n"
            + ai_notice + f"硬體命令：{plan.get('Command')}\n\n確定套用嗎？",
            parent=self.window,
        ):
            self._set_busy(False, "已取消，充電上限未修改")
            return
        self.footer_var.set("正在套用並讀回驗證…")
        self.app._run_async(
            lambda: invoke_battery_api("BatterySet", charge_limit=limit, confirmed=True),
            self._finish_set, self._show_error,
        )

    def _finish_set(self, result: dict[str, Any]) -> None:
        if (
            not result.get("Success") or result.get("Verified") is not True
            or result.get("ChargeLimitPercent") not in BATTERY_LIMIT_LABELS
        ):
            self._show_error(result.get("Error") or "充電上限未通過硬體讀回驗證。")
            return
        limit = result.get("ChargeLimitPercent")
        self.app.log(f"BatterySet：已由硬體讀回 {limit}%，RequestSent={result.get('RequestSent')}。")
        self._set_busy(False, f"已套用並驗證：{limit}%")
        self.refresh()


class MsiSystemControlWindow:
    """Small allowlisted replacement for MSI Center General Settings."""

    def __init__(self, app: FuckMsiCenterApp) -> None:
        self.app = app
        self.window = tk.Toplevel(app.root)
        self.window.title(f"{APP_NAME} | 系統快捷控制")
        self.window.transient(app.root)
        self.window.protocol("WM_DELETE_WINDOW", self.close)
        width = min(app._px(760), int(self.window.winfo_screenwidth() * 0.90))
        height = min(app._px(570), int(self.window.winfo_screenheight() * 0.90))
        self.window.geometry(f"{width}x{height}")
        self.window.minsize(
            min(app._px(680), int(self.window.winfo_screenwidth() * 0.75)),
            min(app._px(500), int(self.window.winfo_screenheight() * 0.75)),
        )

        self.busy = False
        self.status: dict[str, Any] | None = None
        self.controls: dict[str, dict[str, Any]] = {}
        self.last_compatibility_warnings: tuple[str, ...] | None = None
        self.status_vars = {
            feature: tk.StringVar(value="讀取中…") for feature in SYSTEM_FEATURES
        }
        self.footer_var = tk.StringVar(value="")
        self.action_buttons: dict[str, ttk.Button] = {}

        self._build_ui()
        self.refresh()

    def _build_ui(self) -> None:
        outer = ttk.Frame(self.window, padding=self.app._px(16))
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)

        header = ttk.Frame(outer)
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)
        ttk.Label(header, text="系統快捷控制", style="Title.TLabel").grid(
            row=0, column=0, sticky="w"
        )
        self.refresh_button = ttk.Button(
            header, text="唯讀重新整理", command=self.refresh
        )
        self.refresh_button.grid(row=0, column=1, padx=(12, 0))

        controls_frame = ttk.LabelFrame(
            outer, text="MSI 硬體控制", padding=self.app._px(12)
        )
        controls_frame.grid(row=1, column=0, sticky="ew", pady=(12, 10))
        controls_frame.columnconfigure(0, weight=1)

        for row, feature in enumerate(SYSTEM_FEATURES):
            cell = ttk.Frame(controls_frame, padding=(0, self.app._px(7)))
            cell.grid(row=row, column=0, sticky="ew")
            cell.columnconfigure(0, weight=1)
            ttk.Label(
                cell, text=SYSTEM_FEATURE_LABELS[feature], style="Heading.TLabel"
            ).grid(row=0, column=0, sticky="w")
            ttk.Label(
                cell,
                text=SYSTEM_FEATURE_DESCRIPTIONS[feature],
                wraplength=self.app._px(475),
                justify="left",
                style="Muted.TLabel",
            ).grid(row=1, column=0, sticky="w", pady=(3, 0))
            ttk.Label(
                cell, textvariable=self.status_vars[feature], style="Status.TLabel"
            ).grid(row=0, column=1, padx=(12, 12), sticky="e")
            button = ttk.Button(
                cell,
                text="等待狀態",
                command=lambda selected=feature: self.prepare_toggle(selected),
            )
            button.grid(row=0, column=2, rowspan=2, sticky="e")
            self.action_buttons[feature] = button

            if row < len(SYSTEM_FEATURES) - 1:
                ttk.Separator(controls_frame, orient="horizontal").grid(
                    row=row, column=0, sticky="sew", pady=(self.app._px(64), 0)
                )

        notice = ttk.LabelFrame(outer, text="安全界線", padding=self.app._px(10))
        notice.grid(row=2, column=0, sticky="ew")
        ttk.Label(
            notice,
            text=(
                "狀態與預覽只執行唯讀查詢。每次修改前會顯示確切的直接 WMI 或服務命令與"
                "副作用，取消不會呼叫後端；寫入只送一次並讀回驗證，絕不自動重試。"
            ),
            wraplength=self.app._px(700),
            justify="left",
        ).pack(anchor="w")
        ttk.Label(
            notice,
            text=(
                "WebCam 已改用版本無關的直接 MSI_ACPI 後端；WinKey 與 Fn／Win 仍需 MSI "
                "常駐 hook 或多階段 EC／UEFI／HID 路徑，暫時保留服務後端。"
            ),
            wraplength=self.app._px(700),
            justify="left",
            foreground="#a12222",
        ).pack(anchor="w", pady=(6, 0))

        ttk.Label(outer, textvariable=self.footer_var, style="Muted.TLabel").grid(
            row=3, column=0, sticky="w", pady=(8, 0)
        )
        self._update_actions()

    def close(self) -> None:
        if self.busy:
            messagebox.showwarning(
                "操作進行中", "請等待目前系統控制操作完成。", parent=self.window
            )
            return
        self.app.system_dialog = None
        self.window.destroy()

    def _set_busy(self, busy: bool, footer: str = "") -> None:
        self.busy = busy
        self.footer_var.set(footer)
        self._update_actions()

    def _action_text(self, feature: str, enabled: bool) -> str:
        if feature == "WebCam":
            return "停用攝影機" if enabled else "啟用攝影機"
        if feature == "WinKey":
            return "停用 Windows 鍵" if enabled else "啟用 Windows 鍵"
        return "恢復原始位置" if enabled else "交換 Fn／Win"

    def _status_text(self, feature: str, enabled: bool) -> str:
        if feature == "SwitchFnWin":
            return "已交換" if enabled else "原始位置"
        return "已啟用" if enabled else "已停用"

    def _update_actions(self) -> None:
        for feature, button in self.action_buttons.items():
            state = self.controls.get(feature) or {}
            supported = state.get("Supported") is True
            known = isinstance(state.get("Enabled"), bool)
            if supported and known:
                button.configure(text=self._action_text(feature, state["Enabled"]))
            else:
                button.configure(text="不支援" if state else "等待狀態")
            enabled = supported and known and self.app.admin and not self.busy
            button.configure(state="normal" if enabled else "disabled")
        self.refresh_button.configure(state="disabled" if self.busy else "normal")

    def _show_error(self, title: str, error: Any, release_parent: bool = False) -> None:
        self._set_busy(False, "操作失敗")
        if release_parent:
            self.app._set_busy(False, "系統快捷控制失敗")
        self.app.log(f"系統快捷控制 {title}失敗：{error}")
        messagebox.showerror(title, str(error), parent=self.window)

    def refresh(self) -> None:
        if self.busy:
            return
        self._set_busy(True, "正在執行唯讀硬體／服務查詢…")
        self.app.log("系統快捷控制：開始唯讀讀取三個 allowlisted 功能。WebCam 優先使用直接 WMI。")
        self.app._run_async(
            lambda: invoke_system_api("SystemStatus"),
            self._finish_refresh,
            lambda error: self._show_error("狀態查詢", error),
        )

    def _finish_refresh(self, result: dict[str, Any]) -> None:
        if not result.get("Success"):
            self._show_error("狀態查詢", result.get("Error") or result)
            return
        self.status = result
        controls = result.get("Controls") or {}
        self.controls = {
            feature: controls.get(feature) or {} for feature in SYSTEM_FEATURES
        }
        for feature, state in self.controls.items():
            if state.get("UnavailableReason"):
                text = "MSI 服務不可用"
            elif state.get("Supported") is not True:
                text = "此機型不支援"
            elif isinstance(state.get("Enabled"), bool):
                text = self._status_text(feature, state["Enabled"])
            else:
                text = "狀態未知"
            self.status_vars[feature].set(text)
        warnings = tuple(str(item) for item in (result.get("CompatibilityWarnings") or []))
        if warnings:
            warning_text = "\n".join(f"• {item}" for item in warnings)
            self._set_busy(False, "⚠ MSI 元件版本與已驗證版本不同；功能仍可使用")
            self.app.log(f"系統快捷控制相容性警告：{' | '.join(warnings)}")
            if warnings != self.last_compatibility_warnings:
                messagebox.showwarning(
                    "MSI 元件版本尚未驗證",
                    "偵測到不同版本。簽章、服務身分與介面檢查均已通過，"
                    "因此不會封鎖操作，但此組合尚未完成實機驗證：\n\n"
                    f"{warning_text}",
                    parent=self.window,
                )
        elif result.get("CentralServerAvailable") is False:
            self._set_busy(False, "WebCam 直接後端可用；其餘 MSI 服務控制不可用")
            central_error = str(result.get("CentralServerError") or "未知錯誤")
            self.app.log(f"CentralServer 不可用；保留直接 WebCam 控制：{central_error}")
        else:
            self._set_busy(False, "唯讀狀態已更新；沒有送出 Set")
        self.last_compatibility_warnings = warnings
        summary = ", ".join(
            f"{feature}={state.get('Enabled')}" for feature, state in self.controls.items()
        )
        self.app.log(f"系統快捷控制狀態：{summary}。")

    def prepare_toggle(self, feature: str) -> None:
        if self.busy or feature not in SYSTEM_FEATURES:
            return
        state = self.controls.get(feature) or {}
        if state.get("Supported") is not True or not isinstance(
            state.get("Enabled"), bool
        ):
            return
        target = not state["Enabled"]
        self._set_busy(True, "正在建立 side-effect-free plan…")
        self.app._run_async(
            lambda: invoke_system_api(
                "SystemPlan", feature=feature, enabled=target
            ),
            lambda plan: self._confirm_toggle(feature, target, plan),
            lambda error: self._show_error("無法建立系統控制計畫", error),
        )

    def _confirm_toggle(
        self, feature: str, target: bool, plan: dict[str, Any]
    ) -> None:
        if not plan.get("Success"):
            self._show_error("無法建立系統控制計畫", plan.get("Error") or plan)
            return
        if plan.get("AlreadyApplied"):
            self._set_busy(False, "狀態已在背景變更；正在重新整理")
            self.refresh()
            return

        side_effects = "\n".join(
            f"• {item}" for item in (plan.get("SideEffects") or [])
        )
        warnings = tuple(str(item) for item in (plan.get("CompatibilityWarnings") or []))
        compatibility_notice = ""
        if warnings:
            compatibility_notice = (
                "⚠ 相容性警告：目前 MSI 元件版本與已驗證版本不同，但簽章、服務身分、"
                "IsSupport 與 Get 檢查已通過。\n"
                + "\n".join(f"• {item}" for item in warnings)
                + "\n\n"
            )
        backend = str(plan.get("Backend") or "Unknown")
        operation_label = (
            "直接硬體命令" if plan.get("ServiceIndependent") else "CentralServer 命令"
        )
        frame_text = str(plan.get("FrameHex") or "不適用（沒有 TCP frame）")
        accepted = messagebox.askyesno(
            "確認 MSI 系統設定寫入",
            compatibility_notice
            + f"功能：{SYSTEM_FEATURE_LABELS[feature]}\n"
            f"目前：{self._status_text(feature, bool(plan.get('CurrentEnabled')))}\n"
            f"目標：{self._status_text(feature, target)}\n\n"
            f"後端：{backend}\n"
            f"{operation_label}：{plan.get('Command')}\n"
            f"Frame：{frame_text}\n\n"
            f"已知副作用：\n{side_effects}\n\n"
            "按『是』後只送出一次 Set，再用 Get 讀回驗證；失敗不會自動重試。",
            parent=self.window,
        )
        if not accepted:
            self._set_busy(False, "已取消；沒有送出 Set")
            self.app.log(
                f"使用者取消 {feature} 修改；沒有呼叫 SystemSet。"
            )
            return

        self._set_busy(True, f"正在寫入並讀回驗證 {feature}…")
        self.app._set_busy(True, "正在執行系統快捷控制…")
        self.app._run_async(
            lambda: invoke_system_api(
                "SystemSet", feature=feature, enabled=target, confirmed=True
            ),
            self._finish_set,
            lambda error: self._show_error(
                "系統設定寫入", error, release_parent=True
            ),
        )

    def _finish_set(self, result: dict[str, Any]) -> None:
        self.app._set_busy(False, "系統快捷控制操作已結束")
        self._set_busy(False, "系統快捷控制操作已結束")
        if not result.get("Success"):
            self._show_error("系統設定寫入", result.get("Error") or result)
            return
        feature = str(result.get("Feature"))
        enabled = bool(result.get("Enabled"))
        warnings = tuple(str(item) for item in (result.get("CompatibilityWarnings") or []))
        self.app.log(
            f"系統快捷控制已驗證：{feature}={enabled}，"
            f"RequestSent={result.get('RequestSent')}。"
        )
        warning_suffix = ""
        if warnings:
            warning_suffix = "\n\n相容性警告仍然存在：\n" + "\n".join(
                f"• {item}" for item in warnings
            )
        messagebox.showinfo(
            "系統設定已驗證",
            f"{SYSTEM_FEATURE_LABELS.get(feature, feature)}："
            f"{self._status_text(feature, enabled)}\n\n"
            "已由 MSI CentralServer 的 Get 回應讀回驗證。" + warning_suffix,
            parent=self.window,
        )
        self.refresh()


class MsiGpuOcWindow:
    """GPU-only scene/profile editor backed by the guarded PowerShell API."""

    def __init__(self, app: FuckMsiCenterApp) -> None:
        self.app = app
        self.window = tk.Toplevel(app.root)
        self.window.title(f"{APP_NAME} | GPU 核心／VRAM 調校")
        self.window.transient(app.root)
        self.window.protocol("WM_DELETE_WINDOW", self.close)
        width = min(app._px(760), int(self.window.winfo_screenwidth() * 0.90))
        height = min(app._px(780), int(self.window.winfo_screenheight() * 0.90))
        self.window.geometry(f"{width}x{height}")
        self.window.minsize(
            min(app._px(690), int(self.window.winfo_screenwidth() * 0.75)),
            min(app._px(680), int(self.window.winfo_screenheight() * 0.75)),
        )

        self.busy = False
        self.status: dict[str, Any] | None = None
        self.native: dict[str, Any] | None = None
        self.model = ""
        self.nvidia_gpu = ""
        self.core_min = 0
        self.core_max = 0
        self.memory_min = 0
        self.memory_max = 0
        self.msi_core_max = 0
        self.msi_memory_max = 0
        self._syncing_slider = False

        self.target_var = tk.StringVar(value=OC_TARGET_LABELS["ExtremePerformance"])
        self.core_var = tk.StringVar(value="0")
        self.memory_var = tk.StringVar(value="0")
        self.system_var = tk.StringVar(value="讀取中…")
        self.scene_var = tk.StringVar(value="讀取中…")
        self.native_var = tk.StringVar(value="讀取中…")
        self.range_var = tk.StringVar(value="讀取中…")
        self.footer_var = tk.StringVar(value="")

        self._build_ui()
        self.refresh()

    def _build_ui(self) -> None:
        outer = ttk.Frame(self.window, padding=self.app._px(16))
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)

        header = ttk.Frame(outer)
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)
        ttk.Label(header, text="GPU 核心／VRAM Offset", style="Title.TLabel").grid(
            row=0, column=0, sticky="w"
        )
        self.refresh_button = ttk.Button(header, text="唯讀重新整理", command=self.refresh)
        self.refresh_button.grid(row=0, column=1, padx=(12, 0))

        status_frame = ttk.LabelFrame(outer, text="MSI／Native 狀態", padding=self.app._px(10))
        status_frame.grid(row=1, column=0, sticky="ew", pady=(12, 10))
        status_frame.columnconfigure(1, weight=1)
        labels = (
            ("系統：", self.system_var),
            ("User Scenario：", self.scene_var),
            ("目前 GPU：", self.native_var),
            ("MSI 允許範圍：", self.range_var),
        )
        for row, (caption, variable) in enumerate(labels):
            ttk.Label(status_frame, text=caption).grid(row=row, column=0, sticky="nw", pady=2)
            ttk.Label(
                status_frame,
                textvariable=variable,
                wraplength=self.app._px(565),
                justify="left",
            ).grid(row=row, column=1, sticky="w", pady=2)

        edit_frame = ttk.LabelFrame(outer, text="場景與 offset", padding=self.app._px(12))
        edit_frame.grid(row=2, column=0, sticky="ew", pady=(0, 10))
        edit_frame.columnconfigure(1, weight=1)
        ttk.Label(edit_frame, text="目標：").grid(row=0, column=0, sticky="w")
        self.target_combo = ttk.Combobox(
            edit_frame,
            textvariable=self.target_var,
            values=tuple(OC_TARGET_LABELS.values()),
            state="readonly",
        )
        self.target_combo.grid(row=0, column=1, columnspan=2, sticky="ew")
        self.target_combo.bind("<<ComboboxSelected>>", self._on_target_changed)

        ttk.Label(edit_frame, text="GPU core offset：").grid(
            row=1, column=0, sticky="w", pady=(10, 0)
        )
        self.core_spin = ttk.Spinbox(
            edit_frame,
            textvariable=self.core_var,
            from_=0,
            to=0,
            increment=1,
            width=12,
            command=self._sync_core_scale_from_text,
        )
        self.core_spin.grid(row=1, column=1, sticky="w", pady=(10, 0))
        ttk.Label(edit_frame, text="MHz").grid(row=1, column=2, sticky="w", pady=(10, 0))
        self.core_spin.bind("<KeyRelease>", self._sync_core_scale_from_text)
        self.core_spin.bind("<FocusOut>", self._sync_core_scale_from_text)
        self.core_scale = tk.Scale(
            edit_frame,
            from_=0,
            to=0,
            resolution=1,
            tickinterval=1,
            showvalue=False,
            orient="horizontal",
            length=self.app._px(620),
            command=self._on_core_scale,
            highlightthickness=0,
            font=("Microsoft JhengHei UI", 8),
        )
        self.core_scale.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(2, 4))

        ttk.Label(edit_frame, text="VRAM offset：").grid(
            row=3, column=0, sticky="w", pady=(8, 0)
        )
        self.memory_spin = ttk.Spinbox(
            edit_frame,
            textvariable=self.memory_var,
            from_=0,
            to=0,
            increment=1,
            width=12,
            command=self._sync_memory_scale_from_text,
        )
        self.memory_spin.grid(row=3, column=1, sticky="w", pady=(8, 0))
        ttk.Label(edit_frame, text="MHz").grid(row=3, column=2, sticky="w", pady=(8, 0))
        self.memory_spin.bind("<KeyRelease>", self._sync_memory_scale_from_text)
        self.memory_spin.bind("<FocusOut>", self._sync_memory_scale_from_text)
        self.memory_scale = tk.Scale(
            edit_frame,
            from_=0,
            to=0,
            resolution=1,
            tickinterval=1,
            showvalue=False,
            orient="horizontal",
            length=self.app._px(620),
            command=self._on_memory_scale,
            highlightthickness=0,
            font=("Microsoft JhengHei UI", 8),
        )
        self.memory_scale.grid(row=4, column=0, columnspan=3, sticky="ew", pady=(2, 4))

        button_bar = ttk.Frame(edit_frame)
        button_bar.grid(row=5, column=0, columnspan=3, sticky="ew", pady=(10, 0))
        for column in range(3):
            button_bar.columnconfigure(column, weight=1, uniform="oc-actions")
        self.preview_button = ttk.Button(button_bar, text="預覽計畫", command=self.preview)
        self.preview_button.grid(row=0, column=0, sticky="ew", padx=(0, 4))
        self.save_button = ttk.Button(
            button_bar, text="保存 Extreme／User profile", command=self.save_profile
        )
        self.save_button.grid(row=0, column=1, sticky="ew", padx=4)
        self.apply_button = ttk.Button(
            button_bar, text="立即套用至 GPU", command=self.apply_offset
        )
        self.apply_button.grid(row=0, column=2, sticky="ew", padx=(4, 0))

        notice = ttk.LabelFrame(outer, text="行為與安全界線", padding=self.app._px(10))
        notice.grid(row=3, column=0, sticky="ew")
        ttk.Label(
            notice,
            text=(
                "Extreme Performance 與 User 可各自保存 profile；保存只寫入 MSI 的 High/User "
                "Registry 值，不會立即改變 GPU。Gaming Active 引用 Extreme profile，Gaming Inactive "
                "使用 0/0。滑块上限来自 NVIDIA driver 的 P0 delta min/max；查询失败才回退 MSI policy。"
                "『立即套用』只改 driver offset、不切换完整场景，也不会自动重试。"
            ),
            wraplength=self.app._px(700),
            justify="left",
        ).pack(anchor="w")
        ttk.Label(
            notice,
            text=(
                "Offset 不是絕對時脈。即使數值位於 MSI UI 範圍，也可能造成畫面異常、driver reset "
                "或系統不穩；套用前請保存工作。"
            ),
            foreground="#a12222",
            wraplength=self.app._px(700),
            justify="left",
        ).pack(anchor="w", pady=(6, 0))

        ttk.Label(outer, textvariable=self.footer_var, style="Muted.TLabel").grid(
            row=4, column=0, sticky="w", pady=(8, 0)
        )
        self._update_actions()

    def close(self) -> None:
        if self.busy:
            messagebox.showwarning(
                "操作進行中", "請等待目前 GPU 調校操作完成。", parent=self.window
            )
            return
        self.app.oc_dialog = None
        self.window.destroy()

    def _selected_target(self) -> str:
        return OC_LABEL_TARGETS.get(self.target_var.get(), "ExtremePerformance")

    def _set_busy(self, busy: bool, footer: str = "") -> None:
        self.busy = busy
        self.footer_var.set(footer)
        self._update_actions()

    def _update_actions(self) -> None:
        loaded = self.status is not None
        editable = self._selected_target() in ("ExtremePerformance", "User")
        normal = "normal" if loaded and not self.busy else "disabled"
        self.refresh_button.configure(state="disabled" if self.busy else "normal")
        self.target_combo.configure(state="disabled" if self.busy else "readonly")
        self.core_spin.configure(state=normal)
        self.memory_spin.configure(state=normal)
        self.core_scale.configure(state=normal)
        self.memory_scale.configure(state=normal)
        self.preview_button.configure(state=normal)
        self.apply_button.configure(state=normal if self.app.admin else "disabled")
        self.save_button.configure(
            state="normal" if loaded and editable and self.app.admin and not self.busy else "disabled"
        )

    def _show_error(self, title: str, error: Any, release_parent: bool = False) -> None:
        self._set_busy(False, "操作失敗")
        if release_parent:
            self.app._set_busy(False, "GPU 調校操作失敗")
        self.app.log(f"GPU OC {title}失敗：{error}")
        messagebox.showerror(title, str(error), parent=self.window)

    def refresh(self) -> None:
        if self.busy:
            return
        self._set_busy(True, "正在唯讀查詢 Registry 與 GInf…")
        self.app.log("GPU OC：開始唯讀讀取場景 Registry 與 native offset。")

        def work() -> tuple[dict[str, Any], dict[str, Any]]:
            return invoke_oc_api("OCStatus"), invoke_oc_api("OCProbe")

        self.app._run_async(
            work,
            self._finish_refresh,
            lambda error: self._show_error("GPU OC 狀態查詢", error),
        )

    def _finish_refresh(self, result: tuple[dict[str, Any], dict[str, Any]]) -> None:
        status, native = result
        if not status.get("Success"):
            self._show_error("GPU OC 狀態查詢", status.get("Error") or status)
            return
        self.status = status
        self.native = native if native.get("Success") else None
        self.model = str(status.get("Model") or "")
        controllers = status.get("VideoControllers") or []
        if isinstance(controllers, str):
            controllers = [controllers]
        self.nvidia_gpu = next(
            (str(name) for name in controllers if "NVIDIA" in str(name).upper()), ""
        )
        registry = status.get("Registry") or {}
        limits = status.get("Limits") or {}
        self.core_min = int(limits.get("CoreMinimumMHz", registry.get("CoreMinimumMHz", 0)))
        self.core_max = int(limits.get("CoreMaximumMHz", registry.get("CoreMaximumMHz", 0)))
        self.memory_min = int(
            limits.get("MemoryMinimumMHz", registry.get("MemoryMinimumMHz", 0))
        )
        self.memory_max = int(
            limits.get("MemoryMaximumMHz", registry.get("MemoryMaximumMHz", 0))
        )
        self.msi_core_max = int(registry.get("CoreMaximumMHz", 0))
        self.msi_memory_max = int(registry.get("MemoryMaximumMHz", 0))
        self.core_spin.configure(from_=self.core_min, to=self.core_max)
        self.memory_spin.configure(from_=self.memory_min, to=self.memory_max)
        self.core_scale.configure(
            from_=self.core_min,
            to=self.core_max,
            tickinterval=slider_tick_interval(self.core_min, self.core_max),
        )
        self.memory_scale.configure(
            from_=self.memory_min,
            to=self.memory_max,
            tickinterval=slider_tick_interval(self.memory_min, self.memory_max),
        )

        self.system_var.set(
            f"{status.get('Manufacturer')} {self.model} / {self.nvidia_gpu or '未偵測到 NVIDIA GPU'}"
        )
        self.scene_var.set(
            f"{status.get('CurrentMode')}（index {status.get('CurrentModeIndex')}），"
            f"Intelligent={registry.get('Intelligent')}"
        )
        if self.native:
            self.native_var.set(
                f"core {self.native.get('CoreOffsetMHz')} MHz / VRAM "
                f"{self.native.get('MemoryOffsetMHz')} MHz / P{self.native.get('PState')} / "
                f"{self.native.get('CurrentTemperatureC')} °C"
            )
        else:
            self.native_var.set(f"native probe 不可用：{native.get('Error') or '未知錯誤'}")
        driver_text = (
            f"NVIDIA P0 core {limits.get('DriverCoreMinimumMHz')}.."
            f"{limits.get('DriverCoreMaximumMHz')} MHz，VRAM "
            f"{limits.get('DriverMemoryMinimumMHz')}..{limits.get('DriverMemoryMaximumMHz')} MHz"
            if limits.get("DriverProbeSucceeded")
            else f"driver query 失败，回退 MSI policy：{limits.get('DriverProbeError')}"
        )
        self.range_var.set(
            f"GUI core {self.core_min}..{self.core_max} MHz；VRAM "
            f"{self.memory_min}..{self.memory_max} MHz。{driver_text}；"
            f"MSI UI policy core/VRAM 上限 {self.msi_core_max}/{self.msi_memory_max} MHz"
        )
        current_mode = status.get("CurrentMode")
        if current_mode in OC_TARGET_LABELS:
            self.target_var.set(OC_TARGET_LABELS[current_mode])

        self.load_selected_profile()

        # 读取到 GPU 或者 VRAM 的 offset 如果不等于零，则自动将滑块移动到对应的位置
        read_core = 0
        read_memory = 0
        if self.native:
            try:
                read_core = int(self.native.get("CoreOffsetMHz", 0) or 0)
            except (ValueError, TypeError):
                read_core = 0
            try:
                read_memory = int(self.native.get("MemoryOffsetMHz", 0) or 0)
            except (ValueError, TypeError):
                read_memory = 0

        # 若 native 未读出非零值，再检查 status 的 EffectivePlan
        if read_core == 0 and status.get("EffectivePlan"):
            try:
                read_core = int(status["EffectivePlan"].get("CoreOffsetMHz", 0) or 0)
            except (ValueError, TypeError):
                read_core = 0
        if read_memory == 0 and status.get("EffectivePlan"):
            try:
                read_memory = int(status["EffectivePlan"].get("MemoryOffsetMHz", 0) or 0)
            except (ValueError, TypeError):
                read_memory = 0

        # 如果读取到非零 offset，自动将对应滑块移动到该位置
        if read_core != 0:
            self._set_core_value(read_core)
        if read_memory != 0:
            self._set_memory_value(read_memory)

        if read_core != 0 or read_memory != 0:
            self._set_busy(
                False,
                f"已讀取到目前 GPU/VRAM offset（Core: {read_core} MHz, VRAM: {read_memory} MHz），已自動同步至滑塊",
            )
        else:
            self._set_busy(False, "唯讀狀態已更新；尚未執行任何寫入")
        self.app.log(
            "GPU OC 狀態："
            f"Scene={status.get('CurrentMode')}，"
            f"Native={self.native.get('CoreOffsetMHz') if self.native else '?'} / "
            f"{self.native.get('MemoryOffsetMHz') if self.native else '?'} MHz。"
        )

    def _on_target_changed(self, _event: tk.Event[Any] | None = None) -> None:
        self.load_selected_profile()
        self._update_actions()

    def load_selected_profile(self) -> None:
        if self.status is None:
            return
        target = self._selected_target()
        core, memory = oc_profile_values(self.status, target)

        # 若所選為可調校場景且 profile 為 0，若讀取到的 live GPU/VRAM offset 非零，則自動帶入
        if target in ("ExtremePerformance", "GamingActive", "User"):
            native_core = 0
            native_memory = 0
            if self.native:
                try:
                    native_core = int(self.native.get("CoreOffsetMHz", 0) or 0)
                except (ValueError, TypeError):
                    native_core = 0
                try:
                    native_memory = int(self.native.get("MemoryOffsetMHz", 0) or 0)
                except (ValueError, TypeError):
                    native_memory = 0
            if core == 0 and native_core != 0:
                core = native_core
            if memory == 0 and native_memory != 0:
                memory = native_memory

        self._set_scale_values(core, memory)
        self.footer_var.set("已載入該場景依 MSI broker 規則會使用的 offset")

    def _set_core_value(self, core: int) -> None:
        clamped = max(self.core_min, min(self.core_max, int(core)))
        self.core_var.set(str(clamped))
        prev_state = str(self.core_scale.cget("state"))
        self._syncing_slider = True
        try:
            if prev_state == "disabled":
                self.core_scale.configure(state="normal")
            self.core_scale.set(clamped)
        finally:
            if prev_state == "disabled":
                self.core_scale.configure(state=prev_state)
            self._syncing_slider = False

    def _set_memory_value(self, memory: int) -> None:
        clamped = max(self.memory_min, min(self.memory_max, int(memory)))
        self.memory_var.set(str(clamped))
        prev_state = str(self.memory_scale.cget("state"))
        self._syncing_slider = True
        try:
            if prev_state == "disabled":
                self.memory_scale.configure(state="normal")
            self.memory_scale.set(clamped)
        finally:
            if prev_state == "disabled":
                self.memory_scale.configure(state=prev_state)
            self._syncing_slider = False

    def _set_scale_values(self, core: int, memory: int) -> None:
        self._set_core_value(core)
        self._set_memory_value(memory)

    def _on_core_scale(self, value: str) -> None:
        if not self._syncing_slider:
            self.core_var.set(str(int(round(float(value)))))

    def _on_memory_scale(self, value: str) -> None:
        if not self._syncing_slider:
            self.memory_var.set(str(int(round(float(value)))))

    def _sync_core_scale_from_text(self, _event: tk.Event[Any] | None = None) -> None:
        try:
            value = int(self.core_var.get().strip(), 10)
        except ValueError:
            return
        if self.core_min <= value <= self.core_max:
            self._syncing_slider = True
            try:
                self.core_scale.set(value)
            finally:
                self._syncing_slider = False

    def _sync_memory_scale_from_text(self, _event: tk.Event[Any] | None = None) -> None:
        try:
            value = int(self.memory_var.get().strip(), 10)
        except ValueError:
            return
        if self.memory_min <= value <= self.memory_max:
            self._syncing_slider = True
            try:
                self.memory_scale.set(value)
            finally:
                self._syncing_slider = False

    def _offsets(self) -> tuple[int, int]:
        try:
            core = int(self.core_var.get().strip(), 10)
            memory = int(self.memory_var.get().strip(), 10)
        except ValueError as error:
            raise ValueError("Core 與 VRAM offset 必須是整數 MHz。") from error
        if not self.core_min <= core <= self.core_max:
            raise ValueError(f"Core offset 必須在 {self.core_min}..{self.core_max} MHz。")
        if not self.memory_min <= memory <= self.memory_max:
            raise ValueError(
                f"VRAM offset 必須在 {self.memory_min}..{self.memory_max} MHz。"
            )
        target = self._selected_target()
        if target in ("Balanced", "Silent", "SuperBattery", "GamingInactive") and (
            core != 0 or memory != 0
        ):
            raise ValueError("MSI broker 對此場景固定使用 0/0 MHz。")
        return core, memory

    def preview(self) -> None:
        try:
            core, memory = self._offsets()
        except ValueError as error:
            self._show_error("輸入錯誤", error)
            return
        target = self._selected_target()
        self._set_busy(True, "正在建立 side-effect-free plan…")
        self.app._run_async(
            lambda: invoke_oc_api(
                "OCPlan", target=target, core_offset=core, memory_offset=memory
            ),
            lambda result: self._finish_preview(target, result),
            lambda error: self._show_error("無法建立 GPU OC 計畫", error),
        )

    def _finish_preview(self, selected_target: str, result: dict[str, Any]) -> None:
        self._set_busy(False, "計畫已建立；沒有寫入 Registry 或 GPU")
        if not result.get("Success"):
            self._show_error("無法建立 GPU OC 計畫", result.get("Error") or result)
            return
        self.app.log(
            f"GPU OC dry-run：Target={selected_target} -> {result.get('Target')}，"
            f"Arguments={result.get('DirectArguments')}；沒有寫入。"
        )
        messagebox.showinfo(
            "GPU OC 計畫（唯讀）",
            f"GUI 選擇：{OC_TARGET_LABELS[selected_target]}\n"
            f"實際 MSI profile：{result.get('Target')} / index {result.get('ScenarioIndex')}\n"
            f"Core：{result.get('CoreOffsetMHz')} MHz\n"
            f"VRAM：{result.get('MemoryOffsetMHz')} MHz\n\n"
            f"限制來源：{result.get('LimitSource')}\n"
            f"允許範圍：core {result.get('AllowedCoreRangeMHz')}，"
            f"VRAM {result.get('AllowedMemoryRangeMHz')}\n\n"
            "此預覽沒有寫入 Registry 或 GPU。",
            parent=self.window,
        )

    def _msi_policy_warning(self, core: int, memory: int) -> str:
        if core <= self.msi_core_max and memory <= self.msi_memory_max:
            return ""
        return (
            "\n\n注意：此數值高於 MSI Center UI 的 200 MHz policy，但仍位於目前 "
            "NVIDIA driver 回報的 P0 delta 範圍內。MSI Center 更新、重開或切換場景時可能"
            "覆蓋／重設該值；driver 允許也不代表硬體穩定。"
        )

    def save_profile(self) -> None:
        target = self._selected_target()
        if target not in ("ExtremePerformance", "User"):
            self._show_error("不能保存此場景", "只有 Extreme Performance 與 User 有 MSI OC profile。")
            return
        try:
            core, memory = self._offsets()
        except ValueError as error:
            self._show_error("輸入錯誤", error)
            return
        if not messagebox.askyesno(
            "確認保存 MSI GPU profile",
            f"目標：{OC_TARGET_LABELS[target]}\n"
            f"Core：{core} MHz\nVRAM：{memory} MHz\n\n"
            "這會更新 MSI Center 的 High/User Registry profile，但不會立即套用到 GPU。"
            "之後 MSI Center、場景切換或 Gaming Mode 可能使用此值。"
            f"{self._msi_policy_warning(core, memory)}\n\n確定保存嗎？",
            icon="warning",
            parent=self.window,
        ):
            self.app.log("使用者取消 GPU OC profile 保存；沒有寫入 Registry。")
            return
        self._set_busy(True, "正在保存 MSI GPU profile…")
        self.app._set_busy(True, "正在保存 GPU profile…")
        self.app._run_async(
            lambda: invoke_oc_api(
                "OCSave",
                target=target,
                core_offset=core,
                memory_offset=memory,
                expected_model=self.model,
                expected_gpu=self.nvidia_gpu,
                confirmed=True,
            ),
            self._finish_save,
            lambda error: self._show_error("保存 GPU profile", error, release_parent=True),
        )

    def _finish_save(self, result: dict[str, Any]) -> None:
        self.app._set_busy(False, "GPU profile 保存操作已結束")
        self._set_busy(False, "GPU profile 保存操作已結束")
        if not result.get("Success"):
            self._show_error("保存 GPU profile", result.get("Error") or result)
            return
        self.app.log(
            f"GPU profile：Target={result.get('Target')}，Core={result.get('CoreOffsetMHz')}，"
            f"VRAM={result.get('MemoryOffsetMHz')}，AlreadySaved={result.get('AlreadySaved')}。"
        )
        messagebox.showinfo(
            "GPU profile 已保存",
            "MSI profile 已更新；本操作沒有立即改變 GPU offset。",
            parent=self.window,
        )
        self.refresh()

    def apply_offset(self) -> None:
        try:
            core, memory = self._offsets()
        except ValueError as error:
            self._show_error("輸入錯誤", error)
            return
        target = self._selected_target()
        if not messagebox.askyesno(
            "確認立即套用 GPU offset",
            f"來源：{OC_TARGET_LABELS[target]}\n"
            f"Core：{core} MHz\nVRAM：{memory} MHz\n\n"
            "這會立即透過 MSI 簽署的 gpuControl.exe／GInf.dll 修改 NVIDIA driver offset。"
            "它不保存 profile、不切換完整場景，也不會自動重試。\n\n"
            "不穩定可能造成畫面異常或 driver reset；請先保存工作。"
            f"{self._msi_policy_warning(core, memory)}\n\n確定套用嗎？",
            icon="warning",
            parent=self.window,
        ):
            self.app.log("使用者取消 GPU offset 套用；沒有呼叫 gpuControl.exe。")
            return
        self._set_busy(True, "正在套用並讀回驗證 GPU offset…")
        self.app._set_busy(True, "正在套用 GPU offset…")
        self.app._run_async(
            lambda: invoke_oc_api(
                "OCApply",
                core_offset=core,
                memory_offset=memory,
                expected_model=self.model,
                expected_gpu=self.nvidia_gpu,
                confirmed=True,
            ),
            self._finish_apply,
            lambda error: self._show_error("套用 GPU offset", error, release_parent=True),
        )

    def _finish_apply(self, result: dict[str, Any]) -> None:
        self.app._set_busy(False, "GPU offset 套用操作已結束")
        self._set_busy(False, "GPU offset 套用操作已結束")
        if not result.get("Success"):
            self._show_error("套用 GPU offset", result.get("Error") or result)
            return
        self.app.log(
            f"GPU offset 套用成功：Core={result.get('CoreOffsetMHz')}，"
            f"VRAM={result.get('MemoryOffsetMHz')}，AlreadyApplied={result.get('AlreadyApplied')}。"
        )
        messagebox.showinfo(
            "GPU offset 已驗證",
            f"Core：{result.get('CoreOffsetMHz')} MHz\n"
            f"VRAM：{result.get('MemoryOffsetMHz')} MHz\n\n"
            "已由 GInf 讀回驗證。此操作沒有保存 MSI profile。",
            parent=self.window,
        )
        self.refresh()

def run_self_test() -> int:
    from unittest import mock

    sample = '{"Success":true,"Mode":"Integrated","ModeIndex":2}'
    parsed = parse_json_output(sample)
    assert parsed["Success"] is True and parsed["ModeIndex"] == 2
    value, pending = parse_ap_state("Data[1]             : 0x02")
    assert value == 2 and pending is True
    value, pending = parse_ap_state("Data[1]             : 0x00")
    assert value == 0 and pending is False
    assert normalize_oc_target("GamingActive") == "ExtremePerformance"
    assert normalize_oc_target("GamingInactive") == "Balanced"
    sample_oc = {
        "Registry": {
            "ExtremeCoreMHz": 75,
            "ExtremeMemoryMHz": 0,
            "UserCoreMHz": 20,
            "UserMemoryMHz": 40,
        }
    }
    assert oc_profile_values(sample_oc, "GamingActive") == (75, 0)
    assert oc_profile_values(sample_oc, "GamingInactive") == (0, 0)
    assert oc_profile_values(sample_oc, "User") == (20, 40)
    assert slider_tick_interval(0, 1000) == 200
    assert slider_tick_interval(0, 3000) == 500
    shutdown_args = immediate_shutdown_arguments()
    assert shutdown_args[-3:] == ["/s", "/t", "0"]
    assert Path(shutdown_args[0]).name.lower() == "shutdown.exe"
    assert should_start_auto_shutdown(
        {"Success": True, "RequestAccepted": True}, enabled=True
    )
    assert not should_start_auto_shutdown(
        {"Success": False, "RequestAccepted": True}, enabled=True
    )
    assert not should_start_auto_shutdown(
        {"Success": True, "RequestAccepted": False}, enabled=True
    )
    assert not should_start_auto_shutdown(
        {"Success": True, "RequestAccepted": True}, enabled=False
    )
    fake_process = mock.Mock(pid=4321)
    with mock.patch.object(subprocess, "Popen", return_value=fake_process) as popen:
        assert start_immediate_shutdown() == 4321
        assert popen.call_args.args[0] == shutdown_args
    with mock.patch.object(
        sys.modules[__name__],
        "run_process",
        return_value=(0, '{"Success":true}'),
    ) as process:
        result = invoke_oc_api(
            "OCApply",
            core_offset=25,
            memory_offset=50,
            expected_model="MODEL",
            expected_gpu="NVIDIA GPU",
            confirmed=True,
        )
        assert result["Success"] is True
        arguments = process.call_args.args[0]
        assert "-ConfirmHardwareRisk" in arguments
        assert arguments[arguments.index("-CoreOffsetMHz") + 1] == "25"
        assert arguments[arguments.index("-MemoryOffsetMHz") + 1] == "50"
    with mock.patch.object(
        sys.modules[__name__],
        "run_process",
        return_value=(0, '{"Success":true}'),
    ) as process:
        result = invoke_system_api(
            "SystemSet", feature="WebCam", enabled=False, confirmed=True
        )
        assert result["Success"] is True
        arguments = process.call_args.args[0]
        assert "-ConfirmSystemChange" in arguments
        assert arguments[arguments.index("-Feature") + 1] == "WebCam"
        assert arguments[arguments.index("-Enabled") + 1] == "0"
    elevation_executable, elevation_parameters = elevation_launch_details()
    assert elevation_executable == sys.executable
    assert str(SCRIPT_PATH) in elevation_parameters
    print("Self-test passed.")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return run_self_test()
    if os.name != "nt":
        raise SystemExit("This GUI only supports Windows.")
    if (
        not API_CLI.is_file()
        or not AP_PROBE.is_file()
        or not OC_API_MODULE.is_file()
        or not SYSTEM_API_MODULE.is_file()
        or not DIRECT_API_MODULE.is_file()
        or not POWERSHELL.is_file()
    ):
        raise SystemExit(f"Required {APP_NAME} backend or Windows PowerShell file was not found.")
    if not is_administrator():
        result = request_administrator_relaunch()
        if result > 32:
            return 0
        show_elevation_required_error(result)
        return 1
    dpi_awareness = enable_windows_high_dpi_awareness()
    root = tk.Tk()
    FuckMsiCenterApp(root, dpi_awareness)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
