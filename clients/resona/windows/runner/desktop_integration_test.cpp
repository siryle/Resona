#include "desktop_integration.h"
#include "tray_logo.h"

#include <flutter/standard_method_codec.h>

#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

void Check(bool condition, const char* description) {
  if (!condition) {
    std::cerr << "FAIL: " << description << '\n';
    std::exit(1);
  }
}

class Result : public flutter::MethodResult<Value> {
 public:
  Result() = default;
  Result(Result&& other) : value(std::move(other.value)), success(other.success) {}
  Value value;
  bool success = false;

 protected:
  void SuccessInternal(const Value* result) override {
    success = true;
    if (result) value = *result;
  }
  void ErrorInternal(const std::string&, const std::string&, const Value*) override {}
  void NotImplementedInternal() override {}
};

class Messenger : public flutter::BinaryMessenger {
 public:
  flutter::BinaryMessageHandler handler;
  mutable std::vector<std::string> actions;
  void Send(const std::string&, const uint8_t* message, size_t size,
             flutter::BinaryReply reply) const override {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    auto call = codec.DecodeMethodCall(message, size);
    actions.push_back(call->method_name());
    if (reply) {
      const auto response = codec.EncodeSuccessEnvelope();
      reply(response->data(), response->size());
    }
  }
  void SetMessageHandler(const std::string&,
                          flutter::BinaryMessageHandler callback) override {
    handler = std::move(callback);
  }
  Result Call(const std::string& method, const Map& args = {}) {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    const auto message = codec.EncodeMethodCall(
        flutter::MethodCall<Value>(method, std::make_unique<Value>(args)));
    Result result;
    handler(message->data(), message->size(), [&](const uint8_t* bytes, size_t size) {
      codec.DecodeAndProcessResponseEnvelope(bytes, size, &result);
    });
    return result;
  }
};

Map Settings(bool enabled, bool locked, double size) {
  return {{Value("enabled"), Value(enabled)}, {Value("locked"), Value(locked)},
          {Value("fontSize"), Value(size)}};
}

int FontSize(const Result& result) {
  return static_cast<int>(std::get<double>(std::get<Map>(result.value).at(Value("fontSize"))));
}
}  // namespace

