from pathlib import Path
import hashlib
import importlib.util
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('release_audit',ROOT/'scripts/audit-android-release.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)

class ReleasePolicyTests(unittest.TestCase):
    def archive(self,changed=None,removed=()):
        data={'assets/flutter_assets/assets/ggml-base.bin':b'model','lib/arm64-v8a/libindex_probe.so':b'native','classes.dex':b'no injection','assets/flutter_assets/NOTICES.Z':b'notice'}
        for file in ['IndexRelay-MIT.txt','whisper.cpp-MIT.txt','Whisper-model-MIT.txt','Android-Apache-2.0.txt','Android-NOTICE.txt']: data['assets/flutter_assets/assets/notices/'+file]=b'license'
        data.update(changed or {})
        for name in removed: data.pop(name)
        temp=tempfile.NamedTemporaryFile(suffix='.apk',delete=False);temp.close();path=Path(temp.name);self.addCleanup(path.unlink)
        with zipfile.ZipFile(path,'w') as z:
            for name,content in data.items():z.writestr(name,content)
        return path
    def inspect(self,path):
        with patch.dict(audit.LOCK['whisper'],{'model_bytes':5,'model_sha256':hashlib.sha256(b'model').hexdigest()}):return audit.inspect_zip(path)
    def test_valid_minimal_review_asset_set(self):self.assertTrue(self.inspect(self.archive())['trialAssetsAbsent'])
    def test_no_speech_or_golden_in_distribution(self):
        for name in ['assets/flutter_assets/assets/japanese.wav','assets/flutter_assets/assets/audio-golden.json','res/xml/debug_network_security_config.xml']:
            with self.assertRaises(ValueError):self.inspect(self.archive({name:b'test'}))
    def test_injection_class_rejected(self):
        with self.assertRaises(ValueError):self.inspect(self.archive({'classes.dex':b'Ldev/example/DeliveryHarness;'}))
    def test_model_hash_and_size_are_verified(self):
        with self.assertRaises(ValueError):self.inspect(self.archive({'assets/flutter_assets/assets/ggml-base.bin':b'other'}))
    def test_all_notices_required(self):
        with self.assertRaises(ValueError):self.inspect(self.archive(removed=['assets/flutter_assets/assets/notices/Whisper-model-MIT.txt']))
    def test_wrong_abi_rejected(self):
        with self.assertRaises(ValueError):self.inspect(self.archive({'lib/x86_64/libindex_probe.so':b'x86'}))
    def test_identity_and_example_signing_policy(self):
        audit.validate_identity('dev.example.review',True)
        for value,unsigned in [('dev.example.review',False),('com.example.review',False),('onlyone',True),('a.b;command',True)]:
            with self.assertRaises(ValueError):audit.validate_identity(value,unsigned)
        audit.validate_identity('test.indexrelay.release',False)

    def test_cleanup_refuses_local_and_self_hosted_environments(self):
        spec=importlib.util.spec_from_file_location('prune',ROOT/'scripts/ci-prune-tools.py')
        prune=importlib.util.module_from_spec(spec);spec.loader.exec_module(prune)
        for env in [{},{'GITHUB_ACTIONS':'true','RUNNER_OS':'Linux','RUNNER_ENVIRONMENT':'self-hosted'}]:
            with self.assertRaises(RuntimeError):prune.require_hosted_runner(env)
