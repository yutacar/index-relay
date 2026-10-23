#!/usr/bin/env python3
"""Build/audit a production APK. Unsigned review is explicit; no debug key fallback."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/audit-android-release.py');audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--application-id',required=True);p.add_argument('--version',default='0.12.1');p.add_argument('--build-number',type=int,default=34);p.add_argument('--unsigned',action='store_true');args=p.parse_args()
    audit.validate_identity(args.application_id,args.unsigned)
    if args.build_number<31: p.error('Build number must not regress from migration baseline')
    if not args.unsigned and not (ROOT/'flutter_probe/android/release-signing.local.properties').is_file(): p.error('Configure local distribution signing or pass --unsigned')
    env=dict(os.environ,ORG_GRADLE_PROJECT_indexApplicationId=args.application_id,ORG_GRADLE_PROJECT_indexUnsigned=str(args.unsigned).lower(),ORG_GRADLE_PROJECT_indexAbis='arm64-v8a')
    subprocess.run([sys.executable,str(ROOT/'scripts/prepare-app-notices.py')],check=True)
    subprocess.run([str(ROOT/'flutter_probe/android/gradlew'),':app:writeDependencyInventory'],cwd=ROOT/'flutter_probe/android',env=env,check=True)
    subprocess.run([sys.executable,str(ROOT/'scripts/check-app-notices.py')],check=True)
    subprocess.run(['flutter','build','apk','--flavor','production','--release','--target-platform','android-arm64','--build-name',args.version,'--build-number',str(args.build_number)],cwd=ROOT/'flutter_probe',env=env,check=True)
    apk=ROOT/'flutter_probe/build/app/outputs/flutter-apk/app-production-release.apk'
    command=[sys.executable,str(ROOT/'scripts/audit-android-release.py'),str(apk),'--application-id',args.application_id,'--version',args.version,'--build-number',str(args.build_number),'--report',str(ROOT/'work/android-release/audit.json')]
    if args.unsigned: command.append('--unsigned')
    subprocess.run(command,check=True)
if __name__=='__main__': main()
