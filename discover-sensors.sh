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
