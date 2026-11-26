#include "desktop_integration.h"

#include <windowsx.h>
#include <gdiplus.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cwctype>
#include <variant>
#include <vector>

#include "tray_logo.h"

#pragma warning(push, 3)
#include <propidl.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.media.h>
#include <systemmediatransportcontrolsinterop.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#pragma warning(pop)

namespace {
constexpr UINT kTray = WM_APP + 20;
constexpr UINT kExit = WM_APP + 21;
constexpr UINT kRegisterTray = WM_APP + 22;
constexpr UINT kAudioOutputsChanged = WM_APP + 23;
constexpr UINT kSmtcButton = WM_APP + 24;
constexpr wchar_t kSettings[] = L"Software\\Resona\\Desktop";
constexpr wchar_t kLyricsClass[] = L"ResonaDesktopLyrics";
enum Command : UINT {
  kOpen = 100, kToggle, kNext, kPrevious, kFavorite, kSequential,
  kRepeatAll, kRepeatOne, kShuffle, kLyrics, kLock, kQuit, kFont = 200
};

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                   const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

bool Flag(const flutter::EncodableMap& map, const char* key) {
  const auto value = Find(map, key);
  const auto flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

std::string Text(const flutter::EncodableMap& map, const char* key) {
  const auto value = Find(map, key);
  const auto text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : "";
}

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                      static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), size);
  return wide;
}

std::string Narrow(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                       static_cast<int>(wide.size()), nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) return {};
  std::string text(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      text.data(), size, nullptr, nullptr);
  return text;
}

bool ContainsCaseInsensitive(const std::wstring& haystack,
                             const std::wstring& needle) {
  if (needle.empty()) return true;
  auto it = std::search(
      haystack.begin(), haystack.end(), needle.begin(), needle.end(),
      [](wchar_t a, wchar_t b) { return std::towlower(a) == std::towlower(b); });
  return it != haystack.end();
}

bool StartsWithCaseInsensitive(const std::wstring& value,
                               const std::wstring& prefix) {
  if (value.size() < prefix.size()) return false;
  return std::equal(prefix.begin(), prefix.end(), value.begin(),
                    [](wchar_t a, wchar_t b) {
                      return std::towlower(a) == std::towlower(b);
                    });
}

std::wstring ReadPropString(IPropertyStore* store, const PROPERTYKEY& key) {
  if (!store) return {};
  PROPVARIANT value;
  PropVariantInit(&value);
  std::wstring result;
  if (SUCCEEDED(store->GetValue(key, &value)) &&
      value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
    result = value.pwszVal;
  }
  PropVariantClear(&value);
  return result;
}

struct AudioEndpointInfo {
  std::wstring id;
  std::string name;
  std::string enumerator;
  bool is_bluetooth = false;
  bool is_default = false;
};

class DeviceNotificationClient final : public IMMNotificationClient {
 public:
  explicit DeviceNotificationClient(HWND owner) : owner_(owner) {}

  void Detach() { owner_.store(nullptr); }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++ref_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = --ref_;
    if (count == 0) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
      *ppv = static_cast<IMMNotificationClient*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override {
    PostChange();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override {
    PostChange();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override {
    PostChange();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role,
                                                   LPCWSTR) override {
    if (flow == eRender && role == eConsole) PostChange();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR,
                                                   const PROPERTYKEY) override {
    return S_OK;
  }

 private:
  void PostChange() const {
    if (const HWND target = owner_.load()) {
      PostMessage(target, kAudioOutputsChanged, 0, 0);
    }
  }

  std::atomic<ULONG> ref_{1};
  std::atomic<HWND> owner_{nullptr};
};

using SmtcButtonHandlerBase = ABI::Windows::Foundation::ITypedEventHandler<
    ABI::Windows::Media::SystemMediaTransportControls*,
    ABI::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs*>;

class SmtcButtonHandler final : public SmtcButtonHandlerBase {
 public:
  explicit SmtcButtonHandler(HWND owner) : owner_(owner) {}

  void Detach() { owner_.store(nullptr); }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++ref_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = --ref_;
    if (count == 0) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == __uuidof(IUnknown) ||
        riid == __uuidof(SmtcButtonHandlerBase)) {
      *ppv = static_cast<SmtcButtonHandlerBase*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE Invoke(
      ABI::Windows::Media::ISystemMediaTransportControls*,
      ABI::Windows::Media::ISystemMediaTransportControlsButtonPressedEventArgs*
          args) override {
    if (!args) return S_OK;
    ABI::Windows::Media::SystemMediaTransportControlsButton button{};
    if (SUCCEEDED(args->get_Button(&button))) {
      if (const HWND target = owner_.load()) {
        PostMessage(target, kSmtcButton, static_cast<WPARAM>(button), 0);
      }
    }
    return S_OK;
  }

 private:
  std::atomic<ULONG> ref_{1};
  std::atomic<HWND> owner_{nullptr};
};

DWORD ReadSetting(const wchar_t* name, DWORD fallback) {
  DWORD value = fallback, bytes = sizeof(value);
  if (RegGetValue(HKEY_CURRENT_USER, kSettings, name, RRF_RT_REG_DWORD,
                  nullptr, &value, &bytes) != ERROR_SUCCESS) return fallback;
  return value;
}

bool LightTaskbar() {
  DWORD light = 0, bytes = sizeof(light);
  RegGetValue(HKEY_CURRENT_USER,
              L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
              L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &bytes);
  return light != 0;
}

void MenuItem(HMENU menu, UINT id, const std::wstring& title,
              bool enabled = true, bool checked = false) {
  std::wstring label;
  for (wchar_t ch : title) {
    label += ch;
    if (ch == L'&') label += ch;
  }
  MENUITEMINFO item{};
  item.cbSize = sizeof(item);
  item.fMask = MIIM_ID | MIIM_STRING | MIIM_STATE;
  item.wID = id;
  item.dwTypeData = label.data();
  item.fState = (enabled ? MFS_ENABLED : MFS_DISABLED) |
                (checked ? MFS_CHECKED : MFS_UNCHECKED);
  InsertMenuItem(menu, GetMenuItemCount(menu), TRUE, &item);
}
}  // namespace

struct DesktopIntegration::AudioState {
  explicit AudioState(HWND owner) : owner_(owner) {}

