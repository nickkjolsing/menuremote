import asyncio
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, call, patch

from pyatv.const import FeatureName, FeatureState, Protocol
from pyatv.core import CoreStateDispatcher
from pyatv.core.facade import FacadeAppleTV
from pyatv.protocols.companion import CompanionFeatures, CompanionRemoteControl
from pyatv.protocols.companion.api import HidCommand
from pyatv.protocols.mrp import MrpFeatures, MrpRemoteControl
from pyatv.settings import Settings

from test_discovery import bridge, device


class VolumeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bridge = bridge.Bridge(asyncio.get_running_loop(), str(Path(self.temp.name) / "pyatv.conf"))
        self.bridge.target_id = "test-tv"
        self.atv = Mock()
        self.atv.audio.volume = 42.0
        self.atv.audio.set_volume = AsyncMock()
        self.bridge.atv = self.atv
        self.available = set()
        self.atv.features.in_state.side_effect = lambda state, *features: all(f in self.available for f in features)
        self.atv.features.get.return_value = None

    async def test_absolute_volume_needs_both_a_readable_level_and_set_support(self):
        self.available.update((FeatureName.Volume, FeatureName.SetVolume))
        self.assertEqual(self.bridge.volume_state(), {
            "level": 42.0, "available": True, "up_available": False, "down_available": False,
        })
        self.available.remove(FeatureName.Volume)
        self.assertFalse(self.bridge.volume_state()["available"])
        self.assertIsNone(self.bridge.volume_state()["level"])
        self.available = {FeatureName.Volume}
        self.assertEqual(self.bridge.volume_state()["level"], 42)
        self.assertFalse(self.bridge.volume_state()["available"])

    async def test_relative_volume_is_available_without_an_absolute_level(self):
        self.available.update((FeatureName.VolumeUp, FeatureName.VolumeDown))
        self.assertEqual(self.bridge.volume_state(), {
            "level": None, "available": False, "up_available": True, "down_available": True,
        })
        self.available.remove(FeatureName.VolumeDown)
        self.assertFalse(self.bridge.volume_state()["down_available"])
        self.assertTrue(self.bridge.volume_state()["up_available"])

    async def test_invalid_levels_never_enable_a_slider(self):
        self.available.update((FeatureName.Volume, FeatureName.SetVolume, FeatureName.VolumeUp))
        for level in (None, float("nan"), float("inf"), -1, 101, True, "42"):
            with self.subTest(level=level):
                self.atv.audio.volume = level
                state = self.bridge.volume_state()
                self.assertFalse(state["available"])
                self.assertIsNone(state["level"])
                self.assertTrue(state["up_available"])
        for level in (0, 100):
            self.atv.audio.volume = level
            self.assertTrue(self.bridge.volume_state()["available"])

    async def test_connection_or_capability_failure_reports_unavailable(self):
        for atv in (None, self.atv):
            self.bridge.atv = atv
            self.atv.features.in_state.side_effect = bridge.exceptions.ConnectionFailedError("lost")
            self.assertEqual(self.bridge.volume_state(), {
                "level": None, "available": False, "up_available": False, "down_available": False,
            })

    async def test_output_and_volume_updates_recheck_current_capabilities(self):
        self.available.update((FeatureName.Volume, FeatureName.SetVolume))
        with patch.object(bridge, "emit") as emit:
            self.bridge.emit_volume()
            emit.assert_called_with("volume", device_id="test-tv", level=42, available=True,
                                    up_available=False, down_available=False)
            self.available = {FeatureName.VolumeUp, FeatureName.VolumeDown}
            self.bridge.volume_update(42, 0)
            emit.assert_called_with("volume", device_id="test-tv", level=None, available=False,
                                    up_available=True, down_available=True)
            self.available.clear()
            self.bridge.outputdevices_update([], [])
            emit.assert_called_with("volume", device_id="test-tv", level=None, available=False,
                                    up_available=False, down_available=False)

    async def test_periodic_refresh_checks_volume_even_if_metadata_fails(self):
        self.atv.metadata.playing = AsyncMock(side_effect=RuntimeError("No active player"))
        with patch.object(bridge, "emit") as emit:
            with self.assertRaises(RuntimeError):
                await self.bridge.refresh()
        self.assertIn("volume", [event.args[0] for event in emit.call_args_list])

    async def test_set_volume_checks_current_device_and_capabilities(self):
        self.available.update((FeatureName.Volume, FeatureName.SetVolume))
        await self.bridge.cmd_volume({"device_id": "test-tv", "level": 30})
        self.atv.audio.set_volume.assert_awaited_once_with(30.0)
        for invalid in (float("nan"), float("inf"), -1, 101, True, "30"):
            with self.assertRaises(ValueError):
                await self.bridge.cmd_volume({"device_id": "test-tv", "level": invalid})
        with self.assertRaises(bridge.exceptions.ConnectionFailedError):
            await self.bridge.cmd_volume({"device_id": "old-tv", "level": 50})
        self.available.clear()
        with self.assertRaises(bridge.exceptions.NotSupportedError):
            await self.bridge.cmd_volume({"device_id": "test-tv", "level": 50})
        self.atv.audio.set_volume.assert_awaited_once()

    async def test_companion_button_support_does_not_prove_absolute_volume_or_cec(self):
        # Companion infers these buttons from protocol support, even with no
        # volume flag. The UI must not claim it detected a receiver or CEC.
        features = CompanionFeatures(Mock(), Mock())
        self.assertEqual(features.get_feature(FeatureName.SetVolume).state, FeatureState.Unavailable)
        self.assertEqual(features.get_feature(FeatureName.VolumeUp).state, FeatureState.Available)


class VolumeButtonRoutingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        loop = asyncio.get_running_loop()
        self.bridge = bridge.Bridge(loop, str(Path(self.temp.name) / "pyatv.conf"))
        self.bridge.target_id = "test-tv"
        self.session = Mock(close=AsyncMock())
        self.atv = FacadeAppleTV(device(), self.session, CoreStateDispatcher(), Settings())
        self.bridge.atv = self.atv
        self.mrp = MrpRemoteControl(loop, Mock(), Mock())
        self.atv.remote_control.register(self.mrp, Protocol.MRP)
        self.api = Mock(hid_command=AsyncMock())
        self.atv.remote_control.register(CompanionRemoteControl(self.api), Protocol.Companion)
        features = CompanionFeatures(self.api, Mock())
        self.atv.features.register(features, Protocol.Companion)
        self.atv.features.add_mapping(Protocol.Companion, {FeatureName.VolumeUp, FeatureName.VolumeDown,
                                                         FeatureName.Volume, FeatureName.SetVolume})
        mrp_features = MrpFeatures(device(), Mock(), Mock(is_available=False))
        self.atv.features.register(mrp_features, Protocol.MRP)
        self.atv.features.add_mapping(Protocol.MRP, {FeatureName.VolumeUp, FeatureName.VolumeDown,
                                                   FeatureName.Volume, FeatureName.SetVolume})

    async def asyncTearDown(self):
        await self.bridge.disconnect()

    async def test_volume_buttons_use_companion_without_waiting_for_a_level_event(self):
        self.assertFalse(self.atv.features.in_state(FeatureState.Available, FeatureName.VolumeUp))
        self.assertTrue(self.bridge.volume_state()["up_available"], "MRP hid the usable Companion button")
        with patch.object(bridge, "emit"):
            await asyncio.wait_for(self.bridge.cmd_volume_step({"direction": "up", "device_id": "test-tv"}), 1)
            await asyncio.wait_for(self.bridge.cmd_volume_step({"direction": "down", "device_id": "test-tv"}), 1)
        self.assertEqual(self.api.hid_command.await_args_list, [
            call(True, HidCommand.VolumeUp), call(False, HidCommand.VolumeUp),
            call(True, HidCommand.VolumeDown), call(False, HidCommand.VolumeDown),
        ])
        self.assertEqual(self.atv.remote_control.main_protocol, Protocol.MRP)

    async def test_failed_press_restores_routing_and_does_not_send_a_second_command(self):
        self.api.hid_command.side_effect = bridge.exceptions.ConnectionFailedError("lost")
        with self.assertRaises(bridge.exceptions.ConnectionFailedError):
            await self.bridge.cmd_volume_step({"direction": "up", "device_id": "test-tv"})
        self.api.hid_command.assert_awaited_once_with(True, HidCommand.VolumeUp)
        self.assertEqual(self.atv.remote_control.main_protocol, Protocol.MRP)

    async def test_stale_queued_press_cannot_change_the_replacement_tvs_volume(self):
        await self.bridge.remote_commands.acquire()
        pending = asyncio.create_task(self.bridge.cmd_volume_step({"direction": "up", "device_id": "test-tv"}))
        await asyncio.sleep(0)
        self.bridge.target_id = "replacement-tv"
        self.bridge.remote_commands.release()
        with self.assertRaises(bridge.exceptions.ConnectionFailedError):
            await pending
        self.api.hid_command.assert_not_awaited()

    async def test_invalid_or_unsupported_commands_send_nothing(self):
        with self.assertRaises(ValueError):
            await self.bridge.cmd_volume_step({"direction": "louder", "device_id": "test-tv"})
        self.atv.features.get(Protocol.Companion).in_state = Mock(return_value=False)
        with self.assertRaises(bridge.exceptions.NotSupportedError):
            await self.bridge.cmd_volume_step({"direction": "up", "device_id": "test-tv"})
        self.api.hid_command.assert_not_awaited()

    async def test_older_tv_without_companion_uses_the_available_mrp_button(self):
        older = FacadeAppleTV(device(), self.session, CoreStateDispatcher(), Settings())
        self.bridge.atv = older
        older.remote_control.register(self.mrp, Protocol.MRP)
        features = MrpFeatures(device(), Mock(), Mock(is_available=True))
        older.features.register(features, Protocol.MRP)
        older.features.add_mapping(Protocol.MRP, {FeatureName.VolumeUp, FeatureName.VolumeDown})
        with patch("pyatv.protocols.mrp._send_hid_key", new=AsyncMock()) as send, patch.object(bridge, "emit"):
            await self.bridge.cmd_volume_step({"direction": "up", "device_id": "test-tv"})
        self.assertEqual(send.await_args.args[1], "volume_up")
        self.api.hid_command.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
