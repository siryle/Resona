"use strict";
(() => {
  const modes = ["off", "all", "one", "shuffle"];
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
  const api = { modes, nextIndex, shuffled, appendUnique };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else globalThis.ResonaPlayback = api;
})();
