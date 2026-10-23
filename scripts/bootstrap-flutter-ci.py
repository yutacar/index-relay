#!/usr/bin/env python3
"""Prepare verified Linux Flutter/Whisper inputs on an ephemeral CI runner, without secrets."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
LOCK=json.loads((ROOT/'flutter_probe/toolchain-lock.json').read_text())
def download(url,target,sha):
    if target.is_file() and digest(target)==sha: return
    temp=target.with_suffix('.part'); temp.unlink(missing_ok=True)
    try:
        with urllib.request.urlopen(url,timeout=120) as response, temp.open('wb') as out:
            while chunk:=response.read(1024*1024): out.write(chunk)
        if digest(temp)!=sha: raise RuntimeError('Downloaded file hash mismatch')
        temp.replace(target)
    finally: temp.unlink(missing_ok=True)
def digest(file):
    sha=hashlib.sha256()
    with file.open('rb') as stream:
        while chunk:=stream.read(1024*1024): sha.update(chunk)
    return sha.hexdigest()
def main():
    task=Path(os.environ['RUNNER_TEMP'])/'index-relay-toolchain'; task.mkdir(parents=True,exist_ok=True)
    archive=task/'flutter.tar.xz'; download(LOCK['flutter']['linux_x64_archive'],archive,LOCK['flutter']['linux_x64_archive_sha256'])
    subprocess.run(['tar','xf',str(archive),'-C',str(task)],check=True); archive.unlink()
    flutter=task/'flutter'; source=task/'whisper'
    source.mkdir()
    subprocess.run(['git','-C',str(source),'init','--quiet'],check=True)
    subprocess.run(['git','-C',str(source),'remote','add','origin',LOCK['whisper']['source_url']],check=True)
    subprocess.run(['git','-C',str(source),'fetch','--depth=1','origin',LOCK['whisper']['commit']],check=True)
    subprocess.run(['git','-C',str(source),'checkout','--detach','FETCH_HEAD'],check=True)
    actual=subprocess.check_output([str(flutter/'bin/flutter'),'--version','--machine'],text=True)
    version=json.loads(actual[actual.index('{'):]); assert version['frameworkRevision']==LOCK['flutter']['commit']
    subprocess.run([str(flutter/'bin/flutter'),'--disable-analytics'],check=True)
    subprocess.run([str(flutter/'bin/flutter'),'precache','--android'],check=True)
    model=task/'ggml-base.bin'; download(LOCK['whisper']['model_url'],model,LOCK['whisper']['model_sha256'])
    subprocess.run(['python3',str(ROOT/'scripts/prepare-flutter-probe.py'),'--flutter-sdk',str(flutter),'--android-sdk',os.environ['ANDROID_HOME'],
                    '--whisper-source',str(source),'--model',str(model),'--fixture-mode','tone'],check=True)
    with open(os.environ['GITHUB_PATH'],'a') as out: out.write(str(flutter/'bin')+'\n'+os.environ['ANDROID_HOME']+'/platform-tools\n'+os.environ['ANDROID_HOME']+'/emulator\n')
    with open(os.environ['GITHUB_ENV'],'a') as out: out.write('FLUTTER_SDK='+str(flutter)+'\nWHISPER_SOURCE='+str(source)+'\n')
if __name__=='__main__': main()
