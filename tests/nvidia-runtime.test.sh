#!/usr/bin/env bash
# Exercise actual Process/collector ordering, retries, timeout and overlap
# protection in Quickshell, without changing the installed plugin or desktop.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/runtime" "$work/config"
chmod 700 "$work/runtime"
cp "$root/Metrics.qml" "$root/Metrics.js" "$root/discover-sensors.sh" "$work/config/"
cp "$root/tests/nvidia-runtime.qml" "$work/config/shell.qml"

cat >"$work/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import sys
import time

args = sys.argv[1:]
state = Path(os.environ["OMARCHY_SYSMON_TEST_STATE"])
if args == ["--query-gpu=uuid,memory.total", "--format=csv,noheader,nounits"]:
    if os.environ.get("OMARCHY_SYSMON_TEST_AMD"):
        sys.exit(9)
    print("GPU-aabb-1234, 8192", flush=True)
    sys.exit(0)
count_file = state / "count"
count = int(count_file.read_text()) + 1 if count_file.exists() else 1
expected = ["--id=GPU-aabb-1234", "--query-gpu=utilization.gpu,temperature.gpu" +
            (",memory.used" if count in (2, 3, 4) else ""),
            "--format=csv,noheader,nounits", "--loop-ms=" + ("1000" if count in (2, 3, 4) else "2000")]
if args != expected:
    (state / "bad-args").write_text(repr(args))
    sys.exit(2)
pid_file = state / "pid"
if pid_file.exists():
    try:
        os.kill(int(pid_file.read_text()), 0)
    except ProcessLookupError:
        pass
    else:
        (state / "overlap").touch()
        sys.exit(3)
pid_file.write_text(str(os.getpid()))
count_file.write_text(str(count))
signal.signal(signal.SIGTERM, signal.SIG_IGN if count == 3 else lambda *_: sys.exit(0))
try:
    if count == 1:
        print("37, 52", flush=True)
        time.sleep(2)
        print("41, 53", flush=True)
    elif count == 2:
        print("12, N/A, 256", flush=True)
        time.sleep(1)
        print("18, 43, 512", flush=True)
        time.sleep(1)
        sys.exit(9)
    elif count == 3:
        print("25, 45, 128", flush=True)
        time.sleep(15)  # Ignore TERM: watchdog must force-kill this stream.
    elif count == 4:
        print("0, 40, 0", flush=True)
    elif count == 5:
        print("55, 46", flush=True)
    else:
        print("22, 47, 64", flush=True)
    while True:
        time.sleep(1)
finally:
    pid_file.unlink(missing_ok=True)
EOF
chmod +x "$work/bin/nvidia-smi"

status=0
env PATH="$work/bin:$PATH" XDG_RUNTIME_DIR="$work/runtime" XDG_CACHE_HOME="$work/cache" \
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=basic QT_QUICK_CONTROLS_STYLE=Basic \
  OMARCHY_SYSMON_TEST_STATE="$work/state" \
  OMARCHY_SYSMON_DRM_ROOT="$work/no-cards" OMARCHY_SYSMON_HWMON_ROOT="$work/no-hwmon" \
  timeout -k 1s 26s qs --no-color -p "$work/config" >"$work/log" 2>&1 || status=$?
cat "$work/log"
(( status == 0 )) || exit "$status"
if [[ -f "$work/state/overlap" || -f "$work/state/bad-args" ]] || ! rg -q 'NVIDIA QML runtime checks passed' "$work/log"; then
  echo 'FAIL: NVIDIA runtime checks or query overlap guard'
  for diagnostic in overlap bad-args count; do
    if [[ -f "$work/state/$diagnostic" ]]; then
      echo "$diagnostic: $(cat "$work/state/$diagnostic")"
    fi
  done
  exit 1
fi
[[ "$(cat "$work/state/count")" == 5 ]] || { echo 'FAIL: unexpected process launches'; exit 1; }
echo 'NVIDIA runtime passed: streams are reused across samples and recovery never overlaps'


# Preserve the existing sysfs backend's continuous closed-panel monitoring.
device="$work/drm/card0/device"
mkdir -p "$device/hwmon/hwmon0"
printf '7\n' >"$device/gpu_busy_percent"
printf '50000\n' >"$device/hwmon/hwmon0/temp1_input"
printf '1024\n' >"$device/mem_info_vram_used"
printf '8192\n' >"$device/mem_info_vram_total"
cp "$root/tests/amd-runtime.qml" "$work/config/shell.qml"
status=0
env PATH="$work/bin:$PATH" XDG_RUNTIME_DIR="$work/runtime" XDG_CACHE_HOME="$work/cache" \
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=basic QT_QUICK_CONTROLS_STYLE=Basic \
  OMARCHY_SYSMON_TEST_STATE="$work/state" OMARCHY_SYSMON_TEST_AMD=1 \
  OMARCHY_SYSMON_DRM_ROOT="$work/drm" OMARCHY_SYSMON_HWMON_ROOT="$work/no-hwmon" \
  timeout -k 1s 14s qs --no-color -p "$work/config" >"$work/amd-log" 2>&1 || status=$?
cat "$work/amd-log"
(( status == 0 )) || exit "$status"
rg -q 'AMD continuous monitoring checks passed' "$work/amd-log"
