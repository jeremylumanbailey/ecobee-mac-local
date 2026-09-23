"""Private JSON-lines IPC helper. Credentials only travel over inherited pipes.

IP HomeKit only: no cloud endpoints, listening web server, Bluetooth, or credential files.
"""
import asyncio
import json
import logging
import math
import re
import sys
import time

BASE = "-0000-1000-8000-0026BB765291"
def uuid(short):
    return short.upper().zfill(8) + BASE if len(short) <= 8 else short.upper()

TYPES = {"current": "11", "humidity": "10", "mode": "33", "state": "0F",
         "fanState": "AF",  # Current operation, distinct from the requested fan mode.
         "target": "35", "heat": "12", "cool": "0D",
         "fan": "C35DA3C0-E004-40E3-B153-46655CDD9214",
         "resume": "FA128DE6-9D7D-49A4-B6D8-4E4E234DEE38"}
WRITABLE = {"mode", "target", "heat", "cool", "fan", "resume"}

def by_type(service, kind):
    return next((c for c in service.get("characteristics", []) if uuid(c["type"]) == uuid(kind)), None)

def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

def parse_accessories(accessories):
    thermostats, sensors = [], []
    model, firmware, root_name = "Ecobee", "Unknown", "My thermostat"
    for accessory in accessories:
        aid = accessory["aid"]
        info = next((s for s in accessory.get("services", []) if uuid(s["type"]) == uuid("3E")), {})
        def info_value(kind, default):
            return (by_type(info, kind) or {}).get("value", default)
        name = info_value("23", f"Accessory {aid}")
        for service in accessory.get("services", []):
            if uuid(service["type"]) == uuid("4A"):
                model = info_value("21", model)
                firmware = info_value("52", firmware)
                root_name = name
                item = {"id": f"{aid}.{service['iid']}", "name": name, "fields": {}}
                for field, kind in TYPES.items():
                    char = by_type(service, kind)
                    if not char:
                        continue
                    # Error-valued characteristics must never masquerade as fresh readings.
                    if char.get("status", 0) != 0:
                        continue
                    value = char.get("value")
                    if numeric(value):
                        item[field] = value
                    if field in WRITABLE and "pw" in char.get("perms", []):
                        meta = {"aid": aid, "iid": char["iid"], "format": char.get("format", "float")}
                        for src, dst in [("minValue", "minimum"), ("maxValue", "maximum"), ("minStep", "step"), ("valid-values", "validValues")]:
                            if src in char:
                                meta[dst] = char[src]
                        item["fields"][field] = meta
                thermostats.append(item)
            elif uuid(service["type"]) in {uuid("8A"), uuid("86")}:
                temperature = (by_type(service, "11") or {}).get("value")
                occupancy = (by_type(service, "71") or {}).get("value")
                sensor = next((s for s in sensors if s["id"] == str(aid)), None)
                if sensor is None:
                    sensor = {"id": str(aid), "name": name}
                    sensors.append(sensor)
                if numeric(temperature):
                    sensor["temperature"] = temperature
                if occupancy in (0, 1):
                    sensor["occupied"] = bool(occupancy)
    return {"name": root_name, "model": model, "firmware": firmware, "thermostats": thermostats, "sensors": sensors}

