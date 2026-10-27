"use strict";
function cloudError(message) {
  $("cloud-error").textContent = message;
  $("cloud-probe-error").textContent = message;
}
const cloud115 = {
  timer: null,
  authTimer: null,
  generation: 0,
  authGeneration: 0,
  progressRequest: 0,
  authLoading: false,
  offset: 0,
  folder: "0",
  busy: false,
  syncBusy: false,
  probeBusy: false,
  syncStopping: false,
  probeStopping: false,
  enabled: false,
  requesting: false,
  connected: false,
  accountID: "",
  profileRequest: 0,
  profileLoading: false,
  profile: null,
  folderRequest: 0,
  pathRequest: 0,
  folderLoading: false,
  folderData: null,
  folderPage: 0,
  stop() {
    this.generation++;
    this.authGeneration++;
    this.authLoading = false;
    this.profileRequest++;
    this.profileLoading = false;
    this.pathRequest++;
    this.pathAbort?.abort();
    this.closeFolders();
    clearTimeout(this.timer);
    clearTimeout(this.authTimer);
    $("cloud-auth").close();
  },
  controls() {
    for (const node of document.querySelectorAll("#cloud-form input, #cloud-form select, #cloud-form button"))
      node.disabled = this.busy || this.requesting;
    $("cloud-sync").disabled = this.syncBusy || this.requesting || !this.connected || !this.enabled;
    $("cloud-download-lyrics").disabled = this.syncBusy || this.requesting;
    $("cloud-sync-time").disabled = this.busy || this.requesting || $("cloud-sync-mode").value !== "daily";
    $("cloud-browse").disabled = this.busy || this.requesting || !this.connected;
    $("cloud-folder-use").disabled = this.folderLoading || !this.folderData || this.busy || this.requesting || !this.connected;
    $("cloud-go-tasks").disabled = false;
    $("cloud-probe").disabled = this.syncBusy || this.requesting || !this.connected || !this.enabled;
    $("cloud-retry").disabled = this.syncBusy || this.requesting || !this.connected || !this.enabled;
    for (const [id, busy, stopping] of [["cloud-sync-stop", this.syncBusy, this.syncStopping], ["cloud-probe-stop", this.probeBusy, this.probeStopping]]) {
      $(id).hidden = !busy;
      $(id).disabled = stopping;
      $(id).textContent = stopping ? "正在终止…" : id === "cloud-sync-stop" ? "终止生成" : "终止预探测";
    }
    $("cloud-disconnect").disabled = this.busy || !this.connected;
    $("cloud-account-refresh").disabled = this.profileLoading || !this.connected;
    $("cloud-authorize").disabled = this.busy || this.authLoading;
    $("cloud-auth-refresh").disabled = this.busy || this.authLoading;
    $("cloud-auth-methods").disabled = this.busy || this.authLoading;
    $("cloud-download-http-hint").textContent = $("cloud-download-http").value === "true"
      ? "HTTP 会明文传输 115 Cookie，仅在信任的网络中启用。"
      : "仅影响地址获取，播放仍通过主端口 302 跳转。";
  },
  async load(settings = false, append = false) {
    if (!state.user || !["cloud115", "probe"].includes(state.view)) return;
    const generation = ++this.generation;
    clearTimeout(this.timer);
    try {
      const data = await api("/cloud115?" + new URLSearchParams({
        state: $("cloud-state").value, offset: append ? String(this.offset) : "0", limit: "100",
      }));
      if (generation !== this.generation || !state.user || !["cloud115", "probe"].includes(state.view)) return;
      const generated = this.lastSync !== data.last_sync && data.last_sync && !data.last_sync.startsWith("0001");
      this.lastSync = data.last_sync;
      const refreshLibrary = (generated || this.syncBusy) && !data.sync_busy;
      this.enabled = data.settings.enabled;
      this.applyProgress(data);
      if (settings) {
        $("cloud-base-url").value = data.settings.base_url || window.location.origin;
        $("cloud-root-id").value = data.settings.root_id || "0";
        const schedule = data.settings.sync_schedule || { mode: data.settings.interval_minutes > 0 ? "daily" : "manual", time: "03:00" };
        $("cloud-sync-mode").value = schedule.mode;
        $("cloud-sync-time").value = schedule.time || "03:00";
        $("cloud-sync-zone").textContent = `按服务端本地时间 ${data.timezone} 执行。`;
        this.pathRequest++;
        $("cloud-root-path").value = data.settings.root_id === "0" || !data.settings.root_id
          ? "/" : data.settings.root_path?.startsWith("/") ? data.settings.root_path : "";
        $("cloud-root-path").title = $("cloud-root-path").value;
        $("cloud-enabled").checked = data.settings.enabled;
        $("cloud-download-lyrics").checked = data.settings.download_lyrics === true;
        $("cloud-download-http").value = String(data.settings.download_http === true);
      }
      const changedAccount = this.accountID !== data.account;
      this.accountID = data.account;
      if (changedAccount || !data.connected) this.profile = null;
      this.renderAccount(data);
      if (settings && data.connected && !$("cloud-root-path").value && state.view === "cloud115") void this.resolveFolder();
      if (data.connected && state.view === "cloud115" && (settings || changedAccount)) void this.loadAccount();
      const counts = data.counts;
      $("cloud-progress").textContent = [
        `已索引 ${Object.values(counts).reduce((sum, count) => sum + count, 0) - (counts.missing || 0) - (counts.skipped || 0)} 首`,
        `已准备 ${counts.ready || 0} 首`,
        `待探测 ${(counts.pending || 0) + (counts.probing || 0)} 首`,
        `失败 ${counts.failed || 0} 首`,
        `已跳过 ${counts.skipped || 0} 首`,
        data.last_sync && !data.last_sync.startsWith("0001") ? `上次同步 ${new Date(data.last_sync).toLocaleString()}` : "",
      ].filter(Boolean).join(" · ");
      if (!append) $("cloud-items").replaceChildren();
      const labels = { pending: "待探测", probing: "探测中", ready: "已准备", failed: "探测失败", missing: "来源失效", skipped: "已跳过" };
      for (const item of data.items) {
        const row = el("tr");
        const name = el("td");
        name.append(el("strong", "", item.name), el("small", "muted", item.path));
        const status = el("td");
        status.append(el("span", "", item.queued && item.track_id !== data.probe_current ? "排队中" : labels[item.state] || item.state));
        if (item.error) status.append(el("small", "form-error", item.error));
        const action = el("td");
        if (item.state !== "missing") {
          const retry = el("button", "text-button", item.state === "ready" ? "重新探测" : "重试");
          retry.type = "button";
          retry.disabled = data.sync_busy || item.queued || !data.connected || !data.settings.enabled;
          retry.addEventListener("click", () => this.task("retry", item.track_id));
          action.append(retry);
        }
        row.append(name, status, action);
        $("cloud-items").append(row);
      }
      this.offset = (append ? this.offset : 0) + data.items.length;
      if (!this.offset) {
        const row = el("tr"), cell = el("td", "muted", "暂无文件。连接账号后，指定音乐目录并开始同步。");
        cell.colSpan = 3;
        row.append(cell);
        $("cloud-items").append(row);
      }
      $("cloud-more").hidden = this.offset >= data.total;
      cloudError("");
      this.controls();
      if (data.busy) this.timer = setTimeout(() => this.poll(generation), 1000);
      if (refreshLibrary) await loadSystem();
    } catch (error) {
      if (generation === this.generation) {
        cloudError(error.message);
        if (this.busy) this.timer = setTimeout(() => this.poll(generation), 3000);
      }
    }
  },
  applyProgress(data) {
    this.busy = data.busy;
    this.syncBusy = data.sync_busy;
    this.probeBusy = data.probe_busy;
    this.syncStopping = data.sync_stopping;
    this.probeStopping = data.probe_stopping;
    this.connected = data.connected;
    document.querySelector(".account-sheet").dataset.connected = String(data.connected);
    if (data.enabled !== undefined) this.enabled = data.enabled;
    $("cloud-sync-progress").textContent = data.message || "等待生成 · 生成后自动刷新网盘音乐库";
    $("cloud-probe-progress").textContent = [
      data.probe_message || "等待预探测",
      `当前 ${data.probe_current ? "1" : "0"} 首 · 排队 ${data.probe_queued || 0} 首`,
    ].join(" · ");
    this.controls();
  },
  renderAccount(data) {
    const profile = this.profile;
    $("cloud-account").textContent = data.connected ? "已连接" : data.account ? "登录已失效" : "尚未连接";
    $("cloud-account-name").textContent = data.connected ? profile?.name || data.account_name || data.account : "连接 115 账号";
    $("cloud-identity-note").textContent = data.connected ? "115 账号已连接，Cookie 仅保存在服务器" : data.account ? "请重新扫码登录，已有索引将保留。" : "使用 115 客户端扫码登录，无需应用 ID。";
    $("cloud-membership").hidden = !data.connected || !profile?.membership;
    $("cloud-membership").textContent = profile?.membership || "";
    $("cloud-avatar").hidden = !data.connected || !profile?.avatar;
    if (profile?.avatar) $("cloud-avatar").src = profile.avatar;
    else $("cloud-avatar").removeAttribute("src");
    $("cloud-authorize").hidden = data.connected;
    $("cloud-disconnect").hidden = !data.connected;
    $("cloud-account-refresh").hidden = !data.connected;
    document.querySelector("#cloud115-view .storage").hidden = !data.connected;
    const space = data.connected && profile?.space;
    for (const id of ["cloud-storage-values", "cloud-storage-meter", "cloud-storage-used", "cloud-storage-remaining"]) $(id).hidden = !space;
    $("cloud-storage-note").hidden = !!space;
    $("cloud-storage-note").textContent = this.profileLoading ? "正在读取会员与容量资料…" : "容量暂时无法读取，已有设置与任务仍可使用。";
    $("cloud-generation-login-hint").hidden = data.connected;
    if (space) {
      const bytes = value => {
        const units = ["B", "KB", "MB", "GB", "TB", "PB"];
        const index = Math.min(Math.floor(Math.log(Math.max(1, value)) / Math.log(1024)), units.length - 1);
        return `${(value / 1024 ** index).toFixed(index ? 2 : 0)} ${units[index]}`;
      };
      const percent = Math.min(100, Math.max(0, space.used / space.total * 100));
      $("cloud-storage-values").replaceChildren(el("strong", "", bytes(space.used)), el("span", "separator", "/"), document.createTextNode(bytes(space.total)));
      $("cloud-storage-meter").setAttribute("aria-valuenow", percent.toFixed(1));
      $("cloud-storage-meter").firstElementChild.style.width = `${percent}%`;
      $("cloud-storage-used").textContent = `已使用 ${percent.toFixed(1)}%`;
      $("cloud-storage-remaining").textContent = `剩余 ${bytes(space.remaining)}`;
    }
  },
  async loadAccount() {
    const request = ++this.profileRequest, account = this.accountID;
    this.profileLoading = true;
    this.controls();
    $("cloud-storage-note").textContent = "正在读取会员与容量资料…";
    try {
      const data = await api("/cloud115/account", { signal: AbortSignal.timeout(15000) });
      if (request !== this.profileRequest || !state.user || !this.connected || this.accountID !== account) return;
      this.profile = data;
    } catch (error) {
      if (request !== this.profileRequest || !state.user || this.accountID !== account) return;
      toast(`115 资料读取失败：${error.message}`);
    } finally {
      if (request === this.profileRequest) {
        this.profileLoading = false;
        this.renderAccount({ account: this.accountID, account_name: $("cloud-account-name").textContent, connected: this.connected });
        this.controls();
      }
    }
  },
  async poll(generation = this.generation) {
    if (generation !== this.generation || !state.user || !["cloud115", "probe"].includes(state.view)) return;
    clearTimeout(this.timer);
    const request = ++this.progressRequest;
    try {
      const data = await api("/cloud115/progress", { signal: AbortSignal.timeout(15000) });
      if (generation !== this.generation || !state.user || !["cloud115", "probe"].includes(state.view)) return;
      if (request !== this.progressRequest) return;
      const finished = (this.syncBusy && !data.sync_busy) || (this.probeBusy && !data.probe_busy);
      this.applyProgress(data);
      cloudError("");
      if (finished) {
        void loadSystem().catch(error => {
          if (generation === this.generation && state.user && ["cloud115", "probe"].includes(state.view))
            cloudError(`音乐库统计刷新失败：${error.message}`);
        });
        void this.load();
      } else if (data.busy) this.timer = setTimeout(() => this.poll(generation), 1000);
    } catch (error) {
      if (generation !== this.generation || !state.user || !["cloud115", "probe"].includes(state.view)) return;
      if (request !== this.progressRequest) return;
      cloudError(`状态读取失败：${error.message}，正在重试；后台任务继续运行。`);
      this.timer = setTimeout(() => this.poll(generation), 3000);
    }
  },
  async task(action, trackID = "") {
    const generation = this.generation;
    this.requesting = true;
    this.controls();
    try {
      const body = { track_id: trackID };
      if (action === "sync") body.download_lyrics = $("cloud-download-lyrics").checked;
      await api(`/cloud115/${action}`, { method: "POST", body: JSON.stringify(body), signal: AbortSignal.timeout(15000) });
      if (generation !== this.generation || !state.user || !["cloud115", "probe"].includes(state.view)) return;
      this.busy = true;
      if (action === "sync") {
        this.syncBusy = true;
        $("cloud-sync-progress").textContent = "任务已启动，正在后台运行；可离开页面。";
      } else this.probeBusy = true;
      void this.poll(generation);
    } catch (error) {
      if (generation === this.generation && state.user && ["cloud115", "probe"].includes(state.view)) {
        cloudError(error.message);
        void this.poll(generation);
      }
    } finally {
      this.requesting = false;
      this.controls();
    }
  },
  async terminate(task) {
    const generation = this.generation;
    const key = task === "sync" ? "syncStopping" : "probeStopping";
    this.progressRequest++;
    this[key] = true;
    this.controls();
    try {
      await api(`/cloud115/${task}/stop`, { method: "POST", body: "{}", signal: AbortSignal.timeout(15000) });
      if (generation === this.generation) void this.poll(generation);
    } catch (error) {
      if (generation !== this.generation || !state.user || !["cloud115", "probe"].includes(state.view)) return;
      this[key] = false;
      cloudError(`终止请求失败：${error.message}，请重试。`);
      this.controls();
    }
  },
  closeFolders() {
    this.folderRequest++;
    this.folderAbort?.abort();
    this.folderLoading = false;
    $("cloud-directory-browser").close();
  },
  async resolveFolder() {
    const request = ++this.pathRequest, parent = $("cloud-root-id").value, account = this.accountID;
    this.pathAbort?.abort();
    this.pathAbort = new AbortController();
    try {
      const data = await api("/cloud115/folders?parent=" + encodeURIComponent(parent), { signal: this.pathAbort.signal });
      if (request !== this.pathRequest || parent !== $("cloud-root-id").value || account !== this.accountID || !state.user || state.view !== "cloud115") return;
      $("cloud-root-path").value = data.path;
      $("cloud-root-path").title = data.path;
    } catch (error) {
      if (request === this.pathRequest && state.user && state.view === "cloud115") cloudError(`音乐目录路径读取失败，请重新选择目录。${error.message}`);
    }
  },
  async folders(parent) {
    const request = ++this.folderRequest;
    this.folderAbort?.abort();
    this.folderAbort = new AbortController();
    this.folder = parent;
    this.folderLoading = true;
    this.folderData = null;
    $("cloud-directory-error").textContent = "";
    $("cloud-folder-retry").hidden = true;
    $("cloud-folder-count").textContent = "正在读取目录…";
    $("cloud-folder-prev").disabled = $("cloud-folder-next").disabled = true;
    $("cloud-folders").setAttribute("aria-busy", "true");
    $("cloud-folders").replaceChildren(el("p", "directory-empty", "正在读取文件夹…"));
    this.controls();
    try {
      const data = await api("/cloud115/folders?parent=" + encodeURIComponent(parent), { signal: this.folderAbort.signal });
      if (request !== this.folderRequest || !$("cloud-directory-browser").open || !state.user || state.view !== "cloud115") return;
      this.folderData = data;
      this.folderPage = 0;
      $("cloud-folder-path").replaceChildren();
      for (const [index, part] of data.breadcrumbs.entries()) {
        const button = el("button", "", part.name);
        button.type = "button";
        if (index === data.breadcrumbs.length - 1) button.setAttribute("aria-current", "location");
        button.addEventListener("click", () => this.folders(part.id));
        if (index) $("cloud-folder-path").append(managementIcon("chevron"));
        $("cloud-folder-path").append(button);
      }
      this.renderFolders();
    } catch (error) {
      if (request !== this.folderRequest || !$("cloud-directory-browser").open) return;
      $("cloud-directory-error").textContent = error.message;
      $("cloud-folder-retry").hidden = false;
      $("cloud-folder-count").textContent = "读取失败";
      $("cloud-folders").replaceChildren(el("p", "directory-empty", "目录暂不可用，请重试或从全部文件重新选择。"));
    } finally {
      if (request === this.folderRequest) {
        this.folderLoading = false;
        $("cloud-folders").setAttribute("aria-busy", "false");
        this.controls();
      }
    }
  },
  renderFolders() {
    const items = this.folderData.items, start = this.folderPage * 50;
    $("cloud-folders").replaceChildren();
    for (const folder of items.slice(start, start + 50)) {
      const button = el("button", "cloud-folder-entry");
      button.append(managementIcon("folder"), el("span", "", folder.name), managementIcon("chevron"));
      button.type = "button";
      button.addEventListener("click", () => this.folders(folder.id));
      $("cloud-folders").append(button);
    }
    if (!items.length) $("cloud-folders").append(el("p", "directory-empty", "此目录没有子文件夹，可直接选择当前目录。"));
    $("cloud-folders").scrollTop = 0;
    $("cloud-folder-count").textContent = `第 ${this.folderPage + 1} / ${Math.max(1, Math.ceil(items.length / 50))} 页 · 共 ${items.length} 个文件夹`;
    $("cloud-folder-prev").disabled = this.folderPage === 0;
    $("cloud-folder-next").disabled = start + 50 >= items.length;
  },
  async authorize() {
    clearTimeout(this.authTimer);
    const generation = ++this.authGeneration;
    this.authLoading = true;
    this.controls();
    if (!$("cloud-auth").open) $("cloud-auth").showModal();
    $("cloud-qr").hidden = true;
    $("cloud-auth-link").hidden = true;
    $("cloud-auth-state").textContent = "正在获取二维码…";
    const clientType = document.querySelector('input[name="cloud-client-type"]:checked').value;
    try {
      const data = await api("/cloud115/auth", { method: "POST", body: JSON.stringify({ client_type: clientType }) });
      if (generation !== this.authGeneration || !state.user || !["cloud115", "probe"].includes(state.view)) return;
      $("cloud-qr").src = "/api/v1/cloud115/auth/qr?" + Date.now();
      $("cloud-qr").hidden = false;
      $("cloud-auth-link").href = data.url;
      $("cloud-auth-link").hidden = false;
      $("cloud-auth-state").textContent = "等待扫码，请使用 115 客户端。";
      this.authTimer = setTimeout(() => this.pollAuth(generation), 2500);
    } catch (error) {
      if (generation === this.authGeneration) $("cloud-auth-state").textContent = error.message + "，请刷新二维码重试。";
    } finally {
      if (generation === this.authGeneration) {
        this.authLoading = false;
        this.controls();
      }
    }
  },
  async pollAuth(generation) {
    if (generation !== this.authGeneration || !state.user || !["cloud115", "probe"].includes(state.view)) return;
    try {
      const data = await api("/cloud115/auth");
      if (generation !== this.authGeneration) return;
      if (data.status === 2) {
        $("cloud-auth").close();
        toast("115 登录成功。启用音源并保存后即可同步。");
        await this.load();
        if (!this.profileLoading) void this.loadAccount();
        return;
      }
      if (data.status < 0) throw new Error(data.status === -2 ? "登录已取消，请刷新二维码重试。" : "二维码已过期，请刷新二维码重试。");
      $("cloud-auth-state").textContent = data.status === 1 ? "已扫码，请在 115 中确认登录。" : "等待扫码，请使用 115 客户端。";
      this.authTimer = setTimeout(() => this.pollAuth(generation), 2500);
    } catch (error) {
      if (generation === this.authGeneration) $("cloud-auth-state").textContent = error.message;
    }
  },
};
$("cloud-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  cloud115.busy = true;
  cloud115.controls();
  try {
    await api("/cloud115", { method: "PUT", body: JSON.stringify({
      root_id: $("cloud-root-id").value.trim(),
      root_path: $("cloud-root-path").value,
      base_url: $("cloud-base-url").value.trim() || window.location.origin, enabled: $("cloud-enabled").checked,
      sync_schedule: { mode: $("cloud-sync-mode").value, time: $("cloud-sync-time").value },
      download_lyrics: $("cloud-download-lyrics").checked,
      download_http: $("cloud-download-http").value === "true",
    }) });
    toast("115 设置已保存");
    await cloud115.load();
  } catch (error) {
    cloudError(error.message);
    cloud115.busy = false;
    cloud115.controls();
  }
});
$("cloud-authorize").addEventListener("click", () => cloud115.authorize());
$("cloud-auth-refresh").addEventListener("click", () => cloud115.authorize());
$("cloud-auth-methods").addEventListener("change", () => cloud115.authorize());
$("cloud-auth-cancel").addEventListener("click", () => {
  clearTimeout(cloud115.authTimer);
  cloud115.authGeneration++;
  cloud115.authLoading = false;
  $("cloud-auth").close();
  cloud115.controls();
});
$("cloud-auth").addEventListener("cancel", event => {
  event.preventDefault();
  $("cloud-auth-cancel").click();
});
$("cloud-disconnect").addEventListener("click", async () => {
  try { await api("/cloud115/disconnect", { method: "POST", body: "{}" }); cloud115.stop(); await cloud115.load(true); }
  catch (error) { cloudError(error.message); }
});
$("cloud-sync-stop").addEventListener("click", () => cloud115.terminate("sync"));
$("cloud-probe-stop").addEventListener("click", () => cloud115.terminate("probe"));
$("cloud-sync").addEventListener("click", () => cloud115.task("sync"));
$("cloud-probe").addEventListener("click", () => cloud115.task("probe"));
$("cloud-retry").addEventListener("click", () => cloud115.task("retry"));
$("cloud-refresh").addEventListener("click", () => cloud115.load());
$("cloud-state").addEventListener("change", () => cloud115.load());
$("cloud-more").addEventListener("click", () => cloud115.load(false, true));
$("cloud-sync-mode").addEventListener("change", () => cloud115.controls());
$("cloud-download-http").addEventListener("change", () => cloud115.controls());
$("cloud-browse").addEventListener("click", () => {
  $("cloud-folder-path").replaceChildren();
  const root = el("button", "", "全部文件");
  root.type = "button";
  root.addEventListener("click", () => cloud115.folders("0"));
  $("cloud-folder-path").append(root);
  $("cloud-directory-browser").showModal();
  void cloud115.folders($("cloud-root-id").value || "0");
});
$("cloud-directory-close").addEventListener("click", () => cloud115.closeFolders());
$("cloud-directory-browser").addEventListener("cancel", event => {
  event.preventDefault();
  cloud115.closeFolders();
});
$("cloud-folder-retry").addEventListener("click", () => cloud115.folders(cloud115.folder));
$("cloud-folder-prev").addEventListener("click", () => { cloud115.folderPage--; cloud115.renderFolders(); });
$("cloud-folder-next").addEventListener("click", () => { cloud115.folderPage++; cloud115.renderFolders(); });
$("cloud-account-refresh").addEventListener("click", () => cloud115.loadAccount());
$("cloud-avatar").addEventListener("error", () => { $("cloud-avatar").hidden = true; });
$("cloud-go-tasks").addEventListener("click", () => navigate("probe"));
$("cloud-folder-use").addEventListener("click", () => {
  if ($("cloud-folder-use").disabled) return;
  cloud115.pathRequest++;
  $("cloud-root-id").value = cloud115.folderData.parent;
  $("cloud-root-path").value = cloud115.folderData.path;
  $("cloud-root-path").title = cloud115.folderData.path;
  cloud115.closeFolders();
  toast("目录已选择，请保存设置");
});
$("library-scope").addEventListener("change", async () => {
  state.library = $("library-scope").value;
  state.tracks = [];
  state.albums = [];
  await loadSystem();
  await navigate(["overview", "tracks", "albums", "artists", "favorites", "manage"].includes(state.view) ? state.view : "tracks");
});
