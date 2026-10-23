#!/usr/bin/env python3
"""Prepare local-only probe paths/fixture; never include personal audio or model binaries in Git."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import shutil
import math
import struct
import wave
import sys

ROOT = Path(__file__).resolve().parents[1]
WHISPER_COMMIT = 'd1be6fde11ac6e0407606b4e42fe72d34add8037'
MODEL_SHA = '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe'
TEXT = 'これはインデックスリレーの動作確認です。録音した音声を文字に変換します。'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--flutter-sdk', type=Path, required=True)
    p.add_argument('--android-sdk', type=Path, required=True)
    p.add_argument('--whisper-source', type=Path, required=True)
    p.add_argument('--model', type=Path, required=True)
    p.add_argument('--fixture-mode', choices=['speech','tone','none'], default='speech')
    args = p.parse_args()
    flutter, android, whisper, model = (x.resolve(strict=True) for x in (args.flutter_sdk, args.android_sdk, args.whisper_source, args.model))
    if not (flutter/'bin/flutter').is_file() or not (android/'platform-tools/adb').is_file():
        p.error('Flutter and Android platform-tools must be installed')
    head = subprocess.check_output(['git', '-C', str(whisper), 'rev-parse', 'HEAD'], text=True).strip()
    if head != WHISPER_COMMIT:
        p.error('Unexpected whisper.cpp commit')
    # Also reject local source modifications; an unchanged HEAD is insufficient.
    if subprocess.check_output(['git', '-C', str(whisper), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        p.error('whisper.cpp has modified tracked sources')
    digest = hashlib.sha256()
    with model.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): digest.update(chunk)
    if digest.hexdigest() != MODEL_SHA:
        p.error('Whisper base model SHA-256 mismatch')
    probe = ROOT/'flutter_probe'
    def prop(path):
        value = str(path)
        if '\n' in value or '\r' in value: p.error('Invalid local path')
        return value.replace('\\', '\\\\').replace(':', '\\:')
    (probe/'android/local.properties').write_text('sdk.dir='+prop(android)+'\nflutter.sdk='+prop(flutter)+'\nwhisper.source='+prop(whisper)+'\n')
    assets = probe/'assets'; assets.mkdir(exist_ok=True)
    shutil.copyfile(model, assets/'ggml-base.bin')
    if args.fixture_mode == 'speech':
        if sys.platform != 'darwin': p.error('Japanese TTS fixture requires macOS; use tone for non-speech CI')
        temp = assets/'japanese.aiff'
        try:
            subprocess.run(['say', '-v', 'Kyoko', '-r', '150', '-o', str(temp), TEXT], check=True)
            subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(temp), str(assets/'japanese.wav')], check=True)
        finally: temp.unlink(missing_ok=True)
    elif args.fixture_mode == 'tone':
        # Explicit CI fixture, not Japanese speech and never evidence of ASR accuracy.
        with wave.open(str(assets/'japanese.wav'),'wb') as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
            output.writeframes(b''.join(struct.pack('<h',round(1000*math.sin(i*2*math.pi*440/16000))) for i in range(16000)))
    wrapper = flutter/'bin/cache/artifacts/gradle_wrapper'
    if not (wrapper/'gradle/wrapper/gradle-wrapper.jar').is_file(): p.error('Run flutter precache --android first')
    import json
    expected = json.loads((probe/'toolchain-lock.json').read_text())['flutter']['gradle_wrapper_sha256']
    if hashlib.sha256((wrapper/'gradle/wrapper/gradle-wrapper.jar').read_bytes()).hexdigest() != expected: p.error('Unexpected Flutter wrapper JAR')
    for relative in ['gradlew','gradlew.bat','gradle/wrapper/gradle-wrapper.jar']:
        target = probe/'android'/relative; target.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(wrapper/relative,target)
    (probe/'android/gradlew').chmod(0o755)
    subprocess.run([sys.executable,str(ROOT/'scripts/prepare-app-notices.py')],check=True)
    print('Verified local Whisper source/model; prepared requested fixture mode and ignored local paths.')
    print('Verified model staged as an ignored offline asset for this probe; see flutter_probe/README.md.')

if __name__ == '__main__': main()
