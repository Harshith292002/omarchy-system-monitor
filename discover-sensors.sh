#!/bin/bash

shopt -s nullglob

for hwmon in /sys/class/hwmon/hwmon*; do
  [[ -r "$hwmon/name" ]] || continue
  IFS= read -r name <"$hwmon/name"
  [[ "$name" == "coretemp" || "$name" == "k10temp" || "$name" == "zenpower" ]] || continue

  selected=""
  for label_file in "$hwmon"/temp*_label; do
    IFS= read -r label <"$label_file"
    if [[ "$label" == "Package id 0" || "$label" == "Tctl" ]]; then
      candidate="${label_file%_label}_input"
      [[ -r "$candidate" ]] && selected="$candidate"
      break
    fi
  done

  if [[ -z "$selected" ]]; then
    for candidate in "$hwmon"/temp*_input; do
      [[ -r "$candidate" ]] && selected="$candidate" && break
    done
  fi

  if [[ -n "$selected" ]]; then
    printf 'cpu_temp\t%s\n' "$selected"
    break
  fi
done

for block_path in /sys/class/block/*; do
  device="${block_path##*/}"
  [[ -e "$block_path/partition" ]] && continue
  [[ -e "$block_path/device" ]] || continue
  case "$device" in
    loop*|ram*|zram*|fd*|sr*) continue ;;
  esac
  printf 'disk\t%s\n' "$device"
done

# GPU. Vendors expose different subsets, so each sensor is probed on its own
# rather than gated behind one capability:
#
#   amdgpu        gpu_busy_percent, hwmon temperature (temp1_input), mem_info_vram_*
#   i915          hwmon temperature only (temp1_input); no device-wide busy
#                 counter exists in sysfs, utilisation needs the PMU or
#                 per-client fdinfo
#   xe            hwmon temperature only, but as temp2_input: xe's hwmon ABI
#                 numbers package temp starting at 2, there is no temp1 (see
#                 Documentation/ABI/testing/sysfs-driver-intel-xe-hwmon)
#   nouveau       hwmon temperature only (temp1_input)
#   NVIDIA prop.  nothing readable via sysfs at all, not even temperature —
#                 every reading requires NVML (nvidia-smi), which means a
#                 helper process. Deliberately left unsupported rather than
#                 spawning one per sample.
#
# Cards are ranked so one publishing utilisation wins outright, then by video
# memory. That keeps the discrete adapter on hybrid systems without hardcoding
# device IDs, and still reports a temperature-only card when it is all there is.
# Overridable so the discovery logic can be exercised against fixture trees
# that stand in for hardware this machine does not have.
drm_root="${OMARCHY_SYSMON_DRM_ROOT:-/sys/class/drm}"

best_rank=-1
best_vram=-1
gpu_busy=""
gpu_temp=""
gpu_vram_used=""
gpu_vram_total=""
gpu_gtt_used=""
gpu_gtt_total=""

for card in "$drm_root"/card*; do
  name="${card##*/}"
  [[ "$name" =~ ^card[0-9]+$ ]] || continue
  device="$card/device"
  [[ -d "$device" ]] || continue

  busy=""
  [[ -r "$device/gpu_busy_percent" ]] && busy="$device/gpu_busy_percent"

  # temp1_input covers amdgpu, i915, and nouveau. xe has no temp1 at all —
  # its package sensor starts numbering at temp2 — so that is checked as a
  # fallback rather than a replacement.
  temp=""
  for hwmon in "$device"/hwmon/hwmon*; do
    if [[ -r "$hwmon/temp1_input" ]]; then
      temp="$hwmon/temp1_input"
    elif [[ -r "$hwmon/temp2_input" ]]; then
      temp="$hwmon/temp2_input"
    else
      continue
    fi
    break
  done

  # Nothing readable here — an NVIDIA card on the proprietary driver, or a
  # display-only device. Reporting it would mean a panel full of dashes.
  [[ -n "$busy" || -n "$temp" ]] || continue

  vram=0
  [[ -r "$device/mem_info_vram_total" ]] && IFS= read -r vram <"$device/mem_info_vram_total"
  [[ "$vram" =~ ^[0-9]+$ ]] || vram=0

  if [[ -n "$busy" ]]; then rank=2; else rank=1; fi
  if (( rank > best_rank )) || { (( rank == best_rank )) && (( vram > best_vram )); }; then
    best_rank=$rank
    best_vram=$vram
    gpu_busy="$busy"
    gpu_temp="$temp"
    gpu_vram_used=""
    gpu_vram_total=""
    gpu_gtt_used=""
    gpu_gtt_total=""
    [[ -r "$device/mem_info_vram_used" ]] && gpu_vram_used="$device/mem_info_vram_used"
    [[ -r "$device/mem_info_vram_total" ]] && gpu_vram_total="$device/mem_info_vram_total"
    [[ -r "$device/mem_info_gtt_used" ]] && gpu_gtt_used="$device/mem_info_gtt_used"
    [[ -r "$device/mem_info_gtt_total" ]] && gpu_gtt_total="$device/mem_info_gtt_total"
  fi
done

[[ -n "$gpu_busy" ]] && printf 'gpu_busy\t%s\n' "$gpu_busy"
[[ -n "$gpu_temp" ]] && printf 'gpu_temp\t%s\n' "$gpu_temp"
[[ -n "$gpu_vram_used" ]] && printf 'gpu_vram_used\t%s\n' "$gpu_vram_used"
[[ -n "$gpu_vram_total" ]] && printf 'gpu_vram_total\t%s\n' "$gpu_vram_total"
[[ -n "$gpu_gtt_used" ]] && printf 'gpu_gtt_used\t%s\n' "$gpu_gtt_used"
[[ -n "$gpu_gtt_total" ]] && printf 'gpu_gtt_total\t%s\n' "$gpu_gtt_total"
exit 0
