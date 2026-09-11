// Pure logic for the headphones panel.
//
// Everything here is a function of its arguments: no bindings, no state, no
// Qt. That is what makes it testable, and this is the part worth testing --
// the panel's job is to show what the daemon reports, and every bug that has
// cost real time here was in deciding *what* to show, not in drawing it.
//
// Run the tests with:  node tests/model.test.js

// -- optimistic values ------------------------------------------------------
//
// A click has to show its effect at once, so what we asked for overrides what
// the daemon last reported until the device agrees. These three do that.

function effective(pending, state, field, fallback) {
  if (pending[field] !== undefined) return pending[field]
  var v = state[field]
  return v === undefined || v === null ? fallback : v
}

function sameValue(a, b) {
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (Number(a[i]) !== Number(b[i])) return false
    return true
  }
  return a === b
}

function withClaim(pending, field, value) {
  var next = {}
  for (var k in pending) next[k] = pending[k]
  next[field] = value
  return next
}

// Once the device agrees, stop overriding: from then on the panel shows what
// the headphones actually report, including changes made on the headset.
function reconciled(pending, state) {
  var next = {}, changed = false
  for (var k in pending) {
    if (sameValue(pending[k], state[k])) changed = true
    else next[k] = pending[k]
  }
  return changed ? next : null
}

// -- device actions ---------------------------------------------------------
//
// These have no value to claim, so they are tracked separately: MAC -> the
// action asked for. An entry clears when the headset's own list shows it
// happened, which is the only honest signal available.

function withDeviceAction(busy, mac, action) {
  var next = {}
  for (var k in busy) next[k] = busy[k]
  next[mac] = action
  return next
}

function reconciledDevices(busy, devices) {
  var next = {}, changed = false
  for (var mac in busy) {
    var want = busy[mac]
    var found = null
    for (var i = 0; i < devices.length; i++)
      if (devices[i].mac === mac) found = devices[i]
    // There is no "connect": the headset cannot dial out to a paired device.
    var done = (want === "disconnect" && found && !found.connected)
            || (want === "unpair" && !found)
    if (done) changed = true
    else next[mac] = want
  }
  return changed ? next : null
}

// -- wording ----------------------------------------------------------------

var FIELD_NAMES = {
  mode: "noise mode", ambient_level: "ambient level", eq_preset: "equaliser",
  eq_bands: "bands", eq_clear_bass: "clear bass", dsee: "DSEE",
  audio_priority: "connection", listening: "listening mode",
  auto_power_off: "auto power off", wearing_power: "pause when removed",
  power_off: "switch off", auto_pause: "auto pause", multipoint: "multipoint"
}

function fieldList(fields) {
  var out = []
  for (var i = 0; i < fields.length; i++) out.push(FIELD_NAMES[fields[i]] || fields[i])
  return out.join(", ")
}

function unconfirmedText(fields) {
  if (!fields || fields.length === 0) return ""
  return "Set, but not echoed back yet: " + fieldList(fields) + "."
}

function unacknowledgedText(fields) {
  if (!fields || fields.length === 0) return ""
  return "No answer from the headphones for: " + fieldList(fields) + "."
}

// -- power off --------------------------------------------------------------
//
// Wearing detection and the timer are alternatives, not separate settings, so
// they share one control and one wire value.

function powerOffLabel(value) {
  if (value === "when-removed") return "when removed"
  if (value === "never" || value === "") return "never"
  return value + " min"
}

function powerOffValue(label) {
  if (label === "when removed") return "when-removed"
  if (label === "never") return "never"
  return String(parseInt(label))
}

// -- batteries --------------------------------------------------------------

// Earbuds report three readings and the headline can only carry one, so the
// rest are spelled out. A single-battery headset has nothing to add.
// Left, then right, then whatever else -- a fixed order, not the order the
// device happened to answer in. Reading "R 40%  L 100%" one time and
// "L 100%  R 40%" the next makes the glance cost more than the number saves.
var PART_ORDER = ["main", "left", "right", "case"]
var PART_LABEL = { left: "L", right: "R" }

function batteryParts(batteries) {
  if (!batteries || batteries.length < 2) return ""
  var sorted = batteries.slice().sort(function (a, b) {
    var ai = PART_ORDER.indexOf(a.part), bi = PART_ORDER.indexOf(b.part)
    return (ai < 0 ? PART_ORDER.length : ai) - (bi < 0 ? PART_ORDER.length : bi)
  })
  var out = []
  for (var i = 0; i < sorted.length; i++) {
    var b = sorted[i]
    out.push((PART_LABEL[b.part] || b.part) + " " + b.level + "%")
  }
  return out.join("   ")
}

// -- keyboard ---------------------------------------------------------------

// Only offer a key for something this device actually has. The buds have no
// connection mode; the headphones have no head gestures.
function shortcutHints(has, hasMultipoint) {
  var keys = [["n/a/o", "modes"], ["c", "cycle"]]
  if (has("dsee")) keys.push(["d", "dsee"])
  if (has("auto_pause")) keys.push(["p", "pause"])
  if (hasMultipoint) keys.push(["m", "multipoint"])
  if (has("equalizer")) keys.push(["e", "equaliser"], ["z", "undo"])
  return keys
}

// -- device rows ------------------------------------------------------------

function deviceLabel(device) {
  if (!device) return ""
  return device.name && device.name !== "" ? device.name : device.mac
}

// The buds answer "none" for a button they do not have, which is not a value
// worth a row: it says a button this device lacks is set to nothing.
function buttonMode(raw) {
  var v = raw === undefined || raw === null ? "" : String(raw)
  return v === "none" ? "" : v
}
