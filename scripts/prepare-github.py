#!/usr/bin/env python3
"""Create a new source-only publication folder; never overwrite a destination."""
from pathlib import Path
import argparse
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FILES = ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", ".gitignore", ".gitattributes"]
TREES = ["docs", ".github", "ThirdPartyNotices", "scripts", "tests"]
SKIP = {".DS_Store", "__pycache__", "xcuserdata", ".gradle", ".kotlin", "build", ".git"}

def ignore(directory, names):
    return [name for name in names if name in SKIP or name.endswith((".pyc", ".xcuserstate", ".xcappdata"))]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    target = args.destination.resolve()
    if target == ROOT or target.is_relative_to(ROOT) and target.parts[len(ROOT.parts)] not in {"outputs", "work"}:
        parser.error("Use a separate destination, or an outputs/work child.")
    if target.exists(): parser.error("Destination already exists; choose a new directory.")
    target.mkdir(parents=True)
    for filename in FILES + (["LICENSE"] if (ROOT / "LICENSE").is_file() else []):
        shutil.copy2(ROOT / filename, target / filename)
    for directory in TREES:
        shutil.copytree(ROOT / directory, target / directory, ignore=ignore)
    shutil.copytree(ROOT / "ios/IndexRelay", target / "ios/IndexRelay", ignore=ignore)
    shutil.copytree(ROOT / "ios/IndexRelay.xcodeproj", target / "ios/IndexRelay.xcodeproj", ignore=ignore)
    shutil.copytree(ROOT / "bridge", target / "bridge", ignore=ignore)
    project = target / "ios/IndexRelay.xcodeproj/project.pbxproj"
    value = re.sub(r'DEVELOPMENT_TEAM = [^;]*;', 'DEVELOPMENT_TEAM = "";', project.read_text())
    # Keep bundle-derived background task identifiers consistent in a public example.
    original_bundle = re.search(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);', value).group(1)
    project.write_text(re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = [^;]+;', 'PRODUCT_BUNDLE_IDENTIFIER = dev.example.indexrelay;', value))
    for path in (target / "tests").rglob("*.swift"):
        path.write_text(path.read_text().replace(original_bundle, "dev.example.indexrelay"))
    subprocess.run(["python3", str(target / "scripts/check-publication.py")], check=True)
    subprocess.run(["python3", str(target / "scripts/verify-gradle-wrapper.py")], check=True)
    print("Prepared source-only folder:", target)
    print("No repository, commit, remote or upload was created.")

if __name__ == "__main__":
    main()
