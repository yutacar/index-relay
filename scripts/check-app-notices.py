#!/usr/bin/env python3
"""Require review when resolved Android dependency coordinates drift from embedded notices."""
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
def main():
    actual=json.loads((ROOT/'flutter_probe/build/app/reports/index-relay-dependencies.json').read_text())
    reviewed=json.loads((ROOT/'ThirdPartyNotices/Android-runtime-dependencies.json').read_text())
    key=lambda row:(row['group'],row['name'],row['version'])
    if sorted(map(key,actual)) != sorted(map(key,reviewed)): raise SystemExit('Android runtime dependency inventory changed; review licenses/notices before distribution.')
    print('Resolved runtime coordinates match reviewed notices.')
if __name__=='__main__':main()
