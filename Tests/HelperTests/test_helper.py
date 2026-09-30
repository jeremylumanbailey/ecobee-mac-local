import asyncio
import copy
import importlib.util
import math
from pathlib import Path
import unittest
from datetime import datetime, timedelta, timezone

path = Path(__file__).parents[2] / "helper" / "hap_helper.py"
spec = importlib.util.spec_from_file_location("hap_helper", path)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

def characteristic(iid, kind, value=None, writable=False, **metadata):
    return {"iid": iid, "type": helper.uuid(kind), "value": value,
            "perms": ["pr", "pw"] if writable else ["pr"], "format": "float", **metadata}

def accessories():
    return [{"aid": 1, "services": [
        {"iid": 1, "type": "3E", "characteristics": [characteristic(2, "23", "Hallway"), characteristic(3, "21", "Essential"), characteristic(4, "52", "4.10.4.48")]},
        {"iid": 10, "type": "4A", "characteristics": [
            characteristic(11, "11", 22.5), characteristic(12, "10", 43),
            characteristic(13, "33", 3, True, minValue=0, maxValue=3, **{"valid-values": [0, 1, 2, 3]}),
            characteristic(14, "35", 22, True, minValue=7, maxValue=32, minStep=0.5),
            characteristic(15, "12", 20, True, minValue=7, maxValue=32, minStep=0.5),
            characteristic(16, "0D", 24, True, minValue=7, maxValue=32, minStep=0.5),
            characteristic(17, helper.TYPES["resume"], None, True, format="bool")]}]}]

class ParsingTests(unittest.TestCase):
    def setUp(self): self.state = helper.parse_accessories(accessories())
    def test_reads_model_firmware_and_celsius(self):
        self.assertEqual(self.state["firmware"], "4.10.4.48")
        self.assertEqual(self.state["thermostats"][0]["current"], 22.5)
    def test_exposes_only_writable_supported_controls(self):
        self.assertNotIn("fan", self.state["thermostats"][0]["fields"])
        self.assertNotIn("current", self.state["thermostats"][0]["fields"])
    def test_skips_readings_with_error_status(self):
        data = accessories(); data[0]["services"][1]["characteristics"][0]["status"] = -70402
        self.assertNotIn("current", helper.parse_accessories(data)["thermostats"][0])
    def test_valid_write_resolves_exact_device_characteristic(self):
        self.assertEqual(helper.validate_writes(self.state, "1.10", {"target": 23}), [(1, 14, 23)])
    def test_current_fan_state_is_separate_from_requested_fan_mode(self):
        for current in (0, 1, 2):
            data = accessories()
            data[0]["services"][1]["characteristics"] += [
                characteristic(18, "AF", current),
                characteristic(19, helper.TYPES["fan"], 0, True)]
            thermostat = helper.parse_accessories(data)["thermostats"][0]
            self.assertEqual(thermostat["fanState"], current)
            self.assertEqual(thermostat["fan"], 0)
            self.assertNotIn("fanState", thermostat["fields"])
    def test_fan_only_commands_leave_temperature_and_mode_untouched(self):
        data = accessories()
        data[0]["services"][1]["characteristics"].append(
            characteristic(19, helper.TYPES["fan"], 0, True))
        state = helper.parse_accessories(data)
        for value in (0, 100):
            self.assertEqual(helper.validate_writes(state, "1.10", {"fan": value}), [(1, 19, value)])
        for value in (1, 50, -1, 101, True, "100"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                helper.validate_writes(state, "1.10", {"fan": value})
    def test_missing_or_failed_fan_reading_does_not_report_off(self):
        self.assertNotIn("fanState", self.state["thermostats"][0])
        data = accessories()
        data[0]["services"][1]["characteristics"].append(characteristic(18, "AF", 0, status=-70402))
        self.assertNotIn("fanState", helper.parse_accessories(data)["thermostats"][0])
    def test_rejects_wrong_thermostat(self):
        with self.assertRaises(ValueError): helper.validate_writes(self.state, "2.10", {"target": 23})
    def test_rejects_unsupported_control(self):
        with self.assertRaises(ValueError): helper.validate_writes(self.state, "1.10", {"fan": 100})
    def test_rejects_nan_infinite_boolean_and_string(self):
        for value in [math.nan, math.inf, True, "23"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                helper.validate_writes(self.state, "1.10", {"target": value})
    def test_rejects_out_of_range_and_step(self):
        for value in [6, 33, 22.25]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                helper.validate_writes(self.state, "1.10", {"target": value})
    def test_rejects_crossed_thresholds(self):
        with self.assertRaises(ValueError): helper.validate_writes(self.state, "1.10", {"heat": 25})
        with self.assertRaises(ValueError): helper.validate_writes(self.state, "1.10", {"heat": 23, "cool": 23})
    def test_accepts_valid_threshold_pair(self):
        self.assertEqual(helper.validate_writes(self.state, "1.10", {"heat": 21, "cool": 25}), [(1, 15, 21), (1, 16, 25)])
    def test_rejects_mode_not_in_valid_values(self):
        self.state["thermostats"][0]["fields"]["mode"]["validValues"] = [0, 1]
        with self.assertRaises(ValueError): helper.validate_writes(self.state, "1.10", {"mode": 2})
    def test_resume_must_be_explicit_and_alone(self):
        self.assertEqual(helper.validate_writes(self.state, "1.10", {"resume": True}), [(1, 17, True)])
        for changes in [{"resume": False}, {"resume": True, "target": 22}]:
            with self.assertRaises(ValueError): helper.validate_writes(self.state, "1.10", changes)
    def test_errors_do_not_include_exception_secrets(self):
        self.assertNotIn("SECRET", helper.safe_error(RuntimeError("SECRET"), "connect"))
        self.assertIn("may have reached", helper.safe_error(TimeoutError(), "write"))

def native_fan_hold(now):
    data = accessories()
    info = data[0]["services"][0]["characteristics"]
    info[1]["value"] = "ECB701"; info[2]["value"] = "4.10.40048"
    chars = data[0]["services"][1]["characteristics"]
    chars[2]["value"] = 0
    end = (now + timedelta(minutes=15)).isoformat(timespec="seconds") + "Q"
    for iid, key, value in [(30, "state", 0), (31, "currentComfort", 3),
                            (32, "fanRequested", 100), (33, "fanReadback", 100),
                            (34, "fanTarget", 0), (35, "fanState", 2), (36, "holdEnd", end)]:
        chars.append(characteristic(iid, helper.TIMER_INSPECTION_TYPES[key], value, key in ("fanRequested", "fanTarget", "holdEnd")))
    return data, end

class DeadlineTrialTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 9, 29, 10, 0, tzinfo=timezone(timedelta(hours=-4)))
        self.data, self.end = native_fan_hold(self.now)
    def test_writes_local_wall_time_and_expects_normalized_readback(self):
        writes, end, baseline = helper.prepare_fan_deadline_trial(self.data, self.end, self.now)
        self.assertEqual(writes, [(1, 36, "2026-09-29T10:02:00")])
        self.assertEqual(end, "2026-09-29T10:02:00-04:00Q")
        self.assertEqual(baseline["mode"], 0)
    def test_refuses_heating_or_cooling_mode(self):
        self.data[0]["services"][1]["characteristics"][2]["value"] = 1
        with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data, self.end, self.now)
    def test_refuses_stale_expected_hold(self):
        with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data, "different", self.now)
    def test_refuses_hold_that_is_about_to_end_or_indefinite(self):
        for now in (self.now+timedelta(minutes=14), self.now-timedelta(days=1)):
            with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data, self.end, now)
    def test_refuses_other_firmware(self):
        self.data[0]["services"][0]["characteristics"][2]["value"] = "unknown"
        with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data, self.end, self.now)
    def test_refuses_absent_timezone(self):
        field = self.data[0]["services"][1]["characteristics"][-1]
        field["value"] = "2026-09-29T10:15:00Q"
        with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data, field["value"], self.now)

