import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('wrapper', ROOT / 'scripts/gradle_wrapper.py')
wrapper = importlib.util.module_from_spec(spec); spec.loader.exec_module(wrapper)


class WrapperTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / 'bridge'; self.root.mkdir()
        for name in ('gradlew', 'gradlew.bat'):
            shutil.copy2(ROOT / 'bridge' / name, self.root / name)
        shutil.copytree(ROOT / 'bridge/gradle/wrapper', self.root / 'gradle/wrapper')
        self.properties = self.root / 'gradle/wrapper/gradle-wrapper.properties'
        self.jar = self.root / 'gradle/wrapper/gradle-wrapper.jar'

    def test_reviewed_wrapper_is_accepted_without_network(self):
        wrapper.verify(self.root)

    def test_modified_jar_is_rejected(self):
        self.jar.write_bytes(self.jar.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'JAR checksum'): wrapper.verify(self.root)

    def test_missing_jar_is_rejected(self):
        self.jar.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing'): wrapper.verify(self.root)

    def test_symlinked_jar_is_rejected(self):
        other = self.root / 'other.jar'; self.jar.rename(other); self.jar.symlink_to(other)
        with self.assertRaisesRegex(ValueError, 'symlinked'): wrapper.verify(self.root)

    def test_changed_launchers_are_rejected(self):
        for name in ('gradlew', 'gradlew.bat'):
            path = self.root / name; before = path.read_bytes()
            path.write_bytes(before + b'\nchanged')
            with self.assertRaisesRegex(ValueError, 'launcher checksum'): wrapper.verify(self.root)
            path.write_bytes(before)

    def test_batch_launcher_line_endings_are_portable(self):
        path = self.root / 'gradlew.bat'; path.write_bytes(path.read_bytes().replace(b'\r\n', b'\n'))
        wrapper.verify(self.root)

    def test_non_executable_unix_launcher_is_rejected(self):
        (self.root / 'gradlew').chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'not executable'): wrapper.verify(self.root)

    def test_distribution_url_and_sha_are_pinned(self):
        before = self.properties.read_text()
        for old, new in (('services.gradle.org', 'unreviewed.invalid'),
                         (wrapper.DISTRIBUTION_SHA256, '0' * 64), ('8.14.3-bin.zip', '8.14.4-bin.zip')):
            self.properties.write_text(before.replace(old, new))
            with self.assertRaisesRegex(ValueError, 'properties differ'): wrapper.verify(self.root)
        self.properties.write_text(before)

    def test_duplicate_property_is_rejected(self):
        self.properties.write_text(self.properties.read_text() + '\nnetworkTimeout=10000\n')
        with self.assertRaisesRegex(ValueError, 'duplicate'): wrapper.verify(self.root)

    def test_unknown_property_is_rejected(self):
        self.properties.write_text(self.properties.read_text() + '\nunreviewed=value\n')
        with self.assertRaisesRegex(ValueError, 'properties differ'): wrapper.verify(self.root)


if __name__ == '__main__': unittest.main()
