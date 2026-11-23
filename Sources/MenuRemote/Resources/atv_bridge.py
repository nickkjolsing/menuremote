#!/usr/bin/env python3
"""Bridge between the MenuRemote menu bar app and pyatv.

Speaks newline-delimited JSON: commands arrive on stdin, events go to stdout.
Logs go to stderr.
"""

import asyncio
import base64
import json
import logging
import os
import re
import sys
import time
from copy import deepcopy

import pyatv
from pyatv import exceptions
from pyatv.const import (
    DeviceState,
    DeviceModel,
    FeatureName,
    FeatureState,
    InputAction,
    KeyboardFocusState,
    PairingRequirement,
    PowerState,
    Protocol,
)
from pyatv.interface import AudioListener, DeviceListener, KeyboardListener, PowerListener, PushListener, RemoteControl
from pyatv.storage.file_storage import FileStorage

LOG = logging.getLogger("atv_bridge")
REMOTE_NAME = "MenuRemote"
PAIR_PROTOCOLS = (Protocol.AirPlay, Protocol.Companion, Protocol.MRP)
NEEDS_PAIRING = (PairingRequirement.Mandatory, PairingRequirement.Optional)
RECONNECT_DELAYS = (2, 5, 10, 30, 60)
POLL_INTERVAL = 5
CONNECT_TIMEOUT = 30
REFRESH_TIMEOUT = 10
CLOSE_TIMEOUT = 5

KEYS = {"up", "down", "left", "right", "select", "menu", "home", "top_menu"}
FEATURES = {
    "play_pause": FeatureName.PlayPause,
    "skip_forward": FeatureName.SkipForward,
    "skip_backward": FeatureName.SkipBackward,
    "set_position": FeatureName.SetPosition,
    "set_volume": FeatureName.SetVolume,
    "volume": FeatureName.Volume,
    "turn_on": FeatureName.TurnOn,
    "turn_off": FeatureName.TurnOff,
    "artwork": FeatureName.Artwork,
}

TV_MODEL_NAMES = {
    DeviceModel.AppleTVGen1: "Apple TV (1st generation)",
    DeviceModel.Gen2: "Apple TV (2nd generation)",
    DeviceModel.Gen3: "Apple TV (3rd generation)",
    DeviceModel.Gen4: "Apple TV HD",
    DeviceModel.Gen4K: "Apple TV 4K (1st generation)",
    DeviceModel.AppleTV4KGen2: "Apple TV 4K (2nd generation)",
    DeviceModel.AppleTV4KGen3: "Apple TV 4K (3rd generation)",
}
# Hardware identifiers, not software-version gates. Unknown future TVs remain usable.
# https://appledb.dev/device-selection/Apple-TV.html
# https://support.apple.com/en-us/149359
TV_HARDWARE_NAMES = {
    "AppleTV1,1": "Apple TV (1st generation)",
    "AppleTV2,1": "Apple TV (2nd generation)",
    "AppleTV3,1": "Apple TV (3rd generation)",
    "AppleTV3,2": "Apple TV (3rd generation)",
    "AppleTV5,3": "Apple TV HD",
    "AppleTV6,2": "Apple TV 4K (1st generation)",
    "AppleTV11,1": "Apple TV 4K (2nd generation)",
    "AppleTV14,1": "Apple TV 4K (3rd generation)",
    "AppleTV18,1": "Apple TV 4K (4th generation)",
}


def emit(event, **payload):
    sys.stdout.write(json.dumps({"event": event, **payload}) + "\n")
    sys.stdout.flush()


def is_remote_candidate(conf):
    """Show identified Apple TV hardware, including models newer than pyatv.

    AirPlay, MRP and Companion also occur on other devices. Neither service
    presence nor a user-assigned name is proof that a receiver is an Apple TV.
    This filter applies only to the picker, never to saved-device reconnects.
    """
    if not any(s.enabled for s in conf.services):
        return False
    info = conf.device_info
    if info.model in TV_MODEL_NAMES:
        return True
    if info.model != DeviceModel.Unknown:
        return False
    return bool(re.fullmatch(r"AppleTV\d+,\d+", info.raw_model or "", re.IGNORECASE))


def services_to_pair(conf):
    return [
        s.protocol
        for s in conf.services
        if s.enabled and s.protocol in PAIR_PROTOCOLS and s.pairing in NEEDS_PAIRING
    ]


def is_paired(conf):
    return all(conf.get_service(p).credentials for p in services_to_pair(conf))


