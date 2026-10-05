"""Non-destructive Tk/control-flow tests for Fuck-MSI-Center."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tkinter as tk
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "fuck_msi_center.py"
SPEC = importlib.util.spec_from_file_location("fuck_msi_center", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
GUI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUI)


class GuiShutdownFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.dpi_mode = GUI.enable_windows_high_dpi_awareness()

    def setUp(self) -> None:
        self.root = tk.Tk()
        self.root.withdraw()
        with mock.patch.object(GUI.FuckMsiCenterApp, "refresh_status"):
            self.app = GUI.FuckMsiCenterApp(self.root, self.dpi_mode)
        self.app.admin = True
        self.app.hardware_model = "Sword 16 HX B14VGKG"
        self.app.access_tier = "Full"
        self.root.update_idletasks()

    def tearDown(self) -> None:
        self.root.destroy()

    def test_auto_shutdown_is_default_off(self) -> None:
        self.assertFalse(self.app.auto_shutdown_var.get())

    def test_exact_model_access_tiers(self) -> None:
        self.assertEqual(GUI.model_access_tier("Sword 16 HX B14VGKG"), "Full")
        self.assertEqual(GUI.model_access_tier("Sword 16 HX B14VEKG"), "GpuModeOnly")
        self.assertEqual(GUI.model_access_tier("Sword 16 HX B14VFKG"), "GpuModeOnly")
        self.assertEqual(GUI.model_access_tier("Sword 16 HX Unknown"), "Unsupported")

    def test_horizontal_model_warns_once_and_locks_non_gpu_features(self) -> None:
        status = {
            "Success": True,
            "Model": "Sword 16 HX B14VFKG",
            "AccessTier": "GpuModeOnly",
            "HorizontalCompatibility": True,
            "Mode": "Hybrid",
            "ModeIndex": 0,
            "StagedTargetIndex": 0,
            "LegacyWmiData0": "0x0B",
            "NewSwitchSupport": True,
            "DiscreteSupport": True,
            "IntegratedSupport": True,
        }
        ap_state = {"Data1": 0, "Pending": False}
        with mock.patch.object(GUI.messagebox, "showwarning") as warning:
            self.app._finish_refresh((status, ap_state, None))
            self.app._finish_refresh((status, ap_state, None))
        warning.assert_called_once()
        self.assertEqual(self.app.access_tier, "GpuModeOnly")
        self.assertEqual(str(self.app.open_oc_button.cget("state")), "normal")
        self.assertEqual(str(self.app.open_system_button.cget("state")), "disabled")
        self.assertEqual(str(self.app.open_battery_button.cget("state")), "disabled")
        self.assertIn("僅 GPU 功能", str(self.app.compatibility_value.cget("text")))

    def test_full_model_keeps_all_feature_buttons_available(self) -> None:
        status = {
            "Success": True,
            "Model": "Sword 16 HX B14VGKG",
            "AccessTier": "Full",
            "HorizontalCompatibility": False,
            "Mode": "Hybrid",
            "ModeIndex": 0,
            "StagedTargetIndex": 0,
            "LegacyWmiData0": "0x0B",
            "NewSwitchSupport": True,
            "DiscreteSupport": True,
            "IntegratedSupport": True,
        }
        with mock.patch.object(GUI.messagebox, "showwarning") as warning:
            self.app._finish_refresh((status, {"Data1": 0, "Pending": False}, None))
        warning.assert_not_called()
        self.assertEqual(self.app.access_tier, "Full")
        self.assertEqual(str(self.app.open_oc_button.cget("state")), "normal")
        self.assertEqual(str(self.app.open_system_button.cget("state")), "normal")
        self.assertEqual(str(self.app.open_battery_button.cget("state")), "normal")

    def test_cancel_switch_confirmation_sends_no_request_and_no_shutdown(self) -> None:
        for target in GUI.MODE_ORDER:
            for auto_shutdown in (False, True):
                with self.subTest(target=target, auto_shutdown=auto_shutdown):
                    self.app.auto_shutdown_var.set(auto_shutdown)
                    status = {
                        "Success": True,
                        "Mode": "Hybrid" if target == "Discrete" else "Discrete",
                    }
                    with (
                        mock.patch.object(Path, "is_file", return_value=True),
                        mock.patch.object(
                            GUI.messagebox, "askokcancel"
                        ) as extra_confirmation,
                        mock.patch.object(
                            GUI.messagebox, "askyesno", return_value=False
                        ) as confirmation,
                        mock.patch.object(
                            GUI, "invoke_api", side_effect=[status, {"Success": True}]
                        ) as api,
                        mock.patch.object(
                            GUI, "read_ap_state",
                            return_value={"Data1": 0, "Pending": False},
                        ),
                        mock.patch.object(
                            self.app, "_run_async",
                            side_effect=lambda work, done: done(work()),
                        ),
                        mock.patch.object(GUI, "start_immediate_shutdown") as shutdown,
                    ):
                        self.app.prepare_switch(target)
                    self.assertEqual(
                        api.call_args_list,
                        [mock.call("Status"), mock.call("Plan", target)],
                    )
                    confirmation.assert_called_once()
                    extra_confirmation.assert_not_called()
                    shutdown.assert_not_called()
                    self.assertFalse(self.app.busy)

    def test_switch_asks_once_and_sends_one_request(self) -> None:
        for target in GUI.MODE_ORDER:
            for auto_shutdown in (False, True):
                with self.subTest(target=target, auto_shutdown=auto_shutdown):
                    self.app._set_busy(False)
                    self.app.auto_shutdown_var.set(auto_shutdown)
                    status = {
                        "Success": True,
                        "Mode": "Hybrid" if target == "Discrete" else "Discrete",
                    }
                    plan = {
                        "Success": True,
                        "Backend": "WindowsFirmwareApi+DirectWmiAcpi",
                        "CurrentUefiByte5": "0x35",
                        "PlannedUefiByte5": "0x34",
                        "SwitchCommand": "MSI_ACPI.Set_Data(0xD1, 0x01)",
                        "DelayMilliseconds": 2000,
                        "AcknowledgeCommand": "MSI_ACPI.Set_Data(0xBE, 0x02)",
                    }
                    result = {"Success": True, "RequestAccepted": True}

                    def confirm(*_args, **_kwargs) -> bool:
                        # The sole prompt must appear before the state-changing request.
                        self.assertEqual(api.call_count, 2)
                        shutdown.assert_not_called()
                        self.assertEqual(
                            str(self.app.auto_shutdown_checkbox.cget("state")), "disabled"
                        )
                        return True

                    with (
                        mock.patch.object(Path, "is_file", return_value=True),
                        mock.patch.object(
                            GUI.messagebox, "askokcancel"
                        ) as extra_confirmation,
                        mock.patch.object(
                            GUI.messagebox, "askyesno", side_effect=confirm
                        ) as confirmation,
                        mock.patch.object(GUI.messagebox, "showinfo"),
                        mock.patch.object(
                            GUI, "invoke_api", side_effect=[status, plan, result]
                        ) as api,
                        mock.patch.object(
                            GUI, "read_ap_state",
                            return_value={"Data1": 0, "Pending": False},
                        ),
                        mock.patch.object(
                            self.app, "_run_async",
                            side_effect=lambda work, done: done(work()),
                        ),
                        mock.patch.object(
                            GUI, "start_immediate_shutdown", return_value=4321
                        ) as shutdown,
                    ):
                        self.app.prepare_switch(target)
                    confirmation.assert_called_once()
                    extra_confirmation.assert_not_called()
                    self.assertEqual(
                        api.call_args_list,
                        [
                            mock.call("Status"),
                            mock.call("Plan", target),
                            mock.call("Request", target),
                        ],
                    )
                    prompt = confirmation.call_args.args[1]
                    self.assertIn(f"目標模式：{target}", prompt)
                    self.assertIn(plan["SwitchCommand"], prompt)
                    self.assertIn(plan["AcknowledgeCommand"], prompt)
                    self.assertIn(GUI.SHUTDOWN_COMMAND, prompt)
                    if auto_shutdown:
                        self.assertIn("請先儲存所有工作", prompt)
                        self.assertIn("立即執行", prompt)
                        shutdown.assert_called_once_with()
                    else:
                        self.assertIn("不會自動關機", prompt)
                        shutdown.assert_not_called()

    def test_missing_shutdown_program_blocks_switch_before_confirmation(self) -> None:
        self.app.auto_shutdown_var.set(True)
        with (
            mock.patch.object(Path, "is_file", return_value=False),
            mock.patch.object(GUI.messagebox, "showerror") as error,
            mock.patch.object(GUI.messagebox, "askyesno") as confirmation,
            mock.patch.object(GUI, "invoke_api") as api,
            mock.patch.object(GUI, "start_immediate_shutdown") as shutdown,
        ):
            self.app.prepare_switch("Hybrid")
        error.assert_called_once()
        confirmation.assert_not_called()
        api.assert_not_called()
        shutdown.assert_not_called()
        self.assertFalse(self.app.busy)

    def test_failure_never_starts_shutdown(self) -> None:
        result = {
            "Success": False,
            "RequestAccepted": True,
            "AlreadyApplied": False,
            "ExitCode": 1,
            "Error": "simulated failure",
        }
        with (
            mock.patch.object(GUI.messagebox, "showerror"),
            mock.patch.object(GUI, "start_immediate_shutdown") as shutdown,
        ):
            self.app._finish_request(result, auto_shutdown=True)
        shutdown.assert_not_called()

    def test_accepted_opt_in_starts_only_mocked_shutdown(self) -> None:
        result = {
            "Success": True,
            "RequestAccepted": True,
            "AlreadyApplied": False,
            "ExitCode": 0,
            "RawOutput": "simulated accepted request",
        }
        with mock.patch.object(GUI, "start_immediate_shutdown", return_value=4321) as shutdown:
            self.app._finish_request(result, auto_shutdown=True)
        shutdown.assert_called_once_with()
        self.assertTrue(self.app.ap_state["Pending"])

    def test_accepted_without_opt_in_does_not_start_shutdown(self) -> None:
        result = {
            "Success": True,
            "RequestAccepted": True,
            "AlreadyApplied": False,
            "ExitCode": 0,
            "RawOutput": "simulated accepted request",
        }
        with (
            mock.patch.object(GUI.messagebox, "showinfo"),
            mock.patch.object(GUI, "start_immediate_shutdown") as shutdown,
        ):
            self.app._finish_request(result, auto_shutdown=False)
        shutdown.assert_not_called()

    def test_non_admin_main_relaunches_before_creating_tk(self) -> None:
        with (
            mock.patch.object(GUI, "is_administrator", return_value=False),
            mock.patch.object(GUI, "request_administrator_relaunch", return_value=42) as relaunch,
            mock.patch.object(GUI.tk, "Tk") as tk_constructor,
        ):
            self.assertEqual(GUI.main(), 0)
        relaunch.assert_called_once_with()
        tk_constructor.assert_not_called()

    def test_canceled_uac_opens_no_tk_window(self) -> None:
        with (
            mock.patch.object(GUI, "is_administrator", return_value=False),
            mock.patch.object(GUI, "request_administrator_relaunch", return_value=5),
            mock.patch.object(GUI, "show_elevation_required_error") as show_error,
            mock.patch.object(GUI.tk, "Tk") as tk_constructor,
        ):
            self.assertEqual(GUI.main(), 1)
        show_error.assert_called_once_with(5)
        tk_constructor.assert_not_called()

    def test_cancel_oc_apply_calls_no_backend(self) -> None:
        with mock.patch.object(GUI.MsiGpuOcWindow, "refresh"):
            dialog = GUI.MsiGpuOcWindow(self.app)
        try:
            dialog.status = {
                "Registry": {
                    "ExtremeCoreMHz": 75,
                    "ExtremeMemoryMHz": 0,
                }
            }
            dialog.model = "Sword 16 HX B14VGKG"
            dialog.nvidia_gpu = "NVIDIA GeForce RTX 4070 Laptop GPU"
            dialog.core_min = 0
            dialog.core_max = 200
            dialog.memory_min = 0
            dialog.memory_max = 200
            dialog.core_var.set("75")
            dialog.memory_var.set("0")
            with (
                mock.patch.object(GUI.messagebox, "askyesno", return_value=False),
                mock.patch.object(GUI, "invoke_oc_api") as oc_api,
            ):
                dialog.apply_offset()
            oc_api.assert_not_called()
        finally:
            dialog.busy = False
            dialog.close()

    def test_cancel_profile_save_calls_no_backend(self) -> None:
        with mock.patch.object(GUI.MsiGpuOcWindow, "refresh"):
            dialog = GUI.MsiGpuOcWindow(self.app)
        try:
            dialog.status = {
                "Registry": {
                    "ExtremeCoreMHz": 75,
                    "ExtremeMemoryMHz": 0,
                }
            }
            dialog.core_min = 0
            dialog.core_max = 200
            dialog.memory_min = 0
            dialog.memory_max = 200
            dialog.core_var.set("75")
            dialog.memory_var.set("0")
            with (
                mock.patch.object(GUI.messagebox, "askyesno", return_value=False),
                mock.patch.object(GUI, "invoke_oc_api") as oc_api,
            ):
                dialog.save_profile()
            oc_api.assert_not_called()
        finally:
            dialog.busy = False
            dialog.close()

    def test_cancel_system_toggle_calls_no_backend(self) -> None:
        with mock.patch.object(GUI.MsiSystemControlWindow, "refresh"):
            dialog = GUI.MsiSystemControlWindow(self.app)
        try:
            dialog.controls = {
                "WebCam": {"Supported": True, "Enabled": True},
                "WinKey": {"Supported": True, "Enabled": True},
                "SwitchFnWin": {"Supported": True, "Enabled": False},
            }
            dialog._set_busy(True, "計畫已建立")
            plan = {
                "Success": True,
                "Feature": "WebCam",
                "CurrentEnabled": True,
                "TargetEnabled": False,
                "AlreadyApplied": False,
                "Command": "Set;WebCam;0",
                "FrameHex": "68 00 00 00 00 13",
                "SideEffects": ["simulated side effect"],
                "CompatibilityWarnings": ["simulated version mismatch"],
            }
            with (
                mock.patch.object(
                    GUI.messagebox, "askyesno", return_value=False
                ) as confirmation,
                mock.patch.object(GUI, "invoke_system_api") as system_api,
            ):
                dialog._confirm_toggle("WebCam", False, plan)
            system_api.assert_not_called()
            self.assertIn("simulated version mismatch", confirmation.call_args.args[1])
            self.assertFalse(dialog.busy)
        finally:
            dialog.busy = False
            dialog.close()

    def test_system_version_mismatch_warns_once_without_disabling_controls(self) -> None:
        with mock.patch.object(GUI.MsiSystemControlWindow, "refresh"):
            dialog = GUI.MsiSystemControlWindow(self.app)
        try:
            result = {
                "Success": True,
                "CompatibilityWarnings": ["simulated unverified MSI version"],
                "Controls": {
                    "WebCam": {"Supported": True, "Enabled": True},
                    "WinKey": {"Supported": True, "Enabled": True},
                    "SwitchFnWin": {"Supported": True, "Enabled": False},
                },
            }
            with mock.patch.object(GUI.messagebox, "showwarning") as warning:
                dialog._finish_refresh(result)
                dialog._finish_refresh(result)
            warning.assert_called_once()
            self.assertEqual(str(dialog.action_buttons["WebCam"].cget("state")), "normal")
            self.assertIn("版本", dialog.footer_var.get())
        finally:
            dialog.busy = False
            dialog.close()

    def test_driver_limits_configure_sliders_and_tick_segments(self) -> None:
        with mock.patch.object(GUI.MsiGpuOcWindow, "refresh"):
            dialog = GUI.MsiGpuOcWindow(self.app)
        try:
            status = {
                "Success": True,
                "Manufacturer": "Micro-Star International Co., Ltd.",
                "Model": "Sword 16 HX B14VGKG",
                "VideoControllers": ["NVIDIA GeForce RTX 4070 Laptop GPU"],
                "CurrentMode": "ExtremePerformance",
                "CurrentModeIndex": 1,
                "Registry": {
                    "Intelligent": 0,
                    "CoreMinimumMHz": 0,
                    "CoreMaximumMHz": 200,
                    "MemoryMinimumMHz": 0,
                    "MemoryMaximumMHz": 200,
                    "ExtremeCoreMHz": 75,
                    "ExtremeMemoryMHz": 0,
                },
                "Limits": {
                    "DriverProbeSucceeded": True,
                    "CoreMinimumMHz": 0,
                    "CoreMaximumMHz": 1000,
                    "MemoryMinimumMHz": 0,
                    "MemoryMaximumMHz": 3000,
                    "DriverCoreMinimumMHz": -1000,
                    "DriverCoreMaximumMHz": 1000,
                    "DriverMemoryMinimumMHz": -1000,
                    "DriverMemoryMaximumMHz": 3000,
                },
            }
            native = {
                "Success": True,
                "CoreOffsetMHz": 75,
                "MemoryOffsetMHz": 0,
                "PState": 8,
                "CurrentTemperatureC": 40,
            }
            dialog._finish_refresh((status, native))
            self.assertEqual(float(dialog.core_scale.cget("to")), 1000.0)
            self.assertEqual(float(dialog.memory_scale.cget("to")), 3000.0)
            self.assertEqual(float(dialog.core_scale.cget("tickinterval")), 200.0)
            self.assertEqual(float(dialog.memory_scale.cget("tickinterval")), 500.0)
            self.assertEqual(dialog.core_var.get(), "75")
            self.assertEqual(dialog.memory_var.get(), "0")
        finally:
            dialog.busy = False
            dialog.close()

    def test_nonzero_read_offsets_auto_move_sliders(self) -> None:
        with mock.patch.object(GUI.MsiGpuOcWindow, "refresh"):
            dialog = GUI.MsiGpuOcWindow(self.app)
        try:
            status = {
                "Success": True,
                "CurrentMode": "ExtremePerformance",
                "CurrentModeIndex": 1,
                "Registry": {
                    "CoreMinimumMHz": 0,
                    "CoreMaximumMHz": 200,
                    "MemoryMinimumMHz": 0,
                    "MemoryMaximumMHz": 200,
                    "ExtremeCoreMHz": 0,
                    "ExtremeMemoryMHz": 0,
                },
                "Limits": {
                    "CoreMinimumMHz": 0,
                    "CoreMaximumMHz": 1000,
                    "MemoryMinimumMHz": 0,
                    "MemoryMaximumMHz": 3000,
                },
            }
            # Test 1: Only GPU core has non-zero offset
            native1 = {"Success": True, "CoreOffsetMHz": 85, "MemoryOffsetMHz": 0}
            dialog._finish_refresh((status, native1))
            self.assertEqual(dialog.core_var.get(), "85")
            self.assertEqual(float(dialog.core_scale.get()), 85.0)
            self.assertEqual(dialog.memory_var.get(), "0")
            self.assertEqual(float(dialog.memory_scale.get()), 0.0)

            # Test 2: Only VRAM has non-zero offset
            native2 = {"Success": True, "CoreOffsetMHz": 0, "MemoryOffsetMHz": 160}
            dialog._finish_refresh((status, native2))
            self.assertEqual(dialog.core_var.get(), "0")
            self.assertEqual(float(dialog.core_scale.get()), 0.0)
            self.assertEqual(dialog.memory_var.get(), "160")
            self.assertEqual(float(dialog.memory_scale.get()), 160.0)

            # Test 3: Both have non-zero offsets
            native3 = {"Success": True, "CoreOffsetMHz": 120, "MemoryOffsetMHz": 350}
            dialog._finish_refresh((status, native3))
            self.assertEqual(dialog.core_var.get(), "120")
            self.assertEqual(float(dialog.core_scale.get()), 120.0)
            self.assertEqual(dialog.memory_var.get(), "350")
            self.assertEqual(float(dialog.memory_scale.get()), 350.0)
        finally:
            dialog.busy = False
            dialog.close()


class BatteryFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.dpi_mode = GUI.enable_windows_high_dpi_awareness()

    def setUp(self) -> None:
        self.root = tk.Tk()
        self.root.withdraw()
        with mock.patch.object(GUI.FuckMsiCenterApp, "refresh_status"):
            self.app = GUI.FuckMsiCenterApp(self.root, self.dpi_mode)
        self.app.admin = True
        with mock.patch.object(GUI.MsiBatteryWindow, "refresh"):
            self.dialog = GUI.MsiBatteryWindow(self.app)
        self.app.battery_dialog = self.dialog
        self.dialog._finish_refresh(self.state(100))
        self.dialog.limit_var.set(60)

    @staticmethod
    def state(limit: int) -> dict:
        return {"Success": True, "Supported": True, "ChargeLimitPercent": limit, "RawValueHex": "0xE4"}

    @staticmethod
    def plan() -> dict:
        return {
            "Success": True, "ChargeLimitPercent": 60, "CurrentLimitPercent": 100,
            "AlreadyApplied": False, "Command": "MSI_ACPI.Set_Data(0xD7, 0xBC)",
        }

    def synchronous(self, work, done, on_error=None) -> None:
        done(work())

    def tearDown(self) -> None:
        self.root.destroy()

    def test_presets_sync_from_hardware_without_writes(self) -> None:
        with mock.patch.object(GUI, "invoke_battery_api") as api:
            for limit in (60, 80, 100):
                self.dialog._finish_refresh(self.state(limit))
                self.assertEqual(self.dialog.limit_var.get(), limit)
                self.assertIn(f"{limit}%", self.dialog.current_var.get())
        api.assert_not_called()

    def test_cancel_after_fresh_plan_launches_no_set(self) -> None:
        with (
            mock.patch.object(GUI, "invoke_battery_api", return_value=self.plan()) as api,
            mock.patch.object(self.app, "_run_async", side_effect=self.synchronous),
            mock.patch.object(GUI.messagebox, "askyesno", return_value=False),
        ):
            self.dialog.prepare_change()
        self.assertEqual(api.call_args_list, [mock.call("BatteryPlan", charge_limit=60)])
        self.assertFalse(self.dialog.busy)
        self.assertFalse(self.app.busy)

    def test_confirmed_change_launches_one_set_then_refreshes(self) -> None:
        result = {"Success": True, "Verified": True, "ChargeLimitPercent": 60, "RequestSent": True}
        plan = self.plan()
        plan["MsiPolicy"] = {"AIChargerEnabled": True}
        with (
            mock.patch.object(GUI, "invoke_battery_api", side_effect=[plan, result, self.state(60)]) as api,
            mock.patch.object(self.app, "_run_async", side_effect=self.synchronous),
            mock.patch.object(GUI.messagebox, "askyesno", return_value=True) as prompt,
        ):
            self.dialog.prepare_change()
        self.assertEqual(api.call_args_list, [
            mock.call("BatteryPlan", charge_limit=60),
            mock.call("BatterySet", charge_limit=60, confirmed=True),
            mock.call("BatteryStatus"),
        ])
        prompt.assert_called_once()
        self.assertIn("AI Charger", prompt.call_args.args[1])
        self.assertIn("0xBC", prompt.call_args.args[1])
        self.assertEqual(self.dialog.limit_var.get(), 60)
        self.assertFalse(self.app.busy)

    def test_failed_set_disables_stale_state_and_does_not_retry(self) -> None:
        with (
            mock.patch.object(GUI, "invoke_battery_api", side_effect=[self.plan(), {"Success": False, "Error": "read-back mismatch"}]) as api,
            mock.patch.object(self.app, "_run_async", side_effect=self.synchronous),
            mock.patch.object(GUI.messagebox, "askyesno", return_value=True),
            mock.patch.object(GUI.messagebox, "showerror") as error,
        ):
            self.dialog.prepare_change()
        self.assertEqual(api.call_count, 2)
        error.assert_called_once()
        self.assertIsNone(self.dialog.status)
        self.assertEqual(str(self.dialog.apply_button.cget("state")), "disabled")
        self.assertFalse(self.app.busy)

    def test_failed_plan_never_shows_confirmation_or_sends_set(self) -> None:
        with (
            mock.patch.object(GUI, "invoke_battery_api", return_value={"Success": False, "Error": "unknown firmware"}) as api,
            mock.patch.object(self.app, "_run_async", side_effect=self.synchronous),
            mock.patch.object(GUI.messagebox, "askyesno") as prompt,
            mock.patch.object(GUI.messagebox, "showerror"),
        ):
            self.dialog.prepare_change()
        prompt.assert_not_called()
        self.assertEqual(api.call_count, 1)

    def test_other_operation_busy_blocks_battery_controls(self) -> None:
        self.app._set_busy(True)
        with mock.patch.object(GUI, "invoke_battery_api") as api:
            self.dialog.prepare_change()
            self.dialog.refresh()
        api.assert_not_called()
        self.assertEqual(str(self.dialog.apply_button.cget("state")), "disabled")

    def test_invalid_status_disables_apply(self) -> None:
        with mock.patch.object(GUI.messagebox, "showerror"):
            self.dialog._finish_refresh(self.state(95))
        self.assertIsNone(self.dialog.status)
        self.assertEqual(str(self.dialog.apply_button.cget("state")), "disabled")

    def test_battery_process_arguments_require_explicit_confirmation(self) -> None:
        for command in ("BatteryStatus", "BatteryPlan", "BatterySet"):
            for confirmed in (False, True):
                with mock.patch.object(GUI, "run_process", return_value=(0, '{"Success":true}')) as run:
                    GUI.invoke_battery_api(command, charge_limit=60, confirmed=confirmed)
                arguments = run.call_args.args[0]
                self.assertEqual("-ConfirmBatteryChange" in arguments, command == "BatterySet" and confirmed)
                self.assertEqual(arguments[arguments.index("-ChargeLimitPercent") + 1], "60")
        with mock.patch.object(GUI, "run_process") as run:
            with self.assertRaises(ValueError):
                GUI.invoke_battery_api("BatterySet", charge_limit=95, confirmed=True)
        run.assert_not_called()


class OcApiArgumentTests(unittest.TestCase):
    def test_apply_confirmation_flag_is_only_added_when_confirmed(self) -> None:
        with mock.patch.object(
            GUI, "run_process", return_value=(0, '{"Success": true}')
        ) as run:
            GUI.invoke_oc_api(
                "OCApply",
                core_offset=25,
                memory_offset=50,
                expected_model="MODEL",
                expected_gpu="GPU",
                confirmed=True,
            )
        arguments = run.call_args.args[0]
        self.assertIn("-ConfirmHardwareRisk", arguments)
        self.assertNotIn("-ConfirmRegistryWrite", arguments)

    def test_gaming_targets_map_to_real_msi_profiles(self) -> None:
        self.assertEqual(GUI.normalize_oc_target("GamingActive"), "ExtremePerformance")
        self.assertEqual(GUI.normalize_oc_target("GamingInactive"), "Balanced")
        state = {
            "Registry": {
                "ExtremeCoreMHz": 75,
                "ExtremeMemoryMHz": 10,
                "UserCoreMHz": 20,
                "UserMemoryMHz": 30,
            }
        }
        self.assertEqual(GUI.oc_profile_values(state, "GamingActive"), (75, 10))
        self.assertEqual(GUI.oc_profile_values(state, "GamingInactive"), (0, 0))
        self.assertEqual(GUI.oc_profile_values(state, "User"), (20, 30))
        self.assertEqual(GUI.slider_tick_interval(0, 1000), 200)
        self.assertEqual(GUI.slider_tick_interval(0, 3000), 500)


class SystemApiArgumentTests(unittest.TestCase):
    def test_system_confirmation_flag_is_only_added_when_confirmed(self) -> None:
        with mock.patch.object(
            GUI, "run_process", return_value=(0, '{"Success": true}')
        ) as run:
            GUI.invoke_system_api(
                "SystemSet", feature="SwitchFnWin", enabled=False, confirmed=True
            )
        arguments = run.call_args.args[0]
        self.assertIn("-ConfirmSystemChange", arguments)
        self.assertEqual(arguments[arguments.index("-Enabled") + 1], "0")

        with mock.patch.object(
            GUI, "run_process", return_value=(0, '{"Success": true}')
        ) as run:
            GUI.invoke_system_api(
                "SystemPlan", feature="SwitchFnWin", enabled=False, confirmed=True
            )
        self.assertNotIn("-ConfirmSystemChange", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