int main() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  // Registry redirection is process-local; tests never touch real app settings.
  const std::wstring path = L"Software\\ResonaDesktopTests-" + std::to_wstring(GetCurrentProcessId());
  HKEY temporary = nullptr;
  Check(RegCreateKeyEx(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
                        KEY_ALL_ACCESS, nullptr, &temporary, nullptr) == ERROR_SUCCESS,
        "create isolated preferences");
  Check(RegOverridePredefKey(HKEY_CURRENT_USER, temporary) == ERROR_SUCCESS,
        "redirect preferences");
  HWND owner = CreateWindowEx(0, L"STATIC", L"Resona desktop test", WS_OVERLAPPEDWINDOW,
                              0, 0, 920, 620, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  Check(owner != nullptr, "create owner window");
  Messenger messenger;
  {
    DesktopIntegration desktop(owner, &messenger);
    const auto initial = messenger.Call("initialize");
    Check(initial.success && FontSize(initial) == 28, "default font size");
    HWND lyrics = FindWindow(L"ResonaDesktopLyrics", nullptr);
    Check(lyrics && !IsWindowVisible(lyrics), "lyrics initially hidden");
    Check(messenger.Call("preferences", Settings(true, false, 32)).success,
          "enable lyrics");
    Check(IsWindowVisible(lyrics), "enabled lyrics visible");
    Check(GetWindowLongPtr(lyrics, GWL_EXSTYLE) & WS_EX_NOACTIVATE,
          "lyrics never steal keyboard focus");
    Check(!(GetWindowLongPtr(lyrics, GWL_EXSTYLE) & WS_EX_TRANSPARENT),
          "unlocked lyrics accept mouse input");
    const auto locked = messenger.Call("preferences", Settings(true, true, 99));
    Check(locked.success && FontSize(locked) == 48, "font size upper bound");
    Check(GetWindowLongPtr(lyrics, GWL_EXSTYLE) & WS_EX_TRANSPARENT,
          "locked lyrics allow cross-process click-through");
    Check(FontSize(messenger.Call("preferences", Settings(true, true, -5))) == 18,
          "font size lower bound");
    Check(messenger.Call("update", {{Value("lyric"), Value("A synchronized line")},
                                    {Value("title"), Value("Track")}}).success,
          "playback updates render lyrics");
    wchar_t accessible_name[128]{};
    GetWindowText(lyrics, accessible_name, 128);
    Check(std::wstring(accessible_name) == L"A synchronized line",
          "lyrics expose their current text as the accessible window name");
    messenger.Call("preferences", Settings(true, false, 28));
    SetWindowPos(lyrics, nullptr, -30000, -30000, 760, 112, SWP_NOACTIVATE | SWP_NOZORDER);
    SendMessage(lyrics, WM_EXITSIZEMOVE, 0, 0);
    RECT frame{};
    GetWindowRect(lyrics, &frame);
    MONITORINFO monitor{sizeof(monitor)};
    GetMonitorInfo(MonitorFromWindow(lyrics, MONITOR_DEFAULTTONEAREST), &monitor);
    Check(frame.left >= monitor.rcWork.left && frame.top >= monitor.rcWork.top &&
              frame.right <= monitor.rcWork.right && frame.bottom <= monitor.rcWork.bottom,
          "offscreen positions clamp to the monitor work area");
    SendMessage(lyrics, WM_CLOSE, 0, 0);
    Check(!IsWindowVisible(lyrics) && IsWindow(owner), "closing lyrics preserves the app");
    Check(messenger.actions.back() == "preferences", "native preference changes notify Dart");
    Check(desktop.HandleMessage(WM_QUERYENDSESSION, 0, 0) == TRUE,
          "shutdown is not prevented");
    Check(messenger.actions.back() == "save", "shutdown requests playback persistence");
    desktop.HandleMessage(WM_SYSCOMMAND, SC_CLOSE, 0);
    Check(messenger.actions.back() == "quit" && IsWindow(owner),
          "taskbar close waits for Dart to save before destroying the owner");
    const auto count = messenger.actions.size();
    desktop.HandleMessage(WM_CLOSE, 0, 0);
    Check(messenger.actions.size() == count, "duplicate quit requests ignored");
    for (const int size : {16, 20, 24, 32}) {
      for (const bool light : {false, true}) {
        HICON icon = CreateTrayLogo(size, light);
        Check(icon != nullptr, "tray mark renders at small and high-DPI sizes");
        ICONINFO info{};
        Check(GetIconInfo(icon, &info) != FALSE, "read rendered tray mark");
        BITMAPINFO bitmap{};
        bitmap.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bitmap.bmiHeader.biWidth = size;
        bitmap.bmiHeader.biHeight = -size;
        bitmap.bmiHeader.biPlanes = 1;
        bitmap.bmiHeader.biBitCount = 32;
        std::vector<uint32_t> pixels(size * size);
        HDC dc = GetDC(nullptr);
        Check(GetDIBits(dc, info.hbmColor, 0, size, pixels.data(), &bitmap,
                        DIB_RGB_COLORS) != 0, "read tray pixels");
        ReleaseDC(nullptr, dc);
        size_t visible = 0;
        for (const auto pixel : pixels) if (pixel >> 24) ++visible;
        Check(visible > pixels.size() / 10 && visible < pixels.size() * 9 / 10,
              "tray mark has a visible silhouette and transparent surroundings");
        DeleteObject(info.hbmColor);
        DeleteObject(info.hbmMask);
        DestroyIcon(icon);
      }
    }
  }
  Check(!FindWindow(L"ResonaDesktopLyrics", nullptr), "lyrics window released");
  Check(!messenger.handler, "channel handler released");
  {
    DesktopIntegration restored(owner, &messenger);
    const auto preferences = messenger.Call("initialize");
    const auto values = std::get<Map>(preferences.value);
    Check(!std::get<bool>(values.at(Value("enabled"))) && FontSize(preferences) == 28,
          "preferences restored after restart");
  }
  DestroyWindow(owner);
  RegOverridePredefKey(HKEY_CURRENT_USER, nullptr);
  RegCloseKey(temporary);
  RegDeleteTree(HKEY_CURRENT_USER, path.c_str());
  std::cout << "Windows desktop integration checks passed.\n";
  return 0;
}
