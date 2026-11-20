#!/usr/bin/env bash
# Exercises GPU discovery against fixture sysfs trees, so the vendor matrix is
# verified rather than assumed on machines that only have one kind of card.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/discover-sensors.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0

# The sysfs fixtures below must be hermetic: on a box with an NVIDIA card the
# real nvidia-smi would answer first and mask every one of them. Stub it off
# by default and point the override at a fixture script in the NVIDIA section.
export OMARCHY_SYSMON_NVIDIA_SMI="$work/no-such-nvidia-smi"

card() { # <tree> <card> [busy] [vram_total] [temp]
  local dir="$work/$1/$2/device"
  mkdir -p "$dir"
  [[ -n "${3:-}" ]] && printf '%s\n' "$3" >"$dir/gpu_busy_percent"
  if [[ -n "${4:-}" ]]; then
    printf '%s\n' "$4" >"$dir/mem_info_vram_total"
    printf '%s\n' "1000" >"$dir/mem_info_vram_used"
  fi
  if [[ -n "${5:-}" ]]; then
    mkdir -p "$dir/hwmon/hwmon0"
    printf '%s\n' "$5" >"$dir/hwmon/hwmon0/temp1_input"
  fi
  return 0
}

check() { # <name> <tree> <key> <expected-substring-or-EMPTY>
  local out actual
  out="$(OMARCHY_SYSMON_DRM_ROOT="$work/$2" bash "$script" | grep "^$3	" || true)"
  actual="${out#*	}"
  if [[ "$4" == "EMPTY" ]]; then
    if [[ -z "$actual" ]]; then echo "  ok   $1: $3 absent"; else
      echo "  FAIL $1: $3 expected absent, got '$actual'"; failures=$((failures+1)); fi
  elif [[ "$actual" == *"$4"* ]]; then
    echo "  ok   $1: $3 -> $actual"
  else
    echo "  FAIL $1: $3 expected '*$4*', got '$actual'"; failures=$((failures+1)); fi
}

# CPU package sensors and Apple Silicon platform sensors live under hwmon, so
# those fixtures override the hwmon root the same way the DRM fixtures do.
hwmon_tree() { # <tree> <hwmon-dir> <driver-name>
  mkdir -p "$work/$1/$2"
  printf '%s\n' "$3" >"$work/$1/$2/name"
}

probe_hw() { # <tree>
  OMARCHY_SYSMON_HWMON_ROOT="$work/$1" OMARCHY_SYSMON_DRM_ROOT="$work/no-cards" bash "$script"
}

# Exact-line and key-absent checks compare in pure bash rather than piping
# into grep -q: with pipefail, grep -q's early exit SIGPIPEs the probe and a
# successful match would report as a failure.
expect_line() { # <name> <tree> <exact-line>
  local out line found=0
  out="$(probe_hw "$2")"
  while IFS= read -r line; do
    if [[ "$line" == "$3" ]]; then found=1; break; fi
  done <<<"$out"
  if (( found )); then echo "  ok   $1"; else
    echo "  FAIL $1: expected line '$3'"; failures=$((failures+1)); fi
}

expect_key_absent() { # <name> <tree> <key>
  local out line found=0
  out="$(probe_hw "$2")"
  while IFS= read -r line; do
    if [[ "$line" == "$3"$'\t'* ]]; then found=1; break; fi
  done <<<"$out"
  if (( found )); then
    echo "  FAIL $1: $3 unexpectedly emitted"; failures=$((failures+1)); else
    echo "  ok   $1: $3 absent"; fi
}

echo "AMD hybrid (discrete + integrated) - picks the card with more VRAM"
card amd card0 "100" "536870912"   "35000"
card amd card1 "6"   "17095983104" "28000"
check "amd" amd gpu_busy  "card1"
check "amd" amd gpu_temp  "card1"
check "amd" amd gpu_vram_total "card1"

echo "Intel Arc (no busy counter anywhere) - still reports temperature"
card intel card0 "" "" "40000"
card intel card1 "" "" "52000"
check "intel" intel gpu_busy EMPTY
check "intel" intel gpu_temp "card"
check "intel" intel gpu_vram_total EMPTY

