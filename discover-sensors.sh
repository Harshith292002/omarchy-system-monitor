#!/bin/bash

shopt -s nullglob

# Overridable so the CPU-temperature and platform-sensor discovery can be
# exercised against fixture hwmon trees, mirroring the DRM root below.
hwmon_root="${OMARCHY_SYSMON_HWMON_ROOT:-/sys/class/hwmon}"

for hwmon in "$hwmon_root"/hwmon*; do
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

# Apple Silicon (Asahi Linux) publishes no package sensor at all — the SoC's
# die temperatures live in the PMU and never reach sysfs — so x86-only driver
# matching above finds nothing. The SMC hwmon driver instead carries labelled
# platform sensors: peripheral temperatures and power rails, including a
# heatpipe power estimate that tracks the heat the SoC is dissipating. Those
# are listed here so the panel can show every reading that does exist.
for hwmon in "$hwmon_root"/hwmon*; do
  [[ -r "$hwmon/name" ]] || continue
  IFS= read -r name <"$hwmon/name"
  [[ "$name" == "macsmc_hwmon" ]] || continue

  for input in "$hwmon"/temp*_input; do
    [[ -r "$input" ]] || continue
    label=""
    label_file="${input%_input}_label"
    if [[ -r "$label_file" ]]; then
      IFS= read -r label <"$label_file"
      # sysfs labels may carry trailing padding; trim whitespace from both
      # ends without touching spaces inside the label itself.
      label="${label#"${label%%[![:space:]]*}"}"
      label="${label%"${label##*[![:space:]]}"}"
    fi
    if [[ -z "$label" ]]; then
      # ".../temp3_input" -> "Temperature 3"
      label="Temperature ${input##*temp}"
      label="${label%_input}"
    fi
    printf 'platform_sensor\t%s\ttemp\t%s\n' "$input" "$label"
  done

  for input in "$hwmon"/power*_input; do
    [[ -r "$input" ]] || continue
    label=""
    label_file="${input%_input}_label"
    if [[ -r "$label_file" ]]; then
      IFS= read -r label <"$label_file"
      label="${label#"${label%%[![:space:]]*}"}"
      label="${label%"${label##*[![:space:]]}"}"
    fi
    if [[ -z "$label" ]]; then
      # ".../power2_input" -> "Power 2"
      label="Power ${input##*power}"
      label="${label%_input}"
    fi
    printf 'platform_sensor\t%s\tpower\t%s\n' "$input" "$label"
  done

  # Fans: the input path plus the driver's RPM window, so the panel can poll
  # live speeds straight from sysfs without shelling out.
  for input in "$hwmon"/fan*_input; do
    [[ -r "$input" ]] || continue
    label=""
    label_file="${input%_input}_label"
    if [[ -r "$label_file" ]]; then
      IFS= read -r label <"$label_file"
      label="${label#"${label%%[![:space:]]*}"}"
      label="${label%"${label##*[![:space:]]}"}"
    fi
    fan_index="${input##*fan}"
    fan_index="${fan_index%_input}"
    [[ -z "$label" ]] && label="Fan $fan_index"
    min=""
    [[ -r "${input%_input}_min" ]] && IFS= read -r min <"${input%_input}_min"
    max=""
    [[ -r "${input%_input}_max" ]] && IFS= read -r max <"${input%_input}_max"
    printf 'fan\t%s\t%s\t%s\t%s\t%s\n' "$input" "$fan_index" "$label" "${min:-0}" "${max:-0}"
  done

  break
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

# GPU. Two very different worlds:
#
#   sysfs         amdgpu         gpu_busy_percent, hwmon temperature
#                               (temp1_input), mem_info_vram_*
#                 i915          hwmon temperature only (temp1_input); no
#                               device-wide busy counter exists in sysfs,
#                               utilisation needs the PMU or per-client fdinfo
#                 xe            hwmon temperature only, but as temp2_input:
#                               xe's hwmon ABI numbers package temp starting
#                               at 2, there is no temp1 (see
#                               Documentation/ABI/testing/sysfs-driver-intel-xe-hwmon)
#                 nouveau       hwmon temperature only (temp1_input)
#
#   NVIDIA prop.  nothing readable via sysfs at all, not even temperature —
#                 every reading requires NVML, whose userland face is
#                 nvidia-smi. Reported as "gpu_nvml" so the panel can poll it
#                 with one short-lived helper per sample instead of a FileView.
#
# Sysfs cards are ranked so one publishing utilisation wins outright, then by
# video memory, which keeps the discrete adapter on hybrid systems without
# hardcoding device IDs. A working nvidia-smi outranks both: on a hybrid pair
# the integrated card reads 0% while the real work happens on the NVIDIA one,
# so reporting the iGPU would be a lie rather than a preference. Both roots
# are overridable so the discovery logic can be exercised against fixture
# trees that stand in for hardware this machine does not have.
drm_root="${OMARCHY_SYSMON_DRM_ROOT:-/sys/class/drm}"
nvidia_smi="${OMARCHY_SYSMON_NVIDIA_SMI:-nvidia-smi}"

nvidia_gpu=""
if command -v "$nvidia_smi" >/dev/null 2>&1; then
  # One line per card: "0, NVIDIA GeForce RTX 5060 Ti". `timeout` keeps a
  # wedged driver from stalling discovery, and the first card is the one the
  # panel shows — multi-GPU boxes still get a working reading, not a matrix.
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    nvidia_gpu="$line"
    break
  done < <(timeout 5 "$nvidia_smi" --query-gpu=index,name \
             --format=csv,noheader 2>/dev/null)
fi

if [[ -n "$nvidia_gpu" ]]; then
  nvidia_index="${nvidia_gpu%%,*}"
  nvidia_index="${nvidia_index//[[:space:]]/}"
  nvidia_name="${nvidia_gpu#*,}"
  nvidia_name="${nvidia_name#"${nvidia_name%%[![:space:]]*}"}"
  [[ -n "$nvidia_index" && "$nvidia_index" =~ ^[0-9]+$ ]] \
    && printf 'gpu_nvml\t%s\t%s\n' "$nvidia_index" "$nvidia_name"
  exit 0
fi

best_rank=-1
best_vram=-1
gpu_busy=""
gpu_temp=""
gpu_vram_used=""
gpu_vram_total=""

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
    [[ -r "$device/mem_info_vram_used" ]] && gpu_vram_used="$device/mem_info_vram_used"
    [[ -r "$device/mem_info_vram_total" ]] && gpu_vram_total="$device/mem_info_vram_total"
  fi
done

[[ -n "$gpu_busy" ]] && printf 'gpu_busy\t%s\n' "$gpu_busy"
[[ -n "$gpu_temp" ]] && printf 'gpu_temp\t%s\n' "$gpu_temp"
[[ -n "$gpu_vram_used" ]] && printf 'gpu_vram_used\t%s\n' "$gpu_vram_used"
[[ -n "$gpu_vram_total" ]] && printf 'gpu_vram_total\t%s\n' "$gpu_vram_total"
exit 0
