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
        for raw_model in ("AppleTV18,1", "AppleTV999,1"):
            for os in OperatingSystem:
                for version in (None, "1.0", "99.7", "future-version"):
                    with self.subTest(raw_model=raw_model, os=os, version=version):
                        self.assertTrue(bridge.is_remote_candidate(device(
                            name="Living Room", raw_model=raw_model,
                            os=os, version=version)))

    def test_recognized_apple_tv_with_remote_service_is_still_suggested(self):
        self.assertTrue(bridge.is_remote_candidate(device(
            model=DeviceModel.AppleTV4KGen3, raw_model="AppleTV14,1")))

    def test_non_tv_receivers_are_not_suggested(self):
        for model, raw_model, os in [
            (DeviceModel.HomePod, "AudioAccessory1,1", OperatingSystem.TvOS),
            (DeviceModel.HomePodMini, "AudioAccessory5,1", OperatingSystem.TvOS),
            (DeviceModel.HomePodGen2, "AudioAccessory6,1", OperatingSystem.TvOS),
            (DeviceModel.Unknown, "Mac17,9", OperatingSystem.MacOS),
            (DeviceModel.Unknown, "Receiver1,1", OperatingSystem.Unknown),
            (DeviceModel.Unknown, None, OperatingSystem.Unknown),
        ]:
            with self.subTest(model=model, raw_model=raw_model):
                # Even a device named Apple TV needs an advertised remote service.
                self.assertFalse(bridge.is_remote_candidate(device(
                    model=model, raw_model=raw_model, os=os,
                    companion_pairing=PairingRequirement.Unsupported)))

    def test_remote_services_alone_do_not_identify_an_apple_tv(self):
        for raw_model in (None, "FutureHardware1,1", "Mac17,9", "AudioAccessory5,1"):
            for protocols in ((Protocol.MRP,), (Protocol.AirPlay, Protocol.Companion)):
                self.assertFalse(bridge.is_remote_candidate(device(
                    name="Apple TV", raw_model=raw_model, protocols=protocols)))

    def test_known_non_tv_devices_are_excluded_even_with_remote_services(self):
        for model, raw_model, os in [
            (DeviceModel.HomePod, "AudioAccessory1,1", OperatingSystem.TvOS),
            (DeviceModel.HomePodMini, "AudioAccessory5,1", OperatingSystem.TvOS),
            (DeviceModel.HomePodGen2, "AudioAccessory6,1", OperatingSystem.TvOS),
            (DeviceModel.Unknown, "MacBookPro18,1", OperatingSystem.MacOS),
            (DeviceModel.Unknown, "Mac17,9", OperatingSystem.MacOS),
            (DeviceModel.Music, None, OperatingSystem.MacOS),
        ]:
            with self.subTest(model=model, raw_model=raw_model):
                self.assertFalse(bridge.is_remote_candidate(device(
                    model=model, raw_model=raw_model, os=os)))

    def test_disabled_remote_services_are_not_suggested_or_paired(self):
        conf = device()
        for service in conf.services:
            service.enabled = False
        self.assertFalse(bridge.is_remote_candidate(conf))
        self.assertEqual(bridge.services_to_pair(conf), [])

    def test_identified_tv_is_kept_even_if_pairing_is_temporarily_disabled(self):
        conf = device(companion_pairing=PairingRequirement.Disabled)
        self.assertTrue(bridge.is_remote_candidate(conf))
        conf.get_service(Protocol.Companion).credentials = "existing-credentials"
        self.assertTrue(bridge.is_remote_candidate(conf))


class DiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bridge = bridge.Bridge(
            asyncio.get_running_loop(), str(Path(self.temp.name) / "pyatv.conf"))
        delays = patch.object(bridge, "INITIAL_SCAN_DELAYS", (0, 0, 0))
        delays.start()
        self.addCleanup(delays.stop)

    async def test_initial_scan_recovers_from_failure_without_a_manual_retry(self):
        tv = device()
        with patch.object(self.bridge, "scan", new=AsyncMock(side_effect=[OSError("Network unavailable"), [tv]])) as scan:
            with patch.object(bridge, "emit") as emit, self.assertLogs("atv_bridge", level="WARNING"):
                await self.bridge.handle({"cmd": "scan"})
        self.assertEqual(scan.await_count, 2)
        self.assertEqual([call.args[0] for call in emit.call_args_list], ["scanning", "devices"])
        emit.assert_any_call("devices", devices=[bridge.device_dict(tv)])

    async def test_initial_empty_scan_retries_before_showing_no_devices(self):
        tv = device()
        speaker = device("speaker", model=DeviceModel.HomePodMini, raw_model="AudioAccessory5,1")
        with patch.object(self.bridge, "scan", new=AsyncMock(side_effect=[[], [speaker], [tv]])) as scan:
            with patch.object(bridge, "emit") as emit:
                await self.bridge.cmd_scan({})
        self.assertEqual(scan.await_count, 3)
        self.assertEqual([call.args[0] for call in emit.call_args_list], ["scanning", "devices"])
        emit.assert_any_call("devices", devices=[bridge.device_dict(tv)])

    async def test_initial_retries_end_with_an_error_and_manual_retry_still_works(self):
        scan = AsyncMock(side_effect=OSError("Network unavailable"))
        with patch.object(self.bridge, "scan", new=scan), patch.object(bridge, "emit") as emit:
            with self.assertLogs("atv_bridge", level="WARNING"):
                await self.bridge.handle({"cmd": "scan"})
            self.assertEqual(scan.await_count, 3)
            emit.assert_called_with("error", command="scan", message="Network unavailable")
            # An explicit retry after the initial budget must still send a scan.
            scan.side_effect = None
            scan.return_value = [device()]
            await self.bridge.cmd_scan({})
            self.assertEqual(scan.await_count, 4)
            emit.assert_called_with("devices", devices=[bridge.device_dict(device())])

    async def test_empty_initial_search_stops_and_later_searches_do_not_retry(self):
        with patch.object(self.bridge, "scan", new=AsyncMock(return_value=[])) as scan:
            with patch.object(bridge, "emit") as emit:
                await self.bridge.cmd_scan({})
                self.assertEqual(scan.await_count, 3)
                emit.assert_called_with("devices", devices=[])
                await self.bridge.cmd_scan({})
                self.assertEqual(scan.await_count, 4)

    async def test_successful_first_search_does_not_retry(self):
        with patch.object(self.bridge, "scan", new=AsyncMock(return_value=[device()])) as scan:
            with patch.object(bridge, "emit"):
                await self.bridge.cmd_scan({})
        scan.assert_awaited_once()

    async def test_overlapping_search_requests_share_the_active_search(self):
        started, finish = asyncio.Event(), asyncio.Event()

        async def slow_scan():
            started.set()
            await finish.wait()
            return [device()]

        with patch.object(self.bridge, "scan", new=AsyncMock(side_effect=slow_scan)) as scan:
            with patch.object(bridge, "emit") as emit:
                pending = asyncio.create_task(self.bridge.cmd_scan({}))
                try:
                    await asyncio.wait_for(started.wait(), 1)
                    await self.bridge.cmd_scan({})
                finally:
                    finish.set()
                    await asyncio.wait_for(pending, 1)
        scan.assert_awaited_once()
        self.assertEqual([call.args[0] for call in emit.call_args_list], ["scanning", "devices"])

    async def test_cancellation_is_not_retried(self):
        with patch.object(self.bridge, "scan", new=AsyncMock(side_effect=asyncio.CancelledError)) as scan:
            with patch.object(bridge, "emit") as emit:
                with self.assertRaises(asyncio.CancelledError):
                    await self.bridge.cmd_scan({})
        scan.assert_awaited_once()
        self.assertFalse(self.bridge.discovery_lock.locked())
        self.assertEqual([call.args[0] for call in emit.call_args_list], ["scanning"])

    async def test_picker_finds_replacement_despite_cached_tv_with_same_name(self):
        old = device("old-tv", model=DeviceModel.Gen4K, raw_model="AppleTV6,2")
        new = device("new-tv")
        self.bridge.configs[old.identifier] = old
        self.bridge.target_id = old.identifier
        with patch.object(bridge.pyatv, "scan", new=AsyncMock(return_value=[new])) as scan:
            with patch.object(bridge, "emit") as emit:
                await self.bridge.cmd_scan({"cmd": "scan"})

        self.assertIsNone(scan.call_args.kwargs["identifier"])
        emit.assert_any_call("devices", devices=[bridge.device_dict(new)])
        self.assertIs(self.bridge.configs["new-tv"], new)

    async def test_unclassified_devices_are_hidden_but_saved_connections_still_work(self):
        unknown = device(raw_model=None, protocols=(Protocol.AirPlay,))
        with patch.object(bridge.pyatv, "scan", new=AsyncMock(return_value=[unknown])) as scan:
            with patch.object(bridge, "emit") as emit:
                await self.bridge.cmd_scan({"cmd": "scan"})
            emit.assert_any_call("devices", devices=[])
            self.assertIs(self.bridge.configs[unknown.identifier], unknown)
            # Connection scans must not reapply picker suggestions as a filter.
            self.assertEqual(await self.bridge.scan(unknown.identifier), [unknown])
            self.assertEqual(scan.call_args.kwargs["identifier"], unknown.identifier)

        with patch.object(self.bridge, "pair_next", new=AsyncMock()):
            await self.bridge.cmd_pair_begin({"id": unknown.identifier})
        self.assertIs(self.bridge.pair_conf, unknown)
        self.assertEqual(self.bridge.pair_queue, [Protocol.AirPlay])

    async def test_scan_does_not_offer_macs_or_homepods_as_tvs(self):
        tv = device()
        mac = device("mac", raw_model="Mac17,9", os=OperatingSystem.MacOS)
        speaker = device("speaker", model=DeviceModel.HomePodMini, raw_model="AudioAccessory5,1")
        with patch.object(bridge.pyatv, "scan", new=AsyncMock(return_value=[tv, mac, speaker])):
            with patch.object(bridge, "emit") as emit:
                await self.bridge.cmd_scan({})
        emit.assert_any_call("devices", devices=[bridge.device_dict(tv)])

    async def test_device_details_use_generation_and_reported_software(self):
        for raw_model, expected in [
            ("AppleTV18,1", "Apple TV 4K (4th generation)"),
            ("AppleTV14,1", "Apple TV 4K (3rd generation)"),
            ("AppleTV11,1", "Apple TV 4K (2nd generation)"),
            ("AppleTV6,2", "Apple TV 4K (1st generation)"),
            ("AppleTV5,3", "Apple TV HD"),
            ("AppleTV999,1", "Apple TV"),
        ]:
            with self.subTest(raw_model=raw_model):
                details = bridge.device_dict(device(raw_model=raw_model, version="27.1"))
                self.assertEqual(details["model"], expected)
                self.assertEqual(details["software"], "tvOS 27.1")

    async def test_missing_or_approximate_software_versions_are_not_invented(self):
        self.assertIsNone(bridge.device_dict(device())["software"])
        self.assertIsNone(bridge.device_dict(device(version="23.x"))["software"])
        self.assertEqual(bridge.device_dict(device(raw_model="AppleTV3,2", version="7.9"))["software"],
                         "Apple TV Software 7.9")

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
