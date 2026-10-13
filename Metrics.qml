import QtQuick
import Quickshell
import Quickshell.Io
import "Metrics.js" as Model

Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false
  readonly property string pluginPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/harshith.system-monitor"
  readonly property int closedRefreshMs: Math.max(2000, Number(settings.closedRefreshSec || 5) * 1000)
  readonly property int openRefreshMs: Math.max(1000, Number(settings.openRefreshSec || 2) * 1000)
  readonly property string configuredInterface: String(settings.networkInterface || "").trim()
  readonly property string activeInterface: configuredInterface !== "" ? configuredInterface : autoInterface
  readonly property int historyWindowMs: 120000

  property real cpuPercent: -1
  property var perCore: []
  property real memoryPercent: -1
  property double memoryUsed: 0
  property double memoryTotal: 0
  property real swapPercent: -1
  property double swapUsed: 0
  property double swapTotal: 0
  property real loadOne: -1
  property real loadFive: -1
  property real loadFifteen: -1
  property double uptimeSeconds: 0
  property real cpuTemperature: -1
  property real gpuPercent: -1
  property real gpuTemperature: -1
  property double gpuVramUsed: -1
  property double gpuVramTotal: -1
  property real networkDownBps: -1
  property real networkUpBps: -1
  property real diskReadBps: -1
  property real diskWriteBps: -1
  property real filesystemPercent: -1
  property double filesystemUsed: 0
  property double filesystemTotal: 0
  property var extraFilesystems: []
  property string hostname: ""
  property string autoInterface: ""
  property string cpuTempPath: ""
  property string gpuBusyPath: ""
  property string gpuTempPath: ""
  property string gpuVramUsedPath: ""
  property string gpuVramTotalPath: ""
  property var diskDevices: []
  property double lastSampleMs: 0
  property double lastFilesystemRefreshMs: 0

  // Apple Silicon (Asahi) platform sensors. The specs array is the Instantiator
  // model and only ever changes at discovery; the parallel values array is
  // reassigned on every sample. Keeping them separate stops a value update
  // from tearing down and rebuilding every sensor's FileView.
  property var platformSensorSpecs: []
  property var platformSensorValues: []

  // Display rows: specs zipped with their latest values. Reassigned whenever
  // either source changes, so Panel Repeaters re-render cheaply.
  readonly property var platformSensors: {
    var rows = []
    for (var i = 0; i < platformSensorSpecs.length; i++) {
      rows.push({
        label: platformSensorSpecs[i].label,
        kind: platformSensorSpecs[i].kind,
        value: platformSensorValues[i] === undefined ? -1 : platformSensorValues[i]
      })
    }
    return rows
  }

  readonly property bool hasPlatformSensors: platformSensorSpecs.length > 0

  // Hottest platform temperature; drives the bar's warning tint and the
  // tooltip's peak reading on machines with no package sensor.
  readonly property real hottestPlatformTemp: {
    var hottest = -1
    for (var i = 0; i < platformSensors.length; i++) {
      if (platformSensors[i].kind !== "temp") continue
      if (platformSensors[i].value > hottest) hottest = platformSensors[i].value
    }
    return hottest
  }

  // The hottest platform temperature and the sensor that owns it, so the
  // temperature tile can name its source instead of pretending a package
  // sensor exists.
  readonly property var hottestPlatformSensor: {
    var best = null
    for (var i = 0; i < platformSensors.length; i++) {
      if (platformSensors[i].kind !== "temp") continue
      if (!best || platformSensors[i].value > best.value) best = platformSensors[i]
    }
    return best
  }

  // Heatpipe power (the SMC's PHPC reading): an estimate of the heat the
  // SoC is dissipating through its heatpipes. With no die temperature
  // exposed, this is the closest thing to a CPU thermal load Asahi offers —
  // and the same input the fan curves follow. -1 when unavailable.
  readonly property real heatpipeWatts: {
    var value = -1
    for (var i = 0; i < platformSensors.length; i++) {
      if (platformSensors[i].kind !== "power") continue
      if (String(platformSensors[i].label).indexOf("Heatpipe") < 0) continue
      if (platformSensors[i].value > value) value = platformSensors[i].value
    }
    return value
  }

  // ---- Fan control (Apple Silicon, via the asahi-fanctl helper) ----
  // The daemon's mode lives in a root-readable config file, so the active
  // preset and the bar's manual-mode tint stay live with zero polling. Fan
  // RPMs come straight from sysfs FileViews; the control-lock state from
  // the watched module parameter; and one `sudo -n asahi-fanctl status`
  // per panel open covers the daemon's own state.
  property string fanMode: ""
  property real fanCurveLoW: 4
  property real fanCurveHiW: 18
  property real fanCurveRpmMin: 1300
  property real fanCurveRpmMax: 5700
  property real fanCurveFloorRpm: 0
  property var fanStatus: null
  property string fanCtlError: ""
  property bool fanControlSeen: false
  property bool fanControlUnlocked: false

  // Fan specs from discovery (the Instantiator model) with parallel live
  // arrays for current speed and manual target.
  property var fanSpecs: []
  property var fanValues: []
  property var fanTargets: []

  readonly property bool fanCtlAvailable: fanMode !== ""
  readonly property bool fansManual: fanMode !== "" && fanMode !== "auto"

  // Display rows: specs zipped with their live readings.
  readonly property var fans: {
    var rows = []
    for (var i = 0; i < fanSpecs.length; i++) {
      rows.push({
        index: fanSpecs[i].index,
        label: fanSpecs[i].label,
        rpm: fanValues[i] === undefined ? -1 : fanValues[i],
        target: fanTargets[i] === undefined ? -1 : fanTargets[i],
        min: fanSpecs[i].min,
        max: fanSpecs[i].max
      })
    }
    return rows
  }

  function runFanctl(args) {
    fanctlProc.command = ["sudo", "-n", "/usr/local/bin/asahi-fanctl"].concat(args)
    fanctlProc.running = true
  }

  // ---- Thermal headline history ----
  // One point per sample tick of whichever value the HEAT tile carries:
  // package temperature, heatpipe watts, then warmest exposed temperature.
  property var thermalHistory: []
  property string lastThermalUnit: ""
  property double lastThermalRecordMs: 0

  readonly property real thermalHeadline: cpuTemperature >= 0 ? cpuTemperature : (heatpipeWatts >= 0 ? heatpipeWatts : hottestPlatformTemp)
  readonly property string thermalHeadlineUnit: cpuTemperature >= 0 ? "°C" : (heatpipeWatts >= 0 ? "W" : "°C")
  readonly property real thermalPeak: Model.peakValue(thermalHistory)

  function recordThermal() {
    var now = Date.now()
    if (now - lastThermalRecordMs < 900) return
    var value = thermalHeadline
    if (!isFinite(value) || value < 0) return
    if (thermalHeadlineUnit !== lastThermalUnit) {
      thermalHistory = []
      lastThermalUnit = thermalHeadlineUnit
    }
    lastThermalRecordMs = now
    thermalHistory = appendHistory(thermalHistory, now, value)
  }

  property var cpuHistory: []
  property var memoryHistory: []
  property var gpuHistory: []
  property var networkDownHistory: []
  property var networkUpHistory: []

  // Both halves of a mirrored chart share one scale, so the peak is taken
  // across the pair. The panel prints the same number it draws against.
  readonly property real networkPeak: Math.max(Model.peakValue(networkDownHistory), Model.peakValue(networkUpHistory))
  readonly property real coreMaximum: Model.maximumPercent(perCore)

  property var cpuSnapshot: ({})
  property var networkSnapshot: null
  property var diskSnapshot: null

  function appendHistory(current, timestamp, value) {
    if (!isFinite(value) || value < 0) return current
    var cutoff = timestamp - historyWindowMs
    var next = []
    for (var i = 0; i < current.length; i++) {
      if (current[i].time >= cutoff) next.push(current[i])
    }
    next.push({ time: timestamp, value: value })
    if (next.length > 130) next = next.slice(next.length - 130)
    return next
  }

  function updateSensorValue(index, raw) {
    var spec = platformSensorSpecs[index]
    var value = spec ? Model.parseSensorValue(raw, spec.kind) : -1
    if (platformSensorValues[index] === value) return
    var next = platformSensorValues.slice()
    next[index] = value
    platformSensorValues = next
  }

  function updateFanValue(pos, which, raw) {
    var spec = fanSpecs[pos]
    if (!spec) return
    var text = String(raw === undefined || raw === null ? "" : raw).trim()
    var value = /^[0-9]+$/.test(text) ? Number(text) : -1
    if (which === "rpm") {
      if (fanValues[pos] === value) return
      var nextValues = fanValues.slice()
      nextValues[pos] = value
      fanValues = nextValues
    } else {
      if (fanTargets[pos] === value) return
      var nextTargets = fanTargets.slice()
      nextTargets[pos] = value
      fanTargets = nextTargets
    }
  }

  function parseFanConfig(raw) {
    var lines = String(raw || "").split("\n")
    var values = ({})
    for (var i = 0; i < lines.length; i++) {
      var separator = lines[i].indexOf("=")
      if (separator < 0) continue
      values[lines[i].slice(0, separator).trim()] = lines[i].slice(separator + 1).trim()
    }
    fanMode = values.MODE !== undefined ? values.MODE : "auto"
    var number = Number(values.CURVE_LO_W)
    if (isFinite(number) && number > 0) fanCurveLoW = number
    number = Number(values.CURVE_HI_W)
    if (isFinite(number) && number > 0) fanCurveHiW = number
    number = Number(values.CURVE_RPM_MIN)
    if (isFinite(number) && number >= 0) fanCurveRpmMin = number
    number = Number(values.CURVE_RPM_MAX)
    if (isFinite(number) && number >= 0) fanCurveRpmMax = number
    number = Number(values.CURVE_FLOOR_RPM)
    if (isFinite(number) && number >= 0) fanCurveFloorRpm = number
  }

  function enableFanControl() {
    fanctlProc.rediscovers = true
    runFanctl(["enable"])
  }

  function sample() {
    statFile.reload()
    memoryFile.reload()
    loadFile.reload()
    uptimeFile.reload()
    routeFile.reload()
    networkFile.reload()
    diskFile.reload()
    if (cpuTempPath !== "") temperatureFile.reload()
    if (gpuBusyPath !== "") gpuBusyFile.reload()
    if (gpuTempPath !== "") gpuTemperatureFile.reload()
    // VRAM only moves when the panel is open and a human is looking; polling
    // it on the closed cadence buys nothing and costs two sysfs reads.
    if (panelOpen && gpuVramUsedPath !== "") gpuVramUsedFile.reload()
    for (var i = 0; i < sensorFileViews.count; i++) {
      var sensorFile = sensorFileViews.objectAt(i)
      if (sensorFile) sensorFile.sample()
    }
    // Fan speeds are cheap sysfs reads and the history chart wants them
    // even while nobody is looking, so they follow the shared cadence.
    for (var j = 0; j < fanFileViews.count; j++) {
      var fanFile = fanFileViews.objectAt(j)
      if (fanFile) fanFile.sample()
    }
    recordThermal()

    var now = Date.now()
    if (panelOpen && !filesystemProc.running && now - lastFilesystemRefreshMs >= 60000) {
      lastFilesystemRefreshMs = now
      filesystemProc.running = true
    }
  }

  function handleCpu(raw) {
    var parsed = Model.parseCpu(raw, cpuSnapshot)
    cpuSnapshot = parsed.snapshot
    perCore = parsed.cores
    if (parsed.overall < 0) return
    cpuPercent = parsed.overall
    var now = Date.now()
    lastSampleMs = now
    cpuHistory = appendHistory(cpuHistory, now, cpuPercent)
  }

  function handleMemory(raw) {
    var parsed = Model.parseMemory(raw)
    memoryPercent = parsed.percent
    memoryUsed = parsed.used
    memoryTotal = parsed.total
    swapPercent = parsed.swapPercent
    swapUsed = parsed.swapUsed
    swapTotal = parsed.swapTotal
    memoryHistory = appendHistory(memoryHistory, Date.now(), memoryPercent)
  }

  function handleLoad(raw) {
    var parsed = Model.parseLoad(raw)
    loadOne = parsed.one
    loadFive = parsed.five
    loadFifteen = parsed.fifteen
  }

  function handleNetwork(raw) {
    var current = Model.parseNetwork(raw, activeInterface)
    var now = Date.now()
    if (!current) {
      networkSnapshot = null
      networkDownBps = -1
      networkUpBps = -1
      return
    }

    if (networkSnapshot && networkSnapshot.interfaceName === activeInterface) {
      var elapsed = (now - networkSnapshot.time) / 1000
      var rxDelta = current.rx - networkSnapshot.rx
      var txDelta = current.tx - networkSnapshot.tx
      if (elapsed > 0 && elapsed < 30 && rxDelta >= 0 && txDelta >= 0) {
        networkDownBps = rxDelta / elapsed
        networkUpBps = txDelta / elapsed
        networkDownHistory = appendHistory(networkDownHistory, now, networkDownBps)
        networkUpHistory = appendHistory(networkUpHistory, now, networkUpBps)
      }
    }
    networkSnapshot = { interfaceName: activeInterface, rx: current.rx, tx: current.tx, time: now }
  }

  function handleDisk(raw) {
    var current = Model.parseDisk(raw, diskDevices)
    var now = Date.now()
    if (!current) {
      diskSnapshot = null
      diskReadBps = -1
      diskWriteBps = -1
      return
    }

    if (diskSnapshot) {
      var elapsed = (now - diskSnapshot.time) / 1000
      var readDelta = current.readBytes - diskSnapshot.readBytes
      var writeDelta = current.writeBytes - diskSnapshot.writeBytes
      if (elapsed > 0 && elapsed < 30 && readDelta >= 0 && writeDelta >= 0) {
        diskReadBps = readDelta / elapsed
        diskWriteBps = writeDelta / elapsed
      }
    }
    diskSnapshot = { readBytes: current.readBytes, writeBytes: current.writeBytes, time: now }
  }

  onActiveInterfaceChanged: {
    networkSnapshot = null
    networkDownBps = -1
    networkUpBps = -1
    networkDownHistory = []
    networkUpHistory = []
  }

  onPanelOpenChanged: {
    sampleTimer.restart()
    sample()
    // One helper poll per open covers the daemon's own state (active, mode
    // sanity); everything else lives in watched files and sysfs views.
    if (panelOpen && fanCtlAvailable && !fanStatusProc.running) fanStatusProc.running = true
  }

  Timer {
    id: sampleTimer
    interval: root.panelOpen ? root.openRefreshMs : root.closedRefreshMs
    repeat: true
    running: true
    onTriggered: root.sample()
  }

  // One FileView per discovered platform sensor, created on demand. Item
  // delegates with zero size keep them out of the visual tree; the Instantiator
  // pattern mirrors the shell's own agents plugin.
  Instantiator {
    id: sensorFileViews
    model: root.platformSensorSpecs

    delegate: Item {
      id: sensorDelegate
      required property var modelData

      function sample() { sensorFile.reload() }

      FileView {
        id: sensorFile
        path: sensorDelegate.modelData.path
        watchChanges: false
        printErrors: false
        onLoaded: root.updateSensorValue(sensorDelegate.modelData.index, text())
        onLoadFailed: root.updateSensorValue(sensorDelegate.modelData.index, "")
      }
    }
  }

  // One pair of FileViews per discovered fan: current speed (polled on the
  // shared cadence) and the manual target.
  Instantiator {
    id: fanFileViews
    model: root.fanSpecs

    delegate: Item {
      id: fanDelegate
      required property var modelData

      function sample() {
        fanInputFile.reload()
        fanTargetFile.reload()
      }

      FileView {
        id: fanInputFile
        path: fanDelegate.modelData.path
        watchChanges: false
        printErrors: false
        onLoaded: root.updateFanValue(fanDelegate.modelData.pos, "rpm", text())
        onLoadFailed: root.updateFanValue(fanDelegate.modelData.pos, "rpm", "")
      }

      FileView {
        id: fanTargetFile
        path: fanDelegate.modelData.targetPath
        watchChanges: false
        printErrors: false
        onLoaded: root.updateFanValue(fanDelegate.modelData.pos, "target", text())
        onLoadFailed: root.updateFanValue(fanDelegate.modelData.pos, "target", "")
      }
    }
  }

  FileView {
    id: statFile
    path: "/proc/stat"
    watchChanges: false
    printErrors: false
    onLoaded: root.handleCpu(text())
  }

  FileView {
    id: memoryFile
    path: "/proc/meminfo"
    watchChanges: false
    printErrors: false
    onLoaded: root.handleMemory(text())
  }

  FileView {
    id: loadFile
    path: "/proc/loadavg"
    watchChanges: false
    printErrors: false
    onLoaded: root.handleLoad(text())
  }

  FileView {
    id: uptimeFile
    path: "/proc/uptime"
    watchChanges: false
    printErrors: false
    onLoaded: root.uptimeSeconds = Model.parseUptime(text())
  }

  FileView {
    id: routeFile
    path: "/proc/net/route"
    watchChanges: false
    printErrors: false
    onLoaded: if (root.configuredInterface === "") root.autoInterface = Model.parseDefaultInterface(text())
  }

  FileView {
    id: networkFile
    path: "/proc/net/dev"
    watchChanges: false
    printErrors: false
    onLoaded: root.handleNetwork(text())
  }

  FileView {
    id: diskFile
    path: "/proc/diskstats"
    watchChanges: false
    printErrors: false
    onLoaded: root.handleDisk(text())
  }

  FileView {
    id: temperatureFile
    path: root.cpuTempPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      var value = Number(String(text()).trim()) / 1000
      root.cpuTemperature = isFinite(value) && value > 0 ? value : -1
    }
    onLoadFailed: root.cpuTemperature = -1
  }

  FileView {
    id: gpuBusyFile
    path: root.gpuBusyPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      root.gpuPercent = Model.parseGpuPercent(text())
      if (root.gpuPercent >= 0) root.gpuHistory = root.appendHistory(root.gpuHistory, Date.now(), root.gpuPercent)
    }
    onLoadFailed: root.gpuPercent = -1
  }

  FileView {
    id: gpuTemperatureFile
    path: root.gpuTempPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      var value = Number(String(text()).trim()) / 1000
      root.gpuTemperature = isFinite(value) && value > 0 ? value : -1
    }
    onLoadFailed: root.gpuTemperature = -1
  }

  FileView {
    id: gpuVramUsedFile
    path: root.gpuVramUsedPath
    watchChanges: false
    printErrors: false
    onLoaded: root.gpuVramUsed = Model.parseByteCount(text())
    onLoadFailed: root.gpuVramUsed = -1
  }

  FileView {
    id: gpuVramTotalFile
    path: root.gpuVramTotalPath
    watchChanges: false
    printErrors: false
    onLoaded: root.gpuVramTotal = Model.parseByteCount(text())
    onLoadFailed: root.gpuVramTotal = -1
  }

  FileView {
    path: "/etc/hostname"
    watchChanges: true
    printErrors: false
    onLoaded: root.hostname = String(text()).trim()
    onFileChanged: reload()
  }

  // The daemon rewrites its config on every mode change, so watching this
  // file keeps the active preset (and the bar's manual-mode tint) live with
  // zero polling. Absent file = helper not installed = no fan section.
  FileView {
    id: fanModeFile
    path: "/etc/asahi-fand.conf"
    watchChanges: true
    printErrors: false
    onLoaded: root.parseFanConfig(text())
    onLoadFailed: root.fanMode = ""
    onFileChanged: reload()
  }

  // The kernel parameter gates manual control. Watching it keeps the Enable
  // button honest the moment control unlocks — including when the daemon
  // does it on its own, which rebinds the driver and moves sysfs paths, so
  // a false→true transition triggers a rediscovery.
  FileView {
    id: fanControlParamFile
    path: "/sys/module/macsmc_hwmon/parameters/fan_control"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var value = String(text()).trim()
      root.fanControlUnlocked = value === "Y" || value === "y" || value === "1"
      if (root.fanControlUnlocked && !root.fanControlSeen && !discoveryProc.running) {
        discoveryProc.running = true
      }
      root.fanControlSeen = root.fanControlUnlocked
    }
    onLoadFailed: root.fanControlUnlocked = false
    onFileChanged: reload()
  }

  // Authoritative one-shot daemon state, polled once per panel open and
  // after every action; RPMs and targets come from sysfs, not from here.
  Process {
    id: fanStatusProc
    command: ["sudo", "-n", "/usr/local/bin/asahi-fanctl", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(String(text)) } catch (error) { parsed = null }
        root.fanStatus = parsed && parsed.daemon !== undefined ? parsed : null
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") root.fanCtlError = String(text).trim()
    }
  }

  // One-shot runner for mode/curve/enable commands; the exit handler
  // refreshes the param view and daemon state, and `enable` additionally
  // rediscovers sensors (the driver rebind moves hwmon paths).
  Process {
    id: fanctlProc
    property bool rediscovers: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fanCtlError = String(text).trim()
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) root.fanCtlError = ""
      fanControlParamFile.reload()
      if (rediscovers && !discoveryProc.running) discoveryProc.running = true
      rediscovers = false
      if (!fanStatusProc.running) fanStatusProc.running = true
    }
  }

  Process {
    id: discoveryProc
    command: ["bash", root.pluginPath + "/discover-sensors.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var discovered = Model.parseDiscovery(text)
        root.cpuTempPath = discovered.cpuTempPath
        root.gpuBusyPath = discovered.gpuBusyPath
        root.gpuTempPath = discovered.gpuTempPath
        root.gpuVramUsedPath = discovered.gpuVramUsedPath
        root.gpuVramTotalPath = discovered.gpuVramTotalPath
        root.diskDevices = discovered.devices
        root.diskSnapshot = null
        if (root.cpuTempPath !== "") temperatureFile.reload()
        if (root.gpuBusyPath !== "") gpuBusyFile.reload()
        if (root.gpuTempPath !== "") gpuTemperatureFile.reload()
        // Total VRAM is fixed for the life of the card, so read it once here
        // rather than on every sample.
        if (root.gpuVramTotalPath !== "") gpuVramTotalFile.reload()
        if (root.gpuVramUsedPath !== "") gpuVramUsedFile.reload()
        diskFile.reload()

        // Same sensors, same objects: skip the reassignment when the set has
        // not changed, so live FileViews are not torn down for nothing.
        var specs = []
        for (var i = 0; i < discovered.platformSensors.length; i++) {
          specs.push({
            index: i,
            path: discovered.platformSensors[i].path,
            kind: discovered.platformSensors[i].kind,
            label: discovered.platformSensors[i].label
          })
        }
        if (JSON.stringify(specs) !== JSON.stringify(root.platformSensorSpecs)) {
          root.platformSensorSpecs = specs
          var values = []
          for (var j = 0; j < specs.length; j++) values.push(-1)
          root.platformSensorValues = values
        }
        for (var k = 0; k < sensorFileViews.count; k++) {
          var sensorFile = sensorFileViews.objectAt(k)
          if (sensorFile) sensorFile.sample()
        }

        // Fans: same pattern — rebuild only when the set changed (a driver
        // rebind moves paths).
        var nextFanSpecs = []
        for (var f = 0; f < discovered.fans.length; f++) {
          nextFanSpecs.push({
            pos: f,
            index: discovered.fans[f].index,
            path: discovered.fans[f].path,
            targetPath: discovered.fans[f].targetPath,
            label: discovered.fans[f].label,
            min: discovered.fans[f].min,
            max: discovered.fans[f].max
          })
        }
        if (JSON.stringify(nextFanSpecs) !== JSON.stringify(root.fanSpecs)) {
          root.fanSpecs = nextFanSpecs
          var nextFanValues = []
          var nextFanTargets = []
          for (var g = 0; g < nextFanSpecs.length; g++) {
            nextFanValues.push(-1)
            nextFanTargets.push(-1)
          }
          root.fanValues = nextFanValues
          root.fanTargets = nextFanTargets
        }
        for (var h = 0; h < fanFileViews.count; h++) {
          var fanFile = fanFileViews.objectAt(h)
          if (fanFile) fanFile.sample()
        }
        // An SMC hwmon machine may have the fan control helper installed:
        // prime the daemon state (mode comes from the watched config file).
        if ((specs.length > 0 || nextFanSpecs.length > 0) && !fanStatusProc.running) {
          fanStatusProc.running = true
        }
      }
    }
  }

  Process {
    id: filesystemProc
    // Local, on-disk filesystems only, with a type column; the parser drops
    // pseudo mounts and collapses subvolumes. `-l` keeps a stale network
    // mount from hanging df.
    command: ["df", "-P", "-k", "-l", "-T"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var all = Model.parseFilesystems(text)
        var extras = []
        for (var i = 0; i < all.length; i++) {
          if (all[i].mount === "/") {
            root.filesystemPercent = all[i].percent
            root.filesystemUsed = all[i].used
            root.filesystemTotal = all[i].total
          } else {
            extras.push(all[i])
          }
        }
        root.extraFilesystems = extras
      }
    }
  }

  Component.onCompleted: {
    discoveryProc.running = true
    sample()
  }
}
