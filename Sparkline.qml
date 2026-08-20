import QtQuick

// Rolling time-series plot with two shapes:
//
//   single — `points` drawn as a line over an optional fill, growing up from
//            the bottom edge. Optional `gridLevels` draw faint rules at
//            fractions of full scale so a mostly-idle chart still reads as
//            "lots of headroom" rather than "empty box".
//
//   mirror — `points` above a center axis and `mirrorPoints` below it, on one
//            shared scale. Used for the send/receive pairs so direction
//            survives the trip to the screen instead of being summed away.
//
// `fixedMaximum` pins the vertical scale so the caller can label the chart
// with the same number it was drawn against; leave it <= 0 to auto-scale to
// the window peak.
Canvas {
  id: root

  property var points: []
  property var mirrorPoints: null
  property color lineColor: "white"
  property color mirrorLineColor: lineColor
  property color fillColor: Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.14)
  property color mirrorFillColor: Qt.rgba(mirrorLineColor.r, mirrorLineColor.g, mirrorLineColor.b, 0.14)
  property color gridColor: Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.10)
  property var gridLevels: []
  property bool dashed: false
  property real lineWidth: 1.5
  property real fixedMaximum: -1
  property int windowMs: 120000

  readonly property bool mirrored: mirrorPoints !== null && mirrorPoints !== undefined

  antialiasing: true
  onPointsChanged: requestPaint()
  onMirrorPointsChanged: requestPaint()
  onLineColorChanged: requestPaint()
  onMirrorLineColorChanged: requestPaint()
  onFixedMaximumChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  function newestTime(list) {
    return (list && list.length > 0) ? Number(list[list.length - 1].time) : 0
  }

  function peakValue(list) {
    var peak = 0
    if (!list) return peak
    for (var i = 0; i < list.length; i++) {
      var value = Number(list[i].value)
      if (isFinite(value) && value > peak) peak = value
    }
    return peak
  }

  function drawGrid(ctx, axis, span) {
    ctx.strokeStyle = gridColor
    ctx.lineWidth = 1
    if (mirrored) {
      var center = Math.round(axis) + 0.5
      ctx.beginPath()
      ctx.moveTo(0, center)
      ctx.lineTo(width, center)
      ctx.stroke()
      return
    }
    for (var i = 0; i < gridLevels.length; i++) {
      var level = Math.max(0, Math.min(1, Number(gridLevels[i])))
      var y = Math.round(axis - level * span) + 0.5
      ctx.beginPath()
      ctx.moveTo(0, y)
      ctx.lineTo(width, y)
      ctx.stroke()
    }
  }

  // `direction` is -1 for series that grow upward from the axis, +1 for the
  // mirrored half that grows downward.
  function drawSeries(ctx, list, oldest, maximum, axis, span, direction, stroke, fill, dash) {
    if (!list || list.length < 2) return

    function pointX(point) {
      return Math.max(0, Math.min(width, (Number(point.time) - oldest) * width / windowMs))
    }
    function pointY(point) {
      var value = Number(point.value)
      if (!isFinite(value) || value < 0) value = 0
      return axis + direction * Math.min(1, value / maximum) * span
    }

    ctx.beginPath()
    ctx.moveTo(pointX(list[0]), axis)
    for (var fillIndex = 0; fillIndex < list.length; fillIndex++)
      ctx.lineTo(pointX(list[fillIndex]), pointY(list[fillIndex]))
    ctx.lineTo(pointX(list[list.length - 1]), axis)
    ctx.closePath()
    ctx.fillStyle = fill
    ctx.fill()

    if (ctx.setLineDash) ctx.setLineDash(dash ? [3, 3] : [])
    ctx.beginPath()
    ctx.moveTo(pointX(list[0]), pointY(list[0]))
    for (var lineIndex = 1; lineIndex < list.length; lineIndex++)
      ctx.lineTo(pointX(list[lineIndex]), pointY(list[lineIndex]))
    ctx.strokeStyle = stroke
    ctx.lineWidth = lineWidth
    ctx.stroke()
    if (ctx.setLineDash) ctx.setLineDash([])
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.clearRect(0, 0, width, height)
    if (width <= 0 || height <= 0) return

    var newest = Math.max(newestTime(points), mirrored ? newestTime(mirrorPoints) : 0)
    if (newest <= 0) return
    var oldest = newest - windowMs

    var maximum = fixedMaximum
    if (!(maximum > 0)) {
      maximum = Math.max(peakValue(points), mirrored ? peakValue(mirrorPoints) : 0) * 1.12
      if (!(maximum > 0)) maximum = 1
    }

    var axis = mirrored ? height / 2 : height - 1
    var span = mirrored ? (height / 2 - 1) : (height - 2)

    drawGrid(ctx, axis, span)
    if (mirrored)
      drawSeries(ctx, mirrorPoints, oldest, maximum, axis, span, 1, mirrorLineColor, mirrorFillColor, false)
    drawSeries(ctx, points, oldest, maximum, axis, span, -1, lineColor, fillColor, dashed)
  }
}
