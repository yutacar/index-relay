#!/usr/bin/env python3
"""Stage reviewed licenses for the Flutter license screen; deterministic and offline."""
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]

def main():
    out=ROOT/'flutter_probe/assets/notices'; out.mkdir(parents=True,exist_ok=True)
    files={'IndexRelay-MIT.txt':ROOT/'LICENSE', 'whisper.cpp-MIT.txt':ROOT/'ThirdPartyNotices/whisper.cpp-v1.9.5-LICENSE.txt',
           'Whisper-model-MIT.txt':ROOT/'ThirdPartyNotices/Whisper-model-MIT.txt','Android-Apache-2.0.txt':ROOT/'ThirdPartyNotices/Apache-2.0.txt'}
    for name,source in files.items(): (out/name).write_bytes(source.read_bytes())
    rows=json.loads((ROOT/'ThirdPartyNotices/Android-runtime-dependencies.json').read_text())
    text='Android runtime dependencies (resolved versions; includes platform variants/BOMs).\n'
    text+='Public POM license metadata is retained for Haversine. Included native components are covered by the publisher metadata; source reproducibility is not implied.\n'
    text+='\n'.join(f"{r['group']}:{r['name']}:{r['version']} - {r['license']}" for r in rows)
    for file in ['SLF4J-2.0.17-MIT.txt','Flutter-3.47.7-BSD.txt']:
        text+='\n\n'+file+'\n'+(ROOT/'ThirdPartyNotices'/file).read_text()
    text+='\nFlutter/Dart package licenses and notices are additionally supplied by Flutter LicenseRegistry.\n'
    (out/'Android-NOTICE.txt').write_text(text)
    print('Staged reviewed app notices.')
if __name__=='__main__': main()
