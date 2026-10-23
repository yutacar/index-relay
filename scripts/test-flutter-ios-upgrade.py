#!/usr/bin/env python3
"""Upgrade synthetic legacy data on a NEW disposable simulator; never uses an iPhone.
Needs the prepared Flutter SDK on PATH and an already built/verified iOS bridge.
"""
from pathlib import Path
import argparse, hashlib, importlib.util, json, os, plistlib, shutil, struct, subprocess, tempfile, time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'dev.example.indexRelayProbe'
OUT = ROOT / 'work/flutter-ios-upgrade'
backup_spec = importlib.util.spec_from_file_location('migration_check', ROOT / 'scripts/ios-migration-check.py')
backup_check = importlib.util.module_from_spec(backup_spec); backup_spec.loader.exec_module(backup_check)

def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, text=True, **kwargs)

def capture(*args):
    return run(*args, capture_output=True).stdout.strip()

def wait_for(path):
    deadline = time.monotonic() + 30
    while not path.exists():
        error = path.parent / 'upgrade-fixture-error.txt'
        if error.exists():
            raise RuntimeError(error.read_text())
        if time.monotonic() > deadline:
            raise RuntimeError('Simulator fixture did not become ready')
        time.sleep(.25)

def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for directory in ['ReceivedRecordings', 'Transcripts']
            for p in (root / directory).glob('*') if p.is_file()}

