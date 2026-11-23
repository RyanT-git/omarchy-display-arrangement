// Run: node tests/layout.test.js
const assert = require("assert")
const L = require("../Layout.js")

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    console.error("FAIL " + name)
    throw e
  }
}

function mon(name, x, y, scale, extra) {
  return Object.assign({
    name, description: "", width: 1920, height: 1080, refreshRate: 60,
    x, y, scale, transform: 0, enabled: true, focused: false, mirrored: false
  }, extra || {})
}

const pos = (ms, n) => { const m = ms.find(x => x.name === n); return [m.x, m.y, m.scale] }

test("parse drops unsafe names and bad sizes", () => {
  const raw = JSON.stringify([
    { name: "DP-1", width: 1920, height: 1080, x: 0, y: 0, scale: 1.25, transform: 0, refreshRate: 60 },
    { name: 'DP-2"}) os.execute("x', width: 1920, height: 1080 },
    { name: "HDMI-A-1", width: 0, height: 1080 },
    { name: "DP-3", width: 2560, height: 1440, disabled: true, description: "<img src=x>\nfoo" }
  ])
  const ms = L.parseMonitors(raw)
  assert.deepStrictEqual(ms.map(m => m.name), ["DP-1", "DP-3"])
  assert.strictEqual(ms[1].enabled, false)
  assert.ok(!ms[1].description.includes("\n"))
  assert.deepStrictEqual(L.parseMonitors("not json"), [])
  assert.deepStrictEqual(L.parseMonitors('{"a":1}'), [])
})

test("logical size follows scale and rotation", () => {
  assert.deepStrictEqual(L.logicalSize(mon("A", 0, 0, 1.25)), { w: 1536, h: 864 })
  assert.deepStrictEqual(L.logicalSize(mon("A", 0, 0, 1, { transform: 1 })), { w: 1080, h: 1920 })
})

test("today's bug: 1.25 left monitor leaves a 384px gap", () => {
  const ms = [mon("DP-1", 0, 0, 1.25), mon("DP-2", 1920, 0, 1)]
  const a = L.analyze(ms)
  assert.strictEqual(a.ok, false)
  assert.deepStrictEqual(a.isolated, ["DP-2"])
  assert.strictEqual(a.gaps[0].distance, 384)
})

test("a flush side-by-side layout is fine", () => {
  assert.strictEqual(L.analyze([mon("DP-1", 0, 0, 1), mon("DP-2", 1920, 0, 1)]).ok, true)
  assert.strictEqual(L.analyze([mon("DP-1", 0, 0, 1.25), mon("DP-2", 1536, 0, 1)]).ok, true)
})

test("corner-only contact is not connected; overlap is flagged", () => {
  assert.strictEqual(L.analyze([mon("A", 0, 0, 1), mon("B", 1920, 1080, 1)]).ok, false)
  const o = L.analyze([mon("A", 0, 0, 1), mon("B", 1000, 0, 1)])
  assert.deepStrictEqual(o.overlapping, [["A", "B"]])
})

test("closeGaps keeps the anchor and pulls the other flush", () => {
  const ms = L.closeGaps([mon("DP-1", 0, 0, 1.25), mon("DP-2", 1920, 0, 1)], "DP-1", { minShare: 64 })
  assert.deepStrictEqual(pos(ms, "DP-1"), [0, 0, 1.25])
  assert.deepStrictEqual(pos(ms, "DP-2"), [1536, 0, 1])
  assert.strictEqual(L.analyze(ms).ok, true)
})

test("closeGaps with the right monitor as anchor normalizes to 0,0", () => {
  const ms = L.closeGaps([mon("DP-1", 0, 0, 1.25), mon("DP-2", 1920, 0, 1)], "DP-2", { minShare: 64 })
  assert.strictEqual(L.analyze(ms).ok, true)
  assert.deepStrictEqual(pos(ms, "DP-1"), [0, 0, 1.25])
  assert.deepStrictEqual(pos(ms, "DP-2"), [1536, 0, 1])
})

test("closeGaps separates overlapping monitors", () => {
  const ms = L.closeGaps([mon("A", 0, 0, 1), mon("B", 1700, 100, 1)], "A", { minShare: 64 })
  assert.strictEqual(L.analyze(ms).ok, true)
  assert.deepStrictEqual(pos(ms, "B"), [1920, 100, 1])
})

