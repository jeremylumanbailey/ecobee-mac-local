import asyncio
import contextlib
import copy
import io
import json
import sys
import time
import types
import unittest
from datetime import datetime, timezone
from unittest.mock import AsyncMock, Mock, patch
from test_helper import helper, accessories, characteristic, native_fan_hold

class InventoryTests(unittest.TestCase):
    def test_empty_inventory_uses_honest_defaults(self):
        result = helper.parse_accessories([])
        self.assertEqual(result['thermostats'], [])
        self.assertEqual(result['sensors'], [])
        self.assertEqual(result['firmware'], 'Unknown')

    def test_merges_temperature_and_occupancy_services_per_accessory(self):
        data = [{'aid': 2, 'services': [
            {'iid': 1, 'type': '8A', 'characteristics': [characteristic(2, '11', 21.5)]},
            {'iid': 3, 'type': '86', 'characteristics': [characteristic(4, '71', 1)]}]}]
        self.assertEqual(helper.parse_accessories(data)['sensors'], [
            {'id': '2', 'name': 'Accessory 2', 'temperature': 21.5, 'occupied': True}])

    def test_sensor_error_status_does_not_look_like_fresh_reading(self):
        data = [{'aid': 2, 'services': [{'iid': 1, 'type': '8A', 'characteristics': [
            characteristic(2, '11', 21.5, status=-70402), characteristic(3, '71', 1, status=-70402)]}]}]
        sensor = helper.parse_accessories(data)['sensors'][0]
        self.assertNotIn('temperature', sensor)
        self.assertNotIn('occupied', sensor)

    def test_nonfinite_sensor_values_are_ignored(self):
        data = [{'aid': 2, 'services': [{'iid': 1, 'type': '8A', 'characteristics': [
            characteristic(2, '11', float('nan')), characteristic(3, '71', 9)]}]}]
        self.assertEqual(set(helper.parse_accessories(data)['sensors'][0]), {'id', 'name'})

    def test_invalid_command_shapes_and_modes(self):
        state = helper.parse_accessories(accessories())
        for changes in (None, [], {}, {'unknown': 1}, {'mode': -1}, {'target': 36}, {'target': 3}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                helper.validate_writes(state, '1.10', changes)

    def test_integer_control_cannot_truncate_fraction(self):
        state = helper.parse_accessories(accessories())
        state['thermostats'][0]['fields']['target'].update(format='int', step=0)
        with self.assertRaises(ValueError): helper.validate_writes(state, '1.10', {'target': 22.5})
        self.assertEqual(helper.validate_writes(state, '1.10', {'target': 22}), [(1, 14, 22)])

    def test_missing_threshold_reading_blocks_partial_update(self):
        state = helper.parse_accessories(accessories()); state['thermostats'][0].pop('cool')
        with self.assertRaises(ValueError): helper.validate_writes(state, '1.10', {'heat': 20})

    def test_error_categories_and_secret_redaction(self):
        for name, expected in [('AuthenticationError', 'Pairing'), ('InvalidSignatureError', 'Pairing'),
                               ('UnpairedError', 'Pairing'), ('BackoffError', 'wait'), ('BusyError', 'wait'),
                               ('MaxTriesError', 'wait'), ('ConnectionFailure', 'reached'), ('NotFound', 'reached')]:
            error = type(name, (Exception,), {})('PRIVATE_FIXTURE')
            message = helper.safe_error(error, 'connect')
            self.assertIn(expected, message); self.assertNotIn('PRIVATE_FIXTURE', message)
        self.assertIn('may have reached', helper.safe_error(OSError('PRIVATE_FIXTURE'), 'test_fan_deadline'))
        self.assertEqual(helper.safe_error(ValueError('Invalid input'), 'write'), 'Invalid input')

class BridgeTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.bridge = helper.Bridge()
        self.bridge.controller = Mock()
        self.pairing = Mock()
        self.pairing.list_accessories_and_characteristics = AsyncMock(return_value=accessories())
        self.pairing.put_characteristics = AsyncMock(return_value={})
        self.pairing.close = AsyncMock()
        self.pairing.remove_pairing = AsyncMock(return_value=True)
        self.pairing.pairing_data = {'iOSPairingId': 'synthetic-controller'}

    async def test_hello_does_not_start_network(self):
        self.bridge.start = AsyncMock(side_effect=AssertionError('No network for hello'))
        self.assertEqual((await self.bridge.command({'command':'hello'}))['version'], 1)

    async def test_start_initializes_dependencies_once(self):
        bridge = helper.Bridge()
        zc = Mock(); zc.async_close = AsyncMock()
        browser = Mock(); browser.async_cancel = AsyncMock()
        controller = Mock(); controller.async_start = AsyncMock(); controller.async_stop = AsyncMock()
        modules = {
            'zeroconf.asyncio': types.SimpleNamespace(AsyncZeroconf=Mock(return_value=zc), AsyncServiceBrowser=Mock(return_value=browser)),
            'aiohomekit.controller.ip.controller': types.SimpleNamespace(IpController=Mock(return_value=controller)),
            'aiohomekit.characteristic_cache': types.SimpleNamespace(CharacteristicCacheMemory=Mock()),
        }
        with patch.dict(sys.modules, modules):
            await bridge.start(); await bridge.start()
        controller.async_start.assert_awaited_once()
        await bridge.close()
        controller.async_stop.assert_awaited_once(); browser.async_cancel.assert_awaited_once(); zc.async_close.assert_awaited_once()

    async def test_discovery_filters_unrelated_accessories(self):
        def device(name, category):
            return types.SimpleNamespace(description=types.SimpleNamespace(id=name, name=name, model=name, category=category, address='192.0.2.1', status_flags=1))
        async def discover():
            for d in [device('lamp',5), device('thermostat',9), device('ecobee sensor',1)]: yield d
        self.bridge.controller.async_discover = discover
        with patch.object(helper.asyncio, 'sleep', AsyncMock()):
            result = await self.bridge.command({'command':'discover'})
        self.assertEqual([d['name'] for d in result['devices']], ['thermostat','ecobee sensor'])

    async def test_pairing_via_discovery_and_endpoint(self):
        discovery = Mock(); discovery.description.status_flags = 1
        discovery.async_start_pairing = AsyncMock(return_value=AsyncMock(return_value=self.pairing))
        self.bridge.controller.async_find = AsyncMock(return_value=discovery)
        self.assertEqual(await self.bridge.command({'command':'start_pairing','deviceID':'fixture'}), {'ready': True})
        endpoint = dict(id='fixture',name='Fixture',model='ECB701',address='192.0.2.1',port=1234,featureFlags=0,statusFlags=1,configNumber=1)
        with patch('aiohomekit.controller.ip.discovery.IpDiscovery', return_value=discovery):
            self.assertEqual(await self.bridge.command({'command':'start_pairing','deviceID':'fixture','endpoint':endpoint}), {'ready': True})
        self.assertGreater(self.bridge.pair_deadline, time.monotonic())

    async def test_pairing_rejects_mismatched_endpoint(self):
        with self.assertRaises(ValueError):
            await self.bridge.command({'command':'start_pairing','deviceID':'wanted','endpoint':{'id':'other'}})

    async def test_pairing_rejects_already_paired_device(self):
        discovery = Mock(); discovery.description.status_flags = 0
        self.bridge.controller.async_find = AsyncMock(return_value=discovery)
        with self.assertRaises(ValueError): await self.bridge.command({'command':'start_pairing','deviceID':'fixture'})

    async def test_expired_and_invalid_pairing_codes(self):
        self.bridge.finish_pairing = AsyncMock(return_value=self.pairing)
        self.bridge.pair_deadline = time.monotonic()-1
        with self.assertRaises(ValueError): await self.bridge.command({'command':'finish_pairing','pin':'12345678'})
        self.bridge.pair_deadline = time.monotonic()+100
        for pin in ['abc', '123', '', '123456789']:
            with self.subTest(pin=pin), self.assertRaises(ValueError): await self.bridge.command({'command':'finish_pairing','pin':pin})
        self.bridge.finish_pairing.assert_not_awaited()

    async def test_connect_updates_endpoint_without_mutating_saved_keys(self):
        self.bridge.pairing = self.pairing
        self.bridge.controller.load_pairing.return_value = self.pairing
        data = {'Connection':'IP','AccessoryPairingID':'fixture','AccessoryIP':'192.0.2.2'}
        result = await self.bridge.command({'command':'connect','pairing':data,'endpoint':{'id':'FIXTURE','address':'192.0.2.1','port':1234}})
        self.assertIn('snapshot',result); self.pairing.close.assert_awaited_once()
        loaded = self.bridge.controller.load_pairing.call_args.args[1]
        self.assertEqual(loaded['AccessoryIP'],'192.0.2.1'); self.assertEqual(data['AccessoryIP'],'192.0.2.2')

    async def test_connect_rejects_wrong_transport_and_identity(self):
        for data in [None, [], {'Connection':'BLE'}]:
            with self.subTest(data=data), self.assertRaises(ValueError): await self.bridge.command({'command':'connect','pairing':data})
        with self.assertRaises(ValueError):
            await self.bridge.command({'command':'connect','pairing':{'Connection':'IP','AccessoryPairingID':'wanted'},'endpoint':{'id':'other'}})
        self.bridge.controller.load_pairing.return_value = None
        with self.assertRaises(ValueError): await self.bridge.command({'command':'connect','pairing':{'Connection':'IP'}})

    async def test_unpaired_commands_are_rejected(self):
        for command in ['refresh','inspect_fan_timer','test_fan_deadline','unpair','unknown']:
            with self.subTest(command=command), self.assertRaises(ValueError): await self.bridge.command({'command':command})

    async def test_write_success_and_readback_warning(self):
        self.bridge.pairing = self.pairing
        result = await self.bridge.command({'command':'write','thermostatID':'1.10','changes':{'target':23}})
        self.assertIn('snapshot',result)
        self.pairing.put_characteristics.assert_awaited_once_with([(1,14,23)])
        self.pairing.list_accessories_and_characteristics.side_effect = [accessories(), TimeoutError()]
        self.assertIn('warning', await self.bridge.command({'command':'write','thermostatID':'1.10','changes':{'target':23}}))

    async def test_unpair_requires_confirmation_before_discarding_session(self):
        self.bridge.pairing = self.pairing
        self.pairing.remove_pairing.return_value = False
        with self.assertRaises(ValueError): await self.bridge.command({'command':'unpair'})
        self.assertIs(self.bridge.pairing,self.pairing)
        self.pairing.remove_pairing.return_value = True
        self.assertEqual(await self.bridge.command({'command':'unpair'}), {'removed':True})
        self.assertIsNone(self.bridge.pairing)

    async def test_close_releases_pairing_even_without_other_dependencies(self):
        self.bridge.controller = None; self.bridge.pairing = self.pairing
        await self.bridge.close(); self.pairing.close.assert_awaited_once()
        await helper.Bridge().close()

    async def test_deadline_rejection_and_changed_climate_are_not_success(self):
        data,end = native_fan_hold(datetime.now(timezone.utc))
        self.bridge.pairing = self.pairing
        self.pairing.list_accessories_and_characteristics.return_value = data
        self.pairing.put_characteristics.return_value = {(1,36):{'status':-1}}
        with self.assertRaises(ValueError): await self.bridge.command({'command':'test_fan_deadline','expectedEnd':end})
        changed = copy.deepcopy(data); changed[0]['services'][1]['characteristics'][2]['value'] = 1
        self.pairing.list_accessories_and_characteristics.side_effect = [data, changed]
        self.pairing.put_characteristics.return_value = {}
        with patch.object(helper.asyncio,'sleep',AsyncMock()):
            result = await self.bridge.command({'command':'test_fan_deadline','expectedEnd':end})
        self.assertFalse(result['climateUnchanged'])

class DeadlineBoundaries(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc); self.data,self.end = native_fan_hold(self.now)

    def test_multiple_services_are_rejected(self):
        self.data[0]['services'].append(copy.deepcopy(self.data[0]['services'][1]))
        with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data,self.end,self.now)

    def test_unwritable_deadline_and_unreadable_climate(self):
        chars = self.data[0]['services'][1]['characteristics']
        chars[-1]['perms'] = ['pr']
        with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data,self.end,self.now)
        chars[-1]['perms'] = ['pr','pw']; chars[3]['status'] = -1
        with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data,self.end,self.now)

    def test_bad_date_is_rejected(self):
        self.data[0]['services'][1]['characteristics'][-1]['value'] = '2026-99-99T10:00:00+00:00Q'
        with self.assertRaises(ValueError): helper.prepare_fan_deadline_trial(self.data,'2026-99-99T10:00:00+00:00Q',self.now)

class ProtocolLoopTests(unittest.IsolatedAsyncioTestCase):
    async def test_json_loop_reports_errors_and_always_closes(self):
        bridge = Mock(); bridge.command = AsyncMock(side_effect=[{'version':1},RuntimeError('PRIVATE_FIXTURE')]);bridge.close = AsyncMock()
        inputs = '\n'.join(['[]','not json',json.dumps({'id':'one','command':'hello'}),json.dumps({'id':'two','command':'refresh'})])+'\n'
        output = io.StringIO()
        with patch.object(helper,'Bridge',return_value=bridge),patch.object(helper.sys,'stdin',io.StringIO(inputs)),contextlib.redirect_stdout(output):
            await helper.main()
        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([m['ok'] for m in messages],[False,False,True,False])
        self.assertEqual(messages[2]['id'],'one')
        self.assertNotIn('PRIVATE_FIXTURE',output.getvalue());bridge.close.assert_awaited_once()
