#!/usr/bin/env python3
"""Check publication candidates without printing potentially sensitive matches."""
from pathlib import Path
import re
import hashlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RULES = {
    "personal absolute path": re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    "Telegram credential": re.compile(r"\b[0-9]{6,}:[A-Za-z0-9_-]{30,}\b"),
    "Discord credential": re.compile(r"https://(?:discord(?:app)?\.com)/api/(?:v[0-9]+/)?webhooks/[0-9]+/[A-Za-z0-9._-]{30,}"),
    "GitHub credential": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "personal signing team": re.compile(r'DEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}'),
}
BLOCKED = {".wav", ".pcm", ".m4a", ".mp3", ".ipa", ".p12", ".p8", ".mobileprovision", ".log"}

def candidate_files():
    top = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    # An export can be ignored by an unrelated parent repository. Use Git's index only
    # when it belongs to this exact project, otherwise inspect the exported files directly.
    if top.returncode == 0 and Path(top.stdout.strip()).resolve() == ROOT.resolve():
        result = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--cached", "--others", "--exclude-standard", "-z"], capture_output=True, check=True)
        return sorted({ROOT / p.decode() for p in result.stdout.split(b"\0") if p})
    # Exported ZIP before git init: no build/runtime directories are eligible.
    return sorted(p for p in ROOT.rglob("*") if p.is_file() and not set(p.relative_to(ROOT).parts).intersection({".git", "work", "outputs", "build", ".gradle", ".kotlin", "xcuserdata"}))

def main():
    failures = []
    files = candidate_files()
    if not files:
        raise SystemExit("Publication check failed: no candidate files were inspected.")
    for path in files:
        rel = path.relative_to(ROOT)
        if path.is_symlink():
            failures.append((rel, "symbolic link")); continue
        if path.suffix.lower() in BLOCKED or path.name.startswith(".env") or "IndexReceiverBridge.xcframework" in path.parts:
            failures.append((rel, "private/generated artifact")); continue
        if path.stat().st_size > 25 * 1024 * 1024:
            failures.append((rel, "large binary")); continue
        if path.suffix.lower() == ".jar":
            if rel.as_posix() != "bridge/gradle/wrapper/gradle-wrapper.jar" or hashlib.sha256(path.read_bytes()).hexdigest() != "7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172":
                failures.append((rel, "unapproved JAR"))
            continue
        if path.suffix.lower() == ".png":
            continue
        try:
            content = path.read_text()
        except UnicodeError:
            failures.append((rel, "unexpected binary")); continue
        for label, pattern in RULES.items():
            if pattern.search(content): failures.append((rel, label))
    for rel, label in failures:
        print(f"FAIL {rel}: {label}")
    if failures:
        raise SystemExit(f"Publication check failed: {len(failures)} findings (matched values are hidden).")
    print(f"Publication check passed: {len(files)} files. Pattern checks supplement manual review; they are not proof of absence of secrets.")

if __name__ == "__main__":
    main()