  void Initialize() {
    if (initialized_) return;
    initialized_ = true;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_ALL, IID_PPV_ARGS(&enumerator_));
    if (SUCCEEDED(hr) && enumerator_) {
      notify_client_ = new DeviceNotificationClient(owner_);
      if (FAILED(enumerator_->RegisterEndpointNotificationCallback(
              notify_client_))) {
        notify_client_->Detach();
        notify_client_->Release();
        notify_client_ = nullptr;
      }
    }

    const HRESULT ro_hr = RoInitialize(RO_INIT_SINGLETHREADED);
    ro_initialized_ = SUCCEEDED(ro_hr);
    constexpr wchar_t kSmtcClass[] =
        L"Windows.Media.SystemMediaTransportControls";
    HSTRING_HEADER class_header{};
    HSTRING class_name = nullptr;
    if (SUCCEEDED(WindowsCreateStringReference(
            kSmtcClass,
            static_cast<UINT32>(sizeof(kSmtcClass) / sizeof(wchar_t) - 1),
            &class_header, &class_name))) {
      ISystemMediaTransportControlsInterop* interop = nullptr;
      if (SUCCEEDED(
              RoGetActivationFactory(class_name, IID_PPV_ARGS(&interop))) &&
          interop) {
        if (SUCCEEDED(interop->GetForWindow(owner_, IID_PPV_ARGS(&smtc_))) &&
            smtc_) {
          constexpr boolean kWinRtTrue = 1;
          smtc_->put_IsEnabled(kWinRtTrue);
          smtc_->put_IsPlayEnabled(kWinRtTrue);
          smtc_->put_IsPauseEnabled(kWinRtTrue);
          smtc_->put_IsStopEnabled(kWinRtTrue);
          smtc_->put_IsNextEnabled(kWinRtTrue);
          smtc_->put_IsPreviousEnabled(kWinRtTrue);
          smtc_->put_PlaybackStatus(
              ABI::Windows::Media::MediaPlaybackStatus_Closed);
          smtc_handler_ = new SmtcButtonHandler(owner_);
          if (FAILED(smtc_->add_ButtonPressed(smtc_handler_, &smtc_token_))) {
            smtc_handler_->Detach();
            smtc_handler_->Release();
            smtc_handler_ = nullptr;
          } else {
            has_smtc_token_ = true;
          }
          smtc_->get_DisplayUpdater(&updater_);
        }
        interop->Release();
      }
    }
  }

  void Shutdown() {
    if (notify_client_) {
      notify_client_->Detach();
      if (enumerator_) {
        enumerator_->UnregisterEndpointNotificationCallback(notify_client_);
      }
      notify_client_->Release();
      notify_client_ = nullptr;
    }
    if (enumerator_) {
      enumerator_->Release();
      enumerator_ = nullptr;
    }
    if (smtc_handler_) {
      smtc_handler_->Detach();
      if (smtc_ && has_smtc_token_) {
        smtc_->remove_ButtonPressed(smtc_token_);
      }
      smtc_handler_->Release();
      smtc_handler_ = nullptr;
      has_smtc_token_ = false;
    }
    if (updater_) {
      updater_->Release();
      updater_ = nullptr;
    }
    if (smtc_) {
      smtc_->Release();
      smtc_ = nullptr;
    }
    if (ro_initialized_) {
      RoUninitialize();
      ro_initialized_ = false;
    }
  }

