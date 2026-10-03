"""Packaging unit tests mock signing/disk-image tools; these do not certify a real release."""
from pathlib import Path
import hashlib
import os
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

class LicenseTests(unittest.TestCase):
    def test_collects_notices_metadata_and_python_license_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);source=root/'package';source.mkdir()
            (source/'LICENSE').write_text('Package license fixture')
            (source/'secret.pem').write_text('MUST_NOT_BE_COPIED')
            python_license=root/'lib'/f'python{sys.version_info.major}.{sys.version_info.minor}'/'LICENSE.txt'
            python_license.parent.mkdir(parents=True);python_license.write_text('Python license fixture')
            class Distribution:
                metadata={'Name':'fixture-package'};version='1.2.3';files=['LICENSE','secret.pem','missing-NOTICE']
                def read_text(self,name):return 'fixture metadata' if name=='METADATA' else None
                def locate_file(self,file):return source/file
            output=root/'notices'
            with patch('importlib.metadata.distributions',return_value=[Distribution()]),patch.object(sys,'base_prefix',str(root)),patch.object(sys,'argv',['licenses.py',str(output)]):
                runpy.run_path(str(ROOT/'scripts/licenses.py'),run_name='__main__')
            self.assertEqual((output/'fixture-package/LICENSE').read_text(),'Package license fixture')
            self.assertIn('1.2.3',(output/'fixture-package/PACKAGE.txt').read_text())
            self.assertEqual((output/'Python-LICENSE.txt').read_text(),'Python license fixture')
            self.assertFalse((output/'fixture-package/secret.pem').exists())

class DMGScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.app=self.root/'Ecobee Local.app';(self.app/'Contents').mkdir(parents=True)
        self.info=self.app/'Contents/Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'26.0'}))
        self.tools=self.root/'tools';self.tools.mkdir()
        signing=self.tools/'codesign';signing.write_text('#!/bin/sh\nexit "${TEST_SIGN_EXIT:-0}"\n');signing.chmod(0o755)
        disk=self.tools/'hdiutil'
        disk.write_text(f'#!{sys.executable}\n'+'''import os,sys
from pathlib import Path
if sys.argv[1]=='create':
    stage=Path(sys.argv[sys.argv.index('-srcfolder')+1])
    assert (stage/'Ecobee Local.app/Contents/Info.plist').is_file()
    assert os.readlink(stage/'Applications')=='/Applications'
    text=(stage/'Install.txt').read_text()
    assert 'not an Apple-notarized' in text and 'macOS 26.0' in text
    Path(sys.argv[-1]).write_bytes(b'unit-test disk image fixture')
if sys.argv[1]=='verify':sys.exit(int(os.environ.get('TEST_VERIFY_EXIT','0')))
''');disk.chmod(0o755)
        self.output=self.root/'release.dmg'
        self.env=dict(os.environ,PATH=str(self.tools)+os.pathsep+os.environ['PATH'],ECOBEE_DMG_APP=str(self.app),ECOBEE_DMG_OUTPUT=str(self.output),TMPDIR=str(self.root))
    def run_script(self):
        return subprocess.run(['bash',str(ROOT/'scripts/build-dmg.sh')],env=self.env,text=True,capture_output=True,timeout=20)
    def test_packages_verified_app_and_writes_matching_checksum(self):
        result=self.run_script();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(Path(str(self.output)+'.sha256').read_text().split()[0],hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertFalse(list(self.root.glob('ecobee-dmg.*')),'Staging directory must be cleaned')
    def test_existing_release_is_never_overwritten(self):
        self.output.write_bytes(b'existing release')
        self.assertNotEqual(self.run_script().returncode,0)
        self.assertEqual(self.output.read_bytes(),b'existing release')
    def test_existing_checksum_is_never_overwritten(self):
        checksum=Path(str(self.output)+'.sha256');checksum.write_text('existing')
        self.assertNotEqual(self.run_script().returncode,0);self.assertEqual(checksum.read_text(),'existing')
    def test_missing_app_and_bad_version_are_rejected(self):
        self.env['ECOBEE_DMG_APP']=str(self.root/'missing.app')
        self.assertNotEqual(self.run_script().returncode,0)
        self.env['ECOBEE_DMG_APP']=str(self.app)
        self.info.write_bytes(plistlib.dumps({'CFBundleShortVersionString':'../../invalid','LSMinimumSystemVersion':'26.0'}))
        self.assertNotEqual(self.run_script().returncode,0)
    def test_signature_and_image_verification_failures_stop_packaging(self):
        self.env['TEST_SIGN_EXIT']='1'
        self.assertNotEqual(self.run_script().returncode,0);self.assertFalse(self.output.exists())
        self.env['TEST_SIGN_EXIT']='0';self.env['TEST_VERIFY_EXIT']='1'
        self.assertNotEqual(self.run_script().returncode,0)
        self.assertFalse(Path(str(self.output)+'.sha256').exists())
        self.assertFalse(list(self.root.glob('ecobee-dmg.*')))
