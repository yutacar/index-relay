from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('live', ROOT/'scripts/record-android-live-check.py')
live = importlib.util.module_from_spec(spec); spec.loader.exec_module(live)
D = '10000000-0000-4000-8000-000000000001'
T = '10000000-0000-4000-8000-000000000002'


def state(confirmation=True):
    return dict(previewDiagnostics=True, testTransportActive=False, mockConfigurationPresent=False, receiverEnabled=False, busy=False,
                requiresConfirmation=confirmation, recordings=[], deliveries=[], destinations=[
                    dict(id=D,provider='discord',verified=True,enabled=True,kind='text',identity='private-channel',prefix='<@123> memo',name='private-name',secret='never-export-this'),
                    dict(id=T,provider='telegram',verified=True,enabled=True,kind='group',identity='private-group',prefix='memo',name='private-name',secret='never-export-this')])


def completed(s, confirmation=True, phase='sent'):
    s = deepcopy(s)
    s['recordings'] = [dict(id='recording',phase='done',engine='whisper.cpp 1.9.5 / base / ja',text='private-transcript',simulation=True)]
    s['deliveries'] = [dict(id='job-'+d['id'],recordingID='recording',destinationID=d['id'],provider=d['provider'],
                            confirmationRequired=confirmation,text=d['prefix']+' private-transcript',phase=phase,
                            attempts=0 if phase=='confirmation' else 1,receipt='private-receipt' if phase=='sent' else None) for d in s['destinations']]
    return s


