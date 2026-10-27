"use strict";
const runtimeLogs = {
  level: "",
  paused: false,
  timer: null,
  request: 0,
  searchTimer: null,
  counts: {},
  stop() {
    clearInterval(this.timer);
    clearTimeout(this.searchTimer);
    this.request++;
  },
  start() {
    this.renderLevels();
    this.load();
    this.timer = setInterval(() => {
      if (!this.paused && !document.hidden) this.load();
    }, 5000);
  },
  renderLevels() {
    const buttons = ["", "DEBUG", "INFO", "WARN", "ERROR"].map((level) => {
      const total = Object.values(this.counts).reduce((a, b) => a + b, 0);
      const button = el("button", `log-level ${level.toLowerCase()}`);
      button.append(
        document.createTextNode(level || "全部"),
        el("small", "", String(level ? this.counts[level] || 0 : total)),
      );
      button.setAttribute("aria-pressed", String(this.level === level));
      button.addEventListener("click", () => {
        this.level = level;
        this.renderLevels();
        this.load();
      });
      return button;
    });
    $("logs-levels").replaceChildren(...buttons);
  },
  async load() {
    if (!state.user || state.view !== "logs") return;
    const request = ++this.request;
    const query = new URLSearchParams({
      level: this.level,
      category: $("logs-category").value,
      search: $("logs-search").value,
    });
    try {
      const data = await api(`/logs?${query}`);
      if (request !== this.request || !state.user || state.view !== "logs")
        return;
      $("logs-error").textContent = "";
      this.counts = data.counts;
      // Preserve keyboard focus while auto-refresh updates the counters.
      if (!$("logs-levels").contains(document.activeElement))
        this.renderLevels();
      else
        [...$("logs-levels").children].forEach((button, index) => {
          const level = ["", "DEBUG", "INFO", "WARN", "ERROR"][index];
          button.querySelector("small").textContent = String(
            level
              ? data.counts[level]
              : Object.values(data.counts).reduce((a, b) => a + b, 0),
          );
        });
      $("logs-count").textContent =
        `显示 ${data.items.length} 条 · 已保留 ${data.retained} 条`;
      $("logs-status").textContent =
        `${this.paused ? "自动刷新已暂停" : "自动刷新中"} · 更新于 ${new Date().toLocaleTimeString()}`;
      const categories = {
        system: "系统运行",
        scan: "整理与刮削",
        plugin: "插件",
        settings: "设置更改",
        strm: "STRM 生成",
        probe: "STRM 预探测",
        playback: "302 播放",
      };
      const rows = data.items.map((entry) => {
        const row = el("article", `log-entry ${entry.level.toLowerCase()}`);
        const stamp = el("time", "", new Date(entry.time).toLocaleString());
        stamp.dateTime = entry.time;
        row.append(
          el("strong", "log-entry-level", `[${entry.level}]`),
          stamp,
          el("span", "log-category", categories[entry.category]),
          el("span", "log-message", entry.message),
        );
        return row;
      });
      $("logs-list").replaceChildren(
        ...(rows.length
          ? rows
          : [empty("暂无匹配日志", "调整等级、类别或搜索关键词后重试。")]),
      );
    } catch (error) {
      if (request === this.request && state.user) {
        $("logs-error").textContent =
          `日志读取失败：${error.message}。可点击「刷新日志」重试。`;
        $("logs-status").textContent = "更新失败";
      }
    }
  },
};
$("logs-refresh").addEventListener("click", () => runtimeLogs.load());
$("logs-pause").addEventListener("click", () => {
  runtimeLogs.paused = !runtimeLogs.paused;
  $("logs-pause").textContent = runtimeLogs.paused ? "恢复刷新" : "暂停刷新";
  $("logs-pause").setAttribute("aria-pressed", String(runtimeLogs.paused));
  $("logs-status").textContent = runtimeLogs.paused
    ? "自动刷新已暂停"
    : "自动刷新中";
  if (!runtimeLogs.paused) runtimeLogs.load();
});
$("logs-category").addEventListener("change", () => runtimeLogs.load());
$("logs-search").addEventListener("input", () => {
  clearTimeout(runtimeLogs.searchTimer);
  runtimeLogs.searchTimer = setTimeout(() => runtimeLogs.load(), 250);
});
$("logs-clear").addEventListener("click", async () => {
  if (!confirm("清空服务器保存的全部运行日志？此操作无法撤销。")) return;
  $("logs-clear").disabled = true;
  runtimeLogs.request++;
  try {
    await api("/logs", { method: "DELETE" });
    await runtimeLogs.load();
  } catch (error) {
    $("logs-error").textContent = error.message;
  } finally {
    $("logs-clear").disabled = false;
  }
});
