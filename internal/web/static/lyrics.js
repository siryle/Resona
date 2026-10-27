"use strict";
(() => {
  function parse(text) {
    const offset =
      Number(text.match(/\[offset:([+-]?\d+)\]/i)?.[1] || 0) / 1000;
    const lines = [];
    for (const line of text.split(/\r?\n/)) {
      const matches = [
        ...line.matchAll(/\[(\d+):([0-5]\d)(?:[.:](\d{1,3}))?\]/g),
      ];
      if (!matches.length) continue;
      const last = matches[matches.length - 1];
      const content = line.slice(last.index + last[0].length).trim();
      if (!content) continue;
      for (const match of matches)
        lines.push({
          time: Math.max(
            0,
            Number(match[1]) * 60 +
              Number(match[2]) +
              Number("0." + (match[3] || "0")) +
              offset,
          ),
          text: content,
        });
    }
    lines.sort((a, b) => a.time - b.time);
    return {
      lines,
      plain: lines.length
        ? ""
        : text
            .replace(/^\[(?:ar|ti|al|by|offset|re|ve|length):.*\]\s*$/gim, "")
            .trim(),
    };
  }
  function activeAt(lines, seconds) {
    let low = 0,
      high = lines.length - 1,
      result = -1;
    while (low <= high) {
      const mid = Math.floor((low + high) / 2);
      if (lines[mid].time <= seconds) {
        result = mid;
        low = mid + 1;
      } else high = mid - 1;
    }
    return result;
  }
  const api = { parse, activeAt };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else globalThis.ResonaLyrics = api;
})();
