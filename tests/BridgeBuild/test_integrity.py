import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('integrity', ROOT / 'scripts/bridge_integrity.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeIntegrityTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.stage = self.root / 'stage'
        self.installed = self.root / 'ios/Frameworks/IndexReceiverBridge.xcframework'
        for name in bridge.BINARIES:
            path = self.stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'new build')
        bridge.record(self.stage)
        shutil.copytree(self.stage, self.installed)

    def test_record_and_verify_both_slices(self):
        self.assertEqual(len(bridge.verify(self.stage)['sha256']), 2)

    def test_corruption_is_rejected(self):
        (self.stage / bridge.BINARIES[1]).write_bytes(b'changed')
        with self.assertRaises(ValueError): bridge.verify(self.stage)

    def test_missing_slice_is_rejected(self):
        (self.stage / bridge.BINARIES[0]).unlink()
        with self.assertRaises(ValueError): bridge.verify(self.stage)

    def test_missing_receipt_is_rejected(self):
        (self.stage / bridge.RECEIPT).unlink()
        with self.assertRaises(OSError): bridge.verify(self.stage)

    def test_incomplete_receipt_is_rejected(self):
        receipt = bridge.verify(self.stage)
        del receipt['sha256'][bridge.BINARIES[1]]
        (self.stage / bridge.RECEIPT).write_text(json.dumps(receipt))
        with self.assertRaises(ValueError): bridge.verify(self.stage)

    def test_symlinked_binary_is_rejected(self):
        path = self.stage / bridge.BINARIES[0]
        copy = self.root / 'outside'
        path.rename(copy); path.symlink_to(copy)
        with self.assertRaises(ValueError): bridge.verify(self.stage)

    def test_bad_staging_preserves_installed_output(self):
        before = bridge.verify(self.installed)
        (self.stage / bridge.BINARIES[0]).write_bytes(b'corrupt')
        with self.assertRaises(ValueError): bridge.install(self.stage, self.installed)
        self.assertEqual(bridge.verify(self.installed), before)

    def test_install_succeeds_for_new_build_without_old_hash_approval(self):
        (self.stage / bridge.BINARIES[0]).write_bytes(b'new timestamps or code')
        bridge.record(self.stage)
        bridge.install(self.stage, self.installed)
        self.assertEqual(bridge.verify(self.stage), bridge.verify(self.installed))
        self.assertEqual(list(self.installed.parent.glob('.index-relay-install-*')), [])

    def test_failed_copy_preserves_installed_output(self):
        def fail_copy(*args, **kwargs): raise OSError('simulated disk failure')
        from unittest.mock import patch
        before = bridge.verify(self.installed)
        with patch.object(bridge.shutil, 'copytree', fail_copy):
            with self.assertRaises(OSError): bridge.install(self.stage, self.installed)
        self.assertEqual(bridge.verify(self.installed), before)

    def test_failed_replace_restores_previous_installation(self):
        before = bridge.verify(self.installed)
        def fail_replace(source, dest):
            if source.name == 'candidate': raise OSError('simulated rename failure')
            os.replace(source, dest)
        with self.assertRaises(OSError): bridge.install(self.stage, self.installed, replace=fail_replace)
        self.assertEqual(bridge.verify(self.installed), before)

    def test_failed_restore_keeps_recoverable_previous_copy(self):
        before = bridge.verify(self.installed)
        def fail_replace(source, dest):
            if source.name in {'candidate', 'previous'}: raise OSError('simulated rename failure')
            os.replace(source, dest)
        with self.assertRaises(OSError): bridge.install(self.stage, self.installed, replace=fail_replace)
        saved = list(self.installed.parent.glob('.index-relay-install-*/previous'))
        self.assertEqual(len(saved), 1)
        self.assertEqual(bridge.verify(saved[0]), before)

    def test_install_rejects_identical_paths(self):
        with self.assertRaises(ValueError): bridge.install(self.stage, self.stage)


class BuildCommandTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'scripts').mkdir(); (self.root / 'bridge/gradle').mkdir(parents=True)
        self.metadata = self.root / 'bridge/gradle/verification-metadata.xml'
        self.metadata.write_text('<verification-metadata/>')
        for name in ('build-receiver-framework.sh', 'bridge-env.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        for name in ("verify-gradle-wrapper.py", "gradle_wrapper.py"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        for name in ("gradlew", "gradlew.bat"):
            shutil.copy2(ROOT / "bridge" / name, self.root / "bridge" / name)
        shutil.copytree(ROOT / "bridge/gradle/wrapper", self.root / "bridge/gradle/wrapper")
        tools = self.root / 'tools'; tools.mkdir()
        for name, script in {
            'uname': '#!/bin/sh\nif [ "$1" = "-s" ]; then echo Darwin; else echo arm64; fi\n',
            'gradle': '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "Gradle ${TEST_GRADLE_VERSION:-8.14.3}"; exit 0; fi\nprintf "%s\\n" "$@" > "$TEST_ARGUMENTS"\necho STRICT_DEPENDENCY_FAILURE >&2\nexit 51\n',
            'xcodebuild': '#!/bin/sh\necho UNEXPECTED_XCODE >&2\nexit 52\n',
        }.items():
            path = tools / name; path.write_text(script); path.chmod(0o755)
        self.args = self.root / 'args'
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get('PATH', ''),
                        GRADLE_CMD=str(tools / 'gradle'), TEST_ARGUMENTS=str(self.args))

    def run_script(self, *args):
        return subprocess.run(['bash', str(self.root / 'scripts/build-receiver-framework.sh'), *args],
                              env=self.env, capture_output=True, text=True)

    def test_default_path_uses_verified_wrapper_without_system_gradle(self):
        self.env.pop('GRADLE_CMD', None)
        java = self.root / 'jdk/bin/java'
        java.parent.mkdir(parents=True)
        java.write_text('#!/bin/sh\necho "Gradle 8.14.3"\n')
        java.chmod(0o755)
        self.env['JAVA_HOME'] = str(java.parent.parent)
        result = subprocess.run(['bash', '-c', 'source "$1"; printf "%s" "$receiver_gradle"',
                                 '--', str(self.root / 'scripts/bridge-env.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith(str(self.root / 'bridge/gradlew')))
        self.assertFalse(self.args.exists(), 'System Gradle must not be selected')

    def test_wrapper_tampering_stops_before_overridden_gradle(self):
        launcher = self.root / 'bridge/gradlew'
        launcher.write_bytes(launcher.read_bytes() + b'\nchanged')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('launcher checksum', result.stderr)
        self.assertFalse(self.args.exists())

    def test_wrong_gradle_version_is_rejected(self):
        self.env['TEST_GRADLE_VERSION'] = '8.14.4'
        self.assertIn('Expected Gradle 8.14.3', self.run_script().stderr)
        self.assertFalse(self.args.exists())

    def test_missing_dependency_metadata_is_rejected_before_compilation(self):
        self.metadata.unlink()
        self.assertIn('metadata is required', self.run_script().stderr)
        self.assertFalse(self.args.exists())

    def test_dependency_failure_stops_before_xcode_and_baselines_do_not_change(self):
        before = self.metadata.read_bytes()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('STRICT_DEPENDENCY_FAILURE', result.stderr)
        self.assertNotIn('UNEXPECTED_XCODE', result.stderr)
        args = self.args.read_text().splitlines()
        i = args.index('--dependency-verification')
        self.assertEqual(args[i + 1], 'strict')
        self.assertIn('--rerun-tasks', args)
        self.assertNotIn('--write-verification-metadata', args)
        self.assertEqual(self.metadata.read_bytes(), before)

    def test_legacy_bootstrap_and_checksum_update_are_rejected(self):
        for option in ('--bootstrap-verification', '--update-checksums', '--dependency-verification=off'):
            self.assertNotEqual(self.run_script(option).returncode, 0)
        self.assertFalse(self.args.exists())


if __name__ == '__main__': unittest.main()
