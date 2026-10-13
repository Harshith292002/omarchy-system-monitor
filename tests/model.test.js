const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Metrics.js")

const root = path.join(__dirname, "..")

const sampleStat = [
  "cpu  3357 0 4323 422382 0 0 0 0 0 0",
  "cpu0 1000 0 500 100000 0 0 0 0 0 0",
  "cpu1 800 0 400 90000 0 0 0 0 0 0"
].join("\n")

const previousStat = [
  "cpu  3000 0 4000 400000 0 0 0 0 0 0",
  "cpu0 900 0 450 95000 0 0 0 0 0 0",
  "cpu1 700 0 350 85000 0 0 0 0 0 0"
].join("\n")

test("cpu parser derives overall and per-core usage from consecutive samples", () => {
  const parsed = Model.parseCpu(sampleStat, Model.parseCpu(previousStat, null).snapshot)
  assert.ok(parsed.overall >= 0 && parsed.overall <= 100)
  assert.equal(parsed.cores.length, 2)
  assert.equal(parsed.cores[0].name, "CPU0")
})

test("memory parser converts kilobyte meminfo fields into byte totals", () => {
  const raw = [
    "MemTotal:       16384000 kB",
    "MemAvailable:    8192000 kB",
    "SwapTotal:       4194304 kB",
    "SwapFree:        2097152 kB"
  ].join("\n")
  const parsed = Model.parseMemory(raw)
  assert.equal(parsed.total, 16384000 * 1024)
  assert.equal(parsed.used, 8192000 * 1024)
  assert.equal(parsed.percent, 50)
  assert.equal(parsed.swapPercent, 50)
})

test("network parser follows the selected interface counters", () => {
  const raw = [
    "Inter-|   Receive                                                |  Transmit",
    " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed",
    "  lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0",
    "wlan0: 5000 20 0 0 0 0 0 0 7000 30 0 0 0 0 0 0"
  ].join("\n")
  assert.deepEqual(Model.parseNetwork(raw, "wlan0"), { rx: 5000, tx: 7000 })
  assert.equal(Model.parseDefaultInterface("Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\nwlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n"), "wlan0")
})

test("configuration-derived labels cannot become rich text", () => {
  const crafted = "<img src=\"https://example.invalid/pixel?x=1&y='2'\">"
  assert.equal(
    Model.escapeMarkup(crafted),
    "&lt;img src=&quot;https://example.invalid/pixel?x=1&amp;y=&#39;2&#39;&quot;&gt;"
  )

  const qml = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
  assert.match(qml, /Model\.escapeMarkup\(metrics\.activeInterface\)/)
  assert.match(qml, /id: headingText[\s\S]{0,160}textFormat: Text\.PlainText/)
  assert.doesNotMatch(qml, /" · " \+ metrics\.activeInterface/)
})

test("discovery parser maps sensor probe output into runtime paths", () => {
  const raw = [
    "cpu_temp\t/sys/class/hwmon/hwmon2/temp1_input",
    "disk\tnvme0n1",
    "disk\tsda"
  ].join("\n")
  assert.deepEqual(Model.parseDiscovery(raw), {
    cpuTempPath: "/sys/class/hwmon/hwmon2/temp1_input",
    gpuBusyPath: "",
    gpuTempPath: "",
    gpuVramUsedPath: "",
    gpuVramTotalPath: "",
    devices: ["nvme0n1", "sda"],
    platformSensors: [],
    fans: []
  })
})

test("discovery parser captures gpu sensor paths alongside cpu and disks", () => {
  const raw = [
    "cpu_temp\t/sys/class/hwmon/hwmon3/temp1_input",
    "disk\tnvme0n1",
    "gpu_busy\t/sys/class/drm/card1/device/gpu_busy_percent",
    "gpu_temp\t/sys/class/drm/card1/device/hwmon/hwmon1/temp1_input",
    "gpu_vram_used\t/sys/class/drm/card1/device/mem_info_vram_used",
    "gpu_vram_total\t/sys/class/drm/card1/device/mem_info_vram_total"
  ].join("\n")
  const parsed = Model.parseDiscovery(raw)
  assert.equal(parsed.gpuBusyPath, "/sys/class/drm/card1/device/gpu_busy_percent")
  assert.equal(parsed.gpuTempPath, "/sys/class/drm/card1/device/hwmon/hwmon1/temp1_input")
  assert.equal(parsed.gpuVramTotalPath, "/sys/class/drm/card1/device/mem_info_vram_total")
  assert.deepEqual(parsed.devices, ["nvme0n1"])
  assert.deepEqual(parsed.platformSensors, [])
  assert.deepEqual(parsed.fans, [])
})

