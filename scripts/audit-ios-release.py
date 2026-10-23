#!/usr/bin/env python3
"""Inspect an iOS .app for unexpected ASR models and preview audio; no signing or installation."""
import argparse
import json
from pathlib import Path
import plistlib


def inspect(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleName') != info.get('CFBundleDisplayName'):
        raise ValueError('Internal app name must match display name')
    if not info.get('CFBundleName'):
        raise ValueError('Missing app name')
    files = [p for p in app.rglob('*') if p.is_file()]
    if any(p.name.startswith('ggml-') or p.name in {'japanese.wav', 'audio-golden.json'} for p in files):
        raise ValueError('Unexpected ASR model or preview fixture in iOS app')
    return dict(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                bundleBytes=sum(p.stat().st_size for p in files), whisperModelIncluded=False,
                internalNameMatchesDisplayName=True, deviceSigningVerified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    print(json.dumps(inspect(args.app), indent=2))


if __name__ == '__main__':
    main()
