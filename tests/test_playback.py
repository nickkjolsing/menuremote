import asyncio
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, call, patch

from pyatv.const import Protocol
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


if __name__ == "__main__":
    unittest.main()
