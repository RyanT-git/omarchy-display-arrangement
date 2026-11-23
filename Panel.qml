import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model
import "Layout.js" as Layout

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // ---- Arrangement editor ----
  // liveMonitors is what Hyprland reports; draftMonitors is what the
  // arrangement canvas shows and edits. The draft follows the live layout
  // until the first edit, then holds until Apply or Reset.
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  function tr(key, english) { return strings.t(key, english) }

  property var liveMonitors: []
  property var draftMonitors: []
  // Delegate keys for the canvas. Only reassigned when the set of outputs
  // changes, so a drag doesn't rebuild the box under the pointer.
  property var arrangeNames: []
  property string arrangeSelected: ""
  property bool arrangeDragging: false
  property var arrangeFrozenView: null
  // Layout to go back to if an applied one isn't confirmed in time.
  property var arrangePrevious: []
  property bool arrangeConfirming: false
  property int arrangeCountdown: 0
  readonly property int arrangeConfirmSeconds: 15
  property string arrangeMessage: ""
  property bool arrangeMessageIsError: false
  readonly property var arrangeAnalysis: Layout.analyze(draftMonitors)
  readonly property bool arrangeDirty: !Layout.sameLayout(draftMonitors, liveMonitors)
  readonly property string persistScript: decodeURIComponent(
    String(Qt.resolvedUrl("persist-layout.py")).replace(/^file:\/\//, ""))

  function snapOptions(view) {
    // Align edges that land within ~10 on-screen px of each other.
    return { minShare: 64, alignThreshold: view && view.k > 0 ? Style.space(10) / view.k : 0 }
  }

  // Identify: a big label on every physical screen for a few seconds.
  property bool identifying: false
  readonly property int identifySeconds: 4

  function identifyDisplays() {
    root.refresh()
    root.identifying = true
    identifyTimer.restart()
  }

  // Stable 1-based number per output, by connector name (DP-1 before DP-2),
  // so it doesn't change when the displays are rearranged.
  function arrangeNumber(name) {
    var names = root.liveMonitors.map(function(m) { return m.name })
    names.sort(function(a, b) { return a.localeCompare(b, undefined, { numeric: true }) })
    return names.indexOf(name) + 1
  }

  function liveMonitor(name) {
    for (var i = 0; i < liveMonitors.length; i++)
      if (liveMonitors[i].name === name) return liveMonitors[i]
    return null
  }

  function arrangeMonitor(name) {
    for (var i = 0; i < draftMonitors.length; i++)
      if (draftMonitors[i].name === name) return draftMonitors[i]
    return null
  }

  function updateLiveMonitors(raw) {
    var parsed = Layout.parseMonitors(raw)
    var names = Layout.placed(parsed).map(function(m) { return m.name })
    var namesChanged = names.join("\n") !== root.arrangeNames.join("\n")
    var wasDirty = root.arrangeDirty
    root.liveMonitors = parsed
    if (!wasDirty || namesChanged || root.draftMonitors.length === 0) root.draftMonitors = parsed
    if (namesChanged) root.arrangeNames = names
    if (names.indexOf(root.arrangeSelected) < 0) {
      var focused = parsed.filter(function(m) { return m.focused })[0]
      root.arrangeSelected = focused ? focused.name : (names[0] || "")
    }
  }

  function setArrangeMessage(text, isError) {
    root.arrangeMessage = text
    root.arrangeMessageIsError = !!isError
    if (text) arrangeMessageClear.restart()
  }

  function closeArrangeGaps() {
    var anchor = root.arrangeSelected || (root.liveMonitors.filter(function(m) { return m.focused })[0] || {}).name
    root.draftMonitors = Layout.closeGaps(root.draftMonitors, anchor, snapOptions(null))
  }

  function stepArrangeScale(direction) {
    var m = arrangeMonitor(root.arrangeSelected)
    if (!m) return
    var s = Layout.stepScale(m, direction)
    if (s === m.scale) return
    // Keep the top-left corner where it is, then re-attach to the neighbours.
    var next = Layout.withMonitor(root.draftMonitors, m.name, { scale: s })
    root.draftMonitors = Layout.settle(next, m.name, snapOptions(null))
  }

  function applyArrangement() {
    if (!root.arrangeDirty || !root.arrangeAnalysis.ok || arrangeApplyProc.running) return
    var expr = Layout.hyprEval(root.draftMonitors)
    if (!expr) return
    root.arrangePrevious = root.liveMonitors
    root.setArrangeMessage("", false)
    arrangeApplyProc.reverting = false
    arrangeApplyProc.command = ["hyprctl", "eval", expr]
    arrangeApplyProc.running = true
  }

  function keepArrangement() {
    if (!root.arrangeConfirming) return
    arrangeConfirmTimer.stop()
    root.arrangeConfirming = false
    arrangePersistProc.command = ["python3", "-I", root.persistScript].concat(Layout.persistArgs(root.liveMonitors))
    arrangePersistProc.running = true
  }

  function revertArrangement() {
    arrangeConfirmTimer.stop()
    root.arrangeConfirming = false
    var expr = Layout.hyprEval(root.arrangePrevious)
    if (!expr) return
    root.draftMonitors = root.arrangePrevious
    arrangeApplyProc.reverting = true
    arrangeApplyProc.command = ["hyprctl", "eval", expr]
    arrangeApplyProc.running = true
  }

  // Fit the draft layout into the canvas, with room around it to drag into.
  function arrangeView(monitors, width, height, pad) {
    var rects = Layout.placed(monitors).map(Layout.rectOf)
    if (!rects.length || width <= 0 || height <= 0) return { k: 0, minX: 0, minY: 0, ox: 0, oy: 0 }
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    rects.forEach(function(r) {
      minX = Math.min(minX, r.x); minY = Math.min(minY, r.y)
      maxX = Math.max(maxX, r.x + r.w); maxY = Math.max(maxY, r.y + r.h)
    })
    var bw = maxX - minX
    var bh = maxY - minY
    var margin = Math.max(bw, bh) * 0.12
    minX -= margin; minY -= margin; bw += margin * 2; bh += margin * 2
    var k = Math.min((width - pad * 2) / bw, (height - pad * 2) / bh)
    return {
      k: k,
      minX: minX,
      minY: minY,
      ox: (width - bw * k) / 2,
      oy: (height - bh * k) / 2
    }
  }

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || section === "scale"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays,
      arrangement: {
        outputs: root.arrangeNames,
        layout: Layout.persistArgs(root.draftMonitors),
        dirty: root.arrangeDirty,
        ok: root.arrangeAnalysis.ok,
        confirming: root.arrangeConfirming,
        identifying: root.identifying
      }
    })
  }

  ShellIpc {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function identify(): string { root.identifyDisplays(); return "ok" }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!layoutProc.running) layoutProc.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent, Commons.I18n.t)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    // hyprctl keyword is rejected under the Lua config ("non-legacy parsers"),
    // so drive the monitor through the hl.monitor eval API instead.
    var output = '"' + name.replace(/[\\"]/g, "\\$&") + '"'
    // hl.monitor updates the existing rule. Keep its mode, position and scale
    // when bringing the display back.
    var expr = enabled
      ? 'hl.monitor({ output = ' + output + ', disabled = true })'
      : 'hl.monitor({ output = ' + output + ', disabled = false })'
    actionProc.command = ["hyprctl", "eval", expr]
    if (!actionProc.running) actionProc.running = true
  }

  function setScale(scale) {
    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Process {
    id: layoutProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateLiveMonitors(String(text || ""))
    }
  }

  Process {
    id: arrangeApplyProc
    property bool reverting: false
    stdout: StdioCollector { id: arrangeApplyOut; waitForEnd: true }
    stderr: StdioCollector { id: arrangeApplyErr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(arrangeApplyOut.text || "").trim()
      var ok = exitCode === 0 && out === "ok"
      if (reverting) {
        root.setArrangeMessage(ok ? root.tr("arrange.reverted", "Reverted to the previous layout.")
          : root.tr("arrange.applyFailed", "Hyprland rejected the layout: %1")
              .arg((out + " " + String(arrangeApplyErr.text || "")).trim().slice(0, 200)), !ok)
      } else if (ok) {
        root.arrangeCountdown = root.arrangeConfirmSeconds
        root.arrangeConfirming = true
        arrangeConfirmTimer.restart()
      } else {
        root.setArrangeMessage(root.tr("arrange.applyFailed", "Hyprland rejected the layout: %1")
          .arg((out + " " + String(arrangeApplyErr.text || "")).trim().slice(0, 200)), true)
      }
      root.refresh()
    }
  }

  // Like Windows: an applied layout reverts on its own unless confirmed, so a
  // layout that strands the pointer can't stick.
  Timer {
    id: arrangeConfirmTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.arrangeCountdown = root.arrangeCountdown - 1
      if (root.arrangeCountdown <= 0) root.revertArrangement()
    }
  }

  Process {
    id: arrangePersistProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: arrangePersistErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.setArrangeMessage(root.tr("arrange.saved", "Saved to monitors.lua."), false)
      else root.setArrangeMessage(root.tr("arrange.saveFailed", "Applied, but saving failed: %1")
        .arg(String(arrangePersistErr.text || ("exit " + exitCode)).trim().slice(0, 200)), true)
      root.refresh()
    }
  }

  Timer {
    id: arrangeMessageClear
    interval: 6000
    onTriggered: root.arrangeMessage = ""
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(780))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

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
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: Commons.I18n.t("monitor.display")
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return Commons.I18n.t("monitor.fixedBrightness")
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Arrangement ----------
          PanelSeparator {
            visible: root.arrangeNames.length > 1
            foreground: root.bar.foreground
          }

          Column {
            id: arrangeSection
            visible: root.arrangeNames.length > 1
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(arrangeHeader.implicitHeight, identifyButton.implicitHeight)

              PanelSectionHeader {
                id: arrangeHeader
                text: root.tr("arrange.title", "Arrangement")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              ArrangeButton {
                id: identifyButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.tr("arrange.identify", "Identify")
                active: root.identifying
                onClicked: root.identifyDisplays()
              }
            }

            Rectangle {
              id: arrangeCanvas
              width: parent.width
              height: Style.space(170)
              radius: Style.space(6)
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              border.width: 1
              border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
              clip: true

              readonly property real pad: Style.space(10)
              readonly property var liveView: root.arrangeView(root.draftMonitors, width, height, pad)
              // Hold the zoom still while dragging, or the box would slide
              // away from the pointer as the bounds change.
              readonly property var view: root.arrangeFrozenView || liveView

              // Clicking empty canvas clears nothing but keeps focus here.
              MouseArea { anchors.fill: parent }

              Repeater {
                model: root.arrangeNames

                MonitorBox {
                  required property string modelData
                  monitorName: modelData
                  view: arrangeCanvas.view
                  canvas: arrangeCanvas
                }
              }
            }

            // Selected display: name, mode, and fine scale control.
            Item {
              width: parent.width
              implicitHeight: Math.max(selInfo.implicitHeight, selScale.implicitHeight)
              readonly property var mon: root.arrangeMonitor(root.arrangeSelected)
              visible: !!mon

              Column {
                id: selInfo
                anchors.left: parent.left
                anchors.right: selScale.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: parent.parent.mon
                    ? parent.parent.mon.name + (parent.parent.mon.description ? " · " + parent.parent.mon.description : "")
                    : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: {
                    var m = parent.parent.mon
                    if (!m) return ""
                    var size = Layout.logicalSize(m)
                    return root.tr("arrange.details", "%1×%2 @ %3 Hz · %4×%5 logical")
                      .arg(m.width).arg(m.height).arg(Math.round(m.refreshRate))
                      .arg(size.w).arg(size.h)
                  }
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Row {
                id: selScale
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                enabled: !root.arrangeConfirming

                Button {
                  text: "−"
                  bordered: true
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.stepArrangeScale(-1)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: parent.parent.mon ? Commons.I18n.formatNumber(parent.parent.mon.scale) + "x" : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  width: Style.space(40)
                  horizontalAlignment: Text.AlignHCenter
                }

                Button {
                  text: "+"
                  bordered: true
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.stepArrangeScale(1)
                }
              }
            }

            // Status: confirm countdown, a problem, a result, or the hint.
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              readonly property var a: root.arrangeAnalysis
              readonly property bool problem: !root.arrangeConfirming && !a.ok
              text: {
                strings.strings // re-translate on language change
                if (root.arrangeConfirming)
                  return strings.tn("arrange.confirm", root.arrangeCountdown, "Keep this layout? Reverting in %1 seconds.")
                    .arg(Commons.I18n.formatNumber(root.arrangeCountdown))
                if (a.gaps.length)
                  return root.tr("arrange.gap", "%1 isn't touching another display (%2 px gap), so the pointer can't reach it.")
                    .arg(a.gaps[0].name).arg(Commons.I18n.formatNumber(a.gaps[0].distance))
                if (a.overlapping.length)
                  return root.tr("arrange.overlap", "%1 and %2 overlap.").arg(a.overlapping[0][0]).arg(a.overlapping[0][1])
                if (root.arrangeMessage) return root.arrangeMessage
                if (root.arrangeDirty) return root.tr("arrange.unsaved", "Changes not applied yet.")
                return root.tr("arrange.hint", "Drag a display to move it. Drag a corner to change its scale.")
              }
              color: problem || (root.arrangeMessage && root.arrangeMessageIsError)
                ? Commons.Color.urgent
                : (root.arrangeConfirming ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4))
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: root.arrangeConfirming || problem
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(6)
              visible: !root.arrangeConfirming

              ArrangeButton {
                text: root.tr("arrange.closeGaps", "Close gaps")
                enabled: !root.arrangeAnalysis.ok
                onClicked: root.closeArrangeGaps()
              }
              ArrangeButton {
                text: root.tr("arrange.reset", "Reset")
                enabled: root.arrangeDirty
                onClicked: root.draftMonitors = root.liveMonitors
              }
              ArrangeButton {
                text: root.tr("arrange.apply", "Apply")
                enabled: root.arrangeDirty && root.arrangeAnalysis.ok && !arrangeApplyProc.running
                active: enabled
                onClicked: root.applyArrangement()
              }
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(6)
              visible: root.arrangeConfirming

              ArrangeButton {
                text: root.tr("arrange.revert", "Revert")
                onClicked: root.revertArrangement()
              }
              ArrangeButton {
                text: root.tr("arrange.keep", "Keep")
                active: true
                onClicked: root.keepArrangement()
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: Commons.I18n.t("monitor.brightness")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                textFormat: Text.PlainText
                text: Commons.I18n.formatNumber(Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent)) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: Commons.I18n.t("monitor.textSize")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                textFormat: Text.PlainText
                text: Commons.I18n.formatNumber(textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: Commons.I18n.t("monitor.scale")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                textFormat: Text.PlainText
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: Commons.I18n.t("monitor.displays")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: Commons.I18n.formatNumber(root.effectiveScale(scaleValue)) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  Timer {
    id: identifyTimer
    interval: root.identifySeconds * 1000
    onTriggered: root.identifying = false
  }

  // One label per physical screen while identifying. Click-through (empty
  // input mask) and no keyboard focus, so it never gets in the way.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: idWindow
      required property var modelData
      readonly property var mon: root.liveMonitor(modelData.name)
      readonly property bool selected: root.arrangeSelected === modelData.name

      screen: modelData
      visible: root.identifying
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "display-arrangement-identify"
      mask: Region {}
      implicitWidth: idCard.width
      implicitHeight: idCard.height

      Rectangle {
        id: idCard
        width: Math.max(idColumn.implicitWidth, Style.space(220)) + Style.space(64)
        height: idColumn.implicitHeight + Style.space(48)
        radius: Style.cornerRadius
        color: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 0.94)
        border.width: Math.max(2, Style.space(idWindow.selected ? 4 : 2))
        border.color: idWindow.selected ? Commons.Color.accent : Commons.Color.popups.border

        Column {
          id: idColumn
          anchors.centerIn: parent
          spacing: Style.space(4)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: String(root.arrangeNumber(idWindow.modelData.name) || "")
            color: idWindow.selected ? Commons.Color.accent : Commons.Color.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge * 4
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: idWindow.modelData.name
            color: Commons.Color.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            visible: text !== ""
            text: idWindow.mon && idWindow.mon.description ? idWindow.mon.description : ""
            color: Qt.darker(Commons.Color.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: idWindow.mon
              ? idWindow.mon.width + "×" + idWindow.mon.height + " · " + Commons.I18n.formatNumber(idWindow.mon.scale) + "x"
              : ""
            color: Qt.darker(Commons.Color.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }
    }
  }

  component ArrangeButton: Button {
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    // Button has no disabled look of its own; disabling the item already
    // stops its MouseArea.
    opacity: enabled ? 1.0 : 0.4
  }

  // One display on the arrangement canvas. Drag the body to move it; drag a
  // corner to change its scale. On release it snaps flush to a neighbour.
  component MonitorBox: Item {
    id: box
    required property string monitorName
    property var view
    property Item canvas

    readonly property var mon: root.arrangeMonitor(monitorName)
    readonly property var rect: mon ? Layout.rectOf(mon) : ({ x: 0, y: 0, w: 0, h: 0 })
    readonly property bool selected: root.arrangeSelected === monitorName
    readonly property bool trouble: {
      var a = root.arrangeAnalysis
      if (a.isolated.indexOf(monitorName) >= 0) return true
      for (var i = 0; i < a.overlapping.length; i++)
        if (a.overlapping[i].indexOf(monitorName) >= 0) return true
      return false
    }
    readonly property color accent: Commons.Color.accent
    readonly property color fg: root.bar.foreground

    property bool busy: false
    property bool moved: false
    property var startMon: null
    property real startX: 0
    property real startY: 0

    visible: !!mon && view.k > 0
    x: view.ox + (rect.x - view.minX) * view.k
    y: view.oy + (rect.y - view.minY) * view.k
    width: rect.w * view.k
    height: rect.h * view.k
    z: busy ? 3 : (selected ? 2 : 1)

    Behavior on x { enabled: !root.arrangeDragging; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    Behavior on y { enabled: !root.arrangeDragging; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    Behavior on width { enabled: !root.arrangeDragging; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    Behavior on height { enabled: !root.arrangeDragging; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

    function begin(mouse, area) {
      root.arrangeSelected = monitorName
      if (root.arrangeConfirming) return
      root.arrangeFrozenView = box.view
      root.arrangeDragging = true
      box.busy = true
      box.moved = false
      box.startMon = box.mon
      var p = area.mapToItem(box.canvas, mouse.x, mouse.y)
      box.startX = p.x
      box.startY = p.y
    }

    function delta(mouse, area) {
      var p = area.mapToItem(box.canvas, mouse.x, mouse.y)
      var dx = p.x - box.startX
      var dy = p.y - box.startY
      if (Math.abs(dx) + Math.abs(dy) > 3) box.moved = true
      return { x: dx / box.view.k, y: dy / box.view.k }
    }

    function finish() {
      if (!box.busy) return
      var v = box.view
      box.busy = false
      if (box.moved)
        root.draftMonitors = Layout.settle(root.draftMonitors, monitorName, root.snapOptions(v))
      root.arrangeDragging = false
      root.arrangeFrozenView = null
    }

    HoverHandler { id: boxHover }

    Rectangle {
      anchors.fill: parent
      anchors.margins: 1
      radius: Style.space(4)
      color: box.selected
        ? Qt.rgba(box.accent.r, box.accent.g, box.accent.b, 0.28)
        : Qt.rgba(box.fg.r, box.fg.g, box.fg.b, 0.10)
      border.width: box.selected || box.trouble ? 2 : 1
      border.color: box.trouble
        ? Commons.Color.urgent
        : (box.selected ? box.accent : Qt.rgba(box.fg.r, box.fg.g, box.fg.b, 0.45))
    }

    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(8)
      spacing: 0

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: root.arrangeNumber(box.monitorName) + " · " + box.monitorName
        color: box.fg
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: box.mon ? Commons.I18n.formatNumber(box.mon.scale) + "x" : ""
        color: Qt.darker(box.fg, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: root.arrangeConfirming ? Qt.ArrowCursor : (box.busy ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
      onPressed: function(mouse) { box.begin(mouse, this) }
      onPositionChanged: function(mouse) {
        if (!pressed || !box.busy) return
        var d = box.delta(mouse, this)
        root.draftMonitors = Layout.withMonitor(root.draftMonitors, box.monitorName, {
          x: Math.round(box.startMon.x + d.x),
          y: Math.round(box.startMon.y + d.y)
        })
      }
      onReleased: box.finish()
      onCanceled: box.finish()
    }

    Repeater {
      model: ["tl", "tr", "bl", "br"]

      Rectangle {
        id: handle
        required property string modelData
        readonly property bool isLeft: modelData === "tl" || modelData === "bl"
        readonly property bool isTop: modelData === "tl" || modelData === "tr"
        width: Style.space(10)
        height: width
        radius: Style.space(2)
        x: isLeft ? 1 : box.width - width - 1
        y: isTop ? 1 : box.height - height - 1
        z: 4
        color: handleArea.containsMouse || handleArea.pressed ? box.accent : box.fg
        opacity: (box.selected || boxHover.hovered || handleArea.pressed) && !root.arrangeConfirming ? 0.9 : 0
        visible: opacity > 0

        MouseArea {
          id: handleArea
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: handle.modelData === "tl" || handle.modelData === "br" ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
          onPressed: function(mouse) { box.begin(mouse, this) }
          onPositionChanged: function(mouse) {
            if (!pressed || !box.busy) return
            var d = box.delta(mouse, this)
            var r = Layout.resizeFromCorner(box.startMon, handle.modelData, d.x, d.y)
            root.draftMonitors = Layout.withMonitor(root.draftMonitors, box.monitorName, r)
          }
          onReleased: box.finish()
          onCanceled: box.finish()
        }
      }
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.focused
          ? Commons.I18n.t("monitor.displayFocused").arg(monitorRow.display.name)
          : monitorRow.display.name
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}