def validate_writes(snapshot, thermostat_id, changes):
    """Resolve addresses from a fresh accessory inventory, never trust client-provided IIDs."""
    thermostat = next((t for t in snapshot["thermostats"] if t["id"] == thermostat_id), None)
    if thermostat is None:
        raise ValueError("The selected thermostat is no longer available. Refresh and retry.")
    if not isinstance(changes, dict) or not changes or set(changes) - WRITABLE:
        raise ValueError("Unsupported thermostat command.")
    if "resume" in changes and len(changes) != 1:
        raise ValueError("Resume schedule must be sent separately.")
    writes = []
    for field, value in changes.items():
        metadata = thermostat["fields"].get(field)
        if metadata is None:
            raise ValueError(f"The thermostat does not expose a writable {field} control.")
        if field == "resume":
            if value is not True:
                raise ValueError("Invalid resume command.")
        else:
            if not numeric(value):
                raise ValueError("A control value must be a finite number.")
            if field == "mode" and value not in [0, 1, 2, 3]:
                raise ValueError("Unsupported heating/cooling mode.")
            if field == "fan" and value not in [0, 100]:
                raise ValueError("Fan must be auto or on.")
            if field in {"target", "heat", "cool"} and not 4 <= value <= 35:
                raise ValueError("Choose a temperature between 4°C and 35°C.")
            if "minimum" in metadata and value < metadata["minimum"] - 1e-6:
                raise ValueError("The temperature is below the thermostat’s allowed range.")
            if "maximum" in metadata and value > metadata["maximum"] + 1e-6:
                raise ValueError("The temperature is above the thermostat’s allowed range.")
            if metadata.get("validValues") and value not in metadata["validValues"]:
                raise ValueError("That setting is not supported by the thermostat.")
            step = metadata.get("step", 0)
            if step and abs((value - metadata.get("minimum", 0)) / step - round((value - metadata.get("minimum", 0)) / step)) > 1e-5:
                raise ValueError("That temperature does not match the thermostat’s supported increments.")
            if metadata.get("format") in {"uint8", "uint16", "uint32", "int"}:
                if value != int(value):
                    raise ValueError("This control requires a whole number.")
                value = int(value)
        writes.append((metadata["aid"], metadata["iid"], value))
    if "heat" in changes or "cool" in changes:
        heat, cool = changes.get("heat", thermostat.get("heat")), changes.get("cool", thermostat.get("cool"))
        if not numeric(heat) or not numeric(cool) or heat >= cool:
            raise ValueError("The heating target must be below the cooling target.")
    return writes

class Bridge:
    def __init__(self):
        self.zc = self.browser = self.controller = self.pairing = None
        self.finish_pairing = None
        self.pair_deadline = 0

    async def start(self):
        if self.controller:
            return
        from zeroconf.asyncio import AsyncZeroconf, AsyncServiceBrowser
        from aiohomekit.controller.ip.controller import IpController
        from aiohomekit.characteristic_cache import CharacteristicCacheMemory
        self.zc = AsyncZeroconf()
        self.browser = AsyncServiceBrowser(self.zc.zeroconf, "_hap._tcp.local.", handlers=[lambda **kwargs: None])
        self.controller = IpController(CharacteristicCacheMemory(), self.zc)
        await self.controller.async_start()

    async def snapshot(self):
        if self.pairing is None:
            raise ValueError("Pair with a thermostat first.")
        return parse_accessories(await self.pairing.list_accessories_and_characteristics())

    async def command(self, request):
        command = request.get("command")
        if command == "hello":
            return {"version": 1, "transport": "HomeKit over local Wi-Fi"}
        await self.start()
        if command == "discover":
            await asyncio.sleep(6)
            devices = []
            async for discovery in self.controller.async_discover():
                d = discovery.description
                if int(d.category) != 9 and "ecobee" not in (d.name + d.model).lower():
                    continue
                devices.append({"id": d.id, "name": d.name, "model": d.model,
                                "address": d.address, "available": bool(int(d.status_flags) & 1)})
            return {"devices": devices}
        if command == "start_pairing":
            if endpoint := request.get("endpoint"):
                from aiohomekit.zeroconf import HomeKitService
                from aiohomekit.controller.ip.discovery import IpDiscovery
                from aiohomekit.model.feature_flags import FeatureFlags
                from aiohomekit.model.status_flags import StatusFlags
                from aiohomekit.model.categories import Categories
                if endpoint["id"].lower() != request["deviceID"].lower():
                    raise ValueError("The discovery identity changed. Search again.")
                description = HomeKitService(name=endpoint["name"], id=endpoint["id"], model=endpoint["model"],
                    feature_flags=FeatureFlags(endpoint["featureFlags"]), status_flags=StatusFlags(endpoint["statusFlags"]),
                    config_num=endpoint["configNumber"], state_num=1, category=Categories(9), protocol_version="1.1",
                    type="_hap._tcp.local.", address=endpoint["address"], addresses=[endpoint["address"]], port=endpoint["port"])
                discovery = IpDiscovery(self.controller, description)
            else:
                discovery = await self.controller.async_find(request["deviceID"], timeout=10)
            if not int(discovery.description.status_flags) & 1:
                raise ValueError("This thermostat is already paired to a HomeKit controller.")
            self.finish_pairing = await discovery.async_start_pairing("thermostat")
            self.pair_deadline = time.monotonic() + 180
            return {"ready": True}
        if command == "finish_pairing":
            if not self.finish_pairing or time.monotonic() > self.pair_deadline:
                raise ValueError("The pairing session expired. Select the thermostat and start again.")
            pin = re.sub(r"[- ]", "", request.get("pin", ""))
            if not re.fullmatch(r"\d{8}", pin):
                raise ValueError("Enter the eight-digit code shown on the thermostat.")
            finish, self.finish_pairing = self.finish_pairing, None
            self.pairing = await finish(f"{pin[:3]}-{pin[3:5]}-{pin[5:]}")
            # Return keys immediately, before any optional reads can fail. Swift saves to Keychain.
            return {"pairing": self.pairing.pairing_data}
        if command == "connect":
            if self.pairing:
                await self.pairing.close()
            data = request.get("pairing")
            if not isinstance(data, dict) or data.get("Connection") != "IP":
                raise ValueError("The saved pairing is not a local IP pairing.")
            if endpoint := request.get("endpoint"):
                if endpoint["id"].lower() != data["AccessoryPairingID"].lower():
                    raise ValueError("Discovery returned a different thermostat.")
                data = dict(data, AccessoryIP=endpoint["address"], AccessoryIPs=[endpoint["address"]], AccessoryPort=endpoint["port"])
            self.pairing = self.controller.load_pairing("thermostat", data)
            if self.pairing is None:
                raise ValueError("The saved pairing could not be loaded.")
            return {"snapshot": await self.snapshot()}
        if command == "refresh":
            return {"snapshot": await self.snapshot()}
        if command == "write":
            snapshot = await self.snapshot()
            writes = validate_writes(snapshot, request.get("thermostatID"), request.get("changes"))
            results = await self.pairing.put_characteristics(writes)
            if any(r.get("status", 0) != 0 for r in results.values()):
                raise ValueError("The thermostat rejected one or more changes. Refresh to check its current settings; some changes may have applied.")
            try:
                return {"snapshot": await self.snapshot()}
            except Exception:
                return {"warning": "The command was accepted, but updated readings are unavailable. Refresh to confirm the current settings."}
        if command == "unpair":
            if self.pairing is None:
                raise ValueError("Reconnect before removing the pairing.")
            result = await self.pairing.remove_pairing(self.pairing.pairing_data["iOSPairingId"])
            if result is not True:
                raise ValueError("The thermostat did not confirm that pairing was removed.")
            await self.pairing.close()
            self.pairing = None
            return {"removed": True}
        raise ValueError("Unknown command.")

    async def close(self):
        if self.pairing:
            await self.pairing.close()
        if self.controller:
            await self.controller.async_stop()
        if self.browser:
            await self.browser.async_cancel()
        if self.zc:
            await self.zc.async_close()

