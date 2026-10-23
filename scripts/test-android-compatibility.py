#!/usr/bin/env python3
"""Own-AVD Android31/33/36 checks. Synthetic ASR, no BLE/credentials/external posts.

Requires installed google_apis ARM64 images. Never resets an existing emulator.
Results (including sampled memory, not an absolute peak) stay under work/.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'dev.example.index_relay_probe'


def synthetic(source, destination, seconds):
    with wave.open(str(source), 'rb') as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 16000)
        data = wav.readframes(wav.getnframes())
    size = seconds * 32000
    with wave.open(str(destination), 'wb') as wav:
        wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        wav.writeframes((data * ((size + len(data) - 1) // len(data)))[:size])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apis', type=int, nargs='+', default=[31, 33, 36], choices=[31, 33, 36])
    parser.add_argument('--long-seconds', type=int, nargs='+', default=[60, 180, 300], choices=[15, 60, 180, 300])
    parser.add_argument('--port', type=int, default=5558)
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    assert args.port >= 5558 and args.port % 2 == 0
    assert args.timeout >= 60
    serial = f'emulator-{args.port}'
    assert serial not in subprocess.check_output(['adb', 'devices'], text=True), 'Port already in use'
    out = ROOT / 'work/android-compatibility'; out.mkdir(parents=True, exist_ok=True)
    avds = out / 'avd'; avds.mkdir(exist_ok=True)
    env = dict(os.environ, ANDROID_AVD_HOME=str(avds))
    apk = ROOT / 'flutter_probe/build/app/outputs/flutter-apk/app-preview-debug.apk'
    assert apk.is_file()
    immutable = out / 'compat-tested.apk'
    shutil.copyfile(apk, immutable)
    apk = immutable
    evidence = {'scope': 'ARM64 emulator; synthetic repeated speech; no real BLE/external posts',
                'apkSha256': hashlib.sha256(apk.read_bytes()).hexdigest(), 'emulatorCores': 2, 'emulatorMemoryMiB': 2048, 'cases': []}
    def save(): (out / 'evidence.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    def adb(*command, data=None, check=True):
        return subprocess.run(['adb', '-s', serial, *map(str, command)], input=data,
                              capture_output=True, check=check, timeout=120).stdout
    def shell(*command, **kwargs): return adb('shell', *command, **kwargs).decode().strip()
    def write(path, data): adb('exec-in', 'run-as', PACKAGE, 'sh', '-c', f'cat > {path}', data=data)
    def read(path): return adb('exec-out', 'run-as', PACKAGE, 'cat', path, check=False)
    def broadcast(command): shell('am', 'broadcast', '-n', PACKAGE + '/.ReceiverHarnessBroadcast', '--es', 'command', command)
    def wait(action, seconds=30):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = action()
            if value: return value
            time.sleep(.5)
        raise AssertionError('Timed out waiting for emulator state')
    def inspect():
        shell('run-as', PACKAGE, 'rm', '-f', 'no_backup/receiver-test-state.json')
        broadcast('inspect')
        state = json.loads(wait(lambda: read('no_backup/receiver-test-state.json')))
        assert not state['destinations'] and not state['deliveries']
        assert not state['testTransportActive'] and not state['mockConfigurationPresent']
        return state
    def command(method, **arguments):
        write('no_backup/delivery-harness-input.json', json.dumps({'method': method, 'args': arguments}).encode())
        shell('run-as', PACKAGE, 'rm', '-f', 'no_backup/delivery-harness-result.json')
        broadcast('delivery')
        result = json.loads(wait(lambda: read('no_backup/delivery-harness-result.json')))
        assert result['ok'], result
    def service():
        shell('am', 'start', '-W', '-n', PACKAGE + '/.ReceiverHarnessActivity')
        wait(lambda: inspect()['receiverRunning'])
    def boot():
        wait(lambda: shell('getprop', 'sys.boot_completed', check=False) == '1', 300)
        for binder in ['package', 'activity']:
            wait(lambda: shell('service', 'check', binder).endswith(': found'), 60)
        shell('input', 'keyevent', '82')
    def fixture(seconds):
        path = out / 'synthetic.wav'
        synthetic(ROOT / 'flutter_probe/assets/japanese.wav', path, seconds)
        write('no_backup/compat-fixture.wav', path.read_bytes())
        command('audioFixture')
    try:
        for api in args.apis:
            name = f'index_relay_compat_{api}'; avd = avds / (name + '.avd')
            if not avd.exists():
                subprocess.run(['avdmanager', 'create', 'avd', '--name', name, '--package',
                                f'system-images;android-{api};google_apis;arm64-v8a', '--path', str(avd)],
                               input='no\n', text=True, check=True, capture_output=True, env=env, timeout=120)
            (avds / (name + '.ini')).write_text(f'avd.ini.encoding=UTF-8\npath={avd}\ntarget=android-{api}\n')
            with (out / f'emulator-{api}.log').open('w') as log:
                process = subprocess.Popen(['emulator', '-avd', name, '-port', str(args.port), '-no-window',
                                            '-no-snapshot', '-no-audio', '-no-boot-anim', '-gpu', 'swiftshader',
                                            '-memory', '2048', '-cores', '2'], env=env, stdout=log, stderr=log)
                try:
                    boot()
                    assert int(shell('getprop', 'ro.build.version.sdk')) == api
                    assert shell('getprop', 'ro.kernel.qemu') == '1'
                    adb('install', '-r', apk)
                    assert 'Success' in shell('pm', 'clear', PACKAGE)
                    assert not inspect()['capabilities']['bluetooth']
                    entry = {'api': api, 'bluetoothInitiallyDenied': True, 'asr': []}
                    evidence['cases'].append(entry); save()
                    for permission in ['BLUETOOTH_SCAN', 'BLUETOOTH_CONNECT']:
                        shell('pm', 'grant', PACKAGE, 'android.permission.' + permission)
                    if api >= 33: shell('pm', 'revoke', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
                    service(); state = inspect()
                    assert state['capabilities']['bluetooth']
                    if api >= 33: assert not state['capabilities']['notifications']
                    entry['serviceWithoutNotificationPermission'] = api >= 33
                    shell('pm', 'revoke', PACKAGE, 'android.permission.BLUETOOTH_SCAN')
                    # Android may apply revocation/process termination asynchronously.
                    def revoked():
                        state = inspect()
                        return not state['capabilities']['bluetooth'] and not state['receiverRunning']
                    wait(revoked)
                    shell('pm', 'grant', PACKAGE, 'android.permission.BLUETOOTH_SCAN')
                    service(); shell('am', 'force-stop', PACKAGE)
                    assert not inspect()['receiverRunning']
                    service(); entry['permissionRevocationAndManualRestart'] = True
                    if api == 36:
                        adb('reboot'); boot()
                        assert not inspect()['receiverRunning']
                        service(); entry['rebootRequiresManualRestart'] = True
                    write('no_backup/ggml-base.bin', b'invalid synthetic model')
                    fixture(15)
                    wait(lambda: any(r['phase'] == 'needsAttention' for r in inspect()['recordings']))
                    failed = inspect()
                    assert failed['modelStatus'] == 'failed'
                    assert all('モデル' in r['detail'] for r in failed['recordings'])
                    command('prepareModel'); assert inspect()['modelStatus'] == 'ready'
                    entry['invalidModelGuidanceAndRepair'] = True
                    for seconds in (args.long_seconds if api == 36 else [15]):
                        existing = [r['id'] for r in inspect()['recordings']]
                        if existing: command('deleteRecordings', ids=existing)
                        start = time.monotonic(); fixture(seconds)
                        peak_pss = peak_rss = 0
                        while True:
                            rows = inspect()['recordings']
                            assert len(rows) == 1 and rows[0]['samples'] == seconds * 16000
                            row = rows[0]; mem = shell('dumpsys', 'meminfo', PACKAGE)
                            pss = re.search(r'TOTAL PSS:\s*(\d+)', mem); rss = re.search(r'TOTAL RSS:\s*(\d+)', mem)
                            if pss: peak_pss = max(peak_pss, int(pss[1]))
                            if rss: peak_rss = max(peak_rss, int(rss[1]))
                            if row['phase'] in ['done', 'needsAttention']: break
                            assert time.monotonic() - start < args.timeout, 'ASR exceeded bounded observation time'
                            time.sleep(2)
                        result = {'audioSeconds': seconds, 'wallSeconds': round(time.monotonic() - start, 2),
                                  'nativeAsrMs': row['elapsedMs'], 'sampledPeakPssKiB': peak_pss,
                                  'sampledPeakRssKiB': peak_rss, 'phase': row['phase'], 'nonemptyResult': bool(row['text'])}
                        entry['asr'].append(result); save(); print(json.dumps({'api': api, **result}), flush=True)
                        assert row['phase'] == 'done' and row['text'], row.get('detail')
                    previous = {r['id'] for r in inspect()['recordings']}; fixture(300)
                    def active():
                        return next((r for r in inspect()['recordings'] if r['id'] not in previous and r['phase'] == 'processing'), None)
                    row = wait(active); command('deleteRecordings', ids=[row['id']])
                    wait(lambda: not inspect()['busy'], 60)
                    assert all(r['id'] != row['id'] for r in inspect()['recordings'])
                    entry['deleteDuringAsrNoResurrection'] = True; save()
                finally:
                    adb('emu', 'kill', check=False); process.wait(timeout=30)
    except Exception as error:
        evidence['failure'] = str(error); save(); raise
    evidence['passed'] = True; save()


if __name__ == '__main__':
    main()