  std::vector<AudioEndpointInfo> QueryOutputs(bool* bluetooth_disconnected,
                                              bool update_tracking) {
    if (bluetooth_disconnected) *bluetooth_disconnected = false;
    std::vector<AudioEndpointInfo> result;
    if (!enumerator_) return result;

    std::wstring default_id;
    IMMDevice* default_device = nullptr;
    if (SUCCEEDED(enumerator_->GetDefaultAudioEndpoint(eRender, eConsole,
                                                       &default_device)) &&
        default_device) {
      LPWSTR id_raw = nullptr;
      if (SUCCEEDED(default_device->GetId(&id_raw)) && id_raw) {
        default_id = id_raw;
        CoTaskMemFree(id_raw);
      }
      default_device->Release();
    }

    IMMDeviceCollection* collection = nullptr;
    if (FAILED(enumerator_->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                               &collection)) ||
        !collection) {
      return result;
    }
    UINT count = 0;
    if (SUCCEEDED(collection->GetCount(&count))) {
      std::wstring next_active_bt_id;
      bool prev_bt_still_present = false;
      for (UINT i = 0; i < count; ++i) {
        IMMDevice* device = nullptr;
        if (FAILED(collection->Item(i, &device)) || !device) continue;
        LPWSTR id_raw = nullptr;
        std::wstring id;
        if (SUCCEEDED(device->GetId(&id_raw)) && id_raw) {
          id = id_raw;
          CoTaskMemFree(id_raw);
        }
        std::wstring name_w;
        std::wstring enumerator_w;
        IPropertyStore* store = nullptr;
        if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &store)) && store) {
          name_w = ReadPropString(store, PKEY_Device_FriendlyName);
          enumerator_w = ReadPropString(store, PKEY_Device_EnumeratorName);
          store->Release();
        }
        device->Release();
        if (id.empty() || name_w.empty()) continue;
        const bool is_bt =
            StartsWithCaseInsensitive(enumerator_w, L"BTH") ||
            ContainsCaseInsensitive(name_w, L"Bluetooth");
        const bool is_default = !default_id.empty() && id == default_id;
        if (!active_bt_id_.empty() && id == active_bt_id_) {
          prev_bt_still_present = true;
        }
        if (is_default && is_bt) {
          next_active_bt_id = id;
        }
        AudioEndpointInfo info;
        info.id = id;
        info.name = Narrow(name_w);
        info.enumerator = Narrow(enumerator_w);
        info.is_bluetooth = is_bt;
        info.is_default = is_default;
        result.push_back(std::move(info));
      }
      if (bluetooth_disconnected && !active_bt_id_.empty() &&
          !prev_bt_still_present) {
        *bluetooth_disconnected = true;
      }
      if (update_tracking) {
        active_bt_id_ = next_active_bt_id;
      }
    }
    collection->Release();
    return result;
  }

  flutter::EncodableList EncodeOutputs(
      const std::vector<AudioEndpointInfo>& items) const {
    flutter::EncodableList list;
    list.reserve(items.size());
    for (const auto& item : items) {
      flutter::EncodableMap entry;
      entry[flutter::EncodableValue("id")] =
          flutter::EncodableValue(Narrow(item.id));
      entry[flutter::EncodableValue("name")] =
          flutter::EncodableValue(item.name);
      entry[flutter::EncodableValue("enumerator")] =
          flutter::EncodableValue(item.enumerator);
      entry[flutter::EncodableValue("bluetooth")] =
          flutter::EncodableValue(item.is_bluetooth);
      entry[flutter::EncodableValue("isDefault")] =
          flutter::EncodableValue(item.is_default);
      list.push_back(flutter::EncodableValue(std::move(entry)));
    }
    return list;
  }

  void UpdateSmtc(bool available, bool playing, bool opening,
                  const std::wstring& title, const std::wstring& artist,
                  const std::wstring& album) {
    if (!smtc_) return;
    ABI::Windows::Media::MediaPlaybackStatus status =
        ABI::Windows::Media::MediaPlaybackStatus_Closed;
    if (available) {
      if (opening) {
        status = ABI::Windows::Media::MediaPlaybackStatus_Changing;
      } else if (playing) {
        status = ABI::Windows::Media::MediaPlaybackStatus_Playing;
      } else {
        status = ABI::Windows::Media::MediaPlaybackStatus_Paused;
      }
    }
    smtc_->put_PlaybackStatus(status);
    if (!updater_) return;
    if (!available) {
      updater_->ClearAll();
      updater_->Update();
      return;
    }
    updater_->put_Type(ABI::Windows::Media::MediaPlaybackType_Music);
    ABI::Windows::Media::IMusicDisplayProperties* music = nullptr;
    if (SUCCEEDED(updater_->get_MusicProperties(&music)) && music) {
      HSTRING_HEADER title_header{}, artist_header{};
      HSTRING title_str = nullptr, artist_str = nullptr;
      if (SUCCEEDED(WindowsCreateStringReference(
              title.c_str(), static_cast<UINT32>(title.size()), &title_header,
              &title_str))) {
        music->put_Title(title_str);
      }
      if (SUCCEEDED(WindowsCreateStringReference(
              artist.c_str(), static_cast<UINT32>(artist.size()),
              &artist_header, &artist_str))) {
        music->put_Artist(artist_str);
      }
      ABI::Windows::Media::IMusicDisplayProperties2* music2 = nullptr;
      if (SUCCEEDED(music->QueryInterface(IID_PPV_ARGS(&music2))) && music2) {
        HSTRING_HEADER album_header{};
        HSTRING album_str = nullptr;
        if (SUCCEEDED(WindowsCreateStringReference(
                album.c_str(), static_cast<UINT32>(album.size()),
                &album_header, &album_str))) {
          music2->put_AlbumTitle(album_str);
        }
        music2->Release();
      }
      music->Release();
    }
    updater_->Update();
  }

  HWND owner_;
  bool initialized_ = false;
  bool ro_initialized_ = false;
  IMMDeviceEnumerator* enumerator_ = nullptr;
  DeviceNotificationClient* notify_client_ = nullptr;
  ABI::Windows::Media::ISystemMediaTransportControls* smtc_ = nullptr;
  ABI::Windows::Media::ISystemMediaTransportControlsDisplayUpdater* updater_ =
      nullptr;
  SmtcButtonHandler* smtc_handler_ = nullptr;
  EventRegistrationToken smtc_token_{};
  bool has_smtc_token_ = false;
  std::wstring active_bt_id_;
  std::string last_signature_;
};

