import QtQuick
import Quickshell
import Quickshell.Io
import "." as Plugin

ShellRoot {
  id: root
  property int stage: 0
  property int historyCount: 0
  readonly property string device: Quickshell.env("OMARCHY_SYSMON_DRM_ROOT") + "/card0/device"

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

  Process {
    id: changeSensors
    property string busy: "31"
    property string temp: "62000"
    property string used: "2048"
    command: ["bash", "-c", "printf '%s\\n' \"$2\" >\"$1/gpu_busy_percent\"; printf '%s\\n' \"$3\" >\"$1/hwmon/hwmon0/temp1_input\"; printf '%s\\n' \"$4\" >\"$1/mem_info_vram_used\"", "-", root.device, busy, temp, used]
  }

  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      if (root.stage === 0 && metrics.gpuPercent === 7 && metrics.gpuTemperature === 50 && metrics.gpuVramUsed === 1024) {
        root.check(metrics.gpuVramTotal === 8192, "AMD discovery reads VRAM once")
        changeSensors.running = true
        root.stage = 1
      } else if (root.stage === 1 && metrics.gpuPercent === 31 && metrics.gpuTemperature === 62) {
        root.check(metrics.gpuVramUsed === 1024, "closed panel preserves cached VRAM")
        root.check(metrics.gpuHistory.length > 1, "AMD history continues while hidden")
        metrics.panelOpen = true
        root.stage = 2
      } else if (root.stage === 2 && metrics.gpuVramUsed === 2048) {
        root.historyCount = metrics.gpuHistory.length
        metrics.panelOpen = false
        changeSensors.busy = "47"
        changeSensors.temp = "75000"
        changeSensors.used = "3072"
        changeSensors.running = true
        root.stage = 3
      } else if (root.stage === 3 && metrics.gpuPercent === 47 && metrics.gpuTemperature === 75) {
        root.check(metrics.gpuVramUsed === 2048, "closing AMD panel retains latest VRAM")
        root.check(metrics.gpuHistory.length > root.historyCount, "AMD history survives panel transitions")
        console.log("AMD continuous monitoring checks passed")
        Qt.quit()
      }
    }
  }

  Timer {
    interval: 10000
    running: true
    onTriggered: {
      console.error("FAIL: AMD continuous checks stalled at stage " + root.stage)
      Qt.exit(1)
    }
  }
}
