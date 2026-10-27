"use strict";
const fileManager = {
  items: [],
  selected: new Set(),
  clipboard: null,
  request: 0,
  busy: false,
  path: "/",
  root: "library",
  storage: "local",
  locations: { local: { root: "library", path: "" }, cloud: { root: "filesystem", path: "/" } },
  async open() {
    await this.connection();
    await this.load();
  },
  async connection() {
    const data = await api("/cloud115/progress");
    if (!state.user || state.view !== "files") return;
    $("files-tab-cloud").hidden = !data.connected;
    if (!data.connected && this.storage === "cloud") await this.selectStorage("local");
  },
  async selectStorage(storage) {
    if (this.busy || storage === this.storage || (storage === "cloud" && $("files-tab-cloud").hidden)) return;
    this.locations[this.storage] = { root: $("files-root").value, path: $("files-path").value };
    this.reset();
    this.storage = storage;
    const location = this.locations[storage];
    this.root = location.root;
    $("files-root").value = location.root;
    $("files-root").hidden = storage === "cloud";
    $("files-path").value = location.path;
    $("files-panel").setAttribute("aria-labelledby", storage === "cloud" ? "files-tab-cloud" : "files-tab-local");
    $("files-hint").textContent = storage === "cloud"
      ? "直接管理已登录的 115 网盘。复制、移动与重命名遇到同名项会保留原文件。操作后请重新快速生成 STRM，更新网盘音乐库。剪贴板仅用于当前存储。"
      : "可浏览服务器任意可访问目录。音乐库、导入目录、插件收件目录和 STRM 目录为快捷入口；文件操作会同步更新曲库索引。";
    for (const tab of $("files-tabs").querySelectorAll('[role="tab"]')) {
      const selected = tab.dataset.storage === storage;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
    }
    this.controls();
    await this.load();
  },
  reset() {
    this.request++;
    this.clipboard = null;
    this.selected.clear();
    this.items = [];
    $("files-list").replaceChildren();
    $("files-breadcrumbs").replaceChildren();
    $("files-summary").textContent = "";
  },
  controls() {
    $("files-selected").textContent =
      `已选 ${this.selected.size} 项${this.clipboard ? ` · 已${this.clipboard.action === "copy" ? "复制" : "剪切"} ${this.clipboard.paths.length} 项` : ""}`;
    const available = this.items.filter((item) => !item.blocked).length;
    $("files-all").checked = available > 0 && this.selected.size === available;
    $("files-all").indeterminate =
      this.selected.size > 0 && this.selected.size < available;
    $("files-all").disabled = this.busy || available === 0;
    for (const button of document.querySelectorAll("[data-file-action]")) {
      const action = button.dataset.fileAction;
      button.disabled =
        this.busy ||
        (action === "paste"
          ? !this.clipboard
          : action === "rename"
            ? this.selected.size !== 1
            : this.selected.size === 0);
    }
    for (const node of document.querySelectorAll(
      "#files-path-form button, #files-path-form input, #files-path-form select, #files-breadcrumbs button",
    ))
      node.disabled = this.busy;
    $("files-up").disabled = this.busy || this.path === "/";
    for (const node of document.querySelectorAll(
      "#files-list input, #files-list button",
    ))
      node.disabled = this.busy || node.dataset.blocked === "true";
    for (const tab of $("files-tabs").querySelectorAll('[role="tab"]')) tab.disabled = this.busy;
    for (const row of $("files-list").children) row.classList.toggle("is-selected", this.selected.has(row.dataset.path));
  },
  breadcrumbs() {
    const parts = this.path.split("/").filter(Boolean);
    const nav = $("files-breadcrumbs");
    nav.replaceChildren();
    const entry = (name, path, current) => {
      const node = el(current ? "span" : "button", "file-crumb", name);
      node.title = path;
      if (current) node.setAttribute("aria-current", "location");
      else {
        node.type = "button";
        node.addEventListener("click", () => { $("files-path").value = path; this.load(); });
      }
      nav.append(node);
    };
    entry(this.storage === "cloud" ? "115 网盘" : "服务器", "/", !parts.length);
    parts.forEach((part, index) => {
      nav.append(managementIcon("chevron"));
      entry(part, "/" + parts.slice(0, index + 1).join("/"), index === parts.length - 1);
    });
  },
  async load() {
    if (!state.user || state.view !== "files") return;
    const request = ++this.request;
    const root = $("files-root").value;
    const storage = this.storage;
    try {
      const data = await api(
        `${storage === "cloud" ? "/cloud115/files" : "/files"}?${new URLSearchParams({ root, path: $("files-path").value })}`,
      );
      if (request !== this.request || !state.user || state.view !== "files")
        return;
      this.root = "filesystem";
      $("files-root").value = "filesystem";
      this.path = data.path;
      this.items = data.items;
      this.selected.clear();
      this.breadcrumbs();
      const folders = data.items.filter(item => item.type === "文件夹").length;
      $("files-summary").textContent = `${folders} 个文件夹 · ${data.items.length - folders} 个文件`;
      $("files-path").value = data.path;
      $("files-error").textContent = "";
      const rows = data.items.map((item) => {
        const row = el("tr");
        row.dataset.path = item.path;
        row.classList.toggle("file-blocked", item.blocked);
        const cell = el("td");
        const check = el("input");
        check.type = "checkbox";
        check.dataset.blocked = String(item.blocked);
        check.setAttribute("aria-label", `选择 ${item.name}`);
        check.addEventListener("change", () => {
          check.checked
            ? this.selected.add(item.path)
            : this.selected.delete(item.path);
          this.controls();
        });
        cell.append(check);
        const name = el("td", "file-name");
        const button = el("button", "file-open");
        const kind = item.type === "文件夹" ? "folder" : /\.(mp3|flac|m4a|aac|alac|wav|ogg|opus|aif|aiff|wma|strm)$/i.test(item.name) ? "audio" : "file";
        const icon = el("span", `file-icon ${kind}`);
        icon.append(managementIcon(kind));
        button.append(icon, el("span", "file-label", item.name));
        button.title = item.name;
        button.dataset.blocked = String(item.blocked);
        if (item.type === "文件夹") {
          button.classList.add("directory");
          button.addEventListener("click", () => {
            $("files-path").value = item.path;
            this.load();
          });
        } else {
          button.addEventListener("click", () => {
            check.checked = !check.checked;
            check.dispatchEvent(new Event("change"));
          });
        }
        name.append(button);
        const bytes =
          item.size < 1024
            ? `${item.size} B`
            : item.size < 1024 ** 2
              ? `${(item.size / 1024).toFixed(1)} KB`
              : item.size < 1024 ** 3
                ? `${(item.size / 1024 ** 2).toFixed(1)} MB`
                : `${(item.size / 1024 ** 3).toFixed(2)} GB`;
        row.append(
          cell,
          name,
          el("td", "file-type", item.type),
          el("td", "file-size", item.type === "文件夹" ? "—" : bytes),
          el("td", "file-date", item.modified && !item.modified.startsWith("0001") ? new Date(item.modified).toLocaleString() : "—"),
        );
        return row;
      });
      if (!rows.length) {
        const row = el("tr");
        const cell = el("td", "files-empty", "此目录为空");
        cell.colSpan = 5;
        row.append(cell);
        rows.push(row);
      }
      $("files-list").replaceChildren(...rows);
    } catch (error) {
      if (request === this.request && state.user) {
        $("files-error").textContent = `无法读取目录：${error.message}`;
        // Keep the directory selector consistent with the entries still displayed.
        $("files-root").value = this.root;
        $("files-path").value = this.path;
        if (storage === "cloud") void this.connection().catch(() => {});
      }
    } finally {
      this.controls();
    }
  },
  async action(action) {
    const paths = [...this.selected];
    if (["copy", "cut"].includes(action)) {
      this.clipboard = {
        root: this.root,
        paths,
        action: action === "copy" ? "copy" : "move",
      };
      this.controls();
      return;
    }
    let body = { action, root: this.root, paths };
    if (action === "paste") {
      if (!this.clipboard) return;
      body = { ...this.clipboard, target_root: this.root, target: this.path };
    } else if (action === "rename") {
      const old = paths[0].split("/").pop();
      const name = prompt("输入新的名称（包含文件扩展名）", old);
      if (name === null || name === old) return;
      if (
        !name.trim() ||
        name === "." ||
        name === ".." ||
        name.includes("/") ||
        name.includes("\0")
      ) {
        $("files-error").textContent = "名称不能为空、点目录或包含斜线。";
        return;
      }
      body.target = `${this.path === "/" ? "/" : this.path + "/"}${name}`;
    } else if (action === "move") {
      const destination = prompt("输入目标文件夹的绝对路径", this.path);
      if (destination === null) return;
      if (!destination.startsWith("/")) {
        $("files-error").textContent = "请输入以 / 开头的绝对路径。";
        return;
      }
      body.target_root = "filesystem";
      body.target = destination;
    } else if (action === "delete") {
      if (
        !confirm(
          this.storage === "cloud"
            ? `将已选 ${paths.length} 项及文件夹内容移入 115 回收站？`
            : `永久删除已选 ${paths.length} 项及文件夹内的全部内容？音乐库索引将同步移除，此操作无法撤销。`,
        )
      )
        return;
    }
    this.busy = true;
    this.controls();
    let failure;
    try {
      const result = await api(this.storage === "cloud" ? "/cloud115/files/operations" : "/files/operations", {
        method: "POST",
        body: JSON.stringify(body),
      });
      if (action === "paste" && this.clipboard?.action === "move")
        this.clipboard = null;
      toast(`文件操作完成，共 ${result.completed} 项。`);
    } catch (error) {
      failure = error.message;
    } finally {
      this.busy = false;
      await this.load();
      if (failure && state.user) $("files-error").textContent = failure;
      this.controls();
    }
  },
};
$("files-tabs").addEventListener("click", event => {
  const tab = event.target.closest("[data-storage]");
  if (tab) void fileManager.selectStorage(tab.dataset.storage);
});
$("files-tabs").addEventListener("keydown", event => {
  const tabs = [...$("files-tabs").querySelectorAll('[role="tab"]')].filter(tab => !tab.hidden && !tab.disabled);
  const index = tabs.indexOf(document.activeElement);
  if (index < 0 || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
  event.preventDefault();
  const next = event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : (index + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
  tabs[next].focus();
  void fileManager.selectStorage(tabs[next].dataset.storage);
});
$("files-path-form").addEventListener("submit", (event) => {
  event.preventDefault();
  fileManager.load();
});
$("files-root").addEventListener("change", () => {
  $("files-path").value = "";
  fileManager.load();
});
$("files-refresh").addEventListener("click", () => fileManager.load());
$("files-up").addEventListener("click", () => {
  $("files-path").value =
    fileManager.path.split("/").slice(0, -1).join("/") || "/";
  fileManager.load();
});
$("files-all").addEventListener("change", () => {
  const checked = $("files-all").checked;
  fileManager.selected = new Set(
    checked
      ? fileManager.items
          .filter((item) => !item.blocked)
          .map((item) => item.path)
      : [],
  );
  for (const check of document.querySelectorAll("#files-list input"))
    check.checked = checked && check.dataset.blocked !== "true";
  fileManager.controls();
});
for (const button of document.querySelectorAll("[data-file-action]"))
  button.addEventListener("click", () =>
    fileManager.action(button.dataset.fileAction),
  );
