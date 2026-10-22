import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/check-publication.py'


class PublicationTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.parent = Path(tmp.name)
        self.project = self.parent / 'exports/project'
        (self.project / 'scripts').mkdir(parents=True)
        shutil.copy2(SCRIPT, self.project / 'scripts/check-publication.py')
        (self.project / 'README.md').write_text('Synthetic export\n')

    def audit(self):
        return subprocess.run(['python3', str(self.project / 'scripts/check-publication.py')], capture_output=True, text=True)

    def test_export_without_git_is_inspected(self):
        result = self.audit()
        self.assertEqual(result.returncode, 0)
        self.assertIn('2 files', result.stdout)

    def test_ignored_export_inside_parent_git_is_inspected(self):
        subprocess.run(['git', 'init', '-q', str(self.parent)], check=True)
        (self.parent / '.gitignore').write_text('/exports/\n')
        result = self.audit()
        self.assertEqual(result.returncode, 0)
        self.assertIn('2 files', result.stdout)

    def test_secret_in_ignored_parent_export_is_rejected_without_echoing_value(self):
        subprocess.run(['git', 'init', '-q', str(self.parent)], check=True)
        (self.parent / '.gitignore').write_text('/exports/\n')
        marker = '-----BEGIN ' + 'PRIVATE KEY-----'
        (self.project / 'secret.txt').write_text(marker + '\nsynthetic-hidden-value\n')
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('private key', result.stdout)
        self.assertNotIn(marker, result.stdout + result.stderr)
        self.assertNotIn('synthetic-hidden-value', result.stdout + result.stderr)

    def test_own_git_index_remains_respected(self):
        subprocess.run(['git', 'init', '-q', str(self.project)], check=True)
        (self.project / '.gitignore').write_text('/work/\n')
        (self.project / 'work').mkdir()
        (self.project / 'work/private.wav').write_bytes(b'local fixture')
        result = self.audit()
        self.assertEqual(result.returncode, 0)
        self.assertIn('3 files', result.stdout)

    def test_exact_reviewed_wrapper_jar_is_allowed(self):
        jar = self.project / 'bridge/gradle/wrapper/gradle-wrapper.jar'
        jar.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'bridge/gradle/wrapper/gradle-wrapper.jar', jar)
        self.assertEqual(self.audit().returncode, 0)

    def test_modified_wrapper_jar_is_rejected(self):
        jar = self.project / 'bridge/gradle/wrapper/gradle-wrapper.jar'
        jar.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'bridge/gradle/wrapper/gradle-wrapper.jar', jar)
        jar.write_bytes(jar.read_bytes() + b'changed')
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unapproved JAR', result.stdout)

    def test_reviewed_jar_at_another_path_is_rejected(self):
        shutil.copy2(ROOT / 'bridge/gradle/wrapper/gradle-wrapper.jar', self.project / 'other.jar')
        self.assertNotEqual(self.audit().returncode, 0)

    def test_empty_candidate_set_is_not_success(self):
        spec = importlib.util.spec_from_file_location('publication', SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.ROOT = self.parent / 'empty'
        module.ROOT.mkdir()
        with self.assertRaisesRegex(SystemExit, 'no candidate files'):
            module.main()


if __name__ == '__main__': unittest.main()