echo "Intel xe (package temp is temp2_input, there is no temp1) - still found"
mkdir -p "$work/xe/card0/device/hwmon/hwmon0"
printf '48000\n' >"$work/xe/card0/device/hwmon/hwmon0/temp2_input"
check "xe" xe gpu_busy EMPTY
check "xe" xe gpu_temp "temp2_input"

echo "Card with both temp1 and temp2 - temp1 wins (amdgpu edge sensor over the rest)"
mkdir -p "$work/temp-precedence/card0/device/hwmon/hwmon0"
printf '30000\n' >"$work/temp-precedence/card0/device/hwmon/hwmon0/temp1_input"
printf '55000\n' >"$work/temp-precedence/card0/device/hwmon/hwmon0/temp2_input"
check "temp-precedence" temp-precedence gpu_temp "temp1_input"

echo "NVIDIA proprietary without nvidia-smi - nothing readable, nothing claimed"
card nvidia card0 "" "" ""
check "nvidia" nvidia gpu_busy EMPTY
check "nvidia" nvidia gpu_temp EMPTY

echo "nouveau alongside AMD - utilisation outranks a temperature-only card"
card mixed card0 ""    ""            "60000"
card mixed card1 "12"  "8589934592"  "45000"
check "mixed" mixed gpu_busy "card1"
check "mixed" mixed gpu_temp "card1"

echo "AMD with less VRAM than a temperature-only card - utilisation still wins"
card rank card0 ""   "34359738368" "60000"
card rank card1 "3"  "8589934592"  "45000"
check "rank" rank gpu_busy "card1"

echo "coretemp - Package id 0 label wins over bare temp inputs"
hwmon_tree coretemp hwmon0 coretemp
printf 'Package id 0\n' >"$work/coretemp/hwmon0/temp1_label"
printf '45000\n' >"$work/coretemp/hwmon0/temp1_input"
printf '47000\n' >"$work/coretemp/hwmon0/temp2_input"
expect_line "coretemp package sensor" coretemp \
  "$(printf 'cpu_temp\t%s/hwmon0/temp1_input' "$work/coretemp")"
expect_key_absent "coretemp emits no platform sensors" coretemp platform_sensor

echo "macsmc_hwmon - labelled temps and power rails become platform sensors"
hwmon_tree macsmc hwmon2 macsmc_hwmon
printf 'NAND Flash Temperature  \n' >"$work/macsmc/hwmon2/temp1_label"
printf '38500\n' >"$work/macsmc/hwmon2/temp1_input"
printf '45000\n' >"$work/macsmc/hwmon2/temp2_input"
printf '29970000\n' >"$work/macsmc/hwmon2/power1_input"
printf 'Total System Power\n' >"$work/macsmc/hwmon2/power1_label"
printf 'Fan 1 \n' >"$work/macsmc/hwmon2/fan1_label"
printf '2417\n' >"$work/macsmc/hwmon2/fan1_input"
printf '1200\n' >"$work/macsmc/hwmon2/fan1_min"
printf '5779\n' >"$work/macsmc/hwmon2/fan1_max"
expect_line "macsmc labelled temp with trailing padding trimmed" macsmc \
  "$(printf 'platform_sensor\t%s/hwmon2/temp1_input\ttemp\tNAND Flash Temperature' "$work/macsmc")"
expect_line "macsmc unlabelled temp gets a numbered fallback" macsmc \
  "$(printf 'platform_sensor\t%s/hwmon2/temp2_input\ttemp\tTemperature 2' "$work/macsmc")"
expect_line "macsmc power rail keeps its label" macsmc \
  "$(printf 'platform_sensor\t%s/hwmon2/power1_input\tpower\tTotal System Power' "$work/macsmc")"
expect_line "macsmc fan record carries index, label and bounds" macsmc \
  "$(printf 'fan\t%s/hwmon2/fan1_input\t1\tFan 1\t1200\t5779' "$work/macsmc")"
