#!/usr/bin/env python3
"""Inspect known network strings in both bridge slices; this is not a network sandbox.

Normal checks never write the baseline. To update it, save --report output, review
that file, then explicitly run --approve-baseline REPORT.json. Approval requires
that the reviewed report still matches both current binaries. Builds never approve.
"""
from pathlib import Path
import argparse
import json
import os
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORK = ROOT / "ios/Frameworks/IndexReceiverBridge.xcframework"
BASELINE = ROOT / "bridge/network-surface.json"
SLICES = ("ios-arm64", "ios-arm64-simulator")
URL = re.compile(rb"(?:https?|wss?)://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]{3,200}")
MARKERS = ("NSURLSession", "CFNetwork", "nw_connection", "nw_endpoint", "io.ktor.client", "WebSocket",
           "CFSocket", "getaddrinfo", "SecTrustEvaluate", "NSStream")


def surface(data):
    return {"urls": sorted({m.group().decode("ascii") for m in URL.finditer(data)}),
            "markers": sorted(name for name in MARKERS if name.encode() in data)}


def snapshot(framework):
    slices = {}
    for name in SLICES:
        binary = framework / name / "IndexReceiverBridge.framework/IndexReceiverBridge"
        if not binary.is_file():
            raise ValueError("Required bridge binary not found: " + name)
        slices[name] = surface(binary.read_bytes())
    return {"schema": 1, "slices": slices}


def validate(report):
    if not isinstance(report, dict) or set(report) != {"schema", "slices"} or type(report["schema"]) is not int or report["schema"] != 1:
        raise ValueError("Unsupported network report schema")
    slices = report["slices"]
    if not isinstance(slices, dict) or set(slices) != set(SLICES):
        raise ValueError("Network report must cover both required slices")
    for fields in slices.values():
        if not isinstance(fields, dict) or set(fields) != {"urls", "markers"}:
            raise ValueError("Malformed network report fields")
        for values in fields.values():
            if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
                raise ValueError("Malformed network report values")
    return report


def additions(current, baseline):
    validate(current); validate(baseline)
    return {name: {key: sorted(set(current["slices"][name][key]) - set(baseline["slices"][name][key]))
                   for key in ("urls", "markers")} for name in SLICES}


def approve(current, reviewed, destination):
    validate(current); validate(reviewed)
    if current != reviewed:
        raise ValueError("Reviewed report no longer matches current binaries; regenerate and review it")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, encoding="utf-8", delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(reviewed, handle, indent=2, ensure_ascii=False); handle.write("\n")
            handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", type=Path, default=FRAMEWORK, help="XCFramework to inspect (allows staging inspection)")
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--report", action="store_true", help="print both slices as JSON; write no files")
    action.add_argument("--approve-baseline", type=Path, metavar="REVIEWED_REPORT", help="explicitly approve a reviewed report matching current binaries")
    args = parser.parse_args(argv)
    try:
        current = snapshot(args.framework)
        if args.report:
            print(json.dumps(current, indent=2, ensure_ascii=False)); return 0
        if args.approve_baseline is not None:
            reviewed = json.loads(args.approve_baseline.read_text())
            approve(current, reviewed, args.baseline)
            print("Recorded the explicitly reviewed report. This does not attest runtime traffic or dependency authenticity.")
            return 0
        if not args.baseline.is_file():
            raise ValueError("No reviewed baseline; generate --report, review it, then use --approve-baseline REPORT.json")
        delta = additions(current, json.loads(args.baseline.read_text()))
        if any(values for fields in delta.values() for values in fields.values()):
            print(json.dumps(delta, indent=2), file=sys.stderr)
            raise ValueError("New bridge network strings detected; the baseline was not changed")
        for name, fields in current["slices"].items():
            print(f"{name}: within reviewed baseline ({len(fields['urls'])} URL strings, {len(fields['markers'])} known markers).")
        return 0
    except (OSError, ValueError, TypeError) as error:
        print("Bridge network check failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
