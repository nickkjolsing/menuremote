import asyncio
import importlib.util
from ipaddress import IPv4Address
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

from pyatv.conf import AppleTV, ManualService
from pyatv.const import DeviceModel, FeatureState, OperatingSystem, PairingRequirement, Protocol
from pyatv.interface import DeviceInfo, FeatureInfo, Features


BRIDGE_PATH = (Path(__file__).resolve().parents[1]
               / "Sources/MenuRemote/Resources/atv_bridge.py")
spec = importlib.util.spec_from_file_location("atv_bridge", BRIDGE_PATH)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def device(identifier="new-tv", name="Apple TV 4K", model=DeviceModel.Unknown,
           raw_model="AppleTV18,1", os=OperatingSystem.Unknown,
           protocols=(Protocol.AirPlay, Protocol.Companion),
           companion_pairing=PairingRequirement.Mandatory, version=None):
    conf = AppleTV(IPv4Address("192.0.2.1"), name, device_info=DeviceInfo({
        DeviceInfo.MODEL: model,
        DeviceInfo.RAW_MODEL: raw_model,
        DeviceInfo.OPERATING_SYSTEM: os,
        DeviceInfo.VERSION: version,
    }))
    for protocol in protocols:
        conf.add_service(ManualService(
            identifier, protocol, 7000, {},
            pairing_requirement=(companion_pairing if protocol == Protocol.Companion
                                 else PairingRequirement.Mandatory),
        ))
    return conf


class DeviceSuggestionTests(unittest.TestCase):
    def test_remote_services_work_without_known_models_or_software_versions(self):
        for raw_model in ("AppleTV18,1", "AppleTV999,1", "FutureHardware1,1", None):
            for os in OperatingSystem:
                for version in (None, "1.0", "99.7", "future-version"):
                    with self.subTest(raw_model=raw_model, os=os, version=version):
                        self.assertTrue(bridge.is_remote_candidate(device(
                            name="Living Room", raw_model=raw_model,
                            os=os, version=version)))

    def test_recognized_apple_tv_with_remote_service_is_still_suggested(self):
        self.assertTrue(bridge.is_remote_candidate(device(
            model=DeviceModel.AppleTV4KGen3, raw_model="AppleTV14,1")))

    def test_streaming_and_unsupported_companion_services_are_not_suggested(self):
        for model, raw_model, os in [
            (DeviceModel.HomePod, "AudioAccessory1,1", OperatingSystem.TvOS),
            (DeviceModel.HomePodMini, "AudioAccessory5,1", OperatingSystem.TvOS),
            (DeviceModel.HomePodGen2, "AudioAccessory6,1", OperatingSystem.TvOS),
            (DeviceModel.Unknown, "Mac17,9", OperatingSystem.MacOS),
            (DeviceModel.Unknown, "Receiver1,1", OperatingSystem.Unknown),
            (DeviceModel.Unknown, None, OperatingSystem.Unknown),
            (DeviceModel.Gen3, "AppleTV3,2", OperatingSystem.Legacy),
        ]:
            with self.subTest(model=model, raw_model=raw_model):
                # Even a device named Apple TV needs an advertised remote service.
                self.assertFalse(bridge.is_remote_candidate(device(
                    model=model, raw_model=raw_model, os=os,
                    companion_pairing=PairingRequirement.Unsupported)))

    def test_mrp_service_is_suggested_without_companion_or_model_metadata(self):
        self.assertTrue(bridge.is_remote_candidate(device(
            raw_model=None, protocols=(Protocol.MRP,))))

    def test_disabled_remote_services_are_not_suggested_or_paired(self):
        conf = device()
        for service in conf.services:
            service.enabled = False
        self.assertFalse(bridge.is_remote_candidate(conf))
        self.assertEqual(bridge.services_to_pair(conf), [])

    def test_existing_companion_credentials_work_when_pairing_is_unavailable(self):
        conf = device(companion_pairing=PairingRequirement.Disabled)
        self.assertFalse(bridge.is_remote_candidate(conf))
        conf.get_service(Protocol.Companion).credentials = "existing-credentials"
        self.assertTrue(bridge.is_remote_candidate(conf))


class DiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bridge = bridge.Bridge(
            asyncio.get_running_loop(), str(Path(self.temp.name) / "pyatv.conf"))

    async def test_picker_finds_replacement_despite_cached_tv_with_same_name(self):
        old = device("old-tv", model=DeviceModel.Gen4K, raw_model="AppleTV6,2")
        new = device("new-tv")
        self.bridge.configs[old.identifier] = old
        self.bridge.target_id = old.identifier
        with patch.object(bridge.pyatv, "scan", new=AsyncMock(return_value=[new])) as scan:
            with patch.object(bridge, "emit") as emit:
                await self.bridge.cmd_scan({"cmd": "scan"})

        self.assertIsNone(scan.call_args.kwargs["identifier"])
        emit.assert_any_call("devices", devices=[{
            "id": "new-tv", "name": "Apple TV 4K", "address": "192.0.2.1",
            "model": "AppleTV18,1", "paired": False,
        }], other_devices=[])
        self.assertIs(self.bridge.configs["new-tv"], new)

    async def test_unclassified_devices_remain_selectable_and_reconnectable(self):
        unknown = device(raw_model=None, protocols=(Protocol.AirPlay,))
        with patch.object(bridge.pyatv, "scan", new=AsyncMock(return_value=[unknown])) as scan:
            with patch.object(bridge, "emit") as emit:
                await self.bridge.cmd_scan({"cmd": "scan"})
            emit.assert_any_call("devices", devices=[], other_devices=[bridge.device_dict(unknown)])
            self.assertIs(self.bridge.configs[unknown.identifier], unknown)
            # Connection scans must not reapply picker suggestions as a filter.
            self.assertEqual(await self.bridge.scan(unknown.identifier), [unknown])
            self.assertEqual(scan.call_args.kwargs["identifier"], unknown.identifier)

        with patch.object(self.bridge, "pair_next", new=AsyncMock()):
            await self.bridge.cmd_pair_begin({"id": unknown.identifier})
        self.assertIs(self.bridge.pair_conf, unknown)
        self.assertEqual(self.bridge.pair_queue, [Protocol.AirPlay])

    async def test_discovery_keeps_only_devices_with_a_usable_identifier(self):
        unidentified = device(protocols=())
        with patch.object(bridge.pyatv, "scan", new=AsyncMock(return_value=[unidentified])):
            self.assertEqual(await self.bridge.scan(), [])

    async def test_unsupported_pairing_reports_a_clear_error(self):
        unknown = device(protocols=(Protocol.RAOP,))
        self.bridge.configs[unknown.identifier] = unknown
        with self.assertRaisesRegex(bridge.exceptions.NotSupportedError, "supported pairing method"):
            await self.bridge.cmd_pair_begin({"id": unknown.identifier})

    async def test_older_mrp_devices_use_their_advertised_pairing_method(self):
        older = device(raw_model=None, protocols=(Protocol.MRP,))
        self.bridge.configs[older.identifier] = older
        with patch.object(self.bridge, "pair_next", new=AsyncMock()):
            await self.bridge.cmd_pair_begin({"id": older.identifier})
        self.assertEqual(self.bridge.pair_queue, [Protocol.MRP])

    async def test_streaming_only_connection_reports_error_and_closes(self):
        class StreamingFeatures(Features):
            def get_feature(self, name):
                return FeatureInfo(FeatureState.Unsupported)

        conf = device(raw_model=None)
        for service in conf.services:
            service.credentials = "test-credentials"
        atv = Mock()
        atv.features = StreamingFeatures()
        atv.close.return_value = set()
        self.bridge.target_id = conf.identifier
        with patch.object(self.bridge, "scan", new=AsyncMock(return_value=[conf])):
            with patch.object(bridge.pyatv, "connect", new=AsyncMock(return_value=atv)):
                with patch.object(bridge, "emit") as emit:
                    with self.assertRaisesRegex(bridge.exceptions.NotSupportedError, "remote controls"):
                        await self.bridge.connect()
        atv.close.assert_called_once()
        self.assertIsNone(self.bridge.atv)
        self.assertNotIn("connected", [call.args[0] for call in emit.call_args_list])

    async def test_idle_or_unknown_feature_states_do_not_reject_a_device(self):
        class InactiveFeatures(Features):
            def __init__(self, state):
                self.state = state

            def get_feature(self, name):
                return FeatureInfo(self.state)

        conf = device(raw_model=None)
        for service in conf.services:
            service.credentials = "test-credentials"
        self.bridge.target_id = conf.identifier
        for state in (FeatureState.Unavailable, FeatureState.Unknown):
            with self.subTest(state=state):
                atv = Mock()
                atv.features = InactiveFeatures(state)
                atv.close.return_value = set()
                with patch.object(self.bridge, "scan", new=AsyncMock(return_value=[conf])):
                    with patch.object(bridge.pyatv, "connect", new=AsyncMock(return_value=atv)):
                        with patch.object(self.bridge, "refresh", new=AsyncMock()):
                            with patch.object(bridge, "emit") as emit:
                                await self.bridge.connect()
                self.assertIs(self.bridge.atv, atv)
                emit.assert_any_call("connected", device=bridge.device_dict(conf))
                await self.bridge.disconnect()

    async def test_replacement_does_not_inherit_same_named_tvs_credentials(self):
        old = device("old-tv")
        old.get_service(Protocol.AirPlay).credentials = "old-credentials"
        await self.bridge.storage.get_settings(old)
        new = device("new-tv")
        settings = await self.bridge.storage.get_settings(new)
        self.assertIsNone(settings.protocols.airplay.credentials)
        self.assertFalse(bridge.is_paired(new))


if __name__ == "__main__":
    unittest.main()