DesktopIntegration::DesktopIntegration(HWND owner,
                                       flutter::BinaryMessenger* messenger)
    : owner_(owner) {
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&graphics_token_, &input, nullptr);
  enabled_ = ReadSetting(L"LyricsEnabled", 0) != 0;
  locked_ = ReadSetting(L"LyricsLocked", 0) != 0;
  font_size_ = static_cast<int>(std::clamp(ReadSetting(L"FontSize", 28), 18UL, 48UL));
  positioned_ = ReadSetting(L"Positioned", 0) != 0;
  x_ = static_cast<int>(ReadSetting(L"X", 0));
  y_ = static_cast<int>(ReadSetting(L"Y", 0));
  taskbar_created_ = RegisterWindowMessage(L"TaskbarCreated");
  if (taskbar_created_) {
    ChangeWindowMessageFilterEx(owner_, taskbar_created_, MSGFLT_ALLOW, nullptr);
  }
  WNDCLASS wc{};
  wc.lpfnWndProc = LyricsProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kLyricsClass;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClass(&wc);
  lyrics_ = CreateWindowEx(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
                              WS_EX_NOACTIVATE,
                          kLyricsClass, L"Resona Desktop Lyrics", WS_POPUP,
                          0, 0, 760, 112, nullptr, nullptr, wc.hInstance, this);
  // Register after the owner has finished installing its message handler.
  PostMessage(owner_, kRegisterTray, 0, 0);
  audio_ = std::make_unique<AudioState>(owner_);
  audio_->Initialize();
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "app.resona/desktop", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call,
             std::unique_ptr<flutter::MethodResult<Value>> result) {
        if (call.method_name() == "initialize") {
          if (!lyrics_ || !graphics_token_) {
            result->Error("desktop_unavailable", "Could not create desktop controls.");
            return;
          }
          initialized_ = true;
          if (!tray_added_) AddTrayIcon();
          UpdateLyrics();
          auto preferences = Preferences();
          preferences[Value("trayAvailable")] = Value(tray_added_);
          preferences[Value("trayError")] = Value(static_cast<int32_t>(tray_error_));
          result->Success(Value(preferences));
        } else if (call.method_name() == "update") {
          const auto map = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
          if (!map) { result->Error("invalid_state", "Expected playback state."); return; }
          Update(*map);
          result->Success();
        } else if (call.method_name() == "preferences") {
          const auto map = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
          if (!map) { result->Error("invalid_preferences", "Expected preferences."); return; }
          if (Find(*map, "enabled")) enabled_ = Flag(*map, "enabled");
          if (Find(*map, "locked")) locked_ = Flag(*map, "locked");
          if (const auto size = Find(*map, "fontSize")) {
            double value = 28;
            if (const auto real = std::get_if<double>(size)) value = *real;
            if (const auto integer = std::get_if<int32_t>(size)) value = *integer;
            font_size_ = std::isfinite(value)
                ? static_cast<int>(std::clamp(value, 18.0, 48.0)) : 28;
          }
          UpdateLyrics();
          if (SavePreferences()) result->Success(Value(Preferences()));
          else result->Error("save_failed", "Could not save desktop preferences.");
        } else if (call.method_name() == "audioOutputs") {
          const auto items = audio_ ? audio_->QueryOutputs(nullptr, true)
                                    : std::vector<AudioEndpointInfo>{};
          result->Success(Value(audio_ ? audio_->EncodeOutputs(items)
                                       : flutter::EncodableList{}));
        } else if (call.method_name() == "openBluetoothSettings") {
          ShellExecute(owner_, L"open", L"ms-settings:bluetooth", nullptr,
                       nullptr, SW_SHOWNORMAL);
          result->Success();
        } else if (call.method_name() == "openSoundSettings") {
          ShellExecute(owner_, L"open", L"ms-settings:sound", nullptr, nullptr,
                       SW_SHOWNORMAL);
          result->Success();
        } else if (call.method_name() == "quit") {
          result->Success();
          PostMessage(owner_, kExit, 0, 0);
        } else {
          result->NotImplemented();
        }
      });
}

DesktopIntegration::~DesktopIntegration() {
  if (audio_) {
    audio_->Shutdown();
    audio_.reset();
  }
  if (channel_) channel_->SetMethodCallHandler(nullptr);
  KillTimer(owner_, kRegisterTray);
  if (tray_added_) Shell_NotifyIcon(NIM_DELETE, &tray_);
  if (tray_.hIcon) DestroyIcon(tray_.hIcon);
  if (lyrics_) DestroyWindow(lyrics_);
  if (graphics_token_) Gdiplus::GdiplusShutdown(graphics_token_);
}

void DesktopIntegration::AddTrayIcon() {
  if (!graphics_token_) return;
  const HWND taskbar = FindWindow(L"Shell_TrayWnd", nullptr);
  const UINT dpi = GetDpiForWindow(taskbar ? taskbar : owner_);
  HICON icon = CreateTrayLogo(GetSystemMetricsForDpi(SM_CXSMICON, dpi), LightTaskbar());
  if (!icon) {
    SetTimer(owner_, kRegisterTray, 1000, nullptr);
    return;
  }
  const HICON previous = tray_.hIcon;
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = owner_;
  tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  tray_.uCallbackMessage = kTray;
  tray_.hIcon = icon;
  const std::wstring tip = title_.empty() ? L"Resona" : L"Resona - " + title_;
  wcsncpy_s(tray_.szTip, tip.c_str(), _TRUNCATE);
  // Explorer may lose an icon while our cached registration still says it exists.
  SetLastError(ERROR_SUCCESS);
  tray_added_ = Shell_NotifyIcon(NIM_MODIFY, &tray_) != FALSE ||
                Shell_NotifyIcon(NIM_ADD, &tray_) != FALSE;
  tray_error_ = tray_added_ ? ERROR_SUCCESS : GetLastError();
  if (tray_added_) {
    tray_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, &tray_);
    KillTimer(owner_, kRegisterTray);
  } else {
    SetTimer(owner_, kRegisterTray, 1000, nullptr);
  }
  if (previous) DestroyIcon(previous);
}