test("discovery parser captures macsmc fan records with bounds", () => {
  const raw = [
    "fan\t/sys/class/hwmon/hwmon2/fan1_input\t1\tFan 1\t1200\t5779",
    "fan\t/sys/class/hwmon/hwmon2/fan2_input\t2\tFan 2\t1200\t6241",
    // Non-numeric bounds drop the record rather than half-parsing it.
    "fan\t/sys/class/hwmon/hwmon2/fan3_input\t3\tBroken\tNaN\t0",
    // A label containing a tab survives; bounds are the last two fields.
    "fan\t/sys/class/hwmon/hwmon2/fan4_input\t4\tLeft\tRight\t1200\t6241"
  ].join("\n")
  assert.deepEqual(Model.parseDiscovery(raw).fans, [
    { path: "/sys/class/hwmon/hwmon2/fan1_input", targetPath: "/sys/class/hwmon/hwmon2/fan1_target", index: 1, label: "Fan 1", min: 1200, max: 5779 },
    { path: "/sys/class/hwmon/hwmon2/fan2_input", targetPath: "/sys/class/hwmon/hwmon2/fan2_target", index: 2, label: "Fan 2", min: 1200, max: 6241 },
    { path: "/sys/class/hwmon/hwmon2/fan4_input", targetPath: "/sys/class/hwmon/hwmon2/fan4_target", index: 4, label: "Left\tRight", min: 1200, max: 6241 }
  ])
})

test("discovery parser captures macsmc platform sensors with kind and label", () => {
  const raw = [
    "platform_sensor\t/sys/class/hwmon/hwmon2/temp1_input\ttemp\tNAND Flash Temperature",
    "platform_sensor\t/sys/class/hwmon/hwmon2/power1_input\tpower\tTotal System Power",
    "platform_sensor\t/sys/class/hwmon/hwmon2/temp2_input\ttemp\tBattery Hotspot",
    // Unknown kinds are dropped rather than guessed at.
    "platform_sensor\t/sys/class/hwmon/hwmon2/curr1_input\tcurr\tCharger Current",
    // A label containing a tab survives: everything past the kind is the label.
    "platform_sensor\t/sys/class/hwmon/hwmon2/power4_input\tpower\tHeatpipe\tPower",
    // Malformed lines are skipped whole.
    "platform_sensor\t/sys/class/hwmon/hwmon2/temp9_input\ttemp"
  ].join("\n")
  const parsed = Model.parseDiscovery(raw)
  assert.equal(parsed.cpuTempPath, "")
  assert.deepEqual(parsed.platformSensors, [
    { path: "/sys/class/hwmon/hwmon2/temp1_input", kind: "temp", label: "NAND Flash Temperature" },
    { path: "/sys/class/hwmon/hwmon2/power1_input", kind: "power", label: "Total System Power" },
    { path: "/sys/class/hwmon/hwmon2/temp2_input", kind: "temp", label: "Battery Hotspot" },
    { path: "/sys/class/hwmon/hwmon2/power4_input", kind: "power", label: "Heatpipe\tPower" }
  ])
})

test("platform sensor values follow the hwmon ABI scale and reject junk", () => {
  assert.equal(Model.parseSensorValue("38500", "temp"), 38.5)
  assert.equal(Model.parseSensorValue("29970000", "power"), 29.97)
  // Zero is a real reading (a rail at rest), not a missing one.
  assert.equal(Model.parseSensorValue("0", "power"), 0)
  assert.equal(Model.parseSensorValue("", "temp"), -1)
  assert.equal(Model.parseSensorValue("   ", "temp"), -1)
  assert.equal(Model.parseSensorValue(null, "temp"), -1)
  assert.equal(Model.parseSensorValue("abc", "temp"), -1)
  // Negative readings are not published by these sensors; treat as missing.
  assert.equal(Model.parseSensorValue("-3", "temp"), -1)
})

test("gpu percent parser clamps to the 0-100 band and rejects missing readings", () => {
  assert.equal(Model.parseGpuPercent("6"), 6)
  assert.equal(Model.parseGpuPercent("150"), 100)
  // A blank sysfs read must not become 0%, which would claim an idle GPU.
  assert.equal(Model.parseGpuPercent(""), -1)
  assert.equal(Model.parseGpuPercent("   "), -1)
  assert.equal(Model.parseGpuPercent(null), -1)
  assert.equal(Model.parseGpuPercent("abc"), -1)
  assert.equal(Model.parseGpuPercent("-3"), -1)
})

test("byte counter parser distinguishes zero from unavailable", () => {
  assert.equal(Model.parseByteCount("17095983104"), 17095983104)
  assert.equal(Model.parseByteCount("0"), 0)
  assert.equal(Model.parseByteCount(""), -1)
  assert.equal(Model.parseByteCount("nope"), -1)
})

