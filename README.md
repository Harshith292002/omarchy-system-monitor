# Omarchy System Monitor

A low-overhead system dashboard for the Omarchy bar. It reads Linux `/proc`
and `/sys` directly, so there is no background daemon and no extra packages.

## Features

- Compact bar widget with adaptive, CPU-only, memory-only, or dual display modes
- Expandable panel with CPU, memory, temperature, load, and uptime
- Per-core utilization strip and two-minute CPU and memory sparklines
- Network throughput with mirrored up/down chart on a shared scale
- Disk read and write rates with automatic device discovery
- Root filesystem and swap capacity meters
- Configurable refresh intervals and warning thresholds
- Right-click cycles the bar display; middle-click opens btop

## Requirements

- Omarchy 4.0 or newer with shell plugin support
- Linux with standard `/proc` and `/sys` interfaces

## Install

```sh
omarchy plugin add https://github.com/Harshith292002/omarchy-system-monitor.git --enable
omarchy restart shell
```

## Update

```sh
omarchy plugin update harshith.system-monitor --yes
omarchy restart shell
```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Bar display | Adaptive | `Adaptive`, `CPU`, `Memory`, or `Both` |
| Closed refresh interval | 5 s | How often the bar polls while the panel is closed |
| Open refresh interval | 2 s | How often metrics refresh while the panel is open |
| Warning threshold | 80% | CPU or memory level that turns the bar warning color |
| Critical threshold | 95% | CPU or memory level that turns the bar urgent color |
| Network interface | empty | Leave empty to follow the default route |

Temperature discovery prefers package sensors on Intel (`coretemp`) and AMD
(`k10temp`, `zenpower`) hardware. Disk activity aggregates physical block
devices and skips loop, RAM, and optical drives.

## Development

The live plugin directory is also the Git checkout:

```sh
cd ~/.config/omarchy/plugins/harshith.system-monitor
omarchy plugin validate .
node --test tests/model.test.js
```

Changes under this directory are normally hot-reloaded by Omarchy. Restart the
shell when a changed QML component remains cached:

```sh
omarchy restart shell
```

## Privacy

This plugin reads live system metrics from the machine it runs on. Nothing is
sent off-device. The repository contains only plugin source code; no hostname,
network layout, or machine-specific configuration is stored here.

## License

MIT. See [LICENSE](LICENSE).
