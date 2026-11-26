"use strict";
(() => {
  const modes = ["off", "all", "one", "shuffle"];
  const minRate = 0.5;
  const maxRate = 2.0;
  const rateStep = 0.1;
  const rates = Array.from({ length: 16 }, (_, index) => (5 + index) / 10);
  function normalizeRate(value) {
    if (value === null || value === undefined || value === "") return 1;
    const num = Number(value);
    if (!Number.isFinite(num)) return 1;
    const clamped = Math.min(maxRate, Math.max(minRate, num));
    return Math.round(clamped * 10) / 10;
  }
  function stepRate(value, deltaSteps) {
    const current = normalizeRate(value);
    return normalizeRate((Math.round(current * 10) + deltaSteps) / 10);
  }
  function formatRate(value) {
    return `${normalizeRate(value).toFixed(1)}x`;
  }
  function formatCompactRate(value) {
    const normalized = normalizeRate(value);
    const tenths = Math.round(normalized * 10);
    return tenths % 10 === 0 ? `${tenths / 10}x` : `${normalized.toFixed(1)}x`;
  }
  function nextIndex(length, current, direction, mode, ended = false, random = Math.random) {
    if (length < 1 || current < 0 || current >= length) return -1;
    if (ended && mode === "one") return current;
    if (mode === "shuffle") {
      if (length === 1) return current;
      return (current + 1 + Math.floor(random() * (length - 1))) % length;
    }
    const next = current + direction;
    if (next >= 0 && next < length) return next;
    return mode === "off" ? -1 : (next + length) % length;
  }
  function shuffled(items, random = Math.random) {
    const result = [...items];
    for (let index = result.length - 1; index > 0; index--) {
      const other = Math.floor(random() * (index + 1));
      [result[index], result[other]] = [result[other], result[index]];
    }
    return result;
  }
  function appendUnique(queue, items) {
    const ids = new Set(queue.map((track) => track.id));
    return [
      ...queue,
      ...items.filter((track) => {
        if (ids.has(track.id)) return false;
        ids.add(track.id);
        return true;
      }),
    ];
  }
  const api = {
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
  };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else globalThis.ResonaPlayback = api;
})();
