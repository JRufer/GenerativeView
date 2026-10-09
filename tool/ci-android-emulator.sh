#!/usr/bin/env bash
# CI only: run the integration test on a booted Android emulator.
# OUT is a folder for logs and screenshots.
set -uxo pipefail
OUT="${OUT:-${RUNNER_TEMP:-/tmp}/emulator}"

pkg=com.jrufer.generativeview
mkdir -p "$OUT/screens"

# Install once so "All files access" can be granted before the test starts
# (on a real device the user grants it from the in-app banner).
flutter build apk --debug --target-platform android-x64 2>&1 | tail -5
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell appops set "$pkg" MANAGE_EXTERNAL_STORAGE allow
adb shell mkdir -p /sdcard/Download/gv-fixtures
adb push core/tests/fixtures/comfy_tags.mp4 /sdcard/Download/gv-fixtures/
adb push core/tests/fixtures/comfy_tags.webm /sdcard/Download/gv-fixtures/

# The test pauses on each stage; sample the screen while it runs.
(
  for i in $(seq -w 1 80); do
    adb exec-out screencap -p > "$OUT/screens/android-$i.png" 2>/dev/null || true
    sleep 3
  done
) &
sampler=$!

flutter test integration_test/app_test.dart -d emulator-5554 \
  --dart-define=GV_FIXTURES=/sdcard/Download/gv-fixtures \
  --dart-define=GV_TEST_VIDEO=1 2>&1 | tee "$OUT/integration-android.log"
status=${PIPESTATUS[0]}

kill "$sampler" 2>/dev/null || true
adb logcat -d -t 400 flutter:V AndroidRuntime:E '*:S' > "$OUT/logcat.txt" 2>/dev/null || true
# Keep a handful of distinct frames rather than eighty near-duplicates.
python3 - "$OUT/screens" <<'PY'
import hashlib, os, sys
d = sys.argv[1]; seen = set()
for name in sorted(os.listdir(d)):
    if not name.startswith('android-'): continue
    p = os.path.join(d, name)
    data = open(p, 'rb').read()
    h = hashlib.md5(data).hexdigest()
    if len(data) < 1000 or h in seen: os.remove(p)
    seen.add(h)
PY
exit "$status"
