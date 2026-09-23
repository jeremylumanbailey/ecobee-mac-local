import asyncio
import copy
import importlib.util
import math
from pathlib import Path
import unittest

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

class CommandTests(unittest.IsolatedAsyncioTestCase):
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