def safe_error(error, command):
    if isinstance(error, ValueError):
        return str(error)
    name = type(error).__name__
    if name in {"AuthenticationError", "InvalidSignatureError", "UnpairedError"}:
        return "Pairing was not accepted. Check the code, or whether HomeKit pairing was reset on the thermostat."
    if name in {"MaxTriesError", "BackoffError", "BusyError"}:
        return "The thermostat asked us to wait. Close its pairing screen, wait a minute, then try again."
    if isinstance(error, (TimeoutError, OSError)) or "Connection" in name or "NotFound" in name:
        message = "The thermostat could not be reached. Check the same local network and macOS Local Network permission."
    else:
        message = f"Local connection failed ({name}). Retry discovery or reconnect."
    if command == "write":
        message += " A change may have reached the thermostat. Refresh before trying again."
    return message

async def main():
    logging.basicConfig(level=logging.CRITICAL, stream=sys.stderr)
    bridge = Bridge()
    try:
        while line := await asyncio.to_thread(sys.stdin.readline):
            request_id, command = None, None
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError("Invalid request.")
                request_id, command = request.get("id"), request.get("command")
                result = await asyncio.wait_for(bridge.command(request), timeout=40)
                response = {"id": request_id, "ok": True, "result": result}
            except Exception as error:
                response = {"id": request_id, "ok": False, "error": safe_error(error, command)}
            print(json.dumps(response, allow_nan=False), flush=True)
    finally:
        await bridge.close()

if __name__ == "__main__":
    asyncio.run(main())
