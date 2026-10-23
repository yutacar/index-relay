from pathlib import Path
import importlib.util
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('compatibility', ROOT / 'scripts/test-android-compatibility.py')
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)


class SyntheticAudioTests(unittest.TestCase):
    def test_repeated_fixture_preserves_exact_five_minute_limit(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.wav'
            result = Path(folder) / 'result.wav'
            with wave.open(str(source), 'wb') as f:
                f.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                f.writeframes(b'\x01\x00\xff\xff' * 8000)
            compatibility.synthetic(source, result, 300)
            with wave.open(str(result), 'rb') as f:
                self.assertEqual((f.getnframes(), f.getframerate()), (4_800_000, 16000))
                self.assertEqual(f.readframes(2), b'\x01\x00\xff\xff')

    def test_rejects_stereo_instead_of_silently_mismeasuring_duration(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.wav'
            with wave.open(str(source), 'wb') as f:
                f.setparams((2, 2, 16000, 0, 'NONE', 'not compressed'))
                f.writeframes(b'\0' * 64)
            with self.assertRaises(AssertionError):
                compatibility.synthetic(source, Path(folder) / 'result.wav', 15)
