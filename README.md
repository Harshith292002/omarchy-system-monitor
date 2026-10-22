# System Monitor for Omarchy

[![Omarchy 4.0+](https://img.shields.io/badge/Omarchy-4.0%2B-c6aa75?style=flat-square)](https://omarchy.org/manual/shell-plugins/)
[![Validate](https://img.shields.io/github/actions/workflow/status/Harshith292002/omarchy-system-monitor/validate.yml?branch=main&style=flat-square&label=validate)](https://github.com/Harshith292002/omarchy-system-monitor/actions/workflows/validate.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-6aa6b2?style=flat-square)](LICENSE)

A low-overhead dashboard for the Omarchy bar. System Monitor reads Linux
metrics directly from `/proc` and `/sys`, so it stays responsive without a
background daemon or telemetry service.

![System Monitor dashboard preview](preview.png)

<p align="center"><sub>Built from a live Omarchy capture; system identifiers anonymized.</sub></p>

## Highlights

- Adaptive bar widget that can show CPU, memory, GPU, or both
- Expandable dashboard for CPU, RAM, temperature, load, and uptime
- Platform sensor section on Apple Silicon (Asahi): every labelled SMC
  temperature and power rail, since no SoC die sensor exists there
- Fan control on Apple Silicon (optional, via the `asahi-fanctl` helper):
  live RPMs, SMC/Auto plus Quiet, Boost, Full, and custom heatpipe-power
  curve presets
- Bar `Temp` mode: heatpipe watts on Asahi (`HEAT`), package °C elsewhere
  (`TEMP`); never selected by Adaptive
- GPU utilization, temperature, and VRAM, with per-sensor vendor fallbacks
- Two-minute CPU, memory, and GPU history with per-core utilization
- Mirrored network throughput history on a shared scale
- Automatic disk discovery with live read and write rates
- Root, swap, and every mounted local disk in one capacity section, discovered automatically
- Configurable refresh intervals and warning thresholds
- Native Omarchy styling with no bundled theme or hard-coded palette

<p align="center">
  <img src="docs/screenshots/system-monitor-panel.png" alt="System Monitor panel with CPU, memory, temperature, network, disk throughput, and a capacity section listing the root filesystem, swap, and an auto-discovered boot partition" width="485">
</p>

## Install

System Monitor requires Omarchy 4.0 or newer with shell plugin support.

```sh
omarchy plugin add https://github.com/Harshith292002/omarchy-system-monitor.git --enable
```

The shell normally picks up the plugin immediately. If the widget does not
appear, restart it once:

```sh
omarchy restart shell
```

## Use

| Action | Result |
| --- | --- |
| Left-click | Open or close the dashboard |
| Right-click | Cycle `Adaptive` → `CPU` → `Memory` → `Both` → `Icon` (`GPU` is added to the cycle automatically when a card publishes a utilization counter) |
| Middle-click | Open `btop` |
| `R` while open | Refresh metrics now |
| `B` while open | Open `btop` |

Adaptive mode displays whichever of CPU or memory is currently under more
pressure. Warning and critical colors follow the active Omarchy theme.

## Metrics

| Area | Source |
| --- | --- |
| CPU, per-core load, and uptime | `/proc/stat`, `/proc/loadavg`, `/proc/uptime` |
| Memory and swap | `/proc/meminfo` |
| Network throughput | `/proc/net/route`, `/proc/net/dev` |
| Disk throughput | `/proc/diskstats` and `/sys/class/block` |
| CPU temperature | `/sys/class/hwmon` (`coretemp`, `k10temp`, or `zenpower`) |
| Platform sensors (Apple Silicon/Asahi) | `/sys/class/hwmon` (`macsmc_hwmon` labelled temps and power rails) |
| GPU load, temperature, and VRAM | `/sys/class/drm/card*/device` (`gpu_busy_percent`, `hwmon`, `mem_info_vram_*`) |
| Filesystem capacity | `df -P -k -l -T` |

Temperature is shown when a supported package sensor is available. Apple
Silicon Macs on Asahi have none — the SoC's die temperatures live in the PMU,
not sysfs — so the headline tile there shows heatpipe power (the SMC's
estimate of the watts the SoC is dissipating; it tracks the warmth you feel
and drives the fan curves), the SENSORS section lists every labelled
`macsmc_hwmon` reading, and the bar tint follows heatpipe watts and the
hottest platform temperature. Disk
activity aggregates physical devices and ignores loop, RAM, zram, floppy, and
optical devices.

The capacity section lists the root filesystem, swap, and every other local
disk `df` reports. Pseudo filesystems (tmpfs, overlay, squashfs, and so on)
and network mounts are excluded by an on-disk-type allowlist, and subvolumes
or bind mounts on one device are shown once. Removable drives appear and
disappear as they are mounted. Nothing to configure.

Each GPU tile is gated on its own sensor, because vendors expose different
subsets:

| Driver | Utilization | Temperature | VRAM |
| --- | --- | --- | --- |
| `amdgpu` | yes | yes (`temp1_input`) | yes |
| `i915` (Intel, pre-Arc) | no | yes, kernel 6.12+ (`temp1_input`) | no |
| `xe` (Intel, Arc/Meteor Lake/Lunar Lake+) | no | yes, kernel 6.15+ (`temp2_input` — `xe` has no `temp1`) | no |
| `nouveau` | no | yes (`temp1_input`) | no |
| NVIDIA proprietary | no | no | no |

Only `amdgpu` publishes a device-wide utilization counter in sysfs. Intel
exposes utilization through the PMU or per-client `fdinfo`, both of which need
either elevated capabilities or per-process accounting. The NVIDIA proprietary
driver doesn't register a `hwmon` device at all — not even for temperature —
so every reading, utilization included, requires NVML (`nvidia-smi`). Reading
any of these would mean spawning a helper process on every sample, which this
plugin deliberately avoids, so a card that cannot be read is left out rather
than reported as idle, and NVIDIA is unsupported outright.

A card with a temperature sensor but no utilization counter still gets a
section, showing just the tiles it can fill. When nothing is readable, the
panel keeps its original layout untouched.

Cards are ranked so one publishing utilization wins outright, then by video
memory, which picks the discrete adapter on hybrid systems without hard-coding
device identifiers. Two temperature-only cards in one machine — an Intel iGPU
next to an Arc card, for instance — cannot currently be told apart, and the
first is used.

## Fan control (Apple Silicon, optional)

On Asahi machines the panel grows a FANS section when the `asahi-fanctl`
helper and its `asahi-fand` systemd daemon are installed. Nothing is
required for the monitoring features — without the helper the section
simply explains that control is unavailable.

| Preset | Behavior |
| --- | --- |
| Auto | Fans are handed back to the SMC's automatic curve (Apple's firmware) |
| Quiet | Idles at the fan minimum, ramps from 6 W, capped at ~65% of range |
| Boost | Audible ~30% floor even at idle, 100% of range by 14 W |
| Full | Maximum RPM |
| Custom | Your own curve: RPM scales between two bounds as heatpipe power crosses a watt window, with an optional always-at-least floor |

The presets are deliberately far apart — Quiet and Boost differ by more
than 1200 RPM at idle. Live RPM rows show the effect of a preset change
immediately. The sensors section charts the thermal headline (heatpipe
watts on Asahi, package temperature elsewhere) over a two-minute window.

### Heatpipe power (definition)

On Apple Silicon under Asahi, **heatpipe power** is the SMC’s estimate of
how many watts the SoC is dumping through its heatpipes. It is **not** die
temperature (°C) and **not** chassis skin temperature — those die sensors
are not exposed in sysfs. The HEAT tile and optional bar `Temp` mode show
this value because it is the best available proxy for SoC thermal load and
the same input the fan curves follow.

Why heatpipe power and not CPU temperature: Asahi does not expose SoC die
temperatures — they live in the PMU. The SMC's heatpipe power reading is an
estimate of the heat the SoC is dissipating, which makes it the best
available proxy for how hard the chip is working.

Safety model, in order: any platform sensor at or above the critical
threshold (default 70°C, `CRITICAL_TEMP_C` in `/etc/asahi-fand.conf`)
forces maximum RPM and sends a notification; stopping or crashing the
daemon hands every fan back to the SMC (`ExecStopPost`); and a suspend hook
restores automatic control before sleep. While a preset other than Auto is
active the SMC does **not** manage the fans — the bar widget tints to say
so.

The helper is invoked through a targeted sudoers rule
(`NOPASSWD: /usr/local/bin/asahi-fanctl`); it validates every argument
(mode whitelist, per-fan RPM bounds) before touching sysfs.

## Configure

Open **Setup → Plugins → System Monitor** to change these values:

| Setting | Default | Range or behavior |
| --- | ---: | --- |
| Bar display | Adaptive | `Adaptive`, `CPU`, `Memory`, `GPU`, `Both`, or `Icon` (glyph only; still tints at warning/critical) |
| Closed refresh | 5 s | 2–60 seconds |
| Open refresh | 2 s | 1–10 seconds |
| Warning threshold | 80% | 50–95% |
| Critical threshold | 95% | 60–100% |
| Network interface | Automatic | Leave empty to follow the default route |

## Update

```sh
omarchy plugin update harshith.system-monitor --yes
```

## Remove

```sh
omarchy plugin remove harshith.system-monitor --yes
```

Removing the plugin removes its widget and checkout. It does not change system
packages or files outside Omarchy's plugin configuration.

## Dependencies and privacy

There are no third-party packages or services to install. The plugin uses
`bash` and `df`, which are part of a standard Omarchy installation. `btop` is
optional and is only launched when you request it.

All monitoring stays on-device. The plugin does not use the network, write a
metrics database, collect credentials, or send telemetry. Its only persistent
state is the widget configuration managed by Omarchy in
`~/.config/omarchy/shell.json`.

## Development

Validate the manifest and run the model tests from a checkout:

```sh
omarchy plugin validate .
node --test tests/model.test.js
bash tests/discovery.test.sh
```

Changes inside an installed plugin directory normally hot-reload. Restart the
shell if a QML component remains cached:

```sh
omarchy restart shell
```

## License

[MIT](LICENSE) © 2026 Harshith Chennupati.
