#!/usr/bin/env python3
"""Free space only on an ephemeral GitHub-hosted Linux runner, before SDK installation."""
import json
import os
from pathlib import Path
import shutil


def require_hosted_runner(env):
    if not (env.get('GITHUB_ACTIONS')=='true' and env.get('RUNNER_OS')=='Linux' and env.get('RUNNER_ENVIRONMENT')=='github-hosted'):
        raise RuntimeError('Cleanup is restricted to GitHub-hosted Linux CI; never run on a local/self-hosted machine')

def main():
    require_hosted_runner(os.environ)
    sdk=Path(os.environ['ANDROID_HOME']).resolve()
    if str(sdk) not in ['/usr/local/lib/android/sdk','/opt/android-sdk']:
        raise RuntimeError('Unexpected hosted SDK directory; refusing cleanup')
    before=shutil.disk_usage('.').free
    targets=[Path(p) for p in ['/usr/share/dotnet','/opt/ghc','/usr/local/.ghcup','/usr/local/share/boost','/opt/hostedtoolcache/CodeQL']]
    targets.append(sdk/'system-images') # The exact required image is installed after this step.
    for folder,keep in [('ndk','28.2.13676358'),('cmake','3.22.1'),('platforms','android-36'),('build-tools','36.0.0')]:
        directory=sdk/folder
        if directory.is_dir(): targets.extend(p for p in directory.iterdir() if p.name!=keep)
    removed=[]
    for target in targets:
        if target.is_dir() and not target.is_symlink():
            shutil.rmtree(target); removed.append(str(target))
    after=shutil.disk_usage('.').free
    report={'beforeFreeGiB':round(before/2**30,2),'afterFreeGiB':round(after/2**30,2),'removed':removed}
    out=Path('work/flutter-ci/prune.json');out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    if after<20*2**30: raise RuntimeError('CI requires at least 20 GiB free before installing/building the Android toolchain')
if __name__=='__main__':main()
