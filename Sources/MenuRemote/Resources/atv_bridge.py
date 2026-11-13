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
import sys
import time
from copy import deepcopy

import pyatv
from pyatv import exceptions
from pyatv.const import (
    DeviceState,
    FeatureName,
    FeatureState,
    PairingRequirement,
    PowerState,
    Protocol,
)
from pyatv.interface import AudioListener, DeviceListener, PowerListener, PushListener
from pyatv.storage.file_storage import FileStorage

LOG = logging.getLogger("atv_bridge")
REMOTE_NAME = "MenuRemote"
PAIR_PROTOCOLS = (Protocol.AirPlay, Protocol.Companion, Protocol.MRP)
NEEDS_PAIRING = (PairingRequirement.Mandatory, PairingRequirement.Optional)
RECONNECT_DELAYS = (2, 5, 10, 30, 60)
POLL_INTERVAL = 5

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


def emit(event, **payload):
    sys.stdout.write(json.dumps({"event": event, **payload}) + "\n")
    sys.stdout.flush()


def is_remote_candidate(conf):
    """Suggest devices by remote services, independently of model/OS metadata.

    AirPlay alone also describes speakers and Macs. Companion must advertise
    pairing we support (or already have credentials); MRP is a remote service.
    This is only a picker suggestion: other devices remain selectable too.
    """
    return any(
        s.enabled and (
            s.protocol == Protocol.MRP
            or (s.protocol == Protocol.Companion
                and (s.pairing in NEEDS_PAIRING or s.credentials))
        )
        for s in conf.services
    )


def services_to_pair(conf):
    return [
        s.protocol
        for s in conf.services
        if s.enabled and s.protocol in PAIR_PROTOCOLS and s.pairing in NEEDS_PAIRING
    ]


def is_paired(conf):
    return all(conf.get_service(p).credentials for p in services_to_pair(conf))


def device_dict(conf):
    return {
        "id": conf.identifier,
        "name": conf.name,
        "address": str(conf.address),
        "model": conf.device_info.model_str or "Unknown model",
        "paired": is_paired(conf),
    }


class Bridge(PushListener, DeviceListener, PowerListener, AudioListener):
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
        await self.disconnect()

    async def handle(self, msg):
        cmd = msg.get("cmd")
        try:
            handler = getattr(self, f"cmd_{cmd}", None)
            if handler is None:
                raise ValueError(f"unknown command: {cmd}")
            await handler(msg)
        except Exception as ex:  # report everything to the UI
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
        others = [c for c in found if not is_remote_candidate(c)]
        emit(
            "devices",
            devices=[device_dict(c) for c in suggested],
            other_devices=[device_dict(c) for c in others],
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

    async def cmd_connect(self, msg):
        self.target_id = msg["id"]
        if self.reconnect_task:
            self.reconnect_task.cancel()
            self.reconnect_task = None
        await self.disconnect()
        await self.connect(wake=msg.get("wake", False))

    async def cmd_disconnect(self, msg):
        self.target_id = None
        await self.disconnect()
        emit("disconnected", reason="user")

    async def connect(self, wake=False):
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
        self.atv.push_updater.start()
        self.artwork_id = None
        emit("connected", device=device_dict(conf))
        self.powerstate_update(None, self.atv.power.power_state)
        self.emit_volume()
        await self.refresh()
        self.poll_task = asyncio.ensure_future(self.poll())

    async def disconnect(self):
        if self.poll_task:
            self.poll_task.cancel()
            self.poll_task = None
        if self.atv is not None:
            atv, self.atv = self.atv, None
            self.closing = True
            try:
                atv.push_updater.stop()
                await asyncio.gather(*atv.close(), return_exceptions=True)
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
        await self.publish(await self.atv.metadata.playing())

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
        await getattr(self.require_atv().remote_control, key)()

    async def cmd_play_pause(self, msg):
        await self.require_atv().remote_control.play_pause()
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
            if self.reconnect_task:
                self.reconnect_task.cancel()
                self.reconnect_task = None
            await self.connect(wake=True)
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
