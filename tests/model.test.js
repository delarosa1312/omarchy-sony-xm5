// Tests for the panel's pure logic.
//
// Model.js is loaded the way QML loads it -- as a plain script with no module
// system -- so it is read and evaluated rather than imported.
//
//     node tests/model.test.js

const { test } = require("node:test")
const assert = require("node:assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "shell-plugin", "Model.js"), "utf8")
const Model = vm.createContext({})
vm.runInContext(source, Model)

// -- optimistic values ------------------------------------------------------

test("a claimed value is shown before the device agrees", () => {
  assert.equal(Model.effective({ mode: "ambient" }, { mode: "off" }, "mode", ""), "ambient")
})

test("with nothing claimed, the device's own reading shows", () => {
  assert.equal(Model.effective({}, { mode: "off" }, "mode", ""), "off")
})

test("a field the daemon has not reported falls back", () => {
  assert.equal(Model.effective({}, {}, "mode", "unknown"), "unknown")
  assert.equal(Model.effective({}, { mode: null }, "mode", "unknown"), "unknown")
})

test("equaliser bands compare by value, not by identity", () => {
  // Two arrays are never === each other, so a claim would never clear and the
  // sliders would sit on our value forever.
  assert.ok(Model.sameValue([1, 2, 3], [1, 2, 3]))
  assert.ok(Model.sameValue([1, 2, 3], ["1", "2", "3"]), "the wire gives strings")
  assert.ok(!Model.sameValue([1, 2, 3], [1, 2, 4]))
  assert.ok(!Model.sameValue([1, 2], [1, 2, 3]))
})

test("claiming does not mutate the map it was given", () => {
  // QML only re-evaluates bindings when the property is reassigned, so a
  // mutated map updates nothing on screen.
  const before = { mode: "ambient" }
  const after = Model.withClaim(before, "dsee", true)
  assert.deepEqual(before, { mode: "ambient" })
  assert.deepEqual(after, { mode: "ambient", dsee: true })
})

test("a claim clears once the device reports the same value", () => {
  const next = Model.reconciled({ mode: "ambient" }, { mode: "ambient" })
  assert.deepEqual(next, {})
})

test("a claim the device has not caught up with is kept", () => {
  assert.equal(Model.reconciled({ mode: "ambient" }, { mode: "off" }), null,
    "null means nothing changed, so the panel leaves the map alone")
})

test("one claim clearing does not drop the others", () => {
  const next = Model.reconciled({ mode: "ambient", dsee: true }, { mode: "ambient", dsee: false })
  assert.deepEqual(next, { dsee: true })
})

// -- device actions ---------------------------------------------------------

test("a disconnect stops spinning when the headset says it is gone", () => {
  const next = Model.reconciledDevices({ "AA:BB": "disconnect" },
    [{ mac: "AA:BB", connected: false }])
  assert.deepEqual(next, {})
})

test("a disconnect keeps spinning while the device is still connected", () => {
  assert.equal(Model.reconciledDevices({ "AA:BB": "disconnect" },
    [{ mac: "AA:BB", connected: true }]), null)
})

test("an unpair is done when the device leaves the list entirely", () => {
  assert.deepEqual(Model.reconciledDevices({ "AA:BB": "unpair" }, []), {})
})

test("connect is not an action this panel can complete", () => {
  // The headset cannot dial out to a paired device, so a connect would spin
  // until the sweep cleared it. There is no button for it, and no handling.
  assert.equal(Model.reconciledDevices({ "AA:BB": "connect" },
    [{ mac: "AA:BB", connected: true }]), null)
})

// -- wording ----------------------------------------------------------------

test("field names are put into words", () => {
  assert.equal(Model.unconfirmedText(["eq_clear_bass", "mode"]),
    "Set, but not echoed back yet: clear bass, noise mode.")
  assert.equal(Model.unacknowledgedText(["dsee"]),
    "No answer from the headphones for: DSEE.")
})

test("nothing outstanding says nothing at all", () => {
  assert.equal(Model.unconfirmedText([]), "")
  assert.equal(Model.unacknowledgedText(undefined), "")
})

test("a field with no friendly name still reads", () => {
  assert.equal(Model.unconfirmedText(["something_new"]),
    "Set, but not echoed back yet: something_new.")
})

// -- power off --------------------------------------------------------------

test("the power-off label and wire value round-trip", () => {
  for (const wire of ["when-removed", "never", "5", "15", "30", "60", "180"])
    assert.equal(Model.powerOffValue(Model.powerOffLabel(wire)), wire)
})

test("an unset power-off reads as never", () => {
  assert.equal(Model.powerOffLabel(""), "never")
})

// -- batteries --------------------------------------------------------------

test("a single-battery headset has no parts to spell out", () => {
  assert.equal(Model.batteryParts([{ part: "main", level: 57 }]), "")
  assert.equal(Model.batteryParts([]), "")
})

test("earbuds name both buds before the case", () => {
  assert.equal(
    Model.batteryParts([
      { part: "case", level: 71 },
      { part: "right", level: 40 },
      { part: "left", level: 100 },
    ]),
    "L 100%   R 40%   case 71%",
    "worn first and in a fixed order, whatever order they arrive in")
})

// -- shortcuts --------------------------------------------------------------

test("a key is only offered for something the device has", () => {
  const none = Model.shortcutHints(() => false, false)
  assert.deepEqual(none.map(k => k[0]), ["n/a/o", "c"])

  const buds = Model.shortcutHints(name => name !== "connection_mode", true)
  assert.deepEqual(buds.map(k => k[0]), ["n/a/o", "c", "d", "p", "m", "e", "z"])
})

// -- device rows ------------------------------------------------------------

test("a device with no name is shown by address", () => {
  assert.equal(Model.deviceLabel({ mac: "AA:BB", name: "" }), "AA:BB")
  assert.equal(Model.deviceLabel({ mac: "AA:BB", name: "Phone" }), "Phone")
  assert.equal(Model.deviceLabel(null), "")
})

test("a button the device does not have is not a value", () => {
  // The buds answer "none" rather than staying silent.
  assert.equal(Model.buttonMode("none"), "")
  assert.equal(Model.buttonMode(undefined), "")
  assert.equal(Model.buttonMode("nc/ambient"), "nc/ambient")
})