class TimerInspectionTests(unittest.TestCase):
    def test_reports_capabilities_without_exporting_names_or_serials(self):
        data = accessories()
        data[0]["services"][0]["characteristics"] += [characteristic(99, "30", "PRIVATE_SERIAL")]
        data[0]["services"][1]["characteristics"] += [
            characteristic(20, helper.TIMER_INSPECTION_TYPES["holdEnd"], "2026-09-29T12:30:00-04:00T", True, format="string"),
            characteristic(21, "D3", 900, True, format="uint32")]
        report = helper.inspect_fan_timer(data)
        fields = report["services"][0]["fields"]
        self.assertEqual(fields["holdEnd"]["value"], "2026-09-29T12:30:00-04:00T")
        self.assertIn("pw", fields["holdEnd"]["perms"])
        self.assertEqual(fields["setDuration"]["value"], 900)
        self.assertFalse(fields["remainingDuration"]["present"])
        self.assertNotIn("PRIVATE_SERIAL", str(report))
        self.assertNotIn("Hallway", str(report))
    def test_failed_or_write_only_readings_are_not_presented_as_current(self):
        for metadata in ({"status": -70402}, {"perms": ["pw"]}):
            data = accessories()
            data[0]["services"][1]["characteristics"].append(
                characteristic(20, helper.TIMER_INSPECTION_TYPES["holdEnd"], "2026-09-29T12:30:00-04:00T", True, **metadata))
            field = helper.inspect_fan_timer(data)["services"][0]["fields"]["holdEnd"]
            self.assertNotIn("value", field)
    def test_inspection_does_not_enable_timer_writes(self):
        state = helper.parse_accessories(accessories())
        for key in ("holdEnd", "setHoldSchedule", "setDuration"):
            with self.assertRaises(ValueError):
                helper.validate_writes(state, "1.10", {key: 900})

