import QtQuick
import Quickshell
import "." as Plugin

ShellRoot {
  id: root
  property int stage: 0

  function check(condition, message) {
    if (!condition) {
      console.error("FAIL: " + message)
      Qt.exit(1)
    }
  }

  Plugin.Metrics {
    id: metrics
    settings: ({ openRefreshSec: 1, closedRefreshSec: 2 })
  }

  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      if (root.stage === 0 && metrics.gpuPercent === 41) {
        root.check(metrics.gpuTemperature === 53 && metrics.gpuVramUsed === -1, "closed panel samples load and temperature only")
        root.check(metrics.gpuVramTotal === 8589934592, "capacity is cached at discovery")
        root.check(metrics.gpuHistory.length >= 2, "one process streams multiple history samples")
        metrics.panelOpen = true
        root.stage = 1
      } else if (root.stage === 1 && metrics.gpuPercent === 12) {
        root.check(metrics.gpuTemperature === -1 && metrics.gpuVramUsed === 268435456, "N/A leaves VRAM available")
        root.stage = 2
      } else if (root.stage === 2 && metrics.gpuPercent === 18) {
        root.check(metrics.gpuVramUsed === 536870912, "used VRAM refreshes while open")
        root.stage = 3
      } else if (root.stage === 3 && metrics.gpuPercent === -1) {
        root.check(metrics.gpuVramUsed === -1 && metrics.gpuVramTotal === 8589934592, "failed stream clears live values and retains capacity")
        root.stage = 4
      } else if (root.stage === 4 && metrics.gpuPercent === 25) {
        root.stage = 5
      } else if (root.stage === 5 && metrics.gpuPercent === -1) {
        root.check(metrics.gpuVramUsed === -1, "watchdog clears stalled readings")
        root.stage = 6
      } else if (root.stage === 6 && metrics.gpuPercent === 0) {
        root.check(metrics.gpuTemperature === 40 && metrics.gpuVramUsed === 0, "stream recovers from forced termination")
        metrics.panelOpen = false
        root.stage = 7
      } else if (root.stage === 7 && metrics.gpuPercent === 55) {
        root.check(metrics.gpuTemperature === 46, "closing panel restores GPU bar cadence")
        root.check(metrics.gpuVramUsed === 0, "closing panel retains cached VRAM like sysfs monitoring")
        root.check(metrics.gpuHistory.length > 1, "history continues with the panel closed")
        console.log("NVIDIA QML runtime checks passed")
        Qt.quit()
      }
    }
  }

  Timer {
    interval: 22000
    running: true
    onTriggered: {
      console.error("FAIL: NVIDIA runtime stalled at stage " + root.stage)
      Qt.exit(1)
    }
  }
}
