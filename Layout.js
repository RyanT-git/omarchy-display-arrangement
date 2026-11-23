// Display arrangement geometry, kept free of QML so it can be tested in Node.
//
// Hyprland places monitors in *logical* pixels: a 1920x1080 panel at scale
// 1.25 only covers 1536x864 of layout space. A neighbour positioned for the
// old scale then sits apart from it, and the pointer cannot cross that gap.
// Everything here works in logical pixels for that reason.

var MAX_MONITORS = 16
var NAME_RE = /^[A-Za-z0-9._-]{1,64}$/
var SCALE_CANDIDATES = [1, 1.25, 1.5, 1.6, 1.75, 2, 2.5, 3, 4]

function num(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

function plainString(value, maxLength) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .slice(0, maxLength)
}

function gcd(a, b) {
  while (b) {
    var r = a % b
    a = b
    b = r
  }
  return a
}

// Same rule as omarchy-hyprland-monitor-scaling: Hyprland only accepts scales
// that divide the mode into whole logical pixels (in 1/120 steps), so round a
// requested scale up to the next clean one.
function cleanScale(scale, width, height) {
  var requested = num(scale, NaN)
  var w = num(width, 0)
  var h = num(height, 0)
  if (!(requested > 0) || !(w > 0) || !(h > 0)) return NaN
  var divisor = gcd(Math.round(w * 120), Math.round(h * 120))
  var units = Math.round(requested * 120)
  if (units > divisor) units = divisor
  while (divisor % units !== 0) units++
  return Math.round((units / 120) * 10000) / 10000
}

function scaleOptions(mon) {
  var seen = {}
  var out = []
  for (var i = 0; i < SCALE_CANDIDATES.length; i++) {
    var s = cleanScale(SCALE_CANDIDATES[i], mon.width, mon.height)
    if (!isFinite(s) || seen[s]) continue
    seen[s] = true
    out.push(s)
  }
  out.sort(function(a, b) { return a - b })
  return out
}

function nearestScale(options, desired) {
  if (!options.length) return 1
  var best = options[0]
  var bestDist = Infinity
  for (var i = 0; i < options.length; i++) {
    // Compare in log space so 1 -> 1.25 and 2 -> 2.5 feel like equal steps.
    var d = Math.abs(Math.log(options[i]) - Math.log(desired))
    if (d < bestDist) { bestDist = d; best = options[i] }
  }
  return best
}

function stepScale(mon, direction) {
  var options = scaleOptions(mon)
  var idx = 0
  var bestDist = Infinity
  for (var i = 0; i < options.length; i++) {
    var d = Math.abs(options[i] - mon.scale)
    if (d < bestDist) { bestDist = d; idx = i }
  }
  idx = Math.max(0, Math.min(options.length - 1, idx + (direction > 0 ? 1 : -1)))
  return options[idx]
}

// Parse `hyprctl monitors all -j`. Names end up inside a Lua string passed to
// `hyprctl eval`, so anything but a plain connector name is dropped.
function parseMonitors(raw) {
  var list
  try {
    list = typeof raw === "string" ? JSON.parse(raw) : raw
  } catch (e) {
    return []
  }
  if (!Array.isArray(list)) return []

  var out = []
  for (var i = 0; i < list.length && out.length < MAX_MONITORS; i++) {
    var m = list[i]
    if (!m || typeof m !== "object") continue
    var name = String(m.name || "")
    if (!NAME_RE.test(name)) continue
    var width = Math.round(num(m.width, 0))
    var height = Math.round(num(m.height, 0))
    if (width <= 0 || height <= 0 || width > 32768 || height > 32768) continue
    var scale = num(m.scale, 1)
    if (!(scale > 0) || scale > 10) scale = 1
    var transform = Math.round(num(m.transform, 0))
    if (transform < 0 || transform > 7) transform = 0
    out.push({
      name: name,
      description: plainString(m.description || m.model || "", 120),
      width: width,
      height: height,
      refreshRate: Math.max(1, Math.min(1000, num(m.refreshRate, 60))),
      x: Math.round(num(m.x, 0)),
      y: Math.round(num(m.y, 0)),
      scale: Math.round(scale * 10000) / 10000,
      transform: transform,
      enabled: m.disabled !== true,
      focused: m.focused === true,
      mirrored: !!m.mirrorOf && m.mirrorOf !== "none"
    })
  }
  return out
}

