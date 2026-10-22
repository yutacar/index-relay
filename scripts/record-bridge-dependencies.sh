#!/bin/bash
# Generate a candidate in an isolated project; never edits reviewed metadata or installs its output.
set -euo pipefail
if [ "$#" -ne 0 ]; then echo "No arguments accepted; see docs/BUILD.md." >&2; exit 1; fi
source "$(dirname "$0")/bridge-env.sh"
mkdir -p "$receiver_root/work"
receiver_candidate="$(mktemp -d "$receiver_root/work/dependency-review.XXXXXX")"
python3 - "$receiver_root/bridge" "$receiver_candidate" <<'PY'
from pathlib import Path
import shutil, sys
source, dest = map(Path, sys.argv[1:])
for name in ('build.gradle.kts', 'settings.gradle.kts', 'gradle.properties'):
    shutil.copy2(source / name, dest / name)
shutil.copytree(source / 'src', dest / 'src')
metadata = source / 'gradle/verification-metadata.xml'
if metadata.is_file():
    (dest / 'gradle').mkdir()
    shutil.copy2(metadata, dest / 'gradle/verification-metadata.xml')
PY
"$receiver_gradle" -p "$receiver_candidate" -Pkonan.data.dir="$KONAN_DATA_DIR" \
  --write-verification-metadata sha256 --no-build-cache --rerun-tasks \
  linkDebugFrameworkIosArm64 linkDebugFrameworkIosSimulatorArm64
printf 'Candidate only (not approved or installed): %s/gradle/verification-metadata.xml\n' "$receiver_candidate"
echo 'Review artifact versions and hashes against trusted sources, then copy the reviewed metadata explicitly. See docs/BUILD.md.'
