"use strict";
let pluginItems = [],
  editingPlugin = null;
const pluginFields = {
  musicsaverbot: [
    ["enabled", "启用插件", "checkbox"],
    ["token", "Bot Token", "password"],
    [
      "api_url",
      "API 地址",
      "text",
      "留空使用 Telegram 云端；填写 local 使用内置本地 API",
    ],
    [
      "whitelist",
      "用户白名单",
      "textarea",
      "Telegram 用户 ID，每行一个；留空允许所有用户",
    ],
  ],
  telegramlocalapi: [
    ["enabled", "启用插件", "checkbox"],
    ["api_id", "Telegram API ID", "number"],
    ["api_hash", "Telegram API Hash", "password"],
    ["port", "内部监听端口", "number"],
    ["proxy_type", "代理类型", "select"],
    ["proxy_host", "代理服务器", "text"],
    ["proxy_port", "代理端口", "number"],
    ["proxy_user", "代理用户名", "text"],
    ["proxy_password", "代理密码", "password"],
    ["log", "启用服务日志", "checkbox"],
    ["cleanup_hours", "自动清理间隔（小时，0 表示关闭）", "number"],
  ],
};

async function loadPlugins() {
  const request = state.request;
  const data = await api("/plugins");
  if (!state.user || state.view !== "plugins" || state.request !== request)
    return;
  renderPlugins(data);
}

function renderPlugins(data) {
  pluginItems = data.items;
  $("plugin-cards").replaceChildren();
  for (const plugin of pluginItems) {
    const card = el("article", "plugin-card");
    card.dataset.plugin = plugin.id;
    const body = el("div", "plugin-card-body");
    const heading = el("div", "plugin-heading");
    const dot = el("i", `plugin-dot ${plugin.status.state}`);
    dot.setAttribute("aria-hidden", "true");
    heading.append(
      dot,
      el("h3", "", plugin.name),
      el("small", "", `v${plugin.version}`),
    );
    const icon = el(
      "span",
      "plugin-icon",
      plugin.id === "musicsaverbot" ? "♫" : "↗",
    );
    icon.setAttribute("aria-hidden", "true");
    body.append(
      heading,
      icon,
      el("p", "plugin-description", plugin.description),
    );
    const status = el(
      "p",
      `plugin-status ${plugin.status.state}`,
      plugin.status.message,
    );
    status.setAttribute("role", "status");
    body.append(status);
    if (plugin.status.last_saved)
      body.append(
        el("p", "plugin-last", `最近保存 · ${plugin.status.last_saved}`),
      );
    const footer = el("footer", "plugin-footer");
    const author = el("span", "plugin-author");
    author.append(
      el("span", "plugin-avatar", "S"),
      document.createTextNode(plugin.author),
    );
    const configure = el("button", "text-button", "配置");
    configure.addEventListener("click", () => openPlugin(plugin));
    const menu = el("details", "plugin-menu");
    const summary = el("summary", "", "⋮");
    summary.setAttribute("aria-label", `${plugin.name}操作`);
    menu.append(summary);
    const actions = el("div", "plugin-menu-actions");
    for (const [label, action] of [
      [plugin.config.enabled ? "停用插件" : "启用插件", "toggle"],
      ["重启服务", "restart"],
      ...(plugin.id === "telegramlocalapi"
        ? [["清理过期缓存", "clean-cache"]]
        : []),
    ]) {
      const button = el("button", "", label);
      button.addEventListener("click", async () => {
        menu.open = false;
        try {
          button.disabled = true;
          const data = await api(
            `/plugins/${plugin.id}${action === "toggle" ? "" : "/" + action}`,
            {
              method: action === "toggle" ? "PUT" : "POST",
              body: JSON.stringify(
                action === "toggle"
                  ? { ...plugin.config, enabled: !plugin.config.enabled }
                  : {},
              ),
            },
          );
          if (state.user && state.view === "plugins") renderPlugins(data);
          toast(action === "toggle" ? "插件配置已更新" : "操作已完成");
        } catch (error) {
          toast(error.message);
        } finally {
          button.disabled = false;
        }
      });
      actions.append(button);
    }
    menu.append(actions);
    footer.append(author, configure, menu);
    card.append(body, footer);
    $("plugin-cards").append(card);
  }
}

