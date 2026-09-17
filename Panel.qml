import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Metrics.js" as Model

Panel {
  id: root

  moduleName: "harshith.system-monitor"
  ipcTarget: "harshith.system-monitor"
  manageIpc: false

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color muted: Qt.darker(foreground, 1.4)
  readonly property color trackColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property color chartGrid: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.18)
  // Second data hue. Stays inside the accent family so charted values never
  // read as body text, but dark enough to separate from the primary line.
  readonly property color secondary: Qt.darker(accent, 1.5)
  // No warning role exists in the palette — themes ship foreground, accent,
  // urgent and muted — so blend one rather than hardcoding an orange that
  // would clash on half the themes.
  readonly property color warningColor: Qt.tint(accent, Qt.rgba(urgent.r, urgent.g, urgent.b, 0.6))
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string barMode: String(setting("barMode", "Adaptive"))
  // Icon mode keeps the bar quiet: the plugin glyph alone, still tinted at
  // warning/critical pressure, tooltip and dashboard unchanged.
  readonly property bool iconOnly: barMode === "Icon"
  readonly property real warningThreshold: Math.min(Number(setting("warningPercent", 80)), criticalThreshold - 1)
  readonly property real criticalThreshold: Math.max(Number(setting("criticalPercent", 95)), 61)
  readonly property real pressure: Math.max(metrics.cpuPercent, metrics.memoryPercent)
  // On machines with no package sensor (Apple Silicon), the thermal load
  // shows in heatpipe watts: the tint tracks dissipated heat, the hottest
  // platform temperature, and a non-auto fan mode (the SMC's automatic
  // curve is overridden then, so software is the safety net).
  readonly property bool warning: pressure >= warningThreshold || metrics.cpuTemperature >= 85 || metrics.gpuTemperature >= 85 || metrics.hottestPlatformTemp >= 85 || (metrics.cpuTemperature < 0 && metrics.heatpipeWatts >= heatWarnW) || metrics.fansManual
  readonly property bool critical: pressure >= criticalThreshold || metrics.cpuTemperature >= 95 || metrics.gpuTemperature >= 95 || metrics.hottestPlatformTemp >= 95 || (metrics.cpuTemperature < 0 && metrics.heatpipeWatts >= heatCriticalW)

  readonly property string heroGlyph: "󰻠"

  // Package temperature only spans a useful band; drawing 57°C as 57% of a
  // meter makes a cold chip look half-loaded. Anchor the scale at 30°C.
  readonly property real temperatureFloor: 30
  readonly property real temperatureCeiling: 100

  // Keyboard/mouse cursor over the action row — the panel's only actionable
  // controls. Visuals derive from `hasCursor`, never from containsMouse, so
  // one highlight shows at a time no matter which input moved it.
  property bool cursorActive: false
  property int selectedIndex: 0
  readonly property int actionCount: 2

  function percent(value) {
    return isFinite(value) && value >= 0 ? Math.round(value) + "%" : "—"
  }

  // Fixed-width percentage for the bar label. Without the pad the widget
  // resizes as values cross 10 and 100, shoving every widget beside it.
  function padPercent(value) {
    if (!isFinite(value) || value < 0) return "  —"
    var text = Math.round(value) + "%"
    while (text.length < 4) text = " " + text
    return text
  }

  // Fixed-width thermal bar value: watts on Asahi (heatpipe), °C elsewhere.
  function padThermalBarValue() {
    if (thermalTileIsWatts()) {
      var text = metrics.heatpipeWatts.toFixed(1) + "W"
      while (text.length < 5) text = " " + text
      return text
    }
    var t = metrics.cpuTemperature >= 0 ? metrics.cpuTemperature : metrics.hottestPlatformTemp
    if (!isFinite(t) || t < 0) return "  —"
    var deg = Math.round(t) + "°"
    while (deg.length < 4) deg = " " + deg
    return deg
  }

  function thermalBarName() {
    return thermalTileIsWatts() ? "HEAT" : "TEMP"
  }

  function formatBytes(value) {
    var amount = Number(value)
    if (!isFinite(amount) || amount < 0) return "—"
    var units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var index = 0
    while (amount >= 1024 && index < units.length - 1) {
      amount /= 1024
      index++
    }
    var digits = index >= 3 ? 1 : (amount >= 100 ? 0 : 1)
    return amount.toFixed(digits) + " " + units[index]
  }

  // "3.6 / 7.3 GiB" — one unit for the pair, so used/total lines up and the
  // string stays short enough for a third-of-a-panel card.
  function formatPair(used, total) {
    var totalBytes = Number(total)
    if (!isFinite(totalBytes) || totalBytes <= 0) return "—"
    var units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var index = 0
    var scale = 1
    while (totalBytes / scale >= 1024 && index < units.length - 1) {
      scale *= 1024
      index++
    }
    var digits = index >= 3 ? 1 : 0
    return (Number(used) / scale).toFixed(digits) + " / " + (totalBytes / scale).toFixed(digits) + " " + units[index]
  }

  function formatRate(value) {
    return isFinite(value) && value >= 0 ? formatBytes(value) + "/s" : "—"
  }

  function formatUptime(seconds) {
    var totalMinutes = Math.floor(Number(seconds) / 60)
    if (!isFinite(totalMinutes) || totalMinutes < 0) return "—"
    var days = Math.floor(totalMinutes / 1440)
    var hours = Math.floor((totalMinutes % 1440) / 60)
    var minutes = totalMinutes % 60
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + minutes + "m"
    return minutes + "m"
  }

  function loadText() {
    function one(value) { return value >= 0 ? value.toFixed(2) : "—" }
    return one(metrics.loadOne) + " / " + one(metrics.loadFive) + " / " + one(metrics.loadFifteen)
  }

  // ---- Thermal headline ----
  // With a package sensor (x86/AMD) the tile is that temperature. On Apple
  // Silicon there is no die temperature at all, and the warmest exposed
  // sensor is a peripheral that can read mild while the SoC runs hot out of
  // sight — so the headline there is heatpipe power: the watts the SoC is
  // actually dissipating, the number that tracks the warmth you feel and
  // the same input the fan curves follow.
  readonly property real heatWarnW: 15
  readonly property real heatCriticalW: 25
  readonly property real heatCeilingW: 30

  function thermalTileIsWatts() {
    return metrics.cpuTemperature < 0 && metrics.heatpipeWatts >= 0
  }

  function thermalTileTitle() {
    return thermalTileIsWatts() ? "HEAT" : "TEMP"
  }

  function thermalTileValue() {
    if (thermalTileIsWatts()) return metrics.heatpipeWatts.toFixed(1) + " W"
    if (metrics.cpuTemperature >= 0) return Math.round(metrics.cpuTemperature) + "°C"
    if (metrics.hottestPlatformTemp >= 0) return Math.round(metrics.hottestPlatformTemp) + "°C"
    return "—"
  }

  function thermalTileDetail() {
    // Keep this short: the three-up tile row clips longer copy.
    // Heatpipe watts are the real signal; no cool/warm/hot feel labels —
    // those would pretend a chassis-dependent guess is calibrated.
    if (thermalTileIsWatts()) return "heatpipe"
    if (metrics.cpuTemperature >= 0) {
      if (metrics.cpuTemperature >= 85) return "Warm"
      return "Normal"
    }
    // No heatpipe sensor either: the warmest exposed temperature, labelled
    // as what it is — a peripheral, not the machine's peak.
    var source = temperatureSourceLabel()
    if (source !== "") return "warmest: " + source
    return metrics.hasPlatformSensors ? "No SoC sensor" : "Unavailable"
  }

  function thermalTileMeter() {
    if (thermalTileIsWatts()) {
      return Math.max(0, Math.min(100, metrics.heatpipeWatts * 100 / heatCeilingW))
    }
    return temperatureBandMeter(metrics.cpuTemperature >= 0 ? metrics.cpuTemperature : metrics.hottestPlatformTemp)
  }

  function thermalTileMeterColor() {
    if (thermalTileIsWatts()) return levelColor(metrics.heatpipeWatts, heatWarnW, heatCriticalW)
    return levelColor(metrics.cpuTemperature >= 0 ? metrics.cpuTemperature : metrics.hottestPlatformTemp, 85, 95)
  }

  function thermalTileAlarming() {
    if (thermalTileIsWatts()) return metrics.heatpipeWatts >= heatCriticalW
    return (metrics.cpuTemperature >= 0 ? metrics.cpuTemperature : metrics.hottestPlatformTemp) >= 95
  }

  // Tooltip headline: the package sensor when there is one, then heatpipe
  // watts, then the warmest exposed temperature.
  function headlineTempText() {
    if (metrics.cpuTemperature >= 0) return Math.round(metrics.cpuTemperature) + "°C"
    if (metrics.heatpipeWatts >= 0) return "heat " + metrics.heatpipeWatts.toFixed(1) + " W"
    if (metrics.hottestPlatformTemp >= 0) return "warmest " + Math.round(metrics.hottestPlatformTemp) + "°C"
    return "—"
  }

  function temperatureSourceLabel() {
    var sensor = metrics.hottestPlatformSensor
    if (!sensor || !isFinite(sensor.value) || sensor.value < 0) return ""
    return String(sensor.label)
      .replace(/ Temperature$/, "")
      .replace(/ Temp$/, "")
  }

  // Package temperature only spans a useful band; drawing 57°C as 57% of a
  // meter makes a cold chip look half-loaded. Anchor the scale at 30°C.
  function temperatureBandMeter(value) {
    if (!isFinite(value) || value < 0) return -1
    var span = temperatureCeiling - temperatureFloor
    return Math.max(0, Math.min(100, (value - temperatureFloor) * 100 / span))
  }

  // Vendors expose different subsets: amdgpu publishes utilisation, memory and
  // temperature; i915/xe and nouveau publish temperature alone. Each tile is
  // gated on its own sensor so a temperature-only card still gets a section
  // instead of a row of em dashes.
  readonly property bool hasGpuUsage: metrics.gpuPercent >= 0
  readonly property bool hasGpuTemperature: metrics.gpuTemperature >= 0
  readonly property bool hasGpuVram: metrics.gpuVramTotal > 0 && metrics.gpuVramUsed >= 0
  readonly property bool hasGpu: hasGpuUsage || hasGpuTemperature
  readonly property int gpuTileCount: (hasGpuUsage ? 1 : 0) + (hasGpuTemperature ? 1 : 0) + (hasGpuVram ? 1 : 0)

  function gpuTemperatureText() {
    return metrics.gpuTemperature >= 0 ? Math.round(metrics.gpuTemperature) + "°C" : "—"
  }

  function gpuTemperatureDetail() {
    if (metrics.gpuTemperature < 0) return "Unavailable"
    if (metrics.gpuTemperature >= 85) return "Warm"
    return "Normal"
  }

  // Same anchored scale as the CPU package sensor: a cold die drawn as a
  // fraction of 100°C reads as half-loaded.
  function gpuTemperatureMeter() {
    return temperatureBandMeter(metrics.gpuTemperature)
  }

  // Platform sensor rows: hwmon temperatures in °C, power rails in W. The
  // value is muted rather than dash-only when a sensor reports nothing.
  function sensorValueText(sensor) {
    if (!sensor || !isFinite(sensor.value) || sensor.value < 0) return "—"
    if (sensor.kind === "power") return sensor.value.toFixed(1) + " W"
    return Math.round(sensor.value) + "°C"
  }

  function sensorSummaryText() {
    if (metrics.hottestPlatformTemp >= 0) return "peak " + Math.round(metrics.hottestPlatformTemp) + "°C"
    return ""
  }

  // Default SENSORS list stays short: heatpipe (drives HEAT + fans), the
  // battery/charge thermal pair, and total system power. NAND / Wi-Fi /
  // rail watts hide behind "show all" so the panel stays scannable.
  property bool showAllPlatformSensors: false

  function isPrimaryPlatformSensor(sensor) {
    if (!sensor) return false
    var label = String(sensor.label || "").toLowerCase()
    if (label.indexOf("heatpipe") >= 0) return true
    if (label.indexOf("battery") >= 0) return true
    if (label.indexOf("charge") >= 0) return true
    if (label.indexOf("total system") >= 0) return true
    return false
  }

  function visiblePlatformSensors() {
    var all = metrics.platformSensors
    if (root.showAllPlatformSensors) return all
    var rows = []
    for (var i = 0; i < all.length; i++) {
      if (root.isPrimaryPlatformSensor(all[i])) rows.push(all[i])
    }
    // If nothing matched labels (unexpected SMC naming), fall back to all
    // rather than an empty section.
    return rows.length > 0 ? rows : all
  }

  function hiddenPlatformSensorCount() {
    if (root.showAllPlatformSensors) return 0
    var all = metrics.platformSensors
    var visible = root.visiblePlatformSensors()
    if (visible.length === all.length) return 0
    return Math.max(0, all.length - visible.length)
  }

  // ---- Fans ----

  function fanRpmText(fan) {
    if (!fan || !isFinite(fan.rpm) || fan.rpm < 0) return "—"
    var text = Math.round(fan.rpm) + " RPM"
    // The target only means something while the fan is in manual mode;
    // under SMC control it is Apple's own request, not ours.
    if (metrics.fansManual && isFinite(fan.target) && fan.target > 0) {
      text += " · tgt " + Math.round(fan.target)
    }
    return text
  }

  function fansSummaryText() {
    if (!metrics.fanCtlAvailable) return "monitor only"
    if (!metrics.fanControlUnlocked) return "locked · SMC auto"
    if (metrics.fanStatus && metrics.fanStatus.daemon && metrics.fanStatus.daemon.active !== true) return "daemon down"
    if (metrics.fanMode === "" || metrics.fanMode === "auto") return "SMC auto"
    return "manual · " + metrics.fanMode
  }

  function applyFanCurve() {
    metrics.runFanctl([
      "curve",
      String(loWField.field.value),
      String(hiWField.field.value),
      String(rpmMinField.field.value),
      String(rpmMaxField.field.value),
      String(floorField.field.value)
    ])
  }

  // Row skips invisible children, so the divisor is the number of tiles that
  // this card can actually fill.
  function gpuTileWidth(rowWidth, spacing) {
    var count = Math.max(1, gpuTileCount)
    return (rowWidth - spacing * (count - 1)) / count
  }

  function gpuVramPercent() {
    if (metrics.gpuVramTotal <= 0 || metrics.gpuVramUsed < 0) return -1
    return Math.max(0, Math.min(100, metrics.gpuVramUsed * 100 / metrics.gpuVramTotal))
  }

  function gpuVramDetail() {
    if (metrics.gpuVramTotal <= 0 || metrics.gpuVramUsed < 0) return "—"
    return formatPair(metrics.gpuVramUsed, metrics.gpuVramTotal)
  }

  // nvme0n1 → nvme0, mmcblk0 → mmc0; sda and friends are already short.
  function shortDiskName(name) {
    var text = String(name || "")
    var nvme = text.match(/^nvme(\d+)n\d+$/)
    if (nvme) return "nvme" + nvme[1]
    var mmc = text.match(/^mmcblk(\d+)$/)
    if (mmc) return "mmc" + mmc[1]
    return text
  }

  // The row reports combined throughput, so past the first device the names
  // are noise — collapse them into a count.
  function diskLabelText() {
    var devices = metrics.diskDevices
    if (!devices || devices.length === 0) return "DISK"
    if (devices.length === 1) return "DISK · " + shortDiskName(devices[0])
    return "DISK · " + shortDiskName(devices[0]) + " +" + (devices.length - 1)
  }

  function mountBasename(mount) {
    var segments = String(mount).split("/")
    return segments[segments.length - 1] || String(mount)
  }

  // Auto-discovered mount paths. These render into CapacityRow's label, which
  // pins Text.PlainText, so the raw path is passed through the same way the
  // section heading takes its title; escapeMarkup stays reserved for the
  // shared bar tooltip, whose formatting this plugin does not control.
  // Normally the last path segment (/mnt/data -> "data"); when two disks share
  // a basename the colliding ones show the full path.
  function mountLabel(mount) {
    var target = String(mount)
    var base = mountBasename(target)
    var mounts = metrics.extraFilesystems
    for (var i = 0; i < mounts.length; i++) {
      var other = String(mounts[i].mount)
      if (other !== target && mountBasename(other) === base) return target
    }
    return base
  }

  function levelColor(value, warn, crit) {
    if (!isFinite(value) || value < 0) return root.muted
    if (value >= crit) return root.urgent
    if (value >= warn) return root.warningColor
    return root.accent
  }

  function modeLabel() {
    return barMode === "Memory" ? "RAM" : barMode
  }

  // Every horizontal form is a fixed character count, so the widget keeps its
  // width as values cross 10 and 100 instead of shoving its neighbours.
  function barLabel() {
    // A vertical bar has room for the number and nothing else.
    if (button.vertical) {
      if (barMode === "Temp") {
        if (thermalTileIsWatts()) return metrics.heatpipeWatts.toFixed(0)
        var tv = metrics.cpuTemperature >= 0 ? metrics.cpuTemperature : metrics.hottestPlatformTemp
        return isFinite(tv) && tv >= 0 ? String(Math.round(tv)) : "—"
      }
      var value = barMode === "CPU" ? metrics.cpuPercent
        : barMode === "Memory" ? metrics.memoryPercent
        : barMode === "GPU" ? metrics.gpuPercent
        : Math.max(metrics.cpuPercent, metrics.memoryPercent)
      return isFinite(value) && value >= 0 ? String(Math.round(value)) : "—"
    }
    if (barMode === "CPU") return "CPU " + padPercent(metrics.cpuPercent)
    if (barMode === "Memory") return "RAM " + padPercent(metrics.memoryPercent)
    if (barMode === "GPU") return "GPU " + padPercent(metrics.gpuPercent)
    if (barMode === "Temp") return thermalBarName() + " " + padThermalBarValue()
    if (barMode === "Both")
      return "C " + padPercent(metrics.cpuPercent) + " M " + padPercent(metrics.memoryPercent)
    // Adaptive: CPU vs RAM pressure only — never heat/temp (explicit Temp mode).
    return metrics.cpuPercent >= metrics.memoryPercent
      ? "CPU " + padPercent(metrics.cpuPercent)
      : "RAM " + padPercent(metrics.memoryPercent)
  }

  function tooltipText() {
    // WidgetButton's shared tooltip only accepts a string and renders it with
    // Text.AutoText, so neutralize markup before handing it configuration.
    var interfaceName = Model.escapeMarkup(metrics.activeInterface)
    var lines = [
      "CPU " + percent(metrics.cpuPercent) + " · RAM " + percent(metrics.memoryPercent) + " · " + headlineTempText()
    ]
    // Skipped entirely on machines without a utilisation-reporting GPU, so
    // the tooltip never grows a row of em dashes.
    if (hasGpu) {
      var gpu = []
      if (hasGpuUsage) gpu.push("GPU " + percent(metrics.gpuPercent))
      if (hasGpuTemperature) gpu.push((hasGpuUsage ? "" : "GPU ") + gpuTemperatureText())
      if (hasGpuVram) gpu.push("VRAM " + gpuVramDetail())
      lines.push(gpu.join(" · "))
    }
    if (metrics.fans.length > 0) {
      var speeds = []
      for (var fanIndex = 0; fanIndex < metrics.fans.length; fanIndex++) {
        var fan = metrics.fans[fanIndex]
        speeds.push(isFinite(fan.rpm) && fan.rpm >= 0 ? Math.round(fan.rpm) + " RPM" : "—")
      }
      lines.push("Fans " + speeds.join(" / ") + (metrics.fansManual ? " · " + metrics.fanMode : " · SMC"))
    }
    lines.push("Load " + loadText() + (interfaceName !== "" ? " · " + interfaceName : ""))
    lines.push("Net ↓ " + formatRate(metrics.networkDownBps) + " ↑ " + formatRate(metrics.networkUpBps))
    lines.push("Disk R " + formatRate(metrics.diskReadBps) + " · W " + formatRate(metrics.diskWriteBps))
    lines.push("Right-click cycles display · Middle-click opens btop")
    return lines.join("\n")
  }

  function cycleBarMode() {
    // Temp is opt-in via cycle / settings — never selected by Adaptive.
    var modes = hasGpuUsage
      ? ["Adaptive", "CPU", "Memory", "GPU", "Temp", "Both", "Icon"]
      : ["Adaptive", "CPU", "Memory", "Temp", "Both", "Icon"]
    var index = modes.indexOf(barMode)
    var next = modes[(index + 1) % modes.length]
    settings = Object.assign({}, settings, { barMode: next })
    if (bar && bar.shell) bar.shell.updateEntryInline(moduleName, settings)
  }

  function launchBtop() {
    if (bar) bar.run("omarchy-launch-or-focus-tui btop")
    close()
  }

  function moveCursor(delta) {
    if (delta === 0) return
    selectedIndex = Math.max(0, Math.min(actionCount - 1, selectedIndex + delta))
  }

  function activateCursor() {
    if (selectedIndex === 0) cycleBarMode()
    else launchBtop()
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var point = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = point.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = Style.space(6)
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin) flick.contentY = bottom + margin - flick.height
  }

  visible: true
  implicitWidth: iconOnly ? iconButton.implicitWidth : button.implicitWidth
  implicitHeight: iconOnly ? iconButton.implicitHeight : button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      selectedIndex = 0
      metrics.sample()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  Metrics {
    id: metrics
    settings: root.settings
    panelOpen: root.opened
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { metrics.sample(); return "ok" }
  }

  function barPressed(buttonCode) {
    if (buttonCode === Qt.RightButton) cycleBarMode()
    else if (buttonCode === Qt.MiddleButton) launchBtop()
    else toggle()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    visible: !root.iconOnly
    bar: root.bar
    text: root.barLabel()
    fontSize: Style.font.caption
    horizontalMargin: 6
    active: root.warning || root.critical
    activeColor: root.critical ? root.urgent : root.warningColor
    tooltipText: root.tooltipText()
    onPressed: function(buttonCode) { root.barPressed(buttonCode) }
  }

  BarIconButton {
    id: iconButton
    anchors.fill: parent
    visible: root.iconOnly
    bar: root.bar
    text: root.heroGlyph
    active: root.warning || root.critical
    activeColor: root.critical ? root.urgent : root.warningColor
    tooltipText: root.tooltipText()
    onPressed: function(buttonCode) { root.barPressed(buttonCode) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.iconOnly ? iconButton : button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Capped height, not a fixed one: fittedContentHeight still shrinks to fit
    // the screen and to the content itself, this just raises the ceiling so
    // the added CapacityRow entries (one per auto-discovered disk), platform
    // sensor rows, thermal and RPM charts, and the fans section aren't
    // clipped.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(600 + metrics.extraFilesystems.length * 40 + (metrics.hasPlatformSensors ? metrics.platformSensors.length * 40 + (metrics.fanMode === "custom" ? 400 : 300) : 0)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx !== 0 ? dx : dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onTextKey: function(text) {
        if (text === "r" || text === "R") metrics.sample()
        else if (text === "b" || text === "B") root.launchBtop()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(9)

          // ---------- Hero: host · uptime and load ----------
          PanelHero {
            width: parent.width
            title: metrics.hostname !== "" ? metrics.hostname : "System Monitor"
            meta: "Up " + root.formatUptime(metrics.uptimeSeconds) + " · Load " + root.loadText()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: root.heroGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh (R)"
                foreground: root.foreground
                hoverColor: root.accent
                fontFamily: root.fontFamily
                onClicked: metrics.sample()
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- Headline metrics ----------
          Row {
            width: parent.width
            spacing: Style.space(8)

            StatTile {
              width: (parent.width - parent.spacing * 2) / 3
              title: "CPU"
              value: root.percent(metrics.cpuPercent)
              detail: metrics.perCore.length > 0 ? metrics.perCore.length + " threads" : "—"
              meter: metrics.cpuPercent
              meterColor: root.levelColor(metrics.cpuPercent, root.warningThreshold, root.criticalThreshold)
              alarming: metrics.cpuPercent >= root.criticalThreshold
            }

            StatTile {
              width: (parent.width - parent.spacing * 2) / 3
              title: "MEMORY"
              value: root.percent(metrics.memoryPercent)
              detail: root.formatPair(metrics.memoryUsed, metrics.memoryTotal)
              meter: metrics.memoryPercent
              meterColor: root.levelColor(metrics.memoryPercent, root.warningThreshold, root.criticalThreshold)
              alarming: metrics.memoryPercent >= root.criticalThreshold
            }

            StatTile {
              width: (parent.width - parent.spacing * 2) / 3
              title: root.thermalTileTitle()
              value: root.thermalTileValue()
              detail: root.thermalTileDetail()
              meter: root.thermalTileMeter()
              meterColor: root.thermalTileMeterColor()
              alarming: root.thermalTileAlarming()
            }
          }

          // ---------- GPU ----------
          // Hidden outright when no card publishes utilisation, so machines
          // without one keep the original three-tile layout.
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.hasGpu

            StatTile {
              visible: root.hasGpuUsage
              width: root.gpuTileWidth(parent.width, parent.spacing)
              title: "GPU"
              value: root.percent(metrics.gpuPercent)
              detail: root.hasGpuVram ? root.formatBytes(metrics.gpuVramTotal) + " VRAM" : "—"
              meter: metrics.gpuPercent
              meterColor: root.levelColor(metrics.gpuPercent, root.warningThreshold, root.criticalThreshold)
              alarming: metrics.gpuPercent >= root.criticalThreshold
            }

            StatTile {
              visible: root.hasGpuTemperature
              width: root.gpuTileWidth(parent.width, parent.spacing)
              title: "GPU TEMP"
              value: root.gpuTemperatureText()
              detail: root.gpuTemperatureDetail()
              meter: root.gpuTemperatureMeter()
              meterColor: root.levelColor(metrics.gpuTemperature, 85, 95)
              alarming: metrics.gpuTemperature >= 95
            }

            StatTile {
              visible: root.hasGpuVram
              width: root.gpuTileWidth(parent.width, parent.spacing)
              title: "VRAM"
              value: root.percent(root.gpuVramPercent())
              detail: root.gpuVramDetail()
              meter: root.gpuVramPercent()
              meterColor: root.levelColor(root.gpuVramPercent(), root.warningThreshold, root.criticalThreshold)
              alarming: root.gpuVramPercent() >= root.criticalThreshold
            }
          }

          // ---------- Platform sensors (Apple Silicon) ----------
          // Asahi machines have no package sensor, but the SMC publishes
          // labelled peripheral temperatures and power rails. Default list
          // is the useful few; "show all" reveals the rest.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: metrics.hasPlatformSensors

            SectionHeading {
              title: "SENSORS"
              value: root.sensorSummaryText()
            }

            // Thermal headline over time — the same value the HEAT tile
            // carries (heatpipe watts here, package temperature elsewhere),
            // peak-scaled like the network chart.
            Item {
              width: parent.width
              height: Style.space(54)
              visible: metrics.thermalHistory.length > 1

              Sparkline {
                anchors.fill: parent
                points: metrics.thermalHistory
                lineColor: root.accent
                fillColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                gridColor: root.chartGrid
                fixedMaximum: Math.max(metrics.thermalPeak, 0.001)
              }

              Text {
                anchors.left: parent.left
                anchors.top: parent.top
                text: metrics.thermalHeadline >= 0
                  ? metrics.thermalHeadline.toFixed(1) + " " + metrics.thermalHeadlineUnit
                  : ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                anchors.right: parent.right
                anchors.top: parent.top
                text: metrics.thermalPeak > 0
                  ? "peak " + (metrics.thermalPeak >= 100
                      ? Math.round(metrics.thermalPeak)
                      : metrics.thermalPeak.toFixed(1)) + " " + metrics.thermalHeadlineUnit
                  : ""
                textFormat: Text.PlainText
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: root.visiblePlatformSensors()

              SensorRow {
                required property var modelData
                label: modelData.label
                value: root.sensorValueText(modelData)
                meter: modelData.kind === "temp" ? root.temperatureBandMeter(modelData.value) : -1
                meterColor: root.levelColor(modelData.value, 85, 95)
              }
            }

            Button {
              visible: root.hiddenPlatformSensorCount() > 0 || root.showAllPlatformSensors
              width: parent.width
              text: root.showAllPlatformSensors
                ? "Show fewer sensors"
                : ("Show all sensors · " + root.hiddenPlatformSensorCount() + " more")
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.showAllPlatformSensors = !root.showAllPlatformSensors
            }
          }

          // ---------- Fans (Apple Silicon) ----------
          // Macs Fan Control-style: live RPMs plus the preset selector.
          // Auto hands the fans back to the SMC's own curve; the others
          // run in the asahi-fand daemon following heatpipe power.
          // Hidden without the SMC hwmon device.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: metrics.hasPlatformSensors

            SectionHeading {
              title: "FANS"
              value: root.fansSummaryText()
            }

            Repeater {
              model: metrics.fans

              FanRow {
                required property var modelData
                label: modelData.label
                rpmText: root.fanRpmText(modelData)
                rangeText: (isFinite(modelData.min) && isFinite(modelData.max)
                  ? Math.round(modelData.min) + "–" + Math.round(modelData.max) + " RPM" : "")
                manual: metrics.fansManual
              }
            }

            Text {
              visible: metrics.fanCtlError !== ""
              width: parent.width
              text: metrics.fanCtlError
              textFormat: Text.PlainText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Helper missing: sensors keep working, control just isn't
            // possible. Point at the README rather than a dead button.
            Text {
              visible: !metrics.fanCtlAvailable
              width: parent.width
              text: "Fan control requires the asahi-fanctl helper (see README)"
              textFormat: Text.PlainText
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Control locked (module parameter off): one click unlocks it.
            Button {
              visible: metrics.fanCtlAvailable && !metrics.fanControlUnlocked
              width: parent.width
              text: "Enable manual control"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: metrics.enableFanControl()
            }

            // Presets, deliberately far apart so they feel different:
            // Auto (SMC), Quiet (minimum idle, capped), Boost (audible
            // floor, full by 14 W), Full, Custom. One row.
            ButtonGroup {
              width: parent.width
              visible: metrics.fanCtlAvailable
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              options: [
                { value: "auto", label: "Auto" },
                { value: "quiet", label: "Quiet" },
                { value: "boost", label: "Boost" },
                { value: "full", label: "Full" },
                { value: "custom", label: "Custom" }
              ]
              value: metrics.fanMode
              onChanged: function(selected) { metrics.runFanctl(["mode", selected]) }
            }

            // Custom curve: RPM scales from rpm min to max as heatpipe power
            // crosses the watt window; the floor is an always-at-least RPM.
            Column {
              id: curveEditor
              width: parent.width
              spacing: Style.space(4)
              visible: metrics.fanMode === "custom"

              Row {
                spacing: Style.space(8)

                NumberField {
                  id: loWField
                  label: "Low W"
                  from: 0
                  to: 60
                  stepSize: 1
                  value: Math.round(metrics.fanCurveLoW)
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                }

                NumberField {
                  id: hiWField
                  label: "High W"
                  from: 1
                  to: 100
                  stepSize: 1
                  value: Math.round(metrics.fanCurveHiW)
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                }

                NumberField {
                  id: floorField
                  label: "Floor RPM"
                  from: 0
                  to: 6400
                  stepSize: 50
                  value: Math.round(metrics.fanCurveFloorRpm)
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                }
              }

              Row {
                spacing: Style.space(8)

                NumberField {
                  id: rpmMinField
                  label: "Min RPM"
                  from: 1200
                  to: 6400
                  stepSize: 50
                  value: Math.round(metrics.fanCurveRpmMin)
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                }

                NumberField {
                  id: rpmMaxField
                  label: "Max RPM"
                  from: 1200
                  to: 6400
                  stepSize: 50
                  value: Math.round(metrics.fanCurveRpmMax)
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                }

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Apply"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.applyFanCurve()
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- CPU and memory history ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            SectionHeading {
              title: root.hasGpuUsage ? "CPU, MEMORY & GPU" : "CPU & MEMORY"
              value: "2 MIN"
            }

            Item {
              width: parent.width
              height: Style.space(70)

              Sparkline {
                anchors.fill: parent
                points: metrics.cpuHistory
                lineColor: root.accent
                fillColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                gridColor: root.chartGrid
                gridLevels: [0.25, 0.5, 0.75]
                fixedMaximum: 100
              }

              Sparkline {
                anchors.fill: parent
                points: metrics.memoryHistory
                lineColor: root.secondary
                fillColor: "transparent"
                dashed: true
                lineWidth: 1.2
                fixedMaximum: 100
              }

              Sparkline {
                anchors.fill: parent
                visible: root.hasGpuUsage
                points: metrics.gpuHistory
                lineColor: root.warningColor
                fillColor: "transparent"
                lineWidth: 1.2
                fixedMaximum: 100
              }

              // The scale is pinned at 100%, so say so — otherwise an idle
              // machine just looks like an empty box.
              Text {
                anchors.left: parent.left
                anchors.top: parent.top
                text: "100%"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                anchors.top: parent.top
                anchors.right: parent.right
                spacing: Style.space(8)
                LegendDot { colorValue: root.accent; label: "CPU" }
                LegendDot { colorValue: root.secondary; label: "RAM" }
                LegendDot { visible: root.hasGpuUsage; colorValue: root.warningColor; label: "GPU" }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- Per-thread load ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: metrics.perCore.length > 0

            SectionHeading {
              title: "CORES"
              value: metrics.perCore.length + " threads · peak " + root.percent(metrics.coreMaximum)
            }

            Row {
              id: coreStrip
              width: parent.width
              height: Style.space(18)
              spacing: Style.space(3)

              readonly property real cellWidth: metrics.perCore.length > 0
                ? (width - spacing * (metrics.perCore.length - 1)) / metrics.perCore.length
                : 0
              // Numbers only survive down to about four characters; past that
              // the tint carries the reading on its own.
              readonly property bool showValues: cellWidth >= Style.space(30)

              Repeater {
                model: metrics.perCore

                Rectangle {
                  id: coreCell
                  required property var modelData

                  readonly property real load: Math.max(0, Math.min(100, modelData.percent)) / 100

                  width: coreStrip.cellWidth
                  height: coreStrip.height
                  radius: Style.cornerRadius
                  color: root.trackColor

                  // Heat, not a bar: a 5%-loaded core drawn as a bar is a 1px
                  // sliver that reads as a rendering artifact, while a tint
                  // stays legible across the whole range.
                  Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: root.levelColor(coreCell.modelData.percent, root.warningThreshold, root.criticalThreshold)
                    opacity: 0.12 + 0.68 * coreCell.load
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: coreStrip.showValues
                    text: root.percent(coreCell.modelData.percent)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- Throughput ----------
          Column {
            width: parent.width
            spacing: Style.space(8)

            ActivityColumn {
              width: parent.width
              title: metrics.activeInterface !== "" ? "NET · " + metrics.activeInterface : "NET"
              downValue: metrics.networkDownBps
              upValue: metrics.networkUpBps
              downPoints: metrics.networkDownHistory
              upPoints: metrics.networkUpHistory
              peak: metrics.networkPeak
            }

            // Disk gets a single readout line. Its history is the least
            // watched thing in the panel, and dropping the plot buys the
            // network chart the full width.
            Item {
              width: parent.width
              implicitHeight: Math.max(diskName.implicitHeight, diskRates.implicitHeight)

              PanelSectionHeader {
                id: diskName
                text: root.diskLabelText()
                foreground: root.foreground
                fontFamily: root.fontFamily
                elide: Text.ElideRight
                anchors.left: parent.left
                anchors.right: diskRates.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                id: diskRates
                spacing: Style.space(14)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                RateLabel {
                  glyph: "W"
                  glyphColor: root.accent
                  value: metrics.diskWriteBps
                }

                RateLabel {
                  glyph: "R"
                  glyphColor: root.secondary
                  value: metrics.diskReadBps
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- Capacity ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            SectionHeading { title: "CAPACITY" }

            CapacityRow {
              label: "Root filesystem"
              value: root.formatPair(metrics.filesystemUsed, metrics.filesystemTotal)
              percentValue: metrics.filesystemPercent
            }

            CapacityRow {
              visible: metrics.swapTotal > 0
              label: "Swap"
              value: root.formatPair(metrics.swapUsed, metrics.swapTotal)
              percentValue: metrics.swapPercent
            }

            Repeater {
              model: metrics.extraFilesystems

              CapacityRow {
                required property var modelData
                label: root.mountLabel(modelData.mount)
                value: root.formatPair(modelData.used, modelData.total)
                percentValue: modelData.percent
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- Actions ----------
          Row {
            width: parent.width
            spacing: Style.space(8)

            ActionButton {
              width: (parent.width - parent.spacing) / 2
              index: 0
              iconText: "󰑖"
              text: "Bar · " + root.modeLabel()
              tooltipText: "Cycle bar display — also right-click the widget"
              onClicked: root.cycleBarMode()
            }

            ActionButton {
              width: (parent.width - parent.spacing) / 2
              index: 1
              iconText: "󰆍"
              text: "Open btop"
              tooltipText: "Open btop (B)"
              onClicked: root.launchBtop()
            }
          }
        }
      }
    }
  }

  // Section label on the left, its live summary on the right — the shell's
  // house pattern, and it buys back the line a lone header would waste.
  component SectionHeading: Item {
    property string title: ""
    property string value: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(headingText.implicitHeight, valueText.implicitHeight)

    PanelSectionHeader {
      id: headingText
      text: title
      textFormat: Text.PlainText
      foreground: root.foreground
      fontFamily: root.fontFamily
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.right: valueText.visible ? valueText.left : parent.right
      anchors.rightMargin: valueText.visible ? Style.space(8) : 0
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: valueText
      text: value
      visible: text !== ""
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
      width: Math.min(implicitWidth, parent.width * 0.62)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
    }
  }

  component Meter: Rectangle {
    id: meter
    property real value: -1
    property real maximum: 100
    property color fillColor: root.accent

    height: Style.space(3)
    radius: height / 2
    color: root.trackColor

    Rectangle {
      width: meter.width * Math.max(0, Math.min(1, meter.value / meter.maximum))
      height: meter.height
      radius: meter.radius
      color: meter.fillColor

      Behavior on width {
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
      }
    }
  }

  component StatTile: BorderSurface {
    id: tile
    property string title: ""
    property string value: "—"
    property string detail: ""
    property real meter: -1
    property color meterColor: root.accent
    property bool alarming: false

    height: Style.space(80)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.foreground, root.accent)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(9)
      spacing: Style.space(2)

      Text {
        text: tile.title
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }

      Text {
        text: tile.value
        color: tile.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        width: parent.width
        text: tile.detail
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Meter {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(9)
      value: tile.meter
      fillColor: tile.meterColor
    }
  }

  component LegendDot: Row {
    property color colorValue: "white"
    property string label: ""
    spacing: Style.space(4)

    Rectangle {
      width: Style.space(6)
      height: width
      radius: width / 2
      color: parent.colorValue
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: parent.label
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Down and up never get summed together: up is drawn above the axis, down
  // below it, on one shared scale that the corner label spells out.
  component ActivityColumn: Column {
    id: activity
    property string title: ""
    property real downValue: -1
    property real upValue: -1
    property var downPoints: []
    property var upPoints: []
    property real peak: 0

    spacing: Style.space(4)

    // The scale label rides the header rather than the plot: laid over the
    // chart it lands right where the spikes are.
    SectionHeading {
      title: activity.title
      value: activity.peak > 0 ? "±" + root.formatRate(activity.peak) : ""
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(upRate.implicitHeight, downRate.implicitHeight)

      RateLabel {
        id: upRate
        anchors.left: parent.left
        glyph: "↑"
        glyphColor: root.accent
        value: activity.upValue
      }

      RateLabel {
        id: downRate
        anchors.right: parent.right
        glyph: "↓"
        glyphColor: root.secondary
        value: activity.downValue
      }
    }

    Sparkline {
      width: parent.width
      height: Style.space(34)
      points: activity.upPoints
      mirrorPoints: activity.downPoints
      lineColor: root.accent
      mirrorLineColor: root.secondary
      gridColor: root.chartGrid
      fixedMaximum: activity.peak
    }
  }

  // The arrow carries its series' color so a value maps to a half of the
  // mirrored chart without a second legend.
  component RateLabel: Row {
    id: rate
    property string glyph: ""
    property color glyphColor: root.accent
    property real value: -1
    spacing: Style.space(4)

    Text {
      text: rate.glyph
      color: rate.glyphColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Text {
      text: root.formatRate(rate.value)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // One platform sensor: label left, live value right, and for temperatures
  // the same anchored meter band the package tiles use. Power rails skip the
  // meter — there is no natural ceiling for watts.
  component SensorRow: Column {
    id: sensorRow
    property string label: ""
    property string value: "—"
    property real meter: -1
    property color meterColor: root.accent

    width: parent ? parent.width : 0
    spacing: Style.space(3)

    Item {
      width: parent.width
      implicitHeight: Math.max(sensorLabel.implicitHeight, sensorValue.implicitHeight)

      Text {
        id: sensorLabel
        text: sensorRow.label
        // Labels arrive from sysfs label files, so pin the format instead of
        // leaving Text.AutoText to sniff a crafted label as rich text.
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: sensorValue
        text: sensorRow.value
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      visible: sensorRow.meter >= 0
      value: sensorRow.meter
      fillColor: sensorRow.meterColor
    }
  }

  // One fan: label and live RPM on the first line, the driver's RPM window
  // beneath it. The RPM value warms up while the fan is under manual control
  // so the row itself says which side owns it.
  component FanRow: Column {
    id: fanRow
    property string label: ""
    property string rpmText: "—"
    property string rangeText: ""
    property bool manual: false

    width: parent ? parent.width : 0
    spacing: Style.space(3)

    Item {
      width: parent.width
      implicitHeight: Math.max(fanLabel.implicitHeight, fanRpm.implicitHeight)

      Text {
        id: fanLabel
        text: fanRow.label
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: fanRpm
        text: fanRow.rpmText
        textFormat: Text.PlainText
        color: fanRow.manual ? root.warningColor : root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      visible: fanRow.rangeText !== ""
      text: fanRow.rangeText
      textFormat: Text.PlainText
      color: root.muted
      opacity: 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component CapacityRow: Column {
    id: capacity
    property string label: ""
    property string value: "—"
    property real percentValue: -1

    width: parent ? parent.width : 0
    spacing: Style.space(3)

    Item {
      width: parent.width
      implicitHeight: Math.max(capacityLabel.implicitHeight, capacityValue.implicitHeight)

      Text {
        id: capacityLabel
        text: capacity.label
        // Mount paths reach this label from df, so pin the format instead of
        // leaving Text.AutoText to sniff a crafted path as rich text.
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: capacityValue
        text: capacity.value
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: capacity.percentValue
      fillColor: root.levelColor(capacity.percentValue, root.warningThreshold, root.criticalThreshold)
    }
  }

  component ActionButton: Button {
    id: actionButton
    property int index: -1

    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    iconSize: Style.font.icon
    hasCursor: root.cursorActive && root.selectedIndex === actionButton.index
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(actionButton)
    onHovered: function(isHovered) {
      if (!isHovered) return
      root.cursorActive = true
      root.selectedIndex = actionButton.index
    }
  }
}
