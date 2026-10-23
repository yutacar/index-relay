import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('audit', Path(__file__).resolve().parents[2] / 'scripts/audit-ios-release.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Runner.app'
        self.app.mkdir()
        self.info = dict(CFBundleName='Index Relay', CFBundleDisplayName='Index Relay', CFBundleShortVersionString='0.12.1', CFBundleVersion='34')
        self.save()
    def save(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
    def test_clean_bundle(self):
        self.assertFalse(audit.inspect(self.app)['whisperModelIncluded'])
    def test_nested_model_rejected(self):
        model = self.app / 'Frameworks/App.framework/flutter_assets/assets/ggml-base.bin'
        model.parent.mkdir(parents=True)
        model.write_bytes(b'model')
        with self.assertRaises(ValueError): audit.inspect(self.app)
    def test_preview_fixture_rejected(self):
        (self.app / 'japanese.wav').write_bytes(b'fixture')
        with self.assertRaises(ValueError): audit.inspect(self.app)
    def test_probe_name_rejected(self):
        self.info['CFBundleName'] = 'index_relay_probe'; self.save()
        with self.assertRaises(ValueError): audit.inspect(self.app)
