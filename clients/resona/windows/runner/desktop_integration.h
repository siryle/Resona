#ifndef RUNNER_DESKTOP_INTEGRATION_H_
#define RUNNER_DESKTOP_INTEGRATION_H_

#include <windows.h>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <optional>
#include <string>

class DesktopIntegration {
 public:
  DesktopIntegration(HWND owner, flutter::BinaryMessenger* messenger);
  ~DesktopIntegration();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  static LRESULT CALLBACK LyricsProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  void AddTrayIcon();
  void ShowMenu();
  void ShowMainWindow();
  void Quit();
  void Action(const std::string& action, const std::string& argument = "");
  void Update(const Map& state);
  Map Preferences() const;
  bool SavePreferences();
  void PreferencesChanged();
  void PlaceLyrics(bool center = false);
  void UpdateLyrics();
  void PaintLyrics();
  void Hover(bool hovered);
  void LyricsAction(int button);
  int HitButton(POINT point) const;

  HWND owner_;
  HWND lyrics_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  ULONG_PTR graphics_token_ = 0;
  NOTIFYICONDATA tray_{};
  DWORD tray_error_ = ERROR_SUCCESS;
  UINT taskbar_created_ = 0;
  bool tray_added_ = false;
  bool initialized_ = false;
  bool quitting_ = false;
  bool caption_close_ = false;
  bool available_ = false, playing_ = false, opening_ = false;
  bool favorite_ = false, can_favorite_ = false;
  bool enabled_ = false, locked_ = false, hovered_ = false;
  int font_size_ = 28;
  int dpi_ = 96;
  bool positioned_ = false;
  int x_ = 0, y_ = 0;
  std::wstring title_ = L"Resona", artist_, album_, lyric_;
  std::string mode_ = "sequential";
};

#endif
