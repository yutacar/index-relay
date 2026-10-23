from copy import deepcopy
from datetime import datetime,timedelta,timezone
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import wave

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('migration',ROOT/'scripts/ios-migration-check.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
RID='a'*64

class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name);self.container=self.base/'snapshot.xcappdata'
        self.root=self.container/'AppData/Library/Application Support'
        for name in ['ReceivedRecordings','Transcripts','AutomaticRelay','Delivery','History']:(self.root/name).mkdir(parents=True)
        self.write('ReceivedRecordings/'+RID+'.json',dict(id=RID,sampleCount=8,sampleRate=9997))
        with wave.open(str(self.root/'ReceivedRecordings'/f'{RID}.wav'),'wb') as w:
            w.setnchannels(1);w.setsampwidth(2);w.setframerate(9997);w.writeframes(b'\0'*16)
        self.write('Transcripts/'+RID+'.json',dict(recordingID=RID,text='private-transcript'))
        self.write('AutomaticRelay/state.json',dict(enabled=False,jobs={RID:dict(phase='done')}))
        self.write('Delivery/state.json',dict(destinations=[dict(enabled=False,name='private-name')],jobs=[dict(phase='sent',messageID='private-receipt',text='private-post')]))
        self.write('History/deletions.json',dict(deletedIDs=[],pendingIDs=[],retentionLimit=30))
    def write(self,path,value):(self.root/path).write_text(json.dumps(value))
    def identities(self):
        bid='test.indexrelay.app';appid='PREFIX1234.'+bid
        info=dict(CFBundleIdentifier=bid,CFBundleVersion='30',UIBackgroundModes=['bluetooth-central','processing'],BGTaskSchedulerPermittedIdentifiers=[bid+'.transcribe',bid+'.delivery.work'],NSBluetoothAlwaysUsageDescription='Bluetooth',CFBundleSupportedPlatforms=['iPhoneOS'])
        ent={'application-identifier':appid,'com.apple.developer.team-identifier':'TEAM123456','keychain-access-groups':[appid]}
        profile=dict(ExpirationDate=datetime.now(timezone.utc)+timedelta(days=1),TeamIdentifier=['TEAM123456'],Entitlements={'application-identifier':'PREFIX1234.*','keychain-access-groups':['PREFIX1234.*']})
        new=deepcopy(info);new['CFBundleVersion']='31'
        return info,new,ent,deepcopy(ent),profile
    def test_inventory_and_roundtrip_do_not_export_private_data(self):
        manifest=m.inventory(self.container)
        self.assertTrue(manifest['summary']['quiescentSnapshot'])
        for value in ('private-transcript','private-name','private-receipt','private-post',RID):self.assertNotIn(value,json.dumps(manifest))
        restored=self.base/'restored.xcappdata';shutil.copytree(self.container,restored)
        self.assertEqual(m.verify(restored,manifest),manifest)
    def test_detects_changed_removed_and_added_files(self):
        manifest=m.inventory(self.container)
        text=self.container/'extra.txt';text.write_text('new')
        with self.assertRaises(m.MigrationError):m.verify(self.container,manifest)
        text.unlink()
        p=self.root/'Transcripts'/f'{RID}.json';p.write_text(json.dumps(dict(recordingID=RID,text='changed')))
        with self.assertRaises(m.MigrationError):m.verify(self.container,manifest)
        p.unlink()
        with self.assertRaises(m.MigrationError):m.verify(self.container,manifest)
    def test_missing_audio_and_truncated_wav_rejected(self):
        p=self.root/'ReceivedRecordings'/f'{RID}.wav'
        original=p.read_bytes();p.unlink()
        with self.assertRaises(m.MigrationError):m.inventory(self.container)
        p.write_bytes(original[:-2])
        with self.assertRaises(m.MigrationError):m.inventory(self.container)
    def test_symlink_cannot_escape_container(self):
        p=self.container/'outside';p.symlink_to(self.base,target_is_directory=True)
        with self.assertRaises(m.MigrationError):m.inventory(self.container)
    def test_busy_or_enabled_state_is_not_quiescent(self):
        self.write('AutomaticRelay/state.json',dict(enabled=True,jobs={RID:dict(phase='processing')}))
        self.write('Delivery/state.json',dict(destinations=[dict(enabled=True)],jobs=[dict(phase='sending')]))
        result=m.inventory(self.container)['summary']
        self.assertFalse(result['quiescentSnapshot']);self.assertFalse(result['keychainIncluded'])
        self.assertFalse(result['osURLSessionTasksIncluded'])
    def test_missing_sections_and_unknown_state_not_treated_as_ready(self):
        shutil.rmtree(self.root/'History')
        self.assertFalse(m.inventory(self.container)['summary']['quiescentSnapshot'])
        self.write('AutomaticRelay/state.json',dict(enabled=False,jobs={RID:dict(phase='other')}))
        with self.assertRaises(m.MigrationError):m.inventory(self.container)
    def test_manifest_is_private_and_not_overwritten(self):
        p=self.base/'manifest.json';m.save(p,{'test':True})
        self.assertEqual(p.stat().st_mode&0o777,0o600)
        with self.assertRaises(m.MigrationError):m.save(p,{'test':False})
        self.assertEqual(json.loads(p.read_text()),{'test':True})
    def test_same_prefix_different_team_and_wildcard_profile(self):
        result=m.compare(*self.identities())
        self.assertTrue(result['artifactChecksPassed'])
        self.assertFalse(result['readyForDeviceUpdate'])
        self.assertFalse(result['deviceProfileMembershipVerified'])
    def test_bundle_prefix_and_team_changes_rejected(self):
        for field in ('application-identifier','com.apple.developer.team-identifier'):
            args=list(self.identities());args[3][field]='changed'
            with self.assertRaises(m.MigrationError):m.compare(*args)
        args=list(self.identities());args[1]['CFBundleIdentifier']='another.app'
        with self.assertRaises(m.MigrationError):m.compare(*args)
    def test_keychain_group_order_and_shared_data_changes_rejected(self):
        args=list(self.identities());args[2]['keychain-access-groups']+=['shared'];args[3]['keychain-access-groups']=['shared',args[3]['application-identifier']]
        with self.assertRaises(m.MigrationError):m.compare(*args)
        args=list(self.identities());args[3]['com.apple.security.application-groups']=['new']
        with self.assertRaises(m.MigrationError):m.compare(*args)
    def test_build_number_must_increase(self):
        self.assertGreater(m.build_number('31'),m.build_number('30.9'))
        for value in ('30','29','bad',None):
            args=list(self.identities());args[1]['CFBundleVersion']=value
            with self.assertRaises(m.MigrationError):m.compare(*args)
    def test_expired_or_mismatched_profile_rejected(self):
        for field,value in [('ExpirationDate',datetime.now(timezone.utc)-timedelta(days=1)),('TeamIdentifier',['other'])]:
            args=list(self.identities());args[4][field]=value
            with self.assertRaises(m.MigrationError):m.compare(*args)
        args=list(self.identities());args[4]['Entitlements']['keychain-access-groups']=['other.*']
        with self.assertRaises(m.MigrationError):m.compare(*args)
    def test_unsigned_identity_and_simulator_not_accepted_as_device(self):
        args=list(self.identities());args[3]={}
        with self.assertRaises(m.MigrationError):m.compare(*args)
        args=list(self.identities());args[1]['CFBundleSupportedPlatforms']=['iPhoneSimulator']
        with self.assertRaises(m.MigrationError):m.compare(*args)
    def test_background_configuration_must_match(self):
        args=list(self.identities());args[1]['BGTaskSchedulerPermittedIdentifiers']=[]
        with self.assertRaises(m.MigrationError):m.compare(*args)

if __name__=='__main__':unittest.main()