class LiveCheckTests(unittest.TestCase):
    def test_confirmation_requires_before_and_after_approval(self):
        s=state(); session=live.begin(s,[D,T],'confirmation')
        sent=completed(s)
        self.assertFalse(live.observe(session,sent)['apiChecksPassed'])
        session=live.observe(session,completed(s,phase='confirmation'))
        self.assertTrue(session['confirmationObserved'])
        session=live.observe(session,sent)
        self.assertTrue(session['apiChecksPassed'])
        self.assertFalse(live.outcome(session)['allSelectedChecksPassed'])
        session.update(manualArrival='verified',manualMention='verified')
        self.assertTrue(live.outcome(session)['allSelectedChecksPassed'])
        session['manualMention']='failed'
        self.assertFalse(live.outcome(session)['allSelectedChecksPassed'])

    def test_automatic_and_prefix_check(self):
        s=state(False); session=live.begin(s,[D,T],'automatic')
        sent=completed(s,False)
        self.assertTrue(live.observe(session,sent)['apiChecksPassed'])
        sent['deliveries'][0]['text']='wrong-prefix private-transcript'
        with self.assertRaises(live.CheckError): live.observe(session,sent)

    def test_paused_requires_both_checkpoints_and_no_backfill(self):
        s=state()
        for d in s['destinations']: d['enabled']=False
        session=live.begin(s,[D,T],'paused')
        off=completed(s); off['deliveries']=[]
        on=deepcopy(off)
        for d in on['destinations']: d['enabled']=True
        self.assertFalse(live.observe(session,on)['apiChecksPassed'])
        session=live.observe(session,off)
        self.assertFalse(session['apiChecksPassed'])
        self.assertTrue(live.outcome(live.observe(session,on))['allSelectedChecksPassed'])
        on['deliveries']=completed(state())['deliveries']
        with self.assertRaises(live.CheckError): live.observe(session,on)

    def test_mock_transport_and_old_harness_fail_closed(self):
        for value in (True,None):
            s=state(); s['testTransportActive']=value
            with self.assertRaises(live.CheckError): live.begin(s,[D,T],'confirmation')
        s=state(); s['mockConfigurationPresent']=True
        with self.assertRaises(live.CheckError): live.begin(s,[D,T],'confirmation')
        s=state(); del s['previewDiagnostics']
        with self.assertRaises(live.CheckError): live.begin(s,[D,T],'confirmation')

    def test_pending_jobs_and_busy_asr_rejected(self):
        for phase in ('confirmation','sending','unknown','queued','retryWaiting','needsAttention'):
            s=state(); s['deliveries']=[dict(id='old',phase=phase)]
            with self.assertRaises(live.CheckError): live.begin(s,[D,T],'confirmation')
        s=state(); s['recordings']=[dict(id='old',phase='processing')]
        with self.assertRaises(live.CheckError): live.begin(s,[D,T],'confirmation')
        s=state(); s['receiverEnabled']=True
        with self.assertRaises(live.CheckError): live.begin(s,[D,T],'confirmation')

    def test_exact_targets_and_group_only(self):
        with self.assertRaises(live.CheckError): live.begin(state(),[D],'confirmation')
        with self.assertRaises(live.CheckError): live.begin(state(),[D,D],'confirmation')
        for kind in ('private','channel'):
            s=state(); s['destinations'][1]['kind']=kind
            with self.assertRaises(live.CheckError): live.begin(s,[D,T],'confirmation')
        s=state(); s['destinations'][1]['verified']=False
        with self.assertRaises(live.CheckError): live.begin(s,[D,T],'confirmation')

    def test_settings_and_identity_changes_rejected(self):
        with self.assertRaises(live.CheckError): live.begin(state(False),[D,T],'confirmation')
        session=live.begin(state(),[D,T],'confirmation')
        for field in ('identity','prefix'):
            s=completed(state()); s['destinations'][0][field]='changed'
            with self.assertRaises(live.CheckError): live.observe(session,s)

    def test_unexpected_recordings_and_jobs_rejected(self):
        session=live.begin(state(),[D,T],'confirmation')
        s=completed(state()); s['recordings'].append(dict(id='extra',phase='done'))
        with self.assertRaises(live.CheckError): live.observe(session,s)
        s=completed(state()); s['deliveries'][0]['recordingID']='other'
        with self.assertRaises(live.CheckError): live.observe(session,s)
        s=completed(state()); s['deliveries'][0]['destinationID']='other'
        with self.assertRaises(live.CheckError): live.observe(session,s)

    def test_speech_receipt_and_attempt_evidence(self):
        base=state(False); session=live.begin(base,[D,T],'automatic')
        for field,value in (('engine',''),('text',''),('simulation',False)):
            s=completed(base,False); s['recordings'][0][field]=value
            with self.assertRaises(live.CheckError): live.observe(session,s)
        for field,value in (('receipt',None),('attempts',2),('phase','unknown')):
            s=completed(base,False); s['deliveries'][0][field]=value
            self.assertFalse(live.observe(session,s)['apiChecksPassed'])

    def test_evidence_does_not_export_secrets_text_names_or_receipts(self):
        s=state(False); report=live.observe(live.begin(s,[D,T],'automatic'),completed(s,False))
        serialized=json.dumps(report)
        for value in ('never-export-this','private-name','private-channel','private-group','private-transcript','private-receipt','<@123> memo',D,T):
            self.assertNotIn(value,serialized)
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'session.json'; live.save(path,report)
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
            self.assertEqual(json.loads(path.read_text()),report)

    def test_physical_device_rejected_before_adb(self):
        with patch.object(live.subprocess,'run') as run:
            with self.assertRaises(live.CheckError): live.Emulator('physical-device')
            run.assert_not_called()

    def test_observer_never_issues_post_or_mutation_commands(self):
        emulator=object.__new__(live.Emulator); emulator.serial='emulator-5554'
        calls=[]
        def adb(*args,**kw):
            calls.append(args)
            return json.dumps(state()).encode() if args[0]=='exec-out' else b''
        emulator.adb=adb
        emulator.state()
        self.assertEqual(calls,[
            ('shell','run-as',live.PACKAGE,'rm','-f','no_backup/receiver-test-state.json'),
            ('shell','am','broadcast','-n',live.PACKAGE+'/.ReceiverHarnessBroadcast','--es','command','inspect'),
            ('exec-out','run-as',live.PACKAGE,'cat','no_backup/receiver-test-state.json')])


if __name__=='__main__': unittest.main()
