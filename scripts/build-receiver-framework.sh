#!/bin/bash
set -euo pipefail
if [ "$#" -ne 0 ]; then
  echo "No arguments accepted. Dependency recording and network approval are separate commands; see docs/BUILD.md." >&2
  exit 1
fi
source "$(dirname "$0")/bridge-env.sh"
if [ ! -f "$receiver_root/bridge/gradle/verification-metadata.xml" ]; then
  echo "Reviewed dependency verification metadata is required. See docs/BUILD.md; no automatic bootstrap." >&2
  exit 1
fi
"$receiver_gradle" -p "$receiver_root/bridge" -Pkonan.data.dir="$KONAN_DATA_DIR" \
  --dependency-verification strict --no-build-cache --rerun-tasks \
  linkDebugFrameworkIosArm64 linkDebugFrameworkIosSimulatorArm64
receiver_device="$receiver_root/bridge/build/bin/iosArm64/debugFramework/IndexReceiverBridge.framework"
receiver_simulator="$receiver_root/bridge/build/bin/iosSimulatorArm64/debugFramework/IndexReceiverBridge.framework"
receiver_staging="$receiver_root/work/IndexReceiverBridge.xcframework"
if [ -e "$receiver_staging" ]; then rm -rf "$receiver_staging"; fi
xcodebuild -create-xcframework -framework "$receiver_device" -framework "$receiver_simulator" \
  -output "$receiver_staging"
python3 "$receiver_root/scripts/inspect-bridge-network.py" --framework "$receiver_staging"
# This new receipt describes this build's bytes. It is not a reproducible-build or provenance approval.
python3 "$receiver_root/scripts/verify-framework.py" --framework "$receiver_staging" --record-integrity
python3 "$receiver_root/scripts/verify-framework.py" --install-from "$receiver_staging"
