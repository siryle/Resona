"use strict";
const $ = (id) => document.getElementById(id);
const state = {
  view: "overview",
  library: "local",
  tracks: [],
  albums: [],
  queue: [],
  selecting: false,
  selected: new Map(),
  bulkBusy: false,
  bulkToken: 0,
  repeatMode: readRepeatMode(),
  current: null,
  linkRetried: false,
  playbackPosition: 0,
  playbackRequested: false,
  playbackRequest: 0,
  playbackChecking: 0,
  offset: 0,
  total: 0,
  filter: {},
  request: 0,
  user: false,
  setup: false,
  sources: [],
  jobsRequest: 0,
  jobs: [],
  selectedJobs: new Set(),
  deletingJobs: false,
  jobId: null,
  jobRequest: 0,
  sourceSettings: { metadata: "musicbrainz", lyrics: "lrclib" },
};
const listening = {
  expanded: false,
  request: 0,
  lines: [],
  active: -2,
  manualUntil: 0,
  loadedFor: null,
  controller: null,
};
const audio = $("audio");
let toastTimer, searchTimer, pollTimer;
function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function managementIcon(kind) {
  const paths = {
    folder: "M3 7V5a2 2 0 0 1 2-2h5l3 3h6a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z",
    audio: "M9 18V5l11-2v13M9 8l11-2M9 18a3 2 0 1 1-3-2c1.7 0 3 .9 3 2Zm11-2a3 2 0 1 1-3-2c1.7 0 3 .9 3 2Z",
    file: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Zm0 0v6h6M8 13h8M8 17h5",
    chevron: "m9 5 7 7-7 7",
  };
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  for (const [key, value] of Object.entries({ viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": "1.6", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", class: "management-icon" })) svg.setAttribute(key, value);
  const path = document.createElementNS(svg.namespaceURI, "path");
  path.setAttribute("d", paths[kind] || paths.file);
  svg.append(path);
  return svg;
}
function toast(text) {
  $("toast").textContent = text;
  $("toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    $("toast").hidden = true;
  }, 6000);
}
async function api(path, options = {}) {
  const response = await fetch("/api/v1" + path, {
    ...options,
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", ...options.headers },
  });
  const body = await response.json().catch(() => ({}));
  if (response.status === 401 && path !== "/auth/login") showLogin();
  if (!response.ok)
    throw new Error(body.error || `请求失败 (${response.status})`);
  return body;
}
function showLogin() {
  resetSelection();
  setQueueOpen(false, false);
  setExpanded(false, false);
  listening.controller?.abort();
  listening.request++;
  listening.loadedFor = null;
  listening.lines = [];
  $("listening-lyrics-list").replaceChildren();
  for (const dialog of document.querySelectorAll("dialog[open]"))
    dialog.close();
  state.user = false;
  state.jobsRequest++;
  state.jobId = null;
  state.jobRequest++;
  state.jobs = [];
  state.selectedJobs.clear();
  state.request++;
  state.current = null;
  state.queue = [];
  renderPlaybackControls();
  audio.pause();
  audio.removeAttribute("src");
  audio.load();
  $("player-bar").hidden = true;
  document.body.classList.remove("has-player");
  $("app").hidden = true;
  $("login-view").hidden = false;
  clearInterval(pollTimer);
  runtimeLogs.stop();
  fileManager.reset();
  cloud115.stop();
}
function authMode(status) {
  state.setup = !status.initialized;
  $("username").readOnly = state.setup;
  $("username").value = status.username;
  $("confirm-password-wrap").hidden = !state.setup;
  $("confirm-password").required = state.setup;
  $("password").minLength = state.setup ? 8 : 1;
  $("password").autocomplete = state.setup
    ? "new-password"
    : "current-password";
  $("password").placeholder = state.setup
    ? "设置至少 8 个字符的密码"
    : "输入管理员密码";
  $("auth-kicker").textContent = state.setup
    ? "WELCOME TO RESONA"
    : "WELCOME BACK";
  $("auth-title").textContent = state.setup
    ? "为音乐空间，设一把钥匙。"
    : "每一首，都有归处。";
  $("auth-subtitle").textContent = state.setup
    ? "首次使用，请先设置管理员密码。密码将安全保存在服务器。"
    : "登录，回到你的私人音乐库。";
  $("login-button").textContent = state.setup
    ? "设置密码并进入 ↗"
    : "进入音乐空间 ↗";
  $("login-button").disabled = false;
}
async function enter() {
  state.user = true;
  $("login-view").hidden = true;
  $("app").hidden = false;
  $("password").value = "";
  $("confirm-password").value = "";
  await Promise.all([loadSystem(), loadAlbums(), loadJobs(), loadSources()]);
  clearInterval(pollTimer);
  pollTimer = setInterval(() => {
    if (!document.hidden && state.user) {
      Promise.all([
        loadSystem(),
        loadJobs(),
        state.view === "plugins" ? loadPlugins() : Promise.resolve(),
        state.view === "files" ? fileManager.connection() : Promise.resolve(),
        state.view === "overview" || state.view === "albums"
          ? loadAlbums()
          : Promise.resolve(),
      ]).catch((e) => toast(e.message));
    }
  }, 10000);
}
$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("login-button").disabled = true;
  $("login-error").textContent = "";
  try {
    if (state.setup) {
      if ($("password").value !== $("confirm-password").value)
        throw new Error("两次输入的密码不一致");
      await api("/auth/setup", {
        method: "POST",
        body: JSON.stringify({ password: $("password").value }),
      });
      authMode({ initialized: true, username: $("username").value });
      $("login-button").disabled = true;
    }
    await api("/auth/login", {
      method: "POST",
      body: JSON.stringify({
        username: $("username").value,
        password: $("password").value,
      }),
    });
    await enter();
  } catch (e) {
    $("login-error").textContent = e.message;
    if (state.setup) {
      try {
        authMode(await api("/auth/status"));
      } catch {
        /* Keep the setup form available for retry. */
      }
    }
  } finally {
    $("login-button").disabled = false;
  }
});
$("logout").addEventListener("click", async () => {
  try {
    await api("/auth/logout", { method: "POST", body: "{}" });
    showLogin();
  } catch (e) {
    toast(e.message);
  }
});
const pageTitles = {
  overview: ["音乐，井然有声", "把收藏交给 Resona，把时间留给聆听。"],
  tracks: ["每一首，都是热爱", "你的全部音乐，在这里相遇。"],
  albums: ["一张唱片，一段时光", "从封面开始，重温完整的音乐故事。"],
  artists: ["那些熟悉的声音", "每一种声音，都有独特的灵魂。"],
  favorites: ["偏爱，值得循环", "把心动的旋律，留在身边。"],
  manage: ["让音乐，历历在目", "在音乐库中核对标签，为每首收藏补全歌词。"],
  jobs: ["让收藏，各就其位", "识别、刮削、整理，一切有迹可循。"],
  probe: ["任务", "让歌曲准备就绪，让收藏有迹可循。"],
  job: ["每一步，都有记录", "查看任务提示和文件明细，继续完善你的收藏。"],
  plugins: [
    "让音乐，自动归来",
    "从 Telegram 到你的音乐空间，连接更多收藏方式。",
  ],
  logs: ["系统日志", "查看运行记录，定位任务与服务中的问题。"],
  files: ["文件管理", "浏览目录，管理你的音乐文件。"],
  cloud115: ["115 网盘", "连接音乐收藏，在服务器后台完成准备。"],
  settings: ["自己的音乐空间", "简单设置，安心聆听。"],
};
const viewNames = {
  overview: "概览",
  tracks: "全部音乐",
  albums: "专辑",
  artists: "艺术家",
  favorites: "我喜欢的",
  manage: "音乐库",
  jobs: "整理与刮削",
  probe: "STRM 预探测",
  job: "任务详情",
  settings: "设置",
  plugins: "插件",
  logs: "系统日志",
  files: "文件管理",
  cloud115: "115 网盘",
};
const settingsViews = ["settings", "plugins", "cloud115"];
const taskViews = ["jobs", "probe"];
async function navigate(view, filter = {}) {
  setExpanded(false, false);
  runtimeLogs.stop();
  cloud115.stop();
  state.view = view;
  state.filter = filter;
  resetSelection();
  state.request++;
  for (const button of document.querySelectorAll(".nav-item"))
    button.classList.toggle(
      "active",
      button.dataset.view === (settingsViews.includes(view) ? "settings" : taskViews.includes(view) || view === "job" ? "jobs" : view),
    );
  $("breadcrumb").textContent = settingsViews.includes(view) ? "设置 / " + (view === "settings" ? "系统设置" : viewNames[view]) : taskViews.includes(view) ? "任务 / " + viewNames[view] : viewNames[view];
  const title = el("span", "", ".");
  $("page-title").replaceChildren(
    document.createTextNode(settingsViews.includes(view) ? "设置" : taskViews.includes(view) ? "任务" : pageTitles[view][0]),
    title,
  );
  $("page-subtitle").textContent = settingsViews.includes(view) ? "管理系统、插件与网盘音源。" : taskViews.includes(view) ? "管理整理、刮削与预探测任务，查看每一次执行记录。" : pageTitles[view][1];
  $("overview").hidden = view !== "overview";
  $("library-view").hidden = !["tracks", "favorites", "manage"].includes(view);
  $("library-view").classList.toggle("library-management", view === "manage");
  $("albums-view").hidden = view !== "albums";
  $("artists-view").hidden = view !== "artists";
  $("jobs-view").hidden = view !== "jobs";
  $("tasks-view").hidden = !taskViews.includes(view);
  $("cloud-probe-view").hidden = view !== "probe";
  $("job-detail-view").hidden = view !== "job";
  $("settings-view").hidden = !settingsViews.includes(view);
  $("system-settings-panel").hidden = view !== "settings";
  for (const tab of document.querySelectorAll('#settings-tabs [role="tab"], #tasks-tabs [role="tab"]')) {
    const selected = tab.dataset.view === view;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
  }
  $("plugins-view").hidden = view !== "plugins";
  $("logs-view").hidden = view !== "logs";
  $("files-view").hidden = view !== "files";
  $("cloud115-view").hidden = view !== "cloud115";
  $("library-scope-control").hidden = settingsViews.includes(view) || taskViews.includes(view) || ["files", "logs", "job"].includes(view);
  $("page-kicker").hidden = settingsViews.includes(view) || taskViews.includes(view) || ["logs", "files"].includes(view);
  $("scan-button").hidden = settingsViews.includes(view) || ["logs", "files", "jobs", "probe"].includes(view);
  renderScanButton();
  try {
    if (["tracks", "favorites", "manage"].includes(view))
      await loadTracks(false);
    if (view === "albums" || view === "overview") await loadAlbums();
    if (view === "artists") await loadArtists();
    if (view === "jobs") await loadJobs();
    if (view === "job") await loadJobDetail();
    if (view === "settings") await Promise.all([loadSystem(), loadScanSchedule()]);
    if (view === "plugins") await loadPlugins();
    if (view === "logs") runtimeLogs.start();
    if (view === "files") await fileManager.open();
    if (view === "cloud115" || view === "probe") await cloud115.load(true);
  } catch (e) {
    toast(e.message);
  }
}
for (const tablist of [$("settings-tabs"), $("tasks-tabs")]) tablist.addEventListener("keydown", event => {
  const tab = event.target.closest('[role="tab"]');
  if (!tab || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
  event.preventDefault();
  const tabs = [...tablist.querySelectorAll('[role="tab"]')];
  const index = event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1
    : (tabs.indexOf(tab) + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
  navigate(tabs[index].dataset.view);
  tabs[index].focus();
});
document.addEventListener("click", (event) => {
  const target = event.target.closest("[data-view]");
  if (target) {
    $("search").value = "";
    navigate(target.dataset.view);
  }
});
$("search-form").addEventListener("submit", (event) => {
  event.preventDefault();
  navigate(state.view === "manage" ? "manage" : "tracks");
});
$("search").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(
    () => navigate(state.view === "manage" ? "manage" : "tracks"),
    300,
  );
});
function empty(title, message) {
  const box = el("div", "empty");
  box.append(
    el("div", "empty-symbol", "♫"),
    el("h3", "", title),
    el("p", "", message),
  );
  return box;
}
async function loadSystem() {
  const data = await api("/system?library=" + state.library);
  if (!state.user) return;
  $("stat-tracks").textContent = data.tracks.toLocaleString();
  $("stat-albums").textContent = data.albums.toLocaleString();
  $("stat-artists").textContent = data.artists.toLocaleString();
  $("stat-hours").textContent = (data.duration / 3600).toFixed(
    data.duration ? 1 : 0,
  );
  $("version-label").textContent =
    `RESONA ${data.version.version} · ${data.version.build}`;
  const settings = $("settings-list");
  settings.replaceChildren();
  for (const [name, value] of [
    ["版本", `${data.version.version} (${data.version.build})`],
    ["导入目录", data.inbox_path],
    ["音乐库目录", data.library_path],
    [
      "在线元数据",
      data.scrape_enabled
        ? `${sourceLabel(state.sourceSettings.metadata)} · 已启用`
        : "已关闭 · 仅使用本地标签",
    ],
    [
      "自动扫描间隔",
      data.scan_interval === "0s" ? "手动扫描" : data.scan_interval,
    ],
    ["音乐库大小", `${(data.bytes / 1024 ** 3).toFixed(2)} GB`],
  ])
    settings.append(el("dt", "", name), el("dd", "", value));
}
function sourceLabel(id) {
  return (
    state.sources.find((source) => source.id === id)?.name ||
    {
      auto: "自动选择",
      local: "本地标签 / LRC",
      filename: "文件名（待预探测）",
      embedded: "文件内嵌歌词",
      manual: "人工更正",
      LRCLIB: "LRCLIB",
    }[id] ||
    id ||
    "本地标签"
  );
}
function lyricsSourceLabel(id, track) {
  if (id === "local")
    return track?.library === "cloud" ? "STRM 同目录 LRC" : "外置 LRC";
  if (id === "embedded") return "音频内嵌标签";
  if (id === "cloud") return "115 同目录歌词";
  return sourceLabel(id);
}
function fillSources(id, kind, selected) {
  const select = $(id);
  select.replaceChildren();
  const automatic = el("option", "", "自动 · 按优先级尝试");
  automatic.value = "auto";
  select.append(automatic);
  for (const source of state.sources.filter((item) => item[kind])) {
    const option = el("option", "", source.name);
    option.value = source.id;
    select.append(option);
  }
  select.value = selected;
}
function applySources(data) {
  state.sources = data.items;
  state.sourceSettings = data.settings;
  fillSources("default-metadata-source", "metadata", data.settings.metadata);
  fillSources("default-lyrics-source", "lyrics", data.settings.lyrics);
  fillSources("match-source", "metadata", data.settings.metadata);
  fillSources("lyrics-source", "lyrics", data.settings.lyrics);
  renderPriority(
    data.settings.metadata_priority,
    null,
    data.settings.metadata_disabled,
  );
  renderPriority(
    data.settings.lyrics_priority,
    null,
    data.settings.lyrics_disabled,
    "lyrics",
  );
  $("source-capabilities").textContent = `刮削：${data.items
    .filter((s) => s.metadata)
    .map((s) => s.name)
    .join("、")}。歌词：${data.items
    .filter((s) => s.lyrics)
    .map((s) => s.name)
    .join("、")}；本地 LRC 与文件内嵌歌词可直接读取。`;
}
function renderPriority(priority, focused, disabled, kind = "metadata") {
  disabled ??= currentDisabled(kind);
  const list = $(`${kind}-priority`);
  const automatic = $(`default-${kind}-source`).value === "auto";
  list.replaceChildren();
  list.classList.toggle("inactive", !automatic);
  $(
    kind === "metadata" ? "priority-hint" : "lyrics-priority-hint",
  ).textContent = automatic
    ? (kind === "metadata"
        ? "从上到下尝试已启用来源，优先采用时长一致的可信结果。"
        : "从上到下尝试已启用歌词源，匹配成功后停止。") +
      "取消勾选可禁用单个来源。"
    : `选择默认${kind === "metadata" ? "刮削" : "歌词"}源「自动」后可调整优先级；当前只使用所选来源。`;
  priority.forEach((id, index) => {
    const row = el("li");
    row.dataset.source = id;
    const label = el("label", "source-enabled");
    const enabled = el("input");
    enabled.type = "checkbox";
    enabled.checked = !disabled.includes(id);
    enabled.disabled = !automatic;
    enabled.setAttribute("aria-label", `启用 ${sourceLabel(id)}`);
    const copy = el("span");
    copy.append(el("span", "", `${index + 1}. ${sourceLabel(id)}`));
    const requirement = state.sources.find(
      (source) => source.id === id,
    )?.requirement;
    if (requirement) copy.append(el("small", "muted", requirement));
    label.append(enabled, copy);
    row.append(label);
    for (const [label, step] of [
      ["上移", -1],
      ["下移", 1],
    ]) {
      const button = el("button", "text-button", label);
      button.type = "button";
      button.disabled =
        !automatic || index + step < 0 || index + step >= priority.length;
      button.setAttribute("aria-label", `${label} ${sourceLabel(id)}`);
      button.dataset.priorityAction = `${id}-${step}`;
      button.addEventListener("click", () => {
        const reordered = [...priority];
        [reordered[index], reordered[index + step]] = [
          reordered[index + step],
          reordered[index],
        ];
        renderPriority(
          reordered,
          button.dataset.priorityAction,
          currentDisabled(kind),
          kind,
        );
      });
      row.append(button);
    }
    list.append(row);
  });
  if (focused) {
    const buttons = [...list.querySelectorAll("button")];
    const target = buttons.find(
      (button) => button.dataset.priorityAction === focused,
    );
    (target?.disabled
      ? target.closest("li").querySelector("button:not(:disabled)")
      : target
    )?.focus();
  }
}
function currentPriority(kind = "metadata") {
  return [...$(`${kind}-priority`).children].map((row) => row.dataset.source);
}
function currentDisabled(kind = "metadata") {
  return [...$(`${kind}-priority`).children]
    .filter((row) => !row.querySelector("input").checked)
    .map((row) => row.dataset.source);
}
$("default-metadata-source").addEventListener("change", () =>
  renderPriority(currentPriority()),
);
$("default-lyrics-source").addEventListener("change", () =>
  renderPriority(
    currentPriority("lyrics"),
    null,
    currentDisabled("lyrics"),
    "lyrics",
  ),
);
async function loadSources() {
  applySources(await api("/sources"));
}
$("source-settings").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("source-save").disabled = true;
  $("source-error").textContent = "";
  try {
    applySources(
      await api("/sources", {
        method: "PUT",
        body: JSON.stringify({
          metadata: $("default-metadata-source").value,
          lyrics: $("default-lyrics-source").value,
          metadata_priority: currentPriority(),
          metadata_disabled: currentDisabled(),
          lyrics_priority: currentPriority("lyrics"),
          lyrics_disabled: currentDisabled("lyrics"),
        }),
      }),
    );
    toast("来源设置与刮削、歌词优先级已保存。");
    await loadSystem();
  } catch (error) {
    $("source-error").textContent = error.message;
  } finally {
    $("source-save").disabled = false;
  }
});
function artwork(container, track, index = 0) {
  container.replaceChildren();
  if (track.artwork) {
    const image = el("img");
    image.src = track.artwork;
    image.alt = "";
    image.loading = "lazy";
    image.addEventListener(
      "error",
      () => {
        image.remove();
        container.append(el("span", "cover-disc"));
      },
      { once: true },
    );
    container.append(image);
  } else {
    container.classList.add(`tone-${index % 4}`);
    container.append(el("span", "cover-disc"));
  }
}
function albumCard(album, index) {
  const card = el("button", "album-card");
  const cover = el("div", "album-cover");
  artwork(cover, album, index);
  if (album.year) cover.append(el("span", "album-year", album.year));
  card.append(
    cover,
    el("h3", "", album.title),
    el("p", "", `${album.artist} · ${album.tracks} 首`),
  );
  card.addEventListener("click", () => {
    $("search").value = "";
    navigate("tracks", { album: album.id, label: album.title });
  });
  return card;
}
async function loadAlbums() {
  const scope = state.library;
  const data = await api("/albums?library=" + state.library);
  if (!state.user || scope !== state.library) return;
  state.albums = data.items;
  for (const [id, albums] of [
    ["recent-albums", data.items.slice(0, 5)],
    ["all-albums", data.items],
  ]) {
    const container = $(id);
    container.replaceChildren();
    if (!albums.length)
      container.append(
        empty(
          "第一张唱片，等你入库",
          "已有音乐可点击「扫描音乐库」更新索引；新增文件请放入导入目录，在任务页点击「整理入库」。",
        ),
      );
    else
      albums.forEach((album, index) =>
        container.append(albumCard(album, index)),
      );
  }
}
async function loadTracks(append) {
  const generation = ++state.request;
  const params = new URLSearchParams({
    limit: "100",
    offset: append ? String(state.tracks.length) : "0",
    search: $("search").value.trim(),
    library: state.library,
  });
  if (state.view === "favorites") params.set("favorite", "true");
  for (const key of ["album", "artist"])
    if (state.filter[key]) params.set(key, state.filter[key]);
  $("load-more").disabled = true;
  try {
    const data = await api("/tracks?" + params);
    if (generation !== state.request || !state.user) return;
    state.tracks = append ? state.tracks.concat(data.items) : data.items;
    state.total = data.total;
    renderBulkControls();
    $("library-title").textContent =
      state.filter.label ||
      (state.view === "favorites"
        ? "我喜欢的"
        : $("search").value.trim()
          ? "搜索结果"
          : state.view === "manage"
            ? "音乐库"
            : "全部音乐");
    $("track-count").textContent = `${data.total} 首`;
    renderTracks();
    if (state.view === "manage")
      refreshEmbeddedBadges(state.tracks, generation);
    $("load-more").hidden = state.tracks.length >= data.total;
  } finally {
    $("load-more").disabled = false;
  }
}
$("load-more").addEventListener("click", () =>
  loadTracks(true).catch((e) => toast(e.message)),
);
function time(seconds) {
  if (!Number.isFinite(seconds)) return "0:00";
  return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
}
function embeddedLyricsLabel(track) {
  return track.has_embedded_lyrics === true
    ? "标签有歌词"
    : track.has_embedded_lyrics === false
      ? "标签无歌词"
      : "标签歌词待检测";
}
async function refreshEmbeddedBadges(tracks, generation) {
  const pending = tracks.filter((track) => track.has_embedded_lyrics == null);
  await Promise.all(
    Array.from({ length: Math.min(4, pending.length) }, async () => {
      while (
        pending.length &&
        state.user &&
        generation === state.request &&
        state.view === "manage"
      ) {
        const track = pending.shift();
        try {
          const fresh = await api(`/tracks/${track.id}?check_lyrics=true`);
          if (generation !== state.request || !state.user) return;
          track.has_embedded_lyrics = fresh.has_embedded_lyrics;
          const badge = [...document.querySelectorAll(".track-tag-badge")].find(
            (node) => node.dataset.trackId === track.id,
          );
          if (badge) {
            badge.textContent = embeddedLyricsLabel(track);
            badge.classList.toggle(
              "has-lyrics",
              track.has_embedded_lyrics === true,
            );
          }
        } catch {
          /* An unreadable tag remains unknown rather than being marked absent. */
        }
      }
    }),
  );
}
function renderTracks() {
  const list = $("track-list");
  const focused = document.activeElement;
  const focusedTrack = focused?.closest(".track-row")?.dataset.trackId;
  const focusedControl = focused?.classList.contains("track-info")
    ? ".track-info"
    : focused?.classList.contains("track-number")
      ? ".track-number"
      : focused?.classList.contains("icon-button")
        ? ".icon-button"
        : null;
  list.replaceChildren();
  if (!state.tracks.length) {
    list.append(
      empty("这里还没有音乐", "试试其他关键词，或扫描导入目录中的音乐文件。"),
    );
    return;
  }
  state.tracks.forEach((track, index) => {
    const manage = state.view === "manage";
    const activate = () => {
      if (state.selecting && !manage) {
        if (state.selected.has(track.id)) state.selected.delete(track.id);
        else state.selected.set(track.id, track);
        renderTracks();
        renderBulkControls();
      } else if (manage) openTrackDetails(track, state.tracks);
      else play(track, state.tracks);
    };
    const row = el("div", "track-row");
    row.dataset.trackId = track.id;
    const number = el(
      "button",
      "track-number",
      String(index + 1).padStart(2, "0"),
    );
    number.setAttribute(
      "aria-label",
      `${state.selecting ? "选择" : manage ? "歌曲详情" : "播放"} ${track.title}`,
    );
    if (state.selecting && !manage) {
      number.textContent = state.selected.has(track.id) ? "●" : "○";
      number.setAttribute("role", "checkbox");
      number.setAttribute("aria-checked", String(state.selected.has(track.id)));
      row.classList.toggle("selected", state.selected.has(track.id));
    }
    number.addEventListener("click", activate);
    const thumbnail = el("div", "track-thumbnail");
    artwork(thumbnail, track, index);
    const info = el("button", "track-info");
    info.append(el("strong", "", track.title), el("small", "", track.artist));
    if (manage) {
      const badge = el(
        "span",
        `track-tag-badge${track.has_embedded_lyrics ? " has-lyrics" : ""}`,
        embeddedLyricsLabel(track),
      );
      badge.dataset.trackId = track.id;
      badge.title = "仅表示音频文件标签中的歌词，不包含外置 LRC 或在线歌词缓存";
      info.querySelector("small").append(badge);
      const lrc = el("span", `track-lrc-badge${track.has_lrc_lyrics ? " has-lyrics" : ""}`,
        track.has_lrc_lyrics ? "有 LRC 歌词" : "无 LRC 歌词");
      lrc.title = "仅表示歌曲同目录的本地 LRC 文件，不包含音频内嵌歌词或在线缓存";
      info.querySelector("small").append(lrc);
    }
    info.setAttribute(
      "aria-label",
      state.selecting && !manage
        ? `选择 ${track.title} · ${track.artist}`
        : manage
          ? `歌曲详情 · ${track.title}`
          : `播放 ${track.title} · ${track.artist}`,
    );
    info.addEventListener("click", activate);
    row.addEventListener("click", (event) => {
      if (!event.target.closest("button")) activate();
    });
    const favorite = el(
      "button",
      `icon-button${track.favorite ? " liked" : ""}`,
      track.favorite ? "♥" : "♡",
    );
    favorite.setAttribute(
      "aria-label",
      `${track.favorite ? "取消收藏" : "收藏"} ${track.title}`,
    );
    favorite.addEventListener("click", async () => {
      favorite.disabled = true;
      try {
        await toggleFavorite(track);
        renderTracks();
      } catch (e) {
        toast(e.message);
      } finally {
        favorite.disabled = false;
      }
    });
    row.append(
      number,
      thumbnail,
      info,
      el("span", "track-album", track.album),
      el("span", "track-time", time(track.duration)),
      favorite,
    );
    if (state.view === "manage") {
      const actions = el("div", "track-actions");
      actions.append(...trackActions(track));
      row.append(actions);
    }
    list.append(row);
  });
  if (focusedTrack && focusedControl)
    [...list.children]
      .find((row) => row.dataset.trackId === focusedTrack)
      ?.querySelector(focusedControl)
      ?.focus({ preventScroll: true });
}
const metadataKeys = [
  "title",
  "artist",
  "album",
  "album_artist",
  "year",
  "genre",
  "number",
  "disc",
  "mbid",
  "release_id",
  "source",
];
let editingTrack,
  lyricsTrack,
  correctionSession = 0,
  matchRequest = 0,
  lyricsRequest = 0;
