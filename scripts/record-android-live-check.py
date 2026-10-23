#!/usr/bin/env python3
"""Record Android live-post checks without sending, approving, retrying or exporting secrets."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'dev.example.index_relay_probe'
CASES = ('confirmation', 'automatic', 'paused')
TERMINAL = ('sent', 'cancelled')


class CheckError(Exception):
    pass


def key(value):
    return hashlib.sha256(str(value).encode()).hexdigest()


def now():
    return datetime.now(timezone.utc).isoformat()


def guard(state):
    if state.get('previewDiagnostics') is not True or state.get('testTransportActive') is not False or state.get('mockConfigurationPresent') is not False:
        raise CheckError('更新したpreviewDebugが必要です。模擬APIの差し替えがないことも確認してください。')
    if state.get('receiverEnabled'):
        raise CheckError('リング自動受信を停止してください。実送信試験では設定の模擬受信を使います。')


def targets(state, ids):
    selected = [d for d in state['destinations'] if d['id'] in ids]
    if not ids or len(selected) != len(ids) or len(set(ids)) != len(ids):
        raise CheckError('登録した試験用送り先のIDを重複なく指定してください。')
    for d in selected:
        if not d.get('verified') or d.get('provider') not in ('discord', 'telegram'):
            raise CheckError('送り先のAPI照合を済ませてください。')
        if d['provider'] == 'telegram' and d.get('kind') not in ('group', 'supergroup'):
            raise CheckError('Telegramはグループだけを試験できます。')
    return selected


def begin(state, ids, case):
    guard(state)
    if case not in CASES:
        raise CheckError('試験ケースが不正です。')
    selected = targets(state, ids)
    if state.get('busy') or any(r['phase'] in ('queued', 'processing') for r in state['recordings']):
        raise CheckError('処理中の音声がなくなってから開始してください。')
    if any(j['phase'] not in TERMINAL for j in state['deliveries']):
        raise CheckError('未完了の投稿があります。アプリの送信一覧で確認してください。')
    enabled = {d['id'] for d in state['destinations'] if d.get('enabled')}
    if enabled != (set() if case == 'paused' else set(ids)):
        raise CheckError('有効な送り先を、今回指定した試験先だけにしてください。停止試験では全件オフです。')
    if case != 'paused' and state['requiresConfirmation'] != (case == 'confirmation'):
        raise CheckError('アプリの「送信前に確認する」を試験ケースに合わせてください。')
    return {
        'schema': 1, 'session': str(uuid.uuid4()), 'case': case, 'startedAt': now(),
        'destinations': [dict(key=key(d['id']), provider=d['provider'], identityKey=key(d['identity']),
                              prefixKey=key(d['prefix']), mentionExpected=d['provider'] == 'discord' and
                              re.search(r'<@!?\d+>|<@&\d+>', d['prefix']) is not None) for d in selected],
        'baselineRecordingKeys': [key(r['id']) for r in state['recordings']],
        'baselineJobKeys': [key(j['id']) for j in state['deliveries']],
        'confirmationObserved': False, 'pausedObserved': False, 'reenabledWithoutBackfill': False,
        'apiChecksPassed': False, 'manualArrival': 'unverified', 'manualMention': 'unverified',
        'credentialsExported': False, 'contentExported': False, 'physicalBLEVerified': False,
    }


def observe(session, state):
    guard(state)
    result = dict(session)
    wanted = {d['key']: d for d in session['destinations']}
    current = {key(d['id']): d for d in state['destinations']}
    for k, expected in wanted.items():
        d = current.get(k)
        if not d or not d.get('verified') or key(d['identity']) != expected['identityKey'] or key(d['prefix']) != expected['prefixKey']:
            raise CheckError('送り先または接頭語が変わりました。新しい試験セッションを開始してください。')
    recordings = [r for r in state['recordings'] if key(r['id']) not in session['baselineRecordingKeys']]
    if len(recordings) != 1:
        raise CheckError('開始後に模擬受信を1件だけ実行してください。複数件ある場合は新しいセッションが必要です。')
    recording = recordings[0]
    recording_key = key(recording['id'])
    if session.get('recordingKey', recording_key) != recording_key:
        raise CheckError('観測中の録音が変わりました。')
    if recording['phase'] != 'done' or recording.get('engine') != 'whisper.cpp 1.9.5 / base / ja' or not recording.get('text', '').strip() or recording.get('simulation') is not True:
        raise CheckError('模擬音声の端末内Whisper認識が完了するまで待ってください。')
    jobs = [j for j in state['deliveries'] if key(j['id']) not in session['baselineJobKeys']]
    if any(j['recordingID'] != recording['id'] for j in jobs):
        raise CheckError('別の録音の投稿が混在しています。試験を分けてください。')
    enabled = {key(d['id']) for d in state['destinations'] if d.get('enabled')}
    result.update(recordingKey=recording_key, observedAt=now(), localSpeechRecognitionVerified=True)
    if session['case'] == 'paused':
        if jobs or enabled not in (set(), set(wanted)):
            raise CheckError('停止試験で投稿ジョブまたは対象外の有効な送り先が見つかりました。')
        if not enabled:
            result['pausedObserved'] = True
        elif session['pausedObserved']:
            result['reenabledWithoutBackfill'] = True
        result['apiChecksPassed'] = result['pausedObserved'] and result['reenabledWithoutBackfill']
        result['jobs'] = []
        return result
    if enabled != set(wanted) or len(jobs) != len(wanted) or {key(j['destinationID']) for j in jobs} != set(wanted):
        raise CheckError('指定した試験先と投稿ジョブが一致しません。')
    summary = []
    for job in jobs:
        d = current[key(job['destinationID'])]
        body = (d['prefix'].strip() + ' ' if d['prefix'].strip() else '') + recording['text']
        if job['text'] != body or bool(job['confirmationRequired']) != (session['case'] == 'confirmation'):
            raise CheckError('本文の接頭語または確認設定が一致しません。')
        summary.append(dict(key=key(job['id']), destinationKey=key(job['destinationID']), provider=job['provider'],
                            phase=job['phase'], attempts=job['attempts'], receiptPresent=bool(job.get('receipt')),
                            prefixJoinedCorrectly=True))
    if all(j['phase'] == 'confirmation' and j['attempts'] == 0 and not j.get('receipt') for j in jobs):
        result['confirmationObserved'] = True
    result['jobs'] = summary
    result['apiChecksPassed'] = all(j['phase'] == 'sent' and j['attempts'] == 1 and j.get('receipt') for j in jobs) and (
        session['case'] == 'automatic' or result['confirmationObserved'])
    return result


def outcome(session):
    mention_needed = any(d['mentionExpected'] for d in session['destinations'])
    manual_ok = session['case'] == 'paused' or (session['manualArrival'] == 'verified' and (
        not mention_needed or session['manualMention'] == 'verified'))
    return dict(case=session['case'], apiChecksPassed=session['apiChecksPassed'],
                manualArrival=session['manualArrival'], manualMention=session['manualMention'],
                allSelectedChecksPassed=session['apiChecksPassed'] and manual_ok)


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False, encoding='utf-8') as f:
        temp = Path(f.name)
        json.dump(value, f, ensure_ascii=False, indent=2); f.write('\n')
    try:
        os.chmod(temp, 0o600); os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


class Emulator:
    def __init__(self, serial):
        if not re.fullmatch(r'emulator-\d+', serial):
            raise CheckError('専用エミュレーターだけを使用できます。')
        self.serial = serial
        if self.adb('shell', 'getprop', 'ro.kernel.qemu').strip() != b'1':
            raise CheckError('専用エミュレーターを確認できません。')
        if not self.adb('shell', 'pidof', PACKAGE).strip():
            raise CheckError('更新した確認用アプリを開いてください。')

    def adb(self, *args, check=True):
        p = subprocess.run(['adb', '-s', self.serial, *args], capture_output=True, timeout=30)
        if check and p.returncode:
            raise CheckError('ADB操作が完了しません。端末接続と確認用アプリを確認してください。')
        return p.stdout

    def state(self):
        # Does not send delivery commands or alter app settings. Existing app work continues.
        self.adb('shell', 'run-as', PACKAGE, 'rm', '-f', 'no_backup/receiver-test-state.json')
        self.adb('shell', 'am', 'broadcast', '-n', PACKAGE + '/.ReceiverHarnessBroadcast', '--es', 'command', 'inspect')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            raw = self.adb('exec-out', 'run-as', PACKAGE, 'cat', 'no_backup/receiver-test-state.json', check=False)
            if raw:
                try:
                    state = json.loads(raw); guard(state); return state
                except json.JSONDecodeError:
                    pass
            time.sleep(.2)
        raise CheckError('診断情報を取得できません。更新したpreviewDebugを使用してください。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='emulator-5556')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('status')
    start = sub.add_parser('begin')
    start.add_argument('--case', choices=CASES, required=True)
    start.add_argument('--destination-id', action='append', required=True)
    start.add_argument('--session', type=Path, required=True)
    for name in ('observe', 'attest'):
        p = sub.add_parser(name); p.add_argument('--session', type=Path, required=True)
        if name == 'attest':
            p.add_argument('--arrival', choices=('verified', 'failed', 'unverified'), required=True)
            p.add_argument('--mention', choices=('verified', 'failed', 'unverified'), default='unverified')
    args = parser.parse_args()
    try:
        if args.command == 'attest':
            session = json.loads(args.session.read_text())
            if session['case'] == 'paused' or not session['apiChecksPassed']:
                raise CheckError('API受領が確認された投稿ケースだけに、手動の到着確認を記録できます。')
            session.update(manualArrival=args.arrival, manualMention=args.mention, manualObservedAt=now())
        else:
            state = Emulator(args.device).state()
            if args.command == 'status':
                print(json.dumps(dict(destinations=[{k: d[k] for k in ('id', 'provider', 'enabled', 'verified', 'kind')} for d in state['destinations']],
                                      requiresConfirmation=state['requiresConfirmation'],
                                      unfinishedJobs=sum(j['phase'] not in TERMINAL for j in state['deliveries'])), ensure_ascii=False, indent=2))
                return
            if args.command == 'begin':
                for value in args.destination_id: uuid.UUID(value)
                if args.session.exists(): raise CheckError('既存のセッションは上書きしません。別の保存先を指定してください。')
                session = begin(state, args.destination_id, args.case)
            else:
                session = observe(json.loads(args.session.read_text()), state)
        save(args.session, session)
        print(json.dumps(outcome(session), ensure_ascii=False, indent=2))
    except (CheckError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, (str(error) if isinstance(error, CheckError) else '確認を完了できません。入力・セッション・接続を確認してください。') + '\n')


if __name__ == '__main__':
    main()
