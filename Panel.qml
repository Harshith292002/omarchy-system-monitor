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
  readonly property real warningThreshold: Math.min(Number(setting("warningPercent", 80)), criticalThreshold - 1)
  readonly property real criticalThreshold: Math.max(Number(setting("criticalPercent", 95)), 61)
  readonly property real pressure: Math.max(metrics.cpuPercent, metrics.memoryPercent)
  readonly property bool warning: pressure >= warningThreshold || metrics.cpuTemperature >= 85
  readonly property bool critical: pressure >= criticalThreshold || metrics.cpuTemperature >= 95

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

  function temperatureText() {
    return metrics.cpuTemperature >= 0 ? Math.round(metrics.cpuTemperature) + "°C" : "—"
  }

  function temperatureDetail() {
    if (metrics.cpuTemperature < 0) return "Unavailable"
    if (metrics.cpuTemperature >= 85) return "Warm"
    return "Normal"
  }

  function temperatureMeter() {
    if (metrics.cpuTemperature < 0) return -1
    var span = temperatureCeiling - temperatureFloor
    return Math.max(0, Math.min(100, (metrics.cpuTemperature - temperatureFloor) * 100 / span))
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
      var value = barMode === "CPU" ? metrics.cpuPercent
        : barMode === "Memory" ? metrics.memoryPercent
        : Math.max(metrics.cpuPercent, metrics.memoryPercent)
      return isFinite(value) && value >= 0 ? String(Math.round(value)) : "—"
    }
    if (barMode === "CPU") return "CPU " + padPercent(metrics.cpuPercent)
    if (barMode === "Memory") return "RAM " + padPercent(metrics.memoryPercent)
    if (barMode === "Both")
      return "C " + padPercent(metrics.cpuPercent) + " M " + padPercent(metrics.memoryPercent)
    // Adaptive: whichever metric is under more pressure, named so the number
    // is never ambiguous.
    return metrics.cpuPercent >= metrics.memoryPercent
      ? "CPU " + padPercent(metrics.cpuPercent)
      : "RAM " + padPercent(metrics.memoryPercent)
  }

  function tooltipText() {
    // WidgetButton's shared tooltip only accepts a string and renders it with
    // Text.AutoText, so neutralize markup before handing it configuration.
    var interfaceName = Model.escapeMarkup(metrics.activeInterface)
    return [
      "CPU " + percent(metrics.cpuPercent) + " · RAM " + percent(metrics.memoryPercent) + " · " + temperatureText(),
      "Load " + loadText() + (interfaceName !== "" ? " · " + interfaceName : ""),
      "Net ↓ " + formatRate(metrics.networkDownBps) + " ↑ " + formatRate(metrics.networkUpBps),
      "Disk R " + formatRate(metrics.diskReadBps) + " · W " + formatRate(metrics.diskWriteBps),
      "Right-click cycles display · Middle-click opens btop"
    ].join("\n")
  }

  function cycleBarMode() {
    var modes = ["Adaptive", "CPU", "Memory", "Both"]
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
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel()
    fontSize: Style.font.caption
    horizontalMargin: 6
    active: root.warning || root.critical
    activeColor: root.critical ? root.urgent : root.warningColor
    tooltipText: root.tooltipText()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.cycleBarMode()
      else if (buttonCode === Qt.MiddleButton) root.launchBtop()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(600))

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
              title: "TEMP"
              value: root.temperatureText()
              detail: root.temperatureDetail()
              meter: root.temperatureMeter()
              meterColor: root.levelColor(metrics.cpuTemperature, 85, 95)
              alarming: metrics.cpuTemperature >= 95
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- CPU and memory history ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            SectionHeading {
              title: "CPU & MEMORY"
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
