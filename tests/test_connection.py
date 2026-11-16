import asyncio
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, PropertyMock, patch

from pyatv.interface import Playing

from test_discovery import bridge, device


class ConnectionRecoveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bridge = bridge.Bridge(
            asyncio.get_running_loop(), str(Path(self.temp.name) / "pyatv.conf"))
        self.conf = device()
        for service in self.conf.services:
            service.credentials = "test-credentials"
        self.atv = Mock()
        self.atv.features.in_state.return_value = False
        self.atv.metadata.playing = AsyncMock(return_value=Playing())
        self.atv.close.return_value = set()
        self.scan = patch.object(self.bridge, "scan", new=AsyncMock(return_value=[self.conf]))
        self.connect = patch.object(bridge.pyatv, "connect", new=AsyncMock(return_value=self.atv))
        self.scan.start()
        self.connect_mock = self.connect.start()
        self.addCleanup(self.scan.stop)
        self.addCleanup(self.connect.stop)
        self.events = patch.object(bridge, "emit")
        self.emit = self.events.start()
        self.addCleanup(self.events.stop)

    async def asyncTearDown(self):
        self.bridge.target_id = None
        await self.bridge.cancel_reconnect()
        await self.bridge.disconnect()

    async def test_initial_protocol_failure_schedules_retry_and_recovers(self):
        self.connect_mock.side_effect = [
            bridge.exceptions.ConnectionFailedError("remote channel unavailable"), self.atv]
        with patch.object(bridge, "RECONNECT_DELAYS", (0,)):
            await self.bridge.handle({"cmd": "connect", "id": self.conf.identifier})
            retry = self.bridge.reconnect_task
            self.assertIsNotNone(retry)
            await asyncio.wait_for(retry, 1)
        self.assertIs(self.bridge.atv, self.atv)
        self.emit.assert_any_call("connected", device=bridge.device_dict(self.conf))
        self.assertIsNone(self.bridge.reconnect_task)

    async def test_hung_connection_times_out_and_schedules_retry(self):
        async def never_connect(*args, **kwargs):
            await asyncio.Future()
        self.connect_mock.side_effect = never_connect
        with patch.object(bridge, "CONNECT_TIMEOUT", 0.01):
            with self.assertRaises(TimeoutError):
                await self.bridge.cmd_connect({"id": self.conf.identifier})
        self.assertIsNone(self.bridge.atv)
        self.assertIsNotNone(self.bridge.reconnect_task)

    async def test_slow_metadata_keeps_remote_and_starts_polling(self):
        async def never_playing():
            await asyncio.Future()
        self.atv.metadata.playing.side_effect = never_playing
        with patch.object(bridge, "REFRESH_TIMEOUT", 0.01):
            await self.bridge.cmd_connect({"id": self.conf.identifier})
        self.assertIs(self.bridge.atv, self.atv)
        self.assertIsNotNone(self.bridge.poll_task)
        self.assertFalse(self.bridge.poll_task.done())
        self.assertIsNone(self.bridge.reconnect_task)

    async def test_already_closed_connection_can_be_replaced(self):
        old = Mock()
        type(old).push_updater = PropertyMock(
            side_effect=bridge.exceptions.BlockedStateError("push_updater is blocked"))
        old.close.return_value = set()
        self.bridge.atv = old
        await self.bridge.cmd_connect({"id": self.conf.identifier})
        old.close.assert_called_once()
        self.assertIs(self.bridge.atv, self.atv)

    async def test_manual_retry_waits_for_old_attempt_cancellation(self):
        started = asyncio.Event()
        cleaned = asyncio.Event()
        async def old_attempt():
            started.set()
            try:
                await asyncio.Future()
            finally:
                await asyncio.sleep(0)
                cleaned.set()
                self.bridge.atv = None
                self.bridge.reconnect_task = None
        self.bridge.reconnect_task = asyncio.create_task(old_attempt())
        await started.wait()
        await self.bridge.cmd_connect({"id": self.conf.identifier})
        self.assertTrue(cleaned.is_set())
        self.assertIs(self.bridge.atv, self.atv)
        self.assertIsNone(self.bridge.reconnect_task)

    async def test_retry_waits_for_connection_attempt_to_finish(self):
        started = asyncio.Event()
        release = asyncio.Event()
        attempts = 0
        async def establish(wake=False):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                self.bridge.connection_lost("lost during setup")
                started.set()
                await release.wait()
            else:
                self.bridge.atv = self.atv
        with patch.object(self.bridge, "establish_connection", side_effect=establish):
            with patch.object(bridge, "RECONNECT_DELAYS", (0,)):
                initial = asyncio.create_task(self.bridge.cmd_connect({"id": self.conf.identifier}))
                try:
                    await asyncio.wait_for(started.wait(), 1)
                    retry = self.bridge.reconnect_task
                    await asyncio.sleep(0.01)
                    self.assertEqual(attempts, 1, "Connection attempts must not overlap")
                    release.set()
                    await asyncio.wait_for(initial, 1)
                    await asyncio.wait_for(retry, 1)
                finally:
                    release.set()
                    await asyncio.gather(initial, return_exceptions=True)
        self.assertEqual(attempts, 2)
        self.assertIs(self.bridge.atv, self.atv)

    async def test_disconnect_cancels_pending_retry(self):
        self.bridge.target_id = self.conf.identifier
        self.bridge.schedule_reconnect()
        retry = self.bridge.reconnect_task
        await self.bridge.cmd_disconnect({})
        self.assertTrue(retry.done())
        self.assertIsNone(self.bridge.target_id)
        self.assertIsNone(self.bridge.reconnect_task)
        self.connect_mock.assert_not_awaited()

    async def test_loss_during_intentional_close_does_not_start_retry(self):
        self.bridge.target_id = self.conf.identifier
        self.bridge.atv = self.atv
        def close():
            self.bridge.connection_lost("closed")
            return set()
        self.atv.close.side_effect = close
        await self.bridge.disconnect()
        self.assertIsNone(self.bridge.reconnect_task)
        self.assertNotIn("disconnected", [call.args[0] for call in self.emit.call_args_list])

    async def test_close_timeout_still_allows_reconnect(self):
        old = Mock()
        old.close.return_value = {asyncio.create_task(asyncio.sleep(60))}
        self.bridge.atv = old
        with patch.object(bridge, "CLOSE_TIMEOUT", 0.01):
            await self.bridge.cmd_connect({"id": self.conf.identifier})
        self.assertIs(self.bridge.atv, self.atv)
        self.assertFalse(self.bridge.closing)
        self.assertTrue(all(task.cancelled() for task in old.close.return_value))


if __name__ == "__main__":
    unittest.main()
