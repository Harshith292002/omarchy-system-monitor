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
  property real networkDownBps: -1
  property real networkUpBps: -1
  property real diskReadBps: -1
  property real diskWriteBps: -1
  property real filesystemPercent: -1
  property double filesystemUsed: 0
  property double filesystemTotal: 0
  property string hostname: ""
  property string autoInterface: ""
  property string cpuTempPath: ""
  property var diskDevices: []
  property double lastSampleMs: 0
  property double lastFilesystemRefreshMs: 0

  property var cpuHistory: []
  property var memoryHistory: []
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

  function sample() {
    statFile.reload()
    memoryFile.reload()
    loadFile.reload()
    uptimeFile.reload()
    routeFile.reload()
    networkFile.reload()
    diskFile.reload()
    if (cpuTempPath !== "") temperatureFile.reload()

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
  }

  Timer {
    id: sampleTimer
    interval: root.panelOpen ? root.openRefreshMs : root.closedRefreshMs
    repeat: true
    running: true
    onTriggered: root.sample()
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
    path: "/etc/hostname"
    watchChanges: true
    printErrors: false
    onLoaded: root.hostname = String(text()).trim()
    onFileChanged: reload()
  }

  Process {
    id: discoveryProc
    command: ["bash", root.pluginPath + "/discover-sensors.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var discovered = Model.parseDiscovery(text)
        root.cpuTempPath = discovered.cpuTempPath
        root.diskDevices = discovered.devices
        root.diskSnapshot = null
        if (root.cpuTempPath !== "") temperatureFile.reload()
        diskFile.reload()
      }
    }
  }

  Process {
    id: filesystemProc
    command: ["df", "-Pk", "/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseFilesystem(text)
        if (!parsed) return
        root.filesystemPercent = parsed.percent
        root.filesystemUsed = parsed.used
        root.filesystemTotal = parsed.total
      }
    }
  }

  Component.onCompleted: {
    discoveryProc.running = true
    sample()
  }
}