function logicalSize(mon, scale) {
  var s = scale === undefined ? mon.scale : scale
  var w = Math.round(mon.width / s)
  var h = Math.round(mon.height / s)
  if (mon.transform % 2 === 1) return { w: h, h: w }
  return { w: w, h: h }
}

// Monitors that take part in the layout (disabled and mirrored ones don't).
function placed(monitors) {
  return monitors.filter(function(m) { return m.enabled && !m.mirrored })
}

function rectOf(mon) {
  var size = logicalSize(mon)
  return { name: mon.name, x: mon.x, y: mon.y, w: size.w, h: size.h }
}

function rangeOverlap(a0, alen, b0, blen) {
  return Math.min(a0 + alen, b0 + blen) - Math.max(a0, b0)
}

function overlaps(a, b) {
  return rangeOverlap(a.x, a.w, b.x, b.w) > 0 && rangeOverlap(a.y, a.h, b.y, b.h) > 0
}

// Two monitors are joined when they share a stretch of edge the pointer can
// cross. Touching only at a corner doesn't count.
function touches(a, b) {
  var sideBySide = (a.x + a.w === b.x || b.x + b.w === a.x) && rangeOverlap(a.y, a.h, b.y, b.h) > 0
  var stacked = (a.y + a.h === b.y || b.y + b.h === a.y) && rangeOverlap(a.x, a.w, b.x, b.w) > 0
  return sideBySide || stacked
}

function rectGap(a, b) {
  var dx = Math.max(0, Math.max(a.x, b.x) - Math.min(a.x + a.w, b.x + b.w))
  var dy = Math.max(0, Math.max(a.y, b.y) - Math.min(a.y + a.h, b.y + b.h))
  return Math.sqrt(dx * dx + dy * dy)
}

// Report what would trap the pointer: monitors cut off from the rest, and
// monitors stacked on top of each other.
function analyze(monitors) {
  var rects = placed(monitors).map(rectOf)
  var result = { isolated: [], overlapping: [], gaps: [], ok: true }
  if (rects.length < 2) return result

  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      if (overlaps(rects[i], rects[j])) result.overlapping.push([rects[i].name, rects[j].name])
    }
  }

  var seen = {}
  seen[rects[0].name] = true
  var queue = [rects[0]]
  while (queue.length) {
    var cur = queue.shift()
    for (var k = 0; k < rects.length; k++) {
      if (!seen[rects[k].name] && touches(cur, rects[k])) {
        seen[rects[k].name] = true
        queue.push(rects[k])
      }
    }
  }
  for (var n = 0; n < rects.length; n++) {
    if (!seen[rects[n].name]) result.isolated.push(rects[n].name)
  }

  // Size of each disconnected monitor's gap to its nearest neighbour, for the
  // status line.
  for (var g = 0; g < result.isolated.length; g++) {
    var r = rects.filter(function(x) { return x.name === result.isolated[g] })[0]
    var best = Infinity
    var bestName = ""
    for (var o = 0; o < rects.length; o++) {
      if (rects[o].name === r.name) continue
      var d = rectGap(r, rects[o])
      if (d < best) { best = d; bestName = rects[o].name }
    }
    result.gaps.push({ name: r.name, neighbour: bestName, distance: Math.round(best) })
  }

  result.ok = result.isolated.length === 0 && result.overlapping.length === 0
  return result
}

function clamp(v, lo, hi) {
  if (lo > hi) return lo
  return Math.max(lo, Math.min(hi, v))
}

