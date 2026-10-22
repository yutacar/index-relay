#!/bin/bash
# Sourced by the two bridge commands; never forwards arbitrary Gradle arguments.
receiver_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$receiver_root/scripts/verify-gradle-wrapper.py"
receiver_gradle="${GRADLE_CMD:-$receiver_root/bridge/gradlew}"
if ! command -v "$receiver_gradle" >/dev/null 2>&1; then
  echo "Verified Gradle wrapper is required. See docs/BUILD.md." >&2
  exit 1
fi
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "This bridge build requires an Apple Silicon Mac." >&2
  exit 1
fi
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$receiver_root/work/gradle-cache}"
export KONAN_DATA_DIR="${KONAN_DATA_DIR:-$receiver_root/work/konan}"
receiver_version="$("$receiver_gradle" --version | awk '/^Gradle / {print $2}')"
if [ "$receiver_version" != 8.14.3 ]; then
  echo "Expected Gradle 8.14.3; refusing to build with a different version." >&2
  exit 1
fi
