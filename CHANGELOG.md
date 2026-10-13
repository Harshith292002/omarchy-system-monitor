# Changelog

All notable changes to this project will be documented in this file.

## 1.5.2 - 2026-09-17

- Apple Silicon SENSORS default list is shorter (battery hotspot, charge
  regulator, total system power, heatpipe) with the rest behind
  “Show all sensors”
- New bar display mode `Temp`: shows heatpipe watts as `HEAT` on Asahi, or
  package/platform °C as `TEMP` elsewhere. Not part of Adaptive (still
  CPU vs RAM only)
- HEAT tile detail is factual (`heatpipe`) — no cool/warm/hot feel labels

## 1.5.1 - 2026-09-17

- Drop the RPM history sparkline from the fans section (live RPM rows and
  presets stay). Thermal headline chart in sensors is unchanged.

## 1.5.0 - 2026-09-17

- Rework the Apple Silicon fans section around history charts: two minutes
  of RPM per fan (one line each on a shared scale) so switching presets
  shows its effect immediately, and a thermal-headline chart in the sensors
  section plotting the same value the HEAT tile carries — heatpipe watts on
  Asahi, package temperature elsewhere. Fan speeds now come straight from
  sysfs, so the history accumulates even with the panel closed
- Drop the Balanced preset: it sat between Quiet and SMC Auto and was
  indistinguishable from both. Quiet and Boost are now deliberately far
  apart — Quiet idles at the fan minimum and caps at ~65% of range; Boost
  holds a ~30% floor even at idle and reaches 100% by 14 W. One preset row
- Fan RPMs, targets, and the control-lock state now come from watched
  sysfs files instead of a per-tick helper poll; the helper is queried once
  per panel open for the daemon's own state

## 1.4.2 - 2026-09-17

- The headline tile on machines with no package sensor now shows heatpipe
  power ("HEAT 12.4 W · SoC · no die sensor") instead of the warmest exposed
  peripheral temperature. The warmest sensor could read mild while the SoC
  ran far hotter out of sight, which read as the machine's peak and misled.
  Heatpipe power is the SMC's estimate of the watts the SoC is dissipating —
  it tracks the warmth you actually feel and is the same input the fan
  curves follow. The bar tints from 15 W (critical at 25 W). The warmest
  exposed temperature still headlines when no power sensor exists (labelled
  "warmest: ..."), and the SENSORS section is unchanged.

## 1.4.1 - 2026-09-17

- The TEMP tile now carries the hottest platform sensor on machines with no
  package sensor, its detail line naming the source (e.g. "Charge Regulator
  · peak"), instead of a dead dash that read like a discovery failure. The
  SENSORS section still lists every reading.

## 1.4.0 - 2026-09-17

- Add an Apple Silicon fan control section. When the optional `asahi-fanctl`
  helper and its `asahi-fand` systemd daemon are installed, the panel shows
  live fan RPMs and a preset selector: Auto (the SMC's own curve), Quiet,
  Balanced, and Boost (curves driven by heatpipe power), Full, or a custom
  heatpipe-power curve edited inline. The bar tints while any non-auto preset
  is active — that means the SMC's automatic management is overridden and
  software is the safety net. Machines without the SMC hwmon device never
  see the section, and the helper is never required for monitoring.

## 1.3.0 - 2026-09-17

- Add an Apple Silicon (Asahi Linux) sensors section: `macsmc_hwmon` publishes
  no package sensor — SoC die temperatures live in the PMU and never reach
  sysfs — but it does carry labelled peripheral temperatures and power rails,
  including a heatpipe power estimate. Every readable sensor is now listed in
  a SENSORS section, with the hottest temperature driving the bar's
  warning/critical tint and the tooltip's peak reading
- The temperature tile says "No SoC sensor" on those machines instead of a
  bare "Unavailable", making clear the dash is a platform limitation rather
  than a discovery failure
- The hwmon discovery root is overridable via `OMARCHY_SYSMON_HWMON_ROOT` for
  fixture tests, mirroring the DRM root

## 1.2.0 - 2026-08-31

- Add an `Icon` bar display mode: the plugin glyph alone, no live text, for
  bars that should stay quiet. It still tints at warning/critical pressure and
  keeps the tooltip and dashboard; right-click cycling includes it
- List every mounted local disk in the capacity section automatically, one row
  per physical device, alongside the existing root and swap meters. Pseudo and
  network filesystems (tmpfs, overlay, squashfs, NFS, and the like) are left
  out, and subvolumes or bind mounts on one device collapse to a single row.
  No configuration.
- Render auto-discovered mount labels as plain text, so a mount path can never
  be interpreted as rich text in the shared shell process

## 1.1.1 - 2026-08-26

- Fix GPU temperature discovery on the `xe` driver (Intel Arc, Meteor Lake,
  Lunar Lake and newer): its hwmon package sensor is `temp2_input`, not
  `temp1_input`, so those cards previously reported no temperature at all
- Document that NVIDIA's proprietary driver exposes no sysfs data whatsoever,
  not even temperature, and is unsupported by design rather than by omission

## 1.0.1 - 2026-08-20

- Render configuration-derived network interface names as plain text
- Escape interface-name markup before passing it to the shared bar tooltip

## 1.0.0 - 2026-08-20

Initial public release.

- Bar widget with adaptive CPU and memory display modes
- Expandable dashboard with sparklines, per-core load, network, disk, and capacity sections
- Automatic CPU temperature and disk device discovery
- Configurable refresh intervals and warning thresholds
