"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

(async () => {
  const { url, cdn_address } = JSON.parse(
    fs.readFileSync(".build/browser-fixture.json", "utf8"),
  );
  const browser = await chromium.launch({
    args: ["--autoplay-policy=no-user-gesture-required",
      "--no-proxy-server", `--host-resolver-rules=MAP cdnfhnfile.115cdn.net ${cdn_address}`],
  });
  try {
    const page = await browser.newPage({
      viewport: { width: 1440, height: 1000 },
      ignoreHTTPSErrors: true,
      reducedMotion: "reduce",
    });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(url);
    await page.locator("#password").fill("a-test-password-123");
    await page.locator("#login-button").click();
    await page.locator("#app").waitFor({ state: "visible" });
    assert.equal(await page.locator("#logout").innerText(), "退出登录");
    await page.locator('.nav-item[data-view=artists]').click();
    await page.waitForFunction(() => document.querySelector('.artist-avatar img')?.naturalWidth > 0);
    assert((await page.locator('.artist-avatar img').first().getAttribute('src')).includes('/artists/avatar?name=Artist'));
    await page.route('**/api/v1/artists/avatar?*', route => route.fulfill({ status: 404 }));
    await page.locator('.nav-item[data-view=tracks]').click();
    await page.locator('.nav-item[data-view=artists]').click();
    await page.waitForFunction(() => document.querySelector('.artist-avatar')?.textContent === 'A' &&
      !document.querySelector('.artist-avatar img'));
    await page.unroute('**/api/v1/artists/avatar?*');
    const management = await page
      .locator(".nav-item")
      .evaluateAll((nodes) => nodes.map((node) => node.dataset.view));
    assert.equal(management.includes("plugins"), false);
    assert.equal(management.includes("cloud115"), false);
    assert.equal(management.indexOf("settings"), management.indexOf("jobs") + 1);
    assert.equal(management.indexOf("logs"), management.indexOf("settings") + 1);
    async function openSettingsTab(view) {
      await page.locator('.nav-item[data-view=settings]').click();
      if (view !== "settings") await page.locator(`#settings-tab-${view}`).click();
    }
    await openSettingsTab("settings");
    assert.equal(await page.locator("#library-scope").isVisible(), false);
    for (const view of ["files", "logs", "jobs"]) {
      await page.locator(`.nav-item[data-view=${view}]`).click();
      assert.equal(await page.locator("#library-scope").isVisible(), false, `${view} must hide library switch`);
    }
    await openSettingsTab("settings");
    assert.deepEqual(await page.locator('#settings-tabs [role=tab]').allTextContents(), ["系统设置", "插件", "115 网盘"]);
    assert.equal(await page.locator('#system-settings-panel').isVisible(), true);
    await page.locator('#settings-tab-settings').focus();
    await page.keyboard.press("ArrowRight");
    assert.equal(await page.locator('#settings-tab-plugins').getAttribute("aria-selected"), "true");
    assert.equal(await page.locator('#system-settings-panel').isVisible(), false);
    assert.equal(await page.locator('#plugins-view').isVisible(), true);
    assert.equal(await page.locator('.nav-item[data-view=settings]').evaluate(node => node.classList.contains('active')), true);
    await page.keyboard.press("End");
    assert.equal(await page.locator('#settings-tab-cloud115').getAttribute("aria-selected"), "true");
    await page.keyboard.press("ArrowRight");
    assert.equal(await page.locator('#settings-tab-settings').getAttribute("aria-selected"), "true");
    await page.keyboard.press("ArrowLeft");
    assert.equal(await page.locator('#settings-tab-cloud115').getAttribute("aria-selected"), "true");
    await page.keyboard.press("Home");
    assert.equal(await page.locator('#settings-tab-settings').getAttribute("tabindex"), "0");
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      for (const view of ["settings", "plugins", "cloud115"]) {
        await openSettingsTab(view);
        await page.waitForTimeout(400);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "settings tabs overflow");
        assert.equal(await page.locator("#logout").evaluate(node => node.scrollHeight <= node.clientHeight), true, "logout text wraps outside its button");
        await page.screenshot({ path: `.build/resona-v15-settings-${view}-${width}.png` });
      }
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openSettingsTab("plugins");
    await page.locator(".plugin-card").nth(1).waitFor();
    const musicPlugin = page.locator('[data-plugin="musicsaverbot"]');
    await musicPlugin
      .getByRole("button", { name: "配置", exact: true })
      .click();
    await page
      .getByLabel("Bot Token", { exact: true })
      .fill("123456:abcdefghijklmnopqrstuvwxyz_123456");
    await page.getByLabel("用户白名单").fill("42\n123");
    await page.locator("#plugin-save").click();
    await page.locator("#plugin-dialog").waitFor({ state: "hidden" });
    const configured = await page.evaluate(async () =>
      (await fetch("/api/v1/plugins")).json(),
    );
    assert.equal(configured.items[0].has_token, true);
    assert.equal(configured.items[0].config.token, "");
    assert(!JSON.stringify(configured).includes("abcdefghijklmnopqrstuvwxyz"));
    await musicPlugin
      .getByRole("button", { name: "配置", exact: true })
      .click();
    assert.equal(
      await page.getByLabel("Bot Token", { exact: true }).inputValue(),
      "",
    );
    assert.equal(
      await page
        .getByLabel("Bot Token", { exact: true })
        .getAttribute("placeholder"),
      "已设置，留空保留",
    );
    await page.getByLabel("启用插件", { exact: true }).check();
    await page.getByLabel("API 地址", { exact: true }).fill("local");
    await page.locator("#plugin-save").click();
    await page.waitForFunction(() =>
      document.querySelector("#plugin-error").textContent.includes("先启用"),
    );
    await page.keyboard.press("Escape");
    for (const width of [1440, 760, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.waitForTimeout(400);
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth > innerWidth,
        ),
        false,
      );
      await page.screenshot({
        path: `.build/resona-v7-plugins-${width}.png`,
        fullPage: false,
      });
      await page
        .locator('[data-plugin="telegramlocalapi"]')
        .getByRole("button", { name: "配置", exact: true })
        .click();
      assert.equal(
        await page
          .getByLabel("Telegram API Hash", { exact: true })
          .inputValue(),
        "",
      );
      await page.keyboard.press("Escape");
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator(".nav-item[data-view=tracks]").click();
    await page.locator(".track-row").nth(99).waitFor();
    await page.locator(".track-info").first().click();
    await page.waitForFunction(
      () =>
        !document.querySelector("#audio").paused &&
        document.querySelector("#audio").currentTime > 0,
    );
    assert.equal(await page.locator("#track-dialog").isVisible(), false);
    await page.mouse.move(400, 200);
    await page.locator('#search').focus();
    await page.waitForFunction(() => !document.querySelector('#player-lyrics').hidden);
    assert.equal(await page.locator('#player-lyric-current').innerText(), 'First line');
    assert.equal(await page.locator('#player-lyric-next').innerText(), 'Second line');
    await page.locator('#player-bar').hover();
    await page.waitForFunction(() => !document.querySelector('#player-metadata').hidden);
    await page.locator('#seek').focus();
    const beforeSeek = await page.locator('#audio').evaluate(audio => audio.currentTime);
    await page.keyboard.press('ArrowRight');
    await page.waitForFunction(before => document.querySelector('#audio').currentTime >= before + 4.5, beforeSeek);
    assert.equal(await page.locator('#player-lyrics').isVisible(), false);
    await page.locator('#seek').evaluate(input => {
      input.value = '0';
      input.dispatchEvent(new Event('input'));
    });
    const player = await page.locator('#player-bar').boundingBox();
    const progress = await page.locator('.player-progress').boundingBox();
    assert(Math.abs(player.y - progress.y) <= 2, 'seek bar must span the top of the footer');
    await page.screenshot({ path: '.build/web-player-desktop.png' });
    await page.locator("#play-pause").click();
    assert.equal(await page.locator('#player-metadata').isVisible(), true);
    await page.locator(".nav-item[data-view=manage]").click();
    await page.locator("#track-list .track-actions").nth(99).waitFor();
    const source = await page.locator("#audio").getAttribute("src");
    for (const target of [
      ".track-info",
      ".track-thumbnail",
      ".track-number",
      ".track-album",
    ]) {
      await page.locator(target).first().click();
      await page.locator("#track-dialog").waitFor({ state: "visible" });
      assert.equal(
        await page.locator("#audio").evaluate((audio) => audio.paused),
        true,
      );
      assert.equal(await page.locator("#audio").getAttribute("src"), source);
      await page.keyboard.press("Escape");
    }
    await page.locator(".track-info").first().click();
    await page.locator("#track-dialog").waitFor({ state: "visible" });
    await page.locator("#track-detail-name").click();
    assert.equal(await page.locator("#track-dialog").isVisible(), true);
    await page.mouse.click(4, 4);
    await page.locator("#track-dialog").waitFor({ state: "hidden" });
    assert.equal(
      await page.locator(".track-tag-badge").first().innerText(),
      "标签无歌词",
    );
    assert.equal(
      await page.locator(".track-tag-badge").nth(1).innerText(),
      "标签有歌词",
    );
    assert.equal(await page.locator(".track-lrc-badge").first().innerText(), "有 LRC 歌词");
    assert.equal(await page.locator(".track-lrc-badge").nth(1).innerText(), "无 LRC 歌词");
    await page
      .locator(".track-row")
      .first()
      .getByRole("button", { name: "刮削歌词", exact: true })
      .click();
    await page.locator("#lyrics-embed").waitFor({ state: "visible" });
    await page.waitForFunction(
      () => !document.querySelector("#lyrics-embed").disabled,
    );
    assert.match(
      await page.locator("#lyrics-preview").innerText(),
      /First line/,
    );
    const oldTrackID = await page
      .locator(".track-row")
      .first()
      .getAttribute("data-track-id");
    await page.locator("#lyrics-embed").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#lyrics-status")
        .textContent.includes("已写入音频标签"),
    );
    assert.equal(
      await page.locator(".track-tag-badge").first().innerText(),
      "标签有歌词",
    );
    assert.notEqual(
      await page.locator(".track-row").first().getAttribute("data-track-id"),
      oldTrackID,
    );
    assert.equal(
      await page.locator("#audio").evaluate((node) => node.paused),
      true,
    );
    await page.keyboard.press("Escape");
    await page.locator(".track-info").first().click();
    await page
      .locator("#track-detail-actions")
      .getByRole("button", { name: "播放", exact: true })
      .click();
    await page.waitForFunction(() => !document.querySelector("#audio").paused);
    assert.equal(await page.locator("#queue-badge").innerText(), "100");
    await page.locator(".nav-item[data-view=tracks]").click();
    await page.locator("#library-actions").waitFor({ state: "visible" });
    await page.waitForFunction(
      () => !document.querySelector("#track-list .track-actions"),
    );
    // Force multiple server pages even for a small fixture.
    await page.route("**/api/v1/tracks?**", async (route) => {
      const target = new URL(route.request().url());
      if (target.searchParams.get("limit") === "500")
        target.searchParams.set("limit", "40");
      await route.continue({ url: target.toString() });
    });
    await page.locator("#play-all").click();
    await page.waitForFunction(
      () => document.querySelector("#queue-badge").textContent === "105",
    );
    assert.equal(await page.locator(".track-row").count(), 100);
    await page.locator("#queue-toggle").click();
    await page.locator("#queue-panel").waitFor({ state: "visible" });
    assert.equal(await page.locator(".queue-item").count(), 105);
    assert.equal(await page.locator(".queue-item[aria-current]").count(), 1);
    await page.locator(".queue-item").nth(104).click();
    assert.equal(await page.locator("#player-title").innerText(), "Song 105");
    assert.equal(await page.locator("#next").isDisabled(), true);
    await page.waitForFunction(() =>
      Number.isFinite(document.querySelector("#audio").duration),
    );
    await page.locator("#audio").evaluate((audio) => {
      audio.currentTime = audio.duration - 0.05;
    });
    await page.waitForFunction(() => document.querySelector("#audio").ended);
    assert.equal(await page.locator("#player-title").innerText(), "Song 105");
    await page.keyboard.press("Escape");
    assert.equal(
      await page
        .locator("#queue-toggle")
        .evaluate((node) => node === document.activeElement),
      true,
    );
    await page.locator("#repeat-mode").click();
    assert.equal(
      await page.locator("#repeat-mode").getAttribute("aria-pressed"),
      "true",
    );
    await page.locator("#next").click();
    assert.equal(await page.locator("#player-title").innerText(), "Song");
    await page.locator("#repeat-mode").click();
    assert.equal(await page.locator("#repeat-single").isVisible(), true);
    const single = await page.locator("#audio").getAttribute("src");
    await page.evaluate(() =>
      document.querySelector("#audio").dispatchEvent(new Event("ended")),
    );
    assert.equal(await page.locator("#audio").getAttribute("src"), single);
    await page.locator("#next").click();
    assert.equal(await page.locator("#player-title").innerText(), "Song 002");
    await page.locator("#play-pause").click();
    await page.locator("#enqueue-all").click();
    await page.waitForFunction(
      () => !document.querySelector("#enqueue-all").disabled,
    );
    assert.equal(await page.locator("#queue-badge").innerText(), "105");
    assert.equal(
      await page.locator("#audio").evaluate((audio) => audio.paused),
      true,
    );
    assert.equal(await page.locator("#player-title").innerText(), "Song 002");
    await page.locator("#shuffle-all").click();
    await page.waitForFunction(
      () => !document.querySelector("#shuffle-all").disabled,
    );
    await page.locator("#queue-toggle").click();
    const shuffled = await page
      .locator(".queue-item .queue-copy strong")
      .allTextContents();
    assert.equal(new Set(shuffled).size, 105);
    assert.notDeepEqual(shuffled, [
      "Song",
      ...Array.from(
        { length: 104 },
        (_, i) => `Song ${String(i + 2).padStart(3, "0")}`,
      ),
    ]);
    await page.keyboard.press("Escape");
    await page.locator("#select-tracks").click();
    await page.locator(".track-number").first().click();
    await page.locator(".track-number").nth(1).click();
    assert.match(
      await page.locator("#selection-count").innerText(),
      /已选 2 首/,
    );
    await page.locator("#play-all").click();
    await page.waitForFunction(
      () => document.querySelector("#queue-badge").textContent === "2",
    );
    await page.locator("#select-all-tracks").check();
    await page.waitForFunction(() =>
      document.querySelector("#selection-count").textContent.includes("105"),
    );
    await page.locator("#play-all").click();
    await page.waitForFunction(
      () => document.querySelector("#queue-badge").textContent === "105",
    );
    await page.locator("#search").fill("Song 105");
    await page.waitForFunction(
      () => document.querySelectorAll(".track-row").length === 1,
    );
    assert.equal(
      await page.locator("#select-tracks").getAttribute("aria-pressed"),
      "false",
    );
    await page.locator("#play-all").click();
    await page.waitForFunction(
      () => document.querySelector("#queue-badge").textContent === "1",
    );
    assert.equal(await page.locator("#player-title").innerText(), "Song 105");
    await page.reload();
    await page.locator("#app").waitFor({ state: "visible" });
    assert.equal(
      await page.locator("#repeat-mode").getAttribute("aria-label"),
      "单曲循环，切换为随机循环",
    );
    await page.locator(".nav-item[data-view=tracks]").click();
    await page.locator(".track-row").nth(99).waitFor();
    await page.locator("#enqueue-all").click();
    await page.waitForFunction(
      () => document.querySelector("#queue-badge").textContent === "105",
    );
    assert.equal(
      await page.locator("#audio").evaluate((audio) => audio.paused),
      true,
    );
    await page.locator("#repeat-mode").click();
    assert.equal(
      await page.locator("#repeat-mode").getAttribute("aria-label"),
      "随机循环，切换为顺序播放",
    );
    await page.locator("#play-pause").click();
    const beforeRandom = await page.locator("#audio").getAttribute("src");
    await page
      .locator("#audio")
      .evaluate((audio) => audio.dispatchEvent(new Event("ended")));
    await page.waitForFunction(
      (before) =>
        document.querySelector("#audio").getAttribute("src") !== before,
      beforeRandom,
    );
    const afterRandom = await page.locator("#audio").getAttribute("src");
    await page.locator("#next").click();
    assert.notEqual(
      await page.locator("#audio").getAttribute("src"),
      afterRandom,
    );
    assert.equal(await page.locator("#queue-badge").innerText(), "105");
    await page.reload();
    await page.locator("#app").waitFor({ state: "visible" });
    assert.equal(
      await page.locator("#repeat-mode").getAttribute("aria-label"),
      "随机循环，切换为顺序播放",
    );
    await page.locator(".nav-item[data-view=tracks]").click();
    await page.locator("#enqueue-all").click();
    await page.waitForFunction(
      () => document.querySelector("#queue-badge").textContent === "105",
    );
    await page.locator("#queue-toggle").click();
    await page.waitForTimeout(400);
    await page.screenshot({
      path: ".build/resona-v8-queue-desktop.png",
      fullPage: false,
    });
    for (const width of [1024, 800, 760, 390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth > innerWidth,
        ),
        false,
      );
      assert.equal(await page.locator("#repeat-mode").isVisible(), true);
      await page.waitForFunction(() => {
        const panel = document
          .querySelector("#queue-panel")
          .getBoundingClientRect();
        const player = document
          .querySelector("#player-bar")
          .getBoundingClientRect();
        return panel.bottom <= player.top;
      });
      const panel = await page.locator("#queue-panel").boundingBox();
      const player = await page.locator("#player-bar").boundingBox();
      assert(panel.y + panel.height <= player.y, "queue overlaps the player");
    }
    await page.screenshot({
      path: ".build/resona-v8-queue-mobile.png",
      fullPage: false,
    });
    await page.locator("#queue-close").click();
    await page.locator("#expand-player").click();
    await page.locator("#now-playing-view").waitFor({ state: "visible" });
    await page.waitForFunction(
      () =>
        document.querySelectorAll(".listening-lyric").length > 0 ||
        document
          .querySelector("#listening-lyrics-list")
          .textContent.includes("First line"),
    );
    await page.locator("#collapse-player").click();
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator(".nav-item[data-view=settings]").click();
    await page.locator("#lyrics-priority li").nth(3).waitFor();
    for (const width of [1440, 900, 760, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.waitForTimeout(400);
      const metadata = await page.locator("#metadata-priority").boundingBox();
      const lyrics = await page.locator("#lyrics-priority").boundingBox();
      const lyricsSource = await page
        .locator("#default-lyrics-source")
        .boundingBox();
      const metadataHeading = await page
        .getByRole("heading", { name: "刮削优先级", exact: true })
        .boundingBox();
      const lyricsHeading = await page
        .getByRole("heading", { name: "歌词优先级", exact: true })
        .boundingBox();
      assert(Math.abs(lyrics.x - lyricsSource.x) < 1);
      assert(Math.abs(lyricsHeading.x - lyricsSource.x) < 1);
      if (width > 760) {
        assert(lyrics.x >= metadata.x + metadata.width);
        assert(Math.abs(lyricsHeading.y - metadataHeading.y) < 1);
      } else {
        assert(Math.abs(lyrics.x - metadata.x) < 1);
        assert(lyricsSource.y >= metadata.y + metadata.height);
      }
      assert.equal(
        await page.evaluate(() => document.documentElement.scrollWidth > innerWidth),
        false,
      );
      await page.screenshot({
        path: `.build/resona-v11-settings-${width}.png`,
        fullPage: true,
      });
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    assert.equal(
      await page.locator("#lyrics-priority input:disabled").count(),
      4,
    );
    await page.locator("#default-lyrics-source").selectOption("auto");
    await page
      .locator("#lyrics-priority")
      .getByRole("button", { name: "上移 QQ音乐", exact: true })
      .click();
    await page
      .locator("#lyrics-priority")
      .getByRole("checkbox", { name: "启用 LRCLIB", exact: true })
      .uncheck();
    await page.locator("#source-save").click();
    await page.waitForFunction(
      () => !document.querySelector("#source-save").disabled,
    );
    const lyricSettings = await page.evaluate(
      async () => (await (await fetch("/api/v1/sources")).json()).settings,
    );
    assert.equal(lyricSettings.lyrics_priority[0], "qq");
    assert.deepEqual(lyricSettings.lyrics_disabled, ["lrclib"]);
    await page.locator(".nav-item[data-view=logs]").click();
    await page.locator(".log-entry").first().waitFor();
    await page
      .locator("#logs-levels")
      .getByRole("button", { name: /ERROR/ })
      .click();
    await page.waitForFunction(
      () => document.querySelectorAll(".log-entry").length === 1,
    );
    assert.match(
      await page.locator("#logs-list").innerText(),
      /Fixture plugin failure/,
    );
    assert.equal(await page.locator("#logs-list script").count(), 0);
    await page.locator("#logs-category").selectOption("plugin");
    await page.locator("#logs-search").fill("no such log");
    await page.locator("#logs-list .empty").waitFor();
    await page.locator("#logs-search").fill("");
    await page
      .locator("#logs-levels")
      .getByRole("button", { name: /全部/ })
      .click();
    await page.locator("#logs-category").selectOption("");
    await page.locator("#logs-pause").click();
    assert.equal(
      await page.locator("#logs-pause").getAttribute("aria-pressed"),
      "true",
    );
    await page.locator("#logs-refresh").click();
    for (const width of [1440, 760, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.waitForTimeout(200);
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth > innerWidth,
        ),
        false,
      );
      await page.screenshot({ path: `.build/resona-v9-logs-${width}.png` });
    }
    page.once("dialog", (dialog) => dialog.dismiss());
    await page.locator("#logs-clear").click();
    assert((await page.locator(".log-entry").count()) > 1);
    page.once("dialog", (dialog) => dialog.accept());
    await page.locator("#logs-clear").click();
    await page.waitForFunction(
      () => document.querySelectorAll(".log-entry").length === 1,
    );
    await page.locator(".nav-item[data-view=files]").click();
    await page.locator("#files-list tr").first().waitFor();
    await page.waitForFunction(() => document.querySelector("#files-breadcrumbs").textContent.length > 0);
    assert.match(await page.locator("#files-summary").innerText(), /个文件夹.*个文件/);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "file workspace overflows");
      await page.screenshot({ path: `.build/resona-v25-files-${width}.png` });
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    assert.equal(await page.locator("#files-tab-cloud").isVisible(), false, "115 tab exposed before login");
    await page.locator("#files-root").selectOption("strm");
    await page.waitForFunction(() => document.querySelector("#files-path").value.endsWith("/cloud115/strm"));
    assert.match(await page.locator("#files-list").innerText(), /此目录为空/);
    await page.locator("#files-root").selectOption("inbox");
    await page
      .locator("#files-list")
      .getByRole("button", { name: "notes.txt", exact: true })
      .waitFor();
    for (const width of [1440, 760, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.waitForTimeout(200);
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth > innerWidth,
        ),
        false,
      );
      await page.screenshot({ path: `.build/resona-v9-files-${width}.png` });
    }
    await page
      .locator("#files-list")
      .getByRole("checkbox", { name: "选择 notes.txt", exact: true })
      .check();
    await page.locator('[data-file-action="copy"]').click();
    await page
      .locator("#files-list")
      .getByRole("button", { name: "Archive", exact: true })
      .click();
    await page.locator("#files-list .files-empty").waitFor();
    await page.locator('[data-file-action="paste"]').click();
    await page
      .locator("#files-list")
      .getByRole("button", { name: "notes.txt", exact: true })
      .waitFor();
    await page
      .locator("#files-list")
      .getByRole("checkbox", { name: "选择 notes.txt", exact: true })
      .check();
    page.once("dialog", (dialog) => dialog.accept("renamed.txt"));
    await page.locator('[data-file-action="rename"]').click();
    await page
      .locator("#files-list")
      .getByRole("button", { name: "renamed.txt", exact: true })
      .waitFor();
    await page
      .locator("#files-list")
      .getByRole("checkbox", { name: "选择 renamed.txt", exact: true })
      .check();
    page.once("dialog", (dialog) => dialog.accept());
    await page.locator('[data-file-action="delete"]').click();
    await page.locator("#files-list .files-empty").waitFor();
    await page.locator("#files-path").fill("/");
    await page
      .locator("#files-path-form")
      .getByRole("button", { name: "前往", exact: true })
      .click();
    await page.waitForFunction(
      () =>
        document.querySelector("#files-path").value === "/" &&
        document.querySelectorAll("#files-list .directory").length > 0,
    );
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openSettingsTab("settings");
    await page.waitForFunction(() => document.querySelector("#scan-schedule-zone").textContent.includes("UTC") || /\+|-\d\d:/.test(document.querySelector("#scan-schedule-zone").textContent));
    assert.deepEqual(await page.locator("#system-settings-panel > .settings-card > h2").allTextContents(), ["刮削源与歌词源", "定时整理与刮削", "你的音乐服务器"]);
    assert.equal(await page.locator("#scan-schedule-mode option[value=interval], #scan-schedule-interval").count(), 0);
    for (const mode of ["daily", "manual"]) {
      await page.locator("#scan-schedule-mode").selectOption(mode);
      assert.equal(await page.locator("#scan-time-wrap").isVisible(), mode === "daily");
      if (mode === "daily") await page.locator("#scan-schedule-time").fill("04:30");
      await page.locator("#scan-schedule-save").click();
      await page.waitForFunction(() => document.querySelector("#scan-schedule-status").textContent.includes("已保存"));
      const saved = await page.evaluate(async () => (await (await fetch("/api/v1/settings/scan")).json()).settings);
      assert.equal(saved.mode, mode);
      if (mode === "daily") assert.equal(saved.time, "04:30");
    }
    await page.locator(".nav-item[data-view=jobs]").click();
    assert.equal(await page.locator("#scan-schedule").isVisible(), false, "schedule remained on the task page");
    assert.deepEqual(await page.locator('#tasks-tabs [role=tab]').allTextContents(), ["整理与刮削", "STRM 预探测"]);
    await page.locator("#tasks-tab-jobs").focus();
    await page.keyboard.press("ArrowRight");
    await page.locator("#cloud-probe-view").waitFor({ state: "visible" });
    assert.equal(await page.locator('.nav-item[data-view=jobs]').evaluate(node => node.classList.contains("active")), true);
    await page.keyboard.press("Home");
    await page.locator("#jobs-view").waitFor({ state: "visible" });
    assert.equal(await page.locator("#scan-button").isVisible(), false, "task scan entry remains in the page heading");
    assert.equal(await page.locator(".pipeline, #jobs-view .info-note").count(), 0);
    const introStyles = await page.locator("#tasks-view .task-intro").evaluateAll(nodes => nodes.map(node => {
      const style = getComputedStyle(node);
      return ["fontSize", "color", "lineHeight", "backgroundColor", "padding", "margin"].map(key => style[key]);
    }));
    assert.deepEqual(introStyles[0], introStyles[1], "task descriptions differ");
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      const scan = await page.locator("#jobs-scan-button").boundingBox(), scrape = await page.locator("#rescrape-button").boundingBox();
      assert(scan.x + scan.width <= scrape.x + 1 && Math.abs(scan.y - scrape.y) < 1, "task scan button is not directly left of rescrape");
      await page.screenshot({ path: `.build/resona-v26-tasks-${width}.png`, fullPage: true });
    }
    let organizeCalls = 0, libraryScanCalls = 0;
    await page.route("**/api/v1/jobs/scan", route => {
      organizeCalls++;
      return route.fulfill({ status: 409, json: { error: "Fixture organizing request" } });
    });
    await page.route("**/api/v1/library/scan", route => {
      libraryScanCalls++;
      return route.fulfill({ status: 409, json: { error: "Fixture index-only request" } });
    });
    await page.evaluate(() => { state.jobs = []; state.library = "cloud"; renderScanButton(); });
    assert.equal(await page.locator("#jobs-scan-button").textContent(), "整理入库");
    await page.locator("#jobs-scan-button").click();
    await page.waitForFunction(() => document.querySelector("#toast").textContent.includes("Fixture organizing request"));
    assert.equal(organizeCalls, 1);
    assert.equal(libraryScanCalls, 0);
    await page.evaluate(() => { state.library = "local"; });
    await page.locator('.nav-item[data-view=tracks]').click();
    await page.evaluate(() => { state.jobs = []; renderScanButton(); });
    await page.locator("#scan-button").click();
    await page.waitForFunction(() => document.querySelector("#toast").textContent.includes("Fixture index-only request"));
    assert.equal(libraryScanCalls, 1);
    assert.equal(organizeCalls, 1);
    await page.unroute("**/api/v1/jobs/scan");
    await page.unroute("**/api/v1/library/scan");
    await page.locator('.nav-item[data-view=jobs]').click();
    await page.evaluate(() => loadJobs());
    let detailFailure = true;
    await page.route("**/api/v1/jobs/complete-a", route => detailFailure
      ? route.fulfill({ status: 503, json: { error: "Fixture detail temporarily unavailable" } })
      : route.continue());
    await page.locator(".job-open").first().click();
    await page.locator("#job-detail-view").waitFor({ state: "visible" });
    await page.locator("#job-detail-retry").waitFor({ state: "visible" });
    assert.match(await page.locator("#job-detail-status").innerText(), /Fixture detail temporarily unavailable/);
    detailFailure = false;
    await page.locator("#job-detail-retry").click();
    await page.waitForFunction(() =>
      document.querySelector("#job-files").textContent.includes("时长 2:00"),
    );
    assert.equal(await page.locator("#job-detail-retry").isVisible(), false);
    await page.unroute("**/api/v1/jobs/complete-a");
    await page.locator(".nav-item[data-view=jobs]").click();
    await page.locator(".job-record").nth(2).waitFor();
    assert.equal(await page.locator(".job-select:disabled").count(), 1);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.waitForTimeout(500);
      const centers = await page
        .locator(".job-record")
        .first()
        .evaluate((row) =>
          [...row.children].map((node) => {
            const rect = node.getBoundingClientRect();
            return rect.y + rect.height / 2;
          }),
        );
      assert(
        Math.max(...centers) - Math.min(...centers) < 2,
        "task record wraps onto another line",
      );
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth > innerWidth,
        ),
        false,
      );
      await page.screenshot({ path: `.build/resona-v8-jobs-${width}.png` });
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator(".job-select").first().check();
    assert.equal(await page.locator("#jobs-view").isVisible(), true);
    assert.equal(await page.locator("#job-detail-view").isVisible(), false);
    await page.evaluate(() => loadJobs());
    assert.equal(
      await page.locator(".job-select").first().isChecked(),
      true,
      "poll reset selection",
    );
    page.once("dialog", (dialog) => dialog.dismiss());
    await page.locator("#jobs-delete-selected").click();
    assert.equal(await page.locator(".job-record").count(), 3);
    await page.locator("#jobs-select-all").check();
    assert.equal(await page.locator(".job-select:checked").count(), 2);
    await page.locator(".job-select").nth(1).uncheck();
    assert.equal(
      await page
        .locator("#jobs-select-all")
        .evaluate((node) => node.indeterminate),
      true,
    );
    page.once("dialog", (dialog) => dialog.accept());
    await page.locator("#jobs-delete-selected").click();
    await page.waitForFunction(
      () => document.querySelectorAll(".job-record").length === 2,
    );
    page.once("dialog", (dialog) => dialog.dismiss());
    await page.locator("#jobs-delete-all").click();
    assert.equal(await page.locator(".job-record").count(), 2);
    page.once("dialog", (dialog) => dialog.accept());
    await page.locator("#jobs-delete-all").click();
    await page.waitForFunction(
      () => document.querySelectorAll(".job-record").length === 1,
    );
    assert.equal(await page.locator("#jobs-delete-all").isDisabled(), true);
    await page.locator(".job-open").click();
    await page.locator("#job-detail-view").waitFor({ state: "visible" });
    await page.waitForFunction(
      () => document.querySelector("#job-detail-actions .delete-job")?.disabled,
    );
    assert.equal(
      await page.locator("#job-detail-actions .delete-job").isDisabled(),
      true,
    );
    await page.locator(".nav-item[data-view=tracks]").click();
    assert.equal(await page.locator("#scan-button").isDisabled(), true, "local running task should block another local scan");
    await page.locator("#library-scope").selectOption("cloud");
    await page.evaluate(() => loadJobs());
    assert.equal(await page.locator("#scan-button").isVisible(), true, "cloud library has no scan entry");
    assert.equal(await page.locator("#scan-button").isEnabled(), true, "local task blocked a cloud scan");
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "cloud scan button overflows");
      await page.screenshot({ path: `.build/resona-v23-cloud-scan-${width}.png` });
    }
    await page.locator("#scan-button").click();
    await page.locator("#jobs-view").waitFor({ state: "visible" });
    await page.waitForFunction(async () => {
      const data = await (await fetch("/api/v1/jobs?summary=1")).json();
      return data.items.some(job => job.library === "cloud" && job.state === "completed");
    });
    assert.match(await page.locator("#toast").innerText(), /扫描本地 STRM/);
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openSettingsTab("cloud115");
    await page.waitForFunction(() => document.querySelector("#cloud-identity-note").textContent.includes("无需应用 ID"));
    assert.equal(await page.locator("#cloud-client-id").count(), 0);
    for (const action of ["close", "escape", "leave"]) {
      let heldAuth, signalAuth;
      const pendingAuth = new Promise(resolve => { signalAuth = resolve; });
      await page.route("**/api/v1/cloud115/auth", route => {
        if (route.request().method() === "POST") { heldAuth = route; signalAuth(); }
        else return route.continue();
      });
      await page.locator("#cloud-authorize").click();
      await pendingAuth;
      if (action === "close") await page.locator("#cloud-auth-cancel").click();
      else if (action === "escape") await page.keyboard.press("Escape");
      else await page.evaluate(() => navigate("tracks"));
      await heldAuth.fulfill({ json: { url: "https://115.com/scan/dg-stale", client_type: "alipaymini" } });
      await page.waitForTimeout(100);
      assert.equal(await page.locator("#cloud-auth").isVisible(), false, "late QR response reopened a closed session");
      await page.unroute("**/api/v1/cloud115/auth");
      if (action === "leave") await openSettingsTab("cloud115");
    }
    await page.locator("#cloud-authorize").click();
    await page.locator("#cloud-auth").waitFor({ state: "visible" });
    await page.waitForFunction(() => document.querySelector("#cloud-qr").naturalWidth > 0);
    const devices = ["alipaymini", "wechatmini", "115android", "115ios", "web", "115ipad", "tv"];
    assert.deepEqual(await page.locator('[name="cloud-client-type"]').evaluateAll(nodes => nodes.map(node => node.value)), devices);
    for (const device of [...devices.slice(1), devices[0]]) {
      await page.waitForFunction(() => !document.querySelector("#cloud-auth-refresh").disabled);
      const changed = page.waitForResponse(response => response.url().endsWith("/api/v1/cloud115/auth") && response.request().method() === "POST");
      await page.locator(`[name="cloud-client-type"][value="${device}"]`).check();
      const response = await changed;
      assert.equal((await response.json()).client_type, device);
      assert.equal(JSON.parse(response.request().postData()).client_type, device);
    }
    await page.waitForFunction(() => !document.querySelector("#cloud-auth-refresh").disabled);
    await page.route("**/api/v1/cloud115/auth", async route => {
      if (route.request().method() === "GET") await route.fulfill({ json: { status: -1 } });
      else await route.continue();
    });
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.locator("#cloud-auth-methods").scrollIntoViewIfNeeded();
      await page.waitForTimeout(400);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "QR methods overflow viewport");
      await page.screenshot({ path: `.build/resona-v13-qr-${width}.png` });
    }
    await page.waitForFunction(() => document.querySelector("#cloud-auth-state").textContent.includes("二维码已过期"));
    await page.unroute("**/api/v1/cloud115/auth");
    const previousQR = await page.locator("#cloud-qr").getAttribute("src");
    await page.locator("#cloud-auth-refresh").click();
    await page.waitForFunction(previous => !document.querySelector("#cloud-auth-refresh").disabled && document.querySelector("#cloud-qr").getAttribute("src") !== previous, previousQR);
    await page.evaluate(() => cloud115.load());
    await page.waitForFunction(() => document.querySelector("#cloud-auth-state").textContent.includes("已扫码"));
    await page.waitForFunction(() => document.querySelector("#cloud-account-name").textContent.includes("Fixture Account"));
    assert.equal(await page.locator("#cloud-auth").isVisible(), false);
    const cloudStatus = await page.evaluate(async () => (await fetch("/api/v1/cloud115")).json());
    assert.equal(cloudStatus.connected, true);
    assert(!/private|cookie|client_id|access_token/i.test(JSON.stringify(cloudStatus)));
    await page.waitForFunction(() => !cloud115.profileLoading && cloud115.profile?.membership === "年费 VIP");
    assert.equal(await page.locator("#cloud-storage-meter").isVisible(), true);
    await page.route("**/api/v1/cloud115/account", route => route.fulfill({ status: 502, json: { error: "资料暂不可用" } }));
    await page.locator("#cloud-account-refresh").click();
    await page.waitForFunction(() => !cloud115.profileLoading);
    assert.equal(await page.locator("#cloud-storage-meter").isVisible(), true, "refresh failure discarded cached capacity");
    assert.equal(await page.locator("#cloud-account").innerText(), "已连接", "profile failure logged out the account");
    await page.unroute("**/api/v1/cloud115/account");
    let heldProfile;
    await page.route("**/api/v1/cloud115/account", route => {
      heldProfile = () => route.fulfill({ json: { id: "42", name: "Late profile", membership: "VIP", space: null } });
    });
    await page.locator("#cloud-account-refresh").click();
    await page.waitForFunction(() => cloud115.profileLoading);
    await page.locator("#settings-tab-settings").click();
    assert(heldProfile);
    await heldProfile();
    await page.waitForTimeout(100);
    assert.notEqual(await page.locator("#cloud-account-name").textContent(), "Late profile", "late profile changed another page");
    await page.unroute("**/api/v1/cloud115/account");
    await page.locator("#settings-tab-cloud115").click();
    await page.waitForFunction(() => !cloud115.profileLoading);
    assert.equal(await page.locator('[data-plugin="p115strmhelper"]').count(), 0);
    const folderRoots = [
      { id: "11", name: "中文音乐" }, { id: "12", name: "无损收藏" }, { id: "13", name: "Jazz & Soul" },
      { id: "14", name: "Live 演唱会" }, { id: "15", name: "电影原声" }, { id: "16", name: "新专辑" },
    ];
    let heldFolder, holdFolder = false, failFolder = false;
    await page.route("**/api/v1/cloud115/folders?*", route => {
      const parent = new URL(route.request().url()).searchParams.get("parent");
      const breadcrumbs = [{ id: "0", name: "全部文件" }];
      if (parent !== "0") breadcrumbs.push(folderRoots[0]);
      if (parent !== "0" && parent !== "11") breadcrumbs.push({ id: parent, name: "专辑" + (Number(parent) - 100) });
      const data = { parent, path: "/" + breadcrumbs.slice(1).map(part => part.name).join("/"), breadcrumbs,
        items: parent === "0" ? folderRoots : parent === "11" ? Array.from({ length: 52 }, (_, i) => ({ id: String(101 + i), name: `专辑${i + 1}` })) : [] };
      if (holdFolder) { heldFolder = () => route.fulfill({ json: data }); return; }
      if (failFolder) return route.fulfill({ status: 502, json: { error: "目录暂不可用" } });
      return route.fulfill({ json: data });
    });
    assert.equal(await page.locator(".sheet-title h2 svg").count(), 0, "cloud icon remains before the heading");
    assert.equal(await page.locator("#cloud-root-id").getAttribute("type"), "hidden");
    await page.locator("#cloud-browse").click();
    await page.locator(".cloud-folder-entry").nth(5).waitFor();
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "115 directory picker overflows");
      const bounds = await page.locator("#cloud-directory-browser").boundingBox();
      assert(bounds.x >= 0 && bounds.y >= 0 && bounds.y + bounds.height <= 1000, "directory picker exceeds viewport");
      await page.screenshot({ path: `.build/resona-v27-directory-${width}.png`, fullPage: true });
    }
    await page.locator(".cloud-folder-entry").first().click();
    await page.waitForFunction(() => document.querySelector("#cloud-folder-count").textContent.includes("52 个文件夹"));
    assert.equal(await page.locator(".cloud-folder-entry").count(), 50);
    assert.equal(await page.locator("#cloud-folder-path [aria-current]").textContent(), "中文音乐");
    await page.locator("#cloud-folder-next").click();
    assert.equal(await page.locator(".cloud-folder-entry").count(), 2);
    await page.locator(".cloud-folder-entry").last().click();
    await page.waitForFunction(() => document.querySelector("#cloud-folder-path [aria-current]").textContent === "专辑52");
    assert.match(await page.locator("#cloud-folders").innerText(), /没有子文件夹/);
    await page.locator("#cloud-folder-use").click();
    assert.equal(await page.locator("#cloud-root-path").inputValue(), "/中文音乐/专辑52");
    assert.equal(await page.locator("#cloud-root-id").inputValue(), "152");
    await page.locator("#cloud-form button[type=submit]").click();
    await page.waitForFunction(() => !cloud115.busy);
    const pickedSettings = await page.evaluate(async () => (await (await fetch("/api/v1/cloud115")).json()).settings);
    assert.equal(pickedSettings.root_path, "/中文音乐/专辑52");
    assert.equal(pickedSettings.root_id, "152");
    await page.locator("#cloud-browse").click();
    await page.waitForFunction(() => document.querySelector("#cloud-folder-path [aria-current]")?.textContent === "专辑52");
    await page.locator("#cloud-folder-path button").first().click();
    await page.locator(".cloud-folder-entry").nth(5).waitFor();
    await page.keyboard.press("Escape");
    assert.equal(await page.locator("#cloud-root-path").inputValue(), "/中文音乐/专辑52", "cancel changed the selected folder");
    failFolder = true;
    await page.locator("#cloud-browse").click();
    await page.locator("#cloud-folder-retry").waitFor({ state: "visible" });
    assert.equal(await page.locator("#cloud-folder-use").isDisabled(), true);
    failFolder = false;
    await page.locator("#cloud-folder-retry").click();
    await page.waitForFunction(() => !document.querySelector("#cloud-folder-use").disabled);
    await page.locator("#cloud-directory-close").click();
    holdFolder = true;
    await page.locator("#cloud-browse").click();
    await page.waitForFunction(() => cloud115.folderLoading);
    await page.waitForTimeout(50);
    assert(heldFolder);
    await page.locator("#cloud-directory-close").click();
    holdFolder = false;
    await heldFolder();
    assert.equal(await page.locator("#cloud-directory-browser").isVisible(), false);
    assert.equal(await page.locator("#cloud-root-path").inputValue(), "/中文音乐/专辑52", "late directory response changed selection");
    // Existing settings that only contain an ID recover the real path from 115.
    await page.route("**/api/v1/cloud115?*", async route => {
      const response = await route.fetch();
      const data = await response.json();
      data.settings.root_id = "11";
      delete data.settings.root_path;
      await route.fulfill({ json: data });
    });
    await page.evaluate(() => cloud115.load(true));
    await page.waitForFunction(() => document.querySelector("#cloud-root-path").value === "/中文音乐");
    await page.unroute("**/api/v1/cloud115?*");
    await page.locator("#cloud-browse").click();
    await page.waitForFunction(() => !cloud115.folderLoading);
    await page.locator("#cloud-folder-path button").first().click();
    await page.locator(".cloud-folder-entry").nth(5).waitFor();
    await page.locator("#cloud-folder-use").click();
    assert.equal(await page.locator("#cloud-root-path").inputValue(), "/");
    await page.unroute("**/api/v1/cloud115/folders?*");
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator("#cloud-enabled").check();
    await page.locator("#cloud-download-lyrics").check();
    await page.locator("#cloud-base-url").fill("");
    assert.equal(await page.locator("#cloud-download-lyrics").getAttribute("role"), "switch");
    assert.equal(await page.locator(".account-sheet #cloud-sync").count(), 1);
    assert.equal(await page.locator(".cloud-generation, #cloud-interval").count(), 0);
    for (const mode of ["daily", "manual"]) {
      await page.locator("#cloud-sync-mode").selectOption(mode);
      assert.equal(await page.locator("#cloud-sync-time").isDisabled(), mode === "manual");
      if (mode === "daily") await page.locator("#cloud-sync-time").fill("21:45");
      await page.locator("#cloud-form button[type=submit]").click();
      await page.waitForFunction(() => !cloud115.busy);
      const plan = await page.evaluate(async () => (await (await fetch("/api/v1/cloud115")).json()).settings.sync_schedule);
      assert.deepEqual(plan, { mode, interval: "", time: "21:45" });
    }
    await page.locator("#cloud-form button[type=submit]").click();
    await page.waitForFunction(() => !document.querySelector("#cloud-sync").disabled);
    const mainServiceURL = await page.evaluate(async () => (await (await fetch("/api/v1/cloud115")).json()).settings.base_url);
    assert.equal(mainServiceURL, new URL(url).origin, "STRM must use the main service address and port");
    const lyricSetting = await page.evaluate(async () => (await (await fetch("/api/v1/cloud115")).json()).settings.download_lyrics);
    assert.equal(lyricSetting, true, "lyric download choice was not saved");
    assert.equal(await page.locator("#cloud-download-http").inputValue(), "false", "HTTP must be opt-in");
    for (const httpMode of [true, false]) {
      await page.locator("#cloud-download-http").selectOption(String(httpMode));
      assert.equal((await page.locator("#cloud-download-http-hint").textContent()).includes("明文传输 115 Cookie"), httpMode);
      await page.locator("#cloud-form button[type=submit]").click();
      await page.waitForFunction(() => !cloud115.busy);
      const savedMode = await page.evaluate(async () => (await (await fetch("/api/v1/cloud115")).json()).settings.download_http);
      assert.equal(savedMode, httpMode, "download protocol choice was not saved");
      await page.locator("#settings-tab-settings").click();
      await page.locator("#settings-tab-cloud115").click();
      await page.evaluate(() => cloud115.load(true));
      assert.equal(await page.locator("#cloud-download-http").inputValue(), String(httpMode), "protocol choice did not reload");
    }
    await page.waitForFunction(() => document.querySelector("#cloud-membership").textContent.includes("年费 VIP"));
    assert.equal(await page.locator("#cloud-storage-meter").isVisible(), true);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(() => { document.querySelector("#toast").hidden = true; window.scrollTo(0, 0); });
      const columns = await page.locator("#cloud-form").evaluate(node => getComputedStyle(node).gridTemplateColumns.split(" ").length);
      assert.equal(columns, width === 1440 ? 2 : 1, "cloud card column count");
      await page.screenshot({ path: `.build/resona-v26-cloud-${width}.png`, fullPage: true });
    }
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.locator("#cloud-download-http-hint").scrollIntoViewIfNeeded();
      await page.evaluate(() => window.scrollBy(0, 140));
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "protocol setting overflows");
      await page.screenshot({ path: `.build/resona-v24-download-mode-${width}.png` });
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    // A slow progress response must not keep the launch request active or block stop/navigation.
    let heldProgress, progressStopped = false, stopCalls = 0, syncCalls = 0;
    const runningProgress = { busy: true, sync_busy: true, probe_busy: false, connected: true, enabled: true,
      message: "正在读取目录树 · 后台运行", probe_queued: 0 };
    await page.route("**/api/v1/cloud115/sync", route => {
      syncCalls++;
      return route.fulfill({ status: 202, json: { started: true } });
    });
    await page.route("**/api/v1/cloud115/progress", async route => {
      if (!heldProgress && !progressStopped) heldProgress = route;
      else await route.fulfill({ json: { ...runningProgress, busy: !progressStopped, sync_busy: !progressStopped,
        message: progressStopped ? "STRM 生成已终止" : runningProgress.message } });
    });
    await page.route("**/api/v1/cloud115/sync/stop", async route => {
      stopCalls++;
      progressStopped = true;
      await route.fulfill({ status: 202, json: { accepted: true } });
    });
    await page.route("**/api/v1/cloud115?*", async route => {
      const response = await route.fetch();
      const data = await response.json();
      await route.fulfill({ json: progressStopped ? data : { ...data, ...runningProgress } });
    });
    await page.locator("#cloud-sync").click();
    await page.waitForFunction(() => !cloud115.requesting && !document.querySelector("#cloud-sync-stop").hidden);
    assert.equal(await page.locator("#cloud-download-http").isDisabled(), true, "running task permits protocol changes");
    assert.equal(syncCalls, 1, "generation was launched more than once");
    await page.locator("#settings-tab-settings").click();
    assert.equal(await page.locator("#system-settings-panel").isVisible(), true, "background task blocked tab navigation");
    await page.locator("#settings-tab-cloud115").click();
    await page.locator("#cloud-sync-stop").waitFor({ state: "visible" });
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.locator("#cloud-sync-stop").scrollIntoViewIfNeeded();
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "task controls overflow");
      await page.screenshot({ path: `.build/resona-v18-cloud-running-${width}.png` });
    }
    await page.locator("#cloud-sync-stop").click();
    await page.waitForFunction(() => document.querySelector("#cloud-sync-stop").hidden);
    assert.equal(stopCalls, 1, "terminate button did not submit its independent stop endpoint");
    if (heldProgress) await heldProgress.fulfill({ json: runningProgress });
    await page.waitForTimeout(100);
    assert.equal(await page.locator("#cloud-sync-stop").isVisible(), false, "late progress resurrected a stopped task");
    await page.unroute("**/api/v1/cloud115?*");
    await page.unroute("**/api/v1/cloud115/sync");
    await page.unroute("**/api/v1/cloud115/sync/stop");
    await page.unroute("**/api/v1/cloud115/progress");
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator(".nav-item[data-view=tracks]").click();
    assert.equal(await page.locator("#library-scope").isVisible(), true);
    await page.locator("#library-scope").selectOption("cloud");
    const scanRequests = [];
    const recordScan = request => {
      if (request.method() === "POST") scanRequests.push(new URL(request.url()).pathname);
    };
    page.on("request", recordScan);
    await page.locator("#scan-button").click();
    await page.locator("#jobs-view").waitFor({ state: "visible" });
    await page.waitForFunction(async () => {
      const data = await (await fetch("/api/v1/jobs?summary=1")).json();
      return data.items.filter(job => job.library === "cloud" && job.state === "completed").length === 2;
    });
    page.off("request", recordScan);
    assert.deepEqual(scanRequests, ["/api/v1/cloud115/scan"], "cloud scan must only traverse local STRMs");
    const beforeGenerate = await page.evaluate(async () => (await fetch("/api/v1/tracks?library=cloud")).json());
    assert.equal(beforeGenerate.total, 0, "local scan generated STRMs or visited 115");
    await openSettingsTab("cloud115");
    await page.locator("#cloud-sync").click();
    await page.waitForFunction(() => document.querySelector("#cloud-sync-progress").textContent.includes("网盘音乐库已刷新"));
    const generatedTracks = await page.evaluate(async () => (await fetch("/api/v1/tracks?library=cloud")).json());
    assert.equal(generatedTracks.total, 1, "STRM generation must refresh the cloud library before probing");
    assert.equal(generatedTracks.items[0].metadata_source, "filename");
    assert.equal(await page.locator("#cloud-probe").isVisible(), false, "preprobe controls remained in settings");
    await page.locator('#cloud-go-tasks').click();
    await page.locator("#cloud-probe-view").waitFor({ state: "visible" });
    await page.evaluate(() => cloud115.load());
    assert.match(await page.locator("#cloud-probe-progress").innerText(), /等待预探测/);
    await page.locator("#cloud-probe").click();
    await page.waitForFunction(() => document.querySelector("#cloud-progress").textContent.includes("已准备 1 首"));
    assert.match(await page.locator("#cloud-items").innerText(), /Cloud Song\.flac/);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.waitForTimeout(400);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "115 page overflows viewport");
      await page.screenshot({ path: `.build/resona-v13-cloud-${width}.png` });
    }
    let probeStopped = false;
    await page.route("**/api/v1/cloud115/probe", route => route.fulfill({ status: 202, json: { started: true } }));
    await page.route("**/api/v1/cloud115/progress", route => route.fulfill({ json: {
      busy: !probeStopped, sync_busy: false, probe_busy: !probeStopped, connected: true, enabled: true,
      probe_current: probeStopped ? "" : generatedTracks.items[0].id, probe_queued: 2,
      probe_message: probeStopped ? "预探测已暂停，未完成队列已保留" : "正在探测：Cloud Song.mp3",
    } }));
    await page.route("**/api/v1/cloud115/probe/stop", async route => {
      probeStopped = true;
      await route.fulfill({ status: 202, json: { accepted: true } });
    });
    await page.locator("#cloud-probe").click();
    await page.locator("#cloud-probe-stop").waitFor({ state: "visible" });
    assert.equal(await page.locator("#cloud-sync").isEnabled(), true, "preprobe prevented independent STRM generation");
    assert.equal(await page.locator("#cloud-sync-stop").isVisible(), false);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.locator("#cloud-probe-stop").scrollIntoViewIfNeeded();
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "probe stop controls overflow");
      await page.screenshot({ path: `.build/resona-v18-cloud-probing-${width}.png` });
    }
    await page.locator("#cloud-probe-stop").click();
    await page.waitForFunction(() => document.querySelector("#cloud-probe-stop").hidden);
    assert.equal(probeStopped, true, "preprobe terminate endpoint was not called");
    await page.unroute("**/api/v1/cloud115/probe");
    await page.unroute("**/api/v1/cloud115/probe/stop");
    await page.unroute("**/api/v1/cloud115/progress");
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator(".nav-item[data-view=tracks]").click();
    assert.equal(await page.locator("#library-scope").isVisible(), true);
    await page.locator("#library-scope").selectOption("cloud");
    await page.waitForFunction(() => document.querySelectorAll(".track-row").length === 1 && document.querySelector("#track-list").textContent.includes("Cloud Song"));
    let rejectedStreams = 0;
    await page.route("**/api/v1/tracks/*/stream*", route => {
      rejectedStreams++;
      return route.fulfill({ status: 502, json: { error: "115 返回 HTTP 405，请稍后重试" } });
    });
    await page.locator("#play-all").click();
    await page.waitForFunction(() => document.querySelector("#toast").textContent.includes("115 播放失败：115 返回 HTTP 405"));
    assert.equal(rejectedStreams, 2, "failed cloud playback retried without a bound");
    assert(!/无法播放此格式/.test(await page.locator("#toast").innerText()));
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
      await page.screenshot({ path: `.build/resona-v23-playback-error-${width}.png` });
    }
    await page.unroute("**/api/v1/tracks/*/stream*");
    await page.setViewportSize({ width: 1440, height: 1000 });
    let cdnRequests = 0, playbackRefreshes = 0;
    const countRefresh = request => {
      if (new URL(request.url()).hostname === "cdnfhnfile.115cdn.net") cdnRequests++;
      if (new URL(request.url()).pathname.endsWith("/stream") && new URL(request.url()).searchParams.get("refresh") === "1")
        playbackRefreshes++;
    };
    page.on("request", countRefresh);
    await page.locator("#play-all").click();
    await page.waitForFunction(() => document.querySelector("#audio").currentTime > 0);
    page.off("request", countRefresh);
    assert(cdnRequests >= 2, "browser did not retry the rejected CDN link");
    assert.equal(playbackRefreshes, 1, "browser must refresh an expired cloud link once");
    assert.equal(await page.locator("#player-title").innerText(), "Cloud Song");
    await page.locator(".nav-item[data-view=logs]").click();
    await page.locator("#logs-category").selectOption("playback");
    await page.waitForFunction(() => document.querySelector("#logs-list").textContent.includes("115 302 播放跳转"));
    assert.match(await page.locator("#logs-list").innerText(), /302 播放.*115 302 播放跳转/s);
    assert.match(await page.locator("#logs-list").innerText(), /Cloud Song/);
    assert(!/resona-fixture\.flac|https?:\/\/|UID=|SEID=/.test(await page.locator("#logs-list").innerText()), "302 logs leaked a temporary URL or credentials");
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "302 playback logs overflow");
      await page.screenshot({ path: `.build/resona-v25-playback-logs-${width}.png` });
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator(".nav-item[data-view=manage]").click();
    await page.locator(".track-tag-badge").waitFor();
    assert.equal(await page.locator(".track-tag-badge").innerText(), "标签无歌词");
    assert.equal(await page.locator(".track-lrc-badge").innerText(), "有 LRC 歌词");
    await page.route("**/api/v1/tracks/*/lyrics", route => route.fulfill({
      status: 200, headers: { "X-Lyrics-Source": "local", "Content-Type": "text/plain" },
      body: "[00:00.00]Cloud sidecar lyric",
    }));
    await page.locator("#track-list").getByRole("button", { name: "刮削歌词", exact: true }).click();
    await page.waitForFunction(() => document.querySelector("#lyrics-status").textContent.includes("STRM 同目录 LRC"));
    assert.equal(await page.locator("#lyrics-embed").isVisible(), false);
    assert.equal(await page.locator("#lyrics-embed-replace-wrap").isVisible(), false);
    assert.match(await page.locator("#lyrics-storage-hint").innerText(), /不能将歌词写回 115/);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
      await page.screenshot({ path: `.build/resona-v21-cloud-lyrics-${width}.png` });
    }
    await page.keyboard.press("Escape");
    await page.unroute("**/api/v1/tracks/*/lyrics");
    assert.equal(await page.locator(".track-tag-badge").innerText(), "标签无歌词", "external LRC mislabeled as embedded");
    await page.locator(".nav-item[data-view=files]").click();
    await page.locator("#files-tab-cloud").waitFor({ state: "visible" });
    await page.locator("#files-tab-cloud").click();
    await page.locator("#files-list").getByRole("button", { name: "Cloud Song.flac", exact: true }).waitFor();
    assert.equal(await page.locator("#files-root").isVisible(), false);
    await page.locator("#files-list").getByRole("checkbox", { name: "选择 Cloud Song.flac", exact: true }).check();
    await page.locator('[data-file-action="copy"]').click();
    assert.equal(await page.locator('[data-file-action="paste"]').isEnabled(), true);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
      await page.screenshot({ path: `.build/resona-v21-cloud-files-${width}.png` });
    }
    await page.locator("#files-tab-local").click();
    assert.equal(await page.locator('[data-file-action="paste"]').isDisabled(), true, "cloud clipboard escaped into local storage");
    assert.equal(await page.locator("#files-root").isVisible(), true);
    await page.locator("#files-tab-local").focus();
    await page.keyboard.press("ArrowRight");
    await page.waitForFunction(() => document.querySelector("#files-tab-cloud").getAttribute("aria-selected") === "true");
    await page.route("**/api/v1/cloud115/progress", route => route.fulfill({ json: { connected: false } }));
    await page.evaluate(() => fileManager.connection());
    assert.equal(await page.locator("#files-tab-cloud").isVisible(), false);
    assert.equal(await page.locator("#files-tab-local").getAttribute("aria-selected"), "true");
    await page.unroute("**/api/v1/cloud115/progress");
    await page.locator(".nav-item[data-view=tracks]").click();
    await page.locator("#library-scope").selectOption("local");
    await page.locator(".track-row").nth(99).waitFor();
    let held, signal;
    const requested = () =>
      new Promise((resolve) => {
        signal = resolve;
      });
    await page.route("**/api/v1/tracks?**", async (route) => {
      if (route.request().url().includes("limit=500")) {
        held = route;
        signal();
      } else await route.continue();
    });
    const pending = requested();
    await page.locator("#play-all").click();
    await pending;
    const currentTitle = await page.locator("#player-title").innerText();
    await page.locator(".nav-item[data-view=manage]").click();
    await held.continue();
    await page.waitForFunction(
      () => !document.querySelector("#play-library").disabled,
    );
    assert.equal(await page.locator("#player-title").innerText(), currentTitle);
    await page.locator(".nav-item[data-view=tracks]").click();
    await page.locator(".track-row").nth(99).waitFor();
    const logoutPending = requested();
    await page.locator("#play-all").click();
    await logoutPending;
    await page.locator("#logout").click();
    await page.locator("#login-view").waitFor({ state: "visible" });
    await held.continue();
    await page.waitForTimeout(250);
    assert.equal(await page.locator("#player-bar").isVisible(), false);
    assert.equal(await page.locator("#queue-badge").textContent(), "0");
    assert.deepEqual(errors, []);
    console.log(
      "PASS: persistent log filters/pause/clear, unrestricted file browsing/copy/rename/delete, independent lyric priority and task durations; single-line task history, selection across polling, confirmed batch/all deletion, running task protection; embedded lyric badges and real LRC tag import; plugin cards, configuration, secrets and responsive dialogs; management details, paginated queue, shuffle/repeat, selection and lyrics; no JS errors",
    );
    console.log("PASS: Settings system/plugins/115 tabs, keyboard navigation and responsive layout; seven 115 Cookie QR device types without app ID, automatic QR replacement, expired QR refresh, scanned/confirmed states, private credential storage, responsive background STRM launch, independent terminate controls and late progress rejection; STRM uses the main service address and port; STRM/preprobe publication, local/cloud libraries, 302 playback without credential forwarding");
    console.log("PASS: local library scan indexes music without importing or scraping; task entry retains organizing; path-based 115 directory picker, breadcrumbs, pagination, cancel/retry and legacy path recovery");
    console.log("PASS: cloud library local STRM scan on desktop/mobile without 115 login or remote generation; separate generation/preprobe controls; specific playback failure diagnostics and bounded refresh before real 302 playback");
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