class CommandTests(unittest.IsolatedAsyncioTestCase):
    async def test_deadline_trial_checks_readback_and_issues_one_write(self):
        data, end = native_fan_hold(datetime.now(timezone.utc).replace(microsecond=0))
        class Pairing:
            calls = 0
            async def list_accessories_and_characteristics(self): return data
            async def put_characteristics(self, writes):
                self.calls += 1
                self.writes = writes
                data[0]["services"][1]["characteristics"][-1]["value"] = writes[0][2] + "+00:00Q"
                return {}
        bridge = helper.Bridge(); bridge.controller = object(); bridge.pairing = Pairing()
        result = await bridge.command({"command": "test_fan_deadline", "expectedEnd": end})
        self.assertTrue(result["deadlineConfirmed"])
        self.assertTrue(result["climateUnchanged"])
        self.assertEqual(bridge.pairing.calls, 1)
        self.assertEqual(len(bridge.pairing.writes), 1)
        self.assertEqual(bridge.pairing.writes[0][:2], (1, 36))
    async def test_accepted_but_ignored_deadline_is_not_confirmed(self):
        data, end = native_fan_hold(datetime.now(timezone.utc).replace(microsecond=0))
        class Pairing:
            async def list_accessories_and_characteristics(self): return data
            async def put_characteristics(self, writes): return {}
        bridge = helper.Bridge(); bridge.controller = object(); bridge.pairing = Pairing()
        result = await bridge.command({"command": "test_fan_deadline", "expectedEnd": end})
        self.assertFalse(result["deadlineConfirmed"])
        self.assertTrue(result["climateUnchanged"])
    async def test_deadline_read_failure_does_not_claim_verified_timer(self):
        data, end = native_fan_hold(datetime.now(timezone.utc).replace(microsecond=0))
        class Pairing:
            reads = 0
            async def list_accessories_and_characteristics(self):
                self.reads += 1
                if self.reads > 1: raise TimeoutError()
                return data
            async def put_characteristics(self, writes): return {}
        bridge = helper.Bridge(); bridge.controller = object(); bridge.pairing = Pairing()
        result = await bridge.command({"command": "test_fan_deadline", "expectedEnd": end})
        self.assertFalse(result["deadlineConfirmed"])
        self.assertFalse(result["climateUnchanged"])
    async def test_deadline_trial_does_not_retry_uncertain_write(self):
        data, end = native_fan_hold(datetime.now(timezone.utc).replace(microsecond=0))
        class Pairing:
            calls = 0
            async def list_accessories_and_characteristics(self): return data
            async def put_characteristics(self, writes):
                self.calls += 1
                raise TimeoutError()
        bridge = helper.Bridge(); bridge.controller = object(); bridge.pairing = Pairing()
        with self.assertRaises(TimeoutError):
            await bridge.command({"command": "test_fan_deadline", "expectedEnd": end})
        self.assertEqual(bridge.pairing.calls, 1)
    async def test_timer_inspection_only_reads_accessories(self):
        class Pairing:
            reads = 0
            async def list_accessories_and_characteristics(self):
                self.reads += 1
                return accessories()
            async def put_characteristics(self, writes):
                raise AssertionError("Inspection must never write to the thermostat")
        bridge = helper.Bridge(); bridge.controller = object(); bridge.pairing = Pairing()
        result = await bridge.command({"command": "inspect_fan_timer"})
        self.assertIn("diagnostics", result)
        self.assertEqual(bridge.pairing.reads, 1)
    async def test_rejected_write_is_not_retried(self):
        class Pairing:
            calls = 0
            async def list_accessories_and_characteristics(self): return accessories()
            async def put_characteristics(self, writes):
                self.calls += 1
                return {(1, 14): {"status": -70410}}
        bridge = helper.Bridge(); bridge.controller = object(); bridge.pairing = Pairing()
        with self.assertRaises(ValueError): await bridge.command({"command": "write", "thermostatID": "1.10", "changes": {"target": 23}})
        self.assertEqual(bridge.pairing.calls, 1)
    async def test_post_write_read_failure_reports_accepted_not_failed(self):
        class Pairing:
            reads = 0
            async def list_accessories_and_characteristics(self):
                self.reads += 1
                if self.reads > 1: raise TimeoutError()
                return accessories()
            async def put_characteristics(self, writes): return {}
        bridge = helper.Bridge(); bridge.controller = object(); bridge.pairing = Pairing()
        result = await bridge.command({"command": "write", "thermostatID": "1.10", "changes": {"target": 23}})
        self.assertIn("accepted", result["warning"])
    async def test_pairing_keys_returned_before_optional_read(self):
        class Pairing:
            pairing_data = {"Connection": "IP", "test_key": "private"}
        bridge = helper.Bridge(); bridge.controller = object(); bridge.pair_deadline = math.inf
        async def finish(pin):
            self.assertEqual(pin, "123-45-678")
            return Pairing()
        bridge.finish_pairing = finish
        result = await bridge.command({"command": "finish_pairing", "pin": "12345678"})
        self.assertEqual(result["pairing"], Pairing.pairing_data)

if __name__ == "__main__": unittest.main()