test("three monitors in a row all join up", () => {
  const ms = L.closeGaps([mon("A", 0, 0, 1), mon("B", 2500, 0, 1), mon("C", 5000, 0, 1.6)], "A", { minShare: 64 })
  assert.strictEqual(L.analyze(ms).ok, true)
  assert.deepStrictEqual(pos(ms, "B"), [1920, 0, 1])
  assert.deepStrictEqual(pos(ms, "C"), [3840, 0, 1.6])
})

test("drop above snaps to stacked with alignment", () => {
  const dropped = L.settle([mon("A", 0, 0, 1), mon("B", 40, -1300, 1)], "B", { minShare: 64, alignThreshold: 100 })
  assert.strictEqual(L.analyze(dropped).ok, true)
  // B sits on top of A, left edges aligned; normalized so B is at y 0.
  assert.deepStrictEqual(pos(dropped, "B"), [0, 0, 1])
  assert.deepStrictEqual(pos(dropped, "A"), [0, 1080, 1])
})

test("settle keeps a mostly-off-edge drop sharing at least minShare", () => {
  const ms = L.settle([mon("A", 0, 0, 1), mon("B", 1950, 1060, 1)], "B", { minShare: 64, alignThreshold: 0 })
  assert.strictEqual(L.analyze(ms).ok, true)
  const b = ms.find(m => m.name === "B")
  assert.strictEqual(b.x, 1920)
  assert.ok(b.y <= 1080 - 64)
})

test("resizing from a corner snaps to clean scales and pins the opposite corner", () => {
  const m = mon("A", 0, 0, 1)
  const shrink = L.resizeFromCorner(m, "br", -384, -216)
  assert.strictEqual(shrink.scale, 1.25)
  assert.deepStrictEqual([shrink.x, shrink.y], [0, 0])
  const fromTopLeft = L.resizeFromCorner(m, "tl", 384, 216)
  assert.strictEqual(fromTopLeft.scale, 1.25)
  assert.deepStrictEqual([fromTopLeft.x, fromTopLeft.y], [384, 216])
  const grow = L.resizeFromCorner(mon("A", 0, 0, 2), "br", 2000, 0)
  assert.strictEqual(grow.scale, 1)
  assert.strictEqual(L.resizeFromCorner(m, "br", 5000, 5000).scale, 1)
  assert.strictEqual(L.resizeFromCorner(m, "br", -1900, -1000).scale, 4)
})

test("scale options are all clean for the mode", () => {
  const opts = L.scaleOptions(mon("A", 0, 0, 1))
  // 1.75 isn't clean on 1080p, so it rounds up to 1.875 (1024x576 logical).
  assert.deepStrictEqual(opts, [1, 1.25, 1.5, 1.6, 1.875, 2, 2.5, 3, 4])
  opts.forEach(s => assert.strictEqual(L.cleanScale(s, 1920, 1080), s))
  assert.strictEqual(L.stepScale(mon("A", 0, 0, 1.25), 1), 1.5)
  assert.strictEqual(L.stepScale(mon("A", 0, 0, 1), -1), 1)
})

test("hyprEval and persistArgs only emit validated values", () => {
  const ms = [mon("DP-1", 0, 0, 1.25), mon("DP-2", 1536, 0, 1), mon("DP-3", 0, 0, 1, { enabled: false })]
  assert.strictEqual(L.hyprEval(ms),
    'hl.monitor({ output = "DP-1", mode = "1920x1080@60", position = "0x0", scale = 1.25, transform = 0 }) ' +
    'hl.monitor({ output = "DP-2", mode = "1920x1080@60", position = "1536x0", scale = 1, transform = 0 })')
  assert.deepStrictEqual(L.persistArgs(ms), ["DP-1=0,0,1.25", "DP-2=1536,0,1"])
  const bad = [mon('X"); os.exit(', 0, 0, 1)]
  assert.strictEqual(L.hyprEval(bad), "")
})

test("sameLayout ignores unrelated fields", () => {
  const a = [mon("A", 0, 0, 1)]
  assert.ok(L.sameLayout(a, [mon("A", 0, 0, 1, { focused: true })]))
  assert.ok(!L.sameLayout(a, [mon("A", 1, 0, 1)]))
})

console.log(passed + " layout tests passed")
