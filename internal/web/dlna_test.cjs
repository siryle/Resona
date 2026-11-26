"use strict";
const assert = require("node:assert/strict");
const { isBluetoothLabel, shouldAutoAdvance } = require("./static/dlna.js");

assert.equal(isBluetoothLabel("AirPods Pro (Bluetooth)"), true);
assert.equal(isBluetoothLabel("Sony WH-1000XM5 Stereo"), true);
assert.equal(isBluetoothLabel("华为 FreeBuds Pro 3"), true);
assert.equal(isBluetoothLabel("我的蓝牙音箱"), true);
assert.equal(isBluetoothLabel("MacBook Pro Speakers"), false);
assert.equal(isBluetoothLabel(""), false);

// Advance only on natural PLAYING -> STOPPED completion near the end.
assert.equal(shouldAutoAdvance("PLAYING", "STOPPED", 178, 180, false), true);
assert.equal(shouldAutoAdvance("PLAYING", "NO_MEDIA_PRESENT", 180, 180, false), true);
assert.equal(shouldAutoAdvance("PLAYING", "STOPPED", 10, 180, false), false);
assert.equal(shouldAutoAdvance("PLAYING", "STOPPED", 180, 180, true), false);
assert.equal(shouldAutoAdvance("PAUSED_PLAYBACK", "STOPPED", 180, 180, false), false);
assert.equal(shouldAutoAdvance("PLAYING", "PAUSED_PLAYBACK", 180, 180, false), false);

console.log("Web output and DLNA tests passed");
