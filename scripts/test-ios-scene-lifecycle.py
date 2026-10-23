#!/usr/bin/env python3
"""Three cold starts and real background/resume transitions on a NEW synthetic simulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'dev.example.indexRelayProbe'

def run(*args, **kw):
    return subprocess.run(list(map(str, args)), check=True, text=True, **kw)
def capture(*args):
    return run(*args, capture_output=True).stdout.strip()
def wait_for(read, predicate):
    deadline = time.monotonic() + 75
    while True:
        try:
            value = read()
            if predicate(value): return value
        except (FileNotFoundError, json.JSONDecodeError): pass
        if time.monotonic() > deadline: raise RuntimeError('Scene lifecycle evidence did not arrive')
        time.sleep(.25)
def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for folder in ['ReceivedRecordings', 'Transcripts'] for p in (root / folder).glob('*') if p.is_file()}
def require_unlocked():
    state = capture('ioreg', '-n', 'Root', '-d1', '-l')
    if re.search(r'"CGSSessionScreenIsLocked"\s*=\s*(Yes|true)', state):
        raise RuntimeError('Unlock the Mac before Simulator UI lifecycle testing')
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-app', type=Path, required=True)
    parser.add_argument('--flutter-app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--expect-normal-after-first', action='store_true')
    parser.add_argument('--xctest-ui', action='store_true', help='Use isolated XCTest Home/activate automation')
    parser.add_argument('--legacy-ui-fixture', type=Path, help='Additional obsolete-scene stress case; not a clean native-only upgrade')
    parser.add_argument('--background-via-home', action='store_true', help='Wait for the operator to press Simulator Home on each cold start')
    args = parser.parse_args()
    if args.xctest_ui: require_unlocked()
    for app in [args.native_app, args.flutter_app]:
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        assert info['CFBundleSupportedPlatforms'] == ['iPhoneSimulator'] and info['CFBundleIdentifier'] == BUNDLE
    native_info = plistlib.loads((args.native_app / 'Info.plist').read_bytes())
    assert native_info['CFBundleShortVersionString'] == '0.9.7'
    runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
    device = capture('xcrun','simctl','create','IndexRelay disposable lifecycle','com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',runtime)
    print('Created disposable simulator:', device, flush=True)
    try:
        run('xcrun','simctl','boot',device); run('xcrun','simctl','bootstatus',device,'-b')
        def support():
            return Path(capture('xcrun','simctl','get_app_container',device,BUNDLE,'data')) / 'Library/Application Support'
        if args.legacy_ui_fixture:
            info = plistlib.loads((args.legacy_ui_fixture / 'Info.plist').read_bytes())
            assert info['CFBundleSupportedPlatforms'] == ['iPhoneSimulator'] and info['CFBundleIdentifier'] == BUNDLE
            run('xcrun','simctl','install',device,args.legacy_ui_fixture)
            run('xcrun','simctl','launch',device,BUNDLE)
            wait_for(lambda: (support() / 'upgrade-fixture-ready.txt').exists(), bool)
            run('xcrun','simctl','terminate',device,BUNDLE)
        run('xcrun','simctl','install',device,args.native_app)
        run('xcrun','simctl','launch',device,BUNDLE)
        root = support()
        wait_for(lambda: (root / 'AutomaticRelay/state.json').exists(), bool)
        run('xcrun','simctl','terminate',device,BUNDLE)
        # Default: inject data without another UI fixture. The optional fixture deliberately
        # stresses restoration of older scene configurations and is reported separately.
        rid = 'a' * 64
        audio = root / 'ReceivedRecordings'; audio.mkdir(exist_ok=True)
        transcripts = root / 'Transcripts'; transcripts.mkdir(exist_ok=True)
        with wave.open(str(audio / (rid+'.wav')), 'wb') as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
            stream.writeframes(bytes(32000))
        (audio / (rid+'.json')).write_text(json.dumps(dict(id=rid,receivedAt=800000000,sampleRate=16000,sampleCount=16000,collectionIndex=7,contiguous=True,transfer=None)))
        (transcripts / (rid+'.json')).write_text(json.dumps(dict(recordingID=rid,text='Synthetic lifecycle fixture',createdAt=800000000,locale='ja-JP',engine='Apple SpeechAnalyzer / SpeechTranscriber',audioProcessing='adaptive-30hz-v1')))
        original = hashes(root)
        run('xcrun','simctl','launch',device,BUNDLE)
        wait_for(lambda: json.loads((root / 'AutomaticRelay/state.json').read_text()),lambda q: q['jobs'].get(rid,{}).get('phase')=='done' and not q['enabled'])
        run('xcrun','simctl','terminate',device,BUNDLE)
        run('xcrun','simctl','install',device,args.flutter_app)
        root = support(); env = dict(os.environ, SIMCTL_CHILD_INDEX_RELAY_SCENE_PROBE='1')
        def rows(): return json.loads((root / 'scene-probe.json').read_text())
        results=[]
        if args.xctest_ui:
            require_unlocked()
            run('python3', ROOT / 'scripts/prepare-ios-lifecycle-ui.py')
            run('xcodebuild','-project', ROOT / 'work/ios-scene-ui/Lifecycle.xcodeproj',
                '-scheme','Lifecycle','-destination','id='+device,
                '-derivedDataPath',ROOT / 'work/ios-scene-ui/build',
                '-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','test',timeout=600)
            require_unlocked()
            assert {x['launch'] for x in rows()} == {1,2,3}, 'Unexpected process restart during resume'
            for boot in [1,2,3]:
                own=[x for x in rows() if x['launch']==boot]
                for event in ['dart-uiReady','dart-paused','dart-resumed','native-background']:
                    assert any(x['event']==event for x in own), (boot,event,own)
                assert max(i for i,x in enumerate(own) if x['event']=='dart-resumed') > max(i for i,x in enumerate(own) if x['event']=='dart-paused'), own
                adopted=any(x['event']=='adopted' for x in own)
                normal=any(x['event']=='connected' and x['configuration']=='flutter' for x in own)
                if args.expect_normal_after_first and boot>1: assert normal and not adopted, own
                results.append(dict(coldStart=boot,legacySceneAdopted=adopted,
                                    sceneDelegateConnected=any(x['event']=='connected' for x in own),
                                    normalFlutterSceneConnected=normal,dartPausedObserved=True,dartResumedCallbackObserved=True))
        else:
            for boot in [1,2,3]:
                run('xcrun','simctl','launch',device,BUNDLE,env=env)
                wait_for(rows, lambda r: any(x['launch']==boot and x['event']=='dart-uiReady' for x in r))
                before = sum(x['launch']==boot and x['event']=='dart-resumed' for x in rows())
                if args.background_via_home:
                    print('Simulator Home action required for cold start', boot, flush=True)
                else:
                    run('xcrun','simctl','launch',device,'com.apple.Preferences')
                wait_for(rows,lambda r: any(x['launch']==boot and x['event']=='dart-paused' for x in r))
                run('xcrun','simctl','launch',device,BUNDLE,env=env)
                wait_for(rows,lambda r: sum(x['launch']==boot and x['event']=='dart-resumed' for x in r)>before)
                own=[x for x in rows() if x['launch']==boot]
                adopted=any(x['event']=='adopted' for x in own)
                normal=any(x['event']=='connected' and x['configuration']=='flutter' for x in own)
                if args.expect_normal_after_first and boot>1: assert normal and not adopted, own
                results.append(dict(coldStart=boot,legacySceneAdopted=adopted,
                                    sceneDelegateConnected=any(x['event']=='connected' for x in own),
                                    normalFlutterSceneConnected=normal,dartPausedObserved=True,dartResumedCallbackObserved=True))
                print('Cold start', boot, 'legacy adoption', adopted, 'Dart background/resume verified', flush=True)
                run('xcrun','simctl','terminate',device,BUNDLE)
        assert hashes(root)==original
        evidence=dict(passed=True,simulatorRuntime=runtime,synthetic=True,legacyUIFixtureUsed=bool(args.legacy_ui_fixture),realNativeStartup=True,coldStarts=results,trace=rows(),originalFilesUnchanged=True,physicalDeviceAccessed=False,realServicePostsPerformed=False)
    except Exception as error:
        try:
            args.evidence.parent.mkdir(parents=True,exist_ok=True)
            args.evidence.write_text(json.dumps(dict(passed=False, failureType=type(error).__name__, trace=rows()),indent=2)+'\n')
        except (NameError, FileNotFoundError): pass
        raise
    finally:
        subprocess.run(['xcrun','simctl','shutdown',device],capture_output=True)
        run('xcrun','simctl','delete',device)
    current=json.loads(capture('xcrun','simctl','list','devices','--json'))
    assert not any(d['udid']==device for ds in current['devices'].values() for d in ds)
    evidence['disposableSimulatorRemoved']=True
    args.evidence.parent.mkdir(parents=True,exist_ok=True)
    args.evidence.write_text(json.dumps(evidence,indent=2)+'\n')
    print('Lifecycle probe passed',flush=True)
if __name__=='__main__': main()
