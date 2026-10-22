import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/inspect-bridge-network.py"
spec = importlib.util.spec_from_file_location("bridge_network", SCRIPT)
network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)


class NetworkInspectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.framework = self.root / "Bridge.xcframework"
        self.baseline = self.root / "baseline.json"
        for name in network.SLICES:
            self.binary(name).parent.mkdir(parents=True)
            self.binary(name).write_bytes(b"NSURLSession https://known.invalid/path")
        self.initial = network.snapshot(self.framework)
        self.baseline.write_text(json.dumps(self.initial))

    def binary(self, name):
        return self.framework / name / "IndexReceiverBridge.framework/IndexReceiverBridge"

    def invoke(self, *arguments):
        return subprocess.run(["python3", str(SCRIPT), "--framework", str(self.framework),
                               "--baseline", str(self.baseline), *arguments], capture_output=True, text=True)

    def test_both_slices_are_required(self):
        self.binary("ios-arm64-simulator").unlink()
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_normal_check_does_not_write_baseline(self):
        before = self.baseline.read_bytes()
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_new_device_endpoint_is_rejected(self):
        self.binary("ios-arm64").write_bytes(b"https://new-device.invalid/path")
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_new_simulator_endpoint_is_rejected(self):
        self.binary("ios-arm64-simulator").write_bytes(b"https://new-simulator.invalid/path")
        before = self.baseline.read_bytes()
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_new_known_api_marker_is_rejected(self):
        self.binary("ios-arm64-simulator").write_bytes(b"NSURLSession nw_connection https://known.invalid/path")
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_report_is_read_only(self):
        before = self.baseline.read_bytes()
        result = self.invoke("--report")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), self.initial)
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_explicit_reviewed_report_can_be_approved(self):
        self.binary("ios-arm64-simulator").write_bytes(b"https://reviewed.invalid/path")
        report = self.root / "reviewed.json"
        report.write_text(self.invoke("--report").stdout)
        self.assertEqual(self.invoke("--approve-baseline", str(report)).returncode, 0)
        self.assertEqual(self.invoke().returncode, 0)

    def test_stale_report_cannot_bless_new_binary(self):
        report = self.root / "reviewed.json"
        report.write_text(json.dumps(self.initial))
        self.binary("ios-arm64").write_bytes(b"https://changed-after-review.invalid/path")
        before = self.baseline.read_bytes()
        self.assertNotEqual(self.invoke("--approve-baseline", str(report)).returncode, 0)
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_missing_baseline_fails_closed(self):
        self.baseline.unlink()
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse(self.baseline.exists())

    def test_invalid_schema_fails_closed(self):
        self.baseline.write_text(json.dumps({"schema": 2, "slices": {}}))
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_failed_staging_check_preserves_installed_framework_and_baseline(self):
        project = self.root / "project"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        for name in ("build-receiver-framework.sh", "bridge-env.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        destination = project / "ios/Frameworks/IndexReceiverBridge.xcframework"
        shutil.copytree(self.framework, destination)
        baseline = project / "bridge/network-surface.json"
        baseline.parent.mkdir()
        (baseline.parent / "gradle").mkdir()
        (baseline.parent / "gradle/verification-metadata.xml").write_text("<verification-metadata/>")
        baseline.write_bytes(self.baseline.read_bytes())
        before = self.binary("ios-arm64").read_bytes()
        for name in ("verify-gradle-wrapper.py", "gradle_wrapper.py"):
            shutil.copy2(ROOT / "scripts" / name, project / "scripts" / name)
        for name in ("gradlew", "gradlew.bat"):
            shutil.copy2(ROOT / "bridge" / name, project / "bridge" / name)
        shutil.copytree(ROOT / "bridge/gradle/wrapper", project / "bridge/gradle/wrapper")
        tools = project / "fake-tools"
        tools.mkdir()
        programs = {
            "gradle": '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "Gradle 8.14.3"; fi\nexit 0\n',
            "uname": '#!/bin/sh\nif [ "$1" = "-s" ]; then echo Darwin; else echo arm64; fi\n',
            "ditto": "#!/bin/sh\necho UNEXPECTED_INSTALL >&2\nexit 90\n",
            "xcodebuild": "#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\nout=Path(sys.argv[sys.argv.index('-output')+1])\nfor name in ['ios-arm64','ios-arm64-simulator']:\n p=out/name/'IndexReceiverBridge.framework/IndexReceiverBridge'\n p.parent.mkdir(parents=True)\n p.write_bytes(b'NSURLSession https://known.invalid/path' if name=='ios-arm64' else b'https://unexpected.invalid/path')\n",
        }
        for name, content in programs.items():
            tool = tools / name
            tool.write_text(content)
            tool.chmod(0o755)
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
                           GRADLE_CMD=str(tools / "gradle"), GRADLE_USER_HOME=str(project / "cache"),
                           KONAN_DATA_DIR=str(project / "konan"))
        result = subprocess.run(["bash", str(scripts / "build-receiver-framework.sh")], env=environment,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("New bridge network strings", result.stderr)
        self.assertNotIn("UNEXPECTED_INSTALL", result.stderr)
        self.assertEqual((destination / "ios-arm64/IndexReceiverBridge.framework/IndexReceiverBridge").read_bytes(), before)
        self.assertEqual(baseline.read_bytes(), self.baseline.read_bytes())

    def test_old_auto_write_option_is_not_supported(self):
        self.assertNotEqual(self.invoke("--write").returncode, 0)


if __name__ == "__main__":
    unittest.main()
