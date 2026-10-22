"""Per-build integrity receipts, independent from reviewed dependency/network baselines."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORK = ROOT / 'ios/Frameworks/IndexReceiverBridge.xcframework'
RECEIPT = 'IndexRelay-integrity.json'
BINARIES = tuple(name + '/IndexReceiverBridge.framework/IndexReceiverBridge'
                 for name in ('ios-arm64', 'ios-arm64-simulator'))


def fingerprints(framework):
    values = {}
    for relative in BINARIES:
        path = framework / relative
        if not path.is_file() or any(p.is_symlink() for p in (path, path.parent, path.parent.parent, framework)):
            raise ValueError('Missing or symlinked bridge binary: ' + relative)
        values[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {'schema': 1, 'sha256': values}


def verify(framework):
    current = fingerprints(framework)
    receipt = json.loads((framework / RECEIPT).read_text())
    if type(receipt.get('schema')) is not int or receipt != current:
        raise ValueError('Bridge integrity receipt does not match both current binaries')
    return current


def record(framework):
    value = fingerprints(framework)
    # This local receipt records new output, rather than comparing it to a previous build.
    (framework / RECEIPT).write_text(json.dumps(value, indent=2) + '\n')
    verify(framework)


def install(staging, destination, replace=os.replace):
    if staging.resolve() == destination.resolve():
        raise ValueError('Staging and destination must differ')
    expected = verify(staging)
    destination.parent.mkdir(parents=True, exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix='.index-relay-install-', dir=destination.parent))
    candidate, previous = workspace / 'candidate', workspace / 'previous'
    try:
        shutil.copytree(staging, candidate, symlinks=True)
        if verify(candidate) != expected:
            raise ValueError('Staging changed during copy')
        if destination.exists():
            replace(destination, previous)
        try:
            replace(candidate, destination)
        except BaseException:
            if previous.exists():
                replace(previous, destination)
            raise
        if previous.exists():
            shutil.rmtree(previous)
    finally:
        # Never delete the old installation if restoring it failed.
        if previous.exists():
            print('Previous framework preserved at: ' + str(previous), file=sys.stderr)
        else:
            shutil.rmtree(workspace)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--framework', type=Path, default=FRAMEWORK)
    action = parser.add_mutually_exclusive_group()
    action.add_argument('--record-integrity', action='store_true', help='record this build only; not an approval or provenance check')
    action.add_argument('--install-from', type=Path, help='verify staging and copy before replacing the installation')
    args = parser.parse_args(argv)
    try:
        if args.install_from is not None:
            install(args.install_from, args.framework)
        elif args.record_integrity:
            record(args.framework)
        else:
            verify(args.framework)
        print('Bridge local SHA-256 integrity passed (both slices). Not a dependency authenticity or reproducibility proof.')
        return 0
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print('Bridge integrity failed: ' + str(error), file=sys.stderr)
        return 1
