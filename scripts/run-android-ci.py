#!/usr/bin/env python3
"""Run x86_64 AVD checks with synthetic data and local HTTP only; record durations."""
from pathlib import Path
import json
import os
import subprocess
import time
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/flutter-ci'; OUT.mkdir(parents=True,exist_ok=True)

def wait_for_services(adb, emulator, timeout=90):
    """boot_completed can precede the phone binder service on a fresh API 36 AVD."""
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if emulator.poll() is not None: raise RuntimeError('Emulator stopped while waiting for Android services')
        ready=True
        for service in ('package','wifi','phone'):
            result=subprocess.run(adb+['shell','service','check',service],capture_output=True,text=True)
            ready=ready and result.returncode==0 and result.stdout.strip().endswith(': found')
        if ready:
            results=[subprocess.run(adb+command,capture_output=True) for command in (
                ['shell','input','keyevent','82'],['shell','svc','wifi','disable'],['shell','svc','data','disable'])]
            if all(result.returncode==0 for result in results): return
        time.sleep(2)
    raise RuntimeError('Android services or network-disable commands did not become ready within the deadline')

def main():
    sdk=Path(os.environ['ANDROID_HOME']); avd=sdk/'cmdline-tools/latest/bin/avdmanager'
    avd_home=(OUT/'avd').resolve(); avd_home.mkdir(parents=True,exist_ok=True)
    avd_data=avd_home/'index_relay_ci.avd'
    base_env=dict(os.environ,ANDROID_AVD_HOME=str(avd_home))
    # Use the image's default phone hardware; hosted SDK device catalogs vary.
    subprocess.run([str(avd),'create','avd','--force','-n','index_relay_ci','-k','system-images;android-36;google_apis;x86_64','--path',str(avd_data)],input='no\n',text=True,check=True,env=base_env)
    if not (avd_data/'config.ini').is_file(): raise RuntimeError('AVD manager did not create config.ini')
    # Pin discovery too: command-line tools and emulator can use different user-home defaults.
    (avd_home/'index_relay_ci.ini').write_text(f'avd.ini.encoding=UTF-8\npath={avd_data}\ntarget=android-36\n')
    report={'synthetic':True,'speechRecognitionVerified':False,'physicalBLEVerified':False,'externalPostsPerformed':False}
    def run(label,command,cwd=ROOT,env=None):
        start=time.monotonic()
        subprocess.run(command,cwd=cwd,env=env,check=True)
        report[label+'Seconds']=round(time.monotonic()-start,2)
    env=dict(base_env,ORG_GRADLE_PROJECT_indexAbis='x86_64')
    run('previewBuild',['flutter','build','apk','--debug','--flavor','preview','--target-platform','android-x64'],ROOT/'flutter_probe',env)
    # Save main-entry APK: flutter test rebuilds it for the integration target and uninstalls.
    apk=ROOT/'flutter_probe/build/app/outputs/flutter-apk/app-preview-debug.apk'; saved=OUT/'preview-main.apk'; saved.write_bytes(apk.read_bytes())
    subprocess.run([str(ROOT/'flutter_probe/android/gradlew'),'--stop'],cwd=ROOT/'flutter_probe/android',check=True)
    log=(OUT/'emulator-output.txt').open('w')
    emulator=subprocess.Popen([str(sdk/'emulator/emulator'),'-avd','index_relay_ci','-port','5554','-no-window','-no-audio','-no-snapshot','-no-boot-anim','-gpu','swiftshader','-memory','2048','-cores','2','-accel','on'],stdout=log,stderr=subprocess.STDOUT,env=base_env)
    adb=[str(sdk/'platform-tools/adb'),'-s','emulator-5554']
    boot=time.monotonic()
    try:
        deadline=time.monotonic()+300
        while time.monotonic()<deadline:
            if emulator.poll() is not None:
                log.flush()
                raise RuntimeError('CI emulator stopped during boot: '+(OUT/'emulator-output.txt').read_text()[-6000:])
            state=subprocess.run(adb+['shell','getprop','sys.boot_completed'],capture_output=True,text=True)
            if state.stdout.strip()=='1': break
            time.sleep(3)
        else: raise RuntimeError('Emulator boot timed out')
        report['bootSeconds']=round(time.monotonic()-boot,2)
        services=time.monotonic(); wait_for_services(adb,emulator)
        report['serviceReadinessSeconds']=round(time.monotonic()-services,2)
        run('flutterIntegration',['flutter','test','--flavor','preview','integration_test/ci_smoke_test.dart','-d','emulator-5554','-v'],ROOT/'flutter_probe',env)
        subprocess.run([str(ROOT/'flutter_probe/android/gradlew'),'--stop'],cwd=ROOT/'flutter_probe/android',check=True)
        apk.parent.mkdir(parents=True,exist_ok=True); apk.write_bytes(saved.read_bytes())
        run('nativeDelivery',['python3','scripts/test-android-delivery.py','--device','emulator-5554','--reset-test-data','--skip-speech-check'])
        evidence=json.loads((ROOT/'work/android-delivery-tests/evidence.json').read_text())
        assert evidence['syntheticTextMultipleDestinationsAndConfirmation'] and not evidence['realTranscriptionMultipleDestinationsAndConfirmation']
        report['nativeDelivery']=evidence
        (OUT/'evidence.json').write_text(json.dumps(report,indent=2)+'\n')
    finally:
        subprocess.run(adb+['emu','kill'],capture_output=True)
        try: emulator.wait(timeout=20)
        except subprocess.TimeoutExpired: emulator.kill(); emulator.wait()
        log.close()
if __name__=='__main__': main()
