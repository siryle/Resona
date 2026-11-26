"use strict";
(() => {
  function isBluetoothLabel(label) {
    if (typeof label !== "string" || !label.trim()) return false;
    return /bluetooth|airpods|buds|freebuds|wh-|wf-|bose|jbl|beats|sony|sennheiser|蓝牙|耳机/i.test(
      label,
    );
  }

  function shouldAutoAdvance(
    prevState,
    nextState,
    position,
    duration,
    manualStop = false,
  ) {
    if (manualStop || prevState !== "PLAYING") return false;
    if (nextState !== "STOPPED" && nextState !== "NO_MEDIA_PRESENT") {
      return false;
    }
    if (!Number.isFinite(duration) || duration <= 0) return true;
    return Number.isFinite(position) && position >= Math.max(0, duration - 4);
  }

  function createOutputController(deps) {
    const {
      $,
      el,
      api,
      audio,
      state,
      toast,
      playTrackLocally,
      skip,
      renderPlaybackControls,
      renderPlayerProgress,
      updateListeningLyrics,
      setQueueOpen,
      onPanelToggle,
    } = deps;

    const controller = {
      activeDevice: null,
      devices: [],
      localSinks: [],
      selectedSinkId: "",
      status: null,
      playing: false,
      position: 0,
      duration: 0,
      volume: Number($("volume")?.value ?? 0.8),
      pollTimer: null,
      manualStop: false,
      lastTransportState: "",
      detectedBaseUrl: "",
      savedBaseUrl: "",
    };

    const panel = () => $("output-panel");
    const toggleBtn = () => $("output-toggle");

    function isCasting() {
      return Boolean(controller.activeDevice);
    }

    function isPaused() {
      return isCasting() ? !controller.playing : audio.paused;
    }

    function currentPosition() {
      if (isCasting()) return controller.position;
      return Number.isFinite(audio.currentTime) ? audio.currentTime : 0;
    }

    function currentDuration() {
      if (isCasting()) {
        return controller.duration > 0
          ? controller.duration
          : Number(state.current?.duration || 0);
      }
      return Number.isFinite(audio.duration) ? audio.duration : 0;
    }

    function updateToggleButton() {
      const btn = toggleBtn();
      if (!btn) return;
      const active =
        isCasting() ||
        (Boolean(controller.selectedSinkId) &&
          controller.selectedSinkId !== "default");
      btn.setAttribute("aria-pressed", String(active));
      const label = isCasting()
        ? `DLNA 投屏中 · ${controller.activeDevice.name}`
        : activeLabel();
      btn.title = label;
      btn.setAttribute("aria-label", `音频输出与 DLNA 投屏 · ${label}`);
      const status = $("output-status");
      if (status) {
        status.textContent = isCasting()
          ? `DLNA 投屏中 · ${controller.activeDevice.name}`
          : label;
      }
      const stopBtn = $("output-stop-cast");
      if (stopBtn) stopBtn.hidden = !isCasting();
    }

    function activeLabel() {
      const selected = controller.localSinks.find(
        (d) => d.deviceId === controller.selectedSinkId,
      );
      if (selected && selected.label) {
        return `${isBluetoothLabel(selected.label) ? "蓝牙输出" : "音频输出"} · ${selected.label}`;
      }
      const anyBt = controller.localSinks.find((d) =>
        isBluetoothLabel(d.label),
      );
      if (anyBt && anyBt.deviceId === "default") {
        return `蓝牙输出 · ${anyBt.label}`;
      }
      return "本机与蓝牙输出（跟随系统）";
    }

    function updateMediaSession() {
      if (!("mediaSession" in navigator) || !state.current) return;
      try {
        navigator.mediaSession.playbackState = isPaused()
          ? "paused"
          : "playing";
        const duration = currentDuration();
        const position = Math.min(currentPosition(), duration || currentPosition());
        if (
          typeof navigator.mediaSession.setPositionState === "function" &&
          Number.isFinite(duration) &&
          duration > 0
        ) {
          navigator.mediaSession.setPositionState({
            duration,
            playbackRate: isPaused() ? 0 : 1,
            position: Math.max(0, position),
          });
        }
      } catch {
        /* Ignore unsupported MediaSession states on restricted browsers. */
      }
    }

    function syncPlayVisuals() {
      const paused = isPaused();
      $("play-symbol")?.setAttribute(
        "d",
        paused ? "m9 5 11 7-11 7Z" : "M8 5h2v14H8Zm6 0h2v14h-2Z",
      );
      $("play-pause")?.setAttribute("aria-label", paused ? "播放" : "暂停");
      $("listening-record")?.classList.toggle("spinning", !paused);
      updateMediaSession();
    }

    function renderLocalSinks() {
      const list = $("output-local-list");
      const pickBtn = $("output-pick-sink");
      if (!list) return;
      list.replaceChildren();
      const supportsSink = typeof audio.setSinkId === "function";
      if (pickBtn) {
        pickBtn.hidden =
          typeof navigator.mediaDevices?.selectAudioOutput !== "function";
      }

      const defaultBtn = el("button", "output-item");
      defaultBtn.type = "button";
      const isDefault =
        !isCasting() &&
        (!controller.selectedSinkId || controller.selectedSinkId === "default");
      defaultBtn.setAttribute("aria-current", String(isDefault));
      const defCopy = el("span", "output-copy");
      defCopy.append(
        el("strong", "", "系统默认输出（包含当前已连接蓝牙耳机/音箱）"),
        el(
          "small",
          "",
          supportsSink
            ? "在系统蓝牙设置连接设备后自动生效"
            : "由当前操作系统及浏览器接管蓝牙音频路由",
        ),
      );
      defaultBtn.append(
        defCopy,
        el("span", "output-tag", isDefault ? "当前" : "切换"),
      );
      defaultBtn.addEventListener("click", async () => {
        await switchToLocalSink("");
      });
      list.append(defaultBtn);

      const seen = new Set();
      for (const sink of controller.localSinks) {
        if (!sink.deviceId || sink.deviceId === "default" || seen.has(sink.deviceId)) {
          continue;
        }
        seen.add(sink.deviceId);
        const row = el("button", "output-item");
        row.type = "button";
        const active = !isCasting() && controller.selectedSinkId === sink.deviceId;
        row.setAttribute("aria-current", String(active));
        const copy = el("span", "output-copy");
        const name = sink.label || `音频设备 (${sink.deviceId.slice(0, 6)})`;
        copy.append(
          el("strong", "", name),
          el(
            "small",
            "",
            isBluetoothLabel(name) ? "蓝牙音频设备" : "本机 / 外接音频输出",
          ),
        );
        row.append(copy, el("span", "output-tag", active ? "当前" : "选择"));
        row.disabled = !supportsSink;
        row.addEventListener("click", async () => {
          await switchToLocalSink(sink.deviceId);
        });
        list.append(row);
      }
      updateToggleButton();
    }

    function renderDlnaDevices() {
      const list = $("output-dlna-list");
      if (!list) return;
      list.replaceChildren();
      if (!controller.devices.length) {
        list.append(
          el(
            "p",
            "muted output-empty",
            "暂未发现支持 DLNA 投屏的音箱或电视。请确认同一局域网并点击刷新，或下方手动添加描述地址。",
          ),
        );
        updateToggleButton();
        return;
      }
      for (const device of controller.devices) {
        const row = el("div", "output-item dlna-row");
        const active = controller.activeDevice?.udn === device.udn;
        row.setAttribute("aria-current", String(active));
        const mainBtn = el("button", "output-item-main");
        mainBtn.type = "button";
        const copy = el("span", "output-copy");
        copy.append(
          el("strong", "", device.name || device.udn),
          el(
            "small",
            "",
            [device.manufacturer, device.model, device.manual ? "手动" : ""]
              .filter(Boolean)
              .join(" · ") || device.location,
          ),
        );
        mainBtn.append(
          copy,
          el("span", "output-tag", active ? "投屏中" : "投屏"),
        );
        mainBtn.addEventListener("click", () => selectDlnaDevice(device));
        row.append(mainBtn);
        if (device.manual) {
          const del = el("button", "icon-button output-remove", "×");
          del.type = "button";
          del.setAttribute("aria-label", `移除 ${device.name}`);
          del.addEventListener("click", async () => {
            await removeManualDevice(device);
          });
          row.append(del);
        }
        list.append(row);
      }
      updateToggleButton();
    }

    async function refreshLocalSinks() {
      if (!navigator.mediaDevices?.enumerateDevices) {
        controller.localSinks = [];
        renderLocalSinks();
        return;
      }
      try {
        const all = await navigator.mediaDevices.enumerateDevices();
        const prevSelected = controller.selectedSinkId;
        controller.localSinks = all.filter((d) => d.kind === "audiooutput");
        if (
          prevSelected &&
          prevSelected !== "default" &&
          !controller.localSinks.some((d) => d.deviceId === prevSelected)
        ) {
          controller.selectedSinkId = "";
          if (!isCasting() && !audio.paused) {
            audio.pause();
            syncPlayVisuals();
            toast("蓝牙或外接音频设备已断开，已暂停播放。");
          }
          if (typeof audio.setSinkId === "function") {
            await audio.setSinkId("").catch(() => {});
          }
        }
      } catch {
        controller.localSinks = [];
      }
      renderLocalSinks();
    }

    async function switchToLocalSink(sinkId) {
      if (isCasting()) {
        await stopCasting({ restoreLocal: true });
      }
      if (typeof audio.setSinkId === "function") {
        try {
          await audio.setSinkId(sinkId || "");
          controller.selectedSinkId = sinkId || "";
        } catch (error) {
          toast(error?.message || "切换音频输出失败。");
        }
      } else {
        controller.selectedSinkId = "";
      }
      renderLocalSinks();
      renderDlnaDevices();
    }

    async function refreshDlnaDevices(force = false) {
      if (!state.user) return;
      const btn = $("output-refresh");
      if (btn) btn.disabled = true;
      try {
        const data = await api(
          `/dlna/devices${force ? "?refresh=1" : ""}`,
        );
        controller.devices = data.items || [];
        controller.savedBaseUrl = data.base_url || "";
        controller.detectedBaseUrl = data.detected_base_url || "";
        const baseInput = $("dlna-base-url");
        if (baseInput) {
          baseInput.value = controller.savedBaseUrl;
          baseInput.placeholder =
            controller.detectedBaseUrl
              ? `自动检测：${controller.detectedBaseUrl}`
              : "回调地址（如 http://192.168.1.10:8080）";
        }
        renderDlnaDevices();
      } catch (error) {
        toast(error.message);
      } finally {
        if (btn) btn.disabled = false;
      }
    }

    async function selectDlnaDevice(device) {
      if (controller.activeDevice?.udn === device.udn) {
        await stopCasting({ restoreLocal: true });
        return;
      }
      const resumePos = currentPosition();
      const shouldPlay = Boolean(state.current);
      if (!audio.paused) audio.pause();
      controller.activeDevice = device;
      controller.manualStop = false;
      renderDlnaDevices();
      renderLocalSinks();
      if (shouldPlay && state.current) {
        await castTrack(state.current, resumePos);
      } else {
        toast(`已连接 DLNA 设备「${device.name}」，点击歌曲即可投屏播放。`);
      }
    }

    async function castTrack(track, position = 0) {
      if (!controller.activeDevice || !track) return;
      controller.manualStop = false;
      controller.lastTransportState = "";
      controller.position = Number.isFinite(position) ? position : 0;
      controller.duration = Number(track.duration || 0);
      controller.playing = true;
      if (!audio.paused) audio.pause();
      syncPlayVisuals();
      renderPlayerProgress();
      try {
        const status = await api("/dlna/play", {
          method: "POST",
          body: JSON.stringify({
            udn: controller.activeDevice.udn,
            track_id: track.id,
            position: controller.position,
          }),
        });
        applyStatus(status);
        startPolling();
      } catch (error) {
        controller.playing = false;
        syncPlayVisuals();
        toast(error.message || "DLNA 投屏播放失败。");
      }
    }

    function applyStatus(status) {
      if (!status || !status.active) return;
      const prevState = controller.lastTransportState;
      const nextState = status.transport_state || "";
      controller.status = status;
      if (Number.isFinite(status.duration) && status.duration > 0) {
        controller.duration = status.duration;
      }
      if (Number.isFinite(status.position) && status.position >= 0) {
        controller.position = status.position;
      }
      if (typeof status.volume === "number" && Number.isFinite(status.volume)) {
        const volEl = $("volume");
        if (volEl && document.activeElement !== volEl) {
          volEl.value = String(Math.max(0, Math.min(1, status.volume / 100)));
        }
      }
      controller.playing =
        nextState === "PLAYING" || nextState === "TRANSITIONING";
      controller.lastTransportState = nextState;
      renderPlayerProgress();
      updateListeningLyrics();
      syncPlayVisuals();
      if (
        shouldAutoAdvance(
          prevState,
          nextState,
          controller.position,
          controller.duration,
          controller.manualStop,
        ) &&
        state.current?.id === status.track_id
      ) {
        skip(1, true);
      }
    }

    function startPolling() {
      stopPolling();
      controller.pollTimer = setInterval(async () => {
        if (!isCasting() || !state.user) return;
        try {
          const status = await api("/dlna/status");
          if (status.active) applyStatus(status);
        } catch {
          /* Ignore transient polling failures between track transitions. */
        }
      }, 1200);
    }

    function stopPolling() {
      if (controller.pollTimer) {
        clearInterval(controller.pollTimer);
        controller.pollTimer = null;
      }
    }

    async function togglePlayPause() {
      if (!isCasting()) {
        if (audio.paused) audio.play().catch((e) => toast(e.message));
        else audio.pause();
        return;
      }
      const action = controller.playing ? "pause" : "play";
      try {
        const status = await api("/dlna/control", {
          method: "POST",
          body: JSON.stringify({ action }),
        });
        applyStatus(status);
      } catch (error) {
        toast(error.message);
      }
    }

    async function seekTo(seconds) {
      if (!isCasting()) {
        if (Number.isFinite(audio.duration)) {
          audio.currentTime = Math.max(0, Math.min(audio.duration, seconds));
        }
        renderPlayerProgress();
        updateListeningLyrics();
        updateMediaSession();
        return;
      }
      const target = Math.max(0, Math.min(currentDuration() || seconds, seconds));
      controller.position = target;
      renderPlayerProgress();
      updateListeningLyrics();
      try {
        const status = await api("/dlna/control", {
          method: "POST",
          body: JSON.stringify({ action: "seek", position: target }),
        });
        applyStatus(status);
      } catch (error) {
        toast(error.message);
      }
    }

    async function setVolume(value) {
      controller.volume = value;
      if (!isCasting()) {
        audio.volume = value;
        return;
      }
      try {
        await api("/dlna/control", {
          method: "POST",
          body: JSON.stringify({
            action: "volume",
            volume: Math.round(Math.max(0, Math.min(1, value)) * 100),
          }),
        });
      } catch (error) {
        toast(error.message);
      }
    }

    async function stopCasting({ restoreLocal = false } = {}) {
      const wasCasting = isCasting();
      const resumePos = currentPosition();
      const wasPlaying = controller.playing;
      controller.manualStop = true;
      stopPolling();
      controller.activeDevice = null;
      controller.status = null;
      controller.playing = false;
      controller.lastTransportState = "";
      renderDlnaDevices();
      renderLocalSinks();
      if (wasCasting && state.user) {
        await api("/dlna/control", {
          method: "POST",
          body: JSON.stringify({ action: "stop" }),
        }).catch(() => {});
      }
      if (restoreLocal && wasCasting && state.current && playTrackLocally) {
        playTrackLocally(state.current, state.queue, wasPlaying, resumePos);
      } else {
        syncPlayVisuals();
      }
    }

    async function removeManualDevice(device) {
      try {
        if (controller.activeDevice?.udn === device.udn) {
          await stopCasting({ restoreLocal: false });
        }
        await api("/dlna/devices/manual", {
          method: "DELETE",
          body: JSON.stringify({ udn: device.udn, location: device.location }),
        });
        await refreshDlnaDevices(false);
        toast(`已移除「${device.name}」。`);
      } catch (error) {
        toast(error.message);
      }
    }

    function setPanelOpen(open, focus = true) {
      const node = panel();
      const btn = toggleBtn();
      if (!node || !btn) return;
      open = Boolean(open && state.user);
      node.hidden = !open;
      btn.setAttribute("aria-expanded", String(open));
      if (open) {
        setQueueOpen?.(false, false);
        onPanelToggle?.();
        refreshLocalSinks();
        refreshDlnaDevices(controller.devices.length === 0);
        if (focus) $("output-close")?.focus({ preventScroll: true });
      } else if (focus && !$("player-bar").hidden) {
        btn.focus({ preventScroll: true });
      }
    }

    function onLogout() {
      controller.manualStop = true;
      stopPolling();
      controller.activeDevice = null;
      controller.devices = [];
      controller.status = null;
      controller.playing = false;
      setPanelOpen(false, false);
      renderDlnaDevices();
      renderLocalSinks();
    }

    toggleBtn()?.addEventListener("click", () =>
      setPanelOpen(panel()?.hidden),
    );
    $("output-close")?.addEventListener("click", () => setPanelOpen(false));
    $("output-refresh")?.addEventListener("click", () =>
      Promise.all([refreshLocalSinks(), refreshDlnaDevices(true)]),
    );
    $("output-stop-cast")?.addEventListener("click", () =>
      stopCasting({ restoreLocal: true }),
    );
    $("output-pick-sink")?.addEventListener("click", async () => {
      if (!navigator.mediaDevices?.selectAudioOutput) return;
      try {
        const device = await navigator.mediaDevices.selectAudioOutput();
        await refreshLocalSinks();
        if (device?.deviceId) await switchToLocalSink(device.deviceId);
      } catch (error) {
        if (error?.name !== "NotAllowedError" && error?.name !== "AbortError") {
          toast(error?.message || "无法选择系统音频输出。");
        }
      }
    });
    $("dlna-manual-form")?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const input = $("dlna-manual-url");
      const url = input.value.trim();
      if (!url) return toast("请输入 DLNA 设备描述 XML 地址。");
      try {
        const dev = await api("/dlna/devices/manual", {
          method: "POST",
          body: JSON.stringify({ location: url }),
        });
        input.value = "";
        await refreshDlnaDevices(false);
        toast(`已添加 DLNA 设备「${dev.name}」。`);
      } catch (error) {
        toast(error.message);
      }
    });
    $("dlna-base-form")?.addEventListener("submit", async (event) => {
      event.preventDefault();
      const url = $("dlna-base-url").value.trim();
      try {
        const saved = await api("/dlna/settings", {
          method: "PUT",
          body: JSON.stringify({ base_url: url }),
        });
        controller.savedBaseUrl = saved.base_url || "";
        toast(
          controller.savedBaseUrl
            ? "DLNA 回调地址已保存。"
            : "已清除自定义 DLNA 回调地址，恢复自动检测。",
        );
      } catch (error) {
        toast(error.message);
      }
    });
    document.addEventListener("pointerdown", (event) => {
      const node = panel();
      const btn = toggleBtn();
      if (
        node &&
        !node.hidden &&
        !node.contains(event.target) &&
        !btn?.contains(event.target)
      ) {
        setPanelOpen(false, false);
      }
    });
    navigator.mediaDevices?.addEventListener?.("devicechange", refreshLocalSinks);
    refreshLocalSinks();

    return {
      isCasting,
      isPaused,
      currentPosition,
      currentDuration,
      castTrack,
      togglePlayPause,
      seekTo,
      setVolume,
      stopCasting,
      setPanelOpen,
      syncPlayVisuals,
      updateMediaSession,
      onLogout,
    };
  }

  const api = { isBluetoothLabel, shouldAutoAdvance, createOutputController };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else globalThis.ResonaOutput = api;
})();