function openPlugin(plugin) {
  editingPlugin = plugin.id;
  $("plugin-title").textContent = plugin.name;
  $("plugin-description").textContent = plugin.description;
  $("plugin-error").textContent = "";
  $("plugin-fields").replaceChildren();
  for (const [key, title, type, placeholder] of pluginFields[plugin.id]) {
    const label = el("label", type === "checkbox" ? "plugin-switch" : "");
    const input = el(
      type === "textarea" ? "textarea" : type === "select" ? "select" : "input",
    );
    input.name = key;
    input.setAttribute("aria-label", title);
    if (input.tagName === "INPUT") input.type = type;
    if (type === "select") {
      for (const [value, text] of [
        ["", "不使用代理"],
        ["http", "HTTP"],
        ["socks5", "SOCKS5"],
      ]) {
        const option = el("option", "", text);
        option.value = value;
        input.append(option);
      }
    }
    if (type === "checkbox") input.checked = plugin.config[key];
    else input.value = plugin.config[key] ?? "";
    if (type === "password") {
      input.autocomplete = "new-password";
      input.value = "";
      input.placeholder = plugin[`has_${key}`]
        ? "已设置，留空保留"
        : "尚未设置";
    } else if (placeholder) input.placeholder = placeholder;
    if (type === "number") {
      input.min = key === "port" ? "1024" : "0";
      input.max =
        key === "port" || key === "proxy_port"
          ? "65535"
          : key === "cleanup_hours"
            ? "8760"
            : "2147483647";
    }
    if (type === "textarea") input.rows = 4;
    label.append(document.createTextNode(title), input);
    $("plugin-fields").append(label);
  }
  $("plugin-help").textContent =
    plugin.id === "musicsaverbot"
      ? `保存到 ${plugin.save_path}，完整下载后自动整理入库；音频上限 2 GiB（云端下载另受 Telegram 限制），支持音频文档、语音、LRC / TXT 与封面。填写 local 可使用内置服务接收大文件，无需注销云端会话。`
      : `数据目录：${plugin.data_path}。服务端已内置，无需额外安装程序。监听 127.0.0.1，无需暴露端口。API ID / Hash 来自 my.telegram.org。仅提供 Resona 音乐接收所需接口。自动或手动清理仅删除超过 24 小时的下载缓存，保留会话与待处理消息。启用日志后记录连接和缓存状态，不记录凭据或消息正文。`;
  $("plugin-dialog").showModal();
}

$("plugin-close").addEventListener("click", () => $("plugin-dialog").close());
$("plugin-dialog").addEventListener("close", () => {
  editingPlugin = null;
  $("plugin-form").reset();
  $("plugin-fields").replaceChildren();
});
$("plugins-refresh").addEventListener("click", () =>
  loadPlugins().catch((error) => toast(error.message)),
);
$("plugin-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const id = editingPlugin;
  if (!id) return;
  const config = {};
  for (const [key, , type] of pluginFields[id]) {
    const field = $("plugin-form").elements.namedItem(key);
    config[key] =
      type === "checkbox"
        ? field.checked
        : type === "number"
          ? Number(field.value)
          : field.value;
  }
  $("plugin-save").disabled = true;
  $("plugin-error").textContent = "";
  try {
    const data = await api(`/plugins/${id}`, {
      method: "PUT",
      body: JSON.stringify(config),
    });
    if (!state.user || editingPlugin !== id) return;
    if (state.view === "plugins") renderPlugins(data);
    $("plugin-dialog").close();
    toast("插件配置已保存");
  } catch (error) {
    if (state.user && editingPlugin === id)
      $("plugin-error").textContent = error.message;
  } finally {
    $("plugin-save").disabled = false;
  }
});
