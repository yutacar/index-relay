#!/usr/bin/env python3
"""Synthetic HTTP API + native SQLite/Keystore/WorkManager tests; dedicated ARM64 AVD only."""
import argparse
from collections import defaultdict, deque
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import subprocess
import threading
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'dev.example.index_relay_probe'
OUT = ROOT / 'work/android-delivery-tests'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='emulator-5554')
    parser.add_argument('--network-recovery-check', action='store_true', help='Own AVD only: toggle airplane mode and validate real WorkManager network constraints')
    parser.add_argument('--skip-speech-check', action='store_true', help='CI uses completed-text fixtures; does not verify ASR')
    parser.add_argument('--reset-test-data', action='store_true', required=True)
    args = parser.parse_args()
    if not args.device.startswith('emulator-'): raise SystemExit('Dedicated emulator required')
    OUT.mkdir(parents=True, exist_ok=True)
    requests = []; plans = defaultdict(deque); targets = {'111': '100', '222': '100', '333': '300'}
    chats = {'-1001': 'supergroup','-2': 'group','-3': 'private','-4': 'channel'}
    held = threading.Event(); arrived = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *unused): pass
        def do_GET(self): self.route()
        def do_POST(self): self.route()
        def response(self, code, value):
            payload = json.dumps(value).encode()
            self.send_response(code); self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(payload))); self.end_headers()
            try: self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError): pass
        def route(self):
            path = urlsplit(self.path).path
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}')
            if path.startswith('/discord/'):
                key = path.split('/')[-2]
                if self.command == 'GET':
                    if key == '444':
                        self.send_response(302); self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/redirect-trap'); self.end_headers(); return
                    self.response(200,dict(type=1,channel_id=targets[key],guild_id='9')); return
                provider = 'discord'; target = targets[key]
            elif path.endswith('/getMe'):
                self.response(200,dict(ok=True,result=dict(id=5,is_bot=True))); return
            elif path.endswith('/getChat'):
                target = str(body['chat_id']); self.response(200,dict(ok=True,result=dict(id=int(target),type=chats[target]))); return
            elif path.endswith('/sendMessage'):
                provider = 'telegram'; target = str(body['chat_id'])
            else:
                requests.append(dict(trap=True)); self.response(500,{}); return
            requests.append(dict(provider=provider,target=target,path=self.path,body=body,time=time.monotonic()))
            action = plans[(provider,target)].popleft() if plans[(provider,target)] else 'sent'
            if action == 'drop': self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
            if action == 'hold': arrived.set(); held.wait(20)
            if action == '429': self.response(429,{'retry_after':4,'parameters':{'retry_after':4}}); return
            if action == '500': self.response(500,{}); return
            if action == 'migrate': self.response(400,dict(ok=False,error_code=400,parameters=dict(migrate_to_chat_id=-10099))); return
            if action == 'redirect':
                self.send_response(302); self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/redirect-trap'); self.end_headers(); return
            self.response(200,dict(id=str(10000+len(requests))) if provider == 'discord' else dict(ok=True,result=dict(message_id=10000+len(requests))))

    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    port = server.server_port
    def adb(*parts, binary=False, check=True):
        completed = subprocess.run(['adb','-s',args.device,*map(str,parts)],capture_output=True,check=check,timeout=90)
        return completed.stdout if binary else completed.stdout.decode().strip()
    def shell(*parts, **kw): return adb('shell',*parts,**kw)
    def read(path): return adb('exec-out','run-as',PACKAGE,'cat',path,binary=True,check=False)
    def put(value,path):
        file = OUT / 'input.json'; file.write_text(value if isinstance(value,str) else json.dumps(value,ensure_ascii=False))
        remote = '/data/local/tmp/relay-delivery-input'
        adb('push',file,remote); shell('chmod','644',remote); shell('run-as',PACKAGE,'cp',remote,path); shell('rm',remote)
    def broadcast(command): shell('am','broadcast','-n',PACKAGE+'/.ReceiverHarnessBroadcast','--es','command',command)
    def state():
        shell('run-as',PACKAGE,'rm','-f','no_backup/receiver-test-state.json'); broadcast('inspect')
        end = time.monotonic()+10
        while time.monotonic()<end:
            raw = read('no_backup/receiver-test-state.json')
            if raw: return json.loads(raw)
            time.sleep(.1)
        raise AssertionError('State not available')
    def command(method, payload=None, ok=True):
        put({'method':method,'args':payload or {}},'no_backup/delivery-harness-input.json')
        shell('run-as',PACKAGE,'rm','-f','no_backup/delivery-harness-result.json'); broadcast('delivery')
        end = time.monotonic()+45
        while time.monotonic()<end:
            raw = read('no_backup/delivery-harness-result.json')
            if raw:
                result = json.loads(raw); assert result['ok'] == ok, (method,result); return result
            time.sleep(.1)
        raise AssertionError('Command timed out: '+method)
    def wait(predicate, label, seconds=100):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            value=state()
            if predicate(value): return value
            time.sleep(.3)
        raise AssertionError('Timed out: '+label)
    counter = 0
    def transcript(text='試験の文字起こし <@999> @everyone'):
        nonlocal counter
        counter += 1; id=hashlib.sha256(f'fixture-{counter}'.encode()).hexdigest()
        command('completedText',{'id':id,'text':text}); return id
    def jobs(id): return [j for j in state()['deliveries'] if j['recordingID']==id]
    def phase(id, expected): return wait(lambda s: any(j['id']==id and j['phase']==expected for j in s['deliveries']),expected)
    def destination(id, **overrides):
        base=dict(id=id,name='試験Discord',provider='discord',prefix='<@123> メモ',targetHint='',secret='',enabled=True)
        base.update(overrides); command('saveConnectedDestination',base); return next(d for d in state()['destinations'] if d['id']==id)
    def toggle(id,on): command('toggleDestination',{'id':id,'enabled':on})
    def by_job(id): return next(j for j in state()['deliveries'] if j['id']==id)
    def pidkill():
        pid=shell('pidof',PACKAGE).split()[0]; shell('run-as',PACKAGE,'kill','-9',pid)
        shell('am','start','-W','-n',PACKAGE+'/.ReceiverHarnessActivity')
        wait(lambda s:s['receiverRunning'],'restart')

    assert shell('getprop','ro.kernel.qemu')=='1' and shell('getprop','ro.product.cpu.abi') in ('arm64-v8a','x86_64')
    assert int(shell('getprop','ro.build.version.sdk'))>=33
    adb('install','-r',ROOT/'flutter_probe/build/app/outputs/flutter-apk/app-preview-debug.apk')
    shell('am','force-stop',PACKAGE); assert 'Success' in shell('pm','clear',PACKAGE)
    adb('reverse',f'tcp:{port}',f'tcp:{port}')
    for perm in ('BLUETOOTH_SCAN','BLUETOOTH_CONNECT','POST_NOTIFICATIONS'): shell('pm','grant',PACKAGE,'android.permission.'+perm)
    shell('run-as',PACKAGE,'mkdir','-p','no_backup')
    put(str(port),'no_backup/delivery-harness-port')
    shell('am','start','-W','-n',PACKAGE+'/.ReceiverHarnessActivity')
    wait(lambda s:s['receiverRunning'],'start')
    evidence={'synthetic':True,'emulatorAPI':int(shell('getprop','ro.build.version.sdk')),'externalPostsPerformed':False,'physicalBLEVerified':False}
    try:
        baseline=transcript('登録前の文章')
        d='10000000-0000-4000-8000-000000000001'; t='10000000-0000-4000-8000-000000000002'
        destination(d,secret='https://discord.com/api/webhooks/111/fake-a')
        destination(t,name='試験Telegram',provider='telegram',prefix='メモ',targetHint='-1001',secret='5:fake-token')
        assert jobs(baseline)==[] and requests==[]
        for chat in ('-3','-4'):
            command('saveConnectedDestination',dict(name='対象外',provider='telegram',prefix='',targetHint=chat,secret='5:fake-token'),ok=False)
        command('saveConnectedDestination',dict(name='重複',provider='discord',prefix='',secret='https://discord.com/api/webhooks/222/fake-b'),ok=False)
        destination_id_before=[v['identity'] for v in state()['destinations']]
        command('saveConnectedDestination',dict(id=d,name='変更',provider='discord',prefix='',secret='https://discord.com/api/webhooks/333/fake-c'),ok=False)
        assert [v['identity'] for v in state()['destinations']]==destination_id_before
        command('saveConnectedDestination',dict(name='転送',provider='discord',prefix='',secret='https://discord.com/api/webhooks/444/fake-d'),ok=False)
        assert not any(r.get('trap') for r in requests)
        evidence['validationAndIdentityGuards']=True
        print('PASS: validationAndIdentityGuards',flush=True)
        # One genuine ASR completion, not a fixed recognized-text fixture.
        if args.skip_speech_check: transcript('CI completed-text fixture; not recognized speech')
        else: shell('am','broadcast','-n',PACKAGE+'/.ReceiverHarnessBroadcast','--es','command','capture','--ei','start','1','--ei','end','1')
        wait(lambda s:len(s['deliveries'])==2,'real ASR routing')
        initial=state()['deliveries']; assert all(j['phase']=='confirmation' for j in initial) and not requests
        command('saveSettings',dict(historyLimit=200,requiresConfirmation=False)); assert all(j['phase']=='confirmation' for j in state()['deliveries'])
        for job in initial: command('approveDelivery',{'id':job['id'],'text':job['text']}); phase(job['id'],'sent')
        assert len(requests)==2
        discord=next(r for r in requests if r['provider']=='discord'); telegram=next(r for r in requests if r['provider']=='telegram')
        assert discord['path'].endswith('?wait=true') and discord['body']['content'].startswith('<@123> メモ ')
        assert discord['body']['allowed_mentions']==dict(parse=[],users=['123'],roles=[])
        assert 'parse_mode' not in telegram['body'] and telegram['body']['text'].startswith('メモ ')
        assert all(j['receipt'] for j in state()['deliveries'])
        evidence['realTranscriptionMultipleDestinationsAndConfirmation']=not args.skip_speech_check
        evidence['syntheticTextMultipleDestinationsAndConfirmation']=args.skip_speech_check
        print('PASS: multiple destinations and confirmation; speech verified='+str(not args.skip_speech_check),flush=True)
        # Paused routing is not backfilled, credential replacement uses current key for queued jobs.
        toggle(t,False); toggle(d,False); off=transcript(); assert jobs(off)==[]
        toggle(d,True); command('saveSettings',dict(historyLimit=200,requiresConfirmation=True))
        frozen=transcript(); job=jobs(frozen)[0]; toggle(d,False)
        command('approveDelivery',dict(id=job['id'],text=job['text']))
        destination(d,secret='https://discord.com/api/webhooks/222/fake-b',prefix='<@&456> 新',enabled=False)
        assert by_job(job['id'])['text'].startswith('<@123> メモ ')
        before=len(requests); time.sleep(.5); assert len(requests)==before
        toggle(d,True); phase(job['id'],'sent')
        assert '/222/fake-b' in requests[-1]['path'] and requests[-1]['body']['allowed_mentions']['users']==['123']
        assert jobs(off)==[]
        evidence['pauseSnapshotsAndCredentialRotation']=True
        print('PASS: pauseSnapshotsAndCredentialRotation',flush=True)
        # Long text stays actionable; manual shortened text can be approved.
        long=transcript('a'*2001); j=jobs(long)[0]; assert j['phase']=='needsAttention'
        command('approveDelivery',dict(id=j['id'],text='短く編集 <@999>')); phase(j['id'],'sent')
        assert requests[-1]['body']['allowed_mentions']==dict(parse=[],users=[],roles=['456'])
        evidence['lengthAndMentionSafety']=True
        print('PASS: lengthAndMentionSafety',flush=True)
        command('saveSettings',dict(historyLimit=200,requiresConfirmation=False))
        plans[('discord','100')].append('drop'); unknown=transcript(); j=jobs(unknown)[0]; phase(j['id'],'unknown')
        count=len(requests); pidkill(); time.sleep(1); assert by_job(j['id'])['phase']=='unknown' and len(requests)==count
        command('retryDelivery',dict(id=j['id']),ok=False)
        command('retryDelivery',dict(id=j['id'],allowUnknown=True)); phase(j['id'],'sent'); assert len(requests)==count+1
        plans[('discord','100')].append('500'); failed=transcript(); j=jobs(failed)[0]; phase(j['id'],'unknown')
        command('dismissUnknown',dict(id=j['id'])); assert by_job(j['id'])['phase']=='cancelled'
        held.clear(); arrived.clear(); plans[('discord','100')].append('hold')
        interrupted=transcript(); recovering=jobs(interrupted)[0]; assert arrived.wait(10)
        count=len(requests); pidkill(); phase(recovering['id'],'unknown'); held.set()
        time.sleep(.5); assert len(requests)==count
        command('dismissUnknown',dict(id=recovering['id']))
        evidence['interruptedSendingRecoversUnknown']=True
        evidence['ambiguousFailureAndRestartNoAutomaticReplay']=True
        print('PASS: ambiguousFailureAndRestartNoAutomaticReplay',flush=True)
        plans[('discord','100')].append('429'); rate=transcript(); j=jobs(rate)[0]; phase(j['id'],'retryWaiting')
        first_request=requests[-1]; second=transcript(); other=jobs(second)[0]
        command('retryDelivery',dict(id=j['id']),ok=False)
        phase(j['id'],'sent'); phase(other['id'],'sent')
        subsequent=[r for r in requests if r['time']>first_request['time']]
        assert subsequent and all(r['time']-first_request['time']>=3.8 for r in subsequent)
        evidence['rateLimitProviderCooldown']=True
        print('PASS: rateLimitProviderCooldown',flush=True)
        plans[('discord','100')].append('429'); cancelled_rate=transcript(); cancel_job=jobs(cancelled_rate)[0]; phase(cancel_job['id'],'retryWaiting')
        last_rate=requests[-1]; command('cancelDelivery',dict(id=cancel_job['id']))
        after_cancel=transcript(); waiting_job=jobs(after_cancel)[0]; phase(waiting_job['id'],'sent')
        assert requests[-1]['time']-last_rate['time']>=3.8
        evidence['cooldownSurvivesCancelledJob']=True
        plans[('discord','100')].extend(['429']*5)
        budget=transcript(); budget_job=jobs(budget)[0]; phase(budget_job['id'],'needsAttention')
        assert by_job(budget_job['id'])['attempts']==5
        command('cancelDelivery',dict(id=budget_job['id']))
        evidence['automaticRetryBudget']=True
        # Telegram migration is informative only and never changes the destination.
        toggle(d,False); toggle(t,True); plans[('telegram','-1001')].append('migrate')
        migrated=transcript(); j=jobs(migrated)[0]; phase(j['id'],'needsAttention')
        assert '-10099' in by_job(j['id'])['detail']
        assert next(v for v in state()['destinations'] if v['id']==t)['targetHint']=='-1001'
        command('deleteDestination',{'id':t},ok=False); command('cancelDelivery',{'id':j['id']})
        toggle(t,False); toggle(d,True)
        evidence['telegramMigrationRequiresNewDestination']=True
        print('PASS: telegramMigrationRequiresNewDestination',flush=True)
        # Disconnect after server receives a POST, then delete while that request is held.
        held.clear(); arrived.clear(); plans[('discord','100')].append('hold'); removed=transcript(); j=jobs(removed)[0]
        assert arrived.wait(10); command('deleteRecordings',{'ids':[removed]}); held.set(); time.sleep(1)
        assert jobs(removed)==[] and all(r['id']!=removed for r in state()['recordings'])
        evidence['inflightDeletionDoesNotResurrect']=True
        print('PASS: inflightDeletionDoesNotResurrect',flush=True)
        plans[('discord','100')].append('redirect'); redirect=transcript(); j=jobs(redirect)[0]; phase(j['id'],'needsAttention')
        assert not any(r.get('trap') for r in requests)
        evidence['redirectsNotFollowed']=True
        print('PASS: redirectsNotFollowed',flush=True)
        # Credentials never appear in Dart-facing snapshots or plaintext DB.
        snapshot=json.dumps(state()); db=read('no_backup/relay/relay.db')
        assert 'fake-b' not in snapshot and 'fake-token' not in snapshot and b'fake-b' not in db and b'fake-token' not in db
        assert all('credentialKey' not in v for v in state()['destinations'])
        evidence['credentialsExcludedFromSnapshotsAndSQLite']=True
        if args.network_recovery_check:
            # Local HTTP still goes through production CONNECTED constraints in this mode.
            put('required','no_backup/delivery-harness-network-required'); pidkill()
            assert state()['mockNetworkRequired']
            shell('cmd','connectivity','airplane-mode','enable')
            shell('svc','wifi','disable'); shell('svc','data','disable')
            wait(lambda s:not s['capabilities']['network'],'offline network')
            toggle(t,True)
            before=len(requests); offline=transcript('機内モード中の合成試験文')
            pending=jobs(offline); assert len(pending)==2
            assert all(j['phase']=='queued' and j['attempts']==0 for j in pending)
            pidkill(); time.sleep(2)
            assert len(requests)==before and all(j['phase']=='queued' and j['attempts']==0 for j in jobs(offline))
            shell('cmd','connectivity','airplane-mode','disable'); shell('svc','wifi','enable')
            wait(lambda s:s['capabilities']['network'],'network validation',seconds=120)
            for job in pending: phase(job['id'],'sent')
            assert len(requests)==before+2 and all(j['attempts']==1 for j in jobs(offline))
            pidkill(); time.sleep(2); assert len(requests)==before+2
            evidence['networkFixturesUseCompletedText']=True
            evidence['airplaneModePersistsUnsentAcrossRestart']=True
            evidence['networkRecoveryDeliversBothTargetsOnce']=True
            toggle(t,False)
            shell('run-as',PACKAGE,'rm','no_backup/delivery-harness-network-required'); pidkill()
            assert not state()['mockNetworkRequired']
            print('PASS: airplane mode, offline restart and automatic recovery without duplicates',flush=True)
        # A refused TCP connection before any body write is safe to retry.
        unused=socket.socket(); unused.bind(('127.0.0.1',0)); closed_port=unused.getsockname()[1]; unused.close()
        # No adb tunnel: connection must be refused on the emulator itself before a body write.
        put(str(closed_port),'no_backup/delivery-harness-port'); pidkill()
        preconnection=transcript(); pending=jobs(preconnection)[0]; phase(pending['id'],'retryWaiting')
        assert by_job(pending['id'])['retryAfter']>int(time.time()*1000)
        before=len(requests)
        put(str(port),'no_backup/delivery-harness-port'); pidkill()
        phase(pending['id'],'sent')
        assert len(requests)==before+1 and by_job(pending['id'])['attempts']==2
        pidkill(); time.sleep(1); assert len(requests)==before+1
        evidence['preconnectionFailureRecoversOnceAfterRestart']=True
        adb('reverse','--remove',f'tcp:{closed_port}',check=False)
        evidence['definitePreconnectionFailureWaitsForRetry']=True
        (OUT/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
        print('PASS: validation, identity, native ASR, confirmation, multiple targets, snapshots, token rotation, limits, unknown, restart, 429, migration, deletion and redirects',flush=True)
    finally:
        if args.network_recovery_check:
            shell('cmd','connectivity','airplane-mode','disable',check=False)
            shell('svc','wifi','enable',check=False)
        held.set(); broadcast('stop'); shell('am','force-stop',PACKAGE)
        adb('reverse','--remove',f'tcp:{port}',check=False); server.shutdown(); server.server_close()

if __name__=='__main__': main()
