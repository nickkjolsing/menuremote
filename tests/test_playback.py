import asyncio
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, call, patch

from pyatv.const import InputAction, Protocol
from pyatv.core import CoreStateDispatcher
from pyatv.core.facade import FacadeAppleTV
from pyatv.protocols.companion import CompanionRemoteControl
from pyatv.protocols.companion.api import HidCommand
from pyatv.protocols.mrp import MrpRemoteControl, protobuf
from pyatv.settings import Settings

from test_discovery import bridge, device


class PlaybackTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        loop = asyncio.get_running_loop()
        self.bridge = bridge.Bridge(loop, str(Path(self.temp.name) / "pyatv.conf"))
        self.session = Mock(close=AsyncMock())
        self.atv = FacadeAppleTV(device(), self.session, CoreStateDispatcher(), Settings())
        self.bridge.atv = self.atv
        self.psm = Mock()
        self.psm.playing.playback_state = protobuf.PlaybackState.Seeking
        self.psm.playing.command_info.return_value = None
        self.mrp = MrpRemoteControl(loop, self.psm, Mock())
        self.mrp._send_command = AsyncMock()
        self.atv.remote_control.register(self.mrp, Protocol.MRP)
        self.api = Mock(hid_command=AsyncMock())
        self.companion = CompanionRemoteControl(self.api)
        self.atv.remote_control.register(self.companion, Protocol.Companion)
        self.after_command = patch.object(self.bridge, "after_command", new=AsyncMock())
        self.refresh = self.after_command.start()
        self.addCleanup(self.after_command.stop)

    async def asyncTearDown(self):
        await self.bridge.disconnect()

    async def test_variable_speed_playback_sends_physical_toggle(self):
        # Reproduce pyatv's silent no-op with its actual MRP implementation.
        await self.atv.remote_control.play_pause()
        self.mrp._send_command.assert_not_awaited()
        self.api.hid_command.assert_not_awaited()

        await self.bridge.cmd_play_pause({})
        self.assertEqual(self.api.hid_command.await_args_list, [
            call(True, HidCommand.PlayPause), call(False, HidCommand.PlayPause),
        ])
        self.mrp._send_command.assert_not_awaited()
        self.refresh.assert_awaited_once()
        self.assertEqual(self.atv.remote_control.main_protocol, Protocol.MRP)

    async def test_command_failure_restores_normal_protocol_routing(self):
        self.api.hid_command.side_effect = bridge.exceptions.ConnectionFailedError("lost")
        with self.assertRaises(bridge.exceptions.ConnectionFailedError):
            await self.bridge.cmd_play_pause({})
        self.assertEqual(self.atv.remote_control.main_protocol, Protocol.MRP)
        self.refresh.assert_not_awaited()

    async def test_older_tv_without_companion_uses_mrp(self):
        self.atv = FacadeAppleTV(device(), self.session, CoreStateDispatcher(), Settings())
        self.bridge.atv = self.atv
        self.psm.playing.playback_state = protobuf.PlaybackState.Playing
        self.atv.remote_control.register(self.mrp, Protocol.MRP)
        await self.bridge.cmd_play_pause({})
        self.mrp._send_command.assert_awaited_once_with(protobuf.CommandInfo_pb2.Pause)
        self.api.hid_command.assert_not_awaited()
        self.refresh.assert_awaited_once()

    async def test_center_button_tap_and_hold_reach_mrp(self):
        with patch("pyatv.protocols.mrp._send_hid_key", new=AsyncMock()) as send_key:
            await self.bridge.cmd_key({"key": "select"})
            await self.bridge.cmd_key({"key": "select", "hold": True})
        self.assertEqual(send_key.await_args_list, [
            call(self.mrp.protocol, "select", InputAction.SingleTap),
            call(self.mrp.protocol, "select", InputAction.Hold),
        ])

    async def test_center_button_hold_sends_one_companion_press_and_release(self):
        # Exercise pyatv's real hold implementation on a Companion-only device.
        self.atv = FacadeAppleTV(device(), self.session, CoreStateDispatcher(), Settings())
        self.bridge.atv = self.atv
        self.atv.remote_control.register(self.companion, Protocol.Companion)
        events = []
        self.api.hid_command.side_effect = lambda down, key: events.append((down, key))

        async def sleep(delay):
            events.append(("wait", delay))

        with patch("pyatv.protocols.companion.asyncio.sleep", side_effect=sleep):
            await self.bridge.cmd_key({"key": "select", "hold": True})
        self.assertEqual(events, [
            (True, HidCommand.Select), ("wait", 1), (False, HidCommand.Select),
        ])

        events.clear()
        await self.bridge.cmd_key({"key": "select", "hold": False})
        self.assertEqual(events, [(True, HidCommand.Select), (False, HidCommand.Select)])

    async def test_invalid_key_is_rejected_before_sending(self):
        with self.assertRaisesRegex(ValueError, "unknown key"):
            await self.bridge.cmd_key({"key": "invalid", "hold": True})
        self.api.hid_command.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
