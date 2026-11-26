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
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

assert.deepEqual(
  appendUnique(input.slice(0, 1), [input[0], input[1], input[1], input[2]]),
  input,
);
assert.deepEqual(
  input.map((t) => t.id),
  ["a", "b", "c"],
);

async function testWebAppBoot() {
  const staticDir = path.join(__dirname, "static");
  const elements = new Map();
  const makeElement = (id) => ({
    id,
    value: "",
    textContent: "",
    hidden: false,
    disabled: false,
    readOnly: false,
    required: false,
    minLength: 0,
    autocomplete: "",
    placeholder: "",
    checked: false,
    indeterminate: false,
    dataset: {},
    style: { setProperty() {} },
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    elements: { namedItem: () => makeElement("field") },
    addEventListener() {},
    setAttribute() {},
    removeAttribute() {},
    append() {},
    replaceChildren() {},
    querySelectorAll: () => [],
    querySelector: () => null,
    focus() {},
    pause() {},
    load() {},
    close() {},
    showModal() {},
    getBoundingClientRect: () => ({ height: 0 }),
    contains: () => false,
  });
  const getEl = (id) => {
    if (!elements.has(id)) elements.set(id, makeElement(id));
    return elements.get(id);
  };
  getEl("login-button").textContent = "正在连接服务器…";
  getEl("login-button").disabled = true;

  const docListeners = new Map();
  const fetched = [];
  const storage = new Map();
  const ctx = {
    console,
    URLSearchParams,
    navigator: {},
    localStorage: {
      getItem: (k) => (storage.has(k) ? storage.get(k) : null),
      setItem: (k, v) => storage.set(k, String(v)),
    },
    ResizeObserver: class {
      observe() {}
    },
    AbortController: class {
      abort() {}
    },
    setTimeout,
    clearTimeout,
    setInterval: () => 0,
    clearInterval() {},
    document: {
      hidden: false,
      documentElement: makeElement("html"),
      body: makeElement("body"),
      getElementById: getEl,
      createElement: () => makeElement(""),
      createElementNS: () => makeElement(""),
      querySelectorAll: () => [],
      querySelector: () => null,
      addEventListener: (type, fn) => {
        if (!docListeners.has(type)) docListeners.set(type, []);
        docListeners.get(type).push(fn);
      },
    },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    addEventListener() {},
    fetch: async (url) => {
      fetched.push(url);
      if (url === "/api/v1/auth/status") {
        return {
          ok: true,
          status: 200,
          json: async () => ({ initialized: true, username: "admin" }),
        };
      }
      return { ok: false, status: 401, json: async () => ({}) };
    },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.createContext(ctx);

  for (const name of [
    "lyrics.js",
    "playback.js",
    "dlna.js",
    "app.js",
    "plugins.js",
    "logs.js",
    "files.js",
    "cloud115.js",
  ]) {
    const code = fs.readFileSync(path.join(staticDir, name), "utf8");
    vm.runInContext(code, ctx, { filename: name });
  }

  const readyHandlers = docListeners.get("DOMContentLoaded") || [];
  assert.equal(readyHandlers.length, 1);
  await readyHandlers[0]();

  assert.equal(fetched.includes("/api/v1/auth/status"), true);
  assert.equal(getEl("login-button").disabled, false);
  assert.equal(getEl("login-button").textContent, "进入音乐空间 ↗");
  assert.equal(getEl("login-error").textContent, "");
}

testWebAppBoot()
  .then(() => {
    console.log("Web playback mode and boot tests passed");
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
