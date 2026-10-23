from pathlib import Path
import importlib.util
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ci',ROOT/'scripts/run-android-ci.py')
ci=importlib.util.module_from_spec(spec);spec.loader.exec_module(ci)

class ReadinessTests(unittest.TestCase):
    def invoke(self, execute, stopped=False, timeout=10):
        ticks=iter(range(1000))
        emulator=SimpleNamespace(poll=lambda:1 if stopped else None)
        with patch.object(ci.subprocess,'run',side_effect=execute),patch.object(ci.time,'sleep'),patch.object(ci.time,'monotonic',side_effect=lambda:next(ticks)):
            ci.wait_for_services(['adb','-s','emulator-5554'],emulator,timeout=timeout)
    def test_waits_for_binder_service_after_boot_completed(self):
        calls=[]
        def run(command,**kwargs):
            calls.append(command)
            pending=len(calls)<=3
            return SimpleNamespace(returncode=0,stdout='Service: not found' if pending else 'Service: found')
        self.invoke(run)
        self.assertEqual(len(calls),9)
        self.assertNotIn('svc',calls[2])
    def test_retries_failed_disable_command(self):
        calls=[]
        def run(command,**kwargs):
            calls.append(command)
            return SimpleNamespace(returncode=20 if len(calls)==6 else 0,stdout='Service: found')
        self.invoke(run)
        self.assertEqual(len(calls),12)
    def test_does_not_mask_permanently_missing_service(self):
        with self.assertRaisesRegex(RuntimeError,'deadline'):
            self.invoke(lambda *a,**kw:SimpleNamespace(returncode=0,stdout='Service: not found'),timeout=3)
    def test_stopped_emulator_fails_immediately(self):
        with self.assertRaisesRegex(RuntimeError,'stopped'):
            self.invoke(lambda *a,**kw:self.fail('Do not call adb after emulator exit'),stopped=True)