for (const button of document.querySelectorAll("[data-close]"))
  button.addEventListener("click", () => $(button.dataset.close).close());
{
  const dialog = $("track-dialog");
  let startedOutside = false;
  const outside = (event) => {
    const rect = dialog.getBoundingClientRect();
    return (
      event.target === dialog &&
      (event.clientX < rect.left ||
        event.clientX > rect.right ||
        event.clientY < rect.top ||
        event.clientY > rect.bottom)
    );
  };
  dialog.addEventListener("pointerdown", (event) => {
    startedOutside = outside(event);
  });
  dialog.addEventListener("click", (event) => {
    if (startedOutside && outside(event)) dialog.close();
    startedOutside = false;
  });
}
$("correction-dialog").addEventListener("close", () => {
  correctionSession++;
  matchRequest++;
});
$("lyrics-dialog").addEventListener("close", () => {
  lyricsRequest++;
});
function openCorrection(track) {
  correctionSession++;
  editingTrack = track;
  $("correction-track").textContent = `${track.title} · ${track.artist}`;
  $("match-title").value = track.title;
  $("match-artist").value =
    track.artist === "Unknown Artist" ? "" : track.artist;
  $("match-source").value = state.sourceSettings.metadata;
  for (const key of metadataKeys)
    $("metadata-form").elements.namedItem(key).value =
      key === "source" ? track.metadata_source || "manual" : (track[key] ?? "");
  $("metadata-error").textContent = "";
  $("match-results").replaceChildren();
  $("metadata-fields").disabled = false;
  $("metadata-save").disabled = false;
  $("match-search").disabled = false;
  $("correction-dialog").showModal();
}
$("metadata-fields").addEventListener("input", (event) => {
  if (
    ["title", "artist", "album", "album_artist"].includes(event.target.name)
  ) {
    for (const key of ["mbid", "release_id"])
      $("metadata-form").elements.namedItem(key).value = "";
    $("metadata-form").elements.namedItem("source").value = "manual";
    for (const button of $("match-results").querySelectorAll("button"))
      button.setAttribute("aria-pressed", "false");
  }
});
$("match-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const generation = ++matchRequest;
  const title = $("match-title").value.trim(),
    artist = $("match-artist").value.trim();
  $("match-search").disabled = true;
  $("match-results").replaceChildren(
    el("p", "muted", `正在搜索 ${sourceLabel($("match-source").value)}…`),
  );
  try {
    const data = await api(
      `/tracks/${editingTrack.id}/matches?` +
        new URLSearchParams({ title, artist, source: $("match-source").value }),
    );
    if (generation !== matchRequest) return;
    const list = $("match-results");
    list.replaceChildren();
    if (!data.items.length)
      list.append(
        el("p", "muted", "没有找到候选。可以调整搜索词，或直接修改下方标签。"),
      );
    for (const item of data.items) {
      const button = el("button", "match-candidate");
      button.type = "button";
      button.setAttribute("aria-pressed", "false");
      button.append(
        el("strong", "", item.title),
        el("span", "", `${item.artist} · ${item.album || "未提供专辑"}`),
        el(
          "small",
          "",
          `${sourceLabel(item.source)} · ${item.year || "年份未知"} · ${time(item.duration)}${item.score ? " · 搜索评分 " + item.score : ""}`,
        ),
      );
      button.addEventListener("click", () => {
        for (const key of [
          "title",
          "artist",
          "album",
          "album_artist",
          "year",
          "mbid",
          "release_id",
          "source",
        ])
          $("metadata-form").elements.namedItem(key).value = item[key] ?? "";
        for (const key of ["genre", "number", "disc"])
          if (item[key])
            $("metadata-form").elements.namedItem(key).value = item[key];
        for (const candidate of list.querySelectorAll("button"))
          candidate.setAttribute("aria-pressed", String(candidate === button));
      });
      list.append(button);
    }
  } catch (error) {
    if (generation === matchRequest)
      $("match-results").replaceChildren(el("p", "form-error", error.message));
  } finally {
    if (generation === matchRequest) $("match-search").disabled = false;
  }
});
$("metadata-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const id = editingTrack.id;
  const session = correctionSession;
  const body = {};
  for (const key of metadataKeys) {
    const value = $("metadata-form").elements.namedItem(key).value.trim();
    body[key] = key === "number" || key === "disc" ? Number(value) : value;
  }
  $("metadata-fields").disabled = true;
  $("metadata-save").disabled = true;
  $("metadata-error").textContent = "";
  try {
    const updated = await api(`/tracks/${id}/metadata`, {
      method: "PUT",
      body: JSON.stringify(body),
    });
    for (const group of [state.tracks, state.queue])
      for (const track of group)
        if (track.id === id) Object.assign(track, updated);
    if (state.current?.id === id) {
      Object.assign(state.current, updated);
      $("player-title").textContent = updated.title;
      $("player-artist").textContent = updated.artist;
      renderListeningTrack();
      if (listening.expanded) loadListeningLyrics(true);
      if ("mediaSession" in navigator)
        navigator.mediaSession.metadata = new MediaMetadata({
          title: updated.title,
          artist: updated.artist,
          album: updated.album,
        });
    }
    if (session === correctionSession) $("correction-dialog").close();
    renderTracks();
    renderQueue();
    toast("识别更正已保存，后续刮削会保留。");
    await Promise.all([loadAlbums(), loadSystem()]);
    if (["tracks", "favorites", "manage"].includes(state.view))
      await loadTracks(false);
    if (state.view === "job") await loadJobs();
  } catch (error) {
    if (session === correctionSession)
      $("metadata-error").textContent = error.message;
  } finally {
    if (session === correctionSession) {
      $("metadata-fields").disabled = false;
      $("metadata-save").disabled = false;
    }
  }
});
async function openLyrics(track) {
  lyricsTrack = track;
  const generation = ++lyricsRequest;
  $("lyrics-track").textContent = `${track.title} · ${track.artist}`;
  $("lyrics-source").value = state.sourceSettings.lyrics;
  $("lyrics-error").textContent = "";
  $("lyrics-preview").textContent = "";
  $("lyrics-status").textContent = "正在读取现有歌词…";
  $("lyrics-replace").checked = false;
  $("lyrics-replace-wrap").hidden = true;
  $("lyrics-scrape").disabled = true;
  $("lyrics-embed").disabled = true;
  $("lyrics-embed-replace").checked = false;
  const cloud = track.library === "cloud";
  $("lyrics-embed").hidden = cloud;
  $("lyrics-embed-replace-wrap").hidden = cloud;
  $("lyrics-storage-hint").textContent = cloud
    ? "同步的网盘 LRC 保存在 STRM 同目录，在线获取的歌词保存在服务端。标签徽标仅表示远端音频的内嵌歌词；此处不能将歌词写回 115 音频文件。"
    : "写入标签支持 MP3、FLAC、M4A、OGG、Opus，不重新编码音频。修改的是音乐库副本，原导入文件保持不变。";
  $("lyrics-dialog").showModal();
  try {
    const response = await fetch(`/api/v1/tracks/${track.id}/lyrics`, {
      credentials: "same-origin",
    });
    if (generation !== lyricsRequest) return;
    if (response.status === 401) {
      showLogin();
      return;
    }
    if (response.status === 404) {
      $("lyrics-status").textContent = "暂无歌词，点击下方按钮开始获取。";
    } else {
      if (!response.ok) throw new Error("无法读取歌词，请稍后重试");
      const text = await response.text();
      if (generation !== lyricsRequest) return;
      $("lyrics-preview").textContent = text;
      $("lyrics-status").textContent =
        `已有歌词 · ${lyricsSourceLabel(response.headers.get("X-Lyrics-Source"), track)}`;
      $("lyrics-replace-wrap").hidden = false;
      $("lyrics-embed").disabled = cloud;
    }
  } catch (error) {
    if (generation === lyricsRequest)
      $("lyrics-error").textContent = error.message;
  } finally {
    if (generation === lyricsRequest) $("lyrics-scrape").disabled = false;
  }
}
$("lyrics-scrape").addEventListener("click", async () => {
  const generation = lyricsRequest;
  $("lyrics-scrape").disabled = true;
  $("lyrics-error").textContent = "";
  $("lyrics-status").textContent = "正在匹配并获取歌词…";
  try {
    const data = await api(`/tracks/${lyricsTrack.id}/lyrics/scrape`, {
      method: "POST",
      body: JSON.stringify({
        replace: $("lyrics-replace").checked,
        source: $("lyrics-source").value,
      }),
    });
    if (generation !== lyricsRequest) return;
    $("lyrics-preview").textContent = data.text;
    $("lyrics-status").textContent =
      `已保存 · ${lyricsSourceLabel(data.source, lyricsTrack)} · ${data.synced ? "同步歌词" : "纯文本歌词"}`;
    $("lyrics-replace-wrap").hidden = false;
    $("lyrics-replace").checked = false;
    $("lyrics-embed").disabled = lyricsTrack.library === "cloud";
    toast("歌词已保存。");
    if (state.current?.id === lyricsTrack.id) {
      listening.loadedFor = null;
      if (listening.expanded) loadListeningLyrics(true);
    }
  } catch (error) {
    if (generation === lyricsRequest) {
      $("lyrics-error").textContent = error.message;
      $("lyrics-status").textContent = "获取未完成，现有歌词已保留。";
    }
  } finally {
    if (generation === lyricsRequest) $("lyrics-scrape").disabled = false;
  }
});
$("lyrics-embed").addEventListener("click", async () => {
  const generation = lyricsRequest;
  const id = lyricsTrack.id;
  $("lyrics-embed").disabled = true;
  $("lyrics-scrape").disabled = true;
  $("lyrics-error").textContent = "";
  $("lyrics-status").textContent = "正在将歌词写入音频标签，不重新编码音频…";
  try {
    const updated = await api(`/tracks/${id}/lyrics/embed`, {
      method: "POST",
      body: JSON.stringify({ replace: $("lyrics-embed-replace").checked }),
    });
    if (!state.user) return;
    const current = state.current?.id === id;
    const position = audio.currentTime;
    const paused = audio.paused;
    for (const group of [state.tracks, state.queue])
      for (const track of group)
        if (track.id === id) Object.assign(track, updated);
    if (current) {
      Object.assign(state.current, updated);
      audio.src = `/api/v1/tracks/${updated.id}/stream`;
      audio.currentTime = position;
      if (!paused) audio.play().catch((error) => toast(error.message));
      listening.loadedFor = null;
      renderListeningTrack();
      if (listening.expanded) loadListeningLyrics(true);
    }
    if (generation === lyricsRequest) {
      lyricsTrack = updated;
      $("lyrics-status").textContent =
        "已写入音频标签 · 原导入文件与音频编码保持不变";
      $("lyrics-embed-replace").checked = false;
    }
    renderTracks();
    renderQueue();
    await Promise.all([loadSystem(), loadAlbums()]);
    if (state.view === "job") await loadJobs();
    toast("歌词已写入文件标签，徽标已更新。");
  } catch (error) {
    if (generation === lyricsRequest) {
      $("lyrics-error").textContent = error.message;
      $("lyrics-status").textContent = "写入未完成，原音频和现有歌词已保留。";
    }
  } finally {
    if (generation === lyricsRequest) {
      $("lyrics-embed").disabled =
        lyricsTrack.library === "cloud" || !$("lyrics-preview").textContent;
      $("lyrics-scrape").disabled = false;
    }
  }
});
async function toggleFavorite(track) {
  const updated = await api(`/tracks/${track.id}/favorite`, {
    method: "PUT",
    body: JSON.stringify({ favorite: !track.favorite }),
  });
  for (const group of [state.tracks, state.queue])
    for (const item of group)
      if (item.id === updated.id) item.favorite = updated.favorite;
  if (state.current?.id === updated.id) {
    state.current.favorite = updated.favorite;
    $("player-favorite").textContent = updated.favorite ? "♥" : "♡";
  }
}
async function loadArtists() {
  const scope = state.library;
  const data = await api("/artists?library=" + state.library);
  if (!state.user || scope !== state.library) return;
  const list = $("artist-list");
  list.replaceChildren();
  if (!data.items.length)
    list.append(
      empty("等待熟悉的声音", "导入音乐后，艺术家会自动出现在这里。"),
    );
  for (const artist of data.items) {
    const card = el("button", "artist-card");
    const copy = el("div");
    copy.append(
      el("strong", "", artist.name),
      el("small", "", `${artist.tracks} 首歌曲`),
    );
    card.append(
      el("span", "artist-avatar", Array.from(artist.name)[0] || "♫"),
      copy,
    );
    card.addEventListener("click", () =>
      navigate("tracks", { artist: artist.name, label: artist.name }),
    );
    list.append(card);
  }
}
const jobStates = {
  running: "进行中",
  completed: "已完成",
  completed_with_errors: "需检查",
  interrupted: "已中断",
};
const itemStates = {
  processing: "处理中",
  imported: "已入库",
  imported_with_warnings: "入库需检查",
  skipped: "已跳过",
  failed: "失败",
  interrupted: "已中断",
};
function trackActions(track, close) {
  return [
    ["识别更正", openCorrection],
    ["刮削歌词", openLyrics],
  ].map(([label, action]) => {
    const button = el("button", "track-action", label);
    button.addEventListener("click", async () => {
      button.disabled = true;
      try {
        const fresh = await api(`/tracks/${track.id}`);
        if (!state.user) return;
        close?.();
        action(fresh);
      } catch (error) {
        toast(error.message);
      } finally {
        button.disabled = false;
      }
    });
    return button;
  });
}
async function openTrackDetails(track, queue = state.queue) {
  const playlist = queue.some((item) => item.id === track.id)
    ? [...queue]
    : [track];
  try {
    const fresh = await api(`/tracks/${track.id}?check_lyrics=true`);
    if (!state.user) return;
    artwork($("track-detail-art"), fresh);
    $("track-detail-name").textContent = fresh.title;
    $("track-detail-artist").textContent = fresh.artist;
    const fields = $("track-detail-fields");
    fields.replaceChildren();
    for (const [label, value] of [
      ["专辑", fresh.album],
      ["专辑艺术家", fresh.album_artist],
      ["年份", fresh.year],
      ["流派", fresh.genre],
      ["音轨", fresh.number],
      ["格式", fresh.format],
      ["时长", time(fresh.duration)],
      ["信息来源", sourceLabel(fresh.metadata_source || "local")],
      ["标签歌词", embeddedLyricsLabel(fresh)],
    ]) {
      fields.append(el("dt", "", label), el("dd", "", value || "—"));
    }
    const start = el("button", "outline-button", "播放");
    start.addEventListener("click", () => {
      play(
        fresh,
        playlist.map((item) => (item.id === fresh.id ? fresh : item)),
      );
      $("track-dialog").close();
    });
    $("track-detail-actions").replaceChildren(
      start,
      ...trackActions(fresh, () => $("track-dialog").close()),
    );
    $("track-dialog").showModal();
  } catch (error) {
    toast(error.message);
  }
}
function jobSummary(job, open) {
  const box = el("div", "job-summary");
  const header = el("header");
  const title = el(open ? "button" : "h3", open ? "job-open" : "", job.phase);
  if (open) {
    title.setAttribute("aria-label", `任务详情 · ${job.phase}`);
    title.addEventListener("click", () => openJob(job.id));
  }
  header.append(
    title,
    el("time", "", new Date(job.started_at).toLocaleString()),
    el("span", "job-state", jobStates[job.state] || job.state),
  );
  box.append(
    header,
    el(
      "p",
      "",
      `已处理 ${job.processed} · 入库 ${job.imported} · 跳过重复 ${job.skipped} · ${job.errors?.length || 0} 条提示`,
    ),
  );
  return box;
}
function deleteJobButton(job) {
  const button = el("button", "text-button delete-job", "删除记录");
  button.disabled = job.state === "running";
  button.title = button.disabled
    ? "任务结束后可删除记录"
    : "仅删除任务记录，保留音乐文件和曲库";
  button.setAttribute("aria-label", `删除任务记录 · ${job.phase}`);
  button.dataset.actionKey = `delete-${job.id}`;
  button.addEventListener("click", async () => {
    button.disabled = true;
    state.jobsRequest++;
    try {
      await api(`/jobs/${encodeURIComponent(job.id)}`, { method: "DELETE" });
      if (!state.user) return;
      if (state.view === "job" && state.jobId === job.id) {
        state.jobId = null;
        await navigate("jobs");
      } else await loadJobs();
      toast("任务记录已删除，音乐库与文件已保留。");
    } catch (error) {
      toast(error.message);
      button.disabled = job.state === "running";
    }
  });
  return button;
}
function openJob(id) {
  state.jobId = id;
  const cached = state.jobs.find(job => job.id === id);
  $("job-detail-actions").replaceChildren();
  $("job-detail-summary").replaceChildren(...(cached ? [jobSummary(cached, false)] : []));
  $("job-warnings").replaceChildren(el("p", "muted", "正在加载提示条目…"));
  $("job-files").replaceChildren(el("p", "muted", "正在加载文件明细…"));
  $("job-warning-count").textContent = "";
  $("job-file-count").textContent = "";
  navigate("job");
}
async function loadJobDetail() {
  if (!state.user || state.view !== "job" || !state.jobId) return;
  const id = state.jobId;
  const generation = ++state.jobRequest;
  $("job-detail-status").textContent = "正在加载任务详情…";
  $("job-detail-retry").hidden = true;
  try {
    const job = await api(`/jobs/${encodeURIComponent(id)}`);
    if (!state.user || state.view !== "job" || state.jobId !== id || generation !== state.jobRequest) return;
    renderJobDetail(job);
    $("job-detail-status").textContent = "";
  } catch (error) {
    if (!state.user || state.view !== "job" || state.jobId !== id || generation !== state.jobRequest) return;
    $("job-detail-status").textContent = `任务详情加载失败：${error.message}`;
    $("job-detail-retry").hidden = false;
  }
}
$("job-detail-retry").addEventListener("click", () => loadJobDetail());
function scanScheduleControls() {
  const mode = $("scan-schedule-mode").value;
  $("scan-time-wrap").hidden = mode !== "daily";
  $("scan-schedule-time").disabled = mode !== "daily";
}
async function loadScanSchedule() {
  const generation = state.request;
  $("scan-schedule-mode").disabled = true;
  $("scan-schedule-save").disabled = true;
  try {
    const data = await api("/settings/scan");
    if (!state.user || state.view !== "settings" || generation !== state.request) return;
    $("scan-schedule-mode").value = data.settings.mode;
    $("scan-schedule-time").value = data.settings.time || "03:00";
    $("scan-schedule-zone").textContent = `按服务端本地时间 ${data.timezone} 执行。任务运行中会跳过重叠执行；保存后立即生效并在重启后保留。`;
    $("scan-schedule-error").textContent = "";
    scanScheduleControls();
  } catch (error) {
    if (state.user && state.view === "settings" && generation === state.request) $("scan-schedule-error").textContent = `执行计划读取失败：${error.message}`;
  } finally {
    if (generation === state.request) {
      $("scan-schedule-mode").disabled = false;
      $("scan-schedule-save").disabled = false;
    }
  }
}
$("scan-schedule-mode").addEventListener("change", scanScheduleControls);
$("scan-schedule").addEventListener("submit", async event => {
  event.preventDefault();
  $("scan-schedule-save").disabled = true;
  $("scan-schedule-status").textContent = "";
  try {
    await api("/settings/scan", { method: "PUT", body: JSON.stringify({
      mode: $("scan-schedule-mode").value,
      time: $("scan-schedule-time").value,
    }) });
    if (state.user) {
      $("scan-schedule-error").textContent = "";
      $("scan-schedule-status").textContent = "执行计划已保存。";
    }
  } catch (error) { if (state.user) $("scan-schedule-error").textContent = error.message; }
  finally { $("scan-schedule-save").disabled = false; }
});
function jobEntry(item, key, warning = false) {
  const entry = el("article", warning ? "job-item job-warning" : "job-item");
  const copy = el("div", "job-item-copy");
  copy.append(
    el(
      "strong",
      "",
      item.title
        ? `${item.title} · ${item.artist}`
        : item.filename || "任务提示",
    ),
  );
  if (item.filename && item.title)
    copy.append(el("small", "muted", item.filename));
  if (item.album || item.source || item.duration)
    copy.append(
      el(
        "small",
        "muted",
        [
          item.album,
          sourceLabel(item.source || "local"),
          item.duration > 0 ? `时长 ${time(item.duration)}` : "时长未知",
        ]
          .filter(Boolean)
          .join(" · "),
      ),
    );
  if (item.message) copy.append(el("p", "job-item-message", item.message));
  entry.append(copy);
  if (!warning)
    entry.append(el("span", "job-state", itemStates[item.state] || item.state));
  const actions = el("div", "track-actions");
  if (item.track_id) {
    trackActions({ id: item.track_id }).forEach((button, action) => {
      button.dataset.actionKey = `${key}-${action}`;
      actions.append(button);
    });
  } else {
    copy.append(
      el(
        "small",
        "muted",
        "尚未关联入库歌曲，可到音乐库查找后更正或刮削歌词。",
      ),
    );
    const find = el("button", "track-action", "查看音乐库");
    find.addEventListener("click", () => navigate("manage"));
    actions.append(find);
  }
  entry.append(actions);
  return entry;
}
function renderJobDetail(job) {
  $("job-detail-summary").replaceChildren(jobSummary(job, false));
  $("job-detail-actions").replaceChildren(deleteJobButton(job));
  const warnings = $("job-warnings"),
    files = $("job-files");
  warnings.replaceChildren();
  files.replaceChildren();
  $("job-warning-count").textContent = `${job.errors?.length || 0} 条`;
  $("job-file-count").textContent = `${job.items?.length || 0} 项`;
  for (const [index, message] of (job.errors || []).entries()) {
    // Only attach actions when the recorded message identifies a unique indexed song.
    const matches = (job.items || []).filter((item) =>
      item.message?.includes(message),
    );
    const item = matches.length === 1 ? matches[0] : {};
    warnings.append(
      jobEntry({ ...item, message }, `${job.id}-warning-${index}`, true),
    );
  }
  if (!job.errors?.length)
    warnings.append(el("p", "muted", "本次任务没有提示。"));
  for (const [index, item] of (job.items || []).entries())
    files.append(jobEntry(item, `${job.id}-file-${index}`));
  if (!job.items?.length)
    files.append(
      el("p", "muted", "暂无文件明细；旧版任务可能未记录逐文件信息。"),
    );
}
function renderJobSelection() {
  const deletable = state.jobs.filter((job) => job.state !== "running");
  const count = state.selectedJobs.size;
  $("jobs-select-all").checked =
    deletable.length > 0 && count === deletable.length;
  $("jobs-select-all").indeterminate = count > 0 && count < deletable.length;
  $("jobs-select-all").disabled = state.deletingJobs || !deletable.length;
  $("jobs-selection-count").textContent = `已选 ${count} 项`;
  $("jobs-delete-selected").disabled = state.deletingJobs || !count;
  $("jobs-delete-all").disabled = state.deletingJobs || !deletable.length;
  for (const input of document.querySelectorAll(".job-select")) {
    const job = state.jobs.find((item) => item.id === input.value);
    input.checked = state.selectedJobs.has(input.value);
    input.disabled = state.deletingJobs || job?.state === "running";
  }
}
$("jobs-select-all").addEventListener("change", (event) => {
  state.selectedJobs = new Set(
    event.target.checked
      ? state.jobs.filter((job) => job.state !== "running").map((job) => job.id)
      : [],
  );
  renderJobSelection();
});
async function deleteJobSelection(all) {
  if (state.deletingJobs) return;
  if (
    !confirm(
      all
        ? "删除全部已结束的任务记录？运行中的任务将保留，音乐文件和曲库不受影响。"
        : `删除所选 ${state.selectedJobs.size} 条任务记录？音乐文件和曲库不受影响。`,
    )
  )
    return;
  state.deletingJobs = true;
  state.jobsRequest++;
  renderJobSelection();
  try {
    const result = await api("/jobs", {
      method: "DELETE",
      body: JSON.stringify(
        all ? { all: true } : { ids: [...state.selectedJobs] },
      ),
    });
    state.selectedJobs.clear();
    await loadJobs();
    toast(
      `已删除 ${result.deleted} 条记录，音乐文件和曲库已保留。${result.skipped_running ? "运行中的任务已保留。" : ""}`,
    );
  } catch (error) {
    toast(error.message);
  } finally {
    state.deletingJobs = false;
    renderJobSelection();
  }
}
$("jobs-delete-selected").addEventListener("click", () =>
  deleteJobSelection(false),
);
$("jobs-delete-all").addEventListener("click", () => deleteJobSelection(true));
function renderScanButton() {
  const running = state.jobs.some(job => job.state === "running" &&
    (state.library === "cloud" ? job.library === "cloud" : job.library !== "cloud"));
  $("scan-button").disabled = running;
  $("scan-button").textContent = running ? "扫描进行中…" : "＋ 扫描音乐库";
  const organizing = state.jobs.some(job => job.state === "running" && job.library !== "cloud");
  $("jobs-scan-button").disabled = organizing;
  $("jobs-scan-button").textContent = organizing ? "任务进行中…" : "整理入库";
}
async function loadJobs() {
  const generation = ++state.jobsRequest;
  const data = await api("/jobs?summary=1");
  if (!state.user || generation !== state.jobsRequest) return;
  state.jobs = data.items;
  const deletableIDs = new Set(
    data.items.filter((job) => job.state !== "running").map((job) => job.id),
  );
  state.selectedJobs = new Set(
    [...state.selectedJobs].filter((id) => deletableIDs.has(id)),
  );
  const focused = document.activeElement?.dataset.actionKey;
  const list = $("jobs-list");
  list.replaceChildren();
  const running = data.items.some((job) => job.state === "running");
  renderScanButton();
  $("rescrape-button").disabled = running;
  $("job-dot").hidden = !running;
  if (!data.items.length)
    list.append(
      empty(
        "让第一首音乐，找到归处",
        "点击上方「整理入库」，开始识别和整理。支持 MP3、FLAC、M4A、WAV 等常见音频格式。",
      ),
    );
  for (const job of data.items) {
    const card = el("article", "job-card job-record");
    const select = el("input", "job-select");
    select.type = "checkbox";
    select.value = job.id;
    select.dataset.actionKey = `select-${job.id}`;
    select.setAttribute("aria-label", `选择任务记录 · ${job.phase}`);
    select.addEventListener("change", () => {
      if (select.checked) state.selectedJobs.add(job.id);
      else state.selectedJobs.delete(job.id);
      renderJobSelection();
    });
    const title = el("button", "job-open", job.phase);
    title.title = job.phase;
    title.setAttribute("aria-label", `任务详情 · ${job.phase}`);
    title.addEventListener("click", () => openJob(job.id));
    const date = el("time", "", new Date(job.started_at).toLocaleString());
    date.dateTime = job.started_at;
    const counts = el(
      "span",
      "job-counts",
      `处理 ${job.processed} · 入库 ${job.imported} · 跳过 ${job.skipped} · 提示 ${job.errors?.length || 0}`,
    );
    card.append(
      select,
      title,
      el("span", "job-state", jobStates[job.state] || job.state),
      date,
      counts,
      deleteJobButton(job),
    );
    card.addEventListener("click", (event) => {
      if (!event.target.closest("button, input, label")) openJob(job.id);
    });
    list.append(card);
  }
  renderJobSelection();
  if (state.view === "job") await loadJobDetail();
  if (focused)
    [...document.querySelectorAll("[data-action-key]")]
      .find(
        (node) =>
          node.dataset.actionKey === focused && !node.closest("[hidden]"),
      )
      ?.focus({ preventScroll: true });
}
async function startLibraryScan(organize = false) {
  $("scan-button").disabled = true;
  $("jobs-scan-button").disabled = true;
  try {
    if (!organize && state.library === "cloud") {
      await api("/cloud115/scan", { method: "POST", body: "{}" });
      toast("正在扫描本地 STRM，完成后刷新网盘音乐库。");
      await navigate("jobs");
      return;
    }
    await api(organize ? "/jobs/scan" : "/library/scan", { method: "POST", body: "{}" });
    toast(organize ? "整理入库已开始，音乐正在归位。" : "正在扫描本地音乐库，完成后更新索引。");
    await navigate("jobs");
  } catch (e) {
    toast(e.message);
    $("scan-button").disabled = false;
    $("jobs-scan-button").disabled = false;
  }
}
$("scan-button").addEventListener("click", () => startLibraryScan());
$("jobs-scan-button").addEventListener("click", () => startLibraryScan(true));
$("rescrape-button").addEventListener("click", async () => {
  $("rescrape-button").disabled = true;
  try {
    await api("/jobs/scan", { method: "POST", body: '{"rescrape":true}' });
    toast("重新刮削已开始，将重新读取标签并补全元数据。");
    await loadJobs();
  } catch (e) {
    toast(e.message);
    $("rescrape-button").disabled = false;
  }
});
function play(track, queue, autoplay = true) {
  const request = ++state.playbackRequest;
  state.linkRetried = false;
  state.playbackRequested = autoplay;
  state.playbackPosition = 0;
  state.current = track;
  state.queue = [...queue];
  renderPlaybackControls();
  renderQueue();
  audio.src = `/api/v1/tracks/${track.id}/stream`;
  audio.volume = Number($("volume").value);
  $("player-title").textContent = track.title;
  $("player-artist").textContent = track.artist;
  $("player-format").textContent = track.format;
  $("duration").textContent = time(track.duration);
  $("elapsed").textContent = "0:00";
  $("seek").value = "0";
  $("player-favorite").textContent = track.favorite ? "♥" : "♡";
  artwork($("player-art"), track);
  renderListeningTrack();
  listening.controller?.abort();
  listening.request++;
  listening.loadedFor = null;
  listening.lines = [];
  listening.active = -2;
  $("listening-lyrics-list").replaceChildren();
  if (listening.expanded) loadListeningLyrics();
  $("player-bar").hidden = false;
  document.body.classList.add("has-player");
  if ("mediaSession" in navigator)
    navigator.mediaSession.metadata = new MediaMetadata({
      title: track.title,
      artist: track.artist,
      album: track.album,
    });
  if (autoplay)
    audio
      .play()
      .catch(error => playbackRejected(error, request));
}
function playbackRejected(error, request) {
  if (request !== state.playbackRequest || !state.current || error.name === "AbortError" || audio.error) return;
  toast(error.name === "NotAllowedError" ? "浏览器阻止自动播放，请点击播放按钮。" : "播放未能开始，请重新点击播放。");
}