test("filesystem discovery lists real local disks and skips pseudo mounts", () => {
  const raw = [
    "Filesystem     Type   1024-blocks      Used  Available Capacity Mounted on",
    "/dev/nvme0n1p2 ext4     491252516 200000000  266000000      43% /",
    "/dev/nvme0n1p1 vfat        523248     55000     468248      11% /boot",
    "tmpfs          tmpfs      8143972       120    8143852       1% /run",
    "/dev/sda1      xfs     1952559104 500000000 1452559104      26% /mnt/data",
    "efivarfs       efivarfs       128        50         74      41% /sys/firmware/efi/efivars"
  ].join("\n")
  const result = Model.parseFilesystems(raw)
  assert.deepEqual(result.map((entry) => entry.mount), ["/", "/boot", "/mnt/data"])
  assert.equal(result[0].total, 491252516 * 1024)
  assert.equal(result[0].used, 200000000 * 1024)
  assert.ok(result[0].percent > 40 && result[0].percent < 42)
  assert.ok(!("device" in result[0]))
})

test("filesystem discovery collapses subvolumes on one device to a single row", () => {
  const raw = [
    "Filesystem Type  1024-blocks      Used Available Capacity Mounted on",
    "/dev/sda2  btrfs   976302080 400000000 574000000      42% /",
    "/dev/sda2  btrfs   976302080 400000000 574000000      42% /home",
    "/dev/sda2  btrfs   976302080 400000000 574000000      42% /.snapshots",
    "/dev/sdb1  ext4    488384000 100000000 363000000      22% /mnt/backup"
  ].join("\n")
  const result = Model.parseFilesystems(raw)
  assert.deepEqual(result.map((entry) => entry.mount), ["/", "/mnt/backup"])
})

test("filesystem discovery always keeps the root entry even with an unlisted type", () => {
  const raw = [
    "Filesystem Type    1024-blocks     Used Available Capacity Mounted on",
    "overlay    overlay   61202244 20000000  41202244      33% /",
    "tmpfs      tmpfs      8143972      100   8143872       1% /tmp"
  ].join("\n")
  const result = Model.parseFilesystems(raw)
  assert.deepEqual(result.map((entry) => entry.mount), ["/"])
  assert.equal(result[0].total, 61202244 * 1024)
})

test("filesystem discovery marks a zero-block filesystem unavailable", () => {
  const raw = [
    "Filesystem Type 1024-blocks Used Available Capacity Mounted on",
    "/dev/sdz1  ext4           0    0         0        - /mnt/pending"
  ].join("\n")
  const result = Model.parseFilesystems(raw)
  assert.equal(result.length, 1)
  assert.equal(result[0].total, 0)
  assert.equal(result[0].percent, -1)
})

test("filesystem discovery tolerates empty df output", () => {
  assert.deepEqual(Model.parseFilesystems(""), [])
  assert.deepEqual(
    Model.parseFilesystems("Filesystem Type 1024-blocks Used Available Capacity Mounted on"),
    []
  )
})

test("auto-discovered mount labels cannot become rich text", () => {
  const qml = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
  // df-derived mount paths reach CapacityRow's label, so that Text must pin
  // its format rather than letting Text.AutoText sniff a crafted path.
  assert.match(qml, /id: capacityLabel[\s\S]{0,320}textFormat: Text\.PlainText/)
})

test("manifest describes a public bar widget with configurable thresholds", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.id, "harshith.system-monitor")
  assert.equal(manifest.version, "1.5.2")
  assert.equal(manifest.license, "MIT")
  assert.equal(manifest.homepage, "https://github.com/Harshith292002/omarchy-system-monitor")
  assert.equal(manifest.barWidget.defaultSection, "right")
  assert.ok(manifest.barWidget.schema.some((entry) => entry.key === "warningPercent"))
  const barMode = manifest.barWidget.schema.find((entry) => entry.key === "barMode")
  assert.ok(barMode.options.includes("GPU"))
  assert.ok(barMode.options.includes("Temp"))
  assert.ok(barMode.options.includes("Icon"))
})

test("panel exposes bar cycling, btop launch, and live hostname title", () => {
  const qml = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
  assert.match(qml, /function cycleBarMode\(\)/)
  assert.match(qml, /function launchBtop\(\)/)
  assert.match(qml, /metrics\.hostname !== "" \? metrics\.hostname : "System Monitor"/)
  assert.doesNotMatch(qml, /\/home\//)
})

test("repository does not ship machine-specific paths or secrets", () => {
  const tracked = [
    "Panel.qml",
    "Metrics.qml",
    "Metrics.js",
    "Sparkline.qml",
    "discover-sensors.sh",
    "manifest.json",
    "README.md",
    ".github/workflows/validate.yml"
  ]
  for (const file of tracked) {
    const text = fs.readFileSync(path.join(root, file), "utf8")
    assert.doesNotMatch(text, /\/home\/[^/\s]+/)
    assert.doesNotMatch(text, /(api[_-]?key|password|secret|token)\s*[:=]/i)
  }
})

test("repository ships marketplace and README preview images", () => {
  const images = [
    "preview.png",
    "docs/screenshots/system-monitor-panel.png"
  ]
  const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

  for (const file of images) {
    const contents = fs.readFileSync(path.join(root, file))
    assert.deepEqual([...contents.subarray(0, 8)], pngSignature)
    assert.ok(contents.length > 10_000, `${file} should contain a real preview`)
  }
})