def device_dict(conf):
    info = conf.device_info
    model = TV_HARDWARE_NAMES.get(info.raw_model) or TV_MODEL_NAMES.get(info.model) or "Apple TV"
    legacy = info.model in (DeviceModel.AppleTVGen1, DeviceModel.Gen2, DeviceModel.Gen3) or info.raw_model in (
        "AppleTV1,1", "AppleTV2,1", "AppleTV3,1", "AppleTV3,2",
    )
    os_name = "Apple TV Software" if legacy else "tvOS"
    # pyatv can guess a major version from a build (e.g. '23.x'). Do not present
    # that approximation as the actual installed software version.
    version = info.version
    exact_version = version if version and re.fullmatch(r"\d+(?:\.\d+){0,3}", version) else None
    software = f"{os_name} {exact_version}" if exact_version else None
    return {
        "id": conf.identifier,
        "name": conf.name,
        "address": str(conf.address),
        "model": model,
        "software": software,
        "build": info.build_number,
        "paired": is_paired(conf),
    }


class TextEntryError(ValueError):
    """A safe, user-facing text-entry error that never includes submitted text."""


class Bridge(PushListener, DeviceListener, PowerListener, AudioListener, KeyboardListener):
    def __init__(self, loop, storage_path):
        self.loop = loop
        self.storage = FileStorage(storage_path, loop)
        self.configs = {}
        self.atv = None
        self.target_id = None
        self.pairing = None
        self.pair_queue = []
        self.pair_conf = None
        self.pair_step = 0
        self.artwork_id = None
        self.reconnect_task = None
        self.poll_task = None
        self.closing = False
        self.connection_commands = asyncio.Lock()
        self.connection_attempt = asyncio.Lock()
        self.text_commands = asyncio.Lock()
        self.remote_commands = asyncio.Lock()

    # -- lifecycle ---------------------------------------------------------

    async def run(self):
        await self.storage.load()
        emit("ready", version=pyatv.const.__version__)
        reader = asyncio.StreamReader()
        await self.loop.connect_read_pipe(
            lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
        )
        while line := await reader.readline():
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            asyncio.ensure_future(self.handle(msg))
        await self.cmd_disconnect({})

    async def handle(self, msg):
        cmd = msg.get("cmd")
        try:
            handler = getattr(self, f"cmd_{cmd}", None)
            if handler is None:
                raise ValueError(f"unknown command: {cmd}")
            await handler(msg)
        except Exception as ex:  # report everything to the UI
            if cmd == "text":
                # Protocol exceptions may contain the payload. Never log or echo it.
                LOG.warning("text entry failed (%s)", type(ex).__name__)
                message = str(ex) if isinstance(ex, TextEntryError) else (
                    "Couldn't confirm text was sent. Check the TV before trying again."
                )
                emit("error", command=cmd, request=msg.get("request"), message=message)
                return
            LOG.exception("command %s failed", cmd)
            emit("error", command=cmd, message=str(ex) or type(ex).__name__)

    # -- discovery & pairing ----------------------------------------------

    async def scan(self, identifier=None, timeout=5):
        confs = await pyatv.scan(
            self.loop, timeout=timeout, identifier=identifier, storage=self.storage
        )
        # Unknown model/OS information is never a reason to discard a device.
        # Keep every addressable device for both selection and reconnect scans.
        found = [c for c in confs if c.identifier]
        for conf in found:
            self.configs[conf.identifier] = conf
        return found

    async def cmd_scan(self, msg):
        emit("scanning")
        found = await self.scan()
        suggested = [c for c in found if is_remote_candidate(c)]
        emit(
            "devices",
            devices=[device_dict(c) for c in suggested],
        )

    async def cmd_pair_begin(self, msg):
        await self.cmd_pair_cancel(msg)
        conf = self.configs.get(msg["id"]) or next(iter(await self.scan(msg["id"])), None)
        if conf is None:
            raise exceptions.DeviceIdMissingError("Apple TV not found on the network")
        self.pair_conf = conf
        self.pair_queue = services_to_pair(conf)
        if not self.pair_queue:
            raise exceptions.NotSupportedError(
                "This device does not offer a supported pairing method. "
                "Check its remote access settings and scan again."
            )
        self.pair_step = 0
        await self.pair_next()

    async def pair_next(self):
        protocol = self.pair_queue.pop(0)
        self.pairing = await pyatv.pair(
            self.pair_conf, protocol, self.loop, storage=self.storage, name=REMOTE_NAME
        )
        await self.pairing.begin()
        self.pair_step += 1
        emit("pairing", state="need_pin", protocol=protocol.name, step=self.pair_step)

    async def cmd_pair_pin(self, msg):
        if self.pairing is None:
            raise RuntimeError("no pairing in progress")
        self.pairing.pin(int(msg["pin"]))
        try:
            await self.pairing.finish()
            ok = self.pairing.has_paired
        finally:
            await self.pairing.close()
            self.pairing = None
        if not ok:
            self.pair_queue = []
            emit("pairing", state="failed", message="Pairing was rejected")
            return
        if Protocol.Companion in self.pair_queue and await self.reuse_airplay_credentials():
            self.pair_queue.remove(Protocol.Companion)
        await self.storage.save()
        if self.pair_queue:
            await self.pair_next()
            return
        device_id = self.pair_conf.identifier
        self.pair_conf = None
        emit("pairing", state="done", id=device_id)
        await self.cmd_connect({"id": device_id})

    async def reuse_airplay_credentials(self):
        """Use the AirPlay credentials for Companion too, saving a second PIN.

        tvOS accepts the AirPlay pairing on the Companion channel, but verify it
        with a real connection and fall back to pairing Companion if it's rejected.
        """
        settings = await self.storage.get_settings(self.pair_conf)
        credentials = settings.protocols.airplay.credentials
        if not credentials:
            return False
        conf = deepcopy(self.pair_conf)
        conf.set_credentials(Protocol.Companion, credentials)
        try:
            atv = await asyncio.wait_for(
                pyatv.connect(conf, self.loop, protocol=Protocol.Companion), 10
            )
        except Exception as ex:
            LOG.info("AirPlay credentials not accepted for Companion: %s", ex)
            return False
        await asyncio.gather(*atv.close(), return_exceptions=True)
        settings.protocols.companion.credentials = credentials
        return True

    async def cmd_pair_cancel(self, msg):
        self.pair_queue = []
        if self.pairing is not None:
            await self.pairing.close()
            self.pairing = None

    # -- connection --------------------------------------------------------

    async def cancel_reconnect(self):
        task = self.reconnect_task
        if task is not None:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            if self.reconnect_task is task:
                self.reconnect_task = None

    async def cmd_connect(self, msg):
        # Commands arrive concurrently. Finish cancelling the old attempt before
        # starting another, so its cleanup cannot overwrite the new connection.
        async with self.connection_commands:
            await self.cancel_reconnect()
            self.target_id = msg["id"]
            await self.disconnect()
            await self.connect(wake=msg.get("wake", False))

    async def cmd_disconnect(self, msg):
        async with self.connection_commands:
            self.target_id = None
            await self.cancel_reconnect()
            await self.disconnect()
            emit("disconnected", reason="user")

    async def connect(self, wake=False):
        async with self.connection_attempt:
            try:
                async with asyncio.timeout(CONNECT_TIMEOUT):
                    await self.establish_connection(wake)
            except (Exception, asyncio.CancelledError):
                await self.disconnect()
                # Cancellation means another command is taking over, not a failure.
                if not asyncio.current_task().cancelling():
                    self.schedule_reconnect()
                raise

    async def establish_connection(self, wake=False):
        emit("connecting", id=self.target_id)
        found = await self.scan(self.target_id, timeout=4)
        if not found:
            self.schedule_reconnect()
            raise exceptions.DeviceIdMissingError("Apple TV not found on the network")
        conf = found[0]
        if not is_paired(conf):
            emit("needs_pairing", device=device_dict(conf))
            return
        if conf.deep_sleep and not wake:
            # Connecting would wake the TV; wait until it wakes up by itself.
            emit("asleep", device=device_dict(conf))
            self.schedule_reconnect()
            return
        atv = await pyatv.connect(conf, self.loop, storage=self.storage)
        # An unclassified device may be a streaming-only receiver. Decide from
        # actual features after connecting, never from model or OS guesses.
        # Unavailable controls (e.g. playback while idle) are still supported.
        if atv.features.in_state(
            FeatureState.Unsupported,
            FeatureName.Up, FeatureName.PlayPause, FeatureName.SetPosition,
        ):
            await asyncio.gather(*atv.close(), return_exceptions=True)
            raise exceptions.NotSupportedError(
                "This device does not provide remote controls supported by MenuRemote."
            )
        self.atv = atv
        self.atv.listener = self
        self.atv.push_updater.listener = self
        self.atv.power.listener = self
        self.atv.audio.listener = self
        self.atv.keyboard.listener = self
        self.atv.push_updater.start()
        self.artwork_id = None
        emit("connected", device=device_dict(conf))
        self.powerstate_update(None, self.atv.power.power_state)
        self.emit_volume()
        self.emit_keyboard()
        # Metadata is optional: a slow response must not strand an otherwise
        # usable remote, or prevent the polling task from being started.
        try:
            await self.refresh()
        except Exception:
            LOG.debug("initial metadata refresh failed", exc_info=True)
        if self.atv is atv:
            self.poll_task = asyncio.ensure_future(self.poll())
            LOG.info("connected to %s", conf.name)

    async def disconnect(self):
        if self.poll_task:
            self.poll_task.cancel()
            self.poll_task = None
        if self.atv is not None:
            atv, self.atv = self.atv, None
            self.closing = True
            try:
                # pyatv.close() already stops push updates and is idempotent.
                # Accessing push_updater after a loss raises BlockedStateError.
                atv.listener = None
                async with asyncio.timeout(CLOSE_TIMEOUT):
                    await asyncio.gather(*atv.close(), return_exceptions=True)
            except TimeoutError:
                LOG.warning("timed out closing the previous connection")
            finally:
                self.closing = False

    def schedule_reconnect(self):
        if self.target_id is None or self.reconnect_task:
            return
        self.reconnect_task = asyncio.ensure_future(self.reconnect_loop())

    async def reconnect_loop(self):
        attempt = 0
        try:
            while self.target_id and self.atv is None:
                delay = RECONNECT_DELAYS[min(attempt, len(RECONNECT_DELAYS) - 1)]
                emit("reconnecting", seconds=delay)
                await asyncio.sleep(delay)
                try:
                    await self.connect()
                except Exception as ex:
                    LOG.info("reconnect failed: %s", ex)
                attempt += 1
        finally:
            if self.reconnect_task is asyncio.current_task():
                self.reconnect_task = None

    # -- state -------------------------------------------------------------

    async def poll(self):
        while self.atv is not None:
            await asyncio.sleep(POLL_INTERVAL)
            try:
                await self.refresh()
            except Exception:
                LOG.debug("poll failed", exc_info=True)

    async def refresh(self):
        if self.atv is None:
            return
        atv = self.atv
        self.emit_keyboard()
        async with asyncio.timeout(REFRESH_TIMEOUT):
            playing = await atv.metadata.playing()
            if self.atv is atv:
                await self.publish(playing)

    def features(self):
        feats = self.atv.features
        return {
            key: feats.in_state(FeatureState.Available, name)
            for key, name in FEATURES.items()
        }

    async def publish(self, playing):
        atv = self.atv
        if atv is None:
            return
        try:
            app = atv.metadata.app
            app_name = app.name if app else None
        except Exception:
            app_name = None
        emit(
            "now_playing",
            state=playing.device_state.name.lower(),
            media_type=playing.media_type.name.lower(),
            title=playing.title,
            artist=playing.artist,
            album=playing.album,
            series=playing.series_name,
            season=playing.season_number,
            episode=playing.episode_number,
            position=playing.position,
            total=playing.total_time,
            app=app_name,
            timestamp=time.time(),
            features=self.features(),
        )
        await self.publish_artwork(playing)

    async def publish_artwork(self, playing):
        atv = self.atv
        try:
            artwork_id = atv.metadata.artwork_id
        except Exception:
            artwork_id = None
        if playing.device_state == DeviceState.Idle:
            artwork_id = None
        if artwork_id == self.artwork_id:
            return
        self.artwork_id = artwork_id
        art = None
        if artwork_id is not None:
            try:
                art = await atv.metadata.artwork(width=256)
            except Exception:
                LOG.debug("artwork fetch failed", exc_info=True)
        if art and art.bytes:
            emit("artwork", data=base64.b64encode(art.bytes).decode(), mimetype=art.mimetype)
        else:
            emit("artwork", data=None)

    def emit_volume(self):
        try:
            available = self.atv.features.in_state(FeatureState.Available, FeatureName.SetVolume)
            level = self.atv.audio.volume if available else None
        except Exception:
            available, level = False, None
        emit("volume", level=level, available=available)

    # -- commands ----------------------------------------------------------

    def emit_keyboard(self):
        available, focused = False, False
        if self.atv is not None:
            try:
                available = self.atv.features.in_state(FeatureState.Available, FeatureName.TextAppend)
                focused = self.atv.keyboard.text_focus_state == KeyboardFocusState.Focused
            except exceptions.NotSupportedError:
                pass
        emit("keyboard", available=available, focused=focused)

    def require_atv(self):
        if self.atv is None:
            raise exceptions.ConnectionFailedError("Not connected to an Apple TV")
        return self.atv

    async def after_command(self):
        await asyncio.sleep(0.4)
        await self.refresh()

    async def cmd_key(self, msg):
        key = msg["key"]
        if key not in KEYS:
            raise ValueError(f"unknown key: {key}")
        if msg.get("hold", False):
            if key == "top_menu":
                raise ValueError("top_menu does not support holding")
            await self.remote_button(key, action=InputAction.Hold)
        else:
            await self.remote_button(key)

    async def remote_button(self, key, **kwargs):
        # Commands arrive concurrently. Keep button events in order and prevent
        # overlapping protocol takeovers, including a tap during a held Select.
        async with self.remote_commands:
            atv = self.require_atv()
            # Send the same physical Select for center clicks and Return.
            # The physical Play/Pause also handles variable-speed playback,
            # which MRP's emulated toggle silently ignores in the Seeking state.
            # Older TVs without Companion retain pyatv's normal protocol fallback.
            release = atv.takeover(Protocol.Companion, RemoteControl) if key in (
                "select", "play_pause"
            ) else None
            action = kwargs.get("action", InputAction.SingleTap).name
            protocol = atv.remote_control.main_protocol
            LOG.info("sending button=%s action=%s protocol=%s", key, action,
                     protocol.name if protocol else "unknown")
            try:
                await getattr(atv.remote_control, key)(**kwargs)
                LOG.info("sent button=%s action=%s", key, action)
            finally:
                if release:
                    release()

    async def cmd_text(self, msg):
        async with self.text_commands:
            atv = self.require_atv()
            # Reject stale drafts after switching TVs, including a queued command.
            if msg.get("device_id") != self.target_id:
                raise TextEntryError("The selected Apple TV changed. Please try again.")
            if not atv.features.in_state(FeatureState.Available, FeatureName.TextAppend):
                raise TextEntryError("Text entry isn't available on this Apple TV.")
            if atv.keyboard.text_focus_state != KeyboardFocusState.Focused:
                raise TextEntryError("Open a text field on your Apple TV first.")
            text = msg.get("text")
            if not isinstance(text, str) or not text or len(text) > 4096:
                raise TextEntryError("Enter between 1 and 4,096 characters.")
            # Append, never replace, the TV's current text. Do not fetch its contents.
            async with asyncio.timeout(8):
                await atv.keyboard.text_append(text)
            emit("text_sent", request=msg.get("request"))

    async def cmd_play_pause(self, msg):
        await self.remote_button("play_pause")
        await self.after_command()

    async def cmd_skip(self, msg):
        atv = self.require_atv()
        seconds = float(msg.get("seconds", 10))
        rc = atv.remote_control
        feature = FeatureName.SkipForward if seconds > 0 else FeatureName.SkipBackward
        if atv.features.in_state(FeatureState.Available, feature):
            await (rc.skip_forward(seconds) if seconds > 0 else rc.skip_backward(-seconds))
        else:
            playing = await atv.metadata.playing()
            await rc.set_position(max(0, int((playing.position or 0) + seconds)))
        await self.after_command()

    async def cmd_seek(self, msg):
        await self.require_atv().remote_control.set_position(int(msg["position"]))
        await self.after_command()

    async def cmd_volume(self, msg):
        await self.require_atv().audio.set_volume(float(msg["level"]))

    async def cmd_power(self, msg):
        if self.atv is None and msg["on"] and self.target_id:
            await self.cmd_connect({"id": self.target_id, "wake": True})
        power = self.require_atv().power
        await (power.turn_on() if msg["on"] else power.turn_off())

    async def cmd_refresh(self, msg):
        await self.refresh()

    # -- pyatv listeners ---------------------------------------------------

    def playstatus_update(self, updater, playstatus):
        asyncio.ensure_future(self.publish(playstatus))

    def playstatus_error(self, updater, exception):
        LOG.debug("push update error: %s", exception)

    def connection_lost(self, exception):
        if self.closing:
            return
        LOG.info("connection lost: %s", exception)
        self.atv = None
        if self.poll_task:
            self.poll_task.cancel()
            self.poll_task = None
        emit("disconnected", reason=str(exception))
        self.schedule_reconnect()

    def connection_closed(self):
        if self.closing:
            return
        self.connection_lost("connection closed")

    def powerstate_update(self, old_state, new_state):
        emit("power", on=new_state == PowerState.On, known=new_state != PowerState.Unknown)

    def volume_update(self, old_level, new_level):
        emit("volume", level=new_level, available=True)

    def focusstate_update(self, old_state, new_state):
        self.emit_keyboard()

    def volume_device_update(self, output_device, old_level, new_level):
        pass

    def outputdevices_update(self, old_devices, new_devices):
        pass


def main():
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.DEBUG if os.environ.get("ATV_BRIDGE_DEBUG") else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    storage_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.pyatv.conf")
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(Bridge(loop, storage_path).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