// Every spot where `r` sits flush against a side of `o` while sharing at least
// `minShare` of that edge, nearest to where `r` is now. Edges within
// `alignThreshold` of lining up with `o`'s are pulled into line.
function attachCandidates(r, o, minShare, alignThreshold) {
  var out = []
  var shareY = Math.min(minShare, r.h, o.h)
  var shareX = Math.min(minShare, r.w, o.w)

  function alignY(y) {
    if (Math.abs(y - o.y) <= alignThreshold) return o.y
    if (Math.abs(y + r.h - (o.y + o.h)) <= alignThreshold) return o.y + o.h - r.h
    if (Math.abs(y + r.h / 2 - (o.y + o.h / 2)) <= alignThreshold) return Math.round(o.y + o.h / 2 - r.h / 2)
    return y
  }
  function alignX(x) {
    if (Math.abs(x - o.x) <= alignThreshold) return o.x
    if (Math.abs(x + r.w - (o.x + o.w)) <= alignThreshold) return o.x + o.w - r.w
    if (Math.abs(x + r.w / 2 - (o.x + o.w / 2)) <= alignThreshold) return Math.round(o.x + o.w / 2 - r.w / 2)
    return x
  }

  var y = alignY(clamp(r.y, o.y - r.h + shareY, o.y + o.h - shareY))
  out.push({ x: o.x + o.w, y: y })   // right of o
  out.push({ x: o.x - r.w, y: y })   // left of o
  var x = alignX(clamp(r.x, o.x - r.w + shareX, o.x + o.w - shareX))
  out.push({ x: x, y: o.y + o.h })   // below o
  out.push({ x: x, y: o.y - r.h })   // above o
  return out
}

// Move `r` to the nearest spot where it joins at least one of `others`
// without covering any of them, the way Windows snaps a dropped display.
function snapRect(r, others, options) {
  var opts = options || {}
  var minShare = num(opts.minShare, 64)
  var alignThreshold = num(opts.alignThreshold, 0)
  if (!others.length) return { x: r.x, y: r.y }

  var best = null
  var bestDist = Infinity
  for (var i = 0; i < others.length; i++) {
    var cands = attachCandidates(r, others[i], minShare, alignThreshold)
    for (var c = 0; c < cands.length; c++) {
      var moved = { name: r.name, x: Math.round(cands[c].x), y: Math.round(cands[c].y), w: r.w, h: r.h }
      var blocked = false
      for (var k = 0; k < others.length; k++) {
        if (overlaps(moved, others[k])) { blocked = true; break }
      }
      if (blocked) continue
      var dx = moved.x - r.x
      var dy = moved.y - r.y
      var dist = dx * dx + dy * dy
      if (dist < bestDist) { bestDist = dist; best = moved }
    }
  }
  if (!best) return { x: r.x, y: r.y }
  return { x: best.x, y: best.y }
}

function withPositions(monitors, positions) {
  return monitors.map(function(m) {
    var p = positions[m.name]
    if (!p) return m
    var copy = {}
    for (var k in m) copy[k] = m[k]
    copy.x = p.x
    copy.y = p.y
    return copy
  })
}

// Shift the whole layout so its top-left corner sits at 0,0. Purely cosmetic
// for Hyprland, but it keeps monitors.lua readable.
function normalize(monitors) {
  var rects = placed(monitors).map(rectOf)
  if (!rects.length) return monitors
  var minX = Math.min.apply(null, rects.map(function(r) { return r.x }))
  var minY = Math.min.apply(null, rects.map(function(r) { return r.y }))
  if (minX === 0 && minY === 0) return monitors
  var positions = {}
  rects.forEach(function(r) { positions[r.name] = { x: r.x - minX, y: r.y - minY } })
  return withPositions(monitors, positions)
}

// Snap one monitor against the rest, then normalize.
function settle(monitors, name, options) {
  var rects = placed(monitors).map(rectOf)
  var r = rects.filter(function(x) { return x.name === name })[0]
  if (!r) return monitors
  var others = rects.filter(function(x) { return x.name !== name })
  var p = snapRect(r, others, options)
  var positions = {}
  positions[name] = p
  return normalize(withPositions(monitors, positions))
}

