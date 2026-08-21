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
    devices: ["nvme0n1", "sda"]
  })
})

test("manifest describes a public bar widget with configurable thresholds", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.id, "harshith.system-monitor")
  assert.equal(manifest.version, "1.0.1")
  assert.equal(manifest.license, "MIT")
  assert.equal(manifest.homepage, "https://github.com/Harshith292002/omarchy-system-monitor")
  assert.equal(manifest.barWidget.defaultSection, "right")
  assert.ok(manifest.barWidget.schema.some((entry) => entry.key === "warningPercent"))
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
