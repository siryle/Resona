"use strict";
const assert = require("node:assert/strict");
const {
  modes,
  minRate,
  maxRate,
  rateStep,
  rates,
  normalizeRate,
  stepRate,
  formatRate,
  formatCompactRate,
  nextIndex,
  shuffled,
  appendUnique,
} = require("./static/playback.js");
assert.deepEqual(modes, ["off", "all", "one", "shuffle"]);
assert.equal(minRate, 0.5);
assert.equal(maxRate, 2.0);
assert.equal(rateStep, 0.1);
assert.deepEqual(
  rates,
  [0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2],
);
assert.equal(normalizeRate(undefined), 1);
assert.equal(normalizeRate(null), 1);
assert.equal(normalizeRate(""), 1);
assert.equal(normalizeRate(NaN), 1);
assert.equal(normalizeRate(Infinity), 1);
assert.equal(normalizeRate(0.1), 0.5);
assert.equal(normalizeRate(3.4), 2);
assert.equal(normalizeRate("1.25"), 1.3);
assert.equal(normalizeRate(0.1 + 0.2), 0.5);
assert.equal(normalizeRate(1.1 + 0.2), 1.3);
assert.equal(stepRate(1, 1), 1.1);
assert.equal(stepRate(1, -1), 0.9);
assert.equal(stepRate(0.5, -1), 0.5);
assert.equal(stepRate(2.0, 1), 2.0);
assert.equal(formatRate(0.5), "0.5x");
assert.equal(formatRate(1), "1.0x");
assert.equal(formatRate(1.2), "1.2x");
assert.equal(formatRate(2), "2.0x");
assert.equal(formatCompactRate(0.5), "0.5x");
assert.equal(formatCompactRate(1), "1x");
assert.equal(formatCompactRate(1.2), "1.2x");
assert.equal(formatCompactRate(1.5), "1.5x");
assert.equal(formatCompactRate(2), "2x");
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
