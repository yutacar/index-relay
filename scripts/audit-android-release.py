#!/usr/bin/env python3
"""Fail closed on trial assets/components, wrong identity/version, model, ABI or signing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile
ROOT=Path(__file__).resolve().parents[1]
LOCK=json.loads((ROOT/'flutter_probe/toolchain-lock.json').read_text())

def digest(stream):
    sha=hashlib.sha256()
    while chunk:=stream.read(1024*1024): sha.update(chunk)
    return sha.hexdigest()
def validate_identity(value, unsigned):
    if not re.fullmatch(r'[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+',value): raise ValueError('Invalid application ID')
    if not unsigned and value.startswith(('dev.example.','com.example.')): raise ValueError('Example ID cannot be signed for distribution')
def inspect_zip(apk):
    with zipfile.ZipFile(apk) as z:
        names=z.namelist()
        forbidden=[n for n in names if n.endswith(('.wav','.aiff','.pcm','.db','.jks','.keystore')) or n.endswith('audio-golden.json') or 'debug_network_security_config' in n]
        if forbidden: raise ValueError('Trial/private content in distribution APK')
        for name in names:
            if re.fullmatch(r'classes\d*\.dex',name):
                code=z.read(name)
                if b'ReceiverHarness' in code or b'DeliveryHarness' in code: raise ValueError('Injection component in APK')
        model='assets/flutter_assets/assets/ggml-base.bin'
        if z.getinfo(model).file_size != LOCK['whisper']['model_bytes']: raise ValueError('Wrong model size')
        with z.open(model) as stream:
            if digest(stream)!=LOCK['whisper']['model_sha256']: raise ValueError('Wrong model hash')
        required={'IndexRelay-MIT.txt','whisper.cpp-MIT.txt','Whisper-model-MIT.txt','Android-Apache-2.0.txt','Android-NOTICE.txt'}
        if not all('assets/flutter_assets/assets/notices/'+v in names for v in required): raise ValueError('Missing notices')
        if 'assets/flutter_assets/NOTICES.Z' not in names: raise ValueError('Missing Flutter notices')
        abis={n.split('/')[1] for n in names if n.startswith('lib/')}
        if abis!={'arm64-v8a'} or 'lib/arm64-v8a/libindex_probe.so' not in names: raise ValueError('Unexpected distribution ABIs')
        return {'trialAssetsAbsent':True,'injectionClassesAbsent':True,'modelHash':LOCK['whisper']['model_sha256'],'noticesPresent':True,'abis':sorted(abis)}
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('apk',type=Path);p.add_argument('--application-id',required=True);p.add_argument('--version',required=True);p.add_argument('--build-number',type=int,required=True);p.add_argument('--unsigned',action='store_true');p.add_argument('--report',type=Path,required=True);args=p.parse_args()
    validate_identity(args.application_id,args.unsigned);report=inspect_zip(args.apk)
    sdk=Path(os.environ['ANDROID_HOME']);analyzer=sdk/'cmdline-tools/latest/bin/apkanalyzer'
    manifest=subprocess.check_output([str(analyzer),'manifest','print',str(args.apk)],text=True)
    root=ET.fromstring(manifest); ns='{http://schemas.android.com/apk/res/android}';app=root.find('application')
    assert root.attrib['package']==args.application_id and root.attrib[ns+'versionName']==args.version and int(root.attrib[ns+'versionCode'])==args.build_number
    assert app.attrib.get(ns+'debuggable','false')=='false' and app.attrib.get(ns+'testOnly','false')=='false'
    assert app.attrib.get(ns+'allowBackup')=='false' and ns+'networkSecurityConfig' not in app.attrib
    assert 'Harness' not in manifest
    tool=sorted((sdk/'build-tools').glob('*/apksigner'))[-1]
    signed=subprocess.run([str(tool),'verify',str(args.apk)],capture_output=True).returncode==0
    if signed==args.unsigned: raise ValueError('Unexpected signing state')
    with args.apk.open('rb') as stream: sha=digest(stream)
    report.update(applicationId=args.application_id,version=args.version,buildNumber=args.build_number,signed=signed,apkSHA256=sha,productionManifest=True)
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n');print('Production APK audit passed.')
if __name__=='__main__': main()
