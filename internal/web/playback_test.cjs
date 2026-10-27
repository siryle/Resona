"use strict";
const assert = require("node:assert/strict");
const {
  modes,
  nextIndex,
  shuffled,
  appendUnique,
} = require("./static/playback.js");
assert.deepEqual(modes, ["off", "all", "one", "shuffle"]);
for (const mode of modes.filter((mode) => mode !== "shuffle")) {
  assert.equal(nextIndex(0, 0, 1, mode), -1);
  assert.equal(nextIndex(3, -1, 1, mode), -1);
  assert.equal(nextIndex(3, 3, 1, mode), -1);
  assert.equal(nextIndex(3, 1, 1, mode), 2);
  assert.equal(nextIndex(3, 1, -1, mode), 0);
}
assert.equal(nextIndex(3, 2, 1, "off", true), -1);
assert.equal(nextIndex(3, 0, -1, "off"), -1);
assert.equal(nextIndex(3, 2, 1, "all", true), 0);
assert.equal(nextIndex(3, 0, -1, "all"), 2);
assert.equal(nextIndex(3, 1, 1, "one", true), 1);
assert.equal(nextIndex(3, 2, 1, "one"), 0);
assert.equal(nextIndex(1, 0, 1, "off", true), -1);
assert.equal(nextIndex(1, 0, 1, "all", true), 0);
assert.equal(nextIndex(1, 0, 1, "one", true), 0);
assert.equal(nextIndex(0, 0, 1, "shuffle"), -1);
assert.equal(nextIndex(3, -1, 1, "shuffle"), -1);
assert.equal(nextIndex(1, 0, 1, "shuffle", true), 0);
for (let current = 0; current < 4; current++) {
  for (const sample of [0, 0.3, 0.6, 0.99]) {
    for (const direction of [-1, 1]) {
      const next = nextIndex(4, current, direction, "shuffle", true, () => sample);
      assert(next >= 0 && next < 4 && next !== current);
    }
  }
}
const input = [{ id: "a" }, { id: "b" }, { id: "c" }];
assert.deepEqual(
  shuffled(input, () => 0).map((t) => t.id),
  ["b", "c", "a"],
);
assert.deepEqual(
  input.map((t) => t.id),
  ["a", "b", "c"],
);
assert.deepEqual(shuffled([]), []);
assert.deepEqual(
  appendUnique(input.slice(0, 1), [input[0], input[1], input[1], input[2]]),
  input,
);
assert.deepEqual(
  input.map((t) => t.id),
  ["a", "b", "c"],
);
console.log("Web playback mode tests passed");