async function playbackFailed() {
  const track = state.current, request = state.playbackRequest;
  if (!track || state.playbackChecking === request) return;
  if (track.library === "cloud" && !state.linkRetried) {
    state.linkRetried = true;
    state.playbackChecking = request;
    const position = state.playbackPosition, requested = state.playbackRequested;
    try {
      // Inspect only the service response; never fetch CDN audio through CORS.
      const response = await fetch(`/api/v1/tracks/${track.id}/stream?refresh=1`, {
        redirect: "manual", credentials: "same-origin", signal: AbortSignal.timeout(15000),
      });
      if (response.type !== "opaqueredirect" && !response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || `播放地址请求失败 (${response.status})`);
      }
      if (state.current?.id !== track.id || request !== state.playbackRequest) return;
      audio.src = `/api/v1/tracks/${track.id}/stream`;
      audio.addEventListener("loadedmetadata", () => {
        if (request === state.playbackRequest && position > 0) audio.currentTime = position;
      }, { once: true });
      audio.load();
      if (requested) audio.play().catch(error => playbackRejected(error, request));
    } catch (error) {
      if (state.current?.id === track.id && request === state.playbackRequest)
        toast(`115 播放失败：${error.message}`);
    } finally {
      if (state.playbackChecking === request) state.playbackChecking = 0;
    }
    return;
  }
  toast(track.library === "cloud"
    ? "115 已返回播放地址，但音频加载失败。请检查浏览器网络、网盘访问权限或音频格式。"
    : "音频加载失败，请检查文件或浏览器的格式兼容性。");
}
function setExpanded(expanded, focus = true) {
  listening.expanded = Boolean(expanded && state.current);
  $("now-playing-view").hidden = !listening.expanded;
  document.body.classList.toggle("listening-open", listening.expanded);
  $("expand-player").setAttribute("aria-expanded", String(listening.expanded));
  $("expand-player").setAttribute(
    "aria-label",
    listening.expanded ? "收起海报与歌词" : "展开海报与歌词",
  );
  if (listening.expanded) {
    renderListeningTrack();
    loadListeningLyrics();
  }
  if (focus)
    $(listening.expanded ? "collapse-player" : "expand-player").focus({
      preventScroll: true,
    });
}
function renderListeningTrack() {
  if (!state.current) return;
  $("listening-title").textContent = state.current.title;
  $("listening-artist").textContent = state.current.artist;
  $("listening-album").textContent = state.current.album;
  artwork($("listening-art"), state.current);
  $("listening-record").classList.toggle("spinning", !audio.paused);
}
async function loadListeningLyrics(force = false) {
  const track = state.current;
  if (!track || (!force && listening.loadedFor === track.id)) return;
  listening.controller?.abort();
  const controller = new AbortController();
  listening.controller = controller;
  const generation = ++listening.request;
  listening.loadedFor = track.id;
  listening.lines = [];
  listening.active = -2;
  listening.manualUntil = 0;
  const list = $("listening-lyrics-list");
  list.replaceChildren();
  list.scrollTop = 0;
  $("listening-source").textContent = "正在读取歌词…";
  try {
    const response = await fetch(`/api/v1/tracks/${track.id}/lyrics`, {
      credentials: "same-origin",
      signal: controller.signal,
    });
    if (generation !== listening.request || state.current?.id !== track.id)
      return;
    if (response.status === 401) {
      showLogin();
      return;
    }
    if (response.status === 404) {
      $("listening-source").textContent = "暂无歌词";
      list.append(
        el(
          "p",
          "lyric-placeholder",
          "让旋律先行。可通过「歌词来源与获取」补全歌词。",
        ),
      );
      return;
    }
    if (!response.ok) throw new Error("歌词加载失败，可收起后重新展开以重试。");
    const text = await response.text();
    if (generation !== listening.request || state.current?.id !== track.id)
      return;
    const parsed = ResonaLyrics.parse(text);
    listening.lines = parsed.lines;
    $("listening-source").textContent =
      `${lyricsSourceLabel(response.headers.get("X-Lyrics-Source"), track)} · ${parsed.lines.length ? "同步歌词" : "纯文本歌词"}`;
    if (!parsed.lines.length)
      list.append(el("p", "plain-lyrics", parsed.plain));
    for (const line of parsed.lines) {
      const button = el("button", "lyric-line", line.text);
      button.setAttribute("aria-label", `${time(line.time)} ${line.text}`);
      button.addEventListener("click", () => {
        if (Number.isFinite(audio.duration))
          audio.currentTime = Math.min(line.time, audio.duration);
        listening.manualUntil = 0;
        updateListeningLyrics();
      });
      list.append(button);
    }
    updateListeningLyrics();
  } catch (error) {
    if (error.name !== "AbortError" && generation === listening.request) {
      listening.loadedFor = null;
      $("listening-source").textContent = error.message;
    }
  }
}
function updateListeningLyrics() {
  if (!listening.expanded || !listening.lines.length) return;
  const active = ResonaLyrics.activeAt(listening.lines, audio.currentTime);
  const list = $("listening-lyrics-list");
  if (active !== listening.active) {
    listening.active = active;
    [...list.children].forEach((node, index) => {
      const selected =
        active >= 0 &&
        listening.lines[index].time === listening.lines[active].time;
      node.classList.toggle("active", selected);
      if (selected) node.setAttribute("aria-current", "true");
      else node.removeAttribute("aria-current");
    });
  }
  if (active >= 0 && Date.now() >= listening.manualUntil) {
    const node = list.children[active];
    const top =
      node.getBoundingClientRect().top -
      list.getBoundingClientRect().top +
      list.scrollTop -
      list.clientHeight / 2 +
      node.clientHeight / 2;
    list.scrollTo({ top, behavior: "instant" });
  }
}
$("expand-player").addEventListener("click", () =>
  setExpanded(!listening.expanded),
);
$("collapse-player").addEventListener("click", () => setExpanded(false));
$("listening-details").addEventListener(
  "click",
  () => state.current && openTrackDetails(state.current),
);
$("listening-lyrics").addEventListener(
  "click",
  () => state.current && openLyrics(state.current),
);
for (const event of ["wheel", "touchstart", "pointerdown", "keydown"])
  $("listening-lyrics-list").addEventListener(
    event,
    () => {
      listening.manualUntil = Date.now() + 4000;
    },
    { passive: true },
  );
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !$("queue-panel").hidden) {
    setQueueOpen(false);
    return;
  }
  if (
    event.key === "Escape" &&
    listening.expanded &&
    !document.querySelector("dialog[open]")
  )
    setExpanded(false);
});
function skip(direction, ended = false) {
  if (!state.current || !state.queue.length) return;
  const index = ResonaPlayback.nextIndex(
    state.queue.length,
    state.queue.findIndex((track) => track.id === state.current.id),
    direction,
    state.repeatMode,
    ended,
  );
  if (index >= 0) play(state.queue[index], state.queue);
}
function readRepeatMode() {
  try {
    const mode = localStorage.getItem("resona.repeat");
    if (ResonaPlayback.modes.includes(mode)) return mode;
  } catch {}
  return "off";
}
function renderPlaybackControls() {
  const labels = {
    off: "顺序播放",
    all: "列表循环",
    one: "单曲循环",
    shuffle: "随机循环",
  };
  const mode = state.repeatMode;
  const nextMode =
    ResonaPlayback.modes[
      (ResonaPlayback.modes.indexOf(mode) + 1) % ResonaPlayback.modes.length
    ];
  $("repeat-mode").setAttribute(
    "aria-label",
    `${labels[mode]}，切换为${labels[nextMode]}`,
  );
  $("repeat-mode").title = `${labels[mode]}，点击切换为${labels[nextMode]}`;
  $("repeat-mode").setAttribute("aria-pressed", String(mode !== "off"));
  $("repeat-single").hidden = mode !== "one";
  $("repeat-symbol").setAttribute(
    "d",
    mode === "shuffle"
      ? "M3 5h3c5 0 7 14 12 14h3m-4-4 4 4-4 4M3 19h3c2 0 4-3 6-7s4-7 6-7h3m-4-4 4 4-4 4"
      : "m17 2 4 4-4 4M3 11V8a2 2 0 0 1 2-2h16M7 22l-4-4 4-4m14-1v3a2 2 0 0 1-2 2H3",
  );
  $("queue-toggle").disabled = !state.queue.length;
  $("queue-toggle").setAttribute(
    "aria-label",
    `播放列表 · ${state.queue.length} 首`,
  );
  $("queue-badge").textContent = state.queue.length;
  const current = state.queue.findIndex(
    (track) => track.id === state.current?.id,
  );
  for (const [id, direction] of [
    ["previous", -1],
    ["next", 1],
  ]) {
    $(id).disabled =
      ResonaPlayback.nextIndex(state.queue.length, current, direction, mode) <
      0;
  }
}
function renderQueue() {
  $("queue-count").textContent =
    `共 ${state.queue.length} 首 · 点击歌曲切换播放`;
  if ($("queue-panel").hidden) return;
  const list = $("queue-list");
  const scroll = list.scrollTop;
  const focused = document.activeElement?.dataset.queueId;
  list.replaceChildren();
  state.queue.forEach((track, index) => {
    const row = el("button", "queue-item");
    row.dataset.queueId = track.id;
    row.setAttribute("aria-label", `播放 ${track.title} · ${track.artist}`);
    if (track.id === state.current?.id)
      row.setAttribute("aria-current", "true");
    const cover = el("span", "queue-art");
    artwork(cover, track, index);
    const copy = el("span", "queue-copy");
    copy.append(el("strong", "", track.title), el("small", "", track.artist));
    row.append(
      el("span", "queue-number", String(index + 1).padStart(2, "0")),
      cover,
      copy,
      el("span", "track-time", time(track.duration)),
    );
    row.addEventListener("click", () => play(track, state.queue));
    list.append(row);
  });
  list.scrollTop = scroll;
  if (focused)
    [...list.children]
      .find((row) => row.dataset.queueId === focused)
      ?.focus({ preventScroll: true });
}
function setQueueOpen(open, focus = true) {
  open = Boolean(open && state.queue.length && state.user);
  $("queue-panel").hidden = !open;
  $("queue-toggle").setAttribute("aria-expanded", String(open));
  if (open) {
    renderQueue();
    const current =
      $("queue-list").querySelector("[aria-current]") ||
      $("queue-list").firstElementChild;
    if (focus) current?.focus({ preventScroll: true });
    current?.scrollIntoView({ block: "nearest" });
  } else if (focus && !$("player-bar").hidden)
    $("queue-toggle").focus({ preventScroll: true });
}
$("repeat-mode").addEventListener("click", () => {
  state.repeatMode =
    ResonaPlayback.modes[
      (ResonaPlayback.modes.indexOf(state.repeatMode) + 1) %
        ResonaPlayback.modes.length
    ];
  try {
    localStorage.setItem("resona.repeat", state.repeatMode);
  } catch {}
  renderPlaybackControls();
  toast(
    { off: "顺序播放", all: "列表循环", one: "单曲循环", shuffle: "随机循环" }[
      state.repeatMode
    ],
  );
});
$("queue-toggle").addEventListener("click", () =>
  setQueueOpen($("queue-panel").hidden),
);
$("queue-close").addEventListener("click", () => setQueueOpen(false));
document.addEventListener("pointerdown", (event) => {
  if (
    !$("queue-panel").hidden &&
    !$("queue-panel").contains(event.target) &&
    !$("queue-toggle").contains(event.target)
  )
    setQueueOpen(false, false);
});
const playerResize = new ResizeObserver(() => {
  if (!$("player-bar").hidden)
    document.documentElement.style.setProperty(
      "--player-height",
      `${$("player-bar").getBoundingClientRect().height}px`,
    );
});
playerResize.observe($("player-bar"));
renderPlaybackControls();
function resetSelection() {
  state.selecting = false;
  state.selected.clear();
  state.bulkBusy = false;
  state.bulkToken++;
  renderBulkControls();
}
function renderBulkControls() {
  $("library-actions").hidden = state.view !== "tracks";
  $("select-tracks").textContent = state.selecting ? "完成选择" : "选择歌曲";
  $("select-tracks").setAttribute("aria-pressed", String(state.selecting));
  $("selection-controls").hidden = !state.selecting;
  $("selection-count").textContent = `全选 · 已选 ${state.selected.size} 首`;
  if (!state.bulkBusy) {
    $("select-all-tracks").checked =
      state.total > 0 && state.selected.size === state.total;
    $("select-all-tracks").indeterminate =
      state.selected.size > 0 && state.selected.size < state.total;
  }
  $("select-all-tracks").disabled = state.bulkBusy || !state.total;
  for (const id of ["play-all", "enqueue-all", "shuffle-all"])
    $(id).disabled =
      state.bulkBusy || (state.selecting ? !state.selected.size : !state.total);
  $("select-tracks").disabled = state.bulkBusy || !state.total;
  $("play-library").disabled = state.bulkBusy;
  $("library-action-status").textContent = state.bulkBusy
    ? "正在加载歌曲…"
    : "";
}
async function bulkAction(action, entireLibrary = false) {
  if (state.bulkBusy) return;
  const token = ++state.bulkToken;
  const generation = state.request;
  const search = $("search").value.trim();
  const valid = () =>
    state.user &&
    token === state.bulkToken &&
    generation === state.request &&
    search === $("search").value.trim();
  state.bulkBusy = true;
  renderBulkControls();
  try {
    let items =
      !entireLibrary && state.selecting && action !== "select"
        ? [...state.selected.values()]
        : null;
    if (items === null) {
      items = [];
      const params = new URLSearchParams({
        limit: "500",
        search: entireLibrary ? "" : search,
        library: state.library,
      });
      if (!entireLibrary)
        for (const key of ["album", "artist"])
          if (state.filter[key]) params.set(key, state.filter[key]);
      let total;
      do {
        params.set("offset", String(items.length));
        const page = await api("/tracks?" + params);
        if (!valid()) return;
        total = page.total;
        if (!page.items.length) break;
        items.push(...page.items);
      } while (items.length < total);
    }
    if (!valid()) return;
    if (!items.length) return toast("没有可播放的歌曲。");
    if (action === "select") {
      state.selected = new Map(items.map((track) => [track.id, track]));
      renderTracks();
    } else if (action === "append") {
      const queue = ResonaPlayback.appendUnique(state.queue, items);
      const added = queue.length - state.queue.length;
      if (!state.current) play(queue[0], queue, false);
      else {
        state.queue = queue;
        renderPlaybackControls();
        renderQueue();
      }
      toast(
        added
          ? `已加入 ${added} 首歌曲，当前播放保持不变。`
          : "这些歌曲已在播放列表中。",
      );
    } else {
      const queue =
        action === "shuffle" ? ResonaPlayback.shuffled(items) : items;
      play(queue[0], queue);
    }
  } catch (error) {
    if (valid()) toast(error.message);
  } finally {
    if (token === state.bulkToken) {
      state.bulkBusy = false;
      renderBulkControls();
    }
  }
}
$("play-library").addEventListener("click", () => bulkAction("play", true));
$("play-all").addEventListener("click", () => bulkAction("play"));
$("enqueue-all").addEventListener("click", () => bulkAction("append"));
$("shuffle-all").addEventListener("click", () => bulkAction("shuffle"));
$("select-tracks").addEventListener("click", () => {
  state.selecting = !state.selecting;
  state.selected.clear();
  renderTracks();
  renderBulkControls();
});
$("select-all-tracks").addEventListener("change", () => {
  if ($("select-all-tracks").checked) bulkAction("select");
  else {
    state.selected.clear();
    renderTracks();
    renderBulkControls();
  }
});
$("play-pause").addEventListener("click", () => {
  if (audio.paused) audio.play().catch((e) => toast(e.message));
  else audio.pause();
});
$("previous").addEventListener("click", () => skip(-1));
$("next").addEventListener("click", () => skip(1));
$("player-favorite").addEventListener("click", () => {
  if (state.current)
    toggleFavorite(state.current)
      .then(renderTracks)
      .catch((e) => toast(e.message));
});
$("volume").addEventListener("input", () => {
  audio.volume = Number($("volume").value);
});
$("seek").addEventListener("input", () => {
  if (Number.isFinite(audio.duration))
    audio.currentTime = (Number($("seek").value) / 1000) * audio.duration;
});
audio.addEventListener("play", () => {
  state.playbackRequested = true;
  $("play-pause").textContent = "Ⅱ";
  $("play-pause").setAttribute("aria-label", "暂停");
  $("listening-record").classList.add("spinning");
});
audio.addEventListener("pause", () => {
  if (!audio.error) state.playbackRequested = false;
  $("play-pause").textContent = "▶";
  $("play-pause").setAttribute("aria-label", "播放");
  $("listening-record").classList.remove("spinning");
});
audio.addEventListener("ended", () => skip(1, true));
audio.addEventListener("error", playbackFailed);
audio.addEventListener("timeupdate", () => {
  if (Number.isFinite(audio.currentTime) && !audio.error) state.playbackPosition = audio.currentTime;
  updateListeningLyrics();
  $("elapsed").textContent = time(audio.currentTime);
  if (Number.isFinite(audio.duration) && audio.duration > 0) {
    $("duration").textContent = time(audio.duration);
    $("seek").value = String((audio.currentTime / audio.duration) * 1000);
  }
});
if ("mediaSession" in navigator) {
  for (const [action, handler] of [
    ["play", () => audio.play().catch((e) => toast(e.message))],
    ["pause", () => audio.pause()],
    ["previoustrack", () => skip(-1)],
    ["nexttrack", () => skip(1)],
  ])
    navigator.mediaSession.setActionHandler(action, handler);
}
async function bootstrap() {
  try {
    const status = await api("/auth/status");
    authMode(status);
    if (status.initialized) {
      try {
        await api("/auth/session");
        await enter();
      } catch {
        showLogin();
      }
    } else showLogin();
  } catch (e) {
    $("login-error").textContent = "无法连接服务器，请刷新页面重试。";
    $("login-button").textContent = "连接失败";
  }
}
document.addEventListener("DOMContentLoaded", bootstrap);
