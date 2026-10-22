#!/usr/bin/env python3
"""Compile and run deterministic Swift tests on macOS; no ring, network or credentials."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "ios/IndexRelay"
OUT = ROOT / "work/tests"
SUITES = {
    "PrivacyShield": ["PrivacyShieldState"],
    "PairingProbe": ["PairingProbe"],
    "PCM16WAV": ["PCM16WAV"],
    "ReceivedRecording": ["ReceivedRecording"],
    "ReceiverCheckpoint": ["ReceiverCheckpoint"],
    "AudioSignal": ["PCM16WAV", "AudioSignal"],
    "ReceiverComparison": ["PCM16WAV", "ReceiverComparison"],
    "PlaybackCoordinator": ["PlaybackCoordinator"],
    "Transcription": ["PCM16WAV", "AudioSignal", "TranscriptArchive", "TranscriptionController"],
    "AutomaticQueue": ["ReceivedRecording", "TranscriptArchive", "AutomaticQueue"],
    "Delivery": ["TranscriptArchive", "DeliveryModels", "DeliveryNetwork"],
    "History": ["ReceivedRecording", "TranscriptArchive", "AutomaticQueue", "DeliveryModels", "HistoryArchive"],
}

def main():
    names = sys.argv[1:] or list(SUITES)
    if any(name not in SUITES for name in names):
        raise SystemExit("Unknown suite; choose: " + ", ".join(SUITES))
    OUT.mkdir(parents=True, exist_ok=True)
    for name in names:
        binary = OUT / name
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(OUT / "ModuleCache"),
                        *[str(APP / (source + ".swift")) for source in SUITES[name]],
                        str(ROOT / "tests" / name / "main.swift"), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print(f"All {len(names)} suites passed.", flush=True)

if __name__ == "__main__":
    main()