// Pull every monitor into one connected, non-overlapping layout. The anchor
// (the focused monitor by default) stays put; the rest are attached one at a
// time, nearest first, each at the closest free spot to where it was.
function closeGaps(monitors, anchorName, options) {
  var rects = placed(monitors).map(rectOf)
  if (rects.length < 2) return normalize(monitors)

  var anchor = rects.filter(function(r) { return r.name === anchorName })[0] || rects[0]
  var done = [anchor]
  var todo = rects.filter(function(r) { return r !== anchor })
  var positions = {}

  while (todo.length) {
    var pick = 0
    var pickDist = Infinity
    for (var i = 0; i < todo.length; i++) {
      for (var j = 0; j < done.length; j++) {
        var d = rectGap(todo[i], done[j])
        if (d < pickDist) { pickDist = d; pick = i }
      }
    }
    var r = todo.splice(pick, 1)[0]
    var p = snapRect(r, done, options)
    var moved = { name: r.name, x: p.x, y: p.y, w: r.w, h: r.h }
    positions[r.name] = p
    done.push(moved)
  }
  return normalize(withPositions(monitors, positions))
}

// Resize from a dragged corner. The opposite corner stays put; the new scale
// is whichever clean scale best matches the dragged size.
function resizeFromCorner(mon, corner, dxLogical, dyLogical) {
  var start = logicalSize(mon)
  var right = corner === "tr" || corner === "br"
  var bottom = corner === "bl" || corner === "br"
  var wantW = start.w + (right ? dxLogical : -dxLogical)
  var wantH = start.h + (bottom ? dyLogical : -dyLogical)
  // Aspect is fixed, so take whichever axis moved further.
  var ratioW = wantW / start.w
  var ratioH = wantH / start.h
  var ratio = Math.abs(ratioW - 1) >= Math.abs(ratioH - 1) ? ratioW : ratioH
  ratio = Math.max(0.1, ratio)
  var newScale = nearestScale(scaleOptions(mon), mon.scale / ratio)
  var size = logicalSize(mon, newScale)
  return {
    scale: newScale,
    x: right ? mon.x : mon.x + start.w - size.w,
    y: bottom ? mon.y : mon.y + start.h - size.h
  }
}

function withMonitor(monitors, name, patch) {
  return monitors.map(function(m) {
    if (m.name !== name) return m
    var copy = {}
    for (var k in m) copy[k] = m[k]
    for (var p in patch) copy[p] = patch[p]
    return copy
  })
}

function sameLayout(a, b) {
  if (a.length !== b.length) return false
  var byName = {}
  b.forEach(function(m) { byName[m.name] = m })
  for (var i = 0; i < a.length; i++) {
    var o = byName[a[i].name]
    if (!o) return false
    if (o.x !== a[i].x || o.y !== a[i].y || Math.abs(o.scale - a[i].scale) > 0.0001) return false
  }
  return true
}

function formatScale(s) {
  return String(Math.round(s * 10000) / 10000)
}

// Lua for `hyprctl eval`. Names were checked against NAME_RE when parsed and
// every other value is a number, so nothing user-controlled is spliced in raw.
function hyprEval(monitors) {
  return placed(monitors).filter(function(m) { return NAME_RE.test(m.name) }).map(function(m) {
    return 'hl.monitor({ output = "' + m.name + '", mode = "' + m.width + "x" + m.height + "@" +
      (Math.round(m.refreshRate * 1000) / 1000) + '", position = "' + Math.round(m.x) + "x" + Math.round(m.y) +
      '", scale = ' + formatScale(m.scale) + ", transform = " + m.transform + " })"
  }).join(" ")
}

// argv for persist-layout.py: NAME=x,y,scale per placed monitor.
function persistArgs(monitors) {
  return placed(monitors).filter(function(m) { return NAME_RE.test(m.name) }).map(function(m) {
    return m.name + "=" + Math.round(m.x) + "," + Math.round(m.y) + "," + formatScale(m.scale)
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    cleanScale: cleanScale,
    scaleOptions: scaleOptions,
    stepScale: stepScale,
    parseMonitors: parseMonitors,
    logicalSize: logicalSize,
    placed: placed,
    rectOf: rectOf,
    touches: touches,
    overlaps: overlaps,
    analyze: analyze,
    snapRect: snapRect,
    settle: settle,
    closeGaps: closeGaps,
    normalize: normalize,
    resizeFromCorner: resizeFromCorner,
    withMonitor: withMonitor,
    sameLayout: sameLayout,
    hyprEval: hyprEval,
    persistArgs: persistArgs
  }
}