void DesktopIntegration::ShowMainWindow() {
  ShowWindow(owner_, IsIconic(owner_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(owner_);
}

void DesktopIntegration::Action(const std::string& action,
                                const std::string& argument) {
  if (initialized_ && !quitting_) {
    channel_->InvokeMethod(action, argument.empty() ? nullptr
        : std::make_unique<Value>(argument));
  }
}

void DesktopIntegration::Quit() {
  if (quitting_) return;
  SavePreferences();
  if (!initialized_) {
    PostMessage(owner_, kExit, 0, 0);
    return;
  }
  Action("quit");
  quitting_ = true;
}

std::optional<LRESULT> DesktopIntegration::HandleMessage(UINT message,
                                                        WPARAM wparam,
                                                        LPARAM lparam) {
  if (message == taskbar_created_ && taskbar_created_ != 0) {
    tray_added_ = false;
    AddTrayIcon();
    return 0;
  }
  switch (message) {
    case kRegisterTray:
      AddTrayIcon();
      return 0;
    case WM_TIMER:
      if (wparam == kRegisterTray) {
        AddTrayIcon();
        return 0;
      }
      break;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
      if (wparam == HTCLOSE) {
        // DefWindowProc tracks the caption button in a nested message loop.
        caption_close_ = true;
        const LRESULT result = DefWindowProc(owner_, message, wparam, lparam);
        caption_close_ = false;
        return result;
      }
      break;
    case WM_SYSCOMMAND:
      if ((wparam & 0xfff0) == SC_CLOSE) {
        if (caption_close_) ShowWindow(owner_, SW_MINIMIZE);
        else Quit();
        return 0;
      }
      break;
    case WM_CLOSE:
      if (caption_close_) ShowWindow(owner_, SW_MINIMIZE);
      else Quit();
      return 0;
    case kExit:
      DestroyWindow(owner_);
      return 0;
    case kTray:
      if (LOWORD(lparam) == WM_CONTEXTMENU) ShowMenu();
      else if (LOWORD(lparam) == NIN_SELECT ||
               LOWORD(lparam) == NIN_KEYSELECT) ShowMainWindow();
      return 0;
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
      AddTrayIcon();
      PlaceLyrics();
      break;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
      AddTrayIcon();
      PlaceLyrics();
      break;
    case kAudioOutputsChanged:
      NotifyAudioOutputs();
      return 0;
    case kSmtcButton: {
      using ABI::Windows::Media::SystemMediaTransportControlsButton;
      switch (static_cast<SystemMediaTransportControlsButton>(wparam)) {
        case ABI::Windows::Media::SystemMediaTransportControlsButton_Play:
          Action("play");
          break;
        case ABI::Windows::Media::SystemMediaTransportControlsButton_Pause:
          Action("pause");
          break;
        case ABI::Windows::Media::SystemMediaTransportControlsButton_Stop:
          Action("stop");
          break;
        case ABI::Windows::Media::SystemMediaTransportControlsButton_Next:
          Action("next");
          break;
        case ABI::Windows::Media::SystemMediaTransportControlsButton_Previous:
          Action("previous");
          break;
        default:
          break;
      }
      return 0;
    }
    case WM_APPCOMMAND: {
      switch (GET_APPCOMMAND_LPARAM(lparam)) {
        case APPCOMMAND_MEDIA_PLAY_PAUSE:
          Action("toggle");
          return TRUE;
        case APPCOMMAND_MEDIA_PLAY:
          Action("play");
          return TRUE;
        case APPCOMMAND_MEDIA_PAUSE:
          Action("pause");
          return TRUE;
        case APPCOMMAND_MEDIA_STOP:
          Action("stop");
          return TRUE;
        case APPCOMMAND_MEDIA_NEXTTRACK:
          Action("next");
          return TRUE;
        case APPCOMMAND_MEDIA_PREVIOUSTRACK:
          Action("previous");
          return TRUE;
        default:
          break;
      }
      break;
    }
    case WM_QUERYENDSESSION:
      SavePreferences();
      Action("save");
      return TRUE;
  }
  return std::nullopt;
}

void DesktopIntegration::ShowMenu() {
  HMENU menu = CreatePopupMenu();
  MenuItem(menu, 0, available_ ? (playing_ ? L"正在播放" : L"已暂停")
                              : L"尚未播放", false);
  if (available_) {
    MenuItem(menu, 0, title_.substr(0, 120), false);
    MenuItem(menu, 0, (artist_ + (album_.empty() ? L"" : L" · " + album_)).substr(0, 120), false);
  }
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  MenuItem(menu, kToggle, playing_ ? L"暂停" : L"播放", available_ && !opening_);
  MenuItem(menu, kNext, L"下一首", available_);
  MenuItem(menu, kPrevious, L"上一首", available_);
  MenuItem(menu, kFavorite, favorite_ ? L"取消喜欢" : L"喜欢歌曲", can_favorite_, favorite_);
  HMENU repeat = CreatePopupMenu();
  MenuItem(repeat, kSequential, L"顺序播放", true, mode_ == "sequential");
  MenuItem(repeat, kRepeatAll, L"列表循环", true, mode_ == "repeatAll");
  MenuItem(repeat, kRepeatOne, L"单曲循环", true, mode_ == "repeatOne");
  AppendMenu(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(repeat), L"循环播放");
  MenuItem(menu, kShuffle, L"随机播放", true, mode_ == "shuffle");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  MenuItem(menu, kLyrics, L"桌面歌词", true, enabled_);
  MenuItem(menu, kLock, L"锁定桌面歌词（鼠标穿透）", enabled_, locked_);
  HMENU sizes = CreatePopupMenu();
  for (int size = 18; size <= 48; ++size) {
    MenuItem(sizes, kFont + size, std::to_wstring(size), enabled_, font_size_ == size);
  }
  AppendMenu(menu, MF_POPUP | (enabled_ ? 0 : MF_GRAYED),
             reinterpret_cast<UINT_PTR>(sizes), L"歌词字号");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  MenuItem(menu, kOpen, L"打开 Resona");
  MenuItem(menu, kQuit, L"退出 Resona");
  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(owner_);
  const UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                       cursor.x, cursor.y, 0, owner_, nullptr);
  DestroyMenu(menu);
  PostMessage(owner_, WM_NULL, 0, 0);
  switch (selected) {
    case kOpen: ShowMainWindow(); break;
    case kToggle: Action("toggle"); break;
    case kNext: Action("next"); break;
    case kPrevious: Action("previous"); break;
    case kFavorite: Action("favorite"); break;
    case kSequential: Action("mode", "sequential"); break;
    case kRepeatAll: Action("mode", "repeatAll"); break;
    case kRepeatOne: Action("mode", "repeatOne"); break;
    case kShuffle: Action("mode", mode_ == "shuffle" ? "sequential" : "shuffle"); break;
    case kLyrics: enabled_ = !enabled_; PreferencesChanged(); break;
    case kLock: locked_ = !locked_; PreferencesChanged(); break;
    case kQuit: Quit(); break;
    default:
      if (selected >= kFont + 18 && selected <= kFont + 48) {
        font_size_ = static_cast<int>(selected - kFont);
        PreferencesChanged();
      }
  }
}

void DesktopIntegration::Update(const Map& state) {
  available_ = Flag(state, "available");
  playing_ = Flag(state, "playing");
  opening_ = Flag(state, "opening");
  favorite_ = Flag(state, "favorite");
  can_favorite_ = Flag(state, "canFavorite");
  title_ = Wide(Text(state, "title"));
  artist_ = Wide(Text(state, "artist"));
  album_ = Wide(Text(state, "album"));
  mode_ = Text(state, "mode");
  const auto text = Wide(Text(state, "lyric"));
  const bool changed = lyric_ != text;
  lyric_ = text;
  if (changed && lyrics_) {
    SetWindowText(lyrics_, lyric_.c_str());
    NotifyWinEvent(EVENT_OBJECT_NAMECHANGE, lyrics_, OBJID_WINDOW, 0);
  }
  tray_.uFlags = NIF_TIP;
  wcsncpy_s(tray_.szTip, (L"Resona - " + title_).c_str(), _TRUNCATE);
  if (!tray_added_ || !Shell_NotifyIcon(NIM_MODIFY, &tray_)) AddTrayIcon();
  if (changed || hovered_) PaintLyrics();
  UpdateSmtc();
}

void DesktopIntegration::NotifyAudioOutputs(bool initial) {
  if (!audio_ || !initialized_ || quitting_) return;
  bool bluetooth_disconnected = false;
  const auto items = audio_->QueryOutputs(&bluetooth_disconnected, true);
  std::string signature;
  for (const auto& item : items) {
    signature += Narrow(item.id);
    signature += item.is_default ? "*|" : "|";
  }
  if (!initial && !bluetooth_disconnected &&
      signature == audio_->last_signature_) {
    return;
  }
  audio_->last_signature_ = signature;
  Map payload;
  payload[Value("devices")] = Value(audio_->EncodeOutputs(items));
  payload[Value("bluetoothDisconnected")] = Value(bluetooth_disconnected);
  channel_->InvokeMethod("audioOutputsChanged",
                         std::make_unique<Value>(std::move(payload)));
}

void DesktopIntegration::UpdateSmtc() {
  if (!audio_) return;
  audio_->UpdateSmtc(available_, playing_, opening_, title_, artist_, album_);
}

DesktopIntegration::Map DesktopIntegration::Preferences() const {
  return {{Value("enabled"), Value(enabled_)}, {Value("locked"), Value(locked_)},
          {Value("fontSize"), Value(static_cast<double>(font_size_))}};
}

bool DesktopIntegration::SavePreferences() {
  HKEY key = nullptr;
  if (RegCreateKeyEx(HKEY_CURRENT_USER, kSettings, 0, nullptr, 0, KEY_SET_VALUE,
                     nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  bool saved = true;
  auto write = [&](const wchar_t* name, DWORD value) {
    if (RegSetValueEx(key, name, 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&value), sizeof(value)) != ERROR_SUCCESS) saved = false;
  };
  write(L"LyricsEnabled", enabled_);
  write(L"LyricsLocked", locked_);
  write(L"FontSize", static_cast<DWORD>(font_size_));
  write(L"Positioned", positioned_);
  write(L"X", static_cast<DWORD>(x_));
  write(L"Y", static_cast<DWORD>(y_));
  RegCloseKey(key);
  return saved;
}

void DesktopIntegration::PreferencesChanged() {
  if (!SavePreferences()) {
    Action("error", "无法保存桌面歌词设置，请检查用户配置权限。");
  }
  UpdateLyrics();
  if (initialized_) channel_->InvokeMethod("preferences", std::make_unique<Value>(Preferences()));
}

void DesktopIntegration::PlaceLyrics(bool center) {
  if (!lyrics_) return;
  RECT frame{x_, y_, x_ + 1, y_ + 1};
  MONITORINFO monitor{sizeof(monitor)};
  GetMonitorInfo(MonitorFromRect(&frame, MONITOR_DEFAULTTONEAREST), &monitor);
  // Saved positions are clamped again after monitors or taskbar work areas change.
  dpi_ = static_cast<int>(GetDpiForWindow(lyrics_));
  const RECT area = monitor.rcWork;
  const int width = std::min(MulDiv(760, dpi_, 96), static_cast<int>(area.right - area.left));
  const int height = std::min(MulDiv(112, dpi_, 96), static_cast<int>(area.bottom - area.top));
  if (center) {
    x_ = area.left + (area.right - area.left - width) / 2;
    y_ = area.bottom - height - MulDiv(56, dpi_, 96);
  }
  x_ = std::clamp(x_, static_cast<int>(area.left), static_cast<int>(area.right) - width);
  y_ = std::clamp(y_, static_cast<int>(area.top), static_cast<int>(area.bottom) - height);
  SetWindowPos(lyrics_, HWND_TOPMOST, x_, y_, width, height, SWP_NOACTIVATE);
  PaintLyrics();
}

void DesktopIntegration::UpdateLyrics() {
  if (!lyrics_) return;
  hovered_ = false;
  LONG_PTR style = GetWindowLongPtr(lyrics_, GWL_EXSTYLE);
  SetWindowLongPtr(lyrics_, GWL_EXSTYLE,
                   locked_ ? style | WS_EX_TRANSPARENT : style & ~WS_EX_TRANSPARENT);
  if (enabled_) {
    PlaceLyrics(!positioned_);
    positioned_ = true;
    ShowWindow(lyrics_, SW_SHOWNOACTIVATE);
  } else {
    ShowWindow(lyrics_, SW_HIDE);
  }
}

int DesktopIntegration::HitButton(POINT point) const {
  if (!hovered_ || locked_) return -1;
  RECT frame{};
  GetClientRect(lyrics_, &frame);
  const int x = MulDiv(point.x, 96, dpi_), y = MulDiv(point.y, 96, dpi_);
  const int width = MulDiv(frame.right, 96, dpi_);
  if (y < 8 || y >= 40) return -1;
  if (x >= 52 && x < 172) return (x - 52) / 40;
  if (x >= width - 92 && x < width - 12) return 3 + (x - (width - 92)) / 40;
  return -1;
}

void DesktopIntegration::Hover(bool hovered) {
  if (locked_ || hovered_ == hovered) return;
  hovered_ = hovered;
  PaintLyrics();
}

void DesktopIntegration::LyricsAction(int button) {
  switch (button) {
    case 0: if (available_) Action("previous"); break;
    case 1: if (available_ && !opening_) Action("toggle"); break;
    case 2: if (available_) Action("next"); break;
    case 3: locked_ = true; PreferencesChanged(); break;
    case 4: enabled_ = false; PreferencesChanged(); break;
  }
}

void DesktopIntegration::PaintLyrics() {
  if (!lyrics_ || !graphics_token_ || !enabled_) return;
  using namespace Gdiplus;
  RECT frame{};
  GetClientRect(lyrics_, &frame);
  const int width = frame.right, height = frame.bottom;
  if (width <= 0 || height <= 0) return;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!dc || !bitmap) {
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
    ReleaseDC(nullptr, screen);
    return;
  }
  HGDIOBJ previous = SelectObject(dc, bitmap);
  {
    Bitmap surface(width, height, width * 4, PixelFormat32bppPARGB,
                   static_cast<BYTE*>(pixels));
    Graphics g(&surface);
    // A nonzero alpha keeps empty drag areas hit-testable while unlocked.
    g.Clear(Color(locked_ ? 0 : 1, 0, 0, 0));
    const REAL scale = static_cast<REAL>(dpi_) / 96;
    g.ScaleTransform(scale, scale);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
    const REAL w = static_cast<REAL>(width) / scale;
    if (hovered_) {
      GraphicsPath background;
      constexpr REAL r = 12;
      const REAL h = static_cast<REAL>(height) / scale;
      background.AddArc(0.0f, 0.0f, r * 2, r * 2, 180, 90);
      background.AddArc(w - r * 2, 0.0f, r * 2, r * 2, 270, 90);
      background.AddArc(w - r * 2, h - r * 2, r * 2, r * 2, 0, 90);
      background.AddArc(0.0f, h - r * 2, r * 2, r * 2, 90, 90);
      background.CloseFigure();
      SolidBrush dark(Color(184, 0, 0, 0));
      g.FillPath(&dark, &background);
      Pen ink(Color(255, 255, 255, 255), 1.7f);
      ink.SetStartCap(LineCapRound);
      ink.SetEndCap(LineCapRound);
      SolidBrush white(Color(255, 255, 255, 255));
      for (int i = 0; i < 3; ++i) g.DrawLine(&ink, 22.0f, 20.0f + i * 4, 36.0f, 20.0f + i * 4);
      for (int i = 0; i < 3; ++i) {
        const REAL x = 72.0f + i * 40;
        SolidBrush control(available_ && (!opening_ || i != 1) ? Color(255, 255, 255, 255) : Color(90, 255, 255, 255));
        if (i == 1 && playing_) {
          g.FillRectangle(&control, x - 5, 18.0f, 3.0f, 12.0f);
          g.FillRectangle(&control, x + 2, 18.0f, 3.0f, 12.0f);
        } else {
          const REAL direction = i == 0 ? -1.0f : 1.0f;
          PointF triangle[] = {{x - 5 * direction, 18}, {x + 5 * direction, 24},
                               {x - 5 * direction, 30}};
          g.FillPolygon(&control, triangle, 3);
          if (i != 1) g.DrawLine(&ink, x + 7 * direction, 18.0f, x + 7 * direction, 30.0f);
        }
      }
      const REAL lock = w - 72;
      g.DrawRectangle(&ink, lock - 6, 23.0f, 12.0f, 9.0f);
      g.DrawArc(&ink, lock - 4, 15.0f, 8.0f, 14.0f, 180, 180);
      g.DrawLine(&ink, w - 38, 18.0f, w - 26, 30.0f);
      g.DrawLine(&ink, w - 38, 30.0f, w - 26, 18.0f);
    }
    FontFamily family(L"Microsoft YaHei UI");
    FontFamily fallback(L"Segoe UI");
    StringFormat format;
    format.SetAlignment(StringAlignmentCenter);
    format.SetLineAlignment(StringAlignmentCenter);
    format.SetFormatFlags(StringFormatFlagsNoWrap);
    format.SetTrimming(StringTrimmingEllipsisCharacter);
    GraphicsPath text;
    const std::wstring line = lyric_.empty() ? L"Resona" : lyric_;
    text.AddString(line.c_str(), static_cast<INT>(line.size()),
                   family.GetLastStatus() == Ok ? &family : &fallback,
                   FontStyleBold, static_cast<REAL>(font_size_),
                   RectF(22, 42, std::max(1.0f, w - 44), 58), &format);
    Pen shadow(Color(110, 0, 0, 0), 6);
    shadow.SetLineJoin(LineJoinRound);
    g.TranslateTransform(0, 2);
    g.DrawPath(&shadow, &text);
    g.TranslateTransform(0, -1);
    Pen outline(Color(220, 0, 0, 0), 2);
    outline.SetLineJoin(LineJoinRound);
    g.DrawPath(&outline, &text);
    g.TranslateTransform(0, -1);
    SolidBrush white(Color(255, 255, 255, 255));
    g.FillPath(&white, &text);
  }
  RECT location{};
  GetWindowRect(lyrics_, &location);
  POINT destination{location.left, location.top}, source{0, 0};
  SIZE size{width, height};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(lyrics_, screen, &destination, &size, dc, &source,
                      0, &blend, ULW_ALPHA);
  SelectObject(dc, previous);
  DeleteObject(bitmap);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK DesktopIntegration::LyricsProc(HWND window, UINT message,
                                                WPARAM wparam, LPARAM lparam) {
  auto self = reinterpret_cast<DesktopIntegration*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<DesktopIntegration*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(window, message, wparam, lparam);
  switch (message) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_SETCURSOR:
      SetCursor(LoadCursor(nullptr, LOWORD(lparam) == HTCLIENT ? IDC_HAND : IDC_SIZEALL));
      return TRUE;
    case WM_NCHITTEST: {
      if (self->locked_) return HTTRANSPARENT;
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(window, &point);
      return self->HitButton(point) >= 0 ? HTCLIENT : HTCAPTION;
    }
    case WM_MOUSEMOVE:
    case WM_NCMOUSEMOVE: {
      self->Hover(true);
      TRACKMOUSEEVENT track{sizeof(track),
          static_cast<DWORD>(TME_LEAVE | (message == WM_NCMOUSEMOVE ? TME_NONCLIENT : 0)), window, 0};
      TrackMouseEvent(&track);
      return 0;
    }
    case WM_MOUSELEAVE:
    case WM_NCMOUSELEAVE: {
      POINT cursor{};
      RECT rect{};
      GetCursorPos(&cursor);
      GetWindowRect(window, &rect);
      if (!PtInRect(&rect, cursor)) self->Hover(false);
      return 0;
    }
    case WM_LBUTTONUP:
      self->LyricsAction(self->HitButton({GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)}));
      return 0;
    case WM_EXITSIZEMOVE: {
      RECT frame{};
      GetWindowRect(window, &frame);
      self->x_ = frame.left;
      self->y_ = frame.top;
      self->positioned_ = true;
      self->PlaceLyrics();
      self->SavePreferences();
      return 0;
    }
    case WM_DPICHANGED: {
      const auto frame = reinterpret_cast<RECT*>(lparam);
      self->x_ = frame->left;
      self->y_ = frame->top;
      self->dpi_ = HIWORD(wparam);
      self->PlaceLyrics();
      return 0;
    }
    case WM_CLOSE:
      self->enabled_ = false;
      self->PreferencesChanged();
      return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}