expect_key_absent "macsmc emits no cpu_temp (there is no package sensor)" macsmc cpu_temp

echo "macsmc alongside coretemp - both are reported, neither masks the other"
hwmon_tree mixed-hwmon hwmon0 coretemp
printf 'Package id 0\n' >"$work/mixed-hwmon/hwmon0/temp1_label"
printf '52000\n' >"$work/mixed-hwmon/hwmon0/temp1_input"
hwmon_tree mixed-hwmon hwmon3 macsmc_hwmon
printf 'WiFi/BT Module Temp\n' >"$work/mixed-hwmon/hwmon3/temp1_label"
printf '45000\n' >"$work/mixed-hwmon/hwmon3/temp1_input"
expect_line "mixed coretemp still wins cpu_temp" mixed-hwmon \
  "$(printf 'cpu_temp\t%s/hwmon0/temp1_input' "$work/mixed-hwmon")"
expect_line "mixed macsmc still lists its sensors" mixed-hwmon \
  "$(printf 'platform_sensor\t%s/hwmon3/temp1_input\ttemp\tWiFi/BT Module Temp' "$work/mixed-hwmon")"

echo "NVIDIA via nvidia-smi - the NVML card is reported instead of the iGPU"
card nvml-hybrid card0 "0" "536870912" ""
fake_smi="$work/fake-nvidia-smi"
printf '#!/bin/bash\nprintf "1, NVIDIA GeForce RTX 5060 Ti\\n"\n' >"$fake_smi"
chmod +x "$fake_smi"

probe_nvidia() { # <name> <tree> [smi]
  OMARCHY_SYSMON_NVIDIA_SMI="${3:-$fake_smi}" \
    OMARCHY_SYSMON_DRM_ROOT="$work/$2" bash "$script"
}

expect_nvml() { # <name> <tree> <exact-line>
  local found=0 line
  while IFS= read -r line; do
    if [[ "$line" == "$3" ]]; then found=1; break; fi
  done <<<"$(probe_nvidia "$1" "$2")"
  if (( found )); then echo "  ok   $1"; else
    echo "  FAIL $1: expected line '$3'"; failures=$((failures+1)); fi
}

expect_nvml_absent() { # <name> <tree> <smi>
  local found=0 line
  while IFS= read -r line; do
    if [[ "$line" == "gpu_nvml"$'\t'* ]]; then found=1; break; fi
  done <<<"$(probe_nvidia "$1" "$2" "$3")"
  if (( found )); then echo "  FAIL $1: gpu_nvml unexpectedly emitted"; failures=$((failures+1)); else
    echo "  ok   $1: gpu_nvml absent"; fi
}

expect_nvml "nvidia-smi reports index and card name" nvml-hybrid \
  "$(printf 'gpu_nvml\t1\tNVIDIA GeForce RTX 5060 Ti')"

# The iGPU still publishes gpu_busy_percent, but reporting it while the
# discrete card works is the bug this covers: 0% from the AMD adapter.
busy_lines="$(probe_nvidia nvml-hybrid nvml-hybrid | grep -c '^gpu_busy' || true)"
if [[ "$busy_lines" == "0" ]]; then echo "  ok   nvidia: iGPU utilisation not reported"
else echo "  FAIL nvidia: iGPU gpu_busy still emitted"; failures=$((failures+1)); fi

echo "nvidia-smi that fails or prints nothing - falls back to the sysfs card"
printf '#!/bin/bash\nexit 9\n' >"$fake_smi"
expect_nvml_absent "failing nvidia-smi" nvml-hybrid "$fake_smi"
check "failing nvidia-smi" nvml-hybrid gpu_busy "card0"
printf '#!/bin/bash\nprintf "not an index\\n"\n' >"$fake_smi"
expect_nvml_absent "unparseable nvidia-smi" nvml-hybrid "$fake_smi"

echo
if (( failures == 0 )); then echo "all discovery fixtures passed"; else
  echo "$failures failing check(s)"; exit 1; fi
