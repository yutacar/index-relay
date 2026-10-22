#!/usr/bin/env python3
"""Inspect an explicitly exported IndexRelay-comparison.json locally; no networking."""
import argparse
import base64
import hashlib
import io
import json
import wave


def fnv64(data):
    value = 14695981039346656037
    for byte in data:
        value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return f'{value:016x}'


def inspect(bundle):
    manifest = bundle['manifest']
    if manifest['schema'] != 1:
        raise ValueError('Unsupported schema')
    assets = []
    for entry in bundle['files']:
        asset = entry['asset']
        data = base64.b64decode(entry['data'], validate=True)
        if len(data) != asset['bytes'] or hashlib.sha256(data).hexdigest() != asset['sha256']:
            raise ValueError('Asset checksum mismatch: ' + asset['name'])
        assets.append((asset, data))
    if [asset for asset, _ in assets] != manifest['assets']:
        raise ValueError('Manifest/file list mismatch')
    print(f'Assets verified: {len(assets)}; issues: {manifest["issues"]}')
    offsets = {}
    # Each comparison emits callback, optional replay, then saved WAV, in order.
    # Keep occurrences separate when the same collection was transferred twice.
    for result in manifest['results']:
        index = result['collectionEnd']
        candidates = [(i, a, d) for i, (a, d) in enumerate(assets)
                      if a['collection'] == index and i >= offsets.get(index, 0)]
        callback = next(((i, d) for i, a, d in candidates if a['kind'] == 'callback-pcm16le'), None)
        if callback is None:
            print(f'Collection {index}: incomplete assets; comparison record retained')
            continue
        start, pcm = callback
        next_callback = next((i for i, a, _ in candidates if i > start and a['kind'] == 'callback-pcm16le'), len(assets))
        group = [(a, d) for i, a, d in candidates if start < i < next_callback]
        replay = next((d for a, d in group if a['kind'] == 'replay-pcm16le'), None)
        saved = next((d for a, d in group if a['kind'] == 'saved-original-wav'), None)
        offsets[index] = next_callback
        native_hash = result.get('nativeHash')
        bridge = None if native_hash is None else fnv64(pcm) == native_hash
        replay_equal = None if replay is None else replay == pcm
        saved_equal = None
        if saved is not None:
            saved_valid = False
            try:
                with wave.open(io.BytesIO(saved), 'rb') as wav:
                    saved_valid = (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, result['sampleRate'])
                    saved_equal = saved_valid and wav.readframes(wav.getnframes()) == pcm
            except (wave.Error, EOFError):
                saved_equal = False
            if result.get('savedWAVValid') != saved_valid:
                raise ValueError(f'WAV format metadata disagrees with bytes: {index}')
        checks = [('bridgeMatches', bridge), ('replayMatches', replay_equal), ('savedWAVMatches', saved_equal)]
        for key, measured in checks:
            if measured is not None and result.get(key) != measured:
                raise ValueError(f'Comparison metadata disagrees with bytes: {index}/{key}')
        print(f'Collection {result["collectionStart"]}..{index}: bridge={bridge}, replay={replay_equal}, WAV={saved_equal}, raw_complete={result["rawCoverageComplete"]}, samples={len(pcm)//2}')
    print('Replay uses the same decoder; equal bytes do not prove correct speech decoding.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file')
    args = parser.parse_args()
    with open(args.file, encoding='utf-8') as file:
        inspect(json.load(file))
