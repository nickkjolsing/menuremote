import asyncio
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

from pyatv.const import KeyboardFocusState
from pyatv.protocols.companion import CompanionKeyboard

from test_discovery import bridge


class KeyboardTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bridge = bridge.Bridge(
            asyncio.get_running_loop(), str(Path(self.temp.name) / "pyatv.conf"))
        self.api = Mock(text_input_command=AsyncMock())
        self.keyboard = CompanionKeyboard(self.api, Mock())
        self.keyboard._focus_state = KeyboardFocusState.Focused
        self.atv = Mock(keyboard=self.keyboard)
        self.atv.features.in_state.return_value = True
        self.bridge.atv = self.atv
        self.bridge.target_id = "living-room"
        self.message = {
            "cmd": "text", "device_id": "living-room", "request": "request-1",
            "text": "Café 🎬\nA second line",
        }
        self.events = patch.object(bridge, "emit")
        self.emit = self.events.start()
        self.addCleanup(self.events.stop)

    async def test_text_appends_via_real_companion_keyboard_without_read_or_replace(self):
        await self.bridge.handle(self.message)
        self.api.text_input_command.assert_awaited_once_with(
            self.message["text"], clear_previous_input=False)
        self.emit.assert_called_once_with("text_sent", request="request-1")

    async def test_no_focused_field_does_not_send_or_acknowledge(self):
        self.keyboard._focus_state = KeyboardFocusState.Unfocused
        await self.bridge.handle(self.message)
        self.api.text_input_command.assert_not_awaited()
        self.emit.assert_called_once_with(
            "error", command="text", request="request-1",
            message="Open a text field on your Apple TV first.")

    async def test_unsupported_keyboard_does_not_send(self):
        self.atv.features.in_state.return_value = False
        await self.bridge.handle(self.message)
        self.api.text_input_command.assert_not_awaited()
        self.assertIn("isn't available", self.emit.call_args.kwargs["message"])

    async def test_invalid_text_is_rejected(self):
        for value in ("", "x" * 4097, None, 42):
            with self.subTest(value_type=type(value).__name__):
                await self.bridge.handle({**self.message, "text": value})
        self.api.text_input_command.assert_not_awaited()

    async def test_protocol_errors_do_not_expose_text_in_events_or_logs(self):
        secret = "a-private-test-password"
        self.api.text_input_command.side_effect = RuntimeError(secret)
        with self.assertLogs("atv_bridge", level="WARNING") as captured:
            await self.bridge.handle({**self.message, "text": secret})
        self.assertNotIn(secret, repr(captured.output))
        self.assertNotIn(secret, repr(self.emit.call_args_list))
        self.assertEqual(self.emit.call_args.args, ("error",))

    async def test_queued_text_cannot_follow_a_device_switch(self):
        started, finish = asyncio.Event(), asyncio.Event()

        async def append(*args, **kwargs):
            started.set()
            await finish.wait()

        self.api.text_input_command.side_effect = append
        first = asyncio.create_task(self.bridge.cmd_text(self.message))
        await asyncio.wait_for(started.wait(), 1)
        queued = asyncio.create_task(self.bridge.cmd_text(self.message))
        await asyncio.sleep(0)
        self.bridge.target_id = "bedroom"
        finish.set()
        await asyncio.wait_for(first, 1)
        with self.assertRaisesRegex(bridge.TextEntryError, "changed"):
            await asyncio.wait_for(queued, 1)
        self.api.text_input_command.assert_awaited_once()

    async def test_keyboard_focus_is_published_without_field_contents(self):
        self.bridge.focusstate_update(KeyboardFocusState.Unfocused, KeyboardFocusState.Focused)
        self.emit.assert_called_once_with("keyboard", available=True, focused=True)
        self.api.text_input_command.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
