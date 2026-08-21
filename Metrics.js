function finiteNumber(value, fallback) {
  var number = Number(value)
  return isFinite(number) ? number : fallback
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value))
}

// WidgetButton forwards tooltip strings to the shell's shared Text item,
// which currently uses Qt's automatic rich-text detection. Escape markup at
// that boundary so configuration-derived labels cannot become HTML there.
function escapeMarkup(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

function parseCpu(raw, previous) {
  var lines = String(raw || "").split("\n")
  var snapshots = ({})
  var usages = ({})

  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].trim().split(/\s+/)
    if (!/^cpu\d*$/.test(fields[0] || "")) continue

    var values = []
    for (var field = 1; field <= 8; field++) values.push(finiteNumber(fields[field], 0))
    var total = 0
    for (var value = 0; value < values.length; value++) total += values[value]
    var idle = values[3] + values[4]
    snapshots[fields[0]] = { total: total, idle: idle }

    var before = previous ? previous[fields[0]] : null
    if (!before) continue
    var totalDelta = total - before.total
    var idleDelta = idle - before.idle
    if (totalDelta <= 0 || idleDelta < 0) continue
    usages[fields[0]] = clamp((totalDelta - idleDelta) * 100 / totalDelta, 0, 100)
  }

  var cores = []
  var labels = Object.keys(usages).filter(function(label) { return label !== "cpu" })
  labels.sort(function(a, b) { return Number(a.slice(3)) - Number(b.slice(3)) })
  for (var core = 0; core < labels.length; core++) {
    cores.push({ name: labels[core].toUpperCase(), percent: usages[labels[core]] })
  }

  return {
    snapshot: snapshots,
    overall: usages.cpu === undefined ? -1 : usages.cpu,
    cores: cores
  }
}

function parseMemory(raw) {
  var values = ({})
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^([A-Za-z_()]+):\s+(\d+)/)
    if (match) values[match[1]] = Number(match[2]) * 1024
  }

  var total = values.MemTotal || 0
  var available = values.MemAvailable || 0
  var used = total > 0 ? Math.max(0, total - available) : 0
  var swapTotal = values.SwapTotal || 0
  var swapUsed = Math.max(0, swapTotal - (values.SwapFree || 0))
  return {
    total: total,
    used: used,
    percent: total > 0 ? clamp(used * 100 / total, 0, 100) : -1,
    swapTotal: swapTotal,
    swapUsed: swapUsed,
    swapPercent: swapTotal > 0 ? clamp(swapUsed * 100 / swapTotal, 0, 100) : -1
  }
}

function parseLoad(raw) {
  var fields = String(raw || "").trim().split(/\s+/)
  return {
    one: finiteNumber(fields[0], -1),
    five: finiteNumber(fields[1], -1),
    fifteen: finiteNumber(fields[2], -1)
  }
}

function parseUptime(raw) {
  return Math.max(0, finiteNumber(String(raw || "").trim().split(/\s+/)[0], 0))
}

function parseDefaultInterface(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = 1; i < lines.length; i++) {
    var fields = lines[i].trim().split(/\s+/)
    if (fields.length < 4 || fields[1] !== "00000000") continue
    var flags = parseInt(fields[3], 16)
    if (isFinite(flags) && (flags & 2) !== 0) return fields[0]
  }
  return ""
}

function parseNetwork(raw, interfaceName) {
  if (!interfaceName) return null
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var separator = lines[i].indexOf(":")
    if (separator < 0) continue
    var name = lines[i].slice(0, separator).trim()
    if (name !== interfaceName) continue
    var fields = lines[i].slice(separator + 1).trim().split(/\s+/)
    if (fields.length < 9) return null
    return { rx: finiteNumber(fields[0], 0), tx: finiteNumber(fields[8], 0) }
  }
  return null
}

function parseDisk(raw, devices) {
  var wanted = ({})
  for (var i = 0; i < devices.length; i++) wanted[String(devices[i])] = true
  var readSectors = 0
  var writeSectors = 0
  var found = false
  var lines = String(raw || "").split("\n")

  for (var line = 0; line < lines.length; line++) {
    var fields = lines[line].trim().split(/\s+/)
    if (fields.length < 10 || !wanted[fields[2]]) continue
    readSectors += finiteNumber(fields[5], 0)
    writeSectors += finiteNumber(fields[9], 0)
    found = true
  }

  return found ? { readBytes: readSectors * 512, writeBytes: writeSectors * 512 } : null
}

function parseDiscovery(raw) {
  var result = { cpuTempPath: "", devices: [] }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var separator = lines[i].indexOf("\t")
    if (separator < 0) continue
    var key = lines[i].slice(0, separator)
    var value = lines[i].slice(separator + 1).trim()
    if (key === "cpu_temp") result.cpuTempPath = value
    else if (key === "disk" && value !== "") result.devices.push(value)
  }
  return result
}

function parseFilesystem(raw) {
  var lines = String(raw || "").trim().split("\n")
  if (lines.length < 2) return null
  var fields = lines[lines.length - 1].trim().split(/\s+/)
  if (fields.length < 6) return null
  var total = finiteNumber(fields[1], 0) * 1024
  var used = finiteNumber(fields[2], 0) * 1024
  return {
    total: total,
    used: used,
    percent: total > 0 ? clamp(used * 100 / total, 0, 100) : -1
  }
}

// Rolling-window peak, used to pin a sparkline's vertical scale so the chart
// and its printed scale label agree.
function peakValue(history) {
  var peak = 0
  if (!history) return peak
  for (var i = 0; i < history.length; i++) {
    var value = Number(history[i].value)
    if (isFinite(value) && value > peak) peak = value
  }
  return peak
}

function maximumPercent(cores) {
  var peak = -1
  if (!cores) return peak
  for (var i = 0; i < cores.length; i++) {
    var value = Number(cores[i].percent)
    if (isFinite(value) && value > peak) peak = value
  }
  return peak
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    parseCpu: parseCpu,
    parseMemory: parseMemory,
    parseLoad: parseLoad,
    parseUptime: parseUptime,
    parseDefaultInterface: parseDefaultInterface,
    parseNetwork: parseNetwork,
    parseDisk: parseDisk,
    parseDiscovery: parseDiscovery,
    parseFilesystem: parseFilesystem,
    peakValue: peakValue,
    maximumPercent: maximumPercent,
    escapeMarkup: escapeMarkup
  }
}