def simulated_entitlements(file):
    """Read Xcode's simulator-only __TEXT entitlement section, not device code-sign entitlements."""
    data = file.read_bytes()
    if data[:4] != bytes.fromhex('cffaedfe'):
        return None
    commands = struct.unpack_from('<I', data, 16)[0]
    position = 32
    for _ in range(commands):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19:
            count = struct.unpack_from('<I', data, position + 64)[0]
            for i in range(count):
                section = position + 72 + 80 * i
                name = data[section:section + 16].rstrip(b'\0')
                if name == b'__entitlements':
                    length = struct.unpack_from('<Q', data, section + 40)[0]
                    offset = struct.unpack_from('<I', data, section + 48)[0]
                    return plistlib.loads(data[offset:offset + length].rstrip(b'\0'))
        position += size
    return None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, help='Installed iOS simulator runtime identifier')
    parser.add_argument('--device-type', default='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
                        help='Simulator device type supported by the selected runtime')
    parser.add_argument('--native-legacy-app', type=Path, help='Simulator-only native 0.9.7 app with preview Bundle ID')
    args = parser.parse_args()
    if args.native_legacy_app:
        info = plistlib.loads((args.native_legacy_app / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != BUNDLE or info.get('CFBundleShortVersionString') != '0.9.7' or info.get('CFBundleSupportedPlatforms') != ['iPhoneSimulator']:
            raise SystemExit('Expected native 0.9.7 simulator app with preview Bundle ID')
    if (ROOT / 'flutter_probe/ios/Flutter/Migration.local.xcconfig').exists():
        raise SystemExit('Remove local migration override before running this disposable preview test.')
    OUT.mkdir(parents=True, exist_ok=True)
    seed = OUT / 'LegacyFixture.app'
    seed.mkdir(exist_ok=True)
    info = dict(CFBundleIdentifier=BUNDLE, CFBundleExecutable='LegacyFixture', CFBundleName='LegacyFixture',
                CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='0.9.7',
                MinimumOSVersion='26.0', LSRequiresIPhoneOS=True, CFBundleSupportedPlatforms=['iPhoneSimulator'],
                UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False,
                    'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'Fixture'}]}})
    (seed / 'Info.plist').write_bytes(plistlib.dumps(info))
    sources = ['ReceivedRecording', 'TranscriptArchive', 'AutomaticQueue', 'DeliveryModels',
               'DeliveryNetwork', 'DestinationKeychain', 'HistoryArchive', 'PCM16WAV']
    entitlements = OUT / 'Simulator.entitlements'
    identity = 'SIMULATOR.' + BUNDLE
    entitlements.write_bytes(plistlib.dumps({'application-identifier': identity, 'keychain-access-groups': [identity]}))
    sdk = capture('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
    run('xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '6', '-parse-as-library', '-target', 'arm64-apple-ios26.0-simulator',
        '-sdk', sdk, '-module-cache-path', OUT / 'ModuleCache',
        *[ROOT / f'ios/IndexRelay/{s}.swift' for s in sources],
        ROOT / 'tests/FlutterUpgrade/LegacyFixtureApp.swift',
        '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__entitlements', '-Xlinker', entitlements,
        '-o', seed / 'LegacyFixture')
    run('codesign', '--force', '--sign', '-', seed)
    assert simulated_entitlements(seed / 'LegacyFixture')['application-identifier'] == identity
    device = capture('xcrun', 'simctl', 'create', 'IndexRelay disposable upgrade',
                     args.device_type, args.runtime)
    print('Created disposable simulator:', device, flush=True)
    rehearsal = tempfile.TemporaryDirectory(prefix='backup-rehearsal-', dir=OUT)
    try:
        run('xcrun', 'simctl', 'boot', device)
        run('xcrun', 'simctl', 'bootstatus', device, '-b')
        run('xcrun', 'simctl', 'install', device, seed)
        run('xcrun', 'simctl', 'launch', device, BUNDLE)
        root = Path(capture('xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data')) / 'Library/Application Support'
        wait_for(root / 'upgrade-fixture-ready.txt')
        if args.native_legacy_app:
            original = hashes(root)
            run('xcrun', 'simctl', 'terminate', device, BUNDLE)
            run('xcrun', 'simctl', 'install', device, args.native_legacy_app)
            run('xcrun', 'simctl', 'launch', device, BUNDLE)
            root = Path(capture('xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data')) / 'Library/Application Support'
            assert (root / 'upgrade-fixture-ready.txt').exists(), 'Native update lost the fixture container'
            # Observe real native startup reconciliation, rather than just a successful launch request.
            deadline = time.monotonic() + 45
            while True:
                q = json.loads((root / 'AutomaticRelay/state.json').read_text())
                d = json.loads((root / 'Delivery/state.json').read_text())
                if q['jobs']['9' * 64]['phase'] == 'queued' and d['jobs'][2]['phase'] == 'unknown':
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError('Native legacy startup reconciliation did not complete')
                time.sleep(.25)
            assert hashes(root) == original, 'Native startup changed original audio or transcripts'
            print('Native 0.9.7 startup reconciliation verified', flush=True)
        before = hashes(root)
        old_delivery = json.loads((root / 'Delivery/state.json').read_text())
        old_queue = json.loads((root / 'AutomaticRelay/state.json').read_text())
        old_history = json.loads((root / 'History/deletions.json').read_text())
        run('xcrun', 'simctl', 'terminate', device, BUNDLE)
        backup = Path(rehearsal.name) / 'before.xcappdata'
        shutil.copytree(root.parent.parent, backup / 'AppData', symlinks=True)
        manifest = backup_check.inventory(backup)
        backup_check.save(Path(rehearsal.name) / 'manifest.json', manifest)
        backup_check.verify(backup, manifest)
        restored = Path(rehearsal.name) / 'restored.xcappdata'
        shutil.copytree(backup, restored, symlinks=True)
        backup_check.verify(restored, manifest)
        sample = next((restored / 'AppData/Library/Application Support/ReceivedRecordings').glob('*.wav'))
        with sample.open('r+b') as stream:
            stream.seek(44); value = stream.read(1); stream.seek(44); stream.write(bytes([value[0] ^ 1]))
        try:
            backup_check.verify(restored, manifest)
        except backup_check.MigrationError:
            tamper_rejected = True
        else:
            raise AssertionError('Changed backup was accepted')
        run('flutter', 'test', 'integration_test/ios_upgrade_test.dart', '--no-uninstall', '-d', device, cwd=ROOT / 'flutter_probe', timeout=600)
        app = ROOT / 'flutter_probe/build/ios/iphonesimulator/Runner.app'
        signed = [simulated_entitlements(app / name) for name in ['Runner', 'Runner.debug.dylib'] if (app / name).exists()]
        signed = [item for item in signed if item is not None]
        assert signed and all(item['application-identifier'] == identity for item in signed)
        assert all(item['keychain-access-groups'] == [identity] for item in signed)
        # This test requires install-as-update; an uninstall/reinstall loses the marker and fails here.
        new_root = Path(capture('xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data')) / 'Library/Application Support'
        assert (new_root / 'upgrade-fixture-ready.txt').exists(), 'Container was replaced'
        assert hashes(new_root) == before, 'Original WAV/metadata/transcripts changed'
        delivery = json.loads((new_root / 'Delivery/state.json').read_text())
        assert len(delivery['jobs']) == len(old_delivery['jobs']) == 8
        for old, new in zip(old_delivery['jobs'], delivery['jobs']):
            expected = 'unknown' if old['phase'] == 'sending' else old['phase']
            assert new['phase'] == expected, (old['phase'], new['phase'])
            for key in ['id', 'attempt', 'attempts', 'messageID', 'targetIdentity', 'text', 'confirmationRequired']:
                assert old.get(key) == new.get(key), key
        queue = json.loads((new_root / 'AutomaticRelay/state.json').read_text())
        assert queue['jobs']['9' * 64]['phase'] == 'queued', 'Interrupted recognition did not recover'
        assert queue['frontier'] == old_queue['frontier'], '16-bit receive frontier changed'
        assert json.loads((new_root / 'History/deletions.json').read_text()) == old_history
        # Reinstall the fixture executable without deleting data, then use the SAME native Keychain reader.
        subprocess.run(['xcrun', 'simctl', 'terminate', device, BUNDLE], capture_output=True)
        # Rehearse data rollback only inside the newly created disposable simulator.
        backup_check.verify(backup, manifest)
        for directory in ['ReceivedRecordings', 'Transcripts', 'AutomaticRelay', 'Delivery', 'History']:
            destination = new_root / directory
            if destination.exists(): shutil.rmtree(destination)
            shutil.copytree(backup / 'AppData/Library/Application Support' / directory, destination)
        assert hashes(new_root) == before
        assert json.loads((new_root / 'Delivery/state.json').read_text()) == old_delivery
        assert json.loads((new_root / 'AutomaticRelay/state.json').read_text()) == old_queue
        assert json.loads((new_root / 'History/deletions.json').read_text()) == old_history
        run('xcrun', 'simctl', 'install', device, seed)
        env = dict(os.environ, SIMCTL_CHILD_INDEX_RELAY_VERIFY_KEYCHAIN='1')
        run('xcrun', 'simctl', 'launch', device, BUNDLE, env=env)
        last_root = Path(capture('xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data')) / 'Library/Application Support'
        wait_for(last_root / 'upgrade-keychain-result.txt')
        assert (last_root / 'upgrade-keychain-result.txt').read_text() == 'verified'
        evidence = dict(synthetic=True, simulator_runtime=args.runtime, simulator_device_type=args.device_type, legacyRecordings=9,
                        immutableFiles=len(before), originalFilesUnchanged=True, historyAndTombstonesPreserved=True,
                        frontierPreserved=True, receiptAndAttemptIDsPreserved=True, sendingRecoveredAsUnknown=True,
                        keychainReadableAfterUpdate=True, destinationsDisabled=True,
                        backupIntegrityVerified=True, backupTamperRejected=tamper_rejected,
                        simulatorDataRollbackVerified=True, keychainIncludedInBackup=False, nativeLegacyStartupVerified=bool(args.native_legacy_app),
                        backupQuiescent=manifest['summary']['quiescentSnapshot'],
                        limits='Simulator fixture compatibility only; device signing, BLE, locked/background execution remain unverified.')
        (OUT / 'evidence.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
        print('Upgrade fixture verification passed:', OUT / 'evidence.json', flush=True)
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True)
        subprocess.run(['xcrun', 'simctl', 'delete', device], capture_output=True)
        rehearsal.cleanup()

if __name__ == '__main__':
    main()
