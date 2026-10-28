"use strict";
const assert = require("node:assert/strict");
const { parse, activeAt, playbackLines } = require("./static/lyrics.js");
const parsed = parse(
  "[ar:Artist]\n[offset:-500]\n[00:02.50][00:04.500]Line\n[00:01]First\n[00:04.50]Translation",
);
assert.deepEqual(parsed.lines, [
  { time: 0.5, text: "First" },
  { time: 2, text: "Line" },
  { time: 4, text: "Line" },
  { time: 4, text: "Translation" },
]);
assert.equal(activeAt(parsed.lines, 0), -1);
assert.equal(activeAt(parsed.lines, 2), 1);
assert.equal(activeAt(parsed.lines, 4), 3);
assert.equal(activeAt(parsed.lines, 50), 3);
assert.equal(activeAt([], 1), -1);
assert.deepEqual(parse("[ti:Song]\nPlain line\nSecond line"), {
  lines: [],
  plain: "Plain line\nSecond line",
});
assert.equal(parse("[00:01:123]Line").lines[0].time, 1.123);
assert.equal(parse("[offset:1000]\n[00:00.01]Line").lines[0].time, 1.01);
assert.equal(parse("[00:99]Invalid").lines.length, 0);
assert.equal(parse("").plain, "");
assert.deepEqual(playbackLines(parsed.lines, 0), []);
assert.deepEqual(playbackLines(parsed.lines, 2), parsed.lines.slice(1, 3));
assert.deepEqual(playbackLines(parsed.lines, 50), [parsed.lines[3]]);
assert.deepEqual(playbackLines([], 10), []);
console.log("Web lyrics parser tests passed");
