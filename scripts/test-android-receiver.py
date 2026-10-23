#!/usr/bin/env python3
"""Native service/worker tests. Requires a dedicated ARM64 emulator and synthetic reset consent flag."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/android-receiver-tests'
PACKAGE = 'dev.example.index_relay_probe'
LEGACY = '1' * 64


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='emulator-5554')
    parser.add_argument('--legacy-version', type=int, choices=[1,2], default=1)
    parser.add_argument('--migration-only', action='store_true')
    parser.add_argument('--reset-test-data', action='store_true', required=True)
    args = parser.parse_args()
    if not args.device.startswith('emulator-'):
        raise SystemExit('Only a dedicated emulator is allowed.')
    OUT.mkdir(parents=True, exist_ok=True)
    def adb(*command, binary=False, check=True):
        result = subprocess.run(['adb','-s',args.device,*map(str,command)], check=check,
                                capture_output=True, timeout=90)
        return result.stdout if binary else result.stdout.decode().strip()
    def shell(*command, **kwargs): return adb('shell', *command, **kwargs)
    def broadcast(command, *extra):
        return shell('am','broadcast','-n',PACKAGE + '/.ReceiverHarnessBroadcast','--es','command',command,*extra)
    def native_file(path): return adb('exec-out','run-as',PACKAGE,'cat',path,binary=True)
    def inspect():
        broadcast('inspect')
        return json.loads(native_file('no_backup/receiver-test-state.json'))
    def wait(predicate, label, seconds=240):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            state = inspect()
            if predicate(state): return state
            time.sleep(.5)
        raise AssertionError('Timed out: ' + label)
    def start():
        output = shell('am','start','-W','-n',PACKAGE + '/.ReceiverHarnessActivity')
        assert 'Error' not in output, output
        return wait(lambda s: s['receiverRunning'] and s['receiverStatus'].startswith('試験用'), 'foreground service')
    def capture(first, last, fault=None):
        before = inspect(); stamp = max((e['time'] for e in before['receiverEvents']), default=0)
        time.sleep(.01)
        extra = ['--ei','start',str(first),'--ei','end',str(last)]
        if fault: extra += ['--es','fault',fault]
        broadcast('capture',*extra)
        return wait(lambda s: any(e['code'] in ['FIXTURE_SAVED','FIXTURE_FAILED','FIXTURE_REJECTED'] and e['time'] > stamp for e in s['receiverEvents']), 'fixture acceptance')
    def done(state): return all(r['phase'] == 'done' for r in state['recordings'])
    def vault(mode):
        shell('run-as',PACKAGE,'rm','-f','no_backup/vault-test-result.json')
        broadcast('vault','--es','mode',mode)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            raw = native_file('no_backup/vault-test-result.json')
            if raw: return json.loads(raw)['ok']
            time.sleep(.2)
        raise AssertionError('Vault test did not finish')
    assert shell('getprop','ro.kernel.qemu') == '1'
    assert int(shell('getprop','ro.build.version.sdk')) >= 33
    assert shell('getprop','ro.product.cpu.abi') == 'arm64-v8a'
    apk = ROOT / 'flutter_probe/build/app/outputs/flutter-apk/app-preview-debug.apk'
    adb('install','-r',apk)
    shell('am','force-stop',PACKAGE)
    assert 'Success' in shell('pm','clear',PACKAGE)
    # Seed the exact v1 store without any credential, network target or personal recording.
    db = OUT / 'legacy-v1.db'
    db.unlink(missing_ok=True)
    conn = sqlite3.connect(db)
    conn.executescript('''PRAGMA user_version=1;
    CREATE TABLE settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
    INSERT INTO settings VALUES ('historyLimit',17),('requiresConfirmation',1);
    CREATE TABLE recordings (id TEXT PRIMARY KEY, createdAt INTEGER NOT NULL, phase TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', samples INTEGER NOT NULL, engine TEXT NOT NULL DEFAULT '', elapsedMs INTEGER NOT NULL DEFAULT 0, attempt TEXT, detail TEXT);
    CREATE TABLE destinations (id TEXT PRIMARY KEY, name TEXT NOT NULL, provider TEXT NOT NULL, prefix TEXT NOT NULL, targetHint TEXT NOT NULL);
    ''')
    conn.execute("INSERT INTO recordings(id,createdAt,phase,text,samples,engine) VALUES (?,1700000000000,'done',?,16000,'synthetic legacy fixture')",(LEGACY,'移行前の試験文'))
    conn.execute('INSERT INTO destinations VALUES (?,?,?,?,?)',('11111111-2222-4333-8444-555555555555','旧設定','discord','試験',''))
    if args.legacy_version == 2:
        conn.executescript("""ALTER TABLE recordings ADD COLUMN sampleRate INTEGER NOT NULL DEFAULT 16000;
        ALTER TABLE recordings ADD COLUMN simulation INTEGER NOT NULL DEFAULT 1;
        CREATE TABLE receiver (singleton INTEGER PRIMARY KEY CHECK(singleton=1),address TEXT NOT NULL,simulation INTEGER NOT NULL,enabled INTEGER NOT NULL,session TEXT NOT NULL,frontier TEXT NOT NULL);
        CREATE TABLE tombstones (id TEXT PRIMARY KEY);
        CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT,time INTEGER NOT NULL,code TEXT NOT NULL,recordingKey TEXT);
        PRAGMA user_version=2;""")
        conn.execute("INSERT INTO receiver VALUES (1,'fixture',1,1,?,'65534|65533|')",('30000000-0000-4000-8000-000000000001',))
        conn.execute("INSERT INTO tombstones VALUES (?)",('2'*64,))
        conn.execute("UPDATE recordings SET simulation=0")
    conn.commit(); conn.close()
    wav = OUT / 'legacy.wav'
    with wave.open(str(wav),'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000); f.writeframes(bytes(32000))
    for permission in ['BLUETOOTH_SCAN','BLUETOOTH_CONNECT','POST_NOTIFICATIONS']:
        shell('pm','grant',PACKAGE,'android.permission.' + permission)
    shell('run-as',PACKAGE,'mkdir','-p','no_backup/relay/audio')
    for file,target in [(db,'no_backup/relay/relay.db'), (wav,'no_backup/relay/audio/' + LEGACY + '.wav')]:
        remote = '/data/local/tmp/index-relay-' + file.name
        adb('push',file,remote); shell('chmod','644',remote)
        shell('run-as',PACKAGE,'cp',remote,target); shell('rm',remote)
    evidence = dict(synthetic=True, emulatorAPI=int(shell('getprop','ro.build.version.sdk')), physicalBLEVerified=False)
    try:
        state = start()
        assert state['schema'] == 3 and state['historyLimit'] == 17
        assert state['recordings'][0]['id'] == LEGACY and state['recordings'][0]['sampleRate'] == 16000
        assert state['destinations'][0]['prefix'] == '試験'
        assert hashlib.sha256(native_file('no_backup/relay/audio/' + LEGACY + '.wav')).digest() == hashlib.sha256(wav.read_bytes()).digest()
        activities = shell('dumpsys','activity','activities')
        assert PACKAGE + '/.MainActivity' not in activities
        print(f'PASS: v{args.legacy_version} migration; native service starts without Flutter activity',flush=True)
        evidence['legacyMigration'] = True
        if args.legacy_version == 2:
            assert state['frontier'] == '65534|65533|'
            assert '2'*64 in {t['id'] for t in state['tombstones']}
            assert state['recordings'][0]['simulation'] is False
            assert state['deliveries'] == [] and state['destinations'][0]['enabled'] is False
            evidence['legacyVersion'] = 2
            evidence['frontierTombstonesAndDisabledDraftPreserved'] = True
        if args.migration_only:
            (OUT / 'migration-evidence.json').write_text(json.dumps(evidence,indent=2) + '\n')
            print('Migration-only checks passed.',flush=True)
            return
        state = capture(65534,65534)
        assert state['frontier'].startswith('65535|65534|')
        state = wait(done,'real offline Whisper recognition')
        first = next(r for r in state['recordings'] if r['id'] != LEGACY)
        assert '動作確認' in first['text'] and '音声' in first['text']
        assert first['engine'].startswith('whisper.cpp')
        count = len(state['recordings'])
        assert len(capture(65534,65534)['recordings']) == count
        print('PASS: background capture, real recognition and duplicate suppression',flush=True)
        evidence['backgroundRealTranscription'] = True
        evidence['duplicateSuppression'] = True
        state = capture(0,1)
        assert state['frontier'].startswith('65535|65534|0,1')
        state = capture(65535,65535)
        assert state['frontier'] == '2|1|'
        wait(done,'out-of-order recognition')
        broadcast('delete','--es','id',first['id'])
        state = wait(lambda s: all(r['id'] != first['id'] for r in s['recordings']),'deletion')
        assert first['id'] in {t['id'] for t in state['tombstones']}
        assert not any(name.startswith(first['id']) for name in state['audioFiles'])
        assert all(r['id'] != first['id'] for r in capture(65534,65534)['recordings'])
        print('PASS: rollover, gap handling and durable deletion/replay',flush=True)
        evidence['frontierAndTombstones'] = True
        before = inspect(); count = len(before['recordings']); position = before['frontier']
        state = capture(2,2,'incomplete')
        assert len(state['recordings']) == count and state['frontier'] == position
        state = capture(2,2,'after_file')
        assert len(state['recordings']) == count and state['frontier'] == position
        state = capture(2,2)
        assert state['frontier'] == '3|2|'
        wait(done,'retry after failed file checkpoint')
        broadcast('cancel-work'); time.sleep(.5)
        state = capture(3,3,'after_db')
        assert state['frontier'] == '4|3|'
        pending = next(r['id'] for r in state['recordings'] if r['phase'] == 'queued')
        assert vault('save')
        secret_file = 'no_backup/relay/credentials/selftest/10000000-0000-0000-0000-000000000001.bin'
        ciphertext = native_file(secret_file)
        assert b'synthetic-secret-not-a-real-token' not in ciphertext
        pid = shell('pidof',PACKAGE).split()[0]
        shell('run-as',PACKAGE,'kill','-9',pid)
        # System may restart START_STICKY; explicitly entering the native harness also works after a stop.
        start()
        state = wait(lambda s: any(r['id'] == pending and r['phase'] == 'done' for r in s['recordings']), 'persisted job recovery')
        assert state['frontier'] == '4|3|'
        assert vault('load')
        print('PASS: file/DB faults, process-death recovery and Keystore persistence',flush=True)
        evidence['faultAndProcessRecovery'] = True
        evidence['keystorePersistence'] = True
        changed = bytearray(ciphertext); changed[-1] ^= 1
        tampered = OUT / 'tampered.bin'; tampered.write_bytes(changed)
        remote = '/data/local/tmp/index-relay-tampered.bin'
        adb('push',tampered,remote); shell('chmod','644',remote)
        shell('run-as',PACKAGE,'cp',remote,secret_file); shell('rm',remote)
        assert not vault('load'), 'Unauthenticated credential accepted'
        assert vault('save')
        assert native_file(secret_file) != ciphertext
        evidence['credentialTamperRejected'] = True
        shell('dumpsys','battery','unplug')
        shell('input','keyevent','KEYCODE_SLEEP')
        shell('dumpsys','deviceidle','force-idle')
        state = capture(4,4)
        assert state['frontier'] == '5|4|'
        shell('dumpsys','deviceidle','unforce'); shell('dumpsys','battery','reset')
        shell('input','keyevent','KEYCODE_WAKEUP')
        wait(done,'recognition following idle')
        evidence['screenOffAndIdleFixtureCapture'] = True
        capture(5,5)
        state = wait(lambda s: any(r['phase'] == 'processing' for r in s['recordings']), 'running worker before cancellation')
        cancelled = next(r['id'] for r in state['recordings'] if r['phase'] == 'processing')
        broadcast('cancel-work')
        state = wait(lambda s: not s['busy'] and any(r['id'] == cancelled and r['phase'] == 'queued' for r in s['recordings']), 'cooperative native inference cancellation', seconds=60)
        broadcast('delete','--es','id',cancelled)
        state = wait(lambda s: all(r['id'] != cancelled for r in s['recordings']), 'cancelled job deletion')
        assert not state['busy']
        evidence['nativeInferenceCancellation'] = True
        broadcast('stop')
        state = wait(lambda s: not s['receiverRunning'] and not s['receiverEnabled'],'notification stop')
        print('PASS: credential tamper rejection, idle fixture capture and notification stop',flush=True)
        evidence['notificationStop'] = True
        evidence['limits'] = 'Fixtures enter the real native FGS/storage/worker path. Radio/GATT, Index01 bonding/decoding, OEM battery limits and physical locked operation are unverified.'
        (OUT / 'evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2) + '\n')
        print('Native receiver checks passed.',flush=True)
    finally:
        shell('dumpsys','deviceidle','unforce',check=False); shell('dumpsys','battery','reset',check=False)
        shell('input','keyevent','KEYCODE_WAKEUP',check=False)
        broadcast('stop')

if __name__ == '__main__': main()
